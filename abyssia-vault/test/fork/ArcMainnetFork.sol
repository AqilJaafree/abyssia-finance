// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// @dev Base for READ-ONLY-STYLE tests against a fork of Arc mainnet (chain 5042):
/// nothing is broadcast; the fork just provides real deployed bytecode. Skipped
/// when ARC_MAINNET_RPC_URL is unset. Not pinned to a block: Arc mainnet RPCs
/// prune historical state.
abstract contract ArcMainnetFork is Test {
    uint256 internal constant ARC_MAINNET_CHAIN_ID = 5042;

    // Uniswap on Arc mainnet (verified 2026-10-13 against Uniswap's deployments manifest,
    // sdk-core ARC_ADDRESSES, and on-chain wiring).
    address internal constant V3_FACTORY = 0xf0db7b58379503491d857dB50AC9ece64c653918;
    address internal constant V3_POSITION_MANAGER = 0x39654A85A4C05127f5Fd6ED22CAeC077A0fB1377;
    address internal constant V3_SWAP_ROUTER_02 = 0x53BF6B0684Ec7eF91e1387Da3D1a1769bC5A6F77;

    bool internal forked;

    function _forkMainnet() internal {
        string memory url = vm.envOr("ARC_MAINNET_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        assertEq(block.chainid, ARC_MAINNET_CHAIN_ID, "not Arc mainnet");
        forked = true;
    }
}
