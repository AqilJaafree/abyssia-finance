// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {RegistryTestBase} from "./RegistryTestBase.sol";
import {VaultRegistry} from "../../src/registry/VaultRegistry.sol";
import {PoolKey, PoolKeyLib} from "../../src/types/PoolKey.sol";

contract VaultRegistryPoolsTest is RegistryTestBase {
    using PoolKeyLib for PoolKey;

    VaultRegistry.AssetClass internal constant MEME = VaultRegistry.AssetClass.Memecoin;

    function setUp() public override {
        super.setUp();
        _configureMeme();
    }

    // ---------------- v3 ----------------

    function test_addV3PoolResolvesThroughFactory() public {
        address v3PoolAddr = _deployV3Pool(3000);
        vm.prank(admin);
        bytes32 id = registry.addV3Pool(address(meme), 3000, MEME);
        assertEq(id, bytes32(uint256(uint160(v3PoolAddr))));
        VaultRegistry.PoolInfo memory info = registry.getPool(id);
        assertEq(uint8(info.protocol), uint8(VaultRegistry.Protocol.V3));
        assertEq(info.token, address(meme));
        assertEq(info.v3Pool, v3PoolAddr);
        assertTrue(info.enabled);
        assertEq(registry.poolCount(), 1);
        assertEq(registry.poolIdAt(0), id);
    }

    function test_addV3PoolRejectsUnknownPool() public {
        vm.prank(admin);
        vm.expectRevert(VaultRegistry.PoolNotFound.selector);
        registry.addV3Pool(address(meme), 3000, MEME);
    }

    function test_addV3PoolRejectsUsdcOrZeroToken() public {
        vm.startPrank(admin);
        vm.expectRevert(VaultRegistry.InvalidToken.selector);
        registry.addV3Pool(address(usdc), 3000, MEME);
        vm.expectRevert(VaultRegistry.InvalidToken.selector);
        registry.addV3Pool(address(0), 3000, MEME);
        vm.stopPrank();
    }

    function test_addV3PoolTwiceReverts() public {
        _deployV3Pool(3000);
        vm.startPrank(admin);
        bytes32 id = registry.addV3Pool(address(meme), 3000, MEME);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.PoolAlreadyAdded.selector, id));
        registry.addV3Pool(address(meme), 3000, MEME);
        vm.stopPrank();
    }

    function test_addPoolNeedsConfiguredClass() public {
        _deployV3Pool(3000);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(VaultRegistry.ClassNotConfigured.selector, VaultRegistry.AssetClass.Stable)
        );
        registry.addV3Pool(address(meme), 3000, VaultRegistry.AssetClass.Stable);
    }

    function test_v3UnsupportedWhenFactoryZero() public {
        VaultRegistry r = new VaultRegistry(address(usdc), address(0), address(stateView), admin, guardian);
        vm.prank(admin);
        r.setClassParams(MEME, _memeParams());
        vm.prank(admin);
        vm.expectRevert(VaultRegistry.ProtocolUnsupported.selector);
        r.addV3Pool(address(meme), 3000, MEME);
    }

    // ---------------- v4 ----------------

    function test_addV4PoolWithNoHook() public {
        PoolKey memory key = _usdcMemeKey(address(0));
        bytes32 expected = _initV4(key);
        vm.prank(admin);
        bytes32 id = registry.addV4Pool(key, MEME);
        assertEq(id, expected);
        VaultRegistry.PoolInfo memory info = registry.getPool(id);
        assertEq(uint8(info.protocol), uint8(VaultRegistry.Protocol.V4));
        assertEq(info.token, address(meme));
        assertEq(info.v4Key.fee, 3000);
        assertEq(info.v4Key.tickSpacing, 60);
    }

    function test_poolIdMatchesV4Library() public pure {
        // Known v4 PoolId for a fixed key, computed as keccak256(abi.encode(key)).
        PoolKey memory key = PoolKey({
            currency0: address(0x1111),
            currency1: address(0x2222),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        assertEq(
            key.toId(),
            keccak256(abi.encode(address(0x1111), address(0x2222), uint24(3000), int24(60), address(0)))
        );
    }

    function test_addV4PoolRejectsUninitialized() public {
        vm.prank(admin);
        vm.expectRevert(VaultRegistry.PoolNotFound.selector);
        registry.addV4Pool(_usdcMemeKey(address(0)), MEME);
    }

    function test_addV4PoolRejectsNativeCurrency() public {
        PoolKey memory key = PoolKey(address(0), address(usdc), 3000, 60, address(0));
        vm.prank(admin);
        vm.expectRevert(VaultRegistry.NativeCurrencyNotAllowed.selector);
        registry.addV4Pool(key, MEME);
    }

    function test_addV4PoolRejectsUnsortedKey() public {
        PoolKey memory key = _usdcMemeKey(address(0));
        (key.currency0, key.currency1) = (key.currency1, key.currency0);
        vm.prank(admin);
        vm.expectRevert(VaultRegistry.InvalidPoolKey.selector);
        registry.addV4Pool(key, MEME);
    }

    function test_addV4PoolRejectsNonUsdcPair() public {
        address other = makeAddr("other");
        (address c0, address c1) = address(meme) < other ? (address(meme), other) : (other, address(meme));
        vm.prank(admin);
        vm.expectRevert(VaultRegistry.NotUsdcPair.selector);
        registry.addV4Pool(PoolKey(c0, c1, 3000, 60, address(0)), MEME);
    }

    function test_addV4PoolRejectsUnknownHookUntilAllowed() public {
        address hook = makeAddr("hook");
        PoolKey memory key = _usdcMemeKey(hook);
        _initV4(key);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.HookNotAllowed.selector, hook));
        registry.addV4Pool(key, MEME);

        vm.startPrank(admin);
        registry.setHookAllowed(hook, true);
        registry.addV4Pool(key, MEME);
        vm.stopPrank();
        assertEq(registry.poolCount(), 1);
    }

    // ---------------- enable / disable / reclassify ----------------

    function test_guardianDisablesPoolInstantly() public {
        bytes32 id = _addV4();
        vm.prank(guardian);
        registry.disablePool(id);
        assertFalse(registry.isEnabled(id));
    }

    function test_adminCanAlsoDisableAndReEnable() public {
        bytes32 id = _addV4();
        vm.startPrank(admin);
        registry.disablePool(id);
        registry.enablePool(id);
        vm.stopPrank();
        assertTrue(registry.isEnabled(id));
    }

    function test_strangerCannotDisable() public {
        bytes32 id = _addV4();
        vm.prank(alice);
        vm.expectRevert(VaultRegistry.Unauthorized.selector);
        registry.disablePool(id);
    }

    function test_guardianCannotEnable() public {
        bytes32 id = _addV4();
        vm.prank(guardian);
        registry.disablePool(id);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                guardian,
                registry.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(guardian);
        registry.enablePool(id);
    }

    function test_setPoolClass() public {
        bytes32 id = _addV4();
        VaultRegistry.ClassParams memory p = _memeParams();
        p.maxClassBps = 6_000;
        vm.startPrank(admin);
        registry.setClassParams(VaultRegistry.AssetClass.Volatile, p);
        registry.setPoolClass(id, VaultRegistry.AssetClass.Volatile);
        vm.stopPrank();
        assertEq(uint8(registry.getPool(id).assetClass), uint8(VaultRegistry.AssetClass.Volatile));
    }

    function test_unknownPoolReverts() public {
        bytes32 id = keccak256("nope");
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.UnknownPool.selector, id));
        registry.getPool(id);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(VaultRegistry.UnknownPool.selector, id));
        registry.disablePool(id);
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(VaultRegistry.ZeroAddress.selector);
        new VaultRegistry(address(0), address(v3Factory), address(stateView), admin, guardian);
        vm.expectRevert(VaultRegistry.ZeroAddress.selector);
        new VaultRegistry(address(usdc), address(v3Factory), address(stateView), address(0), guardian);
        vm.expectRevert(VaultRegistry.ZeroAddress.selector);
        new VaultRegistry(address(usdc), address(v3Factory), address(stateView), admin, address(0));
    }

    function _addV4() internal returns (bytes32 id) {
        PoolKey memory key = _usdcMemeKey(address(0));
        _initV4(key);
        vm.prank(admin);
        id = registry.addV4Pool(key, MEME);
    }
}
