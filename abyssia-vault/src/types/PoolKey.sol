// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice ABI-compatible mirror of Uniswap v4's PoolKey (Currency and IHooks
/// are address wrappers, so the encoding is identical). Avoids depending on v4-core.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

library PoolKeyLib {
    /// @notice Same as v4's PoolIdLibrary.toId: keccak256 over the 5 static words.
    function toId(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }
}
