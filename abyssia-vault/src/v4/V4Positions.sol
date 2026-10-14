// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
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
/// holder. All amounts returned are BALANCE DELTAS (fee-on-transfer safe): fees are the
/// vault's delta, principal is the recipient's delta. The vault must credit harvested
/// fees in the same transaction (or `sweepSurplus` treats them as surplus).
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
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline,
        address recipient
    ) external returns (uint256 fee0, uint256 fee1, uint256 amount0, uint256 amount1) {
        _requireKnown(s, tokenId);
        _checkRecipient(recipient);
        return _withdraw(posm, tokenId, liquidity, amount0Min, amount1Min, deadline, recipient);
    }

    /// @notice Send all fees the position has accrued to the vault.
    function collectFees(State storage s, IV4PositionManager posm, uint256 tokenId, uint256 deadline)
        external
        returns (uint256 fee0, uint256 fee1)
    {
        _requireKnown(s, tokenId);
        (PoolKey memory key,) = posm.getPoolAndPositionInfo(tokenId);
        return _harvest(posm, key, tokenId, deadline);
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
        return _withdraw(posm, tokenId, part, 0, 0, deadline, recipient);
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
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(_tickLower(info));
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(_tickUpper(info));
        if (sqrtP <= sqrtA) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, false);
        } else if (sqrtP < sqrtB) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, false);
        }
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

    function _withdraw(
        IV4PositionManager posm,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline,
        address recipient
    ) private returns (uint256 fee0, uint256 fee1, uint256 amount0, uint256 amount1) {
        (PoolKey memory key,) = posm.getPoolAndPositionInfo(tokenId);
        // Fees first, to the vault: otherwise the decrease below would pay them to `recipient`.
        (fee0, fee1) = _harvest(posm, key, tokenId, deadline);
        if (liquidity == 0) return (fee0, fee1, 0, 0);

        uint256 before0 = IERC20(key.currency0).balanceOf(recipient);
        uint256 before1 = IERC20(key.currency1).balanceOf(recipient);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            tokenId, uint256(liquidity), amount0Min.toUint128(), amount1Min.toUint128(), bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1, recipient);
        posm.modifyLiquidities(abi.encode(abi.encodePacked(DECREASE_LIQUIDITY, TAKE_PAIR), params), deadline);
        amount0 = IERC20(key.currency0).balanceOf(recipient) - before0;
        amount1 = IERC20(key.currency1).balanceOf(recipient) - before1;
        emit V4LiquidityWithdrawn(tokenId, liquidity, recipient, amount0, amount1);
    }

    /// @dev Decrease by 0 ("poke") realizes the accrued fees; TAKE_PAIR sends them to the
    /// vault (zero amounts are skipped by the PositionManager). A zero-liquidity position
    /// cannot be poked (and owes no fees), so it is skipped.
    function _harvest(IV4PositionManager posm, PoolKey memory key, uint256 tokenId, uint256 deadline)
        private
        returns (uint256 fee0, uint256 fee1)
    {
        if (posm.getPositionLiquidity(tokenId) == 0) return (0, 0);
        uint256 before0 = IERC20(key.currency0).balanceOf(address(this));
        uint256 before1 = IERC20(key.currency1).balanceOf(address(this));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        posm.modifyLiquidities(abi.encode(abi.encodePacked(DECREASE_LIQUIDITY, TAKE_PAIR), params), deadline);
        fee0 = IERC20(key.currency0).balanceOf(address(this)) - before0;
        fee1 = IERC20(key.currency1).balanceOf(address(this)) - before1;
        if (fee0 != 0 || fee1 != 0) emit V4FeesCollected(tokenId, fee0, fee1);
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
