// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IUniswapV3Factory} from "../interfaces/IUniswapV3Factory.sol";
import {IStateView} from "../interfaces/IStateView.sol";
import {PoolKey, PoolKeyLib} from "../types/PoolKey.sol";

/// @title VaultRegistry
/// @notice Risk configuration for one Abyssia vault: per-asset-class limits
/// (bounded by hard caps in code) and the allowlist of Uniswap v3/v4 USDC pools
/// the vault may provide liquidity to.
/// @dev DEFAULT_ADMIN_ROLE is meant to be a TimelockController (owned by a
/// 2-of-3 Safe), so every loosening change is delayed. GUARDIAN_ROLE can only
/// tighten, instantly. Allocation limits are enforced by the vault's rebalance
/// logic (a later plan); this contract stores and validates them.
contract VaultRegistry is AccessControl {
    using PoolKeyLib for PoolKey;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    enum AssetClass {
        Stable,
        Bluechip,
        Volatile,
        Memecoin
    }

    enum Protocol {
        V3,
        V4
    }

    uint8 public constant SHAPE_SPOT = 1;
    uint8 public constant SHAPE_CURVE = 2;
    uint8 public constant SHAPE_BIDASK = 4;
    uint8 public constant ALL_SHAPES = SHAPE_SPOT | SHAPE_CURVE | SHAPE_BIDASK;

    // Hard caps: the admin can never configure past these.
    uint16 public constant HARD_MAX_ALLOCATION_BPS = 5_000; // any single pool ≤ 50% of the vault
    uint8 public constant HARD_MAX_RANGES = 10;
    uint16 public constant HARD_MAX_STOP_LOSS_BPS = 9_000;
    uint32 public constant HARD_MAX_COOLDOWN = 7 days;
    int24 public constant MAX_WIDTH_TICKS = 887_272;

    struct ClassParams {
        uint16 maxAllocationBps; // max share of the vault in one pool of this class
        uint16 maxClassBps; // max share of the vault across all pools of this class
        uint8 allowedShapes; // bitmask of SHAPE_*
        uint8 maxRanges; // max positions per pool
        int24 minWidthTicks; // narrowest range allowed
        int24 maxWidthTicks; // widest range allowed
        uint16 stopLossBps; // forced-exit threshold (0 = none)
        uint32 rebalanceCooldown; // min seconds between rebalances of one pool
        uint128 minPoolLiquidity; // skip pools thinner than this
    }

    struct PoolInfo {
        Protocol protocol;
        AssetClass assetClass;
        bool enabled;
        address token; // the non-USDC side
        address v3Pool; // v3 only
        PoolKey v4Key; // v4 only
    }

    address public immutable usdc;
    IUniswapV3Factory public immutable v3Factory; // zero = v3 unsupported on this chain
    IStateView public immutable v4StateView; // zero = v4 unsupported on this chain

    mapping(AssetClass => ClassParams) internal _classParams;
    mapping(AssetClass => bool) public classConfigured;
    mapping(bytes32 poolId => PoolInfo) internal _pools;
    bytes32[] internal _poolIds;
    mapping(address hook => bool) public hookAllowed;

    event ClassParamsSet(AssetClass indexed assetClass, ClassParams params);
    event PoolAdded(bytes32 indexed poolId, Protocol protocol, AssetClass assetClass, address token);
    event PoolClassSet(bytes32 indexed poolId, AssetClass assetClass);
    event PoolEnabled(bytes32 indexed poolId, bool enabled);
    event HookAllowed(address indexed hook, bool allowed);

    error ZeroAddress();
    error ParamOutOfBounds();
    error ClassNotConfigured(AssetClass assetClass);
    error NotTighter();
    error ProtocolUnsupported();
    error InvalidToken();
    error InvalidPoolKey();
    error NativeCurrencyNotAllowed();
    error NotUsdcPair();
    error HookNotAllowed(address hook);
    error PoolNotFound();
    error PoolAlreadyAdded(bytes32 poolId);
    error UnknownPool(bytes32 poolId);
    error Unauthorized();

    constructor(address usdc_, address v3Factory_, address v4StateView_, address admin, address guardian) {
        if (usdc_ == address(0) || admin == address(0) || guardian == address(0)) revert ZeroAddress();
        usdc = usdc_;
        v3Factory = IUniswapV3Factory(v3Factory_);
        v4StateView = IStateView(v4StateView_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    // ---------------------------------------------------------------------
    // Asset-class parameters
    // ---------------------------------------------------------------------

    /// @notice Per-class ceiling on maxClassBps: riskier classes can never take the whole vault.
    function hardMaxClassBps(AssetClass c) public pure returns (uint16) {
        if (c == AssetClass.Memecoin) return 3_000;
        if (c == AssetClass.Volatile) return 6_000;
        return 10_000;
    }

    function setClassParams(AssetClass c, ClassParams calldata p) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _validate(c, p);
        _classParams[c] = p;
        classConfigured[c] = true;
        emit ClassParamsSet(c, p);
    }

    /// @notice Guardian: lower a class's allocation limits instantly.
    function guardianReduceAllocation(AssetClass c, uint16 maxAllocationBps, uint16 maxClassBps)
        external
        onlyRole(GUARDIAN_ROLE)
    {
        ClassParams storage p = _configured(c);
        if (maxAllocationBps > p.maxAllocationBps || maxClassBps > p.maxClassBps) revert NotTighter();
        if (maxAllocationBps > maxClassBps) revert ParamOutOfBounds();
        p.maxAllocationBps = maxAllocationBps;
        p.maxClassBps = maxClassBps;
        emit ClassParamsSet(c, p);
    }

    /// @notice Guardian: forbid shapes for a class instantly (disabling all = no new positions).
    function guardianDisableShapes(AssetClass c, uint8 mask) external onlyRole(GUARDIAN_ROLE) {
        ClassParams storage p = _configured(c);
        p.allowedShapes &= ~mask;
        emit ClassParamsSet(c, p);
    }

    function classParams(AssetClass c) external view returns (ClassParams memory) {
        return _classParams[c];
    }

    function _validate(AssetClass c, ClassParams calldata p) private pure {
        if (
            p.maxAllocationBps == 0 || p.maxAllocationBps > HARD_MAX_ALLOCATION_BPS
                || p.maxAllocationBps > p.maxClassBps || p.maxClassBps > hardMaxClassBps(c)
                || p.allowedShapes == 0 || (p.allowedShapes & ~ALL_SHAPES) != 0 || p.maxRanges == 0
                || p.maxRanges > HARD_MAX_RANGES || p.minWidthTicks <= 0 || p.minWidthTicks > p.maxWidthTicks
                || p.maxWidthTicks > MAX_WIDTH_TICKS || p.stopLossBps > HARD_MAX_STOP_LOSS_BPS
                || p.rebalanceCooldown > HARD_MAX_COOLDOWN
        ) revert ParamOutOfBounds();
    }

    function _configured(AssetClass c) private view returns (ClassParams storage) {
        if (!classConfigured[c]) revert ClassNotConfigured(c);
        return _classParams[c];
    }

    // ---------------------------------------------------------------------
    // Pool allowlist
    // ---------------------------------------------------------------------

    /// @notice Allow a Uniswap v3 USDC/token pool. The pool is resolved through the
    /// canonical factory, so forks or fake pools can never be added.
    function addV3Pool(address token, uint24 fee, AssetClass c)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (bytes32 poolId)
    {
        if (address(v3Factory) == address(0)) revert ProtocolUnsupported();
        if (token == address(0) || token == usdc) revert InvalidToken();
        _configured(c);
        (address t0, address t1) = token < usdc ? (token, usdc) : (usdc, token);
        address pool = v3Factory.getPool(t0, t1, fee);
        if (pool == address(0)) revert PoolNotFound();
        poolId = bytes32(uint256(uint160(pool)));
        PoolKey memory emptyKey;
        _addPool(poolId, PoolInfo(Protocol.V3, c, true, token, pool, emptyKey));
    }

    /// @notice Allow a Uniswap v4 USDC/token pool. Native currency is rejected (Arc's
    /// 18-decimal USDC representation), and so are hooks that aren't explicitly allowed.
    function addV4Pool(PoolKey calldata key, AssetClass c)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (bytes32 poolId)
    {
        if (address(v4StateView) == address(0)) revert ProtocolUnsupported();
        if (key.currency0 == address(0)) revert NativeCurrencyNotAllowed();
        if (key.currency0 >= key.currency1) revert InvalidPoolKey();
        if (key.currency0 != usdc && key.currency1 != usdc) revert NotUsdcPair();
        if (key.hooks != address(0) && !hookAllowed[key.hooks]) revert HookNotAllowed(key.hooks);
        _configured(c);
        PoolKey memory k = key;
        poolId = k.toId();
        (uint160 sqrtPriceX96,,,) = v4StateView.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolNotFound();
        address token = key.currency0 == usdc ? key.currency1 : key.currency0;
        _addPool(poolId, PoolInfo(Protocol.V4, c, true, token, address(0), k));
    }

    function setHookAllowed(address hook, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (hook == address(0)) revert ZeroAddress();
        hookAllowed[hook] = allowed;
        emit HookAllowed(hook, allowed);
    }

    /// @notice Reclassify a pool (admin, timelocked: moving a pool to a looser class is a loosening).
    function setPoolClass(bytes32 poolId, AssetClass c) external onlyRole(DEFAULT_ADMIN_ROLE) {
        PoolInfo storage info = _known(poolId);
        _configured(c);
        info.assetClass = c;
        emit PoolClassSet(poolId, c);
    }

    /// @notice Stop new liquidity going to a pool. Guardian (instant) or admin.
    function disablePool(bytes32 poolId) external {
        if (!hasRole(GUARDIAN_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert Unauthorized();
        }
        _known(poolId).enabled = false;
        emit PoolEnabled(poolId, false);
    }

    function enablePool(bytes32 poolId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _known(poolId).enabled = true;
        emit PoolEnabled(poolId, true);
    }

    function poolCount() external view returns (uint256) {
        return _poolIds.length;
    }

    function poolIdAt(uint256 i) external view returns (bytes32) {
        return _poolIds[i];
    }

    function getPool(bytes32 poolId) external view returns (PoolInfo memory) {
        return _known(poolId);
    }

    function isEnabled(bytes32 poolId) external view returns (bool) {
        return _pools[poolId].enabled;
    }

    function _addPool(bytes32 poolId, PoolInfo memory info) private {
        if (_pools[poolId].token != address(0)) revert PoolAlreadyAdded(poolId);
        _pools[poolId] = info;
        _poolIds.push(poolId);
        emit PoolAdded(poolId, info.protocol, info.assetClass, info.token);
    }

    function _known(bytes32 poolId) private view returns (PoolInfo storage info) {
        info = _pools[poolId];
        if (info.token == address(0)) revert UnknownPool(poolId);
    }
}
