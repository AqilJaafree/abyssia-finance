// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {AsyncBatchVault} from "../src/AsyncBatchVault.sol";

/// The pre-settlement lock: the keeper freezes redeem requests and cancellations in the
/// open batch, once per batch and for at most BATCH_LOCK.
contract AsyncBatchVaultLockTest is VaultTestBase {
    uint256 internal shares;

    function setUp() public override {
        super.setUp();
        shares = _depositAndClaim(alice, 100 * USDC); // batch 1 settled; batch 2 is open
        vm.warp(block.timestamp + vault.BATCH_LOCK());
    }

    function test_lockBlocksRedeemRequestsAndCancels() public {
        _requestDeposit(bob, 10 * USDC);
        vm.prank(alice);
        vault.requestRedeem(shares / 2);
        _lock();
        uint256 until = block.timestamp + vault.BATCH_LOCK();
        assertEq(vault.batchLockedUntil(), until);

        bytes memory locked = abi.encodeWithSelector(AsyncBatchVault.BatchIsLocked.selector, until);
        vm.startPrank(alice);
        vm.expectRevert(locked);
        vault.requestRedeem(1);
        vm.expectRevert(locked);
        vault.cancelRedeemRequest();
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(locked);
        vault.cancelDepositRequest();
        vm.prank(alice);
        vault.setOperator(bob, true);
        vm.prank(bob);
        vm.expectRevert(locked);
        vault.cancelRedeemRequestFor(alice, bob);
    }

    /// Deposit requests and in-kind exits stay open while locked.
    function test_depositsAndInKindExitsStayOpen() public {
        _lock();
        _requestDeposit(bob, 10 * USDC);
        vm.prank(alice);
        vault.redeemInKind(shares / 2, alice);
        assertEq(vault.balanceOf(alice), shares - shares / 2);
    }

    function test_lockExpires() public {
        _lock();
        vm.warp(block.timestamp + vault.BATCH_LOCK());
        vm.prank(alice);
        vault.requestRedeem(1);
    }

    function test_settlementClearsTheLock() public {
        _lock();
        _settle();
        assertEq(vault.batchLockedUntil(), 0);
        vm.prank(alice);
        vault.requestRedeem(1);
    }

    /// Once per batch, and only after the batch has been open for BATCH_LOCK, so users
    /// always get that long to request or cancel.
    function test_lockLimits() public {
        _lock();
        vm.warp(block.timestamp + vault.BATCH_LOCK());
        vm.prank(keeper);
        vm.expectRevert(AsyncBatchVault.CannotLock.selector);
        vault.lockBatch(); // same batch

        _settle();
        vm.prank(keeper);
        vm.expectRevert(AsyncBatchVault.CannotLock.selector);
        vault.lockBatch(); // the new batch has just opened
        vm.warp(block.timestamp + vault.BATCH_LOCK());
        _lock();
        assertEq(vault.lastLockedBatch(), vault.currentBatchId());
    }

    function test_lockAuthAndPause() public {
        _expectUnauthorized(alice, vault.KEEPER_ROLE());
        vm.prank(alice);
        vault.lockBatch();
        vm.prank(guardian);
        vault.pause();
        vm.prank(keeper);
        vm.expectRevert(); // EnforcedPause
        vault.lockBatch();
    }

    function test_lockEmits() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit AsyncBatchVault.BatchLocked(2, block.timestamp + vault.BATCH_LOCK());
        _lock();
    }

    /// The `*For` cancel events name the operator and the receiver.
    function test_operatorCancelEventNamesOperatorAndReceiver() public {
        _requestDeposit(alice, 10 * USDC);
        vm.prank(alice);
        vault.setOperator(bob, true);
        vm.expectEmit(true, true, false, true, address(vault));
        emit AsyncBatchVault.DepositRequestCancelled(alice, 2, bob, keeper, 10 * USDC);
        vm.prank(bob);
        vault.cancelDepositRequestFor(alice, keeper);
    }

    function _lock() internal {
        vm.prank(keeper);
        vault.lockBatch();
    }
}
