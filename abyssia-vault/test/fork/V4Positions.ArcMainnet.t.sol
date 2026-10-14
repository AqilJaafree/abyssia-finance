// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ArcMainnetFork} from "./ArcMainnetFork.sol";
import {DeployAbyssia} from "../../script/DeployAbyssia.s.sol";
import {V4PositionsHarness} from "../v4/V4PositionsHarness.sol";
import {V4SwapHelper, IPoolManagerTest} from "../v4/V4SwapHelper.sol";
import {V4Positions} from "../../src/v4/V4Positions.sol";
import {IV4PositionManager} from "../../src/interfaces/IV4PositionManager.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";
import {IStateView} from "../../src/interfaces/IStateView.sol";
import {PoolKey, PoolKeyLib} from "../../src/types/PoolKey.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

interface IStateViewManager {
    function poolManager() external view returns (address);
}

/// @dev V4Positions against the REAL Uniswap v4 deployment on Arc mainnet, at the addresses
/// DeployAbyssia pins for chain 5042. Pools are created in-fork with a 6-decimal mock USDC:
/// Arc's USDC cannot be transferred inside a Foundry fork.
contract V4PositionsArcMainnetTest is ArcMainnetFork {
    using PoolKeyLib for PoolKey;

    uint24 internal constant FEE = 3000;
    int24 internal constant SPACING = 60;
    address internal constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    DeployAbyssia.Network internal n;
    IV4PositionManager internal posm;
    V4PositionsHarness internal harness;
    V4SwapHelper internal swapper;
    MockUSDC internal usdc;
    MockERC20 internal meme;
    PoolKey internal key;
    address internal receiver = makeAddr("receiver");
    address internal trader = makeAddr("trader");

    function setUp() public {
        _forkMainnet();
        if (!forked) return;
        n = new DeployAbyssia().network(block.chainid);
        posm = IV4PositionManager(n.posm);
        harness = new V4PositionsHarness(posm, IPermit2(PERMIT2), IStateView(n.stateView));
        swapper = new V4SwapHelper(IPoolManagerTest(V4_POOL_MANAGER));
        usdc = new MockUSDC(6);
        meme = new MockERC20("Meme", "MEME");
        (address c0, address c1) =
            address(usdc) < address(meme) ? (address(usdc), address(meme)) : (address(meme), address(usdc));
        key = PoolKey(c0, c1, FEE, SPACING, address(0));
        IPoolManagerTest(V4_POOL_MANAGER).initialize(key, TickMath.getSqrtPriceAtTick(0));
    }

    /// The pinned PositionManager and StateView are wired to the same PoolManager and Permit2.
    function test_pinnedV4AddressesAreWired() public view {
        assertEq(posm.poolManager(), V4_POOL_MANAGER);
        assertEq(posm.permit2(), PERMIT2);
        assertEq(IStateViewManager(n.stateView).poolManager(), V4_POOL_MANAGER);
        assertGt(PERMIT2.code.length, 0);
        assertEq(n.blockTimeMs, 500);
    }

    /// Open, earn fees, in-kind exit, harvest, withdraw and close on the real contracts;
    /// StateView reads the pool the vault would price.
    function test_lifecycleOnRealV4() public {
        MockERC20(key.currency0).mint(address(harness), 1_000e6);
        MockERC20(key.currency1).mint(address(harness), 1_000e6);
        (uint256 tokenId, uint128 liquidity,,) =
            harness.open(V4Positions.OpenParams(key, -600, 600, 1_000e6, 1_000e6, 0, 0, block.timestamp));
        assertEq(posm.ownerOf(tokenId), address(harness));
        assertEq(IStateView(n.stateView).getLiquidity(key.toId()), liquidity);

        _swap(address(usdc), 100e6);
        harness.inKindExit(1, 4, receiver);
        assertEq(posm.getPositionLiquidity(tokenId), liquidity - liquidity / 4);
        assertGt(usdc.balanceOf(receiver), 0);
        assertGt(meme.balanceOf(receiver), 0);

        _swap(address(meme), 100e6);
        (uint256 f0, uint256 f1) = harness.collectFees(tokenId);
        assertGt(f0 + f1, 0);
        harness.withdraw(tokenId, posm.getPositionLiquidity(tokenId), address(harness));
        harness.close(tokenId);
        assertEq(harness.count(), 0);
    }

    function _swap(address tokenIn, uint256 amountIn) internal {
        bool zeroForOne = tokenIn == key.currency0;
        MockERC20(tokenIn).mint(address(swapper), amountIn);
        swapper.swap(
            key,
            zeroForOne,
            amountIn,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            trader
        );
    }
}
