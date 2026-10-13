// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {V3TestBase} from "./V3TestBase.sol";
import {V3Positions} from "../../src/v3/V3Positions.sol";

contract V3PositionsTest is V3TestBase {
    address internal receiver = makeAddr("receiver");

    function test_deploysOfficialV3() public view {
        assertEq(npm.factory(), v3.factory);
        assertTrue(pool != address(0));
    }

    function test_openMintsPositionOwnedByVault() public {
        uint256 amount = 1_000e6;
        _fundHarness(amount, amount);
        (uint256 tokenId, uint128 liquidity, uint256 a0, uint256 a1) =
            harness.open(_params(-600, 600, amount, amount));
        assertEq(npm.ownerOf(tokenId), address(harness));
        assertGt(liquidity, 0);
        assertLe(a0, amount);
        assertLe(a1, amount);
        assertEq(harness.count(), 1);
        assertEq(harness.tokenIdAt(0), tokenId);
        // Exact approvals, reset after mint.
        assertEq(_allowance(token0), 0);
        assertEq(_allowance(token1), 0);
    }

    function test_positionAmountsMatchMintedPrincipal() public {
        uint256 amount = 1_000e6;
        _fundHarness(amount, amount);
        (uint256 tokenId,, uint256 a0, uint256 a1) = harness.open(_params(-600, 600, amount, amount));
        (uint256 v0, uint256 v1) = harness.positionAmounts(tokenId);
        // Mint rounds up what is paid in, the view rounds down.
        assertApproxEqAbs(v0, a0, 1);
        assertApproxEqAbs(v1, a1, 1);
        assertLe(v0, a0);
        assertLe(v1, a1);
    }

    function test_positionAboveRangeIsAllToken0() public {
        _fundHarness(1_000e6, 0);
        (uint256 tokenId,,,) = harness.open(_params(600, 1200, 1_000e6, 0));
        (uint256 v0, uint256 v1) = harness.positionAmounts(tokenId);
        assertGt(v0, 0);
        assertEq(v1, 0);
    }

    function test_positionBelowRangeIsAllToken1() public {
        _fundHarness(0, 1_000e6);
        (uint256 tokenId,,,) = harness.open(_params(-1200, -600, 0, 1_000e6));
        (uint256 v0, uint256 v1) = harness.positionAmounts(tokenId);
        assertEq(v0, 0);
        assertGt(v1, 0);
    }

    function test_withdrawHalfSendsHalfPrincipal() public {
        (uint256 tokenId, uint128 liquidity) = _openInRange(1_000e6);
        (uint256 v0, uint256 v1) = harness.positionAmounts(tokenId);
        (uint256 out0, uint256 out1) = harness.withdraw(tokenId, liquidity / 2, receiver);
        assertEq(_bal(token0, receiver), out0);
        assertEq(_bal(token1, receiver), out1);
        assertApproxEqAbs(out0, v0 / 2, 2);
        assertApproxEqAbs(out1, v1 / 2, 2);
        assertEq(_liquidity(tokenId), liquidity - liquidity / 2);
    }

    function test_withdrawDoesNotSweepFees() public {
        (uint256 tokenId, uint128 liquidity) = _openInRange(1_000e6);
        _swap(token0, 100e6);
        _swap(token1, 100e6);
        (uint256 v0, uint256 v1) = harness.positionAmounts(tokenId);
        (uint256 out0, uint256 out1) = harness.withdraw(tokenId, liquidity, receiver);
        // Receiver gets principal only (≈ the position's value), not the fees.
        assertApproxEqAbs(out0, v0, 2);
        assertApproxEqAbs(out1, v1, 2);
        // Fees remain owed and are collectable afterwards.
        (uint256 f0, uint256 f1) = harness.collectFees(tokenId, address(harness));
        assertGt(f0, 0);
        assertGt(f1, 0);
    }

    function test_collectFeesPaysSwapFees() public {
        (uint256 tokenId,) = _openInRange(1_000e6);
        _swap(token0, 100e6);
        (uint256 f0, uint256 f1) = harness.collectFees(tokenId, receiver);
        // 0.3% of 100e6 in token0, minus rounding; no token1 fees from a token0-in swap.
        assertApproxEqAbs(f0, 300_000, 2);
        assertEq(f1, 0);
        assertEq(_bal(token0, receiver), f0);
        // Liquidity untouched.
        assertGt(_liquidity(tokenId), 0);
    }

    function test_withdrawProRataTakesShareOfEveryPosition() public {
        (uint256 idA, uint128 liqA) = _openInRange(1_000e6);
        _fundHarness(500e6, 0);
        (uint256 idB, uint128 liqB,,) = harness.open(_params(600, 1200, 500e6, 0));

        harness.withdrawProRata(1, 4, receiver); // 25%

        assertEq(_liquidity(idA), liqA - liqA / 4);
        assertEq(_liquidity(idB), liqB - liqB / 4);
        assertGt(_bal(token0, receiver), 0);
        assertGt(_bal(token1, receiver), 0);
    }

    function test_withdrawProRataLeavesFeesInVault() public {
        (uint256 tokenId,) = _openInRange(1_000e6);
        _swap(token0, 100e6);
        harness.withdrawProRata(1, 2, receiver);
        (uint256 f0,) = harness.collectFees(tokenId, address(harness));
        assertApproxEqAbs(f0, 300_000, 2); // all fees still belong to the vault
    }

    /// @dev Regression: a slice so small it releases 0/0 must not revert the exit
    /// (the position manager's collect() rejects two zero maxima).
    function test_withdrawProRataTinySliceDoesNotRevert() public {
        (uint256 tokenId, uint128 liquidity) = _openInRange(1_000e6);
        harness.withdrawProRata(600, 1e12, receiver);
        assertEq(_liquidity(tokenId), liquidity - uint128(uint256(liquidity) * 600 / 1e12));
    }

    function test_withdrawRespectsMinimums() public {
        (uint256 tokenId, uint128 liquidity) = _openInRange(1_000e6);
        vm.expectRevert(bytes("Price slippage check"));
        harness.withdrawWithMins(tokenId, liquidity, type(uint128).max, 0);
    }

    function test_closeRequiresEmptyPosition() public {
        (uint256 tokenId, uint128 liquidity) = _openInRange(1_000e6);
        vm.expectRevert(abi.encodeWithSelector(V3Positions.PositionNotEmpty.selector, tokenId));
        harness.close(tokenId);

        _swap(token0, 100e6);
        harness.withdraw(tokenId, liquidity, address(harness));
        vm.expectRevert(abi.encodeWithSelector(V3Positions.PositionNotEmpty.selector, tokenId)); // fees owed
        harness.close(tokenId);

        harness.collectFees(tokenId, address(harness));
        harness.close(tokenId);
        assertEq(harness.count(), 0);
        vm.expectRevert(bytes("ERC721: owner query for nonexistent token"));
        npm.ownerOf(tokenId);
    }

    function test_closeKeepsListConsistent() public {
        (uint256 idA, uint128 liqA) = _openInRange(100e6);
        (uint256 idB,) = _openInRange(100e6);
        (uint256 idC,) = _openInRange(100e6);
        harness.withdraw(idA, liqA, address(harness));
        harness.close(idA);
        assertEq(harness.count(), 2);
        // The last id was moved into the closed slot.
        assertEq(harness.tokenIdAt(0), idC);
        assertEq(harness.tokenIdAt(1), idB);
        // Both survivors are still known.
        harness.collectFees(idB, address(harness));
        harness.collectFees(idC, address(harness));
    }

    function test_unknownPositionReverts() public {
        vm.expectRevert(abi.encodeWithSelector(V3Positions.UnknownPosition.selector, 999));
        harness.withdraw(999, 1, receiver);
        vm.expectRevert(abi.encodeWithSelector(V3Positions.UnknownPosition.selector, 999));
        harness.collectFees(999, receiver);
        vm.expectRevert(abi.encodeWithSelector(V3Positions.UnknownPosition.selector, 999));
        harness.close(999);
    }

    function test_positionCapEnforced() public {
        uint256 cap = 50;
        _fundHarness(cap * 1e6, cap * 1e6);
        for (uint256 i = 0; i < cap; i++) {
            harness.open(_params(-600, 600, 1e6, 1e6));
        }
        _fundHarness(1e6, 1e6);
        vm.expectRevert(V3Positions.TooManyPositions.selector);
        harness.open(_params(-600, 600, 1e6, 1e6));
    }

    function _allowance(address token) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(
            abi.encodeWithSignature("allowance(address,address)", address(harness), address(npm))
        );
        require(ok);
        return abi.decode(ret, (uint256));
    }
}
