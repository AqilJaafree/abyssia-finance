// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployPermit2} from "@uniswap/v4-periphery/lib/permit2/test/utils/DeployPermit2.sol";

/// @dev Deploys Uniswap's official v4 build (npm v4-core 1.0.2 PoolManager; v4-periphery
/// 1.0.3 PositionManager and StateView) plus Permit2 at its canonical address, with no
/// RPC. The runtime bytecode is byte-identical to Arc's deployment apart from
/// immutables (verified 2026-10-14; Permit2 differs only in its cached chain id and
/// domain separator).
abstract contract V4Deployer is Test {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    string internal constant ART_POOL_MANAGER =
        "node_modules/@uniswap/v4-core/out/PoolManager.sol/PoolManager.json";
    string internal constant ART_POSITION_MANAGER =
        "node_modules/@uniswap/v4-periphery/foundry-out/PositionManager.sol/PositionManager.json";
    string internal constant ART_STATE_VIEW =
        "node_modules/@uniswap/v4-periphery/foundry-out/StateView.sol/StateView.json";

    /// @dev Gas cap for subscriber notifications; irrelevant here (the vault never subscribes).
    uint256 internal constant UNSUBSCRIBE_GAS_LIMIT = 300_000;

    struct V4 {
        address poolManager;
        address positionManager;
        address stateView;
        address permit2;
    }

    function _deployV4() internal returns (V4 memory d) {
        d.permit2 = new DeployPermit2().deployPermit2();
        d.poolManager = _create(_bytecode(ART_POOL_MANAGER), abi.encode(address(this)));
        // PositionManager(poolManager, permit2, unsubscribeGasLimit, tokenDescriptor, weth9):
        // no descriptor (tokenURI is cosmetic) and no WETH9 (Arc has no wrapped native;
        // native-currency paths are never used).
        d.positionManager = _create(
            _bytecode(ART_POSITION_MANAGER),
            abi.encode(d.poolManager, d.permit2, UNSUBSCRIBE_GAS_LIMIT, address(0), address(0))
        );
        d.stateView = _create(_bytecode(ART_STATE_VIEW), abi.encode(d.poolManager));
    }

    function _bytecode(string memory artifact) private view returns (bytes memory) {
        return vm.parseJsonBytes(vm.readFile(artifact), ".bytecode.object");
    }

    function _create(bytes memory code, bytes memory args) private returns (address addr) {
        bytes memory init = abi.encodePacked(code, args);
        assembly {
            addr := create(0, add(init, 0x20), mload(init))
        }
        require(addr != address(0), "v4 deploy failed");
    }
}
