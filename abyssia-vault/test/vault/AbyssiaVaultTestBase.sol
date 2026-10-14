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
import {VaultRebalance} from "../../src/libraries/VaultRebalance.sol";
import {Shapes} from "../../src/libraries/Shapes.sol";
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
        // Fixture: test pools reserve 64 observations (production default is 1,200).
        vm.prank(admin);
        vault.setMinObservations(64);
        _postReference(v4PoolId, 0);
        // Let the v3 pools' TWAP window fill (the vault's v3 swaps and rebalances need it).
        vm.warp(block.timestamp + vault.twapWindow());
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
            rebalanceCooldown: 0, // tests rebalance a pool repeatedly; the cooldown has its own test
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
        IUniswapV3Pool(pool).increaseObservationCardinalityNext(64); // room for a TWAP
        V3PositionsHarness lp = new V3PositionsHarness(INPM(v3.positionManager));
        _mint(t0, address(lp), 1e12);
        _mint(t1, address(lp), 1e12);
        lp.open(V3Positions.OpenParams(t0, t1, FEE, -FULL, FULL, 1e12, 1e12, 0, 0, block.timestamp));
        vm.prank(admin);
        poolId = registry.addV3Pool(token, FEE, MEMECOIN);
        // A pool added after setUp needs its own TWAP window to fill.
        if (address(vault) != address(0)) vm.warp(block.timestamp + vault.twapWindow());
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
        if (address(vault) != address(0)) _postReference(poolId, 0);
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

    /// @dev Settles at the live price (in tests the pool prices are the fair prices).
    function _settle() internal {
        vm.warp(block.timestamp + vault.minSettleInterval());
        uint256 price = vault.sharePrice();
        vm.prank(keeper);
        vault.settle(price);
    }

    /// @dev Deposit `assets` for `user`, settle and claim; returns the shares.
    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        _requestDeposit(user, assets);
        uint256 id = vault.currentBatchId();
        _settle();
        vm.prank(user);
        shares = vault.claimDeposit(id, user);
    }

    function _spec(uint8 shape, uint8 side, uint8 ranges, int24 width)
        internal
        pure
        returns (Shapes.Spec memory)
    {
        return Shapes.Spec(shape, side, ranges, width);
    }

    function _tick(bytes32 poolId) internal view returns (int24 tick) {
        VaultRegistry.PoolInfo memory info = registry.getPool(poolId);
        if (info.protocol == VaultRegistry.Protocol.V3) (, tick,,,,,) = IUniswapV3Pool(info.v3Pool).slot0();
        else (, tick,,) = IStateView(v4.stateView).getSlot0(poolId);
    }

    function _rebalanceArgs(bytes32 poolId, Shapes.Spec memory spec, uint256 usdcAmt, uint256 tokenAmt)
        internal
        view
        returns (VaultRebalance.Args memory)
    {
        return VaultRebalance.Args(poolId, spec, usdcAmt, tokenAmt, _tick(poolId), block.timestamp);
    }

    /// @dev Keeper rebalance of `poolId` into `spec` at the pool's current tick.
    function _rebalance(bytes32 poolId, Shapes.Spec memory spec, uint256 usdcAmt, uint256 tokenAmt) internal {
        VaultRebalance.Args memory a = _rebalanceArgs(poolId, spec, usdcAmt, tokenAmt);
        vm.prank(keeper);
        vault.rebalance(a);
    }

    /// @dev Buy the pool's token with `amount` USDC, then rebalance the pool into one Spot
    /// range of 1,200 ticks around the price holding `amount` USDC plus everything bought.
    /// Returns the new position's id (the newest in its protocol's list).
    function _openInRange(bytes32 poolId, uint256 amount) internal returns (uint256) {
        uint256 got = _keeperSwap(poolId, true, amount);
        _rebalance(poolId, _spec(Shapes.SPOT, Shapes.BOTH, 1, 1200), amount, got);
        VaultBook.Protocol p = registry.getPool(poolId).protocol == VaultRegistry.Protocol.V3 ? P3 : P4;
        (uint256 n3, uint256 n4) = vault.positionCount();
        return vault.positionAt(p, (p == P3 ? n3 : n4) - 1);
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

    /// @dev The guardian posts a v4 pool's first reference tick.
    function _postReference(bytes32 poolId, int24 tick) internal {
        vm.prank(guardian);
        vault.postReferenceTick(poolId, tick);
    }

    /// @dev The keeper walks a v4 pool's reference tick to `target`: maxTwapDeviation ticks
    /// per post, one post per twapWindow.
    function _walkReference(bytes32 poolId, int24 target) internal {
        int24 step = vault.maxTwapDeviation();
        (,, VaultBook.ReferenceTick memory r) = vault.poolState(poolId);
        int24 ref = r.tick;
        while (ref != target) {
            vm.warp(block.timestamp + vault.twapWindow());
            if (target > ref) ref = target - ref > step ? ref + step : target;
            else ref = ref - target > step ? ref - step : target;
            vm.prank(keeper);
            vault.postReferenceTick(poolId, ref);
        }
    }

    function _expectUnauthorized(address account, bytes32 role) internal {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account, role)
        );
    }
}
