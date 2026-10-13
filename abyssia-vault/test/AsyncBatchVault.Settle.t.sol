// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {AsyncBatchVault} from "../src/AsyncBatchVault.sol";

contract AsyncBatchVaultSettleTest is VaultTestBase {
    /// @dev Simulates a real -50% loss: all 100 USDC deployed, position now worth 50.
    function _halveNav() internal {
        vault.harnessDecreaseIdle(100 * USDC);
        vault.setDeployedValue(50 * USDC);
        deal(address(usdc), address(vault), 0);
    }

    function test_priceMoveWithinGuardSettles() public {
        _depositAndClaim(alice, 100 * USDC);
        _gain(15 * USDC); // +15%, guard is 20%
        _settle();
        assertApproxEqAbs(vault.lastSharePrice(), 1.15e6, 1);
    }

    function test_priceMoveBeyondGuardReverts() public {
        _depositAndClaim(alice, 100 * USDC);
        _gain(50 * USDC); // +50%, guard is 20%
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AsyncBatchVault.PriceMoveTooLarge.selector, 1e6, 1_499_999));
        vault.settle();
    }

    function test_priceDropBeyondGuardReverts() public {
        _depositAndClaim(alice, 100 * USDC);
        _halveNav(); // -50%
        vm.prank(keeper);
        vm.expectRevert();
        vault.settle();
    }

    function test_guardianCanAcceptLargeMove() public {
        _depositAndClaim(alice, 100 * USDC);
        _halveNav(); // -50% (e.g. a rug)
        vm.prank(guardian);
        vault.settleAcceptingPriceMove(0.5e6, 100);
        assertApproxEqAbs(vault.lastSharePrice(), 0.5e6, 1);
    }

    function test_keeperCannotUseGuardianOverride() public {
        vm.prank(keeper);
        vm.expectRevert();
        vault.settleAcceptingPriceMove(1e6, 100);
    }

    function test_settleWhenPausedReverts() public {
        vm.prank(guardian);
        vault.pause();
        vm.prank(keeper);
        vm.expectRevert();
        vault.settle();
    }

    /// @dev Settlement cost must not grow with the number of depositors: 200
    /// one-USDC requests settle in a single cheap transaction.
    function test_settlementCostIndependentOfDepositorCount() public {
        for (uint256 i = 0; i < 200; i++) {
            _requestDeposit(address(uint160(0x1000 + i)), USDC);
        }
        vm.prank(keeper);
        uint256 gasBefore = gasleft();
        vault.settle();
        uint256 used = gasBefore - gasleft();
        // Constant-size bound (includes the first idleAssets SSTORE, 0 -> nonzero).
        assertLt(used, 175_000);
        (, uint128 depositShares,,,) = vault.batches(1);
        assertEq(depositShares, 200e12);
    }
}
