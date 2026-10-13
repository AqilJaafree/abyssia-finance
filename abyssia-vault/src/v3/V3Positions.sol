// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {INonfungiblePositionManager as INPM} from "../interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3Factory} from "../interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "../interfaces/IUniswapV3Pool.sol";

/// @title V3Positions
/// @notice Uniswap v3 liquidity management through the NonfungiblePositionManager,
/// as an EXTERNAL library: the calling contract (the vault) is delegatecalled into,
/// so it owns every position NFT and token while this code lives outside it
/// (keeping the vault under the 24 KB limit).
/// @dev All flows are ERC-20 only. On Arc the position manager's WETH9 is a revert stub,
/// so nothing here ever sends value or uses native-wrapping helpers.
///
/// REQUIRED VAULT PATTERN for in-kind exits (reference: test/v3/V3PositionsHarness.sol).
/// Positions hold arbitrary memecoins, any of which may revert on transfer (paused,
/// blacklist, max-wallet...). One such token must never brick the exit for every
/// other position, so the vault must NOT loop `withdrawSlice` directly. Instead:
///  1. Loop every position. For each, call a vault-internal-only EXTERNAL entrypoint
///     (callable solely by `address(this)`) via `try this.<selfCall>(tokenId, shares,
///     supply, receiver)` that delegates to `withdrawSlice`. Because it is a separate
///     call frame, a failed token transfer inside `collect` reverts the
///     `decreaseLiquidity` with it, atomically.
///  2. On failure, retry with `recipient = address(this)` and record an IOU
///     `owed[receiver][token] += amount` for both position tokens, claimable later
///     (e.g. once the receiver is un-blacklisted). The vault must exclude owed
///     balances from its NAV and idle accounting.
///  3. If that also fails (the token cannot move at all), skip the position and emit
///     an event. Since the decrease reverted atomically nothing was removed: the
///     slice stays in the position and therefore accrues to the REMAINING holders,
///     while the exiting holder (whose shares are already burned) forfeits it. This
///     is the deliberate trade-off: a frozen token cannot be delivered or valued, so
///     the exit proceeds without it rather than being blocked indefinitely.
/// A malicious token can also burn all gas forwarded to the self-call (63/64 of
/// what remains); vaults should bound the gas forwarded per self-call so one
/// position cannot starve the rest of the loop.
library V3Positions {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @dev Hard cap on open v3 positions per vault: keeps valuation and the
    /// in-kind exit loop bounded in gas. Measured ~178k gas per position for an
    /// in-kind slice (~197k cold, incl. the try/self-call pattern: 25 positions
    /// ≈ 4.9M, see test_inKindExitGasAtMaxPositions); 25 v3 + 25 v4 positions keep a
    /// full in-kind exit well under Arc's 30M block gas limit.
    uint256 internal constant MAX_POSITIONS = 25;

    struct State {
        uint256[] tokenIds;
        mapping(uint256 tokenId => uint256) indexPlusOne;
    }

    struct OpenParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    event V3PositionOpened(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event V3LiquidityWithdrawn(
        uint256 indexed tokenId, uint128 liquidity, address recipient, uint256 amount0, uint256 amount1
    );
    event V3FeesCollected(uint256 indexed tokenId, address recipient, uint256 amount0, uint256 amount1);
    event V3PositionClosed(uint256 indexed tokenId);

    error TooManyPositions();
    error UnknownPosition(uint256 tokenId);
    error PositionNotEmpty(uint256 tokenId);
    error InvalidSlice();

    /// @notice Mint a new range position owned by the caller (the vault).
    /// Approvals are exact and reset to zero afterwards.
    function open(State storage s, INPM npm, OpenParams calldata p)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (s.tokenIds.length >= MAX_POSITIONS) revert TooManyPositions();
        IERC20(p.token0).forceApprove(address(npm), p.amount0Desired);
        IERC20(p.token1).forceApprove(address(npm), p.amount1Desired);
        (tokenId, liquidity, amount0, amount1) = npm.mint(
            INPM.MintParams({
                token0: p.token0,
                token1: p.token1,
                fee: p.fee,
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                amount0Desired: p.amount0Desired,
                amount1Desired: p.amount1Desired,
                amount0Min: p.amount0Min,
                amount1Min: p.amount1Min,
                recipient: address(this),
                deadline: p.deadline
            })
        );
        IERC20(p.token0).forceApprove(address(npm), 0);
        IERC20(p.token1).forceApprove(address(npm), 0);
        s.tokenIds.push(tokenId);
        s.indexPlusOne[tokenId] = s.tokenIds.length;
        emit V3PositionOpened(tokenId, liquidity, amount0, amount1);
    }

    /// @notice Remove `liquidity` and send exactly the released principal to `recipient`.
    /// Accrued fees are NOT swept: collect is capped at the decreased amounts.
    function withdraw(
        State storage s,
        INPM npm,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline,
        address recipient
    ) external returns (uint256 amount0, uint256 amount1) {
        _requireKnown(s, tokenId);
        return _withdraw(npm, tokenId, liquidity, amount0Min, amount1Min, deadline, recipient);
    }

    /// @notice Send all fees owed to a position to `recipient`. Because `withdraw` always
    /// collects its principal immediately, what remains owed is fees only.
    function collectFees(State storage s, INPM npm, uint256 tokenId, address recipient)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        _requireKnown(s, tokenId);
        (amount0, amount1) = npm.collect(
            INPM.CollectParams({
                tokenId: tokenId,
                recipient: recipient,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        emit V3FeesCollected(tokenId, recipient, amount0, amount1);
    }

    /// @notice Burn an empty position NFT and drop it from the list.
    function close(State storage s, INPM npm, uint256 tokenId) external {
        uint256 idx = _requireKnown(s, tokenId);
        (,,,,,,, uint128 liquidity,,, uint128 owed0, uint128 owed1) = npm.positions(tokenId);
        if (liquidity != 0 || owed0 != 0 || owed1 != 0) revert PositionNotEmpty(tokenId);
        npm.burn(tokenId);
        uint256 last = s.tokenIds[s.tokenIds.length - 1];
        s.tokenIds[idx] = last;
        s.indexPlusOne[last] = idx + 1;
        s.tokenIds.pop();
        delete s.indexPlusOne[tokenId];
        emit V3PositionClosed(tokenId);
    }

    /// @notice In-kind exit slice of ONE position: remove floor(liquidity * shares / supply)
    /// and send the released principal (no fees) straight to `recipient`, with zero
    /// minimums. No price is used, so nothing can be manipulated against the
    /// remaining holders. Fees stay in the position (they belong to the vault and are
    /// harvested at settlement). Call it per position through a vault self-call — see
    /// the REQUIRED VAULT PATTERN in the library NatSpec.
    /// @param supply total share supply BEFORE the exiting shares were burned.
    function withdrawSlice(
        State storage s,
        INPM npm,
        uint256 tokenId,
        uint256 shares,
        uint256 supply,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1) {
        _requireKnown(s, tokenId);
        if (supply == 0 || shares > supply) revert InvalidSlice();
        (,,,,,,, uint128 liquidity,,,,) = npm.positions(tokenId);
        // shares <= supply, so the slice never exceeds the position's liquidity.
        uint128 part = (uint256(liquidity) * shares / supply).toUint128();
        return _withdraw(npm, tokenId, part, 0, 0, deadline, recipient);
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
    function positionAmounts(INPM npm, uint256 tokenId)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (
            ,,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,,,,
        ) = npm.positions(tokenId);
        if (liquidity == 0) return (0, 0);
        address pool = IUniswapV3Factory(npm.factory()).getPool(token0, token1, fee);
        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtP <= sqrtA) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtA, sqrtB, liquidity, false);
        } else if (sqrtP < sqrtB) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtB, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtP, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liquidity, false);
        }
    }

    function _withdraw(
        INPM npm,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline,
        address recipient
    ) private returns (uint256 amount0, uint256 amount1) {
        if (liquidity == 0) return (0, 0);
        (amount0, amount1) = npm.decreaseLiquidity(
            INPM.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: deadline
            })
        );
        // A tiny liquidity slice can release 0/0 (rounded down in the pool's favour);
        // the position manager's collect() reverts when both maxima are zero, which
        // would brick a small holder's in-kind exit — so skip it.
        if (amount0 == 0 && amount1 == 0) {
            emit V3LiquidityWithdrawn(tokenId, liquidity, recipient, 0, 0);
            return (0, 0);
        }
        npm.collect(
            INPM.CollectParams({
                tokenId: tokenId,
                recipient: recipient,
                amount0Max: amount0.toUint128(),
                amount1Max: amount1.toUint128()
            })
        );
        emit V3LiquidityWithdrawn(tokenId, liquidity, recipient, amount0, amount1);
    }

    function _requireKnown(State storage s, uint256 tokenId) private view returns (uint256 index) {
        uint256 i = s.indexPlusOne[tokenId];
        if (i == 0) revert UnknownPosition(tokenId);
        return i - 1;
    }
}
