// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {RegistryTestBase} from "./RegistryTestBase.sol";
import {VaultRegistry} from "../../src/registry/VaultRegistry.sol";

contract VaultRegistryClassParamsTest is RegistryTestBase {
    VaultRegistry.AssetClass internal constant MEME = VaultRegistry.AssetClass.Memecoin;

    function test_adminSetsValidParams() public {
        _configureMeme();
        assertTrue(registry.classConfigured(MEME));
        VaultRegistry.ClassParams memory p = registry.classParams(MEME);
        assertEq(p.maxAllocationBps, 500);
        assertEq(p.maxClassBps, 2_000);
        assertEq(p.allowedShapes, 4);
    }

    function test_nonAdminCannotSetParams() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, registry.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        registry.setClassParams(MEME, _memeParams());
    }

    function test_hardMaxClassBpsPerClass() public view {
        assertEq(registry.hardMaxClassBps(VaultRegistry.AssetClass.Memecoin), 3_000);
        assertEq(registry.hardMaxClassBps(VaultRegistry.AssetClass.Volatile), 6_000);
        assertEq(registry.hardMaxClassBps(VaultRegistry.AssetClass.Bluechip), 10_000);
        assertEq(registry.hardMaxClassBps(VaultRegistry.AssetClass.Stable), 10_000);
    }

    function test_memecoinClassCannotExceedHardCap() public {
        VaultRegistry.ClassParams memory p = _memeParams();
        p.maxClassBps = 3_001;
        _expectOutOfBounds(p);
    }

    function test_rejectsEachOutOfBoundsField() public {
        VaultRegistry.ClassParams memory p;

        p = _memeParams();
        p.maxAllocationBps = 0;
        _expectOutOfBounds(p);

        p = _memeParams();
        p.maxAllocationBps = 2_001; // > maxClassBps
        _expectOutOfBounds(p);

        p = _memeParams();
        p.allowedShapes = 0;
        _expectOutOfBounds(p);

        p = _memeParams();
        p.allowedShapes = 8; // unknown shape bit
        _expectOutOfBounds(p);

        p = _memeParams();
        p.maxRanges = 0;
        _expectOutOfBounds(p);

        p = _memeParams();
        p.maxRanges = 11;
        _expectOutOfBounds(p);

        p = _memeParams();
        p.minWidthTicks = 0;
        _expectOutOfBounds(p);

        p = _memeParams();
        p.minWidthTicks = 7_000; // > maxWidthTicks
        _expectOutOfBounds(p);

        p = _memeParams();
        p.maxWidthTicks = 1_774_545;
        _expectOutOfBounds(p);

        p = _memeParams();
        p.stopLossBps = 0;
        _expectOutOfBounds(p);

        p = _memeParams();
        p.stopLossBps = 9_001;
        _expectOutOfBounds(p);

        p = _memeParams();
        p.rebalanceCooldown = 7 days + 1;
        _expectOutOfBounds(p);
    }

    function test_bluechipMayUseHalfTheVaultPerPool() public {
        VaultRegistry.ClassParams memory p = _memeParams();
        p.maxAllocationBps = 5_000;
        p.maxClassBps = 10_000;
        vm.prank(admin);
        registry.setClassParams(VaultRegistry.AssetClass.Bluechip, p);
        p.maxAllocationBps = 5_001;
        vm.prank(admin);
        vm.expectRevert(VaultRegistry.ParamOutOfBounds.selector);
        registry.setClassParams(VaultRegistry.AssetClass.Bluechip, p);
    }

    function test_guardianReducesAllocation() public {
        _configureMeme();
        vm.prank(guardian);
        registry.guardianReduceAllocation(MEME, 200, 1_000);
        VaultRegistry.ClassParams memory p = registry.classParams(MEME);
        assertEq(p.maxAllocationBps, 200);
        assertEq(p.maxClassBps, 1_000);
    }

    function test_guardianCannotRaiseAllocation() public {
        _configureMeme();
        vm.prank(guardian);
        vm.expectRevert(VaultRegistry.NotTighter.selector);
        registry.guardianReduceAllocation(MEME, 600, 2_000);
        vm.prank(guardian);
        vm.expectRevert(VaultRegistry.NotTighter.selector);
        registry.guardianReduceAllocation(MEME, 500, 2_500);
    }

    function test_guardianReduceKeepsPerPoolBelowClass() public {
        _configureMeme();
        vm.prank(guardian);
        vm.expectRevert(VaultRegistry.ParamOutOfBounds.selector);
        registry.guardianReduceAllocation(MEME, 500, 400);
    }

    function test_guardianDisablesShapes() public {
        _configureMeme();
        uint8 bidAsk = registry.SHAPE_BIDASK(); // read before prank: prank applies to the next call
        vm.prank(guardian);
        registry.guardianDisableShapes(MEME, bidAsk);
        assertEq(registry.classParams(MEME).allowedShapes, 0);
    }

    function test_guardianActionsNeedConfiguredClass() public {
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.ClassNotConfigured.selector, MEME));
        registry.guardianReduceAllocation(MEME, 1, 1);
    }

    function test_adminIsNotGuardian() public {
        _configureMeme();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, admin, registry.GUARDIAN_ROLE()
            )
        );
        vm.prank(admin);
        registry.guardianDisableShapes(MEME, 4);
    }

    function _expectOutOfBounds(VaultRegistry.ClassParams memory p) internal {
        vm.prank(admin);
        vm.expectRevert(VaultRegistry.ParamOutOfBounds.selector);
        registry.setClassParams(MEME, p);
    }
}
