// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IStateView} from "../../src/interfaces/IStateView.sol";

/// @dev Stand-in for v4 StateView: a pool "exists" once it has a non-zero sqrtPrice.
contract MockStateView is IStateView {
    mapping(bytes32 => uint160) public sqrtPrice;

    function setSqrtPrice(bytes32 poolId, uint160 p) external {
        sqrtPrice[poolId] = p;
    }

    function getSlot0(bytes32 poolId) external view returns (uint160, int24, uint24, uint24) {
        return (sqrtPrice[poolId], 0, 0, 0);
    }

    // Unused by the registry tests that use this mock.
    function getLiquidity(bytes32) external pure returns (uint128) {
        return 0;
    }

    function getPositionInfo(bytes32, address, int24, int24, bytes32)
        external
        pure
        returns (uint128, uint256, uint256)
    {
        return (0, 0, 0);
    }

    function getFeeGrowthInside(bytes32, int24, int24) external pure returns (uint256, uint256) {
        return (0, 0);
    }
}
