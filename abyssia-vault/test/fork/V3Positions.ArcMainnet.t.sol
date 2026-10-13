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
}
