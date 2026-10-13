// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ArcMainnetFork} from "./ArcMainnetFork.sol";
import {V3Positions} from "../../src/v3/V3Positions.sol";
import {INonfungiblePositionManager as INPM} from "../../src/interfaces/INonfungiblePositionManager.sol";
import {V3PositionsHarness} from "../v3/V3PositionsHarness.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

interface IV3FactoryFork {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

interface IV3PoolFork {
    function initialize(uint160 sqrtPriceX96) external;
}

interface ISwapRouter02Fork {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
    function factory() external view returns (address);
    function positionManager() external view returns (address);
}

/// @dev V3Positions against Uniswap's REAL Arc mainnet NonfungiblePositionManager.
/// Arc USDC can't be moved inside a fork (it relies on an Arc precompile), so the
/// pool pairs a 6-decimal USDC mock with a memecoin mock on the real factory.
contract V3PositionsArcMainnetTest is ArcMainnetFork {
    V3PositionsHarness internal harness;
    MockUSDC internal usdc;
    MockERC20 internal meme;
    address internal token0;
    address internal token1;

    function setUp() public {
        _forkMainnet();
        if (!forked) return;
        usdc = new MockUSDC(6);
        meme = new MockERC20("Meme", "MEME");
        (token0, token1) =
            address(usdc) < address(meme) ? (address(usdc), address(meme)) : (address(meme), address(usdc));
        address pool = IV3FactoryFork(V3_FACTORY).createPool(token0, token1, 3000);
        IV3PoolFork(pool).initialize(TickMath.getSqrtPriceAtTick(0));
        harness = new V3PositionsHarness(INPM(V3_POSITION_MANAGER));
        usdc.mint(address(harness), 1_000e6);
        meme.mint(address(harness), 1_000e6);
    }

    function test_realPositionManagerIsWiredToRealFactory() public view {
        assertEq(INPM(V3_POSITION_MANAGER).factory(), V3_FACTORY);
    }

    function test_openValueWithdrawCloseOnRealPositionManager() public {
        (uint256 tokenId, uint128 liquidity, uint256 a0, uint256 a1) = harness.open(
            V3Positions.OpenParams({
                token0: token0,
                token1: token1,
                fee: 3000,
                tickLower: -600,
                tickUpper: 600,
                amount0Desired: 1_000e6,
                amount1Desired: 1_000e6,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        assertEq(INPM(V3_POSITION_MANAGER).ownerOf(tokenId), address(harness));

        (uint256 v0, uint256 v1) = harness.positionAmounts(tokenId);
        assertApproxEqAbs(v0, a0, 1);
        assertApproxEqAbs(v1, a1, 1);

        harness.withdraw(tokenId, liquidity, address(harness));
        harness.collectFees(tokenId, address(harness));
        harness.close(tokenId);
        assertEq(harness.count(), 0);
    }

    /// @dev The mock pool is driven through Uniswap's REAL Arc mainnet SwapRouter02, then
    /// fees are harvested and an in-kind exit runs on the real position manager.
    function test_realSwapRouter02FeesAndInKindExit() public {
        ISwapRouter02Fork router = ISwapRouter02Fork(V3_SWAP_ROUTER_02);
        assertEq(router.factory(), V3_FACTORY);
        assertEq(router.positionManager(), V3_POSITION_MANAGER);

        (uint256 tokenId, uint128 liquidity,,) = harness.open(
            V3Positions.OpenParams(token0, token1, 3000, -600, 600, 1_000e6, 1_000e6, 0, 0, block.timestamp)
        );

        address trader = makeAddr("trader");
        usdc.mint(trader, 100e6);
        vm.startPrank(trader);
        usdc.approve(V3_SWAP_ROUTER_02, 100e6);
        uint256 out = router.exactInputSingle(
            ISwapRouter02Fork.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: address(meme),
                fee: 3000,
                recipient: trader,
                amountIn: 100e6,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();
        assertGt(out, 0);
        assertEq(meme.balanceOf(trader), out);

        (uint256 f0, uint256 f1) = harness.collectFees(tokenId, address(harness));
        assertGt(f0 + f1, 0);

        address receiver = makeAddr("receiver");
        harness.inKindExit(1, 4, receiver); // 25%
        (,,,,,,, uint128 left,,,,) = INPM(V3_POSITION_MANAGER).positions(tokenId);
        assertEq(left, liquidity - liquidity / 4);
        assertGt(usdc.balanceOf(receiver), 0);
        assertGt(meme.balanceOf(receiver), 0);
    }
}
