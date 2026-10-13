// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {VaultTestBase} from "./VaultTestBase.sol";
import {AsyncBatchVault} from "../src/AsyncBatchVault.sol";

contract AsyncBatchVaultHardeningTest is VaultTestBase {
    address internal treasury = makeAddr("treasury");

    // --- F1: donations ------------------------------------------------------

    function test_donationDoesNotMoveNavOrBlockSettle() public {
        uint256 shares = _depositAndClaim(alice, 100 * USDC);
        uint256 priceBefore = vault.sharePrice();

        usdc.mint(address(vault), 500 * USDC); // +500% donation, guard is 20%
        assertEq(vault.totalAssets(), 100 * USDC);
        assertEq(vault.sharePrice(), priceBefore);

        _requestDeposit(bob, 10 * USDC);
        _settle(); // not griefed
        assertEq(vault.lastSharePrice(), priceBefore);

        // A large holder cannot recover the donation through the in-kind exit.
        vm.prank(alice);
        uint256 out = vault.redeemInKind(shares, alice);
        assertApproxEqAbs(out, 100 * USDC, 1);
    }

    function test_sweepSurplusSendsExactlyTheDonation() public {
        uint256 shares = _depositAndClaim(alice, 100 * USDC);
        vm.prank(alice);
        vault.requestRedeem(shares / 2);
        _settle(); // 50 USDC now claimable
        _requestDeposit(bob, 30 * USDC); // 30 USDC pending
        usdc.mint(address(vault), 7 * USDC); // donation

        vm.prank(admin);
        uint256 swept = vault.sweepSurplus(treasury);
        assertEq(swept, 7 * USDC);
        assertEq(usdc.balanceOf(treasury), 7 * USDC);
        assertApproxEqAbs(vault.totalAssets(), 50 * USDC, 1);
        assertEq(vault.pendingDepositAssets(), 30 * USDC);
        assertApproxEqAbs(vault.claimableAssets(), 50 * USDC, 1);

        // Everyone can still be paid in full.
        vm.prank(alice);
        vault.claimRedeem(2, alice);
        vm.prank(bob);
        vault.cancelDepositRequest();
        assertEq(usdc.balanceOf(bob), 30 * USDC);
    }

    function test_sweepSurplusAdminOnly() public {
        usdc.mint(address(vault), 7 * USDC);
        bytes32 role = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, guardian, role)
        );
        vault.sweepSurplus(treasury);
    }

    function test_sweepSurplusRejectsZeroAddress() public {
        usdc.mint(address(vault), 7 * USDC);
        vm.prank(admin);
        vm.expectRevert(AsyncBatchVault.ZeroAddress.selector);
        vault.sweepSurplus(address(0));
    }

    function test_decreaseIdleBeyondIdleReverts() public {
        _depositAndClaim(alice, 100 * USDC);
        vm.expectRevert(
            abi.encodeWithSelector(AsyncBatchVault.InsufficientIdle.selector, 100 * USDC + 1, 100 * USDC)
        );
        vault.harnessDecreaseIdle(100 * USDC + 1);
    }

    // --- F2: bounded guardian override -------------------------------------

    /// @dev Simulates a real -50% loss: all 100 USDC deployed, position now worth 50.
    function _halveNav() internal {
        vault.harnessDecreaseIdle(100 * USDC);
        vault.setDeployedValue(50 * USDC);
        deal(address(usdc), address(vault), 0);
    }

    function test_guardianOverrideWithinTolerance() public {
        _depositAndClaim(alice, 100 * USDC);
        _halveNav();
        vm.prank(keeper);
        vm.expectRevert();
        vault.settle();

        vm.prank(guardian);
        vault.settleAcceptingPriceMove(0.5e6, 100);
        assertApproxEqAbs(vault.lastSharePrice(), 0.5e6, 1);
    }

    function test_guardianOverrideOutsideToleranceReverts() public {
        _depositAndClaim(alice, 100 * USDC);
        _halveNav();
        uint256 live = vault.sharePrice();
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(AsyncBatchVault.PriceNotAsExpected.selector, 0.6e6, live));
        vault.settleAcceptingPriceMove(0.6e6, 100);
    }

    function test_guardianOverrideParamBounds() public {
        _depositAndClaim(alice, 100 * USDC);
        _halveNav();
        vm.startPrank(guardian);
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        vault.settleAcceptingPriceMove(0.5e6, 2_001); // maxCycleMoveBps is 2_000
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        vault.settleAcceptingPriceMove(0, 100);
        vm.stopPrank();
    }

    function test_keeperCannotUseGuardianOverride() public {
        bytes32 role = vault.GUARDIAN_ROLE();
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, keeper, role)
        );
        vault.settleAcceptingPriceMove(1e6, 100);
    }

    // --- F3: shares sent to the vault ---------------------------------------

    function test_directShareTransferToVaultReverts() public {
        uint256 shares = _depositAndClaim(alice, 100 * USDC);
        vm.startPrank(alice);
        vm.expectRevert(AsyncBatchVault.SharesToVaultNotAllowed.selector);
        vault.transfer(address(vault), shares);

        vault.approve(bob, shares);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(AsyncBatchVault.SharesToVaultNotAllowed.selector);
        vault.transferFrom(alice, address(vault), shares);

        // The escrow path still works.
        vm.prank(alice);
        vault.requestRedeem(shares);
        assertEq(vault.balanceOf(address(vault)), shares);
    }

    // --- F4: guard after the vault empties -----------------------------------

    function test_emptyVaultSettlesWithoutStaleGuard() public {
        uint256 shares = _depositAndClaim(alice, 100 * USDC);
        // Three in-guard gains take the last settlement price to ~1.45.
        for (uint256 i = 0; i < 3; i++) {
            _gain(15 * USDC);
            _settle();
        }
        assertApproxEqAbs(vault.lastSharePrice(), 1.45e6, 1);

        vm.prank(alice);
        vault.redeemInKind(shares, alice);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.sharePrice(), 1e6); // ~31% below the last price: beyond the 20% guard

        uint256 bobShares = _depositAndClaim(bob, 100 * USDC);
        assertEq(bobShares, 100e12);
        assertEq(vault.lastSharePrice(), 1e6);
    }
}
