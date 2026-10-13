// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IUniswapV3Factory} from "../../src/interfaces/IUniswapV3Factory.sol";

/// @dev Stand-in for the v3 factory: returns whatever pool was registered for (t0, t1, fee).
contract MockV3Factory is IUniswapV3Factory {
    mapping(bytes32 => address) internal pools;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pools[keccak256(abi.encode(t0, t1, fee))] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return pools[keccak256(abi.encode(t0, t1, fee))];
    }
}
