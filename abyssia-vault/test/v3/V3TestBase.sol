// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {DeployUniswapV3} from "../../script/DeployUniswapV3.s.sol";
import {V3Positions} from "../../src/v3/V3Positions.sol";
import {INonfungiblePositionManager as INPM} from "../../src/interfaces/INonfungiblePositionManager.sol";
import {V3PositionsHarness} from "./V3PositionsHarness.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

interface IV3FactoryTest {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

interface IV3PoolTest {
    function initialize(uint160 sqrtPriceX96) external;
}

interface ISwapRouterTest {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);
}

/// @dev Deploys Uniswap's official v3 bytecode locally (no RPC needed), a 6-dec USDC
/// mock and an 18-dec memecoin, and one USDC/MEME 0.3% pool initialized at tick 0.
abstract contract V3TestBase is Test {
    uint24 internal constant FEE = 3000;
    int24 internal constant SPACING = 60;

    DeployUniswapV3.Deployed internal v3;
    INPM internal npm;
    V3PositionsHarness internal harness;
    MockUSDC internal usdc;
    MockERC20 internal meme;
    address internal token0;
    address internal token1;
    address internal pool;
    address internal trader = makeAddr("trader");

    function setUp() public virtual {
        v3 = new DeployUniswapV3().deployAll();
        npm = INPM(v3.positionManager);
        usdc = new MockUSDC(6);
        meme = new MockERC20("Meme", "MEME");
        (token0, token1) =
            address(usdc) < address(meme) ? (address(usdc), address(meme)) : (address(meme), address(usdc));
        pool = IV3FactoryTest(v3.factory).createPool(token0, token1, FEE);
        IV3PoolTest(pool).initialize(TickMath.getSqrtPriceAtTick(0));
        harness = new V3PositionsHarness(npm);
    }

    function _fundHarness(uint256 amount0, uint256 amount1) internal {
        _mint(token0, address(harness), amount0);
        _mint(token1, address(harness), amount1);
    }

    function _mint(address token, address to, uint256 amount) internal {
        if (token == address(usdc)) usdc.mint(to, amount);
        else meme.mint(to, amount);
    }

    function _params(int24 lower, int24 upper, uint256 a0, uint256 a1)
        internal
        view
        returns (V3Positions.OpenParams memory)
    {
        return V3Positions.OpenParams({
            token0: token0,
            token1: token1,
            fee: FEE,
            tickLower: lower,
            tickUpper: upper,
            amount0Desired: a0,
            amount1Desired: a1,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });
    }

    /// @dev Fund and open a symmetric in-range position.
    function _openInRange(uint256 amount) internal returns (uint256 tokenId, uint128 liquidity) {
        _fundHarness(amount, amount);
        (tokenId, liquidity,,) = harness.open(_params(-600, 600, amount, amount));
    }

    /// @dev Swap through the official SwapRouter to generate fees.
    function _swap(address tokenIn, uint256 amountIn) internal {
        address tokenOut = tokenIn == token0 ? token1 : token0;
        _mint(tokenIn, trader, amountIn);
        vm.startPrank(trader);
        (bool ok,) =
            tokenIn.call(abi.encodeWithSignature("approve(address,uint256)", v3.swapRouter, amountIn));
        require(ok, "approve");
        ISwapRouterTest(v3.swapRouter)
            .exactInputSingle(
                ISwapRouterTest.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: FEE,
                    recipient: trader,
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        vm.stopPrank();
    }

    function _liquidity(uint256 tokenId) internal view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = npm.positions(tokenId);
    }

    function _bal(address token, address who) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        require(ok);
        return abi.decode(ret, (uint256));
    }
}
