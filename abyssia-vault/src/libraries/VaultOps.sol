// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {VaultRegistry} from "../registry/VaultRegistry.sol";
import {V3Positions} from "../v3/V3Positions.sol";
import {V4Positions} from "../v4/V4Positions.sol";
import {VaultBook} from "./VaultBook.sol";
import {VaultSwaps} from "./VaultSwaps.sol";
import {PoolPrice} from "./PoolPrice.sol";
import {PoolOracle} from "./PoolOracle.sol";

/// @title VaultOps
/// @notice The vault's position, swap and inventory operations, as an EXTERNAL library
/// (delegatecalled, so it runs on the vault's storage and owns nothing itself). Every
/// operation keeps the token inventory in the book and RETURNS the USDC amounts, so the
/// vault alone moves idle USDC (`AsyncBatchVault.idleAssets`).
/// @dev Every credit is min(balance delta, the amount Uniswap's math reports): a token
/// lying in `balanceOf` cannot over-credit, and a fee-on-transfer token credits what
/// actually arrived.
library VaultOps {
    uint256 internal constant BPS = 10_000;
    /// @notice Hard cap on distinct non-USDC tokens held as inventory (see reserveToken).
    uint256 internal constant MAX_TOKENS = VaultBook.MAX_POSITIONS;

    struct OpenArgs {
        bytes32 poolId;
        int24 tickLower;
        int24 tickUpper;
        uint256 usdcDesired;
        uint256 tokenDesired;
        uint256 usdcMin;
        uint256 tokenMin;
        uint256 deadline;
    }

    struct SwapArgs {
        bytes32 poolId;
        bool usdcIn;
        uint256 amountIn;
        uint256 minOut;
        uint256 maxSlippageBps;
        uint32 twapWindow;
        int24 maxTwapDeviation;
    }

    /// @dev Class of the pool new exposure went to, for the vault's allocation check.
    struct Exposure {
        VaultRegistry.AssetClass cls;
        VaultRegistry.ClassParams params;
    }

    struct Removal {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    event PositionOpened(
        VaultBook.Protocol indexed protocol, uint256 indexed tokenId, bytes32 indexed poolId
    );
    event PositionClosed(VaultBook.Protocol indexed protocol, uint256 indexed tokenId);
    event TokenOwed(address indexed owner, address indexed token, uint256 amount);

    error InsufficientIdle(uint256 needed, uint256 available);
    error InsufficientInventory(address token, uint256 needed, uint256 available);
    error MinOutTooLow(uint256 minOut, uint256 floor);
    error TooManyTokens();
    error UnknownPosition(VaultBook.Protocol protocol, uint256 tokenId);

    // ---------------------------------------------------------------------
    // Positions
    // ---------------------------------------------------------------------

    /// @notice Open one range from at most `idle` USDC and the token inventory.
    /// @return tokenId the new position
    /// @return usdcSpent USDC the vault paid (debit it from idle)
    /// @return x the pool's class, for the allocation check after the debit
    function open(VaultBook.Book storage b, VaultBook.Env memory e, OpenArgs memory p, uint256 idle)
        external
        returns (uint256 tokenId, uint256 usdcSpent, Exposure memory x)
    {
        VaultBook.PoolMeta memory m;
        (m, x.params, x.cls) = VaultBook.checkOpen(b, e, p.poolId, p.tickUpper - p.tickLower);
        if (p.usdcDesired > idle) revert InsufficientIdle(p.usdcDesired, idle);
        _requireInventory(b, m.token, p.tokenDesired);
        // The position will pay out its token: hold its inventory slot from now on, so
        // withdrawals, harvests and exit slices of it can never hit the token cap.
        reserveToken(b, m.token, p.poolId);
        (uint256 a0, uint256 a1, uint256 min0, uint256 min1) = m.usdcIsToken0
            ? (p.usdcDesired, p.tokenDesired, p.usdcMin, p.tokenMin)
            : (p.tokenDesired, p.usdcDesired, p.tokenMin, p.usdcMin);
        uint256 spent0;
        uint256 spent1;
        if (m.protocol == VaultBook.Protocol.V3) {
            (address t0, address t1) = _pair(m, e.usdc);
            (tokenId,, spent0, spent1) = V3Positions.open(
                b.v3,
                e.npm,
                V3Positions.OpenParams(
                    t0, t1, m.fee, p.tickLower, p.tickUpper, a0, a1, min0, min1, p.deadline
                )
            );
        } else {
            (tokenId,, spent0, spent1) = V4Positions.open(
                b.v4,
                e.posm,
                e.permit2,
                e.stateView,
                V4Positions.OpenParams(m.v4Key, p.tickLower, p.tickUpper, a0, a1, min0, min1, p.deadline)
            );
        }
        b.positionPool[m.protocol][tokenId] = p.poolId;
        uint256 tokenSpent;
        (usdcSpent, tokenSpent) = m.usdcIsToken0 ? (spent0, spent1) : (spent1, spent0);
        _debitToken(b, m.token, tokenSpent);
        emit PositionOpened(m.protocol, tokenId, p.poolId);
    }

    /// @notice Remove liquidity into the vault (v4 also harvests the position's fees).
    /// @return usdcIn USDC received (credit it to idle)
    function withdraw(
        VaultBook.Book storage b,
        VaultBook.Env memory e,
        VaultBook.Protocol protocol,
        Removal memory r
    ) external returns (uint256 usdcIn) {
        VaultBook.PoolMeta memory m = _positionMeta(b, protocol, r.tokenId);
        uint256 a0;
        uint256 a1;
        if (protocol == VaultBook.Protocol.V3) {
            (address t0, address t1) = _pair(m, e.usdc);
            uint256 b0 = IERC20(t0).balanceOf(address(this));
            uint256 b1 = IERC20(t1).balanceOf(address(this));
            (uint256 r0, uint256 r1) = V3Positions.withdraw(
                b.v3, e.npm, r.tokenId, r.liquidity, r.amount0Min, r.amount1Min, r.deadline, address(this)
            );
            (a0, a1) = (_received(t0, b0, r0), _received(t1, b1, r1));
        } else {
            (uint256 f0, uint256 f1, uint256 r0, uint256 r1) = V4Positions.withdraw(
                b.v4,
                e.posm,
                e.stateView,
                r.tokenId,
                r.liquidity,
                r.amount0Min,
                r.amount1Min,
                r.deadline,
                address(this)
            );
            (a0, a1) = (f0 + r0, f1 + r1);
        }
        return _creditPair(b, m, a0, a1, b.positionPool[protocol][r.tokenId]);
    }

    /// @notice Collect a position's fees into the vault.
    /// @return usdcIn USDC received (credit it to idle)
    function harvest(
        VaultBook.Book storage b,
        VaultBook.Env memory e,
        VaultBook.Protocol protocol,
        uint256 tokenId
    ) external returns (uint256 usdcIn) {
        VaultBook.PoolMeta memory m = _positionMeta(b, protocol, tokenId);
        bytes32 poolId = b.positionPool[protocol][tokenId];
        if (protocol == VaultBook.Protocol.V3) {
            (address t0, address t1) = _pair(m, e.usdc);
            uint256 b0 = IERC20(t0).balanceOf(address(this));
            uint256 b1 = IERC20(t1).balanceOf(address(this));
            (uint256 r0, uint256 r1) = V3Positions.collectFees(b.v3, e.npm, tokenId, address(this));
            return _creditPair(b, m, _received(t0, b0, r0), _received(t1, b1, r1), poolId);
        }
        (uint256 f0, uint256 f1) =
            V4Positions.collectFees(b.v4, e.posm, e.stateView, tokenId, block.timestamp);
        return _creditPair(b, m, f0, f1, poolId);
    }

    /// @notice Burn an empty position (v3: its fees must have been collected).
    function close(
        VaultBook.Book storage b,
        VaultBook.Env memory e,
        VaultBook.Protocol protocol,
        uint256 tokenId
    ) external {
        _positionMeta(b, protocol, tokenId);
        if (protocol == VaultBook.Protocol.V3) V3Positions.close(b.v3, e.npm, tokenId);
        else V4Positions.close(b.v4, e.posm, tokenId, block.timestamp);
        delete b.positionPool[protocol][tokenId];
        emit PositionClosed(protocol, tokenId);
    }

    /// @notice One in-kind exit slice of one position, to `recipient` (the receiver, or the
    /// vault as the IOU fallback, in which case what arrived is owed to `owner`, the holder
    /// whose shares were burned, who can claim it to any address).
    /// Fees a v4 slice harvests belong to the vault and are credited.
    /// @return usdcIn USDC fees received by the vault (credit it to idle)
    function slice(
        VaultBook.Book storage b,
        VaultBook.Env memory e,
        VaultBook.Protocol protocol,
        uint256 tokenId,
        uint256 shares,
        uint256 supply,
        address owner,
        address recipient
    ) external returns (uint256 usdcIn) {
        VaultBook.PoolMeta memory m = _positionMeta(b, protocol, tokenId);
        (address t0, address t1) = _pair(m, e.usdc);
        uint256 got0;
        uint256 got1;
        if (protocol == VaultBook.Protocol.V3) {
            uint256 b0 = IERC20(t0).balanceOf(address(this));
            uint256 b1 = IERC20(t1).balanceOf(address(this));
            (got0, got1) =
                V3Positions.withdrawSlice(b.v3, e.npm, tokenId, shares, supply, recipient, block.timestamp);
            if (recipient == address(this)) {
                (got0, got1) = (_received(t0, b0, got0), _received(t1, b1, got1));
            }
        } else {
            uint256 f0;
            uint256 f1;
            (f0, f1, got0, got1) = V4Positions.withdrawSlice(
                b.v4, e.posm, e.stateView, tokenId, shares, supply, recipient, block.timestamp
            );
            usdcIn = _creditPair(b, m, f0, f1, b.positionPool[protocol][tokenId]);
        }
        if (recipient == address(this)) {
            recordOwed(b, owner, t0, got0);
            recordOwed(b, owner, t1, got1);
        }
    }

    // ---------------------------------------------------------------------
    // Swaps
    // ---------------------------------------------------------------------

    /// @notice Exact-input swap between USDC and a pool's token in that pool. USDC -> token
    /// needs a usable pool and at most `idle` USDC; `minOut` must be at least the amount
    /// at the pool's current price minus `a.maxSlippageBps`; in v3 pools the price must be
    /// within `a.maxTwapDeviation` ticks of its `a.twapWindow` TWAP.
    /// @return paid input spent (USDC: debit it from idle)
    /// @return out output received (USDC: credit it to idle)
    /// @return x the pool's class (USDC -> token only), for the allocation check
    function swap(VaultBook.Book storage b, VaultBook.Env memory e, SwapArgs memory a, uint256 idle)
        external
        returns (uint256 paid, uint256 out, Exposure memory x)
    {
        VaultBook.PoolMeta memory m;
        if (a.usdcIn) {
            (m, x.params, x.cls) = VaultBook.usablePool(b, e, a.poolId);
            if (a.amountIn > idle) revert InsufficientIdle(a.amountIn, idle);
        } else {
            m = VaultBook.meta(b, e.registry, a.poolId);
            VaultBook.requireHookless(m, a.poolId);
            _requireInventory(b, m.token, a.amountIn);
        }
        // v3 pools: the price must also be near its TWAP (hookless v4 pools have no oracle).
        if (m.protocol == VaultBook.Protocol.V3) {
            PoolOracle.requireNearTwap(m.v3Pool, a.twapWindow, a.maxTwapDeviation);
        }
        uint160 sqrtP = VaultBook.sqrtPrice(m, e.stateView, a.poolId);
        uint256 atPrice = a.usdcIn
            ? PoolPrice.usdcToToken(a.amountIn, sqrtP, m.usdcIsToken0)
            : PoolPrice.tokenToUsdc(a.amountIn, sqrtP, m.usdcIsToken0);
        uint256 floor = atPrice * (BPS - a.maxSlippageBps) / BPS;
        if (a.minOut < floor) revert MinOutTooLow(a.minOut, floor);

        if (m.protocol == VaultBook.Protocol.V3) {
            (address tokenIn, address tokenOut) = a.usdcIn ? (e.usdc, m.token) : (m.token, e.usdc);
            (paid, out) = VaultSwaps.swapV3(e.swapRouter02, tokenIn, tokenOut, m.fee, a.amountIn, a.minOut);
        } else {
            (paid, out) =
                VaultSwaps.swapV4(e.poolManager, m.v4Key, a.usdcIn == m.usdcIsToken0, a.amountIn, a.minOut);
        }
        if (a.usdcIn) {
            reserveToken(b, m.token, a.poolId);
            creditToken(b, m.token, out, a.poolId);
        } else {
            _debitToken(b, m.token, paid);
        }
    }

    // ---------------------------------------------------------------------
    // Inventory and IOUs
    // ---------------------------------------------------------------------

    /// @notice Make `token` an inventory token (priced via `poolId`) if it is not one yet.
    /// Only the keeper's acquisitions (opening a position, buying a token) call this, and
    /// they revert past MAX_TOKENS. Tokens still used by an open position are never pruned,
    /// so a position's own credits always find their slot already reserved.
    function reserveToken(VaultBook.Book storage b, address token, bytes32 poolId) public {
        if (b.tokenPool[token] != bytes32(0)) return;
        if (b.tokens.length >= MAX_TOKENS) _pruneTokens(b);
        if (b.tokens.length >= MAX_TOKENS) revert TooManyTokens();
        b.tokens.push(token);
        b.tokenPool[token] = poolId;
    }

    /// @notice Credit inventory. Never reverts: a position's token was reserved when it was
    /// opened (an unreserved one is added past the cap rather than losing the credit).
    function creditToken(VaultBook.Book storage b, address token, uint256 amount, bytes32 poolId) public {
        if (amount == 0) return;
        if (b.tokenPool[token] == bytes32(0)) {
            b.tokens.push(token);
            b.tokenPool[token] = poolId;
        }
        b.tokenBalance[token] += amount;
    }

    function recordOwed(VaultBook.Book storage b, address owner, address token, uint256 amount) public {
        if (amount == 0) return;
        b.owed[owner][token] += amount;
        b.owedTotal[token] += amount;
        emit TokenOwed(owner, token, amount);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @dev Credit a (token0, token1) pair: the token to inventory; returns the USDC part.
    function _creditPair(
        VaultBook.Book storage b,
        VaultBook.PoolMeta memory m,
        uint256 a0,
        uint256 a1,
        bytes32 poolId
    ) private returns (uint256 usdcIn) {
        uint256 tokenIn;
        (usdcIn, tokenIn) = m.usdcIsToken0 ? (a0, a1) : (a1, a0);
        creditToken(b, m.token, tokenIn, poolId);
    }

    function _debitToken(VaultBook.Book storage b, address token, uint256 amount) private {
        if (amount == 0) return;
        _requireInventory(b, token, amount);
        b.tokenBalance[token] -= amount;
    }

    function _requireInventory(VaultBook.Book storage b, address token, uint256 amount) private view {
        uint256 bal = b.tokenBalance[token];
        if (amount > bal) revert InsufficientInventory(token, amount, bal);
    }

    /// @dev Drop inventory tokens whose balance reached zero and that no open position uses.
    function _pruneTokens(VaultBook.Book storage b) private {
        address[] storage tokens = b.tokens;
        uint256 i = 0;
        while (i < tokens.length) {
            address t = tokens[i];
            if (b.tokenBalance[t] == 0 && !_usedByPosition(b, t)) {
                tokens[i] = tokens[tokens.length - 1];
                tokens.pop();
                delete b.tokenPool[t];
            } else {
                i++;
            }
        }
    }

    function _usedByPosition(VaultBook.Book storage b, address token) private view returns (bool) {
        uint256 n3 = V3Positions.count(b.v3);
        uint256 n = n3 + V4Positions.count(b.v4);
        for (uint256 i = 0; i < n; i++) {
            (VaultBook.Protocol protocol, uint256 id) = i < n3
                ? (VaultBook.Protocol.V3, V3Positions.tokenIdAt(b.v3, i))
                : (VaultBook.Protocol.V4, V4Positions.tokenIdAt(b.v4, i - n3));
            if (b.poolMeta[b.positionPool[protocol][id]].token == token) return true;
        }
        return false;
    }

    function _positionMeta(VaultBook.Book storage b, VaultBook.Protocol protocol, uint256 tokenId)
        private
        view
        returns (VaultBook.PoolMeta memory)
    {
        bytes32 poolId = b.positionPool[protocol][tokenId];
        if (poolId == bytes32(0)) revert UnknownPosition(protocol, tokenId);
        return b.poolMeta[poolId];
    }

    function _pair(VaultBook.PoolMeta memory m, address usdc) private pure returns (address, address) {
        return m.usdcIsToken0 ? (usdc, m.token) : (m.token, usdc);
    }

    function _received(address token, uint256 before, uint256 reported) private view returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(address(this));
        return Math.min(bal > before ? bal - before : 0, reported);
    }
}
