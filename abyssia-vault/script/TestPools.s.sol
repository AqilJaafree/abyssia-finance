// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {INonfungiblePositionManager as INPM} from "../src/interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {IV4PositionManager} from "../src/interfaces/IV4PositionManager.sol";
import {IPermit2} from "../src/interfaces/IPermit2.sol";
import {PoolKey} from "../src/types/PoolKey.sol";
import {DeployAbyssia} from "./DeployAbyssia.s.sol";

/// @dev Test memecoin for Sepolia: 18 decimals, a fixed supply minted once to `holder`.
contract AbyssiaTestToken is ERC20 {
    constructor(address holder, uint256 supply) ERC20("Abyssia Test Meme", "TMEME") {
        _mint(holder, supply);
    }
}

interface IV3FactoryCreate {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address);
}

interface IV3PoolInit {
    function initialize(uint160 sqrtPriceX96) external;
}

interface IPoolManagerInit {
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24);
}

/// @title TestPools
/// @notice TESTNET ONLY (Ethereum Sepolia; Arc testnet uses script/arc-testnet-pools.sh). Deploys a test memecoin (TMEME) and gives it a
/// USDC 0.3% pool on Uniswap v3 and a hookless one on v4, both at 1 TMEME = 0.01 USDC with
/// full-range liquidity from the deployer's USDC, and raises the v3 pool's observation
/// capacity to `OBSERVATIONS` (the vault refuses v3 pools below its floor). Then run
/// DeployAbyssia with ALLOW_TOKEN set to the printed token address.
/// Uniswap and USDC addresses come from DeployAbyssia's per-chain pins.
/// @dev Usage:
///   DEPLOYER_PRIVATE_KEY=0x... SEED_USDC=2000000 forge script script/TestPools.s.sol \
///     --tc TestPools --rpc-url $RPC_URL --broadcast --slow --skip-simulation
/// `--skip-simulation` makes forge take gas limits from the node: forge's local EVM
/// prices storage and code deposit below Sepolia's Glamsterdam schedule.
contract TestPools is Script {
    uint256 internal constant SEPOLIA = 11_155_111;
    uint24 internal constant FEE = 3000;
    int24 internal constant SPACING = 60;
    int24 internal constant FULL = 887_220;
    /// @dev 1 TMEME (1e18) = 0.01 USDC (1e4): raw price 1e14 (or 1e-14), ~ tick 322,378.
    int24 internal constant PRICE_TICK = 322_380;
    /// @dev Observation capacity for the v3 pool (the vault's default floor), raised in chunks:
    /// Sepolia caps a transaction at 2^24 gas and, since Glamsterdam, each new slot costs ~111k.
    uint16 internal constant OBSERVATIONS = 1_500;
    uint16 internal constant OBSERVATION_CHUNK = 100;
    uint8 internal constant MINT_POSITION = 0x02;
    uint8 internal constant SETTLE_PAIR = 0x0d;

    struct Pools {
        address token;
        address v3Pool;
        PoolKey v4Key;
    }

    function run() external returns (Pools memory p) {
        // Arc testnet: forge's local EVM lacks Arc USDC's precompile, so every USDC transfer
        // reverts before broadcast. Use script/arc-testnet-pools.sh there.
        require(block.chainid == SEPOLIA, "TestPools: Sepolia only (Arc testnet: arc-testnet-pools.sh)");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 seedUsdc = vm.envUint("SEED_USDC");
        // Looked up before broadcasting: `new` inside the broadcast would deploy on-chain.
        DeployAbyssia.Network memory n = new DeployAbyssia().network(block.chainid);
        vm.startBroadcast(pk);
        p = deployPools(n, seedUsdc, vm.addr(pk));
        vm.stopBroadcast();
        console2.log("TMEME", p.token);
        console2.log("v3 pool", p.v3Pool);
    }

    /// @notice Everything above; `actor` sends the calls and pays `seedUsdc` per pool.
    function deployPools(DeployAbyssia.Network memory n, uint256 seedUsdc, address actor)
        public
        returns (Pools memory p)
    {
        address usdc = n.usdc;
        address npm = n.npm;
        address posm = n.posm;
        address permit2 = IV4PositionManager(posm).permit2();
        uint256 tokenSeed = seedUsdc * 1e14; // TMEME worth the USDC at 0.01 USDC each
        p.token = address(new AbyssiaTestToken(actor, 2 * tokenSeed));
        bool usdcIs0 = usdc < p.token;
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(usdcIs0 ? PRICE_TICK : -PRICE_TICK);
        (address t0, address t1) = usdcIs0 ? (usdc, p.token) : (p.token, usdc);
        (uint256 a0, uint256 a1) = usdcIs0 ? (seedUsdc, tokenSeed) : (tokenSeed, seedUsdc);

        // v3: create, initialize, raise observation capacity, seed full range.
        p.v3Pool = IV3FactoryCreate(n.v3Factory).createPool(t0, t1, FEE);
        IV3PoolInit(p.v3Pool).initialize(sqrtP);
        for (uint16 next = OBSERVATION_CHUNK; next <= OBSERVATIONS; next += OBSERVATION_CHUNK) {
            IUniswapV3Pool(p.v3Pool).increaseObservationCardinalityNext(next);
        }
        // initialize and mint are separate transactions: the minimums stop a mint at a price
        // someone moved in between (the v4 mint below is capped by its maximums instead).
        IERC20(t0).approve(npm, a0);
        IERC20(t1).approve(npm, a1);
        INPM(npm)
            .mint(
                INPM.MintParams(
                    t0,
                    t1,
                    FEE,
                    -FULL,
                    FULL,
                    a0,
                    a1,
                    a0 * 99 / 100,
                    a1 * 99 / 100,
                    actor,
                    block.timestamp + 1 hours
                )
            );
        IERC20(t0).approve(npm, 0);
        IERC20(t1).approve(npm, 0);

        // v4: initialize a hookless pool, seed full range through Permit2.
        p.v4Key = PoolKey(t0, t1, FEE, SPACING, address(0));
        IPoolManagerInit(IV4PositionManager(posm).poolManager()).initialize(p.v4Key, sqrtP);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(-FULL), TickMath.getSqrtPriceAtTick(FULL), a0, a1
        );
        IERC20(t0).approve(permit2, a0);
        IERC20(t1).approve(permit2, a1);
        IPermit2(permit2).approve(t0, posm, uint160(a0), uint48(block.timestamp + 1 hours));
        IPermit2(permit2).approve(t1, posm, uint160(a1), uint48(block.timestamp + 1 hours));
        bytes[] memory params = new bytes[](2);
        params[0] =
            abi.encode(p.v4Key, -FULL, FULL, uint256(liquidity), uint128(a0), uint128(a1), actor, bytes(""));
        params[1] = abi.encode(t0, t1);
        IV4PositionManager(posm)
            .modifyLiquidities(
                abi.encode(abi.encodePacked(MINT_POSITION, SETTLE_PAIR), params), block.timestamp + 1 hours
            );
        // No allowance is left behind.
        IPermit2(permit2).approve(t0, posm, 0, 0);
        IPermit2(permit2).approve(t1, posm, 0, 0);
        IERC20(t0).approve(permit2, 0);
        IERC20(t1).approve(permit2, 0);
    }
}
