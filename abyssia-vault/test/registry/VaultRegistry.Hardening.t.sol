// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {RegistryTestBase} from "./RegistryTestBase.sol";
import {VaultRegistry} from "../../src/registry/VaultRegistry.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {MockV3Pool} from "../mocks/MockV3Pool.sol";

contract VaultRegistryHardeningTest is RegistryTestBase {
    VaultRegistry.AssetClass internal constant MEME = VaultRegistry.AssetClass.Memecoin;
    VaultRegistry.AssetClass internal constant BLUE = VaultRegistry.AssetClass.Bluechip;

    address internal hook = makeAddr("hook");

    function setUp() public override {
        super.setUp();
        _configureMeme();
    }

    // ---------------- hook revocation ----------------

    function _addHookedV4() internal returns (bytes32 id) {
        PoolKey memory key = _usdcMemeKey(hook);
        _initV4(key);
        vm.startPrank(admin);
        registry.setHookAllowed(hook, true);
        id = registry.addV4Pool(key, MEME);
        vm.stopPrank();
    }

    function test_guardianRevokeHookMakesPoolUnusable() public {
        bytes32 id = _addHookedV4();
        assertTrue(registry.isUsable(id));

        vm.expectEmit(true, false, false, true, address(registry));
        emit VaultRegistry.HookAllowed(hook, false);
        vm.prank(guardian);
        registry.guardianRevokeHook(hook);

        assertFalse(registry.hookAllowed(hook));
        assertTrue(registry.isEnabled(id)); // raw flag untouched...
        assertFalse(registry.isUsable(id)); // ...but the pool is no longer usable
    }

    function test_enablePoolRevertsWhileHookRevoked() public {
        bytes32 id = _addHookedV4();
        vm.prank(guardian);
        registry.disablePool(id);
        vm.prank(guardian);
        registry.guardianRevokeHook(hook);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.HookNotAllowed.selector, hook));
        registry.enablePool(id);
    }

    function test_reallowingHookRestoresUsability() public {
        bytes32 id = _addHookedV4();
        vm.prank(guardian);
        registry.guardianRevokeHook(hook);
        vm.prank(guardian);
        registry.disablePool(id);

        vm.startPrank(admin);
        registry.setHookAllowed(hook, true);
        registry.enablePool(id);
        vm.stopPrank();
        assertTrue(registry.isUsable(id));
    }

    function test_reallowingHookAloneRestoresEnabledPool() public {
        bytes32 id = _addHookedV4();
        vm.prank(guardian);
        registry.guardianRevokeHook(hook);
        vm.prank(admin);
        registry.setHookAllowed(hook, true);
        assertTrue(registry.isUsable(id));
    }

    function test_nonGuardianCannotRevokeHook() public {
        _addHookedV4();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, registry.GUARDIAN_ROLE()
            )
        );
        vm.prank(alice);
        registry.guardianRevokeHook(hook);
        assertTrue(registry.hookAllowed(hook));
    }

    // ---------------- isUsable ----------------

    function test_isUsableFalseForUnknownPool() public view {
        assertFalse(registry.isUsable(keccak256("nope")));
    }

    function test_isUsableFalseForDisabledPool() public {
        _deployV3Pool(3000);
        vm.prank(admin);
        bytes32 id = registry.addV3Pool(address(meme), 3000, MEME);
        assertTrue(registry.isUsable(id));
        vm.prank(guardian);
        registry.disablePool(id);
        assertFalse(registry.isUsable(id));
    }

    // ---------------- params ----------------

    function test_stopLossZeroRejected() public {
        VaultRegistry.ClassParams memory p = _memeParams();
        p.stopLossBps = 0;
        vm.prank(admin);
        vm.expectRevert(VaultRegistry.ParamOutOfBounds.selector);
        registry.setClassParams(MEME, p);
    }

    function test_fullRangeWidthAcceptedForBluechip() public {
        VaultRegistry.ClassParams memory p = _memeParams();
        p.maxWidthTicks = 1_774_544;
        vm.prank(admin);
        registry.setClassParams(BLUE, p);
        assertEq(registry.classParams(BLUE).maxWidthTicks, 1_774_544);
        assertEq(registry.MAX_WIDTH_TICKS(), 1_774_544);

        p.maxWidthTicks = 1_774_545;
        vm.prank(admin);
        vm.expectRevert(VaultRegistry.ParamOutOfBounds.selector);
        registry.setClassParams(BLUE, p);
    }

    // ---------------- v3 init & metadata ----------------

    function test_uninitializedV3PoolRejected() public {
        MockV3Pool p = new MockV3Pool(); // sqrtPrice == 0
        v3Factory.setPool(address(usdc), address(meme), 3000, address(p));
        vm.prank(admin);
        vm.expectRevert(VaultRegistry.PoolNotFound.selector);
        registry.addV3Pool(address(meme), 3000, MEME);
    }

    function test_v3PoolMetadata() public {
        _deployV3Pool(3000);
        vm.prank(admin);
        bytes32 id = registry.addV3Pool(address(meme), 3000, MEME);
        VaultRegistry.PoolInfo memory info = registry.getPool(id);
        assertEq(info.fee, 3000);
        assertEq(info.tickSpacing, 60);
        assertEq(info.usdcIsToken0, address(usdc) < address(meme));
    }

    function test_v3PoolMetadataOtherFeeTier() public {
        _deployV3Pool(500);
        vm.prank(admin);
        bytes32 id = registry.addV3Pool(address(meme), 500, MEME);
        VaultRegistry.PoolInfo memory info = registry.getPool(id);
        assertEq(info.fee, 500);
        assertEq(info.tickSpacing, 10);
    }

    function test_v4PoolMetadata() public {
        PoolKey memory key = _usdcMemeKey(address(0));
        _initV4(key);
        vm.prank(admin);
        bytes32 id = registry.addV4Pool(key, MEME);
        VaultRegistry.PoolInfo memory info = registry.getPool(id);
        assertEq(info.fee, 3000);
        assertEq(info.tickSpacing, 60);
        assertEq(info.usdcIsToken0, address(usdc) < address(meme));
        assertEq(info.usdcIsToken0, key.currency0 == address(usdc));
        assertEq(info.v4Key.fee, 3000);
    }

    // ---------------- setPoolClass ----------------

    function test_setPoolClassToUnconfiguredClassReverts() public {
        _deployV3Pool(3000);
        vm.prank(admin);
        bytes32 id = registry.addV3Pool(address(meme), 3000, MEME);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(VaultRegistry.ClassNotConfigured.selector, VaultRegistry.AssetClass.Stable)
        );
        registry.setPoolClass(id, VaultRegistry.AssetClass.Stable);
    }

    function test_setPoolClassOnUnknownPoolReverts() public {
        bytes32 id = keccak256("nope");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.UnknownPool.selector, id));
        registry.setPoolClass(id, MEME);
    }

    // ---------------- fuzz ----------------

    /// @dev Whatever the guardian calls, limits only go down and shapes only shrink.
    function testFuzz_guardianCanNeverLoosen(uint16 a, uint16 b, uint8 mask, bool shapesFirst) public {
        VaultRegistry.ClassParams memory before = registry.classParams(MEME);

        vm.startPrank(guardian);
        if (shapesFirst) registry.guardianDisableShapes(MEME, mask);
        try registry.guardianReduceAllocation(MEME, a, b) {} catch {}
        if (!shapesFirst) registry.guardianDisableShapes(MEME, mask);
        vm.stopPrank();

        VaultRegistry.ClassParams memory afterP = registry.classParams(MEME);
        assertLe(afterP.maxAllocationBps, before.maxAllocationBps);
        assertLe(afterP.maxClassBps, before.maxClassBps);
        assertEq(afterP.allowedShapes & ~before.allowedShapes, 0); // subset
        assertEq(afterP.allowedShapes, before.allowedShapes & ~mask);
        // Untouched fields.
        assertEq(afterP.maxRanges, before.maxRanges);
        assertEq(afterP.minWidthTicks, before.minWidthTicks);
        assertEq(afterP.maxWidthTicks, before.maxWidthTicks);
        assertEq(afterP.stopLossBps, before.stopLossBps);
        assertEq(afterP.rebalanceCooldown, before.rebalanceCooldown);
        assertEq(afterP.minPoolLiquidity, before.minPoolLiquidity);
    }

    /// @dev Repeated guardian actions keep ratcheting down.
    function testFuzz_guardianSequenceNeverLoosens(
        uint16[4] memory as_,
        uint16[4] memory bs,
        uint8[4] memory masks
    ) public {
        for (uint256 i; i < 4; ++i) {
            VaultRegistry.ClassParams memory before = registry.classParams(MEME);
            vm.startPrank(guardian);
            try registry.guardianReduceAllocation(MEME, as_[i], bs[i]) {} catch {}
            registry.guardianDisableShapes(MEME, masks[i]);
            vm.stopPrank();
            VaultRegistry.ClassParams memory afterP = registry.classParams(MEME);
            assertLe(afterP.maxAllocationBps, before.maxAllocationBps);
            assertLe(afterP.maxClassBps, before.maxClassBps);
            assertEq(afterP.allowedShapes & ~before.allowedShapes, 0);
        }
    }

    /// @dev Any params setClassParams accepts satisfy every hard cap.
    function testFuzz_acceptedParamsSatisfyHardCaps(uint8 classSeed, VaultRegistry.ClassParams memory p)
        public
    {
        VaultRegistry.AssetClass c = VaultRegistry.AssetClass(classSeed % 4);
        // Keep inputs near the bounds so both accept and reject paths are exercised.
        p.maxAllocationBps = uint16(bound(p.maxAllocationBps, 0, 6_000));
        p.maxClassBps = uint16(bound(p.maxClassBps, 0, 11_000));
        p.allowedShapes = uint8(bound(p.allowedShapes, 0, 9));
        p.maxRanges = uint8(bound(p.maxRanges, 0, 12));
        p.minWidthTicks = int24(bound(p.minWidthTicks, -10, 1_800_000));
        p.maxWidthTicks = int24(bound(p.maxWidthTicks, -10, 1_800_000));
        p.stopLossBps = uint16(bound(p.stopLossBps, 0, 9_500));
        p.rebalanceCooldown = uint32(bound(p.rebalanceCooldown, 0, 8 days));

        vm.prank(admin);
        try registry.setClassParams(c, p) {
            VaultRegistry.ClassParams memory s = registry.classParams(c);
            assertGt(s.maxAllocationBps, 0);
            assertLe(s.maxAllocationBps, registry.HARD_MAX_ALLOCATION_BPS());
            assertLe(s.maxAllocationBps, s.maxClassBps);
            assertLe(s.maxClassBps, registry.hardMaxClassBps(c));
            assertGt(s.allowedShapes, 0);
            assertEq(s.allowedShapes & ~registry.ALL_SHAPES(), 0);
            assertGt(s.maxRanges, 0);
            assertLe(s.maxRanges, registry.HARD_MAX_RANGES());
            assertGt(s.minWidthTicks, 0);
            assertLe(s.minWidthTicks, s.maxWidthTicks);
            assertLe(s.maxWidthTicks, registry.MAX_WIDTH_TICKS());
            assertGt(s.stopLossBps, 0);
            assertLe(s.stopLossBps, registry.HARD_MAX_STOP_LOSS_BPS());
            assertLe(s.rebalanceCooldown, registry.HARD_MAX_COOLDOWN());
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(VaultRegistry.ParamOutOfBounds.selector));
        }
    }
}
