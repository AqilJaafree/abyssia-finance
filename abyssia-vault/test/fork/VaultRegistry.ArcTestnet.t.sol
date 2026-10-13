// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ArcTestnetFork} from "./ArcTestnetFork.sol";
import {VaultRegistry} from "../../src/registry/VaultRegistry.sol";
import {PoolKey, PoolKeyLib} from "../../src/types/PoolKey.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

interface IV3FactoryFull {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

interface IV3PoolInit {
    function initialize(uint160 sqrtPriceX96) external;
}

interface IPoolManagerInit {
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
}

/// @dev Registry against real Arc testnet state: the real v4 PoolManager/StateView
/// and Uniswap's official v3 factory bytecode deployed into the fork.
contract VaultRegistryArcTestnetTest is ArcTestnetFork {
    using PoolKeyLib for PoolKey;

    VaultRegistry internal registry;
    MockERC20 internal meme;
    address internal v3Factory;
    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    VaultRegistry.AssetClass internal constant MEME = VaultRegistry.AssetClass.Memecoin;

    function setUp() public {
        _fork();
        if (!forked) return;
        meme = new MockERC20("Meme", "MEME");
        v3Factory = _deployV3Factory();
        registry = new VaultRegistry(USDC, v3Factory, V4_STATE_VIEW, admin, guardian);
        vm.prank(admin);
        registry.setClassParams(
            MEME,
            VaultRegistry.ClassParams({
                maxAllocationBps: 500,
                maxClassBps: 2_000,
                allowedShapes: 4,
                maxRanges: 10,
                minWidthTicks: 60,
                maxWidthTicks: 6_000,
                stopLossBps: 3_000,
                rebalanceCooldown: 10 minutes,
                minPoolLiquidity: 1e12
            })
        );
    }

    function test_usdcIsSixDecimalErc20OnTestnet() public view {
        (bool ok, bytes memory ret) = USDC.staticcall(abi.encodeWithSignature("decimals()"));
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint8)), 6);
    }

    function test_addsRealV4PoolInitializedOnTestnetPoolManager() public {
        (address c0, address c1) = USDC < address(meme) ? (USDC, address(meme)) : (address(meme), USDC);
        PoolKey memory key = PoolKey(c0, c1, 3000, 60, address(0));
        IPoolManagerInit(V4_POOL_MANAGER).initialize(key, SQRT_PRICE_1_1);

        vm.prank(admin);
        bytes32 id = registry.addV4Pool(key, MEME);
        assertEq(id, key.toId());
        assertEq(registry.getPool(id).token, address(meme));
    }

    function test_rejectsV4PoolNotInitializedOnTestnet() public {
        (address c0, address c1) = USDC < address(meme) ? (USDC, address(meme)) : (address(meme), USDC);
        vm.prank(admin);
        vm.expectRevert(VaultRegistry.PoolNotFound.selector);
        registry.addV4Pool(PoolKey(c0, c1, 3000, 60, address(0)), MEME);
    }

    function test_addsV3PoolFromOfficialFactoryBytecode() public {
        address pool = IV3FactoryFull(v3Factory).createPool(USDC, address(meme), 3000);
        IV3PoolInit(pool).initialize(SQRT_PRICE_1_1);
        vm.prank(admin);
        bytes32 id = registry.addV3Pool(address(meme), 3000, MEME);
        VaultRegistry.PoolInfo memory info = registry.getPool(id);
        assertEq(info.v3Pool, pool);
        assertEq(info.fee, 3000);
        assertEq(info.tickSpacing, 60);
        assertEq(info.usdcIsToken0, USDC < address(meme));
    }

    function test_rejectsUninitializedV3Pool() public {
        IV3FactoryFull(v3Factory).createPool(USDC, address(meme), 3000);
        vm.prank(admin);
        vm.expectRevert(VaultRegistry.PoolNotFound.selector);
        registry.addV3Pool(address(meme), 3000, MEME);
    }
}
