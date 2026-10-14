// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {IV4PositionManager} from "../interfaces/IV4PositionManager.sol";
import {IPermit2} from "../interfaces/IPermit2.sol";
import {IStateView} from "../interfaces/IStateView.sol";
import {PoolKey, PoolKeyLib} from "../types/PoolKey.sol";

/// @title V4Positions
/// @notice Uniswap v4 liquidity management through the v4 PositionManager
/// (`modifyLiquidities`, paid via Permit2), as an EXTERNAL library: the calling contract
/// (the vault) is delegatecalled into, so it owns every position NFT and token while this
/// code lives outside it (keeping the vault under the 24 KB limit).
/// @dev ERC-20 pools only: native currency (address(0)) is rejected, so nothing here
/// sends value or wraps/unwraps.
///
/// FEES. Unlike v3, any v4 liquidity change also pays out ALL fees the position has
/// accrued. Every function that removes liquidity therefore first HARVESTS the fees to
/// the vault in a separate `modifyLiquidities` call (decrease by 0 + take), then removes
/// principal to the recipient. Fees always belong to the vault, never to an exiting
/// holder. Amounts returned are BALANCE DELTAS (fee-on-transfer safe: fees are the
/// vault's delta, principal is the recipient's delta) CAPPED by what Uniswap's own math
/// says was paid (fees from StateView fee growth, principal from the pool formula), so a
/// token that lies in `balanceOf` can never make the vault credit more than it received.
/// `open` reports the larger of the balance delta and the pool-math cost. The vault must
/// credit harvested fees in the same transaction (or `sweepSurplus` treats them as surplus).
///
/// IN-KIND EXITS use the same REQUIRED VAULT PATTERN as V3Positions (reference:
/// test/v4/V4PositionsHarness.sol): a transient-bound, gas-capped `try` self-call per
/// position that calls `withdrawSlice`, an EIP-150 gas guard, an IOU fallback to the
/// vault (`recipient == address(this)`, amounts = the vault's principal delta returned
/// here), and a skip when even that fails. Record harvested fees and IOUs INSIDE the
/// self-call frame: balance deltas are token-reported, so an absurd one must only fail
/// that attempt. Reject receivers that would swallow a slice (the vault itself, the
/// PositionManager, the PoolManager, Permit2). A failed take reverts the whole
/// `modifyLiquidities` (and the fee harvest with it, being in the same frame), so a skip
/// leaves the position untouched.
///
/// HOOKS. A hook can run code on every liquidity change and, with return-delta
/// permissions, alter the amounts. Only registry-allowlisted hooks may be used; a hook
/// that reverts on removal can block withdrawals and exits from its pool, and remove-
/// liquidity callbacks run TWICE per slice (fee harvest + decrease), so their gas counts
/// double against the in-kind exit's per-position gas cap.
library V4Positions {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using PoolKeyLib for PoolKey;

    /// @dev Hard cap on open v4 positions per vault (Plan 5 replaces this with one
    /// combined v3+v4 cap): keeps valuation and the in-kind exit loop bounded in gas.
    uint256 internal constant MAX_POSITIONS = 25;

    // v4-periphery Actions (1.0.3).
    uint8 internal constant DECREASE_LIQUIDITY = 0x01;
    uint8 internal constant MINT_POSITION = 0x02;
    uint8 internal constant BURN_POSITION = 0x03;
    uint8 internal constant SETTLE_PAIR = 0x0d;
    uint8 internal constant TAKE_PAIR = 0x11;

    /// @dev The PositionManager maps these recipient values to msg.sender / itself
    /// (ActionConstants.MSG_SENDER / ADDRESS_THIS), so they are never valid recipients.
    uint160 internal constant MAX_RESERVED_RECIPIENT = 2;

    struct State {
        uint256[] tokenIds;
        mapping(uint256 tokenId => uint256) indexPlusOne;
    }

    struct OpenParams {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    event V4PositionOpened(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event V4LiquidityWithdrawn(
        uint256 indexed tokenId, uint128 liquidity, address recipient, uint256 amount0, uint256 amount1
    );
    event V4FeesCollected(uint256 indexed tokenId, uint256 amount0, uint256 amount1);
    event V4PositionClosed(uint256 indexed tokenId);

    error TooManyPositions();
    error UnknownPosition(uint256 tokenId);
    error PositionNotEmpty(uint256 tokenId);
    error InvalidSlice();
    error InvalidRecipient();
    error NativeCurrencyNotSupported();
    error PoolNotInitialized();
    error ZeroLiquidity();
    error Slippage(uint256 spent0, uint256 spent1);

    /// @notice Mint a new range position owned by the caller (the vault), adding as much
    /// liquidity as `amount0Desired` / `amount1Desired` allow at the pool's current price.
    /// Permit2 allowances are exact, expire this block and are reset to zero afterwards.
    /// Returns `spent0` / `spent1`: what the vault actually paid (balance deltas); debit these.
    function open(
        State storage s,
        IV4PositionManager posm,
        IPermit2 permit2,
        IStateView stateView,
        OpenParams calldata p
    ) external returns (uint256 tokenId, uint128 liquidity, uint256 spent0, uint256 spent1) {
        if (s.tokenIds.length >= MAX_POSITIONS) revert TooManyPositions();
        if (p.key.currency0 == address(0)) revert NativeCurrencyNotSupported();
        liquidity = _liquidityFor(stateView, p);
        if (liquidity == 0) revert ZeroLiquidity();
        tokenId = posm.nextTokenId();
        (spent0, spent1) = _mint(posm, permit2, p, liquidity);
        // Never report less than the pool-math cost (rounded up, as the pool charges it).
        (uint256 cost0, uint256 cost1) = _costOf(stateView, p, liquidity);
        if (cost0 > spent0) spent0 = cost0;
        if (cost1 > spent1) spent1 = cost1;
        if (spent0 < p.amount0Min || spent1 < p.amount1Min) revert Slippage(spent0, spent1);

        s.tokenIds.push(tokenId);
        s.indexPlusOne[tokenId] = s.tokenIds.length;
        emit V4PositionOpened(tokenId, liquidity, spent0, spent1);
    }

    /// @notice Harvest the position's accrued fees to the vault, then remove `liquidity`
    /// and send the released principal to `recipient`.
    /// Returns the fees received by the vault (`fee0`, `fee1`) and the principal received
    /// by `recipient` (`amount0`, `amount1`), all balance deltas.
    function withdraw(
        State storage s,
        IV4PositionManager posm,
        IStateView stateView,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline,
        address recipient
    ) external returns (uint256 fee0, uint256 fee1, uint256 amount0, uint256 amount1) {
        _requireKnown(s, tokenId);
        _checkRecipient(recipient);
        return
            _withdraw(
                posm, stateView, Removal(tokenId, liquidity, amount0Min, amount1Min, deadline, recipient)
            );
    }

    /// @notice Send all fees the position has accrued to the vault.
    function collectFees(
        State storage s,
        IV4PositionManager posm,
        IStateView stateView,
        uint256 tokenId,
        uint256 deadline
    ) external returns (uint256 fee0, uint256 fee1) {
        _requireKnown(s, tokenId);
        (PoolKey memory key, uint256 info) = posm.getPoolAndPositionInfo(tokenId);
        return _harvest(posm, stateView, key, info, tokenId, deadline);
    }

    /// @notice Burn an empty (zero-liquidity) position NFT and drop it from the list.
    /// Fees are paid out on every liquidity change, so an empty position owes none.
    function close(State storage s, IV4PositionManager posm, uint256 tokenId, uint256 deadline) external {
        uint256 idx = _requireKnown(s, tokenId);
        if (posm.getPositionLiquidity(tokenId) != 0) revert PositionNotEmpty(tokenId);
        (PoolKey memory key,) = posm.getPoolAndPositionInfo(tokenId);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        posm.modifyLiquidities(abi.encode(abi.encodePacked(BURN_POSITION, TAKE_PAIR), params), deadline);

        uint256 last = s.tokenIds[s.tokenIds.length - 1];
        s.tokenIds[idx] = last;
        s.indexPlusOne[last] = idx + 1;
        s.tokenIds.pop();
        delete s.indexPlusOne[tokenId];
        emit V4PositionClosed(tokenId);
    }

    /// @notice In-kind exit slice of ONE position: harvest its fees to the vault, then
    /// remove floor(liquidity * shares / supply) and send the released principal straight
    /// to `recipient`, with zero minimums. No price is used, so nothing can be
    /// manipulated against the remaining holders. Call it per position through a vault
    /// self-call (see the library NatSpec).
    /// @param supply total share supply BEFORE the exiting shares were burned.
    function withdrawSlice(
        State storage s,
        IV4PositionManager posm,
        IStateView stateView,
        uint256 tokenId,
        uint256 shares,
        uint256 supply,
        address recipient,
        uint256 deadline
    ) external returns (uint256 fee0, uint256 fee1, uint256 amount0, uint256 amount1) {
        _requireKnown(s, tokenId);
        _checkRecipient(recipient);
        if (supply == 0 || shares > supply) revert InvalidSlice();
        uint128 liquidity = posm.getPositionLiquidity(tokenId);
        // shares <= supply, so the slice never exceeds the position's liquidity.
        // mulDiv: no intermediate overflow, whatever the share supply.
        uint128 part = Math.mulDiv(liquidity, shares, supply).toUint128();
        return _withdraw(posm, stateView, Removal(tokenId, part, 0, 0, deadline, recipient));
    }

    function count(State storage s) external view returns (uint256) {
        return s.tokenIds.length;
    }

    function tokenIdAt(State storage s, uint256 i) external view returns (uint256) {
        return s.tokenIds[i];
    }

    /// @notice Principal token amounts of a position at the pool's CURRENT price,
    /// rounded down. Excludes fees. The pool's spot price is manipulable within a
    /// block: callers that turn this into a share price must add their own
    /// manipulation guard (TWAP / deviation check).
    function positionAmounts(IV4PositionManager posm, IStateView stateView, uint256 tokenId)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        uint128 liquidity = posm.getPositionLiquidity(tokenId);
        if (liquidity == 0) return (0, 0);
        (PoolKey memory key, uint256 info) = posm.getPoolAndPositionInfo(tokenId);
        (uint160 sqrtP,,,) = stateView.getSlot0(key.toId());
        return _amountsFor(sqrtP, _tickLower(info), _tickUpper(info), liquidity, false);
    }

    /// @dev Token amounts of `liquidity` in [tickLower, tickUpper) at `sqrtP`, rounded the
    /// way the pool rounds: up when it is paid in, down when it is paid out.
    function _amountsFor(uint160 sqrtP, int24 tickLower, int24 tickUpper, uint128 liquidity, bool roundUp)
        private
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtP <= sqrtA) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, roundUp);
        } else if (sqrtP < sqrtB) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, liquidity, roundUp);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, liquidity, roundUp);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, roundUp);
        }
    }

    function _costOf(IStateView stateView, OpenParams calldata p, uint128 liquidity)
        private
        view
        returns (uint256, uint256)
    {
        PoolKey memory key = p.key;
        (uint160 sqrtP,,,) = stateView.getSlot0(key.toId());
        return _amountsFor(sqrtP, p.tickLower, p.tickUpper, liquidity, true);
    }

    /// @dev Liquidity the desired amounts buy at the pool's current price (rounded down).
    function _liquidityFor(IStateView stateView, OpenParams calldata p) private view returns (uint128) {
        PoolKey memory key = p.key;
        (uint160 sqrtP,,,) = stateView.getSlot0(key.toId());
        if (sqrtP == 0) revert PoolNotInitialized();
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtP,
            TickMath.getSqrtPriceAtTick(p.tickLower),
            TickMath.getSqrtPriceAtTick(p.tickUpper),
            p.amount0Desired,
            p.amount1Desired
        );
    }

    /// @dev MINT_POSITION (capped at the desired amounts) + SETTLE_PAIR paid through
    /// Permit2. Returns what the vault actually paid (balance deltas).
    function _mint(IV4PositionManager posm, IPermit2 permit2, OpenParams calldata p, uint128 liquidity)
        private
        returns (uint256 spent0, uint256 spent1)
    {
        address c0 = p.key.currency0;
        address c1 = p.key.currency1;
        _approve(c0, permit2, posm, p.amount0Desired);
        _approve(c1, permit2, posm, p.amount1Desired);
        uint256 before0 = IERC20(c0).balanceOf(address(this));
        uint256 before1 = IERC20(c1).balanceOf(address(this));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            p.key,
            p.tickLower,
            p.tickUpper,
            uint256(liquidity),
            p.amount0Desired.toUint128(),
            p.amount1Desired.toUint128(),
            address(this),
            bytes("")
        );
        params[1] = abi.encode(c0, c1);
        posm.modifyLiquidities(abi.encode(abi.encodePacked(MINT_POSITION, SETTLE_PAIR), params), p.deadline);
        spent0 = before0 - IERC20(c0).balanceOf(address(this));
        spent1 = before1 - IERC20(c1).balanceOf(address(this));
        _resetApproval(c0, permit2, posm);
        _resetApproval(c1, permit2, posm);
    }

    /// @dev One liquidity removal, bundled to keep the stack shallow.
    struct Removal {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
        address recipient;
    }

    function _withdraw(IV4PositionManager posm, IStateView stateView, Removal memory r)
        private
        returns (uint256 fee0, uint256 fee1, uint256 amount0, uint256 amount1)
    {
        (PoolKey memory key, uint256 info) = posm.getPoolAndPositionInfo(r.tokenId);
        // Fees first, to the vault: otherwise the decrease below would pay them to `recipient`.
        (fee0, fee1) = _harvest(posm, stateView, key, info, r.tokenId, r.deadline);
        if (r.liquidity == 0) return (fee0, fee1, 0, 0);
        (amount0, amount1) = _decrease(posm, stateView, key, info, r);
    }

    /// @dev Remove principal to `r.recipient`; report its balance delta capped by what the
    /// pool pays out (rounded down), computed before the call.
    function _decrease(
        IV4PositionManager posm,
        IStateView stateView,
        PoolKey memory key,
        uint256 info,
        Removal memory r
    ) private returns (uint256 amount0, uint256 amount1) {
        (uint160 sqrtP,,,) = stateView.getSlot0(key.toId());
        (uint256 max0, uint256 max1) =
            _amountsFor(sqrtP, _tickLower(info), _tickUpper(info), r.liquidity, false);
        uint256 before0 = IERC20(key.currency0).balanceOf(r.recipient);
        uint256 before1 = IERC20(key.currency1).balanceOf(r.recipient);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            r.tokenId, uint256(r.liquidity), r.amount0Min.toUint128(), r.amount1Min.toUint128(), bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1, r.recipient);
        posm.modifyLiquidities(
            abi.encode(abi.encodePacked(DECREASE_LIQUIDITY, TAKE_PAIR), params), r.deadline
        );
        amount0 = Math.min(IERC20(key.currency0).balanceOf(r.recipient) - before0, max0);
        amount1 = Math.min(IERC20(key.currency1).balanceOf(r.recipient) - before1, max1);
        emit V4LiquidityWithdrawn(r.tokenId, r.liquidity, r.recipient, amount0, amount1);
    }

    /// @dev Decrease by 0 ("poke") realizes the accrued fees; TAKE_PAIR sends them to the
    /// vault (zero amounts are skipped by the PositionManager). A zero-liquidity position
    /// cannot be poked (and owes no fees), so it is skipped.
    function _harvest(
        IV4PositionManager posm,
        IStateView stateView,
        PoolKey memory key,
        uint256 info,
        uint256 tokenId,
        uint256 deadline
    ) private returns (uint256 fee0, uint256 fee1) {
        if (posm.getPositionLiquidity(tokenId) == 0) return (0, 0);
        (uint256 owed0, uint256 owed1) = _feesOwed(posm, stateView, key, info, tokenId);
        uint256 before0 = IERC20(key.currency0).balanceOf(address(this));
        uint256 before1 = IERC20(key.currency1).balanceOf(address(this));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        posm.modifyLiquidities(abi.encode(abi.encodePacked(DECREASE_LIQUIDITY, TAKE_PAIR), params), deadline);
        fee0 = Math.min(IERC20(key.currency0).balanceOf(address(this)) - before0, owed0);
        fee1 = Math.min(IERC20(key.currency1).balanceOf(address(this)) - before1, owed1);
        if (fee0 != 0 || fee1 != 0) emit V4FeesCollected(tokenId, fee0, fee1);
    }

    /// @dev Fees the PoolManager will pay on the next poke, exactly as v4-core's
    /// Position.update computes them: (feeGrowthInside - last) * liquidity / 2^128. The
    /// PositionManager owns the pool position, salted with the tokenId.
    function _feesOwed(
        IV4PositionManager posm,
        IStateView stateView,
        PoolKey memory key,
        uint256 info,
        uint256 tokenId
    ) private view returns (uint256 owed0, uint256 owed1) {
        bytes32 poolId = key.toId();
        int24 tl = _tickLower(info);
        int24 tu = _tickUpper(info);
        (uint128 liq, uint256 last0, uint256 last1) =
            stateView.getPositionInfo(poolId, address(posm), tl, tu, bytes32(tokenId));
        (uint256 g0, uint256 g1) = stateView.getFeeGrowthInside(poolId, tl, tu);
        unchecked {
            owed0 = FullMath.mulDiv(g0 - last0, liq, 1 << 128);
            owed1 = FullMath.mulDiv(g1 - last1, liq, 1 << 128);
        }
    }

    function _approve(address token, IPermit2 permit2, IV4PositionManager posm, uint256 amount) private {
        IERC20(token).forceApprove(address(permit2), amount);
        // Expiration = this block: the allowance can never be used after this transaction.
        permit2.approve(token, address(posm), amount.toUint160(), uint48(block.timestamp));
    }

    function _resetApproval(address token, IPermit2 permit2, IV4PositionManager posm) private {
        permit2.approve(token, address(posm), 0, 0);
        IERC20(token).forceApprove(address(permit2), 0);
    }

    function _checkRecipient(address recipient) private pure {
        if (uint160(recipient) <= MAX_RESERVED_RECIPIENT) revert InvalidRecipient();
    }

    function _requireKnown(State storage s, uint256 tokenId) private view returns (uint256 index) {
        uint256 i = s.indexPlusOne[tokenId];
        if (i == 0) revert UnknownPosition(tokenId);
        return i - 1;
    }

    /// @dev v4-periphery PositionInfoLibrary layout: tickLower at bit 8, tickUpper at bit 32.
    function _tickLower(uint256 info) private pure returns (int24 t) {
        assembly ("memory-safe") {
            t := signextend(2, shr(8, info))
        }
    }

    function _tickUpper(uint256 info) private pure returns (int24 t) {
        assembly ("memory-safe") {
            t := signextend(2, shr(32, info))
        }
    }
}
