// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ArcTestnetFork} from "./ArcTestnetFork.sol";
import {V4PositionsHarness} from "../v4/V4PositionsHarness.sol";
import {V4SwapHelper, IPoolManagerTest} from "../v4/V4SwapHelper.sol";
import {V4Positions} from "../../src/v4/V4Positions.sol";
import {IV4PositionManager} from "../../src/interfaces/IV4PositionManager.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";
import {IStateView} from "../../src/interfaces/IStateView.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFreezableERC20} from "../mocks/MockFreezableERC20.sol";

/// @dev V4Positions against the REAL Uniswap v4 deployment on Arc testnet (PoolManager,
/// PositionManager, StateView, canonical Permit2). Pools are created in-fork with a
/// 6-decimal mock USDC: Arc's USDC cannot be transferred inside a Foundry fork.
contract V4PositionsArcTestnetTest is ArcTestnetFork {
    uint24 internal constant FEE = 3000;
    int24 internal constant SPACING = 60;

    IV4PositionManager internal posm = IV4PositionManager(V4_POSITION_MANAGER);
    V4PositionsHarness internal harness;
    V4SwapHelper internal swapper;
    MockUSDC internal usdc;
    MockERC20 internal meme;
    PoolKey internal key;
    address internal receiver = makeAddr("receiver");
    address internal trader = makeAddr("trader");

    function setUp() public {
        _fork();
        if (!forked) return;
        harness = new V4PositionsHarness(posm, IPermit2(PERMIT2), IStateView(V4_STATE_VIEW));
        swapper = new V4SwapHelper(IPoolManagerTest(V4_POOL_MANAGER));
        usdc = new MockUSDC(6);
        meme = new MockERC20("Meme", "MEME");
        key = _initPool(address(meme));
    }

    function test_realDeploymentIsWired() public view {
        assertEq(posm.poolManager(), V4_POOL_MANAGER);
        assertEq(posm.permit2(), PERMIT2);
        assertGt(PERMIT2.code.length, 0);
    }

    /// Full lifecycle against the real contracts: open, earn fees, in-kind exit,
    /// harvest, full withdraw and close.
    function test_lifecycleOnRealV4() public {
        (uint256 tokenId, uint128 liquidity) = _open(key, 1_000e6);
        assertEq(posm.ownerOf(tokenId), address(harness));
        (uint160 permitAmount,,) = IPermit2(PERMIT2).allowance(address(harness), key.currency0, address(posm));
        assertEq(permitAmount, 0);

        _swap(key, address(usdc), 100e6);
        harness.inKindExit(1, 4, receiver);
        assertEq(posm.getPositionLiquidity(tokenId), liquidity - liquidity / 4);
        assertApproxEqAbs(harness.harvested(address(usdc)), 300_000, 2);
        assertGt(usdc.balanceOf(receiver), 0);
        assertGt(meme.balanceOf(receiver), 0);

        _swap(key, address(meme), 100e6);
        (uint256 f0, uint256 f1) = harness.collectFees(tokenId);
        assertGt(f0 + f1, 0);

        harness.withdraw(tokenId, posm.getPositionLiquidity(tokenId), address(harness));
        harness.close(tokenId);
        assertEq(harness.count(), 0);
    }

    /// The IOU fallback against the real PositionManager: a receiver blocked on one
    /// token still exits, with that slice owed to it.
    function test_blockedReceiverIouOnRealV4() public {
        MockFreezableERC20 hostile = new MockFreezableERC20("Hostile", "HOSTILE");
        PoolKey memory hk = _initPool(address(hostile));
        (uint256 hostileId, uint128 hostileLiq) = _open(hk, 1_000e6);
        _open(key, 1_000e6);
        hostile.setBlocked(receiver, true);

        harness.inKindExit(1, 4, receiver);

        assertEq(posm.getPositionLiquidity(hostileId), hostileLiq - hostileLiq / 4);
        assertGt(harness.owed(receiver, address(hostile)), 0);
        assertEq(hostile.balanceOf(receiver), 0);
        assertGt(meme.balanceOf(receiver), 0);
    }

    function _initPool(address other) internal returns (PoolKey memory k) {
        (address c0, address c1) = address(usdc) < other ? (address(usdc), other) : (other, address(usdc));
        k = PoolKey(c0, c1, FEE, SPACING, address(0));
        IPoolManagerTest(V4_POOL_MANAGER).initialize(k, TickMath.getSqrtPriceAtTick(0));
    }

    function _open(PoolKey memory k, uint256 amount) internal returns (uint256 tokenId, uint128 liquidity) {
        MockERC20(k.currency0).mint(address(harness), amount);
        MockERC20(k.currency1).mint(address(harness), amount);
        (tokenId, liquidity,,) = harness.open(
            V4Positions.OpenParams({
                key: k,
                tickLower: -600,
                tickUpper: 600,
                amount0Desired: amount,
                amount1Desired: amount,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
    }

    function _swap(PoolKey memory k, address tokenIn, uint256 amountIn) internal {
        bool zeroForOne = tokenIn == k.currency0;
        MockERC20(tokenIn).mint(address(swapper), amountIn);
        swapper.swap(
            k,
            zeroForOne,
            amountIn,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            trader
        );
    }
}
