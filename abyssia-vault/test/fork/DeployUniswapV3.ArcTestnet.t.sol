// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ArcTestnetFork} from "./ArcTestnetFork.sol";
import {DeployUniswapV3} from "../../script/DeployUniswapV3.s.sol";
import {V3Positions} from "../../src/v3/V3Positions.sol";
import {INonfungiblePositionManager as INPM} from "../../src/interfaces/INonfungiblePositionManager.sol";
import {V3PositionsHarness} from "../v3/V3PositionsHarness.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

interface IV3FactoryDeploy {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

interface IV3PoolDeploy {
    function initialize(uint160 sqrtPriceX96) external;
}

/// @dev Rehearses the testnet v3 deployment on a fork of Arc testnet, then opens a
/// position through it — the exact path a real testnet deployment will take.
contract DeployUniswapV3ArcTestnetTest is ArcTestnetFork {
    DeployUniswapV3.Deployed internal d;

    function setUp() public {
        _fork();
        if (!forked) return;
        d = new DeployUniswapV3().deployAll();
    }

    function test_deploysWiredV3OnTestnet() public view {
        assertEq(INPM(d.positionManager).factory(), d.factory);
        assertGt(d.swapRouter.code.length, 0);
    }

    function test_positionLifecycleOnTestnetDeployment() public {
        MockUSDC usdc = new MockUSDC(6);
        MockERC20 meme = new MockERC20("Meme", "MEME");
        (address t0, address t1) =
            address(usdc) < address(meme) ? (address(usdc), address(meme)) : (address(meme), address(usdc));
        address pool = IV3FactoryDeploy(d.factory).createPool(t0, t1, 3000);
        IV3PoolDeploy(pool).initialize(TickMath.getSqrtPriceAtTick(0));

        V3PositionsHarness harness = new V3PositionsHarness(INPM(d.positionManager));
        usdc.mint(address(harness), 100e6);
        meme.mint(address(harness), 100e6);
        (uint256 tokenId, uint128 liquidity,,) =
            harness.open(V3Positions.OpenParams(t0, t1, 3000, -600, 600, 100e6, 100e6, 0, 0, block.timestamp));
        harness.withdraw(tokenId, liquidity, address(harness));
        harness.collectFees(tokenId, address(harness));
        harness.close(tokenId);
        assertEq(harness.count(), 0);
    }
}
