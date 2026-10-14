// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {V4TestBase} from "./V4TestBase.sol";
import {V4Positions} from "../../src/v4/V4Positions.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev v4-periphery SlippageCheck error (1.0.3).
interface ISlippageErrors {
    error MinimumAmountInsufficient(uint128 minimumAmount, uint128 amountReceived);
}

contract V4PositionsTest is V4TestBase {
    address internal receiver = makeAddr("receiver");

    function test_deploysOfficialV4() public view {
        assertEq(posm.poolManager(), v4.poolManager);
        assertEq(posm.permit2(), v4.permit2);
        assertGt(_sqrtPrice(key), 0);
    }

    function test_openMintsPositionOwnedByVault() public {
        uint256 amount = 1_000e6;
        _mint(token0, address(harness), amount);
        _mint(token1, address(harness), amount);
        (uint256 tokenId, uint128 liquidity, uint256 s0, uint256 s1) =
            harness.open(_params(key, -600, 600, amount, amount));
        assertEq(posm.ownerOf(tokenId), address(harness));
        assertGt(liquidity, 0);
        assertEq(_liquidity(tokenId), liquidity);
        // Spent amounts are the vault's real balance deltas.
        assertEq(_bal(token0, address(harness)), amount - s0);
        assertEq(_bal(token1, address(harness)), amount - s1);
        assertLe(s0, amount);
        assertLe(s1, amount);
        assertEq(harness.count(), 1);
        assertEq(harness.tokenIdAt(0), tokenId);
        // Token -> Permit2 and Permit2 -> PositionManager allowances reset after mint.
        _assertNoAllowance(token0);
        _assertNoAllowance(token1);
    }

    function test_openSlippageReverts() public {
        uint256 amount = 1_000e6;
        _mint(token0, address(harness), amount);
        _mint(token1, address(harness), amount);
        V4Positions.OpenParams memory p = _params(key, -600, 600, amount, amount);
        p.amount0Min = amount + 1; // more than can ever be spent
        vm.expectPartialRevert(V4Positions.Slippage.selector);
        harness.open(p);
    }

    function test_openRejectsNativeCurrency() public {
        PoolKey memory k = PoolKey(address(0), address(usdc), FEE, SPACING, address(0));
        vm.expectRevert(V4Positions.NativeCurrencyNotSupported.selector);
        harness.open(_params(k, -600, 600, 1e6, 1e6));
    }

    function test_openRejectsUninitializedPool() public {
        PoolKey memory k = key;
        k.fee = 500; // a different, never-initialized pool
        k.tickSpacing = 10;
        vm.expectRevert(V4Positions.PoolNotInitialized.selector);
        harness.open(_params(k, -600, 600, 1e6, 1e6));
    }

    function test_openRejectsZeroLiquidity() public {
        vm.expectRevert(V4Positions.ZeroLiquidity.selector);
        harness.open(_params(key, -600, 600, 0, 0));
    }

    function test_positionAmountsMatchMintedPrincipal() public {
        uint256 amount = 1_000e6;
        _mint(token0, address(harness), amount);
        _mint(token1, address(harness), amount);
        (uint256 tokenId,, uint256 s0, uint256 s1) = harness.open(_params(key, -600, 600, amount, amount));
        (uint256 v0, uint256 v1) = harness.positionAmounts(tokenId);
        // Mint rounds up what is paid in, the view rounds down.
        assertApproxEqAbs(v0, s0, 1);
        assertApproxEqAbs(v1, s1, 1);
        assertLe(v0, s0);
        assertLe(v1, s1);
    }

    function test_positionAboveRangeIsAllToken0() public {
        _mint(token0, address(harness), 1_000e6);
        (uint256 tokenId,,,) = harness.open(_params(key, 600, 1200, 1_000e6, 0));
        (uint256 v0, uint256 v1) = harness.positionAmounts(tokenId);
        assertGt(v0, 0);
        assertEq(v1, 0);
    }

    function test_positionBelowRangeIsAllToken1() public {
        _mint(token1, address(harness), 1_000e6);
        (uint256 tokenId,,,) = harness.open(_params(key, -1200, -600, 0, 1_000e6));
        (uint256 v0, uint256 v1) = harness.positionAmounts(tokenId);
        assertEq(v0, 0);
        assertGt(v1, 0);
    }

    function test_withdrawHalfSendsHalfPrincipal() public {
        (uint256 tokenId, uint128 liquidity) = _openInRange(1_000e6);
        (uint256 v0, uint256 v1) = harness.positionAmounts(tokenId);
        (,, uint256 out0, uint256 out1) = harness.withdraw(tokenId, liquidity / 2, receiver);
        assertEq(_bal(token0, receiver), out0);
        assertEq(_bal(token1, receiver), out1);
        assertApproxEqAbs(out0, v0 / 2, 2);
        assertApproxEqAbs(out1, v1 / 2, 2);
        assertEq(_liquidity(tokenId), liquidity - liquidity / 2);
    }

    /// v4 pays accrued fees on ANY liquidity change: withdraw must route them to the
    /// vault and only the principal to the recipient.
    function test_withdrawSendsFeesToVaultPrincipalToRecipient() public {
        (uint256 tokenId, uint128 liquidity) = _openInRange(1_000e6);
        _swap(token0, 100e6);
        _swap(token1, 100e6);
        (uint256 v0, uint256 v1) = harness.positionAmounts(tokenId);
        uint256 h0 = _bal(token0, address(harness));
        uint256 h1 = _bal(token1, address(harness));

        (uint256 f0, uint256 f1, uint256 out0, uint256 out1) = harness.withdraw(tokenId, liquidity, receiver);

        // Receiver gets principal only (≈ the position's value), not the fees.
        assertApproxEqAbs(out0, v0, 2);
        assertApproxEqAbs(out1, v1, 2);
        assertEq(_bal(token0, receiver), out0);
        assertEq(_bal(token1, receiver), out1);
        // 0.3% of each 100e6 swap went to the vault.
        assertApproxEqAbs(f0, 300_000, 2);
        assertApproxEqAbs(f1, 300_000, 2);
        assertEq(_bal(token0, address(harness)) - h0, f0);
        assertEq(_bal(token1, address(harness)) - h1, f1);
    }

    function test_collectFeesPaysSwapFeesToVault() public {
        (uint256 tokenId, uint128 liquidity) = _openInRange(1_000e6);
        _swap(token0, 100e6);
        uint256 h0 = _bal(token0, address(harness));
        (uint256 f0, uint256 f1) = harness.collectFees(tokenId);
        // 0.3% of 100e6 in token0, minus rounding; no token1 fees from a token0-in swap.
        assertApproxEqAbs(f0, 300_000, 2);
        assertEq(f1, 0);
        assertEq(_bal(token0, address(harness)) - h0, f0);
        // Liquidity untouched; a second harvest finds nothing.
        assertEq(_liquidity(tokenId), liquidity);
        (f0, f1) = harness.collectFees(tokenId);
        assertEq(f0, 0);
        assertEq(f1, 0);
    }

    function test_inKindExitTakesShareOfEveryPosition() public {
        (uint256 idA, uint128 liqA) = _openInRange(1_000e6);
        _mint(token0, address(harness), 500e6);
        (uint256 idB, uint128 liqB,,) = harness.open(_params(key, 600, 1200, 500e6, 0));

        harness.inKindExit(1, 4, receiver); // 25%

        assertEq(_liquidity(idA), liqA - liqA / 4);
        assertEq(_liquidity(idB), liqB - liqB / 4);
        assertGt(_bal(token0, receiver), 0);
        assertGt(_bal(token1, receiver), 0);
    }

    /// The exit harvests the position's fees to the vault first, so the exiting holder
    /// never receives them.
    function test_inKindExitKeepsFeesInVault() public {
        (uint256 tokenId,) = _openInRange(1_000e6);
        _swap(token0, 100e6);
        (uint256 v0, uint256 v1) = harness.positionAmounts(tokenId);

        harness.inKindExit(1, 2, receiver);

        assertApproxEqAbs(harness.harvested(token0), 300_000, 2);
        assertEq(harness.harvested(token1), 0);
        // Receiver got half the principal and none of the fees.
        assertApproxEqAbs(_bal(token0, receiver), v0 / 2, 2);
        assertApproxEqAbs(_bal(token1, receiver), v1 / 2, 2);
        (uint256 f0,) = harness.collectFees(tokenId);
        assertEq(f0, 0);
    }

    /// A slice so small it releases 0/0 must not revert the exit (zero takes are skipped).
    function test_inKindExitTinySliceDoesNotRevert() public {
        (uint256 tokenId, uint128 liquidity) = _openInRange(1_000e6);
        uint128 part = uint128(uint256(liquidity) * 600 / 1e12);
        assertGt(part, 0); // the decrease really happens and rounds to 0/0
        vm.expectEmit(true, false, false, true, address(harness));
        emit V4Positions.V4LiquidityWithdrawn(tokenId, part, receiver, 0, 0);
        harness.inKindExit(600, 1e12, receiver);
        assertEq(_liquidity(tokenId), liquidity - part);
        assertEq(_bal(token0, receiver), 0);
        assertEq(_bal(token1, receiver), 0);
    }

    function test_withdrawRespectsMinimums() public {
        (uint256 tokenId, uint128 liquidity) = _openInRange(1_000e6);
        vm.expectPartialRevert(ISlippageErrors.MinimumAmountInsufficient.selector);
        harness.withdrawWithMins(tokenId, liquidity, type(uint128).max, 0);
    }

    /// The PositionManager maps recipients 1 and 2 to msg.sender / itself; never allow them.
    function test_reservedRecipientsRejected() public {
        (uint256 tokenId, uint128 liquidity) = _openInRange(1_000e6);
        for (uint160 r = 0; r <= 2; r++) {
            vm.expectRevert(V4Positions.InvalidRecipient.selector);
            harness.withdraw(tokenId, liquidity, address(r));
        }
        assertEq(_liquidity(tokenId), liquidity);
    }

    function test_closeRequiresEmptyPosition() public {
        (uint256 tokenId, uint128 liquidity) = _openInRange(1_000e6);
        vm.expectRevert(abi.encodeWithSelector(V4Positions.PositionNotEmpty.selector, tokenId));
        harness.close(tokenId);

        _swap(token0, 100e6);
        (uint256 f0,,,) = harness.withdraw(tokenId, liquidity, address(harness));
        assertGt(f0, 0); // fees left with the last liquidity change
        harness.close(tokenId);
        assertEq(harness.count(), 0);
        vm.expectRevert(bytes("NOT_MINTED"));
        posm.ownerOf(tokenId);
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
        harness.collectFees(idB);
        harness.collectFees(idC);
    }

    function test_closeLastElementKeepsListConsistent() public {
        (uint256 idA,) = _openInRange(100e6);
        (uint256 idB,) = _openInRange(100e6);
        (uint256 idC, uint128 liqC) = _openInRange(100e6);
        harness.withdraw(idC, liqC, address(harness));
        harness.close(idC); // last element: nothing to move
        assertEq(harness.count(), 2);
        assertEq(harness.tokenIdAt(0), idA);
        assertEq(harness.tokenIdAt(1), idB);
        vm.expectRevert(abi.encodeWithSelector(V4Positions.UnknownPosition.selector, idC));
        harness.collectFees(idC);

        harness.withdraw(idB, _liquidity(idB), address(harness));
        harness.close(idB);
        harness.withdraw(idA, _liquidity(idA), address(harness));
        harness.close(idA);
        assertEq(harness.count(), 0);

        (uint256 idD,) = _openInRange(100e6);
        assertEq(harness.count(), 1);
        assertEq(harness.tokenIdAt(0), idD);
    }

    /// Fees and withdraws of a fully withdrawn (zero-liquidity) position are no-ops, not reverts.
    function test_emptyPositionHarvestIsNoop() public {
        (uint256 tokenId, uint128 liquidity) = _openInRange(100e6);
        harness.withdraw(tokenId, liquidity, address(harness));
        (uint256 f0, uint256 f1) = harness.collectFees(tokenId);
        assertEq(f0 + f1, 0);
        harness.inKindExit(1, 2, receiver);
        assertEq(_bal(token0, receiver) + _bal(token1, receiver), 0);
    }

    function test_unknownPositionReverts() public {
        vm.expectRevert(abi.encodeWithSelector(V4Positions.UnknownPosition.selector, 999));
        harness.withdraw(999, 1, receiver);
        vm.expectRevert(abi.encodeWithSelector(V4Positions.UnknownPosition.selector, 999));
        harness.collectFees(999);
        vm.expectRevert(abi.encodeWithSelector(V4Positions.UnknownPosition.selector, 999));
        harness.close(999);
    }

    /// A position minted to the vault by someone else is not tracked, so the library
    /// refuses to touch it.
    function test_untrackedPositionIsUnknown() public {
        (uint256 tokenId,) = _openInRange(100e6);
        uint256 foreignId = tokenId + 1; // never minted through the library
        vm.expectRevert(abi.encodeWithSelector(V4Positions.UnknownPosition.selector, foreignId));
        harness.collectFees(foreignId);
    }

    function test_positionCapEnforced() public {
        uint256 cap = V4Positions.MAX_POSITIONS;
        assertEq(cap, 25);
        _mint(token0, address(harness), (cap + 1) * 1e6);
        _mint(token1, address(harness), (cap + 1) * 1e6);
        for (uint256 i = 0; i < cap; i++) {
            harness.open(_params(key, -600, 600, 1e6, 1e6));
        }
        vm.expectRevert(V4Positions.TooManyPositions.selector);
        harness.open(_params(key, -600, 600, 1e6, 1e6));
    }

    function _assertNoAllowance(address token) internal view {
        assertEq(MockERC20(token).allowance(address(harness), v4.permit2), 0);
        (uint160 amount,,) = IPermit2(v4.permit2).allowance(address(harness), token, address(posm));
        assertEq(amount, 0);
    }
}
