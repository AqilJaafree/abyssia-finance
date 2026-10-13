// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VaultRegistry} from "../../src/registry/VaultRegistry.sol";
import {PoolKey, PoolKeyLib} from "../../src/types/PoolKey.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockV3Factory} from "../mocks/MockV3Factory.sol";
import {MockStateView} from "../mocks/MockStateView.sol";
import {MockV3Pool} from "../mocks/MockV3Pool.sol";

abstract contract RegistryTestBase is Test {
    using PoolKeyLib for PoolKey;

    VaultRegistry internal registry;
    MockUSDC internal usdc;
    MockERC20 internal meme;
    MockV3Factory internal v3Factory;
    MockStateView internal stateView;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");

    function setUp() public virtual {
        usdc = new MockUSDC(6);
        meme = new MockERC20("Meme", "MEME");
        v3Factory = new MockV3Factory();
        stateView = new MockStateView();
        registry = new VaultRegistry(address(usdc), address(v3Factory), address(stateView), admin, guardian);
    }

    /// @dev Illustrative memecoin-class params (test fixture, not a production setting).
    function _memeParams() internal pure returns (VaultRegistry.ClassParams memory) {
        return VaultRegistry.ClassParams({
            maxAllocationBps: 500,
            maxClassBps: 2_000,
            allowedShapes: 4, // Bid-Ask
            maxRanges: 10,
            minWidthTicks: 60,
            maxWidthTicks: 6_000,
            stopLossBps: 3_000,
            rebalanceCooldown: 10 minutes,
            minPoolLiquidity: 1e12
        });
    }

    function _configureMeme() internal {
        vm.prank(admin);
        registry.setClassParams(VaultRegistry.AssetClass.Memecoin, _memeParams());
    }

    function _usdcMemeKey(address hooks) internal view returns (PoolKey memory key) {
        (address c0, address c1) =
            address(usdc) < address(meme) ? (address(usdc), address(meme)) : (address(meme), address(usdc));
        key = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: hooks});
    }

    /// @dev Deploy an initialized mock v3 USDC/meme pool and register it in the mock factory.
    function _deployV3Pool(uint24 fee) internal returns (address pool) {
        MockV3Pool p = new MockV3Pool();
        p.setSqrtPrice(79228162514264337593543950336); // price 1.0
        pool = address(p);
        v3Factory.setPool(address(usdc), address(meme), fee, pool);
    }

    /// @dev Make a v4 key "exist" in the mock StateView.
    function _initV4(PoolKey memory key) internal returns (bytes32 id) {
        id = key.toId();
        stateView.setSqrtPrice(id, 79228162514264337593543950336); // price 1.0
    }
}
