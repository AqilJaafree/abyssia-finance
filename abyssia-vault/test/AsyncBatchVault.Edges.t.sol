// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {VaultTestBase} from "./VaultTestBase.sol";
import {AsyncBatchVault} from "../src/AsyncBatchVault.sol";

/// @dev Pause behaviour, zero/empty-state reverts, and batch isolation.
contract AsyncBatchVaultEdgesTest is VaultTestBase {
    function _pause() internal {
        vm.prank(guardian);
        vault.pause();
    }

    // --- unpause -------------------------------------------------------------

    function test_adminUnpauseRestoresRequests() public {
        _pause();
        vm.prank(admin);
        vault.unpause();
        assertFalse(vault.paused());
        _requestDeposit(alice, 10 * USDC);
        assertEq(vault.depositRequestOf(1, alice), 10 * USDC);
    }

    function test_guardianCannotUnpause() public {
        _pause();
        _expectUnauthorized(guardian, vault.DEFAULT_ADMIN_ROLE());
        vm.prank(guardian);
        vault.unpause();
        assertTrue(vault.paused());
    }

    // --- redeem-side reverts ---------------------------------------------------

    function test_requestRedeemZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(AsyncBatchVault.ZeroAmount.selector);
        vault.requestRedeem(0);
    }

    function test_cancelRedeemWithNothingReverts() public {
        vm.prank(alice);
        vm.expectRevert(AsyncBatchVault.NothingToCancel.selector);
        vault.cancelRedeemRequest();
    }

    function test_claimRedeemUnsettledBatchReverts() public {
        uint256 shares = _depositAndClaim(alice, 100 * USDC);
        vm.startPrank(alice);
        vault.requestRedeem(shares);
        vm.expectRevert(abi.encodeWithSelector(AsyncBatchVault.BatchNotSettled.selector, 2));
        vault.claimRedeem(2, alice);
        vm.stopPrank();
    }

    function test_claimRedeemWithoutRequestReverts() public {
        _depositAndClaim(alice, 100 * USDC); // batch 1 settled
        vm.prank(bob);
        vm.expectRevert(AsyncBatchVault.NothingToClaim.selector);
        vault.claimRedeem(1, bob);
    }

    // --- pause behaviour -----------------------------------------------------

    function test_requestRedeemWhenPausedReverts() public {
        uint256 shares = _depositAndClaim(alice, 100 * USDC);
        _pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.requestRedeem(shares);
    }

    function test_settleAcceptingPriceMoveWhenPausedReverts() public {
        _depositAndClaim(alice, 100 * USDC);
        _halveNav();
        _pause();
        vm.prank(guardian);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.settleAcceptingPriceMove(0.5e6, 100);
    }

    function test_cancelsAndClaimsWorkWhenPaused() public {
        uint256 shares = _depositAndClaim(alice, 100 * USDC);

        // alice: redeem request in batch 2; bob: deposit request in batch 2.
        vm.prank(alice);
        vault.requestRedeem(shares / 2);
        _requestDeposit(bob, 20 * USDC);
        _pause();

        vm.startPrank(alice);
        vault.cancelRedeemRequest();
        vm.stopPrank();
        assertEq(vault.balanceOf(alice), shares);

        vm.prank(bob);
        vault.cancelDepositRequest();
        assertEq(usdc.balanceOf(bob), 20 * USDC);
    }

    function test_claimDepositWorksWhenPaused() public {
        _requestDeposit(alice, 100 * USDC);
        _settle();
        _pause();
        vm.prank(alice);
        uint256 shares = vault.claimDeposit(1, alice);
        assertEq(shares, 100e12);
    }

    // --- batch isolation -------------------------------------------------------

    function test_batchesAreIsolatedAcrossPrices() public {
        _requestDeposit(alice, 100 * USDC);
        _settle(); // batch 1 at price 1.0
        _gain(10 * USDC); // price -> ~1.10
        _requestDeposit(bob, 110 * USDC);
        _settle(); // batch 2 at ~1.10

        vm.prank(alice);
        uint256 aliceShares = vault.claimDeposit(1, alice);
        assertEq(aliceShares, 100e12);

        vm.prank(bob);
        uint256 bobShares = vault.claimDeposit(2, bob);
        assertApproxEqRel(bobShares, 100e12, 1e12);

        // Neither user can claim the other's batch.
        vm.prank(alice);
        vm.expectRevert(AsyncBatchVault.NothingToClaim.selector);
        vault.claimDeposit(2, alice);
        vm.prank(bob);
        vm.expectRevert(AsyncBatchVault.NothingToClaim.selector);
        vault.claimDeposit(1, bob);
    }
}
