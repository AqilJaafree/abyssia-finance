// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AbyssiaVaultTestBase} from "./AbyssiaVaultTestBase.sol";
import {AsyncBatchVault} from "../../src/AsyncBatchVault.sol";
import {MockSmartAccount} from "../mocks/MockSmartAccount.sol";

/// @dev ERC-7540 operators, and smart accounts (Safe / ERC-4337 / EIP-7702 shaped) using
/// every user path of the vault.
contract AbyssiaVaultAccountsTest is AbyssiaVaultTestBase {
    address internal operator = makeAddr("operator");

    // ---------------------------------------------------------------------
    // Operators
    // ---------------------------------------------------------------------

    function test_setOperator() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit AsyncBatchVault.OperatorSet(alice, operator, true);
        vm.prank(alice);
        assertTrue(vault.setOperator(operator, true));
        assertTrue(vault.isOperator(alice, operator));
        vm.prank(alice);
        vault.setOperator(operator, false);
        assertFalse(vault.isOperator(alice, operator));
    }

    function test_setOperatorRejectsSelfAndZero() public {
        vm.startPrank(alice);
        vm.expectRevert(AsyncBatchVault.InvalidOperator.selector);
        vault.setOperator(alice, true);
        vm.expectRevert(AsyncBatchVault.InvalidOperator.selector);
        vault.setOperator(address(0), true);
        vm.stopPrank();
    }

    function test_operatorClaimsDepositAndRedeemForController() public {
        vm.prank(alice);
        vault.setOperator(operator, true);
        _requestDeposit(alice, 1_000e6);
        uint256 id = vault.currentBatchId();
        _settle();
        vm.prank(operator);
        uint256 shares = vault.claimDepositFor(id, alice, alice);
        assertEq(vault.balanceOf(alice), shares);

        vm.prank(alice);
        vault.requestRedeem(shares);
        id = vault.currentBatchId();
        _settle();
        vm.prank(operator);
        uint256 assets = vault.claimRedeemFor(id, alice, bob); // operator chooses the receiver
        assertEq(usdc.balanceOf(bob), assets);
        assertApproxEqAbs(assets, 1_000e6, 1);
    }

    function test_operatorCancelsForController() public {
        vm.prank(alice);
        vault.setOperator(operator, true);
        _requestDeposit(alice, 1_000e6);
        vm.prank(operator);
        vault.cancelDepositRequestFor(alice, alice);
        assertEq(usdc.balanceOf(alice), 1_000e6);

        uint256 shares = _deposit(alice, 1_000e6);
        vm.prank(alice);
        vault.requestRedeem(shares);
        vm.prank(operator);
        vault.cancelRedeemRequestFor(alice, alice);
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_nonOperatorCannotActForController() public {
        _requestDeposit(alice, 1_000e6);
        uint256 id = vault.currentBatchId();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AsyncBatchVault.NotOperator.selector, alice, operator));
        vault.cancelDepositRequestFor(alice, operator);
        _settle();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AsyncBatchVault.NotOperator.selector, alice, operator));
        vault.claimDepositFor(id, alice, operator);
        // A revoked operator is locked out again.
        vm.prank(alice);
        vault.setOperator(operator, true);
        vm.prank(alice);
        vault.setOperator(operator, false);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AsyncBatchVault.NotOperator.selector, alice, operator));
        vault.claimDepositFor(id, alice, operator);
    }

    // ---------------------------------------------------------------------
    // Smart accounts
    // ---------------------------------------------------------------------

    /// A smart account approves + requests a deposit in ONE atomic batch, claims, requests
    /// and claims a redemption, and exits in kind to a not-yet-deployed address.
    function test_smartAccountFullLifecycle() public {
        MockSmartAccount account = new MockSmartAccount(alice);
        usdc.mint(address(account), 2_000e6);
        MockSmartAccount.Call[] memory calls = new MockSmartAccount.Call[](2);
        calls[0] =
            MockSmartAccount.Call(address(usdc), abi.encodeCall(IERC20.approve, (address(vault), 2_000e6)));
        calls[1] =
            MockSmartAccount.Call(address(vault), abi.encodeCall(AsyncBatchVault.requestDeposit, (2_000e6)));
        vm.prank(alice);
        account.executeBatch(calls);

        uint256 id = vault.currentBatchId();
        _settle();
        vm.prank(alice);
        account.execute(address(vault), abi.encodeCall(AsyncBatchVault.claimDeposit, (id, address(account))));
        uint256 shares = vault.balanceOf(address(account));
        assertGt(shares, 0);

        vm.prank(alice);
        account.execute(address(vault), abi.encodeCall(AsyncBatchVault.requestRedeem, (shares / 2)));
        id = vault.currentBatchId();
        _settle();
        vm.prank(alice);
        account.execute(address(vault), abi.encodeCall(AsyncBatchVault.claimRedeem, (id, address(account))));
        assertApproxEqAbs(usdc.balanceOf(address(account)), 1_000e6, 1);

        // Counterfactual receiver: an address with no code yet.
        address counterfactual = address(uint160(uint256(keccak256("future smart account"))));
        assertEq(counterfactual.code.length, 0);
        uint256 rest = vault.balanceOf(address(account));
        vm.prank(alice);
        account.execute(address(vault), abi.encodeCall(AsyncBatchVault.redeemInKind, (rest, counterfactual)));
        assertEq(vault.balanceOf(address(account)), 0);
        assertApproxEqAbs(usdc.balanceOf(counterfactual), 1_000e6, 1);
    }

    /// A smart account can be an operator for its owner's EOA, and vice versa.
    function test_smartAccountAsOperator() public {
        MockSmartAccount account = new MockSmartAccount(bob);
        vm.prank(alice);
        vault.setOperator(address(account), true);
        _requestDeposit(alice, 500e6);
        uint256 id = vault.currentBatchId();
        _settle();
        vm.prank(bob);
        account.execute(address(vault), abi.encodeCall(AsyncBatchVault.claimDepositFor, (id, alice, alice)));
        assertGt(vault.balanceOf(alice), 0);
    }
}
