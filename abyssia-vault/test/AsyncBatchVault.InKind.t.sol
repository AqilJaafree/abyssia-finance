// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {AsyncBatchVault} from "../src/AsyncBatchVault.sol";

contract AsyncBatchVaultInKindTest is VaultTestBase {
    function test_redeemInKindPaysProRataIdle() public {
        uint256 a = _depositAndClaim(alice, 300 * USDC);
        _depositAndClaim(bob, 100 * USDC);
        vm.prank(alice);
        uint256 out = vault.redeemInKind(a, alice);
        assertApproxEqAbs(out, 300 * USDC, 1);
        assertEq(vault.balanceOf(alice), 0);
        assertApproxEqAbs(vault.totalAssets(), 100 * USDC, 1);
    }

    function test_redeemInKindIgnoresPendingDepositsAndClaimables() public {
        uint256 a = _depositAndClaim(alice, 100 * USDC);
        _requestDeposit(bob, 500 * USDC); // pending, not NAV
        vm.prank(alice);
        uint256 out = vault.redeemInKind(a / 2, alice);
        assertApproxEqAbs(out, 50 * USDC, 1);
        // Bob's pending deposit is untouched.
        assertEq(vault.pendingDepositAssets(), 500 * USDC);
    }

    function test_redeemInKindWorksWhenPaused() public {
        uint256 a = _depositAndClaim(alice, 100 * USDC);
        vm.prank(guardian);
        vault.pause();
        vm.prank(alice);
        uint256 out = vault.redeemInKind(a, alice);
        assertApproxEqAbs(out, 100 * USDC, 1);
    }

    function test_redeemInKindZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(AsyncBatchVault.ZeroAmount.selector);
        vault.redeemInKind(0, alice);
    }
}
