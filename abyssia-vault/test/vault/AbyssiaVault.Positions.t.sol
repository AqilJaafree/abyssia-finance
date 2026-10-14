// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AbyssiaVaultTestBase} from "./AbyssiaVaultTestBase.sol";
import {AbyssiaVault} from "../../src/AbyssiaVault.sol";
import {AsyncBatchVault} from "../../src/AsyncBatchVault.sol";
import {VaultRegistry} from "../../src/registry/VaultRegistry.sol";
import {VaultBook} from "../../src/libraries/VaultBook.sol";
import {VaultOps} from "../../src/libraries/VaultOps.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface IPoolManagerInit {
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24);
}

contract AbyssiaVaultPositionsTest is AbyssiaVaultTestBase {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 10_000e6);
    }

    function test_constructorWiring() public view {
        assertEq(address(vault.registry()), address(registry));
        assertEq(address(vault.posm()), v4.positionManager);
        assertEq(address(vault.poolManager()), v4.poolManager);
        assertEq(address(vault.permit2()), v4.permit2);
        assertEq(vault.maxSwapSlippageBps(), 500);
    }

    function test_constructorRejectsRegistryForAnotherUsdc() public {
        AbyssiaVault.Config memory c = _config();
        c.registry = new VaultRegistry(address(meme), v3.factory, v4.stateView, admin, guardian);
        vm.expectRevert(AsyncBatchVault.ZeroAddress.selector);
        new AbyssiaVault(c);
    }

    /// Opening a USDC-only range below price in each protocol: idle USDC is debited by
    /// exactly what was spent and NAV is conserved (up to rounding).
    function test_openUsdcOnlyRangeBothProtocols() public {
        uint256 nav = vault.totalAssets();
        // USDC is token0 or token1 depending on addresses; a range on USDC's side of the
        // price takes USDC only.
        (int24 lo, int24 hi) = _usdcSide();
        uint256 id3 = _open(v3PoolId, lo, hi, 1_000e6, 0);
        uint256 id4 = _open(v4PoolId, lo, hi, 1_000e6, 0);

        assertEq(vault.positionPool(P3, id3), v3PoolId);
        assertEq(vault.positionPool(P4, id4), v4PoolId);
        (uint256 n3, uint256 n4) = vault.positionCount();
        assertEq(n3 + n4, 2);
        assertApproxEqAbs(vault.idleAssets(), 8_000e6, 2);
        assertApproxEqAbs(vault.totalAssets(), nav, 4);
        assertApproxEqAbs(vault.positionValue(P3, id3), 1_000e6, 2);
        assertApproxEqAbs(vault.positionValue(P4, id4), 1_000e6, 2);
    }

    function test_openRequiresKeeper() public {
        (int24 lo, int24 hi) = _usdcSide();
        _expectUnauthorized(alice, vault.KEEPER_ROLE());
        vm.prank(alice);
        vault.openPosition(_openArgs(v3PoolId, lo, hi, 100e6, 0));
    }

    function test_openBlockedWhilePaused() public {
        vm.prank(guardian);
        vault.pause();
        (int24 lo, int24 hi) = _usdcSide();
        vm.prank(keeper);
        vm.expectRevert();
        vault.openPosition(_openArgs(v3PoolId, lo, hi, 100e6, 0));
    }

    function test_openRejectsDisabledPool() public {
        vm.prank(guardian);
        registry.disablePool(v3PoolId);
        (int24 lo, int24 hi) = _usdcSide();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(VaultBook.PoolNotUsable.selector, v3PoolId));
        vault.openPosition(_openArgs(v3PoolId, lo, hi, 100e6, 0));
    }

    function test_openRejectsFrozenClass() public {
        vm.prank(guardian);
        registry.guardianDisableShapes(MEMECOIN, 7);
        (int24 lo, int24 hi) = _usdcSide();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(VaultBook.PoolNotUsable.selector, v4PoolId));
        vault.openPosition(_openArgs(v4PoolId, lo, hi, 100e6, 0));
    }

    /// Hookless only: even an allowlisted hook's pool is refused by the vault.
    function test_openRejectsHookedV4Pool() public {
        // A hook with no permission bits is only valid on a dynamic-fee pool.
        address hook = address(uint160(1 << 20)); // low 14 bits (permission flags) all clear
        vm.prank(admin);
        registry.setHookAllowed(hook, true);
        MockERC20 other = new MockERC20("Other", "OTH");
        (address c0, address c1) = _sorted(address(other));
        PoolKey memory key = PoolKey(c0, c1, 0x800000, SPACING, hook);
        IPoolManagerInit(v4.poolManager).initialize(key, TickMath.getSqrtPriceAtTick(0));
        vm.prank(admin);
        bytes32 poolId = registry.addV4Pool(key, MEMECOIN);
        (int24 lo, int24 hi) = _usdcSide();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(VaultBook.HookedPoolNotAllowed.selector, poolId));
        vault.openPosition(_openArgs(poolId, lo, hi, 100e6, 0));
    }

    function test_openRejectsWidthOutOfBounds() public {
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(VaultBook.WidthOutOfBounds.selector, int24(0)));
        vault.openPosition(_openArgs(v3PoolId, -600, -600, 100e6, 0));
        vm.expectRevert(abi.encodeWithSelector(VaultBook.WidthOutOfBounds.selector, int24(240_000)));
        vault.openPosition(_openArgs(v3PoolId, -120_000, 120_000, 100e6, 100e6));
        vm.stopPrank();
    }

    function test_openRejectsTooManyRangesInOnePool() public {
        (int24 lo, int24 hi) = _usdcSide();
        for (uint256 i = 0; i < 10; i++) {
            _open(v3PoolId, lo, hi, 10e6, 0);
        }
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(VaultBook.TooManyRanges.selector, v3PoolId));
        vault.openPosition(_openArgs(v3PoolId, lo, hi, 10e6, 0));
    }

    /// One cap across v3 AND v4.
    function test_openRejectsMoreThanMaxPositionsAcrossProtocols() public {
        (int24 lo, int24 hi) = _usdcSide();
        for (uint256 i = 0; i < 10; i++) {
            _open(v3PoolId, lo, hi, 10e6, 0);
            _open(v4PoolId, lo, hi, 10e6, 0);
        }
        (bytes32 extra) = _extraV3Pool();
        vm.prank(keeper);
        vm.expectRevert(VaultBook.TooManyPositions.selector);
        vault.openPosition(_openArgs(extra, lo, hi, 10e6, 0));
    }

    function test_openRejectsThinPool() public {
        VaultRegistry.ClassParams memory p = _classParams();
        p.minPoolLiquidity = type(uint128).max;
        vm.prank(admin);
        registry.setClassParams(MEMECOIN, p);
        (int24 lo, int24 hi) = _usdcSide();
        vm.prank(keeper);
        vm.expectPartialRevert(VaultBook.PoolTooThin.selector);
        vault.openPosition(_openArgs(v3PoolId, lo, hi, 100e6, 0));
    }

    /// maxAllocationBps / maxClassBps = 30% of NAV (10,000 USDC).
    function test_openRejectsAllocationAboveLimit() public {
        (int24 lo, int24 hi) = _usdcSide();
        _open(v3PoolId, lo, hi, 2_900e6, 0);
        vm.prank(keeper);
        vm.expectPartialRevert(VaultBook.AllocationExceeded.selector);
        vault.openPosition(_openArgs(v3PoolId, lo, hi, 200e6, 0));
        // The class limit spans pools: 2,900 in v3 + 200 in v4 > 3,000.
        vm.prank(keeper);
        vm.expectPartialRevert(VaultBook.AllocationExceeded.selector);
        vault.openPosition(_openArgs(v4PoolId, lo, hi, 200e6, 0));
    }

    function test_openCannotSpendMoreThanIdle() public {
        _requestDeposit(bob, 5_000e6); // pending, not idle
        (int24 lo, int24 hi) = _usdcSide();
        vm.prank(keeper);
        vm.expectPartialRevert(VaultOps.InsufficientIdle.selector);
        vault.openPosition(_openArgs(v3PoolId, lo, hi, 10_001e6, 0));
    }

    function test_openCannotSpendTokensItDoesNotHold() public {
        vm.prank(keeper);
        vm.expectPartialRevert(VaultOps.InsufficientInventory.selector);
        vault.openPosition(_openArgs(v3PoolId, -600, 600, 100e6, 100e6));
    }

    /// Withdrawing a position credits USDC to idle and the token to inventory, at
    /// Uniswap's amounts; collecting fees does the same with the fees.
    function test_withdrawAndCollectCreditIdleAndInventory() public {
        uint256 id3 = _openInRange(v3PoolId, 500e6);
        uint256 id4 = _openInRange(v4PoolId, 500e6);
        _traderSwapV3(address(meme), 2_000e6);
        _traderSwapV4(address(meme), 2_000e6);
        uint256 idleBefore = vault.idleAssets();

        uint256 memeBefore = vault.tokenBalance(address(meme));
        uint128 liq3 = _liq3(id3);
        uint128 liq4 = _liq4(id4);
        vm.startPrank(keeper);
        vault.collectPositionFees(P3, id3);
        uint256 memeFees = vault.tokenBalance(address(meme)) - memeBefore;
        assertGt(memeFees, 0, "v3 fees in MEME");
        vault.withdrawPosition(P3, VaultOps.Removal(id3, liq3, 0, 0, block.timestamp));
        vault.withdrawPosition(P4, VaultOps.Removal(id4, liq4, 0, 0, block.timestamp));
        vm.stopPrank();

        assertGt(vault.idleAssets(), idleBefore);
        assertGt(vault.tokenBalance(address(meme)), memeBefore + memeFees);
        assertEq(vault.tokenPool(address(meme)), v3PoolId);
        assertEq(vault.inventoryTokens().length, 1);
        // Inventory is exactly what the vault holds in MEME.
        assertEq(meme.balanceOf(address(vault)), vault.tokenBalance(address(meme)));
        // Positions are empty and can be closed.
        vm.startPrank(keeper);
        vault.closePosition(P3, id3);
        vault.closePosition(P4, id4);
        vm.stopPrank();
        (uint256 n3, uint256 n4) = vault.positionCount();
        assertEq(n3 + n4, 0);
    }

    /// Accounting matches balances: idle + pending + claimable + owed == USDC held.
    function test_usdcAccountingMatchesBalance() public {
        _openInRange(v3PoolId, 500e6);
        _traderSwapV3(address(meme), 2_000e6);
        _requestDeposit(bob, 500e6);
        uint256 id = _firstPosition(P3);
        uint128 liq = _liq3(id);
        vm.prank(keeper);
        vault.withdrawPosition(P3, VaultOps.Removal(id, liq, 0, 0, block.timestamp));
        assertEq(
            usdc.balanceOf(address(vault)),
            vault.idleAssets() + vault.pendingDepositAssets() + vault.claimableAssets()
        );
    }

    function test_unknownPositionReverts() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(VaultOps.UnknownPosition.selector, P3, 999));
        vault.withdrawPosition(P3, VaultOps.Removal(999, 1, 0, 0, block.timestamp));
    }

    /// Risk-reducing keeper actions keep working while paused.
    function test_withdrawAllowedWhilePaused() public {
        uint256 id = _openInRange(v4PoolId, 500e6);
        vm.prank(guardian);
        vault.pause();
        uint128 liq = _liq4(id);
        vm.prank(keeper);
        vault.withdrawPosition(P4, VaultOps.Removal(id, liq, 0, 0, block.timestamp));
        assertEq(_liq4(id), 0);
    }

    // ---------------------------------------------------------------------

    /// @dev A range entirely on USDC's side of the current price (tick 0): it takes USDC only.
    function _usdcSide() internal view returns (int24 lo, int24 hi) {
        return address(usdc) < address(meme) ? (int24(600), int24(1200)) : (int24(-1200), int24(-600));
    }

    function _extraV3Pool() internal returns (bytes32 poolId) {
        MockERC20 t = new MockERC20("Extra", "EXT");
        (, poolId) = _addV3Pool(address(t));
    }

    function _firstPosition(VaultBook.Protocol p) internal view returns (uint256) {
        return vault.positionAt(p, 0);
    }

    function _liq3(uint256 id) internal view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = vault.npm().positions(id);
    }

    function _liq4(uint256 id) internal view returns (uint128) {
        return vault.posm().getPositionLiquidity(id);
    }
}
