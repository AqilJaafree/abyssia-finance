// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {AsyncBatchVaultHarness} from "./harness/AsyncBatchVaultHarness.sol";

abstract contract VaultTestBase is Test {
    MockUSDC internal usdc;
    AsyncBatchVaultHarness internal vault;

    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant USDC = 1e6;

    function setUp() public virtual {
        usdc = new MockUSDC(6);
        vault = new AsyncBatchVaultHarness(usdc, admin, keeper, guardian);
    }

    function _requestDeposit(address user, uint256 assets) internal {
        usdc.mint(user, assets);
        vm.startPrank(user);
        usdc.approve(address(vault), assets);
        vault.requestDeposit(assets);
        vm.stopPrank();
    }

    /// @dev A real NAV gain (e.g. fees collected into USDC): the USDC arrives and is
    /// credited to idle through vault accounting. A bare transfer would be a donation.
    function _gain(uint256 amount) internal {
        usdc.mint(address(vault), amount);
        vault.harnessIncreaseIdle(amount);
    }

    function _settle() internal {
        vm.prank(keeper);
        vault.settle();
    }

    /// @dev Request, settle, and claim in one go; returns the shares received.
    function _depositAndClaim(address user, uint256 assets) internal returns (uint256 shares) {
        uint256 id = vault.currentBatchId();
        _requestDeposit(user, assets);
        _settle();
        vm.prank(user);
        shares = vault.claimDeposit(id, user);
    }
}
