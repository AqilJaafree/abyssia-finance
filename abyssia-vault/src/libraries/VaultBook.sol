// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultRegistry} from "../registry/VaultRegistry.sol";
import {V3Positions} from "../v3/V3Positions.sol";
import {V4Positions} from "../v4/V4Positions.sol";
import {PoolPrice} from "./PoolPrice.sol";
import {INonfungiblePositionManager as INPM} from "../interfaces/INonfungiblePositionManager.sol";
import {IV4PositionManager} from "../interfaces/IV4PositionManager.sol";
import {IStateView} from "../interfaces/IStateView.sol";
import {IPermit2} from "../interfaces/IPermit2.sol";
import {IV4PoolManager} from "../interfaces/IV4PoolManager.sol";
import {ISwapRouter02} from "../interfaces/ISwapRouter02.sol";
import {IUniswapV3Pool} from "../interfaces/IUniswapV3Pool.sol";
import {PoolKey} from "../types/PoolKey.sol";

/// @title VaultBook
/// @notice The vault's position and inventory book, plus the logic that reads it:
/// pool metadata, valuation, and the checks every new exposure must pass. An EXTERNAL
/// library (delegatecalled), so it runs on the vault's storage while keeping the vault
/// under the 24 KB contract size limit.
library VaultBook {
    uint256 internal constant BPS = 10_000;
    /// @notice Hard cap on open positions across v3 AND v4 (see AbyssiaVault.MAX_POSITIONS).
    uint256 internal constant MAX_POSITIONS = 20;

    enum Protocol {
        V3,
        V4
    }

    /// @dev What the vault needs about a pool, cached from the registry on first use.
    struct PoolMeta {
        bool known;
        Protocol protocol;
        bool usdcIsToken0;
        address token;
        address v3Pool;
        uint24 fee;
        int24 tickSpacing;
        PoolKey v4Key;
    }

    struct Book {
        V3Positions.State v3;
        V4Positions.State v4;
        mapping(Protocol => mapping(uint256 tokenId => bytes32 poolId)) positionPool;
        mapping(bytes32 poolId => PoolMeta) poolMeta;
        mapping(address token => uint256) tokenBalance;
        mapping(address token => bytes32 poolId) tokenPool;
        address[] tokens;
        mapping(address receiver => mapping(address token => uint256)) owed;
        mapping(address token => uint256) owedTotal;
        /// USDC value of a pool's positions right after its last rebalance (stop-loss basis).
        mapping(bytes32 poolId => uint256) entryValue;
        mapping(bytes32 poolId => uint256) lastRebalance;
    }

    /// @dev The vault's fixed external dependencies.
    struct Env {
        VaultRegistry registry;
        INPM npm;
        IV4PositionManager posm;
        IStateView stateView;
        IPermit2 permit2;
        IV4PoolManager poolManager;
        ISwapRouter02 swapRouter02;
        address usdc;
    }

    error PoolNotUsable(bytes32 poolId);
    error HookedPoolNotAllowed(bytes32 poolId);
    error TooManyPositions();
    error TooManyRanges(bytes32 poolId);
    error WidthOutOfBounds(int24 width);
    error PoolTooThin(uint128 liquidity, uint128 minLiquidity);
    error AllocationExceeded(uint256 value, uint256 limit);

    // ---------------------------------------------------------------------
    // Pool metadata and checks
    // ---------------------------------------------------------------------

    /// @notice Registry metadata for `poolId`, cached on first use (a pool's identity
    /// never changes).
    function meta(Book storage b, VaultRegistry registry, bytes32 poolId) public returns (PoolMeta memory m) {
        m = b.poolMeta[poolId];
        if (m.known) return m;
        VaultRegistry.PoolInfo memory info = registry.getPool(poolId);
        m = PoolMeta({
            known: true,
            protocol: info.protocol == VaultRegistry.Protocol.V3 ? Protocol.V3 : Protocol.V4,
            usdcIsToken0: info.usdcIsToken0,
            token: info.token,
            v3Pool: info.v3Pool,
            fee: info.fee,
            tickSpacing: info.tickSpacing,
            v4Key: info.v4Key
        });
        b.poolMeta[poolId] = m;
    }

    /// @notice A pool new exposure may go to (a position, or tokens bought in it):
    /// registry-usable, hookless (v4), deep enough (minPoolLiquidity), and its class not
    /// frozen (some shape allowed and a non-zero allocation).
    function usablePool(Book storage b, Env memory e, bytes32 poolId)
        public
        returns (PoolMeta memory m, VaultRegistry.ClassParams memory cp, VaultRegistry.AssetClass cls)
    {
        if (!e.registry.isUsable(poolId)) {
            revert PoolNotUsable(poolId);
        }
        m = meta(b, e.registry, poolId);
        requireHookless(m, poolId);
        cls = e.registry.getPool(poolId).assetClass;
        cp = e.registry.classParams(cls);
        if (cp.allowedShapes == 0 || cp.maxAllocationBps == 0) revert PoolNotUsable(poolId);
        uint128 liq = m.protocol == Protocol.V3
            ? IUniswapV3Pool(m.v3Pool).liquidity()
            : e.stateView.getLiquidity(poolId);
        if (liq < cp.minPoolLiquidity) revert PoolTooThin(liq, cp.minPoolLiquidity);
    }

    function requireHookless(PoolMeta memory m, bytes32 poolId) internal pure {
        if (m.protocol == Protocol.V4 && m.v4Key.hooks != address(0)) revert HookedPoolNotAllowed(poolId);
    }

    /// @notice Checks for one new range in `poolId`: the pool is usable (see usablePool),
    /// the width is within the class bounds and the position caps hold.
    function checkOpen(Book storage b, Env memory e, bytes32 poolId, int24 width)
        external
        returns (PoolMeta memory m, VaultRegistry.ClassParams memory cp, VaultRegistry.AssetClass cls)
    {
        (m, cp, cls) = usablePool(b, e, poolId);
        if (width < cp.minWidthTicks || width > cp.maxWidthTicks) revert WidthOutOfBounds(width);
        if (V3Positions.count(b.v3) + V4Positions.count(b.v4) >= MAX_POSITIONS) revert TooManyPositions();
        if (_rangesIn(b, m.protocol, poolId) >= cp.maxRanges) revert TooManyRanges(poolId);
    }

    /// @notice After adding exposure to `poolId`: its value (its positions + ALL inventory
    /// of its token) must stay within maxAllocationBps of `nav`, and its class within
    /// maxClassBps. Inventory counts toward the class of the pool that prices it
    /// (`tokenPool`), so when that pool is a different one it is checked too: buying a token
    /// through a second pool can never escape the first pool's or class's limits.
    function checkAllocation(
        Book storage b,
        Env memory e,
        bytes32 poolId,
        VaultRegistry.AssetClass cls,
        VaultRegistry.ClassParams memory cp,
        uint256 nav
    ) external view {
        _checkLimits(b, e, poolId, cls, cp, nav);
        bytes32 pricing = b.tokenPool[b.poolMeta[poolId].token];
        if (pricing != bytes32(0) && pricing != poolId) {
            VaultRegistry.AssetClass pcls = e.registry.getPool(pricing).assetClass;
            _checkLimits(b, e, pricing, pcls, e.registry.classParams(pcls), nav);
        }
    }

    function _checkLimits(
        Book storage b,
        Env memory e,
        bytes32 poolId,
        VaultRegistry.AssetClass cls,
        VaultRegistry.ClassParams memory cp,
        uint256 nav
    ) private view {
        (uint256 poolValue, uint256 classValue) = _exposure(b, e, poolId, cls);
        uint256 poolLimit = nav * cp.maxAllocationBps / BPS;
        if (poolValue > poolLimit) revert AllocationExceeded(poolValue, poolLimit);
        uint256 classLimit = nav * cp.maxClassBps / BPS;
        if (classValue > classLimit) revert AllocationExceeded(classValue, classLimit);
    }

    // ---------------------------------------------------------------------
    // Valuation
    // ---------------------------------------------------------------------

    /// @notice Positions' principal + token inventory, in USDC at each pool's current price.
    /// Excludes unharvested fees and IOUs (`owed`, which is not in `tokenBalance`).
    function deployedValue(Book storage b, Env memory e) external view returns (uint256 total) {
        uint256 n3 = V3Positions.count(b.v3);
        for (uint256 i = 0; i < n3; i++) {
            total += positionValue(b, e, Protocol.V3, V3Positions.tokenIdAt(b.v3, i));
        }
        uint256 n4 = V4Positions.count(b.v4);
        for (uint256 i = 0; i < n4; i++) {
            total += positionValue(b, e, Protocol.V4, V4Positions.tokenIdAt(b.v4, i));
        }
        uint256 nt = b.tokens.length;
        for (uint256 i = 0; i < nt; i++) {
            total += tokenValue(b, e, b.tokens[i]);
        }
    }

    /// @notice USDC value of one position's principal at its pool's current price.
    function positionValue(Book storage b, Env memory e, Protocol protocol, uint256 tokenId)
        public
        view
        returns (uint256)
    {
        bytes32 poolId = b.positionPool[protocol][tokenId];
        PoolMeta memory m = b.poolMeta[poolId];
        (uint256 a0, uint256 a1) = protocol == Protocol.V3
            ? V3Positions.positionAmounts(e.npm, tokenId)
            : V4Positions.positionAmounts(e.posm, e.stateView, tokenId);
        (uint256 usdcAmt, uint256 tokenAmt) = m.usdcIsToken0 ? (a0, a1) : (a1, a0);
        return usdcAmt + PoolPrice.tokenToUsdc(tokenAmt, sqrtPrice(m, e.stateView, poolId), m.usdcIsToken0);
    }

    /// @notice USDC value of the vault's inventory of `token`, via its pricing pool.
    function tokenValue(Book storage b, Env memory e, address token) public view returns (uint256) {
        uint256 amount = b.tokenBalance[token];
        if (amount == 0) return 0;
        bytes32 poolId = b.tokenPool[token];
        PoolMeta memory m = b.poolMeta[poolId];
        return PoolPrice.tokenToUsdc(amount, sqrtPrice(m, e.stateView, poolId), m.usdcIsToken0);
    }

    /// @notice USDC value of all the vault's positions in `poolId` (principal, spot price).
    function poolPositionsValue(Book storage b, Env memory e, bytes32 poolId)
        public
        view
        returns (uint256 v)
    {
        uint256 n3 = V3Positions.count(b.v3);
        uint256 n = n3 + V4Positions.count(b.v4);
        for (uint256 i = 0; i < n; i++) {
            (Protocol protocol, uint256 id) = i < n3
                ? (Protocol.V3, V3Positions.tokenIdAt(b.v3, i))
                : (Protocol.V4, V4Positions.tokenIdAt(b.v4, i - n3));
            if (b.positionPool[protocol][id] == poolId) v += positionValue(b, e, protocol, id);
        }
    }

    function currentTick(PoolMeta memory m, IStateView stateView, bytes32 poolId)
        internal
        view
        returns (int24 tick)
    {
        if (m.protocol == Protocol.V3) (, tick,,,,,) = IUniswapV3Pool(m.v3Pool).slot0();
        else (, tick,,) = stateView.getSlot0(poolId);
    }

    function sqrtPrice(PoolMeta memory m, IStateView stateView, bytes32 poolId)
        internal
        view
        returns (uint160 sqrtP)
    {
        if (m.protocol == Protocol.V3) (sqrtP,,,,,,) = IUniswapV3Pool(m.v3Pool).slot0();
        else (sqrtP,,,) = stateView.getSlot0(poolId);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _rangesIn(Book storage b, Protocol protocol, bytes32 poolId) private view returns (uint256 n) {
        uint256 count = protocol == Protocol.V3 ? V3Positions.count(b.v3) : V4Positions.count(b.v4);
        for (uint256 i = 0; i < count; i++) {
            uint256 id =
                protocol == Protocol.V3 ? V3Positions.tokenIdAt(b.v3, i) : V4Positions.tokenIdAt(b.v4, i);
            if (b.positionPool[protocol][id] == poolId) n++;
        }
    }

    function _exposure(Book storage b, Env memory e, bytes32 poolId, VaultRegistry.AssetClass cls)
        private
        view
        returns (uint256 poolValue, uint256 classValue)
    {
        uint256 n3 = V3Positions.count(b.v3);
        uint256 n = n3 + V4Positions.count(b.v4);
        for (uint256 i = 0; i < n; i++) {
            Protocol protocol = i < n3 ? Protocol.V3 : Protocol.V4;
            uint256 id = i < n3 ? V3Positions.tokenIdAt(b.v3, i) : V4Positions.tokenIdAt(b.v4, i - n3);
            bytes32 pid = b.positionPool[protocol][id];
            uint256 v = positionValue(b, e, protocol, id);
            if (pid == poolId) poolValue += v;
            if (e.registry.getPool(pid).assetClass == cls) classValue += v;
        }
        address poolToken = b.poolMeta[poolId].token;
        uint256 nt = b.tokens.length;
        for (uint256 i = 0; i < nt; i++) {
            address t = b.tokens[i];
            uint256 v = tokenValue(b, e, t);
            if (v == 0) continue;
            if (t == poolToken) poolValue += v;
            if (e.registry.getPool(b.tokenPool[t]).assetClass == cls) classValue += v;
        }
    }
}
