// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {V3TestBase} from "./V3TestBase.sol";
import {V3PositionsHarness} from "./V3PositionsHarness.sol";
import {V3Positions} from "../../src/v3/V3Positions.sol";
import {IUniswapV3Pool} from "../../src/interfaces/IUniswapV3Pool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFreezableERC20} from "../mocks/MockFreezableERC20.sol";
import {MockGasBurnerERC20} from "../mocks/MockGasBurnerERC20.sol";
import {MockLyingERC20} from "../mocks/MockLyingERC20.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev The per-position in-kind exit pattern (harness `inKindExit`) against tokens
/// that refuse transfers, plus slice validation, tick-boundary valuation and the
/// gas bound at MAX_POSITIONS.
contract V3PositionsInKindTest is V3TestBase {
    address internal receiver = makeAddr("receiver");
    MockFreezableERC20 internal hostile;
    uint256 internal memeId;
    uint128 internal memeLiq;
    uint256 internal hostileId;
    uint128 internal hostileLiq;

    event SliceSkipped(uint256 indexed tokenId);

    function setUp() public override {
        super.setUp();
        hostile = new MockFreezableERC20("Hostile", "HOSTILE");
        (memeId, memeLiq) = _openInRange(1_000e6); // USDC/MEME
        (hostileId, hostileLiq) = _openUsdcPool(address(hostile), 1_000e6); // USDC/HOSTILE
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
        assertGt(meme.balanceOf(receiver), 0);
        // HOSTILE position untouched, no USDC from it, no IOUs.
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

    /// (c) withdrawSlice rejects a zero supply and shares above supply (reached through a
    /// correctly bound self-call).
    function test_withdrawSliceRejectsInvalidSlice() public {
        vm.expectRevert(V3Positions.InvalidSlice.selector);
        harness.probeBoundSelfSlice(0, 0, receiver, memeId, 0, 0, receiver, receiver);
        vm.expectRevert(V3Positions.InvalidSlice.selector);
        harness.probeBoundSelfSlice(5, 4, receiver, memeId, 5, 4, receiver, receiver);
        vm.expectRevert(abi.encodeWithSelector(V3Positions.UnknownPosition.selector, 999));
        harness.probeBoundSelfSlice(1, 4, receiver, 999, 1, 4, receiver, receiver);
    }

    /// (d) The self-call entrypoint is closed to everyone but the vault itself.
    function test_sliceToRejectsExternalCallers() public {
        vm.expectRevert(V3PositionsHarness.OnlySelf.selector);
        harness.sliceTo(memeId, 1, 4, receiver, receiver);
        vm.prank(receiver);
        vm.expectRevert(V3PositionsHarness.OnlySelf.selector);
        harness.sliceTo(memeId, 1, 4, receiver, receiver);
    }

    /// (e) A self-call outside any exit has no binding and is rejected.
    function test_sliceToRejectsUnboundSelfCall() public {
        vm.expectRevert(V3PositionsHarness.UnboundSlice.selector);
        harness.probeUnboundSelfSlice(memeId, 1, 4, receiver);
        assertEq(_liquidity(memeId), memeLiq);
    }

    /// (f) A self-call whose shares / supply / receiver differ from the exit in progress,
    /// or that targets a third-party recipient, is rejected.
    function test_sliceToRejectsMismatchedBinding() public {
        address other = makeAddr("other");
        vm.expectRevert(V3PositionsHarness.UnboundSlice.selector);
        harness.probeBoundSelfSlice(1, 4, receiver, memeId, 2, 4, receiver, receiver); // shares
        vm.expectRevert(V3PositionsHarness.UnboundSlice.selector);
        harness.probeBoundSelfSlice(1, 4, receiver, memeId, 1, 2, receiver, receiver); // supply
        vm.expectRevert(V3PositionsHarness.UnboundSlice.selector);
        harness.probeBoundSelfSlice(1, 4, receiver, memeId, 1, 4, other, other); // receiver
        vm.expectRevert(V3PositionsHarness.UnboundSlice.selector);
        harness.probeBoundSelfSlice(1, 4, receiver, memeId, 1, 4, receiver, other); // recipient
        assertEq(_liquidity(memeId), memeLiq);
        // Sanity: a matching binding passes, to the receiver or to the vault itself.
        harness.probeBoundSelfSlice(1, 4, receiver, memeId, 1, 4, receiver, receiver);
        harness.probeBoundSelfSlice(1, 4, receiver, memeId, 1, 4, receiver, address(harness));
        assertLt(_liquidity(memeId), memeLiq);
    }

    /// (g) A token that burns all gas on transfer: its slice attempt is capped at
    /// SLICE_GAS, detected as out-of-gas (no fallback attempt), skipped, and every other
    /// position still pays out.
    function test_gasBurnerIsSkippedWithBoundedGas() public {
        MockGasBurnerERC20 burner = new MockGasBurnerERC20("Burner", "BURN");
        (uint256 burnerId, uint128 burnerLiq) = _openUsdcPool(address(burner), 1_000e6);
        burner.setBurn(true);
        uint256 hostileReceived = hostile.balanceOf(receiver);

        vm.expectEmit(true, false, false, false, address(harness));
        emit SliceSkipped(burnerId);
        // The OOG skip means the vault-recipient fallback is never attempted.
        vm.expectCall(
            address(harness),
            abi.encodeCall(harness.sliceTo, (burnerId, 1, 4, receiver, address(harness))),
            uint64(0)
        );
        uint256 g = gasleft();
        harness.inKindExit{gas: 20_000_000}(1, 4, receiver);
        uint256 used = g - gasleft();
        emit log_named_uint("inKindExit gas (3 positions, 1 gas burner)", used);

        // Uncapped, the burner alone would take 63/64 of the 20M forwarded (~19.7M).
        // Capped: the burner costs one SLICE_GAS (500k) + call overhead, the two honest
        // slices ~200-250k each. 12.5M is the worst case of MAX_POSITIONS (25) burners at
        // SLICE_GAS each; this 3-position exit must also stay under a tight
        // SLICE_GAS + 2 x 400k bound, which a second (fallback) burner attempt would break.
        assertLt(used, 12_500_000);
        assertLt(used, harness.SLICE_GAS() + 2 * 400_000);
        // Burner position untouched; the others paid the receiver.
        assertEq(_liquidity(burnerId), burnerLiq);
        assertEq(_liquidity(memeId), memeLiq - memeLiq / 4);
        assertEq(_liquidity(hostileId), hostileLiq - hostileLiq / 4);
        assertGt(meme.balanceOf(receiver), 0);
        assertGt(hostile.balanceOf(receiver), hostileReceived);
        assertEq(harness.owedTotal(address(burner)), 0);
    }

    /// (h) EIP-150 guard: a caller sending too little gas gets a revert, never a silent
    /// skip of slices that would have succeeded with more gas.
    function test_insufficientGasRevertsNotSkips() public {
        (bool ok, bytes memory ret) =
            address(harness).call{gas: 300_000}(abi.encodeCall(harness.inKindExit, (1, 4, receiver)));
        assertFalse(ok);
        assertEq(bytes4(ret), V3PositionsHarness.InsufficientGasForSlice.selector);
        assertEq(_liquidity(memeId), memeLiq);
        assertEq(_liquidity(hostileId), hostileLiq);
    }

    /// (i) Fee-on-transfer + blocked receiver: the IOU is what the vault actually
    /// received (balance delta), not what the position manager reported collecting.
    function test_feeOnTransferIouIsBalanceDelta() public {
        hostile.setBlocked(receiver, true);
        hostile.setFeeBps(1000); // 10%
        uint256 before = hostile.balanceOf(address(harness));

        vm.recordLogs();
        harness.inKindExit(1, 4, receiver);
        uint256 reported = _reportedToVault(hostileId);

        uint256 received = hostile.balanceOf(address(harness)) - before;
        uint256 iou = harness.owed(receiver, address(hostile));
        assertGt(received, 0);
        assertEq(iou, received);
        assertEq(harness.owedTotal(address(hostile)), received);
        assertLt(iou, reported);
        assertApproxEqAbs(iou, reported - reported / 10, 1);
    }

    /// @dev Amount of HOSTILE the position manager reported sending to the vault for
    /// `tokenId` (from the library's V3LiquidityWithdrawn event).
    function _reportedToVault(uint256 tokenId) internal returns (uint256) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(harness)
                    && logs[i].topics[0] == V3Positions.V3LiquidityWithdrawn.selector
                    && uint256(logs[i].topics[1]) == tokenId
            ) {
                (, address recipient, uint256 a0, uint256 a1) =
                    abi.decode(logs[i].data, (uint128, address, uint256, uint256));
                if (recipient == address(harness)) return address(hostile) < address(usdc) ? a0 : a1;
            }
        }
        revert("no vault-recipient withdraw");
    }

    /// A swap that stops exactly on the position's lower / upper tick: the view must not
    /// overstate what a full withdraw pays out.
    function test_positionAmountsAtLowerTickBoundary() public {
        uint160 limit = TickMath.getSqrtPriceAtTick(-600);
        _swapVia(v3.swapRouter02, token0, token1, 10_000e6, limit);
        _assertBoundary(limit, true);
    }

    function test_positionAmountsAtUpperTickBoundary() public {
        uint160 limit = TickMath.getSqrtPriceAtTick(600);
        _swapVia(v3.swapRouter02, token1, token0, 10_000e6, limit);
        _assertBoundary(limit, false);
    }

    function _assertBoundary(uint160 limit, bool atLower) internal {
        (uint160 sqrtP,,,,,,) = IUniswapV3Pool(pool).slot0();
        assertEq(sqrtP, limit);
        (uint256 v0, uint256 v1) = harness.positionAmounts(memeId);
        // Fully token0 at the lower edge, fully token1 at the upper edge.
        if (atLower) assertEq(v1, 0);
        else assertEq(v0, 0);
        (uint256 out0, uint256 out1) = harness.withdraw(memeId, memeLiq, receiver);
        assertLe(v0, out0);
        assertLe(v1, out1);
    }

    /// Gas bound: a full-cap (25 positions, distinct pools) in-kind exit with cold storage.
    function test_inKindExitGasAtMaxPositions() public {
        uint256 cap = V3Positions.MAX_POSITIONS;
        address[] memory touched = new address[](3 * cap + 4);
        uint256 k;
        // setUp already opened 2 positions; fill the rest with fresh USDC/TOKEN pools.
        for (uint256 i = harness.count(); i < cap; i++) {
            MockERC20 t = new MockERC20("T", "T");
            _openUsdcPool(address(t), 1_000e6);
            touched[k++] = address(t);
        }
        assertEq(harness.count(), cap);
        for (uint256 i = 0; i < cap; i++) {
            (,, address t0, address t1, uint24 fee,,,,,,,) = npm.positions(harness.tokenIdAt(i));
            (bool ok, bytes memory ret) =
                v3.factory.staticcall(abi.encodeWithSignature("getPool(address,address,uint24)", t0, t1, fee));
            require(ok);
            touched[k++] = abi.decode(ret, (address));
        }
        touched[k++] = address(harness);
        touched[k++] = address(npm);
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
        emit log_named_uint("inKindExit gas (25 positions)", used);
        assertLt(used, 10_000_000);
        // Every slice really executed.
        assertGt(usdc.balanceOf(receiver), 0);
        assertEq(_liquidity(memeId), memeLiq - memeLiq / 4);
    }

    /// (j) Blocked receiver + a token that lies in `balanceOf`: the IOU delta is absurd.
    /// The first exit records it; the second would overflow the bookkeeping. Because the
    /// IOU is recorded inside the gas-capped self-call, that only skips the liar's slice:
    /// the exit itself never reverts and every other position still pays out.
    function test_lyingBalanceOfCannotBrickExit() public {
        MockLyingERC20 liar = new MockLyingERC20();
        (uint256 liarId,) = _openUsdcPool(address(liar), 1_000e6);
        liar.setBlocked(receiver, true);

        liar.arm(address(harness));
        harness.inKindExit(1, 100, receiver);
        assertEq(harness.owedTotal(address(liar)), type(uint256).max);

        liar.arm(address(harness));
        uint128 memeBefore = _liquidity(memeId);
        uint128 liarBefore = _liquidity(liarId);
        vm.expectEmit(true, false, false, false, address(harness));
        emit SliceSkipped(liarId);
        harness.inKindExit(1, 100, receiver);
        assertEq(_liquidity(memeId), memeBefore - memeBefore / 100);
        assertEq(_liquidity(liarId), liarBefore);
    }

    /// (k) Receivers that would swallow a slice are rejected up front.
    function test_invalidReceiversRejected() public {
        address[3] memory bad = [address(0), address(harness), address(npm)];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.expectRevert(V3PositionsHarness.InvalidReceiver.selector);
            harness.inKindExit(1, 4, bad[i]);
        }
        assertEq(_liquidity(memeId), memeLiq);
    }
}
