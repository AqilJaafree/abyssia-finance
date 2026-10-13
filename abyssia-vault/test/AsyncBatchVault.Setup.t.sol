// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {AsyncBatchVault} from "../src/AsyncBatchVault.sol";
import {AsyncBatchVaultHarness} from "./harness/AsyncBatchVaultHarness.sol";

contract AsyncBatchVaultSetupTest is VaultTestBase {
    function test_sharesHave12Decimals() public view {
        assertEq(vault.decimals(), 12);
    }

    function test_rolesAssigned() public view {
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(vault.hasRole(vault.KEEPER_ROLE(), keeper));
        assertTrue(vault.hasRole(vault.GUARDIAN_ROLE(), guardian));
    }

    function test_initialParams() public view {
        assertEq(vault.minDeposit(), 1e6);
        assertEq(vault.maxTotalAssets(), 1_000_000e6);
        assertEq(vault.maxCycleMoveBps(), 2_000);
        assertEq(vault.currentBatchId(), 1);
        assertEq(vault.lastSharePrice(), 0);
    }

    function test_initialSharePriceIsOneUsdc() public view {
        assertEq(vault.sharePrice(), 1e6);
    }

    function test_rejectsNon6DecimalAsset() public {
        MockUSDC native18 = new MockUSDC(18);
        vm.expectRevert(AsyncBatchVault.AssetNotSixDecimals.selector);
        new AsyncBatchVaultHarness(native18, admin, keeper, guardian);
    }

    function test_rejectsZeroRoleAddress() public {
        vm.expectRevert(AsyncBatchVault.ZeroAddress.selector);
        new AsyncBatchVaultHarness(usdc, address(0), keeper, guardian);
    }

    function test_syncErc4626EntryPointsRevert() public {
        vm.expectRevert(AsyncBatchVault.AsyncOnly.selector);
        vault.deposit(1e6, alice);
        vm.expectRevert(AsyncBatchVault.AsyncOnly.selector);
        vault.mint(1e12, alice);
        vm.expectRevert(AsyncBatchVault.AsyncOnly.selector);
        vault.withdraw(1e6, alice, alice);
        vm.expectRevert(AsyncBatchVault.AsyncOnly.selector);
        vault.redeem(1e12, alice, alice);
        vm.expectRevert(AsyncBatchVault.AsyncOnly.selector);
        vault.previewDeposit(1e6);
        vm.expectRevert(AsyncBatchVault.AsyncOnly.selector);
        vault.previewMint(1e12);
        vm.expectRevert(AsyncBatchVault.AsyncOnly.selector);
        vault.previewWithdraw(1e6);
        vm.expectRevert(AsyncBatchVault.AsyncOnly.selector);
        vault.previewRedeem(1e12);
    }

    function test_maxFunctionsReturnZero() public view {
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
    }
}
