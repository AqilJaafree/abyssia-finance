// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {VaultTestBase} from "./VaultTestBase.sol";
import {AsyncBatchVault} from "../src/AsyncBatchVault.sol";

contract AsyncBatchVaultSettleTest is VaultTestBase {
    function test_priceMoveWithinGuardSettles() public {
        _depositAndClaim(alice, 100 * USDC);
        _gain(15 * USDC); // +15%, guard is 20%
        _settle();
        assertApproxEqAbs(vault.lastSharePrice(), 1.15e6, 1);
    }

    function test_priceMoveBeyondGuardReverts() public {
        _depositAndClaim(alice, 100 * USDC);
        _gain(50 * USDC); // +50%, guard is 20%
        vm.warp(block.timestamp + vault.minSettleInterval());
        uint256 live = vault.sharePrice();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AsyncBatchVault.PriceMoveTooLarge.selector, 1e6, live));
        vault.settle(live);
    }

    function test_priceDropBeyondGuardReverts() public {
        _depositAndClaim(alice, 100 * USDC);
        _halveNav(); // -50%
        vm.warp(block.timestamp + vault.minSettleInterval());
        uint256 live = vault.sharePrice();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AsyncBatchVault.PriceMoveTooLarge.selector, 1e6, live));
        vault.settle(live);
    }

    function test_guardianCanAcceptLargeMove() public {
        _depositAndClaim(alice, 100 * USDC);
        _halveNav(); // -50% (e.g. a rug)
        vm.prank(guardian);
        vault.settleAcceptingPriceMove(0.5e6, 100);
        assertApproxEqAbs(vault.lastSharePrice(), 0.5e6, 1);
    }

    function test_settleWhenPausedReverts() public {
        vm.prank(guardian);
        vault.pause();
        vm.prank(keeper);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.settle(1e6);
    }

    function _settleGas() internal returns (uint256 used) {
        vm.warp(block.timestamp + vault.minSettleInterval());
        uint256 price = vault.sharePrice();
        vm.prank(keeper);
        uint256 gasBefore = gasleft();
        vault.settle(price);
        used = gasBefore - gasleft();
    }

    /// @dev Settlement cost must not grow with the number of depositors. A throwaway
    /// settle first makes both measured settles warm (no first-time 0 -> nonzero writes).
    function test_settlementCostIndependentOfDepositorCount() public {
        _requestDeposit(address(0xBEEF), USDC);
        _settle(); // throwaway

        _requestDeposit(address(0x1000), USDC);
        uint256 gas1 = _settleGas();

        for (uint256 i = 0; i < 50; i++) {
            _requestDeposit(address(uint160(0x2000 + i)), USDC);
        }
        uint256 gasN = _settleGas();

        assertLe(gasN, gas1 * 105 / 100);
        assertLt(gasN, 175_000);
        (, uint128 depositShares,,,) = vault.batches(3);
        assertEq(depositShares, 50e12);
    }

    /// A keeper can't settle twice within minSettleInterval (walking lastSharePrice).
    function test_settleTooSoonReverts() public {
        _depositAndClaim(alice, 100 * USDC); // settles at t
        uint256 next = vault.lastSettleTime() + vault.minSettleInterval();
        uint256 price = vault.sharePrice();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AsyncBatchVault.SettledTooRecently.selector, next));
        vault.settle(price);
        vm.warp(next);
        vm.prank(keeper);
        vault.settle(price);
        assertEq(vault.lastSettleTime(), next);
    }

    function test_minSettleIntervalAdminCapped() public {
        assertEq(vault.minSettleInterval(), 60);
        vm.startPrank(admin);
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        vault.setMinSettleInterval(1 hours + 1);
        vault.setMinSettleInterval(0);
        vm.stopPrank();
        assertEq(vault.minSettleInterval(), 0);
        _expectUnauthorized(guardian, vault.DEFAULT_ADMIN_ROLE());
        vm.prank(guardian);
        vault.setMinSettleInterval(10);
    }
}
