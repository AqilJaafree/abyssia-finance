// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @title DeployUniswapV3
/// @notice Deploys Uniswap's OFFICIAL v3 build artifacts (npm v3-core 1.0.1 and
/// v3-periphery 1.4.4: UniswapV3Factory, NonfungiblePositionManager, SwapRouter).
/// Uniswap v3 is not deployed on Arc testnet, so Abyssia deploys its own copy there
/// for testing. Mainnet always uses Uniswap's real deployment, never this script.
/// @dev Usage (testnet only):
///   DEPLOYER_PRIVATE_KEY=0x... forge script script/DeployUniswapV3.s.sol \
///     --rpc-url $ARC_TESTNET_RPC_URL --broadcast
contract DeployUniswapV3 is Script {
    uint256 internal constant ARC_TESTNET_CHAIN_ID = 5042002;

    /// @dev Arc has no wrapped-native token. The position manager only touches WETH9
    /// on native-value paths, which Abyssia never uses (mainnet's points at a revert stub).
    address internal constant NO_WETH9 = address(0);

    string internal constant ART_FACTORY =
        "node_modules/@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json";
    string internal constant ART_NPM =
        "node_modules/@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json";
    string internal constant ART_ROUTER =
        "node_modules/@uniswap/v3-periphery/artifacts/contracts/SwapRouter.sol/SwapRouter.json";

    struct Deployed {
        address factory;
        address positionManager;
        address swapRouter;
    }

    function run() external returns (Deployed memory d) {
        require(block.chainid == ARC_TESTNET_CHAIN_ID, "DeployUniswapV3: Arc testnet only");
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        d = deployAll();
        vm.stopBroadcast();
        console2.log("UniswapV3Factory", d.factory);
        console2.log("NonfungiblePositionManager", d.positionManager);
        console2.log("SwapRouter", d.swapRouter);
    }

    /// @notice Deploy all three contracts (no broadcast); also used by tests.
    function deployAll() public returns (Deployed memory d) {
        d.factory = _create(_bytecode(ART_FACTORY));
        // NonfungiblePositionManager(factory, WETH9, tokenDescriptor): no descriptor
        // (tokenURI is cosmetic and unused by the vault).
        d.positionManager =
            _create(abi.encodePacked(_bytecode(ART_NPM), abi.encode(d.factory, NO_WETH9, address(0))));
        d.swapRouter = _create(abi.encodePacked(_bytecode(ART_ROUTER), abi.encode(d.factory, NO_WETH9)));
    }

    function _bytecode(string memory artifact) internal view returns (bytes memory) {
        return vm.parseJsonBytes(vm.readFile(artifact), ".bytecode");
    }

    function _create(bytes memory code) internal returns (address addr) {
        assembly {
            addr := create(0, add(code, 0x20), mload(code))
        }
        require(addr != address(0), "DeployUniswapV3: create failed");
    }
}
