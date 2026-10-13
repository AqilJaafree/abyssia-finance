// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {AsyncBatchVault} from "../src/AsyncBatchVault.sol";

contract AsyncBatchVaultEventsTest is VaultTestBase {
    function test_requestDepositEmits() public {
        usdc.mint(alice, 100 * USDC);
        vm.startPrank(alice);
        usdc.approve(address(vault), 100 * USDC);
        vm.expectEmit(true, true, false, true, address(vault));
        emit AsyncBatchVault.DepositRequested(alice, 1, 100 * USDC);
        vault.requestDeposit(100 * USDC);
        vm.stopPrank();
    }

    function test_cancelDepositEmits() public {
        _requestDeposit(alice, 100 * USDC);
        vm.expectEmit(true, true, false, true, address(vault));
        emit AsyncBatchVault.DepositRequestCancelled(alice, 1, 100 * USDC);
        vm.prank(alice);
        vault.cancelDepositRequest();
    }

    function test_requestRedeemEmits() public {
        uint256 shares = _depositAndClaim(alice, 100 * USDC);
        vm.expectEmit(true, true, false, true, address(vault));
        emit AsyncBatchVault.RedeemRequested(alice, 2, shares);
        vm.prank(alice);
        vault.requestRedeem(shares);
    }

    function test_cancelRedeemEmits() public {
        uint256 shares = _depositAndClaim(alice, 100 * USDC);
        vm.startPrank(alice);
        vault.requestRedeem(shares);
        vm.expectEmit(true, true, false, true, address(vault));
        emit AsyncBatchVault.RedeemRequestCancelled(alice, 2, shares);
        vault.cancelRedeemRequest();
        vm.stopPrank();
    }

    function test_settleEmitsBatchSettled() public {
        _requestDeposit(alice, 100 * USDC);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AsyncBatchVault.BatchSettled(1, 1e6, 100 * USDC, 100e12, 0, 0);
        _settle();
    }

    function test_settleEmitsBatchSettledWithRedeem() public {
        uint256 shares = _depositAndClaim(alice, 100 * USDC);
        vm.prank(alice);
        vault.requestRedeem(shares);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AsyncBatchVault.BatchSettled(2, vault.sharePrice(), 0, 0, shares, 100 * USDC);
        _settle();
    }

    function test_claimDepositEmits() public {
        _requestDeposit(alice, 100 * USDC);
        _settle();
        vm.expectEmit(true, true, false, true, address(vault));
        emit AsyncBatchVault.DepositClaimed(alice, 1, bob, 100e12);
        vm.prank(alice);
        vault.claimDeposit(1, bob);
    }

    function test_claimRedeemEmits() public {
        uint256 shares = _depositAndClaim(alice, 100 * USDC);
        vm.prank(alice);
        vault.requestRedeem(shares);
        _settle();
        vm.expectEmit(true, true, false, true, address(vault));
        emit AsyncBatchVault.RedeemClaimed(alice, 2, bob, 100 * USDC);
        vm.prank(alice);
        vault.claimRedeem(2, bob);
    }

    function test_redeemInKindEmits() public {
        uint256 shares = _depositAndClaim(alice, 100 * USDC);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AsyncBatchVault.RedeemedInKind(alice, bob, shares, 100 * USDC);
        vm.prank(alice);
        vault.redeemInKind(shares, bob);
    }

    function test_sweepSurplusEmits() public {
        usdc.mint(address(vault), 7 * USDC);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AsyncBatchVault.SurplusSwept(bob, 7 * USDC);
        vm.prank(admin);
        vault.sweepSurplus(bob);
    }
}
