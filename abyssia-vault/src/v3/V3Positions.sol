// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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
/// REQUIRED VAULT PATTERN for in-kind exits (reference: test/v3/V3PositionsHarness.sol,
/// `inKindExit` / `sliceTo` / `claimOwed`; copy it, do not loop `withdrawSlice` directly).
/// Positions hold arbitrary memecoins, any of which may revert on transfer (paused,
/// blacklist, max-wallet...) or burn all gas it is given. One such token must never
/// brick the exit for every other position. The vault must:
///  1. Bind the self-call to the exit in progress: before the loop, write
///     keccak256(abi.encode(shares, supply, receiver)) to a TRANSIENT slot (EIP-1153),
///     clear it after; refuse to start an exit while it is set. The self-call entrypoint
///     reverts unless `msg.sender == address(this)`, its (shares, supply, receiver)
///     hash equals the stored value, and its recipient is that receiver or the vault.
///  2. Loop every position, calling that entrypoint (which delegates to `withdrawSlice`)
///     via `try this.<selfCall>{gas: SLICE_GAS}(...)`, with a fixed per-attempt gas cap
///     (reference: 500k; a slice uses ~200k). Its own call frame makes a failed token
///     transfer inside `collect` revert the `decreaseLiquidity` with it, atomically.
///  3. EIP-150 guard: before EVERY attempt, revert if
///     `gasleft() < SLICE_GAS * 64 / 63 + GAS_RESERVE` (reference reserve: 50k), so a
///     caller who sends too little gas gets a revert, never silently skipped slices.
///  4. If the first attempt fails having used >= ~90% of SLICE_GAS (measured with
///     `gasleft()` around it), treat it as out-of-gas: skip the position (emit an event)
///     without the fallback, so a gas burner costs one SLICE_GAS, not two.
///  5. Otherwise retry with `recipient = address(this)` and record an IOU
///     `owed[receiver][token] += amount` plus a per-token `owedTotal[token] += amount`,
///     where `amount` is the vault's BALANCE DELTA of each token across the withdrawal
///     (measured AND recorded inside the gas-capped self-call, so a token reporting an
///     absurd delta can only fail that attempt), never the amounts returned by the
///     position manager — fee-on-transfer tokens would otherwise over-credit. Claims
///     decrement both. `owedTotal` belongs to exited holders: the vault must exclude it
///     from `sweepSurplus` (AsyncBatchVault: balance - idle - pending - claimable must
///     also subtract owedTotal) and from ANY balance-based valuation / NAV.
///  6. If the fallback also fails (the token cannot move at all), skip the position and
///     emit an event. Since the decrease reverted atomically nothing was removed: the
///     slice stays in the position and therefore accrues to the REMAINING holders,
///     while the exiting holder (whose shares are already burned) forfeits it. This
///     is the deliberate trade-off: a frozen token cannot be delivered or valued, so
///     the exit proceeds without it rather than being blocked indefinitely.
/// Worst case per position is 2 x SLICE_GAS (a burner that evades the OOG heuristic by
/// nesting deeper still only gets the fallback attempt), so MAX_POSITIONS v3 positions
/// stay within Arc's 30M block gas limit.
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
        // mulDiv: no intermediate overflow, whatever the share supply.
        uint128 part = Math.mulDiv(liquidity, shares, supply).toUint128();
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
