// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Shapes} from "../../src/libraries/Shapes.sol";

/// @dev Exposes the internal library so reverts can be asserted.
contract ShapesHarness {
    function layout(Shapes.Spec memory spec, int24 tick, int24 spacing, bool usdcIs0, uint256 u, uint256 t)
        external
        pure
        returns (Shapes.Range[] memory)
    {
        return Shapes.layout(spec, tick, spacing, usdcIs0, u, t);
    }
}

contract ShapesTest is Test {
    ShapesHarness internal h = new ShapesHarness();

    function test_spotBothSpansThePrice() public view {
        Shapes.Range[] memory r =
            h.layout(Shapes.Spec(Shapes.SPOT, Shapes.BOTH, 3, 120), 0, 60, true, 300, 300);
        assertEq(r[0].tickLower, -120);
        assertEq(r[0].tickUpper, 0);
        assertEq(r[1].tickLower, 0);
        assertEq(r[2].tickUpper, 240);
        // USDC = token0 is held above the price: ranges 1 (contains it) and 2.
        assertEq(r[0].usdc, 0);
        assertEq(r[1].usdc, 150);
        assertEq(r[2].usdc, 150);
        // The token = token1 is held below: ranges 0 and 1.
        assertEq(r[0].token, 150);
        assertEq(r[1].token, 150);
        assertEq(r[2].token, 0);
    }

    function test_curveIsPeakedAtThePrice() public view {
        // n = 5 one-sided bid below the price (USDC = token1): weights by distance 5,4,3,2,1.
        Shapes.Range[] memory r =
            h.layout(Shapes.Spec(Shapes.CURVE, Shapes.USDC_ONLY, 5, 60), 0, 60, false, 1500, 0);
        assertEq(r[4].tickUpper, 0); // nearest range ends at the price
        assertEq(r[4].usdc, 500);
        assertEq(r[3].usdc, 400);
        assertEq(r[0].usdc, 100);
    }

    function test_bidAskRisesTowardTheEdges() public view {
        Shapes.Range[] memory r =
            h.layout(Shapes.Spec(Shapes.BIDASK, Shapes.USDC_ONLY, 4, 60), 0, 60, true, 1000, 0);
        assertEq(r[0].tickLower, 60); // strictly above the price
        assertEq(r[0].usdc, 100); // weights 1,2,3,4
        assertEq(r[3].usdc, 400);
    }

    function test_tokenOnlyAskSitsOnTheTokenSide() public view {
        // USDC = token0 (above), so the token-only ask sits below the price.
        Shapes.Range[] memory r =
            h.layout(Shapes.Spec(Shapes.SPOT, Shapes.TOKEN_ONLY, 2, 60), 30, 60, true, 0, 100);
        assertEq(r[1].tickUpper, 0);
        assertEq(r[0].token + r[1].token, 100);
    }

    function test_invalidSpecsRevert() public {
        vm.expectRevert(Shapes.InvalidShape.selector);
        h.layout(Shapes.Spec(3, Shapes.BOTH, 1, 60), 0, 60, true, 1, 1);
        vm.expectRevert(Shapes.InvalidSide.selector);
        h.layout(Shapes.Spec(Shapes.SPOT, 3, 1, 60), 0, 60, true, 1, 1);
        vm.expectRevert(Shapes.InvalidRangeCount.selector);
        h.layout(Shapes.Spec(Shapes.SPOT, Shapes.BOTH, 0, 60), 0, 60, true, 1, 1);
        vm.expectRevert(Shapes.InvalidWidth.selector);
        h.layout(Shapes.Spec(Shapes.SPOT, Shapes.BOTH, 1, 90), 0, 60, true, 1, 1);
        vm.expectRevert(Shapes.OutOfTickBounds.selector);
        h.layout(Shapes.Spec(Shapes.SPOT, Shapes.USDC_ONLY, 2, 60), 887_220, 60, true, 1, 1);
    }

    /// @dev For any price, spacing, count and width: ranges are aligned and contiguous;
    /// one-sided ranges never contain the price and sit on the right side; BOTH has exactly
    /// one range containing it; each token's split is complete up to rounding dust and
    /// never exceeds the amount.
    function testFuzz_layoutInvariants(
        int24 tick,
        uint8 spacingSel,
        uint8 n,
        uint8 widthMul,
        uint8 shapeSel,
        uint8 side,
        bool usdcIs0,
        uint128 usdcAmt,
        uint128 tokenAmt
    ) public view {
        int24 spacing = [int24(1), 10, 60, 200][spacingSel % 4];
        n = uint8(bound(n, 1, 10));
        int24 width = int24(uint24(bound(widthMul, 1, 50))) * spacing;
        tick = int24(bound(tick, -800_000, 800_000));
        uint8 shape = [Shapes.SPOT, Shapes.CURVE, Shapes.BIDASK][shapeSel % 3];
        side = side % 3;

        Shapes.Range[] memory r =
            h.layout(Shapes.Spec(shape, side, n, width), tick, spacing, usdcIs0, usdcAmt, tokenAmt);

        uint256 usdcSum;
        uint256 tokenSum;
        uint256 containing;
        bool anyUsdc;
        bool anyToken;
        for (uint256 i = 0; i < n; i++) {
            assertEq(r[i].tickLower % spacing, 0);
            assertEq(r[i].tickUpper - r[i].tickLower, width);
            if (i > 0) assertEq(r[i].tickLower, r[i - 1].tickUpper);
            bool contains = r[i].tickLower <= tick && tick < r[i].tickUpper;
            if (contains) containing++;
            bool holds0 = r[i].tickLower > tick || contains;
            bool holds1 = r[i].tickUpper <= tick || contains;
            bool holdsUsdc = usdcIs0 ? holds0 : holds1;
            bool holdsToken = usdcIs0 ? holds1 : holds0;
            if (!holdsUsdc) assertEq(r[i].usdc, 0);
            if (!holdsToken) assertEq(r[i].token, 0);
            anyUsdc = anyUsdc || holdsUsdc;
            anyToken = anyToken || holdsToken;
            if (side == Shapes.USDC_ONLY) assertFalse(holdsToken);
            if (side == Shapes.TOKEN_ONLY) assertFalse(holdsUsdc);
            usdcSum += r[i].usdc;
            tokenSum += r[i].token;
        }
        if (side == Shapes.BOTH) assertEq(containing, 1);
        else assertEq(containing, 0);
        assertLe(usdcSum, usdcAmt);
        assertLe(tokenSum, tokenAmt);
        if (anyUsdc) assertGe(usdcSum + n, usdcAmt);
        if (anyToken) assertGe(tokenSum + n, tokenAmt);
    }
}
