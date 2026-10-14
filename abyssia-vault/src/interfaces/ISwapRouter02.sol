// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal Uniswap SwapRouter02 surface (swap-router-contracts 1.3.1). Unlike the
/// v1 SwapRouter, ExactInputSingleParams has no `deadline` field.
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}
