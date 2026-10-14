// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ArcTestnetFork} from "./ArcTestnetFork.sol";
import {DeployUniswapV3} from "../../script/DeployUniswapV3.s.sol";
import {V4SwapHelper, IPoolManagerTest} from "../v4/V4SwapHelper.sol";
import {V4PositionsHarness} from "../v4/V4PositionsHarness.sol";
import {AbyssiaVault} from "../../src/AbyssiaVault.sol";
import {VaultRegistry} from "../../src/registry/VaultRegistry.sol";
import {VaultBook} from "../../src/libraries/VaultBook.sol";
import {VaultRebalance} from "../../src/libraries/VaultRebalance.sol";
import {Shapes} from "../../src/libraries/Shapes.sol";
import {V4Positions} from "../../src/v4/V4Positions.sol";
import {INonfungiblePositionManager as INPM} from "../../src/interfaces/INonfungiblePositionManager.sol";
import {IV4PositionManager} from "../../src/interfaces/IV4PositionManager.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";
import {IStateView} from "../../src/interfaces/IStateView.sol";
import {ISwapRouter02} from "../../src/interfaces/ISwapRouter02.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev The vault end to end on an Arc testnet fork: the REAL Uniswap v4 deployment
/// (PoolManager, PositionManager, StateView, Permit2) and Uniswap's official v3 deployed
/// into the fork (v3 is not on testnet). Uses a 6-decimal mock USDC: Arc's USDC cannot be
/// transferred inside a Foundry fork.
contract AbyssiaVaultArcTestnetTest is ArcTestnetFork {
    uint24 internal constant FEE = 3000;
    int24 internal constant FULL = 887_220;

    AbyssiaVault internal vault;
    VaultRegistry internal registry;
    MockUSDC internal usdc;
    MockERC20 internal meme;
    PoolKey internal key;
    bytes32 internal poolId;
    V4SwapHelper internal swapper;
    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");

    function setUp() public {
        _fork();
        if (!forked) return;
        DeployUniswapV3.Deployed memory v3 = new DeployUniswapV3().deployAll();
        usdc = new MockUSDC(6);
        meme = new MockERC20("Meme", "MEME");
        swapper = new V4SwapHelper(IPoolManagerTest(V4_POOL_MANAGER));

        (address c0, address c1) =
            address(usdc) < address(meme) ? (address(usdc), address(meme)) : (address(meme), address(usdc));
        key = PoolKey(c0, c1, FEE, 60, address(0));
        IPoolManagerTest(V4_POOL_MANAGER).initialize(key, TickMath.getSqrtPriceAtTick(0));
        V4PositionsHarness lp = new V4PositionsHarness(
            IV4PositionManager(V4_POSITION_MANAGER), IPermit2(PERMIT2), IStateView(V4_STATE_VIEW)
        );
        MockERC20(c0).mint(address(lp), 1e12);
        MockERC20(c1).mint(address(lp), 1e12);
        lp.open(V4Positions.OpenParams(key, -FULL, FULL, 1e12, 1e12, 0, 0, block.timestamp));

        registry = new VaultRegistry(address(usdc), v3.factory, V4_STATE_VIEW, admin, guardian);
        vm.startPrank(admin);
        registry.setClassParams(
            VaultRegistry.AssetClass.Memecoin,
            VaultRegistry.ClassParams(3_000, 3_000, 7, 10, 60, 120_000, 3_000, 10 minutes, 1e9)
        );
        poolId = registry.addV4Pool(key, VaultRegistry.AssetClass.Memecoin);
        vm.stopPrank();

        vault = new AbyssiaVault(
            AbyssiaVault.Config({
                usdc: usdc,
                name: "Abyssia Memecoin Vault",
                symbol: "abMEME",
                admin: admin,
                keeper: keeper,
                guardian: guardian,
                minDeposit: 1e6,
                maxTotalAssets: 1_000_000e6,
                maxCycleMoveBps: 2_000,
                maxSwapSlippageBps: 500,
                registry: registry,
                npm: INPM(v3.positionManager),
                swapRouter02: ISwapRouter02(v3.swapRouter02),
                posm: IV4PositionManager(V4_POSITION_MANAGER),
                stateView: IStateView(V4_STATE_VIEW),
                blockTimeMs: 500
            })
        );
    }

    function test_wiredToRealV4() public view {
        assertEq(address(vault.poolManager()), V4_POOL_MANAGER);
        assertEq(address(vault.permit2()), PERMIT2);
    }

    /// Deposit, swap and open on the real v4, earn fees, settle (harvest), exit in kind.
    function test_lifecycleOnRealV4() public {
        usdc.mint(alice, 10_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 10_000e6);
        vault.requestDeposit(10_000e6);
        vm.stopPrank();
        vm.warp(block.timestamp + vault.minSettleInterval());
        uint256 price = vault.sharePrice();
        vm.prank(keeper);
        vault.settle(price);
        vm.prank(alice);
        vault.claimDeposit(1, alice);

        // The guardian posts the v4 pool's first reference tick (its price now).
        (, int24 start,,) = IStateView(V4_STATE_VIEW).getSlot0(poolId);
        vm.prank(guardian);
        vault.postReferenceTick(poolId, start);

        vm.startPrank(keeper);
        uint256 got = vault.swap(poolId, true, 1_000e6, 950e6); // floor: 1:1 price minus 5%
        (, int24 tick,,) = IStateView(V4_STATE_VIEW).getSlot0(poolId);
        vault.rebalance(
            VaultRebalance.Args(
                poolId, Shapes.Spec(Shapes.SPOT, Shapes.BOTH, 1, 1200), 1_000e6, got, tick, block.timestamp
            )
        );
        vm.stopPrank();
        uint256 id = vault.positionAt(VaultBook.Protocol.V4, 0);
        assertEq(IV4PositionManager(V4_POSITION_MANAGER).ownerOf(id), address(vault));

        _traderSwap(address(meme), 500e6);
        _traderSwap(address(usdc), 500e6);
        uint256 idleBefore = vault.idleAssets();
        vm.warp(block.timestamp + vault.minSettleInterval());
        price = vault.sharePrice();
        vm.prank(keeper);
        vault.settle(price);
        assertGt(vault.idleAssets(), idleBefore);

        address receiver = makeAddr("receiver");
        uint256 shares = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        vault.redeemInKind(shares, receiver);
        assertGt(usdc.balanceOf(receiver), 4_000e6);
        assertGt(meme.balanceOf(receiver), 0);
    }

    function _traderSwap(address tokenIn, uint256 amountIn) internal {
        bool zeroForOne = tokenIn == key.currency0;
        MockERC20(tokenIn).mint(address(swapper), amountIn);
        swapper.swap(
            key,
            zeroForOne,
            amountIn,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            makeAddr("trader")
        );
    }
}
