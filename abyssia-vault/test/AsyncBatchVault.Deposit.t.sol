// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {VaultTestBase} from "./VaultTestBase.sol";
import {AsyncBatchVault} from "../src/AsyncBatchVault.sol";

contract AsyncBatchVaultDepositTest is VaultTestBase {
    function test_requestDepositEscrowsUsdcOutsideNav() public {
        _requestDeposit(alice, 100 * USDC);
        assertEq(usdc.balanceOf(address(vault)), 100 * USDC);
        assertEq(vault.pendingDepositAssets(), 100 * USDC);
        assertEq(vault.depositRequestOf(1, alice), 100 * USDC);
        (uint128 depositAssets,,,,) = vault.batches(1);
        assertEq(depositAssets, 100 * USDC);
        // Pending deposits are not part of NAV until settled.
        assertEq(vault.totalAssets(), 0);
    }

    function test_requestDepositOneUsdcMinimumAllowed() public {
        _requestDeposit(alice, 1 * USDC);
        assertEq(vault.depositRequestOf(1, alice), 1 * USDC);
    }

    function test_requestDepositBelowMinimumReverts() public {
        usdc.mint(alice, USDC);
        vm.startPrank(alice);
        usdc.approve(address(vault), USDC);
        vm.expectRevert(abi.encodeWithSelector(AsyncBatchVault.BelowMinDeposit.selector, USDC - 1, USDC));
        vault.requestDeposit(USDC - 1);
        vm.stopPrank();
    }

    function test_requestDepositAboveCapReverts() public {
        vm.prank(admin);
        vault.setMaxTotalAssets(150 * USDC);
        _requestDeposit(alice, 100 * USDC);
        usdc.mint(bob, 51 * USDC);
        vm.startPrank(bob);
        usdc.approve(address(vault), 51 * USDC);
        vm.expectRevert(
            abi.encodeWithSelector(AsyncBatchVault.ExceedsMaxTotalAssets.selector, 151 * USDC, 150 * USDC)
        );
        vault.requestDeposit(51 * USDC);
        vm.stopPrank();
    }

    function test_requestDepositWhenPausedReverts() public {
        vm.prank(guardian);
        vault.pause();
        usdc.mint(alice, USDC);
        vm.startPrank(alice);
        usdc.approve(address(vault), USDC);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.requestDeposit(USDC);
        vm.stopPrank();
    }

    function test_cancelDepositRequestRefunds() public {
        _requestDeposit(alice, 100 * USDC);
        vm.prank(alice);
        vault.cancelDepositRequest();
        assertEq(usdc.balanceOf(alice), 100 * USDC);
        assertEq(vault.pendingDepositAssets(), 0);
        assertEq(vault.depositRequestOf(1, alice), 0);
        (uint128 depositAssets,,,,) = vault.batches(1);
        assertEq(depositAssets, 0);
    }

    function test_cancelAfterSettlementReverts() public {
        _requestDeposit(alice, 100 * USDC);
        _settle();
        vm.prank(alice);
        vm.expectRevert(AsyncBatchVault.NothingToCancel.selector);
        vault.cancelDepositRequest();
    }

    function test_settleMintsSharesAtOneUsdcAndClaimTransfersThem() public {
        _requestDeposit(alice, 100 * USDC);
        _settle();

        (, uint128 depositShares,,, bool settled) = vault.batches(1);
        assertTrue(settled);
        assertEq(depositShares, 100e12); // 100 shares at 12 decimals
        assertEq(vault.balanceOf(address(vault)), 100e12);
        assertEq(vault.pendingDepositAssets(), 0);
        assertEq(vault.totalAssets(), 100 * USDC);
        assertEq(vault.currentBatchId(), 2);
        assertEq(vault.lastSharePrice(), 1e6);

        vm.prank(alice);
        uint256 shares = vault.claimDeposit(1, alice);
        assertEq(shares, 100e12);
        assertEq(vault.balanceOf(alice), 100e12);
        assertEq(vault.balanceOf(address(vault)), 0);
    }

    function test_claimTwiceReverts() public {
        _depositAndClaim(alice, 100 * USDC);
        vm.prank(alice);
        vm.expectRevert(AsyncBatchVault.NothingToClaim.selector);
        vault.claimDeposit(1, alice);
    }

    function test_claimBeforeSettlementReverts() public {
        _requestDeposit(alice, 100 * USDC);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AsyncBatchVault.BatchNotSettled.selector, 1));
        vault.claimDeposit(1, alice);
    }

    function test_twoDepositorsSameBatchSplitProRata() public {
        _requestDeposit(alice, 300 * USDC);
        _requestDeposit(bob, 100 * USDC);
        _settle();
        vm.prank(alice);
        uint256 a = vault.claimDeposit(1, alice);
        vm.prank(bob);
        uint256 b = vault.claimDeposit(1, bob);
        assertEq(a, 3 * b);
    }

    function test_laterDepositorPaysHigherPriceAfterGain() public {
        _depositAndClaim(alice, 100 * USDC);
        _gain(10 * USDC); // +10% gain (fees/profit)
        uint256 bobShares = _depositAndClaim(bob, 110 * USDC);
        // 110 USDC at ~1.10 USDC/share ≈ 100 shares. OZ's virtual shares absorb a
        // negligible sliver of the gain, so it is "approximately", not exactly.
        assertApproxEqRel(bobShares, 100e12, 1e12); // within 0.0001%
    }

    function test_onlyKeeperCanSettle() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.settle();
    }

    function test_settleCallsBeforeSettleHook() public {
        _settle();
        assertEq(vault.beforeSettleCalls(), 1);
    }
}
