// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "../types/PoolKey.sol";

/// @notice Minimal Uniswap v4 PoolManager surface (v4-core 1.0.2) for exact-input swaps.
/// `swap` returns a BalanceDelta: amount0 in the upper 128 bits, amount1 in the lower,
/// negative = owed by the caller.
interface IV4PoolManager {
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}
