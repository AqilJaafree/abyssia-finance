// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// @dev Base for tests that fork Arc testnet (chain 5042002). Skipped when
/// ARC_TESTNET_RPC_URL is unset, so `forge test` stays offline-friendly.
abstract contract ArcTestnetFork is Test {
    uint256 internal constant ARC_TESTNET_CHAIN_ID = 5042002;

    // Arc testnet (verified 2026-10-14): v4 lives at the same addresses as mainnet.
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    address internal constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant V4_STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;

    string internal constant V3_FACTORY_ARTIFACT =
        "node_modules/@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json";

    bool internal forked;

    function _fork() internal {
        string memory url = vm.envOr("ARC_TESTNET_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        assertEq(block.chainid, ARC_TESTNET_CHAIN_ID, "not Arc testnet");
        forked = true;
    }

    /// @dev Uniswap v3 is not deployed on Arc testnet, so tests deploy the official
    /// v3-core factory bytecode (npm package uniswap v3-core 1.0.1) into the fork.
    function _deployV3Factory() internal returns (address factory) {
        bytes memory code = vm.parseJsonBytes(vm.readFile(V3_FACTORY_ARTIFACT), ".bytecode");
        assembly {
            factory := create(0, add(code, 0x20), mload(code))
        }
        require(factory != address(0), "v3 factory deploy failed");
    }
}
