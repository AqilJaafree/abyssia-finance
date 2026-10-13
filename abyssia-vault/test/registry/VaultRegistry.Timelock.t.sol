// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {VaultRegistry} from "../../src/registry/VaultRegistry.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockV3Factory} from "../mocks/MockV3Factory.sol";
import {MockStateView} from "../mocks/MockStateView.sol";

/// @dev Production wiring: registry admin = TimelockController (48h) proposed/executed
/// by the Safe; guardian acts instantly.
contract VaultRegistryTimelockTest is Test {
    VaultRegistry internal registry;
    TimelockController internal timelock;
    address internal safe = makeAddr("safe");
    address internal guardian = makeAddr("guardian");
    uint256 internal constant DELAY = 48 hours;
    VaultRegistry.AssetClass internal constant MEME = VaultRegistry.AssetClass.Memecoin;

    function setUp() public {
        address[] memory roles = new address[](1);
        roles[0] = safe;
        timelock = new TimelockController(DELAY, roles, roles, address(0));
        registry = new VaultRegistry(
            address(new MockUSDC(6)),
            address(new MockV3Factory()),
            address(new MockStateView()),
            address(timelock),
            guardian
        );
    }

    function _params(uint16 maxAllocationBps) internal pure returns (VaultRegistry.ClassParams memory) {
        return VaultRegistry.ClassParams({
            maxAllocationBps: maxAllocationBps,
            maxClassBps: 2_000,
            allowedShapes: 4,
            maxRanges: 10,
            minWidthTicks: 60,
            maxWidthTicks: 6_000,
            stopLossBps: 3_000,
            rebalanceCooldown: 10 minutes,
            minPoolLiquidity: 1e12
        });
    }

    function test_safeCannotBypassTimelock() public {
        vm.prank(safe);
        vm.expectRevert();
        registry.setClassParams(MEME, _params(500));
    }

    function test_loosenTakesEffectOnlyAfterDelay() public {
        bytes memory data = abi.encodeCall(VaultRegistry.setClassParams, (MEME, _params(500)));

        vm.prank(safe);
        timelock.schedule(address(registry), 0, data, bytes32(0), bytes32(0), DELAY);

        // Too early.
        vm.warp(block.timestamp + DELAY - 1);
        vm.prank(safe);
        vm.expectRevert();
        timelock.execute(address(registry), 0, data, bytes32(0), bytes32(0));
        assertFalse(registry.classConfigured(MEME));

        // After the delay.
        vm.warp(block.timestamp + 1);
        vm.prank(safe);
        timelock.execute(address(registry), 0, data, bytes32(0), bytes32(0));
        assertTrue(registry.classConfigured(MEME));
        assertEq(registry.classParams(MEME).maxAllocationBps, 500);
    }

    function test_guardianTightensWithoutWaiting() public {
        bytes memory data = abi.encodeCall(VaultRegistry.setClassParams, (MEME, _params(500)));
        vm.prank(safe);
        timelock.schedule(address(registry), 0, data, bytes32(0), bytes32(0), DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(safe);
        timelock.execute(address(registry), 0, data, bytes32(0), bytes32(0));

        vm.prank(guardian);
        registry.guardianReduceAllocation(MEME, 100, 500);
        assertEq(registry.classParams(MEME).maxAllocationBps, 100);
    }
}
