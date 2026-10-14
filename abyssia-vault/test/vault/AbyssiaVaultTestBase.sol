// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {DeployUniswapV3} from "../../script/DeployUniswapV3.s.sol";
import {V4Deployer} from "../v4/V4Deployer.sol";
import {V4SwapHelper, IPoolManagerTest} from "../v4/V4SwapHelper.sol";
import {V3PositionsHarness} from "../v3/V3PositionsHarness.sol";
import {V4PositionsHarness} from "../v4/V4PositionsHarness.sol";
import {AbyssiaVault} from "../../src/AbyssiaVault.sol";
import {VaultRegistry} from "../../src/registry/VaultRegistry.sol";
import {VaultBook} from "../../src/libraries/VaultBook.sol";
import {VaultOps} from "../../src/libraries/VaultOps.sol";
import {V3Positions} from "../../src/v3/V3Positions.sol";
import {V4Positions} from "../../src/v4/V4Positions.sol";
import {INonfungiblePositionManager as INPM} from "../../src/interfaces/INonfungiblePositionManager.sol";
import {IV4PositionManager} from "../../src/interfaces/IV4PositionManager.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";
import {IStateView} from "../../src/interfaces/IStateView.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
import {PoolKey, PoolKeyLib} from "../../src/types/PoolKey.sol";
import {PoolPrice} from "../../src/libraries/PoolPrice.sol";
import {IUniswapV3Pool} from "../../src/interfaces/IUniswapV3Pool.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

interface IV3FactoryInit {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

interface IV3PoolInit {
    function initialize(uint160 sqrtPriceX96) external;
}

/// @dev Full local stack: Uniswap's official v3 and v4 bytecode, a registry with a
/// configured memecoin class, one USDC/MEME pool on each protocol (both at tick 0, with
/// deep full-range background liquidity from an outside LP), and the vault.
abstract contract AbyssiaVaultTestBase is V4Deployer {
    using PoolKeyLib for PoolKey;

    uint24 internal constant FEE = 3000;
    int24 internal constant SPACING = 60;
    int24 internal constant FULL = 887_220;
    VaultRegistry.AssetClass internal constant MEMECOIN = VaultRegistry.AssetClass.Memecoin;
    VaultBook.Protocol internal constant P3 = VaultBook.Protocol.V3;
    VaultBook.Protocol internal constant P4 = VaultBook.Protocol.V4;

    DeployUniswapV3.Deployed internal v3;
    V4 internal v4;
    MockUSDC internal usdc;
    MockERC20 internal meme;
    VaultRegistry internal registry;
    AbyssiaVault internal vault;
    V4SwapHelper internal swapper;

    address internal v3Pool;
    bytes32 internal v3PoolId;
    PoolKey internal v4Key;
    bytes32 internal v4PoolId;

    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal trader = makeAddr("trader");

    function setUp() public virtual {
        v3 = new DeployUniswapV3().deployAll();
        v4 = _deployV4();
        swapper = new V4SwapHelper(IPoolManagerTest(v4.poolManager));
        usdc = new MockUSDC(6);
        meme = new MockERC20("Meme", "MEME");
        registry = new VaultRegistry(address(usdc), v3.factory, v4.stateView, admin, guardian);
        vm.prank(admin);
        registry.setClassParams(MEMECOIN, _classParams());
        (v3Pool, v3PoolId) = _addV3Pool(address(meme));
        (v4Key, v4PoolId) = _addV4Pool(address(meme));
        vault = new AbyssiaVault(_config());
    }

    /// @dev Test fixture class params (not a production setting).
    function _classParams() internal pure virtual returns (VaultRegistry.ClassParams memory) {
        return VaultRegistry.ClassParams({
            maxAllocationBps: 3_000,
            maxClassBps: 3_000,
            allowedShapes: 7,
            maxRanges: 10,
            minWidthTicks: 60,
            maxWidthTicks: 120_000,
            stopLossBps: 3_000,
            rebalanceCooldown: 10 minutes,
            minPoolLiquidity: 1e9
        });
    }

    function _config() internal view returns (AbyssiaVault.Config memory) {
        return AbyssiaVault.Config({
            usdc: usdc,
            name: "Abyssia Memecoin Vault",
            symbol: "abMEME",
            admin: admin,
            keeper: keeper,
            guardian: guardian,
            minDeposit: 1e6,
            maxTotalAssets: 1_000_000e6,
            maxCycleMoveBps: 2_000,
            maxSwapSlippageBps: 500,
            registry: registry,
            npm: INPM(v3.positionManager),
            swapRouter02: ISwapRouter02(v3.swapRouter02),
            posm: IV4PositionManager(v4.positionManager),
            stateView: IStateView(v4.stateView)
        });
    }

    // ---------------------------------------------------------------------
    // Pools
    // ---------------------------------------------------------------------

    /// @dev Create a v3 USDC/`token` pool at tick 0 with deep full-range outside liquidity,
    /// and allowlist it.
    function _addV3Pool(address token) internal returns (address pool, bytes32 poolId) {
        (address t0, address t1) = _sorted(token);
        pool = IV3FactoryInit(v3.factory).createPool(t0, t1, FEE);
        IV3PoolInit(pool).initialize(TickMath.getSqrtPriceAtTick(0));
        V3PositionsHarness lp = new V3PositionsHarness(INPM(v3.positionManager));
        _mint(t0, address(lp), 1e12);
        _mint(t1, address(lp), 1e12);
        lp.open(V3Positions.OpenParams(t0, t1, FEE, -FULL, FULL, 1e12, 1e12, 0, 0, block.timestamp));
        vm.prank(admin);
        poolId = registry.addV3Pool(token, FEE, MEMECOIN);
    }

    /// @dev Same for a hookless v4 pool.
    function _addV4Pool(address token) internal returns (PoolKey memory key, bytes32 poolId) {
        key = _initV4(token, address(0));
        V4PositionsHarness lp = new V4PositionsHarness(
            IV4PositionManager(v4.positionManager), IPermit2(v4.permit2), IStateView(v4.stateView)
        );
        _mint(key.currency0, address(lp), 1e12);
        _mint(key.currency1, address(lp), 1e12);
        lp.open(V4Positions.OpenParams(key, -FULL, FULL, 1e12, 1e12, 0, 0, block.timestamp));
        vm.prank(admin);
        poolId = registry.addV4Pool(key, MEMECOIN);
    }

    function _initV4(address token, address hooks) internal returns (PoolKey memory key) {
        (address c0, address c1) = _sorted(token);
        key = PoolKey(c0, c1, FEE, SPACING, hooks);
        IPoolManagerTest(v4.poolManager).initialize(key, TickMath.getSqrtPriceAtTick(0));
    }

    function _sorted(address token) internal view returns (address, address) {
        return address(usdc) < token ? (address(usdc), token) : (token, address(usdc));
    }

    // ---------------------------------------------------------------------
    // Users and keeper
    // ---------------------------------------------------------------------

    function _mint(address token, address to, uint256 amount) internal {
        MockERC20(token).mint(to, amount);
    }

    function _requestDeposit(address user, uint256 assets) internal {
        usdc.mint(user, assets);
        vm.startPrank(user);
        usdc.approve(address(vault), assets);
        vault.requestDeposit(assets);
        vm.stopPrank();
    }

    function _settle() internal {
        vm.prank(keeper);
        vault.settle();
    }

    /// @dev Deposit `assets` for `user`, settle and claim; returns the shares.
    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        _requestDeposit(user, assets);
        uint256 id = vault.currentBatchId();
        _settle();
        vm.prank(user);
        shares = vault.claimDeposit(id, user);
    }

    function _openArgs(bytes32 poolId, int24 lower, int24 upper, uint256 usdcAmt, uint256 tokenAmt)
        internal
        view
        returns (VaultOps.OpenArgs memory)
    {
        return VaultOps.OpenArgs(poolId, lower, upper, usdcAmt, tokenAmt, 0, 0, block.timestamp);
    }

    function _open(bytes32 poolId, int24 lower, int24 upper, uint256 usdcAmt, uint256 tokenAmt)
        internal
        returns (uint256 tokenId)
    {
        vm.prank(keeper);
        tokenId = vault.openPosition(_openArgs(poolId, lower, upper, usdcAmt, tokenAmt));
    }

    /// @dev Buy MEME-side tokens with `amount` USDC through the pool, then open an in-range
    /// position (-600..600) with `amount` USDC plus everything bought.
    function _openInRange(bytes32 poolId, uint256 amount) internal returns (uint256) {
        uint256 got = _keeperSwap(poolId, true, amount);
        return _open(poolId, -600, 600, amount, got);
    }

    /// @dev Keeper swap of `amountIn` with the loosest minOut the vault accepts.
    function _keeperSwap(bytes32 poolId, bool usdcIn, uint256 amountIn) internal returns (uint256 out) {
        uint256 minOut = _floor(poolId, usdcIn, amountIn);
        vm.prank(keeper);
        out = vault.swap(poolId, usdcIn, amountIn, minOut);
    }

    /// @dev The vault's minOut floor: the amount at the pool's current price, minus
    /// maxSwapSlippageBps (same formula as VaultOps.swap).
    function _floor(bytes32 poolId, bool usdcIn, uint256 amountIn) internal view returns (uint256) {
        VaultRegistry.PoolInfo memory info = registry.getPool(poolId);
        uint160 sqrtP;
        if (info.protocol == VaultRegistry.Protocol.V3) (sqrtP,,,,,,) = IUniswapV3Pool(info.v3Pool).slot0();
        else (sqrtP,,,) = IStateView(v4.stateView).getSlot0(poolId);
        uint256 atPrice = usdcIn
            ? PoolPrice.usdcToToken(amountIn, sqrtP, info.usdcIsToken0)
            : PoolPrice.tokenToUsdc(amountIn, sqrtP, info.usdcIsToken0);
        return atPrice * (10_000 - vault.maxSwapSlippageBps()) / 10_000;
    }

    // ---------------------------------------------------------------------
    // Outside traders (generate fees / move prices)
    // ---------------------------------------------------------------------

    function _traderSwapV3(address tokenIn, uint256 amountIn) internal {
        address tokenOut = tokenIn == address(usdc) ? address(meme) : address(usdc);
        _mint(tokenIn, trader, amountIn);
        vm.startPrank(trader);
        MockERC20(tokenIn).approve(v3.swapRouter02, amountIn);
        ISwapRouter02(v3.swapRouter02)
            .exactInputSingle(
                ISwapRouter02.ExactInputSingleParams(tokenIn, tokenOut, FEE, trader, amountIn, 0, 0)
            );
        vm.stopPrank();
    }

    function _traderSwapV4(address tokenIn, uint256 amountIn) internal {
        bool zeroForOne = tokenIn == v4Key.currency0;
        _mint(tokenIn, address(swapper), amountIn);
        swapper.swap(
            v4Key,
            zeroForOne,
            amountIn,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            trader
        );
    }

    function _expectUnauthorized(address account, bytes32 role) internal {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role)
        );
    }
}
