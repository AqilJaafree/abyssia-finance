// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";
import {AsyncBatchVault} from "../src/AsyncBatchVault.sol";
import {AsyncBatchVaultHarness} from "./harness/AsyncBatchVaultHarness.sol";

contract AsyncBatchVaultFeesTest is VaultTestBase {
    address internal treasury = makeAddr("treasury");
    uint256 internal constant PERIOD = 7 days;

    function setUp() public override {
        super.setUp();
        vm.startPrank(admin);
        vault.setTreasury(treasury);
        vault.setFees(1_500, 0); // the production default (the base turns fees off)
        vm.stopPrank();
    }

    function test_defaults() public {
        AsyncBatchVaultHarness fresh = new AsyncBatchVaultHarness(usdc, admin, keeper, guardian);
        assertEq(fresh.performanceFeeBps(), 1_500);
        assertEq(fresh.managementFeeBps(), 0);
        assertEq(fresh.feePeriod(), PERIOD);
        assertEq(fresh.highWaterMark(), 0);
        assertEq(fresh.treasury(), admin);
    }

    function test_firstSettlementOnlySetsTheHighWaterMark() public {
        _depositAndClaim(alice, 100 * USDC);
        assertEq(vault.highWaterMark(), 1e6);
        assertEq(vault.feePeriodStart(), block.timestamp);
        assertEq(vault.balanceOf(treasury), 0);
    }

    /// A gain is charged only once it has held through a whole period: the period it was made
    /// in opened below it, so it is charged at the close of the next one. Holders keep 85%.
    function test_gainIsChargedOnceItHoldsThroughAPeriod() public {
        _depositAndClaim(alice, 100 * USDC); // period 1 opens at 1.00
        _gain(10 * USDC);
        _settle(); // 1.10
        assertEq(vault.feePeriodLow(), 1e6);
        _settleAfterPeriod(); // period 1's low was its 1.00 opening: nothing charged
        assertEq(vault.balanceOf(treasury), 0);
        assertApproxEqAbs(vault.feePeriodLow(), 1.1e6, 1); // period 2 opens at 1.10
        _settleAfterPeriod(); // the gain held through period 2
        uint256 treasuryValue = vault.convertToAssets(vault.balanceOf(treasury));
        assertApproxEqRel(treasuryValue, 1.5e6, 0.0001e18); // 15% of 10 USDC (virtual-share rounding)
        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(alice)), 108.5e6, 0.0001e18);
        assertApproxEqAbs(vault.highWaterMark(), 1.085e6, 1);
        assertEq(vault.lastSharePrice(), vault.highWaterMark());
        assertEq(vault.feePeriodLow(), vault.lastSharePrice()); // period 3 opens at the post-fee price
    }

    /// M-2: a spike that does not hold through the period is never charged.
    function test_spikeWithinThePeriodIsNotCharged() public {
        _depositAndClaim(alice, 100 * USDC);
        _gain(10 * USDC);
        _settle(); // 1.10
        vault.harnessDecreaseIdle(10 * USDC);
        _settle(); // back to 1.00: the period's low
        _gain(10 * USDC);
        _settleAfterPeriod(); // 1.10 at the close, but the low was 1.00
        assertEq(vault.balanceOf(treasury), 0);
        assertEq(vault.highWaterMark(), 1e6);
    }

    /// The fee is on the period's low, not its close; the rest of the gain is charged in a
    /// later period only if it holds through that one too.
    function test_gainAboveThePeriodLowCarriesToTheNextPeriod() public {
        _depositAndClaim(alice, 100 * USDC);
        _gain(10 * USDC);
        _settle(); // 1.10
        _settleAfterPeriod(); // period 2 opens at 1.10
        _gain(10 * USDC);
        _settle(); // 1.20
        _settleAfterPeriod(); // period 2's low is 1.10: charged on 1.00 -> 1.10 only
        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(treasury)), 1.5e6, 0.0001e18);
        assertApproxEqAbs(vault.highWaterMark(), 1.085e6, 1); // 1.10 less the 0.015 fee per share
        _settleAfterPeriod(); // 1.185 held through period 3
        // Now the remaining 0.10 per share is charged too: 1.5 USDC more.
        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(treasury)), 3e6, 0.001e18);
    }

    /// No fee is charged on recovering losses: only gains above the previous mark.
    function test_noPerformanceFeeBelowHighWaterMark() public {
        _depositAndClaim(alice, 100 * USDC);
        _gain(10 * USDC);
        _settle();
        _settleAfterPeriod();
        _settleAfterPeriod(); // mark 1.085
        uint256 tBefore = vault.balanceOf(treasury);
        assertGt(tBefore, 0);
        // Drop 5%, then recover 4%: still below the mark at the next closes.
        vault.harnessDecreaseIdle(5 * USDC);
        _settle();
        _gain(4 * USDC);
        _settleAfterPeriod();
        _settleAfterPeriod();
        assertEq(vault.balanceOf(treasury), tBefore);
    }

    /// Review M-1: a settlement with deposits or redemptions charges the gain that has held
    /// (up to the period's low) before converting the batch, so an entrant does not pay it.
    function test_flowSettlementChargesTheHeldGainFirst() public {
        _depositAndClaim(alice, 100 * USDC);
        _gain(10 * USDC);
        _settle();
        _settleAfterPeriod(); // period 2 opens at 1.10, nothing charged yet
        vm.warp(block.timestamp + 1 days);
        _requestDeposit(bob, 110 * USDC);
        (uint256 pre, uint256 post) = vault.previewSettlePrice();
        uint256 id = vault.currentBatchId();
        vm.prank(keeper);
        vault.settle(pre);
        assertEq(vault.lastSharePrice(), post);
        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(treasury)), 1.5e6, 0.0001e18);
        vm.prank(bob);
        uint256 bobShares = vault.claimDeposit(id, bob);
        _settleAfterPeriod(); // no price move: bob pays nothing
        assertApproxEqRel(vault.convertToAssets(bobShares), 110e6, 0.0001e18);
    }

    /// A fee change first charges the gain that has held at the old rate.
    function test_feeChangeChargesTheHeldGainAtTheOldRate() public {
        _depositAndClaim(alice, 100 * USDC);
        _gain(10 * USDC);
        _settle();
        _settleAfterPeriod(); // period 2 opens at 1.10
        vm.warp(block.timestamp + 1 days); // the opening price has held a day
        vm.prank(admin);
        vault.setFees(3_000, 0);
        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(treasury)), 1.5e6, 0.0001e18); // 15%
        uint256 tBefore = vault.balanceOf(treasury);
        _settleAfterPeriod(); // no new gain: nothing more at 30%
        assertEq(vault.balanceOf(treasury), tBefore);
    }

    /// 2% a year, one year: the treasury owns ~2% of the vault.
    function test_managementFeeAccruesPerSecond() public {
        vm.prank(admin);
        vault.setFees(0, 200);
        _depositAndClaim(alice, 100 * USDC);
        vm.warp(block.timestamp + 365 days);
        _settle();
        uint256 treasuryValue = vault.convertToAssets(vault.balanceOf(treasury));
        assertApproxEqRel(treasuryValue, 2e6, 0.001e18);
        assertApproxEqRel(vault.totalAssets(), 100e6, 0.000001e18); // fees are dilution, not outflow
    }

    /// L-1: a rate change accrues the fee owed so far at the old rate; the new rate applies
    /// only from the change.
    function test_managementRateChangeIsNotRetroactive() public {
        vm.prank(admin);
        vault.setFees(0, 200);
        _depositAndClaim(alice, 100 * USDC);
        vm.warp(block.timestamp + 365 days);
        vm.prank(guardian);
        vault.lowerFees(0, 0); // a year at 2% is accrued now
        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(treasury)), 2e6, 0.001e18);
        assertEq(vault.lastFeeAccrual(), block.timestamp);
        uint256 tBefore = vault.balanceOf(treasury);
        vm.warp(block.timestamp + 365 days);
        _settle();
        assertEq(vault.balanceOf(treasury), tBefore); // nothing at the new 0% rate
    }

    /// previewSettlePrice matches what settlement checks and converts at: mid-period (the
    /// management fee only) and at a period close (the performance fee too).
    function test_previewSettlePrice() public {
        vm.prank(admin);
        vault.setFees(1_500, 200);
        _depositAndClaim(alice, 100 * USDC);
        _gain(10 * USDC);
        vm.warp(block.timestamp + 1 days);
        (uint256 pre, uint256 post) = vault.previewSettlePrice();
        assertEq(pre, vault.sharePrice());
        assertLt(post, pre); // management fee only
        vm.prank(keeper);
        vault.settle(pre);
        assertEq(vault.lastSharePrice(), post);

        vm.warp(block.timestamp + PERIOD);
        (pre, post) = vault.previewSettlePrice();
        vm.prank(keeper);
        vault.settle(pre);
        assertEq(vault.lastSharePrice(), post);
        assertGt(vault.balanceOf(treasury), 0);
    }

    /// Re-review N-2: a spike at a period's close seeds the next period's low, but a flow
    /// settlement charges it only once the period is a day old (and the spike has held).
    function test_spikeAtTheCloseIsNotChargedEarly() public {
        _depositAndClaim(alice, 100 * USDC);
        _gain(15 * USDC); // spike to 1.15 right at the close
        _settleAfterPeriod(); // period 1's low was 1.00: nothing; period 2 opens at 1.15
        _requestDeposit(bob, 1 * USDC);
        _settle(); // a minute later, with a flow
        assertEq(vault.balanceOf(treasury), 0);
        vault.harnessDecreaseIdle(15 * USDC); // the spike fades
        _settle();
        vm.warp(block.timestamp + 1 days);
        _requestDeposit(bob, 1 * USDC);
        _settle(); // a day in: the period's low is back near 1.00 (~1.0013 after bob's entry)
        // Only that small held gain is charged (~0.02 USDC), never the spike's 2.25 USDC.
        assertLt(vault.convertToAssets(vault.balanceOf(treasury)), 0.05e6);
    }

    /// Re-review N-1: after an unsettled drop, a fee change charges nothing on the lost
    /// gain and still works after a crash below the fee itself.
    function test_feeChangeAfterADropChargesNoLostGain() public {
        _depositAndClaim(alice, 100 * USDC);
        _gain(15 * USDC);
        _settleAfterPeriod(); // period 2 opens at 1.15 (mark 1.00)
        vm.warp(block.timestamp + 1 days);
        vault.harnessDecreaseIdle(40 * USDC); // ~0.75 a share, below the mark
        vm.prank(guardian);
        vault.lowerFees(1_500, 0);
        assertEq(vault.balanceOf(treasury), 0);
        assertEq(vault.highWaterMark(), 1e6);
        vault.harnessDecreaseIdle(74 * USDC); // ~0.01 a share
        vm.prank(guardian);
        vault.lowerFees(0, 0);
        assertEq(vault.performanceFeeBps(), 0);
    }

    /// previewSettlePrice equals the post-fee price the batch converts at, with both fees
    /// on, at or after a period close, with or without a deposit in the batch.
    function testFuzz_previewMatchesSettlement(uint96 g1, uint96 g2, uint32 dt, bool flows, bool redeem)
        public
    {
        vm.prank(admin);
        vault.setFees(3_000, 200);
        uint256 shares = _depositAndClaim(alice, 100 * USDC);
        _gain(bound(g1, 0, 15 * USDC));
        _settle();
        _settleAfterPeriod();
        _gain(bound(g2, 0, 15 * USDC));
        vm.warp(block.timestamp + bound(dt, vault.minSettleInterval(), 2 * PERIOD));
        if (flows) _requestDeposit(bob, 10 * USDC);
        if (redeem) {
            vm.prank(alice);
            vault.requestRedeem(shares / 3);
        }
        (uint256 pre, uint256 post) = vault.previewSettlePrice();
        vm.prank(keeper);
        vault.settle(pre);
        assertEq(vault.lastSharePrice(), post);
    }

    function test_previewBeforeTheFirstSettlement() public view {
        (uint256 pre, uint256 post) = vault.previewSettlePrice();
        assertEq(pre, post);
    }

    function test_feePeriodBoundsAndAuth() public {
        vm.startPrank(admin);
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        vault.setFeePeriod(1 days - 1);
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        vault.setFeePeriod(90 days + 1);
        vault.setFeePeriod(30 days);
        vm.stopPrank();
        assertEq(vault.feePeriod(), 30 days);
        _expectUnauthorized(guardian, vault.DEFAULT_ADMIN_ROLE());
        vm.prank(guardian);
        vault.setFeePeriod(1 days);
    }

    function test_feeAdminCapsAndGuardianLowering() public {
        vm.startPrank(admin);
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        vault.setFees(3_001, 0);
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        vault.setFees(1_500, 201);
        vault.setFees(2_000, 100);
        vm.stopPrank();
        vm.startPrank(guardian);
        vault.lowerFees(1_000, 50);
        vm.expectRevert(AsyncBatchVault.NotLower.selector);
        vault.lowerFees(1_100, 50);
        vm.stopPrank();
        assertEq(vault.performanceFeeBps(), 1_000);
        assertEq(vault.managementFeeBps(), 50);
        _expectUnauthorized(guardian, vault.DEFAULT_ADMIN_ROLE());
        vm.prank(guardian);
        vault.setFees(0, 0);
    }

    function test_treasury() public {
        assertEq(vault.treasury(), treasury);
        vm.startPrank(admin);
        vm.expectRevert(AsyncBatchVault.ZeroAddress.selector);
        vault.setTreasury(address(0));
        vm.expectRevert(AsyncBatchVault.ZeroAddress.selector);
        vault.setTreasury(address(vault));
        vm.stopPrank();
    }

    /// Once a vault empties, the next holders' fee basis is the current price, not the old
    /// mark, and a new period starts.
    function test_highWaterMarkResetsWhenTheVaultEmpties() public {
        uint256 shares = _depositAndClaim(alice, 100 * USDC);
        _gain(15 * USDC); // within the 20% cycle guard
        _settle();
        _settleAfterPeriod();
        _settleAfterPeriod(); // mark ~1.1275
        vm.prank(alice);
        vault.redeemInKind(shares, alice);
        uint256 rest = vault.balanceOf(treasury);
        vm.prank(treasury);
        vault.redeemInKind(rest, treasury);
        assertEq(vault.totalSupply(), 0);
        _depositAndClaim(bob, 100 * USDC); // settles on an empty vault
        assertEq(vault.highWaterMark(), vault.lastSharePrice());
        assertEq(vault.feePeriodStart(), block.timestamp);
        _gain(10 * USDC);
        _settle();
        _settleAfterPeriod();
        _settleAfterPeriod();
        assertGt(vault.balanceOf(treasury), 0); // the new gain is charged once it holds
    }

    function _settleAfterPeriod() internal {
        vm.warp(vault.feePeriodStart() + vault.feePeriod());
        _settle();
    }
}
