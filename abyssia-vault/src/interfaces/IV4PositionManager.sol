// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "../types/PoolKey.sol";

/// @notice Minimal Uniswap v4 PositionManager surface (v4-periphery 1.0.3). `PositionInfo`
/// is a uint256 user type upstream, so it is ABI-identical to the uint256 used here.
interface IV4PositionManager {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, uint256 info);
    function ownerOf(uint256 tokenId) external view returns (address);
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
}
