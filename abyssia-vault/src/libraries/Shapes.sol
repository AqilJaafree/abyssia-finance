// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title Shapes
/// @notice Turns a liquidity shape into N contiguous tick ranges with an amount of USDC and
/// of the pool's token for each, in the spirit of Meteora DLMM's Spot / Curve / Bid-Ask.
/// Pure math; the vault opens the ranges.
/// @dev Placement relative to the pool's current tick:
///  - BOTH: N ranges spanning the price, centred on it (one range contains the price).
///  - USDC_ONLY: N ranges entirely on USDC's side of the price (a bid: they hold only USDC
///    until the price moves into them).
///  - TOKEN_ONLY: N ranges entirely on the token's side (an ask).
/// Weights by distance d (in ranges) from the price: Spot 1; Curve N - d (peaked at the
/// price); Bid-Ask d + 1 (rising toward the edges). Each token is split, by weight, over the
/// ranges that hold it; rounding dust stays with the vault.
library Shapes {
    uint8 internal constant SPOT = 1;
    uint8 internal constant CURVE = 2;
    uint8 internal constant BIDASK = 4;

    uint8 internal constant BOTH = 0;
    uint8 internal constant USDC_ONLY = 1;
    uint8 internal constant TOKEN_ONLY = 2;

    struct Range {
        int24 tickLower;
        int24 tickUpper;
        uint256 usdc;
        uint256 token;
    }

    struct Spec {
        uint8 shape;
        uint8 side;
        uint8 ranges;
        int24 width;
    }

    error InvalidShape();
    error InvalidSide();
    error InvalidRangeCount();
    error InvalidWidth();
    error OutOfTickBounds();

    /// @param tick the pool's current tick
    /// @param spacing the pool's tick spacing
    /// @param usdcIsToken0 USDC is the pool's token0 (token0 is held ABOVE the price)
    function layout(
        Spec memory spec,
        int24 tick,
        int24 spacing,
        bool usdcIsToken0,
        uint256 usdcAmount,
        uint256 tokenAmount
    ) internal pure returns (Range[] memory out) {
        if (spec.shape != SPOT && spec.shape != CURVE && spec.shape != BIDASK) {
            revert InvalidShape();
        }
        if (spec.side > TOKEN_ONLY) revert InvalidSide();
        if (spec.ranges == 0) revert InvalidRangeCount();
        if (spec.width <= 0 || spec.width % spacing != 0) revert InvalidWidth();

        uint256 n = spec.ranges;
        out = new Range[](n);
        int24 base = _floor(tick, spacing); // aligned, <= tick
        int256 w = spec.width;

        // Lower tick of range 0. BOTH: range c = n / 2 starts at the aligned tick, so it
        // contains the price (base <= tick < base + spacing <= base + width).
        int256 start;
        bool above; // one-sided ranges sit above the price (else below)
        uint256 c = n / 2;
        if (spec.side == BOTH) {
            start = int256(base) - int256(c) * w;
        } else {
            // USDC (token0 if usdcIsToken0) is held above the price.
            above = (spec.side == USDC_ONLY) == usdcIsToken0;
            // Strictly above: first range starts one spacing past the aligned tick, so the
            // current tick is never inside it. Below: last range ends at the aligned tick
            // (<= tick), which a v3/v4 position treats as out of range.
            start = above ? int256(base) + spacing : int256(base) - int256(n) * w;
        }

        uint256[] memory weights = new uint256[](n);
        uint256 usdcWeight;
        uint256 tokenWeight;
        for (uint256 i = 0; i < n; i++) {
            int256 lower = start + int256(i) * w;
            int256 upper = lower + w;
            if (lower < TickMath.MIN_TICK || upper > TickMath.MAX_TICK) revert OutOfTickBounds();
            out[i].tickLower = int24(lower);
            out[i].tickUpper = int24(upper);
            // Distance (in ranges) from the price.
            uint256 d = spec.side == BOTH ? (i > c ? i - c : c - i) : above ? i : n - 1 - i;
            uint256 wt = spec.shape == SPOT ? 1 : spec.shape == CURVE ? n - d : d + 1;
            weights[i] = wt;
            (bool holdsUsdc, bool holdsToken) = _holds(lower, upper, tick, usdcIsToken0);
            if (holdsUsdc) usdcWeight += wt;
            if (holdsToken) tokenWeight += wt;
        }
        for (uint256 i = 0; i < n; i++) {
            (bool holdsUsdc, bool holdsToken) = _holds(out[i].tickLower, out[i].tickUpper, tick, usdcIsToken0);
            if (holdsUsdc) out[i].usdc = usdcAmount * weights[i] / usdcWeight;
            if (holdsToken) out[i].token = tokenAmount * weights[i] / tokenWeight;
        }
    }

    /// @dev Which tokens a range holds at `tick`: token1 below the price (upper <= tick),
    /// token0 above it (lower > tick), both when it contains the price.
    function _holds(int256 lower, int256 upper, int24 tick, bool usdcIsToken0)
        private
        pure
        returns (bool holdsUsdc, bool holdsToken)
    {
        bool holds0 = lower > tick || (lower <= tick && tick < upper);
        bool holds1 = upper <= tick || (lower <= tick && tick < upper);
        return usdcIsToken0 ? (holds0, holds1) : (holds1, holds0);
    }

    function _floor(int24 tick, int24 spacing) private pure returns (int24) {
        return int24(_floor256(tick, spacing));
    }

    /// @dev Round down to a multiple of `spacing` (toward negative infinity).
    function _floor256(int256 x, int256 spacing) private pure returns (int256 r) {
        r = x / spacing * spacing;
        if (x < 0 && r != x) r -= spacing;
    }
}
