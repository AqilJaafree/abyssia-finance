// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {V4Deployer} from "./V4Deployer.sol";
import {V4SwapHelper, IPoolManagerTest} from "./V4SwapHelper.sol";
import {V4PositionsHarness} from "./V4PositionsHarness.sol";
import {V4Positions} from "../../src/v4/V4Positions.sol";
import {IV4PositionManager} from "../../src/interfaces/IV4PositionManager.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";
import {IStateView} from "../../src/interfaces/IStateView.sol";
import {PoolKey, PoolKeyLib} from "../../src/types/PoolKey.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Deploys Uniswap's official v4 bytecode locally (no RPC needed), a 6-dec USDC
/// mock and an 18-dec memecoin, and one hookless USDC/MEME 0.3% pool initialized at tick 0.
abstract contract V4TestBase is V4Deployer {
    using PoolKeyLib for PoolKey;

    uint24 internal constant FEE = 3000;
    int24 internal constant SPACING = 60;

    V4 internal v4;
    IV4PositionManager internal posm;
    IStateView internal stateView;
    V4PositionsHarness internal harness;
    V4SwapHelper internal swapper;
    MockUSDC internal usdc;
    MockERC20 internal meme;
    PoolKey internal key;
    address internal token0;
    address internal token1;
    address internal trader = makeAddr("trader");

    function setUp() public virtual {
        v4 = _deployV4();
        _wire(v4);
        usdc = new MockUSDC(6);
        meme = new MockERC20("Meme", "MEME");
        key = _initPool(address(meme));
        (token0, token1) = (key.currency0, key.currency1);
    }

    function _wire(V4 memory d) internal {
        posm = IV4PositionManager(d.positionManager);
        stateView = IStateView(d.stateView);
        harness = new V4PositionsHarness(posm, IPermit2(d.permit2), stateView);
        swapper = new V4SwapHelper(IPoolManagerTest(d.poolManager));
    }

    /// @dev Create a hookless USDC/`other` pool at tick 0.
    function _initPool(address other) internal returns (PoolKey memory k) {
        (address c0, address c1) = address(usdc) < other ? (address(usdc), other) : (other, address(usdc));
        k = PoolKey(c0, c1, FEE, SPACING, address(0));
        IPoolManagerTest(v4.poolManager).initialize(k, TickMath.getSqrtPriceAtTick(0));
    }

    function _params(PoolKey memory k, int24 lower, int24 upper, uint256 a0, uint256 a1)
        internal
        view
        returns (V4Positions.OpenParams memory)
    {
        return V4Positions.OpenParams({
            key: k,
            tickLower: lower,
            tickUpper: upper,
            amount0Desired: a0,
            amount1Desired: a1,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });
    }

    /// @dev Every mock token here exposes the same `mint(address,uint256)`.
    function _mint(address token, address to, uint256 amount) internal {
        MockERC20(token).mint(to, amount);
    }

    /// @dev Fund the harness and open a symmetric in-range position in `k`.
    function _openIn(PoolKey memory k, uint256 amount) internal returns (uint256 tokenId, uint128 liquidity) {
        _mint(k.currency0, address(harness), amount);
        _mint(k.currency1, address(harness), amount);
        (tokenId, liquidity,,) = harness.open(_params(k, -600, 600, amount, amount));
    }

    function _openInRange(uint256 amount) internal returns (uint256 tokenId, uint128 liquidity) {
        return _openIn(key, amount);
    }

    /// @dev Create a fresh USDC/`other` pool and open a symmetric position in it.
    function _openUsdcPool(address other, uint256 amount) internal returns (uint256, uint128) {
        return _openIn(_initPool(other), amount);
    }

    /// @dev Exact-input swap of `amountIn` of `tokenIn` in `k`, stopping at `limit` (0 = none).
    function _swapIn(PoolKey memory k, address tokenIn, uint256 amountIn, uint160 limit) internal {
        bool zeroForOne = tokenIn == k.currency0;
        if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        _mint(tokenIn, address(swapper), amountIn);
        swapper.swap(k, zeroForOne, amountIn, limit, trader);
    }

    function _swap(address tokenIn, uint256 amountIn) internal {
        _swapIn(key, tokenIn, amountIn, 0);
    }

    function _liquidity(uint256 tokenId) internal view returns (uint128) {
        return posm.getPositionLiquidity(tokenId);
    }

    function _sqrtPrice(PoolKey memory k) internal view returns (uint160 sqrtP) {
        (sqrtP,,,) = stateView.getSlot0(k.toId());
    }

    function _bal(address token, address who) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        require(ok);
        return abi.decode(ret, (uint256));
    }
}
