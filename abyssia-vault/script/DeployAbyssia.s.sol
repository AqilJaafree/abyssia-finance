// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {AbyssiaVault} from "../src/AbyssiaVault.sol";
import {AbyssiaVaultFactory} from "../src/AbyssiaVaultFactory.sol";
import {VaultRegistry} from "../src/registry/VaultRegistry.sol";
import {INonfungiblePositionManager as INPM} from "../src/interfaces/INonfungiblePositionManager.sol";
import {IV4PositionManager} from "../src/interfaces/IV4PositionManager.sol";
import {IStateView} from "../src/interfaces/IStateView.sol";
import {ISwapRouter02} from "../src/interfaces/ISwapRouter02.sol";
import {PoolKey} from "../src/types/PoolKey.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title DeployAbyssia
/// @notice Deploys one Abyssia memecoin vault and its governance:
///  1. TimelockController (`PROPOSER` proposes and executes; the guardian may cancel);
///  2. VaultRegistry, with the memecoin class and (optionally) one token's v3 + v4 pools;
///  3. AbyssiaVaultFactory, approving this one vault's init hash (code and arguments);
///  4. AbyssiaVault through the factory, with its treasury;
///  5. hands every admin role to the timelock and renounces the deployer's.
/// Every setting comes from the environment with no defaults (see .env.example); Uniswap
/// and USDC addresses are pinned per chain.
/// @dev Usage:
///   DEPLOYER_PRIVATE_KEY=0x... forge script script/DeployAbyssia.s.sol --rpc-url $RPC --broadcast
/// Forge deploys and links the vault's external libraries as part of the broadcast.
contract DeployAbyssia is Script {
    uint256 internal constant SEPOLIA = 11_155_111;
    uint256 internal constant ARC_MAINNET = 5042;
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant POOL_SPACING = 60;

    struct Network {
        address usdc;
        address v3Factory;
        address npm;
        address swapRouter02;
        address posm;
        address stateView;
    }

    struct Settings {
        address proposer; // the Safe on mainnet
        address keeper;
        address guardian;
        address treasury;
        uint256 timelockDelay;
        string name;
        string symbol;
        uint256 minDeposit;
        uint256 maxTotalAssets;
        uint256 maxCycleMoveBps;
        uint256 maxSwapSlippageBps;
        VaultRegistry.ClassParams memecoin;
        address allowToken; // optional: allowlist USDC/allowToken 0.3% on v3 and v4
        bytes32 salt;
    }

    struct Deployed {
        TimelockController timelock;
        VaultRegistry registry;
        AbyssiaVaultFactory factory;
        AbyssiaVault vault;
    }

    /// @dev Arc mainnet governance floor (the design's 48h timelock).
    uint256 internal constant MAINNET_MIN_DELAY = 48 hours;

    error UnsupportedChain(uint256 chainId);
    error UnsafeSettings(string reason);
    error HandoverIncomplete(string what);

    function run() external returns (Deployed memory d) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        Settings memory s = settingsFromEnv();
        if (block.chainid == ARC_MAINNET) {
            if (s.timelockDelay < MAINNET_MIN_DELAY) revert UnsafeSettings("timelock delay below 48h");
            if (s.proposer == deployer) revert UnsafeSettings("proposer must be the Safe, not the deployer");
        }
        vm.startBroadcast(pk);
        d = deploy(network(block.chainid), s, deployer);
        vm.stopBroadcast();
        console2.log("TimelockController", address(d.timelock));
        console2.log("VaultRegistry", address(d.registry));
        console2.log("AbyssiaVaultFactory", address(d.factory));
        console2.log("AbyssiaVault", address(d.vault));
    }

    /// @notice Uniswap and USDC addresses, verified on-chain (Arc 2026-10-13, Sepolia
    /// 2026-10-14) against Uniswap's deployments manifest.
    function network(uint256 chainId) public pure returns (Network memory) {
        if (chainId == SEPOLIA) {
            return Network({
                usdc: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238,
                v3Factory: 0x0227628f3F023bb0B980b67D528571c95c6DaC1c,
                npm: 0x1238536071E1c677A632429e3655c799b22cDA52,
                swapRouter02: 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E,
                posm: 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4,
                stateView: 0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C
            });
        }
        if (chainId == ARC_MAINNET) {
            return Network({
                usdc: 0x3600000000000000000000000000000000000000,
                v3Factory: 0xf0db7b58379503491d857dB50AC9ece64c653918,
                npm: 0x39654A85A4C05127f5Fd6ED22CAeC077A0fB1377,
                swapRouter02: 0x53BF6B0684Ec7eF91e1387Da3D1a1769bC5A6F77,
                posm: 0x6049c9a0e26405C0985f9E3685C87d0aE917f82B,
                stateView: 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b
            });
        }
        revert UnsupportedChain(chainId);
    }

    function settingsFromEnv() public view returns (Settings memory s) {
        s.proposer = vm.envAddress("PROPOSER");
        s.keeper = vm.envAddress("KEEPER");
        s.guardian = vm.envAddress("GUARDIAN");
        s.treasury = vm.envAddress("TREASURY");
        s.timelockDelay = vm.envUint("TIMELOCK_DELAY");
        s.name = vm.envString("VAULT_NAME");
        s.symbol = vm.envString("VAULT_SYMBOL");
        s.minDeposit = vm.envUint("VAULT_MIN_DEPOSIT");
        s.maxTotalAssets = vm.envUint("VAULT_MAX_TOTAL_ASSETS");
        s.maxCycleMoveBps = vm.envUint("VAULT_MAX_CYCLE_MOVE_BPS");
        s.maxSwapSlippageBps = vm.envUint("VAULT_MAX_SWAP_SLIPPAGE_BPS");
        s.memecoin = VaultRegistry.ClassParams({
            maxAllocationBps: SafeCast.toUint16(vm.envUint("MEMECOIN_MAX_ALLOCATION_BPS")),
            maxClassBps: SafeCast.toUint16(vm.envUint("MEMECOIN_MAX_CLASS_BPS")),
            allowedShapes: SafeCast.toUint8(vm.envUint("MEMECOIN_ALLOWED_SHAPES")),
            maxRanges: SafeCast.toUint8(vm.envUint("MEMECOIN_MAX_RANGES")),
            minWidthTicks: SafeCast.toInt24(vm.envInt("MEMECOIN_MIN_WIDTH_TICKS")),
            maxWidthTicks: SafeCast.toInt24(vm.envInt("MEMECOIN_MAX_WIDTH_TICKS")),
            stopLossBps: SafeCast.toUint16(vm.envUint("MEMECOIN_STOP_LOSS_BPS")),
            rebalanceCooldown: SafeCast.toUint32(vm.envUint("MEMECOIN_REBALANCE_COOLDOWN")),
            minPoolLiquidity: SafeCast.toUint128(vm.envUint("MEMECOIN_MIN_POOL_LIQUIDITY"))
        });
        s.allowToken = vm.envOr("ALLOW_TOKEN", address(0));
        s.salt = vm.envOr("VAULT_SALT", bytes32(0));
    }

    /// @notice The whole deployment. `actor` is whoever sends these calls: the deployer
    /// EOA when broadcasting, this contract in tests. It holds every admin role only until
    /// the final handover.
    function deploy(Network memory n, Settings memory s, address actor) public returns (Deployed memory d) {
        // 1. Timelock: the proposer proposes and executes; the guardian can cancel.
        address[] memory proposers = new address[](1);
        proposers[0] = s.proposer;
        d.timelock = new TimelockController(s.timelockDelay, proposers, proposers, actor);
        d.timelock.grantRole(d.timelock.CANCELLER_ROLE(), s.guardian);

        // 2. Registry: the memecoin class and, optionally, one token's pools.
        d.registry = new VaultRegistry(n.usdc, n.v3Factory, n.stateView, actor, s.guardian);
        d.registry.setClassParams(VaultRegistry.AssetClass.Memecoin, s.memecoin);
        if (s.allowToken != address(0)) {
            d.registry.addV3Pool(s.allowToken, POOL_FEE, VaultRegistry.AssetClass.Memecoin);
            (address c0, address c1) = n.usdc < s.allowToken ? (n.usdc, s.allowToken) : (s.allowToken, n.usdc);
            d.registry
                .addV4Pool(
                    PoolKey(c0, c1, POOL_FEE, POOL_SPACING, address(0)), VaultRegistry.AssetClass.Memecoin
                );
        }

        // 3-4. Factory approving this vault's code and arguments, and the vault through it.
        d.factory = new AbyssiaVaultFactory(actor, actor);
        d.factory.grantRole(d.factory.GUARDIAN_ROLE(), s.guardian);
        bytes memory code = type(AbyssiaVault).creationCode;
        bytes memory args = abi.encode(_config(n, s, d.registry, actor));
        d.factory.setInitApproved(keccak256(abi.encodePacked(code, args)), true);
        d.vault = AbyssiaVault(d.factory.deploy(code, args, s.salt));
        d.vault.setTreasury(s.treasury);

        // 5. Handover: the timelock administers everything; the deployer keeps nothing.
        bytes32 admin = 0x00; // DEFAULT_ADMIN_ROLE
        d.registry.grantRole(admin, address(d.timelock));
        d.registry.renounceRole(admin, actor);
        d.vault.grantRole(admin, address(d.timelock));
        d.vault.renounceRole(admin, actor);
        // Only the timelock deploys, on top of the timelocked per-vault approval: every new
        // vault is a delayed proposal the guardian can cancel.
        d.factory.grantRole(d.factory.DEPLOYER_ROLE(), address(d.timelock));
        d.factory.renounceRole(d.factory.DEPLOYER_ROLE(), actor);
        d.factory.grantRole(admin, address(d.timelock));
        d.factory.renounceRole(admin, actor);
        d.timelock.renounceRole(admin, actor);
        _assertHandover(d, actor);
    }

    /// @dev Fail the whole deployment unless the deployer kept no role anywhere.
    function _assertHandover(Deployed memory d, address actor) internal view {
        bytes32 admin = 0x00;
        if (d.registry.hasRole(admin, actor) || !d.registry.hasRole(admin, address(d.timelock))) {
            revert HandoverIncomplete("registry");
        }
        if (d.vault.hasRole(admin, actor) || !d.vault.hasRole(admin, address(d.timelock))) {
            revert HandoverIncomplete("vault");
        }
        if (
            d.factory.hasRole(admin, actor) || d.factory.hasRole(d.factory.DEPLOYER_ROLE(), actor)
                || !d.factory.hasRole(admin, address(d.timelock))
        ) revert HandoverIncomplete("factory");
        if (d.timelock.hasRole(admin, actor)) revert HandoverIncomplete("timelock");
    }

    function _config(Network memory n, Settings memory s, VaultRegistry registry, address actor)
        internal
        pure
        returns (AbyssiaVault.Config memory)
    {
        return AbyssiaVault.Config({
            usdc: IERC20(n.usdc),
            name: s.name,
            symbol: s.symbol,
            admin: actor,
            keeper: s.keeper,
            guardian: s.guardian,
            minDeposit: s.minDeposit,
            maxTotalAssets: s.maxTotalAssets,
            maxCycleMoveBps: s.maxCycleMoveBps,
            maxSwapSlippageBps: s.maxSwapSlippageBps,
            registry: registry,
            npm: INPM(n.npm),
            swapRouter02: ISwapRouter02(n.swapRouter02),
            posm: IV4PositionManager(n.posm),
            stateView: IStateView(n.stateView)
        });
    }
}
