// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {AsyncBatchVault} from "../src/AsyncBatchVault.sol";

contract AsyncBatchVaultParamsTest is VaultTestBase {
    function test_adminSetsMinDepositWithinBounds() public {
        vm.prank(admin);
        vault.setMinDeposit(100 * USDC);
        assertEq(vault.minDeposit(), 100 * USDC);
        vm.prank(admin);
        vault.setMinDeposit(0);
        assertEq(vault.minDeposit(), 0);
    }

    function test_minDepositAboveCapReverts() public {
        vm.prank(admin);
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        vault.setMinDeposit(100 * USDC + 1);
    }

    function test_zeroDepositRevertsEvenWithZeroMinimum() public {
        vm.prank(admin);
        vault.setMinDeposit(0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AsyncBatchVault.BelowMinDeposit.selector, 0, 0));
        vault.requestDeposit(0);
    }

    function test_maxCycleMoveBpsBounds() public {
        vm.startPrank(admin);
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        vault.setMaxCycleMoveBps(0);
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        vault.setMaxCycleMoveBps(5_001);
        vault.setMaxCycleMoveBps(5_000);
        vm.stopPrank();
        assertEq(vault.maxCycleMoveBps(), 5_000);
    }

    function test_guardianCanOnlyLowerCap() public {
        vm.prank(guardian);
        vault.lowerMaxTotalAssets(10 * USDC);
        assertEq(vault.maxTotalAssets(), 10 * USDC);
        vm.prank(guardian);
        vm.expectRevert(AsyncBatchVault.NotLower.selector);
        vault.lowerMaxTotalAssets(20 * USDC);
    }

    function test_nonAdminCannotSetParams() public {
        bytes32 role = vault.DEFAULT_ADMIN_ROLE();
        vm.startPrank(guardian);
        _expectUnauthorized(guardian, role);
        vault.setMaxTotalAssets(1);
        _expectUnauthorized(guardian, role);
        vault.setMinDeposit(1);
        _expectUnauthorized(guardian, role);
        vault.setMaxCycleMoveBps(1);
        vm.stopPrank();
    }

    function test_onlyGuardianCanPause() public {
        _expectUnauthorized(alice, vault.GUARDIAN_ROLE());
        vm.prank(alice);
        vault.pause();
    }
}
