// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @title PoolParams
/// @notice Prints the TMEME test pools' starting sqrt price (1 TMEME = 0.01 USDC), seed
/// amounts and full-range liquidity, for `arc-testnet-pools.sh` (which cannot use TestPools:
/// see there). Read-only; never broadcasts.
contract PoolParams is Script {
    function run(bool usdcIs0, uint256 seedUsdc) external pure {
        int24 tick = usdcIs0 ? int24(322_380) : int24(-322_380);
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        uint256 tokenSeed = seedUsdc * 1e14;
        (uint256 a0, uint256 a1) = usdcIs0 ? (seedUsdc, tokenSeed) : (tokenSeed, seedUsdc);
        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtP, TickMath.getSqrtPriceAtTick(-887_220), TickMath.getSqrtPriceAtTick(887_220), a0, a1
        );
        console2.log("sqrtP", sqrtP);
        console2.log("a0", a0);
        console2.log("a1", a1);
        console2.log("liquidity", liq);
    }
}
