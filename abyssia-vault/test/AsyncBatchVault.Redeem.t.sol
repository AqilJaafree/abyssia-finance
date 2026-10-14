// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {AsyncBatchVault} from "../src/AsyncBatchVault.sol";

contract AsyncBatchVaultRedeemTest is VaultTestBase {
    function test_requestRedeemEscrowsShares() public {
        uint256 shares = _depositAndClaim(alice, 100 * USDC);
        vm.prank(alice);
        vault.requestRedeem(shares);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(vault)), shares);
        assertEq(vault.redeemRequestOf(2, alice), shares);
        // Escrowed shares still have a claim on NAV until settlement.
        assertEq(vault.totalAssets(), 100 * USDC);
    }

    function test_cancelRedeemRequestReturnsShares() public {
        uint256 shares = _depositAndClaim(alice, 100 * USDC);
        vm.startPrank(alice);
        vault.requestRedeem(shares);
        vault.cancelRedeemRequest();
        vm.stopPrank();
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.redeemRequestOf(2, alice), 0);
    }

    function test_settleBurnsSharesAndReservesAssets() public {
        uint256 shares = _depositAndClaim(alice, 100 * USDC);
        vm.prank(alice);
        vault.requestRedeem(shares);
        _settle();

        assertEq(vault.totalSupply(), 0);
        assertEq(vault.claimableAssets(), 100 * USDC); // exact round trip, no rounding loss here
        assertEq(vault.totalAssets(), 0);

        vm.prank(alice);
        uint256 assets = vault.claimRedeem(2, alice);
        assertEq(assets, 100 * USDC);
        assertEq(usdc.balanceOf(alice), 100 * USDC);
        assertEq(vault.claimableAssets(), 0);
    }

    function test_redeemAfterGainPaysGain() public {
        uint256 shares = _depositAndClaim(alice, 100 * USDC);
        _gain(10 * USDC); // +10%
        vm.prank(alice);
        vault.requestRedeem(shares);
        _settle();
        vm.prank(alice);
        uint256 assets = vault.claimRedeem(2, alice);
        assertApproxEqAbs(assets, 110 * USDC, 1);
    }

    function test_depositsAndRedeemsInSameBatchNet() public {
        uint256 aliceShares = _depositAndClaim(alice, 100 * USDC);
        // Batch 2: alice redeems everything while bob deposits 50.
        vm.prank(alice);
        vault.requestRedeem(aliceShares);
        _requestDeposit(bob, 50 * USDC);
        _settle();

        vm.prank(alice);
        uint256 out = vault.claimRedeem(2, alice);
        vm.prank(bob);
        uint256 bobShares = vault.claimDeposit(2, bob);
        assertApproxEqAbs(out, 100 * USDC, 1);
        assertEq(bobShares, 50e12);
        assertApproxEqAbs(vault.totalAssets(), 50 * USDC, 1);
    }

    function test_redeemRevertsWhenNotEnoughIdle() public {
        uint256 shares = _depositAndClaim(alice, 100 * USDC);
        // Pretend 90 USDC is deployed into LP: NAV is unchanged but only 10 is idle.
        vault.harnessDecreaseIdle(90 * USDC);
        vault.setDeployedValue(90 * USDC);
        deal(address(usdc), address(vault), 10 * USDC);
        vm.prank(alice);
        vault.requestRedeem(shares);
        vm.warp(block.timestamp + vault.minSettleInterval());
        uint256 price = vault.sharePrice();
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(AsyncBatchVault.InsufficientIdle.selector, 100 * USDC, 10 * USDC)
        );
        vault.settle(price);
    }

    function test_claimRedeemWorksWhenPaused() public {
        uint256 shares = _depositAndClaim(alice, 100 * USDC);
        vm.prank(alice);
        vault.requestRedeem(shares);
        _settle();
        vm.prank(guardian);
        vault.pause();
        vm.prank(alice);
        vault.claimRedeem(2, alice);
        assertEq(usdc.balanceOf(alice), 100 * USDC);
    }
}
