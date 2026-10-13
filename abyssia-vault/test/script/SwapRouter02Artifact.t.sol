// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// @dev Pins the vendored SwapRouter02 creation bytecode to the hash recorded in
/// script/artifacts/README.md (npm package swap-router-contracts 1.3.1).
contract SwapRouter02ArtifactTest is Test {
    bytes32 internal constant SWAP_ROUTER_02_BYTECODE_HASH =
        0x603dca716e6cc8be026ebc49ab95f5c163b4b2ec4019615e607ec91710734841;

    function test_vendoredSwapRouter02BytecodeHash() public view {
        bytes memory code = vm.parseJsonBytes(vm.readFile("script/artifacts/SwapRouter02.json"), ".bytecode");
        assertEq(keccak256(code), SWAP_ROUTER_02_BYTECODE_HASH);
    }
}
