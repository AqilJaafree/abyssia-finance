// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {V4TestBase} from "./V4TestBase.sol";
import {V4PositionsHarness} from "./V4PositionsHarness.sol";
import {V4Positions} from "../../src/v4/V4Positions.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFreezableERC20} from "../mocks/MockFreezableERC20.sol";
import {MockGasBurnerERC20} from "../mocks/MockGasBurnerERC20.sol";

/// @dev The per-position in-kind exit pattern (harness `inKindExit`) against tokens
/// that refuse transfers, plus slice validation, tick-boundary valuation and the
/// gas bound at MAX_POSITIONS.
contract V4PositionsInKindTest is V4TestBase {
    address internal receiver = makeAddr("receiver");
    MockFreezableERC20 internal hostile;
    PoolKey internal hostileKey;
    uint256 internal memeId;
    uint128 internal memeLiq;
    uint256 internal hostileId;
    uint128 internal hostileLiq;

    event SliceSkipped(uint256 indexed tokenId);

    function setUp() public override {
        super.setUp();
        hostile = new MockFreezableERC20("Hostile", "HOSTILE");
        (memeId, memeLiq) = _openInRange(1_000e6); // USDC/MEME
        hostileKey = _initPool(address(hostile));
        (hostileId, hostileLiq) = _openIn(hostileKey, 1_000e6); // USDC/HOSTILE
    }

    /// (a) A fully frozen token: its slice is skipped (left in the position for the
    /// remaining holders) and every other position still pays out.
    function test_frozenTokenIsSkippedOthersPaid() public {
        hostile.freeze();
        (uint256 v0, uint256 v1) = harness.positionAmounts(memeId);

        vm.expectEmit(true, false, false, false, address(harness));
        emit SliceSkipped(hostileId);
        harness.inKindExit(1, 4, receiver);

        // MEME/USDC slice delivered.
        assertEq(_liquidity(memeId), memeLiq - memeLiq / 4);
        assertApproxEqAbs(_bal(token0, receiver), v0 / 4, 2);
        assertApproxEqAbs(_bal(token1, receiver), v1 / 4, 2);
        // HOSTILE position untouched, nothing from it, no IOUs.
        assertEq(_liquidity(hostileId), hostileLiq);
        assertEq(hostile.balanceOf(receiver), 0);
        assertEq(harness.owed(receiver, address(hostile)), 0);
        assertEq(harness.owed(receiver, address(usdc)), 0);
    }

    /// (b) The receiver alone is blocked on HOSTILE: that slice is collected to the
    /// vault and owed to the receiver, claimable once the block lifts.
    function test_blockedReceiverGetsIou() public {
        hostile.setBlocked(receiver, true);
        uint256 hostileBefore = hostile.balanceOf(address(harness));
        uint256 usdcBefore = usdc.balanceOf(address(harness));

        harness.inKindExit(1, 4, receiver);

        assertEq(_liquidity(hostileId), hostileLiq - hostileLiq / 4);
        uint256 owedHostile = harness.owed(receiver, address(hostile));
        uint256 owedUsdc = harness.owed(receiver, address(usdc));
        assertGt(owedHostile, 0);
        assertGt(owedUsdc, 0);
        // No swaps, so no fees: the vault's whole delta is the IOU.
        assertEq(hostile.balanceOf(address(harness)) - hostileBefore, owedHostile);
        assertEq(usdc.balanceOf(address(harness)) - usdcBefore, owedUsdc);
        assertEq(harness.owedTotal(address(hostile)), owedHostile);
        assertEq(harness.owedTotal(address(usdc)), owedUsdc);
        // The MEME position still paid the receiver directly.
        assertGt(meme.balanceOf(receiver), 0);
        uint256 usdcDirect = usdc.balanceOf(receiver);

        vm.startPrank(receiver);
        harness.claimOwed(address(usdc));
        assertEq(usdc.balanceOf(receiver), usdcDirect + owedUsdc);
        assertEq(harness.owed(receiver, address(usdc)), 0);
        assertEq(harness.owedTotal(address(usdc)), 0);

        vm.expectRevert(abi.encodeWithSelector(MockFreezableERC20.Blocked.selector, receiver));
        harness.claimOwed(address(hostile));
        assertEq(harness.owed(receiver, address(hostile)), owedHostile);
        vm.stopPrank();

        hostile.setBlocked(receiver, false);
        vm.prank(receiver);
        harness.claimOwed(address(hostile));
        assertEq(hostile.balanceOf(receiver), owedHostile);
        assertEq(harness.owed(receiver, address(hostile)), 0);
        assertEq(harness.owedTotal(address(hostile)), 0);
    }

    /// (b2) With fees accrued, the IOU fallback still splits correctly: fees are the
    /// vault's (harvested), principal is owed to the receiver.
    function test_blockedReceiverIouExcludesFees() public {
        _swapIn(hostileKey, address(usdc), 100e6, 0);
        hostile.setBlocked(receiver, true);
        (uint256 v0, uint256 v1) = harness.positionAmounts(hostileId);
        (uint256 vUsdc, uint256 vHostile) = hostileKey.currency0 == address(usdc) ? (v0, v1) : (v1, v0);

        harness.inKindExit(1, 4, receiver);

        assertApproxEqAbs(harness.harvested(address(usdc)), 300_000, 2);
        assertApproxEqAbs(harness.owed(receiver, address(usdc)), vUsdc / 4, 2);
        assertApproxEqAbs(harness.owed(receiver, address(hostile)), vHostile / 4, 2);
    }

    /// (c) withdrawSlice rejects a zero supply and shares above supply (reached through a
    /// correctly bound self-call).
    function test_withdrawSliceRejectsInvalidSlice() public {
        vm.expectRevert(V4Positions.InvalidSlice.selector);
        harness.probeBoundSelfSlice(0, 0, receiver, memeId, 0, 0, receiver, receiver);
        vm.expectRevert(V4Positions.InvalidSlice.selector);
        harness.probeBoundSelfSlice(5, 4, receiver, memeId, 5, 4, receiver, receiver);
        vm.expectRevert(abi.encodeWithSelector(V4Positions.UnknownPosition.selector, 999));
        harness.probeBoundSelfSlice(1, 4, receiver, 999, 1, 4, receiver, receiver);
    }

    /// (d) The self-call entrypoint is closed to everyone but the vault itself.
    function test_sliceToRejectsExternalCallers() public {
        vm.expectRevert(V4PositionsHarness.OnlySelf.selector);
        harness.sliceTo(memeId, 1, 4, receiver, receiver);
        vm.prank(receiver);
        vm.expectRevert(V4PositionsHarness.OnlySelf.selector);
        harness.sliceTo(memeId, 1, 4, receiver, receiver);
    }

    /// (e) A self-call outside any exit has no binding and is rejected.
    function test_sliceToRejectsUnboundSelfCall() public {
        vm.expectRevert(V4PositionsHarness.UnboundSlice.selector);
        harness.probeUnboundSelfSlice(memeId, 1, 4, receiver);
        assertEq(_liquidity(memeId), memeLiq);
    }

    /// (f) A self-call whose shares / supply / receiver differ from the exit in progress,
    /// or that targets a third-party recipient, is rejected.
    function test_sliceToRejectsMismatchedBinding() public {
        address other = makeAddr("other");
        vm.expectRevert(V4PositionsHarness.UnboundSlice.selector);
        harness.probeBoundSelfSlice(1, 4, receiver, memeId, 2, 4, receiver, receiver); // shares
        vm.expectRevert(V4PositionsHarness.UnboundSlice.selector);
        harness.probeBoundSelfSlice(1, 4, receiver, memeId, 1, 2, receiver, receiver); // supply
        vm.expectRevert(V4PositionsHarness.UnboundSlice.selector);
        harness.probeBoundSelfSlice(1, 4, receiver, memeId, 1, 4, other, other); // receiver
        vm.expectRevert(V4PositionsHarness.UnboundSlice.selector);
        harness.probeBoundSelfSlice(1, 4, receiver, memeId, 1, 4, receiver, other); // recipient
        assertEq(_liquidity(memeId), memeLiq);
        // Sanity: a matching binding passes, to the receiver or to the vault itself.
        harness.probeBoundSelfSlice(1, 4, receiver, memeId, 1, 4, receiver, receiver);
        harness.probeBoundSelfSlice(1, 4, receiver, memeId, 1, 4, receiver, address(harness));
        assertLt(_liquidity(memeId), memeLiq);
    }

    /// (g) A token that burns all gas on transfer: its slice attempt is capped at
    /// SLICE_GAS, fails expensively (so no fallback attempt), is skipped, and every other
    /// position still pays out.
    function test_gasBurnerIsSkippedWithBoundedGas() public {
        MockGasBurnerERC20 burner = new MockGasBurnerERC20("Burner", "BURN");
        (uint256 burnerId, uint128 burnerLiq) = _openUsdcPool(address(burner), 1_000e6);
        burner.setBurn(true);
        uint256 hostileReceived = hostile.balanceOf(receiver);

        vm.expectEmit(true, false, false, false, address(harness));
        emit SliceSkipped(burnerId);
        // An expensive failure means the vault-recipient fallback is never attempted.
        vm.expectCall(
            address(harness),
            abi.encodeCall(harness.sliceTo, (burnerId, 1, 4, receiver, address(harness))),
            uint64(0)
        );
        uint256 g = gasleft();
        harness.inKindExit{gas: 20_000_000}(1, 4, receiver);
        uint256 used = g - gasleft();
        emit log_named_uint("inKindExit gas (3 positions, 1 gas burner)", used);

        // The burner costs one SLICE_GAS (500k) + overhead, the two honest slices
        // well under 400k each; a second (fallback) burner attempt would break this.
        assertLt(used, harness.SLICE_GAS() + 2 * 400_000);
        assertEq(_liquidity(burnerId), burnerLiq);
        assertEq(_liquidity(memeId), memeLiq - memeLiq / 4);
        assertEq(_liquidity(hostileId), hostileLiq - hostileLiq / 4);
        assertGt(meme.balanceOf(receiver), 0);
        assertGt(hostile.balanceOf(receiver), hostileReceived);
        assertEq(harness.owedTotal(address(burner)), 0);
    }

    /// (g2) The fallback rule needs honest failures to be cheap: a blocked-receiver
    /// failure must use well under FALLBACK_MAX_BPS of SLICE_GAS.
    function test_honestFailureIsCheap() public {
        hostile.setBlocked(receiver, true);
        // Bind as an exit would, then measure one failing attempt directly.
        uint256 g = gasleft();
        try harness.probeBoundSelfSlice{gas: 600_000}(1, 4, receiver, hostileId, 1, 4, receiver, receiver) {
            revert("should fail");
        } catch {}
        uint256 used = g - gasleft();
        emit log_named_uint("failed v4 slice (blocked receiver) gas", used);
        assertLt(used, harness.SLICE_GAS() * harness.FALLBACK_MAX_BPS() / 10_000);
    }

    /// (h) EIP-150 guard: a caller sending too little gas gets a revert, never a silent
    /// skip of slices that would have succeeded with more gas.
    function test_insufficientGasRevertsNotSkips() public {
        (bool ok, bytes memory ret) =
            address(harness).call{gas: 300_000}(abi.encodeCall(harness.inKindExit, (1, 4, receiver)));
        assertFalse(ok);
        assertEq(bytes4(ret), V4PositionsHarness.InsufficientGasForSlice.selector);
        assertEq(_liquidity(memeId), memeLiq);
        assertEq(_liquidity(hostileId), hostileLiq);
    }

    /// (i) Fee-on-transfer + blocked receiver: the IOU is what the vault actually
    /// received (balance delta), not what the pool released.
    function test_feeOnTransferIouIsBalanceDelta() public {
        (uint256 v0, uint256 v1) = harness.positionAmounts(hostileId);
        uint256 released = (hostileKey.currency0 == address(hostile) ? v0 : v1) / 4;
        hostile.setBlocked(receiver, true);
        hostile.setFeeBps(1000); // 10%
        uint256 before = hostile.balanceOf(address(harness));

        harness.inKindExit(1, 4, receiver);

        uint256 received = hostile.balanceOf(address(harness)) - before;
        uint256 iou = harness.owed(receiver, address(hostile));
        assertGt(received, 0);
        assertEq(iou, received);
        assertEq(harness.owedTotal(address(hostile)), received);
        assertApproxEqAbs(iou, released - released / 10, 2);
    }

    /// A swap that stops exactly on the position's lower / upper tick: the view must not
    /// overstate what a full withdraw pays out.
    function test_positionAmountsAtLowerTickBoundary() public {
        uint160 limit = TickMath.getSqrtPriceAtTick(-600);
        _swapIn(key, token0, 10_000e6, limit);
        _assertBoundary(limit, true);
    }

    function test_positionAmountsAtUpperTickBoundary() public {
        uint160 limit = TickMath.getSqrtPriceAtTick(600);
        _swapIn(key, token1, 10_000e6, limit);
        _assertBoundary(limit, false);
    }

    function _assertBoundary(uint160 limit, bool atLower) internal {
        assertEq(_sqrtPrice(key), limit);
        (uint256 v0, uint256 v1) = harness.positionAmounts(memeId);
        // Fully token0 at the lower edge, fully token1 at the upper edge.
        if (atLower) assertEq(v1, 0);
        else assertEq(v0, 0);
        (,, uint256 out0, uint256 out1) = harness.withdraw(memeId, memeLiq, receiver);
        assertLe(v0, out0);
        assertLe(v1, out1);
    }

    /// Gas bound: a full-cap (25 positions, distinct pools) in-kind exit with cold storage.
    function test_inKindExitGasAtMaxPositions() public {
        uint256 cap = V4Positions.MAX_POSITIONS;
        address[] memory touched = new address[](cap + 6);
        uint256 k;
        // setUp already opened 2 positions; fill the rest with fresh USDC/TOKEN pools.
        for (uint256 i = harness.count(); i < cap; i++) {
            MockERC20 t = new MockERC20("T", "T");
            _openUsdcPool(address(t), 1_000e6);
            touched[k++] = address(t);
        }
        assertEq(harness.count(), cap);
        touched[k++] = address(harness);
        touched[k++] = address(posm);
        touched[k++] = v4.poolManager;
        touched[k++] = address(usdc);
        touched[k++] = address(meme);
        touched[k++] = address(hostile);
        // Measure a cold exit, as in a fresh transaction.
        for (uint256 i = 0; i < k; i++) {
            vm.cool(touched[i]);
        }

        uint256 g = gasleft();
        harness.inKindExit(1, 4, receiver);
        uint256 used = g - gasleft();
        emit log_named_uint("inKindExit gas (25 v4 positions)", used);
        assertLt(used, 10_000_000);
        // Every slice really executed.
        assertGt(usdc.balanceOf(receiver), 0);
        assertEq(_liquidity(memeId), memeLiq - memeLiq / 4);
    }
}
