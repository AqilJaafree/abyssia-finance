// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IUniswapV3Pool} from "../interfaces/IUniswapV3Pool.sol";

/// @title PoolOracle
/// @notice Uniswap v3's built-in TWAP: the time-weighted average tick over a window. A pool
/// only answers for windows its stored observations cover; raise its capacity first with
/// `increaseObservationCardinalityNext` and let the window fill.
library PoolOracle {
    error TwapUnavailable(address pool, uint32 window);
    error ObservationCapacityTooLow(address pool, uint16 capacity, uint16 required);

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

    /// @notice The TWAP over `window` seconds, only if the pool keeps at least `minCapacity`
    /// observations. The capacity floor stops anyone from making the TWAP unavailable by
    /// overwriting a small ring of observations with a swap every block: it must cover the
    /// window at the chain's block time (the vault enforces that). It checks the capacity the
    /// pool has committed to (`observationCardinalityNext`): the ring grows into it before
    /// any slot is overwritten.
    function checkedTwapTick(address pool, uint32 window, uint16 minCapacity) internal view returns (int24) {
        (,,,, uint16 capacity,,) = IUniswapV3Pool(pool).slot0();
        if (capacity < minCapacity) revert ObservationCapacityTooLow(pool, capacity, minCapacity);
        return twapTick(pool, window);
    }
}
