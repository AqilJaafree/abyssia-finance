// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {AbyssiaVaultTestBase, IV3FactoryInit, IV3PoolInit} from "./AbyssiaVaultTestBase.sol";
import {AbyssiaVault} from "../../src/AbyssiaVault.sol";
import {AsyncBatchVault} from "../../src/AsyncBatchVault.sol";
import {VaultRegistry} from "../../src/registry/VaultRegistry.sol";
import {VaultBook} from "../../src/libraries/VaultBook.sol";
import {VaultOps} from "../../src/libraries/VaultOps.sol";
import {VaultRebalance} from "../../src/libraries/VaultRebalance.sol";
import {Shapes} from "../../src/libraries/Shapes.sol";
import {PoolOracle} from "../../src/libraries/PoolOracle.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

interface IUniswapV3PoolCap {
    function increaseObservationCardinalityNext(uint16 next) external;
}

interface IPoolManagerInitR {
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24);
}

contract AbyssiaVaultRebalanceTest is AbyssiaVaultTestBase {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 10_000e6);
    }

    // ---------------------------------------------------------------------
    // Wiring and parameters
    // ---------------------------------------------------------------------

    function test_constructorWiringAndDefaults() public view {
        assertEq(address(vault.registry()), address(registry));
        assertEq(address(vault.posm()), v4.positionManager);
        assertEq(address(vault.poolManager()), v4.poolManager);
        assertEq(address(vault.permit2()), v4.permit2);
        assertEq(vault.maxSwapSlippageBps(), 500);
        assertEq(vault.maxRebalanceTickDeviation(), 100);
        assertEq(vault.twapWindow(), 600);
        assertEq(vault.maxTwapDeviation(), 500);
    }

    function test_constructorRejectsRegistryForAnotherUsdc() public {
        AbyssiaVault.Config memory c = _config();
        c.registry = new VaultRegistry(address(meme), v3.factory, v4.stateView, admin, guardian);
        vm.expectRevert(AsyncBatchVault.ZeroAddress.selector);
        new AbyssiaVault(c);
    }

    function test_priceGuardsAdminCappedGuardianTightens() public {
        vm.startPrank(admin);
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        vault.setPriceGuards(501, 600, 500);
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        vault.setPriceGuards(100, 59, 500);
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        vault.setPriceGuards(100, 600, 2_001);
        // A 1,800 s window needs 180 observations at the fixture's 10 s blocks.
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        vault.setPriceGuards(200, 1_800, 1_000);
        vault.setMinObservations(180);
        vault.setPriceGuards(200, 1_800, 1_000);
        vm.stopPrank();
        vm.startPrank(guardian);
        vault.tightenPriceGuards(50, 300);
        vm.expectRevert(AsyncBatchVault.NotLower.selector);
        vault.tightenPriceGuards(60, 300);
        vm.stopPrank();
        assertEq(vault.maxRebalanceTickDeviation(), 50);
        assertEq(vault.maxTwapDeviation(), 300);
        assertEq(vault.twapWindow(), 1_800);
    }

    // ---------------------------------------------------------------------
    // Rebalancing
    // ---------------------------------------------------------------------

    /// A USDC-only bid in each protocol: idle USDC is debited by what was spent, NAV is
    /// conserved, and the entry value is recorded.
    function test_rebalanceUsdcOnlyBidBothProtocols() public {
        uint256 nav = vault.totalAssets();
        _rebalance(v3PoolId, _spec(Shapes.SPOT, Shapes.USDC_ONLY, 4, 120), 1_000e6, 0);
        _rebalance(v4PoolId, _spec(Shapes.CURVE, Shapes.USDC_ONLY, 5, 60), 1_000e6, 0);
        (uint256 n3, uint256 n4) = vault.positionCount();
        assertEq(n3, 4);
        assertEq(n4, 5);
        assertApproxEqAbs(vault.idleAssets(), 8_000e6, 10);
        assertApproxEqAbs(vault.totalAssets(), nav, 10);
        (uint160 entry, uint256 last,) = vault.poolState(v4PoolId);
        assertEq(entry, TickMath.getSqrtPriceAtTick(0)); // the pool's price at the rebalance
        assertEq(last, block.timestamp);
    }

    /// A second rebalance replaces the pool's ranges (old NFTs burned, value conserved).
    function test_rebalanceReplacesThePoolsRanges() public {
        _rebalance(v4PoolId, _spec(Shapes.BIDASK, Shapes.USDC_ONLY, 6, 60), 1_000e6, 0);
        uint256 oldId = vault.positionAt(P4, 0);
        uint256 nav = vault.totalAssets();
        _rebalance(v4PoolId, _spec(Shapes.SPOT, Shapes.USDC_ONLY, 2, 600), 2_000e6, 0);
        (, uint256 n4) = vault.positionCount();
        assertEq(n4, 2);
        assertEq(vault.positionPool(P4, oldId), bytes32(0));
        assertApproxEqAbs(vault.totalAssets(), nav, 20);
        assertApproxEqAbs(vault.idleAssets(), 8_000e6, 20);
    }

    /// Both sides: a Curve over 5 ranges around the price, from USDC and bought tokens.
    function test_rebalanceBothSidesCurve() public {
        uint256 got = _keeperSwap(v4PoolId, true, 1_000e6);
        _rebalance(v4PoolId, _spec(Shapes.CURVE, Shapes.BOTH, 5, 120), 1_000e6, got);
        (, uint256 n4) = vault.positionCount();
        assertEq(n4, 5);
        // Only the range containing the price takes both tokens (in the pool's ratio), so
        // some of one side can stay in inventory, where it still counts toward NAV.
        assertLt(vault.tokenBalance(address(meme)), got / 4);
        assertApproxEqRel(vault.totalAssets(), 10_000e6, 0.01e18);
    }

    function test_rebalanceRequiresKeeperAndUnpaused() public {
        VaultRebalance.Args memory a =
            _rebalanceArgs(v3PoolId, _spec(Shapes.SPOT, Shapes.USDC_ONLY, 1, 60), 1e6, 0);
        _expectUnauthorized(alice, vault.KEEPER_ROLE());
        vm.prank(alice);
        vault.rebalance(a);
        vm.prank(guardian);
        vault.pause();
        vm.prank(keeper);
        vm.expectRevert();
        vault.rebalance(a);
    }

    function test_rebalanceRejectsShapeTheClassForbids() public {
        vm.prank(guardian);
        registry.guardianDisableShapes(MEMECOIN, Shapes.CURVE);
        VaultRebalance.Args memory a =
            _rebalanceArgs(v4PoolId, _spec(Shapes.CURVE, Shapes.USDC_ONLY, 2, 60), 1e6, 0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(VaultRebalance.ShapeNotAllowed.selector, Shapes.CURVE));
        vault.rebalance(a);
    }

    function test_rebalanceRejectsFrozenOrDisabledPool() public {
        VaultRebalance.Args memory a =
            _rebalanceArgs(v4PoolId, _spec(Shapes.SPOT, Shapes.USDC_ONLY, 1, 60), 1e6, 0);
        vm.prank(guardian);
        registry.disablePool(v4PoolId);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(VaultBook.PoolNotUsable.selector, v4PoolId));
        vault.rebalance(a);
    }

    /// Hookless only: even an allowlisted hook's pool is refused by the vault.
    function test_rebalanceRejectsHookedV4Pool() public {
        address hook = address(uint160(1 << 20)); // low 14 bits (permission flags) all clear
        vm.prank(admin);
        registry.setHookAllowed(hook, true);
        MockERC20 other = new MockERC20("Other", "OTH");
        (address c0, address c1) = _sorted(address(other));
        PoolKey memory key = PoolKey(c0, c1, 0x800000, SPACING, hook);
        IPoolManagerInitR(v4.poolManager).initialize(key, TickMath.getSqrtPriceAtTick(0));
        vm.prank(admin);
        bytes32 poolId = registry.addV4Pool(key, MEMECOIN);
        VaultRebalance.Args memory a =
            _rebalanceArgs(poolId, _spec(Shapes.SPOT, Shapes.USDC_ONLY, 1, 60), 1e6, 0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(VaultBook.HookedPoolNotAllowed.selector, poolId));
        vault.rebalance(a);
    }

    function test_rebalanceRejectsTooManyRangesAndBadWidth() public {
        VaultRebalance.Args memory a =
            _rebalanceArgs(v4PoolId, _spec(Shapes.SPOT, Shapes.USDC_ONLY, 11, 60), 11e6, 0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(VaultBook.TooManyRanges.selector, v4PoolId));
        vault.rebalance(a);
        a.spec = _spec(Shapes.SPOT, Shapes.USDC_ONLY, 1, 120_060); // > maxWidthTicks
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(VaultBook.WidthOutOfBounds.selector, int24(120_060)));
        vault.rebalance(a);
    }

    /// One position cap across v3 AND v4.
    function test_rebalanceRespectsMaxPositionsAcrossProtocols() public {
        _rebalance(v3PoolId, _spec(Shapes.SPOT, Shapes.USDC_ONLY, 10, 60), 100e6, 0);
        _rebalance(v4PoolId, _spec(Shapes.SPOT, Shapes.USDC_ONLY, 10, 60), 100e6, 0);
        (, bytes32 extra) = _addV3Pool(address(new MockERC20("Extra", "EXT")));
        VaultRebalance.Args memory a =
            _rebalanceArgs(extra, _spec(Shapes.SPOT, Shapes.USDC_ONLY, 1, 60), 10e6, 0);
        vm.prank(keeper);
        vm.expectRevert(VaultBook.TooManyPositions.selector);
        vault.rebalance(a);
    }

    function test_rebalanceRespectsCooldown() public {
        VaultRegistry.ClassParams memory p = _classParams();
        p.rebalanceCooldown = 1 hours;
        vm.prank(admin);
        registry.setClassParams(MEMECOIN, p);
        _rebalance(v4PoolId, _spec(Shapes.SPOT, Shapes.USDC_ONLY, 1, 60), 100e6, 0);
        uint256 until = block.timestamp + 1 hours;
        VaultRebalance.Args memory a =
            _rebalanceArgs(v4PoolId, _spec(Shapes.SPOT, Shapes.USDC_ONLY, 1, 60), 100e6, 0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(VaultRebalance.CooldownActive.selector, until));
        vault.rebalance(a);
        vm.warp(until);
        _rebalance(v4PoolId, _spec(Shapes.SPOT, Shapes.USDC_ONLY, 1, 60), 100e6, 0);
    }

    /// maxAllocationBps / maxClassBps = 30% of NAV (10,000 USDC).
    function test_rebalanceRespectsAllocation() public {
        VaultRebalance.Args memory a =
            _rebalanceArgs(v3PoolId, _spec(Shapes.SPOT, Shapes.USDC_ONLY, 2, 60), 3_100e6, 0);
        vm.prank(keeper);
        vm.expectPartialRevert(VaultBook.AllocationExceeded.selector);
        vault.rebalance(a);
    }

    function test_rebalanceCannotSpendPendingDepositsOrUnheldTokens() public {
        _requestDeposit(bob, 50_000e6);
        VaultRebalance.Args memory a =
            _rebalanceArgs(v4PoolId, _spec(Shapes.SPOT, Shapes.USDC_ONLY, 1, 60), 10_001e6, 0);
        vm.prank(keeper);
        vm.expectPartialRevert(VaultOps.InsufficientIdle.selector);
        vault.rebalance(a);
        a = _rebalanceArgs(v4PoolId, _spec(Shapes.SPOT, Shapes.TOKEN_ONLY, 1, 60), 0, 1e18);
        vm.prank(keeper);
        vm.expectPartialRevert(VaultOps.InsufficientInventory.selector);
        vault.rebalance(a);
    }

    // ---------------------------------------------------------------------
    // Price guards
    // ---------------------------------------------------------------------

    function test_rebalanceRejectsTickAwayFromExpected() public {
        VaultRebalance.Args memory a =
            _rebalanceArgs(v4PoolId, _spec(Shapes.SPOT, Shapes.USDC_ONLY, 1, 60), 1e6, 0);
        a.expectedTick = _tick(v4PoolId) + 101;
        vm.prank(keeper);
        vm.expectPartialRevert(VaultRebalance.TickNotAsExpected.selector);
        vault.rebalance(a);
    }

    /// A v3 pool pushed far from its TWAP: the keeper can neither rebalance nor swap there.
    function test_v3ActionsRequireSpotNearTwap() public {
        _traderSwapV3(address(usdc), 200_000e6); // ~ +40% spot move, TWAP barely moved
        VaultRebalance.Args memory a =
            _rebalanceArgs(v3PoolId, _spec(Shapes.SPOT, Shapes.USDC_ONLY, 1, 60), 1e6, 0);
        vm.prank(keeper);
        vm.expectPartialRevert(VaultBook.PriceOffReference.selector);
        vault.rebalance(a);
        uint256 minOut = _floor(v3PoolId, true, 1e6);
        vm.prank(keeper);
        vm.expectPartialRevert(VaultBook.PriceOffReference.selector);
        vault.swap(v3PoolId, true, 1e6, minOut);
    }

    /// A v3 pool whose observations don't cover the window: fail closed with a clear error.
    function test_v3TwapUnavailableFailsClosed() public {
        MockERC20 fresh = new MockERC20("Fresh", "FRS");
        (address t0, address t1) = _sorted(address(fresh));
        address pool = IV3FactoryInit(v3.factory).createPool(t0, t1, FEE);
        IV3PoolInit(pool).initialize(TickMath.getSqrtPriceAtTick(0));
        IUniswapV3PoolCap(pool).increaseObservationCardinalityNext(64); // capacity is fine, history isn't
        vm.prank(admin);
        bytes32 poolId = registry.addV3Pool(address(fresh), FEE, MEMECOIN);
        VaultRegistry.ClassParams memory p = _classParams();
        p.minPoolLiquidity = 0; // the fresh pool has no liquidity
        vm.prank(admin);
        registry.setClassParams(MEMECOIN, p);
        VaultRebalance.Args memory a =
            _rebalanceArgs(poolId, _spec(Shapes.SPOT, Shapes.USDC_ONLY, 1, 60), 1e6, 0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(PoolOracle.TwapUnavailable.selector, pool, uint32(600)));
        vault.rebalance(a);
    }

    /// A v3 pool that keeps too few observations could have its TWAP wiped by a swap every
    /// block: the vault refuses to rely on it.
    function test_v3ObservationCapacityFloor() public {
        vm.prank(admin);
        vault.setMinObservations(1_200);
        VaultRebalance.Args memory a =
            _rebalanceArgs(v3PoolId, _spec(Shapes.SPOT, Shapes.USDC_ONLY, 1, 60), 1e6, 0);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(PoolOracle.ObservationCapacityTooLow.selector, v3Pool, 64, 1_200)
        );
        vault.rebalance(a);
        IUniswapV3PoolCap(v3Pool).increaseObservationCardinalityNext(1_200);
        vm.prank(keeper);
        vault.rebalance(a);
        assertEq(vault.minObservations(), 1_200);
        vm.prank(admin);
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        vault.setMinObservations(0);
    }

    /// The observation floor must cover the TWAP window at the chain's block time (here 10 s
    /// blocks: 60 observations per 600 s), so a long window can't rest on a short ring.
    function test_observationFloorCoversTheWindow() public {
        assertEq(vault.blockTimeMs(), 10_000);
        vm.startPrank(admin);
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        vault.setMinObservations(59);
        vault.setMinObservations(60);
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        vault.setPriceGuards(100, 601, 500);
        vm.stopPrank();
        AbyssiaVault.Config memory c = _config();
        c.blockTimeMs = 499; // the default 1,200 observations would not cover 600 s
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        new AbyssiaVault(c);
    }

    /// A BOTH layout from USDC only skips the range containing the price (it would take zero
    /// liquidity) instead of reverting.
    function test_bothFromUsdcOnlySkipsTheMiddleRange() public {
        _rebalance(v4PoolId, _spec(Shapes.SPOT, Shapes.BOTH, 3, 120), 900e6, 0);
        (, uint256 n4) = vault.positionCount();
        assertEq(n4, 1); // only the range on USDC's side
        // USDC splits evenly between the middle range and the USDC-side range; the middle
        // share stays idle.
        assertApproxEqAbs(vault.idleAssets(), 9_550e6, 2);
    }

    /// tokenAmount = max deploys all of the token, including what the unwind returned.
    function test_tokenAmountMaxUsesAllInventory() public {
        uint256 got = _keeperSwap(v4PoolId, true, 1_000e6);
        _rebalance(v4PoolId, _spec(Shapes.SPOT, Shapes.TOKEN_ONLY, 2, 600), 0, got);
        _rebalance(v4PoolId, _spec(Shapes.SPOT, Shapes.TOKEN_ONLY, 3, 600), 0, type(uint256).max);
        assertLt(vault.tokenBalance(address(meme)), 10); // only rounding dust left
    }

    // ---------------------------------------------------------------------
    // Stop-loss
    // ---------------------------------------------------------------------

    function test_stopLossOnlyAfterTheLossThreshold() public {
        uint256 got = _keeperSwap(v4PoolId, true, 1_000e6);
        _rebalance(v4PoolId, _spec(Shapes.SPOT, Shapes.TOKEN_ONLY, 3, 600), 0, got);
        vm.prank(keeper);
        vm.expectPartialRevert(VaultRebalance.StopLossNotReached.selector);
        vault.stopLoss(v4PoolId);

        // The token crashes: the ask's value falls by more than the class's 30%, but the
        // stop-loss values it at the reference tick, which has to follow first.
        _traderSwapV4(address(meme), 600_000e6);
        vm.prank(keeper);
        vm.expectPartialRevert(VaultRebalance.StopLossNotReached.selector);
        vault.stopLoss(v4PoolId);
        _walkReference(v4PoolId, _tick(v4PoolId));
        uint256 memeBefore = vault.tokenBalance(address(meme));
        vm.prank(guardian);
        vault.stopLoss(v4PoolId);
        (, uint256 n4) = vault.positionCount();
        assertEq(n4, 0);
        // The liquidity is back in the vault as inventory (no forced swap).
        assertGt(vault.tokenBalance(address(meme)), memeBefore + got / 2);
        (uint160 entry,,) = vault.poolState(v4PoolId);
        assertEq(entry, 0);
    }

    function test_stopLossAccessAndNoEntry() public {
        _expectUnauthorized(alice, vault.KEEPER_ROLE());
        vm.prank(alice);
        vault.stopLoss(v4PoolId);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(VaultRebalance.NoEntryValue.selector, v4PoolId));
        vault.stopLoss(v4PoolId);
    }

    // ---------------------------------------------------------------------
    // Position maintenance
    // ---------------------------------------------------------------------

    /// Withdrawing credits USDC to idle and the token to inventory, at Uniswap's amounts;
    /// collecting fees does the same with the fees; empty positions can be closed.
    function test_withdrawCollectAndClose() public {
        uint256 id3 = _openInRange(v3PoolId, 500e6);
        uint256 id4 = _openInRange(v4PoolId, 500e6);
        _traderSwapV3(address(meme), 2_000e6);
        _traderSwapV4(address(meme), 2_000e6);
        uint256 idleBefore = vault.idleAssets();
        uint256 memeBefore = vault.tokenBalance(address(meme));
        uint128 liq3 = _liq3(id3);
        uint128 liq4 = vault.posm().getPositionLiquidity(id4);
        vm.startPrank(keeper);
        vault.collectPositionFees(P3, id3);
        assertGt(vault.tokenBalance(address(meme)), memeBefore, "v3 fees in MEME");
        vault.withdrawPosition(P3, VaultOps.Removal(id3, liq3, 0, 0, block.timestamp));
        vault.withdrawPosition(P4, VaultOps.Removal(id4, liq4, 0, 0, block.timestamp));
        vault.closePosition(P3, id3);
        vault.closePosition(P4, id4);
        vm.stopPrank();
        assertGt(vault.idleAssets(), idleBefore);
        assertEq(meme.balanceOf(address(vault)), vault.tokenBalance(address(meme)));
        (uint256 n3, uint256 n4) = vault.positionCount();
        assertEq(n3 + n4, 0);
    }

    /// Risk-reducing keeper actions keep working while paused.
    function test_withdrawAllowedWhilePaused() public {
        uint256 id = _openInRange(v4PoolId, 500e6);
        vm.prank(guardian);
        vault.pause();
        uint128 liq = vault.posm().getPositionLiquidity(id);
        vm.prank(keeper);
        vault.withdrawPosition(P4, VaultOps.Removal(id, liq, 0, 0, block.timestamp));
        assertEq(vault.posm().getPositionLiquidity(id), 0);
    }

    function test_unknownPositionReverts() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(VaultOps.UnknownPosition.selector, P3, 999));
        vault.withdrawPosition(P3, VaultOps.Removal(999, 1, 0, 0, block.timestamp));
    }

    function _liq3(uint256 id) internal view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = vault.npm().positions(id);
    }
}
