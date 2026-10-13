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

/// @dev SwapRouter02's exactInputSingle (no deadline field, unlike the v1 SwapRouter).
interface ISwapRouter02Test {
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

    /// @dev Every mock token here exposes the same `mint(address,uint256)`.
    function _mint(address token, address to, uint256 amount) internal {
        MockERC20(token).mint(to, amount);
    }

    /// @dev Create and initialize (at tick 0) a second USDC/`other` pool, fund the
    /// harness and open a symmetric in-range position in it.
    function _openUsdcPool(address other, uint256 amount)
        internal
        returns (uint256 tokenId, uint128 liquidity)
    {
        (address t0, address t1) = address(usdc) < other ? (address(usdc), other) : (other, address(usdc));
        address p = IV3FactoryTest(v3.factory).createPool(t0, t1, FEE);
        IV3PoolTest(p).initialize(TickMath.getSqrtPriceAtTick(0));
        _mint(t0, address(harness), amount);
        _mint(t1, address(harness), amount);
        V3Positions.OpenParams memory params = _params(-600, 600, amount, amount);
        (params.token0, params.token1) = (t0, t1);
        (tokenId, liquidity,,) = harness.open(params);
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

    /// @dev Swap through SwapRouter02 (the router on Arc mainnet) to generate fees.
    function _swap(address tokenIn, uint256 amountIn) internal {
        _swapVia(v3.swapRouter02, tokenIn, tokenIn == token0 ? token1 : token0, amountIn, 0);
    }

    /// @dev Swap via `router` (a SwapRouter02), stopping at `sqrtPriceLimitX96` if non-zero.
    function _swapVia(address router, address tokenIn, address tokenOut, uint256 amountIn, uint160 limit)
        internal
    {
        _mint(tokenIn, trader, amountIn);
        vm.startPrank(trader);
        (bool ok,) = tokenIn.call(abi.encodeWithSignature("approve(address,uint256)", router, amountIn));
        require(ok, "approve");
        ISwapRouter02Test(router)
            .exactInputSingle(
                ISwapRouter02Test.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: FEE,
                    recipient: trader,
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: limit
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
