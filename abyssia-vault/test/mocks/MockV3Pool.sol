// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IUniswapV3Pool} from "../../src/interfaces/IUniswapV3Pool.sol";

/// @dev Stand-in for a v3 pool: "initialized" once it has a non-zero sqrtPrice.
contract MockV3Pool is IUniswapV3Pool {
    uint160 public sqrtPrice;

    function setSqrtPrice(uint160 p) external {
        sqrtPrice = p;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPrice, 0, 0, 0, 0, 0, true);
    }

    // Unused by the registry tests that use this mock.
    function liquidity() external pure returns (uint128) {
        return 0;
    }
}
