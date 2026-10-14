// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {AsyncBatchVault} from "../src/AsyncBatchVault.sol";
import {AsyncBatchVaultHarness} from "./harness/AsyncBatchVaultHarness.sol";

contract AsyncBatchVaultFeesTest is VaultTestBase {
    address internal treasury = makeAddr("treasury");

    function setUp() public override {
        super.setUp();
        vm.startPrank(admin);
        vault.setTreasury(treasury);
        vault.setFees(1_500, 0); // the production default (the base turns fees off)
        vm.stopPrank();
    }

    function test_defaults() public {
        AsyncBatchVaultHarness fresh = new AsyncBatchVaultHarness(usdc, admin, keeper, guardian);
        assertEq(fresh.performanceFeeBps(), 1_500);
        assertEq(fresh.managementFeeBps(), 0);
        assertEq(fresh.highWaterMark(), 0);
        assertEq(fresh.treasury(), admin);
    }

    function test_firstSettlementOnlySetsTheHighWaterMark() public {
        _depositAndClaim(alice, 100 * USDC);
        assertEq(vault.highWaterMark(), 1e6);
        assertEq(vault.balanceOf(treasury), 0);
    }

    /// +10% NAV: the treasury's new shares are worth 15% of the gain, holders keep 85%.
    function test_performanceFeeOnGainAboveHighWaterMark() public {
        _depositAndClaim(alice, 100 * USDC);
        _gain(10 * USDC);
        _settle();
        uint256 treasuryValue = vault.convertToAssets(vault.balanceOf(treasury));
        assertApproxEqRel(treasuryValue, 1.5e6, 0.0001e18); // 15% of 10 USDC (virtual-share rounding)
        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(alice)), 108.5e6, 0.0001e18);
        assertApproxEqAbs(vault.highWaterMark(), 1.085e6, 1);
        assertEq(vault.lastSharePrice(), vault.highWaterMark());
    }

    /// No fee is charged on recovering losses: only gains above the previous peak.
    function test_noPerformanceFeeBelowHighWaterMark() public {
        _depositAndClaim(alice, 100 * USDC);
        _gain(10 * USDC);
        _settle(); // peak 1.085
        uint256 tBefore = vault.balanceOf(treasury);
        // Drop 5%, then recover 4%: still below the peak.
        vault.harnessDecreaseIdle(5 * USDC);
        _settle();
        _gain(4 * USDC);
        _settle();
        assertEq(vault.balanceOf(treasury), tBefore);
    }

    /// 2% a year, one year: the treasury owns ~2% of the vault.
    function test_managementFeeAccruesPerSecond() public {
        vm.prank(admin);
        vault.setFees(0, 200);
        _depositAndClaim(alice, 100 * USDC);
        vm.warp(block.timestamp + 365 days);
        _settle();
        uint256 treasuryValue = vault.convertToAssets(vault.balanceOf(treasury));
        assertApproxEqRel(treasuryValue, 2e6, 0.001e18);
        assertApproxEqRel(vault.totalAssets(), 100e6, 0.000001e18); // fees are dilution, not outflow
    }

    function test_feeAdminCapsAndGuardianLowering() public {
        vm.startPrank(admin);
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        vault.setFees(3_001, 0);
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        vault.setFees(1_500, 201);
        vault.setFees(2_000, 100);
        vm.stopPrank();
        vm.startPrank(guardian);
        vault.lowerFees(1_000, 50);
        vm.expectRevert(AsyncBatchVault.NotLower.selector);
        vault.lowerFees(1_100, 50);
        vm.stopPrank();
        assertEq(vault.performanceFeeBps(), 1_000);
        assertEq(vault.managementFeeBps(), 50);
        _expectUnauthorized(guardian, vault.DEFAULT_ADMIN_ROLE());
        vm.prank(guardian);
        vault.setFees(0, 0);
    }

    function test_treasury() public {
        assertEq(vault.treasury(), treasury);
        vm.startPrank(admin);
        vm.expectRevert(AsyncBatchVault.ZeroAddress.selector);
        vault.setTreasury(address(0));
        vm.expectRevert(AsyncBatchVault.ZeroAddress.selector);
        vault.setTreasury(address(vault));
        vm.stopPrank();
    }
}
