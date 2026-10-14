// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title PoolPrice
/// @notice Converts between USDC and a pool's other token at a Uniswap sqrtPriceX96
/// (sqrt(token1 / token0) in raw base units, Q64.96). Rounds down.
library PoolPrice {
    uint256 internal constant Q96 = 1 << 96;

    /// @notice USDC value of `amount` of the pool's non-USDC token.
    function tokenToUsdc(uint256 amount, uint160 sqrtPriceX96, bool usdcIsToken0)
        internal
        pure
        returns (uint256)
    {
        if (amount == 0) return 0;
        // USDC = token0: USDC per token1 = 1 / P = 2^192 / sqrtP^2.
        if (usdcIsToken0) return Math.mulDiv(Math.mulDiv(amount, Q96, sqrtPriceX96), Q96, sqrtPriceX96);
        // USDC = token1: USDC per token0 = P = sqrtP^2 / 2^192.
        return Math.mulDiv(Math.mulDiv(amount, sqrtPriceX96, Q96), sqrtPriceX96, Q96);
    }

    /// @notice Amount of the pool's non-USDC token worth `amount` USDC.
    function usdcToToken(uint256 amount, uint160 sqrtPriceX96, bool usdcIsToken0)
        internal
        pure
        returns (uint256)
    {
        if (amount == 0) return 0;
        if (usdcIsToken0) return Math.mulDiv(Math.mulDiv(amount, sqrtPriceX96, Q96), sqrtPriceX96, Q96);
        return Math.mulDiv(Math.mulDiv(amount, Q96, sqrtPriceX96), Q96, sqrtPriceX96);
    }
}
