// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {DeployAbyssia} from "../../script/DeployAbyssia.s.sol";
import {SepoliaTestPools} from "../../script/SepoliaTestPools.s.sol";
import {AbyssiaVault} from "../../src/AbyssiaVault.sol";
import {VaultRegistry} from "../../src/registry/VaultRegistry.sol";
import {VaultBook} from "../../src/libraries/VaultBook.sol";
import {VaultRebalance} from "../../src/libraries/VaultRebalance.sol";
import {Shapes} from "../../src/libraries/Shapes.sol";
import {IStateView} from "../../src/interfaces/IStateView.sol";
import {IUniswapV3Pool} from "../../src/interfaces/IUniswapV3Pool.sol";
import {PoolKey, PoolKeyLib} from "../../src/types/PoolKey.sol";

/// @dev The deployment scripts, then the vault end to end, on an Ethereum Sepolia fork:
/// Uniswap's real v3 and v4, Circle's real USDC, and a real timelock handover. Skipped
/// when SEPOLIA_RPC_URL is unset.
contract AbyssiaDeploySepoliaTest is Test {
    using PoolKeyLib for PoolKey;

    uint256 internal constant FORK_BLOCK = 11_913_750;
    /// @dev The funded Sepolia deployer (holds 10 USDC at FORK_BLOCK).
    address internal constant DEPLOYER = 0xd6499417BbC291304fc16f6849A1717D45569494;
    uint256 internal constant DELAY = 5 minutes;

    DeployAbyssia internal script;
    DeployAbyssia.Deployed internal d;
    SepoliaTestPools.Pools internal pools;
    IERC20 internal usdc;
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal treasury = makeAddr("treasury");
    address internal proposer = makeAddr("proposer");
    bool internal forked;

    function setUp() public {
        string memory url = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url, FORK_BLOCK);
        forked = true;
        script = new DeployAbyssia();
        DeployAbyssia.Network memory n = script.network(block.chainid);
        usdc = IERC20(n.usdc);

        SepoliaTestPools poolScript = new SepoliaTestPools();
        vm.prank(DEPLOYER);
        usdc.transfer(address(poolScript), 4e6);
        pools = poolScript.deployPools(2e6, address(poolScript));
        // Let the new v3 pool's TWAP window fill.
        vm.warp(block.timestamp + 11 minutes);

        d = script.deploy(n, _settings(pools.token), address(script));
    }

    function _settings(address token) internal view returns (DeployAbyssia.Settings memory s) {
        s.proposer = proposer;
        s.keeper = keeper;
        s.guardian = guardian;
        s.treasury = treasury;
        s.timelockDelay = DELAY;
        s.name = "Abyssia Memecoin Vault";
        s.symbol = "abMEME";
        s.minDeposit = 1e6;
        s.maxTotalAssets = 1_000e6;
        s.maxCycleMoveBps = 2_000;
        s.maxSwapSlippageBps = 500;
        // Test fixture limits (not production settings).
        s.memecoin = VaultRegistry.ClassParams(3_000, 3_000, 7, 10, 60, 1_774_440, 3_000, 0, 1e9);
        s.allowToken = token;
    }

    /// Every admin role sits with the timelock; the deployer kept nothing.
    function test_governanceHandover() public view {
        bytes32 admin = 0x00;
        address actor = address(script);
        assertTrue(d.registry.hasRole(admin, address(d.timelock)));
        assertFalse(d.registry.hasRole(admin, actor));
        assertTrue(d.vault.hasRole(admin, address(d.timelock)));
        assertFalse(d.vault.hasRole(admin, actor));
        assertTrue(d.factory.hasRole(admin, address(d.timelock)));
        assertFalse(d.factory.hasRole(admin, actor));
        assertFalse(d.factory.hasRole(d.factory.DEPLOYER_ROLE(), actor));
        // Only the timelock deploys vaults, each from a timelocked init-hash approval.
        assertTrue(d.factory.hasRole(d.factory.DEPLOYER_ROLE(), address(d.timelock)));
        assertFalse(d.factory.hasRole(d.factory.DEPLOYER_ROLE(), proposer));
        assertTrue(d.factory.hasRole(d.factory.GUARDIAN_ROLE(), guardian));
        assertFalse(d.timelock.hasRole(admin, actor));
        assertTrue(d.timelock.hasRole(d.timelock.PROPOSER_ROLE(), proposer));
        assertTrue(d.timelock.hasRole(d.timelock.EXECUTOR_ROLE(), proposer));
        assertTrue(d.timelock.hasRole(d.timelock.CANCELLER_ROLE(), guardian));
        assertEq(d.timelock.getMinDelay(), DELAY);
        assertTrue(d.vault.hasRole(d.vault.KEEPER_ROLE(), keeper));
        assertTrue(d.vault.hasRole(d.vault.GUARDIAN_ROLE(), guardian));
        assertEq(d.vault.treasury(), treasury);
        assertTrue(d.factory.isVault(address(d.vault)));
        assertEq(d.registry.poolCount(), 2);
        assertEq(address(d.vault.posm()), script.network(block.chainid).posm);
    }

    /// Admin changes only go through the timelock, after the delay.
    function test_adminChangesNeedTheTimelockDelay() public {
        bytes memory call = abi.encodeCall(AbyssiaVault.setMaxSwapSlippageBps, (300));
        vm.prank(proposer);
        d.timelock.schedule(address(d.vault), 0, call, bytes32(0), bytes32(0), DELAY);
        vm.prank(proposer);
        vm.expectRevert();
        d.timelock.execute(address(d.vault), 0, call, bytes32(0), bytes32(0));
        vm.warp(block.timestamp + DELAY);
        vm.prank(proposer);
        d.timelock.execute(address(d.vault), 0, call, bytes32(0), bytes32(0));
        assertEq(d.vault.maxSwapSlippageBps(), 300);
    }

    /// Real USDC in, a settlement, rebalances on real v3 and v4, a v3 swap, fees, and an
    /// in-kind exit.
    function test_lifecycleOnSepolia() public {
        vm.startPrank(DEPLOYER);
        usdc.approve(address(d.vault), 6e6);
        d.vault.requestDeposit(6e6);
        vm.stopPrank();
        _settle();
        vm.prank(DEPLOYER);
        d.vault.claimDeposit(1, DEPLOYER);
        assertEq(d.vault.idleAssets(), 6e6);

        bytes32 v3Id = d.registry.poolIdAt(0);
        bytes32 v4Id = d.registry.poolIdAt(1);
        _rebalance(v4Id, Shapes.Spec(Shapes.BIDASK, Shapes.USDC_ONLY, 4, 600), 1e6);
        _rebalance(v3Id, Shapes.Spec(Shapes.SPOT, Shapes.USDC_ONLY, 2, 600), 5e5);
        (uint256 n3, uint256 n4) = d.vault.positionCount();
        assertEq(n3, 2);
        assertEq(n4, 4);

        uint256 got = _keeperSwap(v3Id, 2e4); // 1% of the pool: small price impact
        assertGt(got, 0);
        assertEq(d.vault.tokenBalance(pools.token), got);

        vm.warp(block.timestamp + 1 hours);
        _settle(); // harvest + fees
        address receiver = makeAddr("receiver");
        uint256 shares = d.vault.balanceOf(DEPLOYER) / 2;
        vm.prank(DEPLOYER);
        d.vault.redeemInKind(shares, receiver);
        assertGt(usdc.balanceOf(receiver), 2e6);
        assertGt(IERC20(pools.token).balanceOf(receiver), 0);
    }

    function _settle() internal {
        vm.warp(block.timestamp + d.vault.minSettleInterval());
        uint256 price = d.vault.sharePrice();
        vm.prank(keeper);
        d.vault.settle(price);
    }

    function _rebalance(bytes32 poolId, Shapes.Spec memory spec, uint256 usdcAmount) internal {
        VaultRegistry.PoolInfo memory info = d.registry.getPool(poolId);
        int24 tick;
        if (info.protocol == VaultRegistry.Protocol.V3) (, tick,,,,,) = IUniswapV3Pool(info.v3Pool).slot0();
        else (, tick,,) = IStateView(script.network(block.chainid).stateView).getSlot0(poolId);
        vm.prank(keeper);
        d.vault.rebalance(VaultRebalance.Args(poolId, spec, usdcAmount, 0, tick, block.timestamp));
    }

    function _keeperSwap(bytes32 poolId, uint256 usdcIn) internal returns (uint256) {
        // At 1 TMEME = 0.01 USDC, `usdcIn` buys ~usdcIn * 1e14 TMEME; accept 4% less (above
        // the vault's 5% floor, below fee + impact).
        vm.prank(keeper);
        return d.vault.swap(poolId, true, usdcIn, usdcIn * 1e14 * 96 / 100);
    }
}
