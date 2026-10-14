// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IUniswapV3Pool} from "../interfaces/IUniswapV3Pool.sol";

/// @title PoolOracle
/// @notice Uniswap v3's built-in TWAP: the time-weighted average tick over a window, and a
/// guard that the pool's current tick is near it. A pool only answers for windows its
/// stored observations cover; raise its capacity first with
/// `increaseObservationCardinalityNext` and let the window fill.
library PoolOracle {
    error TwapUnavailable(address pool, uint32 window);
    error PriceOffTwap(int24 tick, int24 twapTick);

    /// @notice Arithmetic-mean tick over the last `window` seconds (rounded toward negative
    /// infinity, as Uniswap's OracleLibrary does). Reverts TwapUnavailable if the pool's
    /// observations do not reach back that far.
    function twapTick(address pool, uint32 window) internal view returns (int24 t) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        try IUniswapV3Pool(pool).observe(secondsAgos) returns (int56[] memory cumulatives, uint160[] memory) {
            int56 delta = cumulatives[1] - cumulatives[0];
            int56 w = int56(uint56(window));
            t = int24(delta / w);
            if (delta < 0 && delta % w != 0) t--;
        } catch {
            revert TwapUnavailable(pool, window);
        }
    }

    /// @notice Revert unless the pool's current tick is within `maxDeviation` ticks of its
    /// TWAP over `window` seconds (1 tick ~ 0.01% in price).
    function requireNearTwap(address pool, uint32 window, int24 maxDeviation) internal view {
        (, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        int24 avg = twapTick(pool, window);
        int24 dev = tick > avg ? tick - avg : avg - tick;
        if (dev > maxDeviation) revert PriceOffTwap(tick, avg);
    }
}
