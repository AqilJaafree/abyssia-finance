// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {V3TestBase} from "./V3TestBase.sol";
import {V3PositionsHarness} from "./V3PositionsHarness.sol";
import {V3Positions} from "../../src/v3/V3Positions.sol";
import {IUniswapV3Pool} from "../../src/interfaces/IUniswapV3Pool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFreezableERC20} from "../mocks/MockFreezableERC20.sol";

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
        // The MEME position still paid the receiver directly.
        assertGt(meme.balanceOf(receiver), 0);
        uint256 usdcDirect = usdc.balanceOf(receiver);

        vm.startPrank(receiver);
        harness.claimOwed(address(usdc));
        assertEq(usdc.balanceOf(receiver), usdcDirect + owedUsdc);
        assertEq(harness.owed(receiver, address(usdc)), 0);

        vm.expectRevert(abi.encodeWithSelector(MockFreezableERC20.Blocked.selector, receiver));
        harness.claimOwed(address(hostile));
        assertEq(harness.owed(receiver, address(hostile)), owedHostile);
        vm.stopPrank();

        hostile.setBlocked(receiver, false);
        vm.prank(receiver);
        harness.claimOwed(address(hostile));
        assertEq(hostile.balanceOf(receiver), owedHostile);
        assertEq(harness.owed(receiver, address(hostile)), 0);
    }

    /// (c) withdrawSlice rejects a zero supply and shares above supply.
    function test_withdrawSliceRejectsInvalidSlice() public {
        vm.startPrank(address(harness));
        vm.expectRevert(V3Positions.InvalidSlice.selector);
        harness.sliceTo(memeId, 0, 0, receiver);
        vm.expectRevert(V3Positions.InvalidSlice.selector);
        harness.sliceTo(memeId, 5, 4, receiver);
        vm.expectRevert(abi.encodeWithSelector(V3Positions.UnknownPosition.selector, 999));
        harness.sliceTo(999, 1, 4, receiver);
        vm.stopPrank();
    }

    /// (d) The self-call entrypoint is closed to everyone but the vault itself.
    function test_sliceToRejectsExternalCallers() public {
        vm.expectRevert(V3PositionsHarness.OnlySelf.selector);
        harness.sliceTo(memeId, 1, 4, receiver);
        vm.prank(receiver);
        vm.expectRevert(V3PositionsHarness.OnlySelf.selector);
        harness.sliceTo(memeId, 1, 4, receiver);
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
}
