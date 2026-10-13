// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {V3TestBase} from "./V3TestBase.sol";

contract V3PositionsFuzzTest is V3TestBase {
    /// @dev The in-kind exit removes exactly floor(liquidity * shares / supply) from a
    /// position — never more than the exiting holder's share.
    function testFuzz_inKindExitIsExactShare(uint256 shares, uint256 supply) public {
        supply = bound(supply, 1, 1e30);
        shares = bound(shares, 0, supply);
        (uint256 tokenId, uint128 liquidity) = _openInRange(1_000e6);
        harness.inKindExit(shares, supply, makeAddr("receiver"));
        uint256 removed = uint256(liquidity) * shares / supply;
        assertEq(_liquidity(tokenId), liquidity - removed);
    }

    /// @dev Principal reported by positionAmounts never exceeds what a full withdraw pays out.
    function testFuzz_positionAmountsNeverOverstate(uint256 amount, int24 lowerMul, int24 width) public {
        amount = bound(amount, 1e6, 1e12);
        int24 lower = int24(bound(lowerMul, -20, 19)) * SPACING;
        int24 upper = lower + int24(bound(width, 1, 20)) * SPACING;
        _fundHarness(amount, amount);
        (uint256 tokenId, uint128 liquidity,,) = harness.open(_params(lower, upper, amount, amount));
        if (liquidity == 0) return;
        (uint256 v0, uint256 v1) = harness.positionAmounts(tokenId);
        (uint256 out0, uint256 out1) = harness.withdraw(tokenId, liquidity, makeAddr("receiver"));
        assertLe(v0, out0);
        assertLe(v1, out1);
    }

    /// @dev Same bound after the pool price has moved by a fuzzed swap in a fuzzed
    /// direction (possibly out of the position's range).
    function testFuzz_positionAmountsNeverOverstateAfterSwap(
        uint256 amount,
        int24 lowerMul,
        int24 width,
        uint256 swapIn,
        bool zeroForOne
    ) public {
        amount = bound(amount, 1e6, 1e12);
        int24 lower = int24(bound(lowerMul, -20, 19)) * SPACING;
        int24 upper = lower + int24(bound(width, 1, 20)) * SPACING;
        _fundHarness(amount, amount);
        (uint256 tokenId, uint128 liquidity,,) = harness.open(_params(lower, upper, amount, amount));
        if (liquidity == 0) return;
        // Full-range background liquidity so the swap never runs into an empty tick
        // range (the router rejects a swap that settles 0/0).
        _fundHarness(1e12, 1e12);
        harness.open(_params(-887_220, 887_220, 1e12, 1e12));
        _swap(zeroForOne ? token0 : token1, bound(swapIn, 1e3, 1e13));
        (uint256 v0, uint256 v1) = harness.positionAmounts(tokenId);
        (uint256 out0, uint256 out1) = harness.withdraw(tokenId, liquidity, makeAddr("receiver"));
        assertLe(v0, out0);
        assertLe(v1, out1);
    }
}
