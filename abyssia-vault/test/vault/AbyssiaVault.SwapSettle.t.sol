// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AbyssiaVaultTestBase} from "./AbyssiaVaultTestBase.sol";
import {AbyssiaVault} from "../../src/AbyssiaVault.sol";
import {AsyncBatchVault} from "../../src/AsyncBatchVault.sol";
import {VaultBook} from "../../src/libraries/VaultBook.sol";
import {VaultOps} from "../../src/libraries/VaultOps.sol";
import {VaultSwaps} from "../../src/libraries/VaultSwaps.sol";
import {MockFreezableERC20} from "../mocks/MockFreezableERC20.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract AbyssiaVaultSwapSettleTest is AbyssiaVaultTestBase {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 10_000e6);
    }

    // ---------------------------------------------------------------------
    // Swaps
    // ---------------------------------------------------------------------

    function test_swapUsdcToTokenAndBackBothProtocols() public {
        uint256 nav = vault.totalAssets();
        uint256 got3 = _keeperSwap(v3PoolId, true, 500e6);
        uint256 got4 = _keeperSwap(v4PoolId, true, 500e6);
        assertGt(got3, 0);
        assertGt(got4, 0);
        assertEq(vault.tokenBalance(address(meme)), got3 + got4);
        assertEq(vault.idleAssets(), 9_000e6);
        assertEq(meme.balanceOf(address(vault)), got3 + got4);
        // Priced via the first pool it came from; NAV only loses fees + price impact.
        assertEq(vault.tokenPool(address(meme)), v3PoolId);
        assertApproxEqRel(vault.totalAssets(), nav, 0.01e18);

        _keeperSwap(v4PoolId, false, got4);
        _keeperSwap(v3PoolId, false, got3);
        assertEq(vault.tokenBalance(address(meme)), 0);
        assertApproxEqRel(vault.idleAssets(), 10_000e6, 0.01e18);
        assertLt(vault.idleAssets(), 10_000e6); // paid fees both ways
    }

    function test_swapRejectsMinOutBelowPriceFloor() public {
        vm.prank(keeper);
        vm.expectPartialRevert(VaultOps.MinOutTooLow.selector);
        vault.swap(v3PoolId, true, 100e6, 0);
    }

    function test_swapEnforcesMinOut() public {
        vm.prank(keeper);
        vm.expectPartialRevert(VaultSwaps.InsufficientOutput.selector);
        vault.swap(v4PoolId, true, 100e6, 101e6); // more than the pool can give at 1:1
    }

    function test_swapUsdcInBlockedWhilePausedTokenInAllowed() public {
        uint256 got = _keeperSwap(v3PoolId, true, 500e6);
        vm.prank(guardian);
        vault.pause();
        uint256 minOut = _floor(v3PoolId, true, 100e6);
        vm.prank(keeper);
        vm.expectRevert();
        vault.swap(v3PoolId, true, 100e6, minOut);
        _keeperSwap(v3PoolId, false, got); // de-risking still works
        assertEq(vault.tokenBalance(address(meme)), 0);
    }

    function test_swapUsdcInRespectsAllocation() public {
        uint256 minOut = _floor(v3PoolId, true, 3_100e6);
        vm.prank(keeper);
        vm.expectPartialRevert(VaultBook.AllocationExceeded.selector);
        vault.swap(v3PoolId, true, 3_100e6, minOut);
    }

    function test_swapCannotSpendPendingDeposits() public {
        _requestDeposit(bob, 50_000e6);
        uint256 minOut = _floor(v3PoolId, true, 10_001e6);
        vm.prank(keeper);
        vm.expectPartialRevert(VaultOps.InsufficientIdle.selector);
        vault.swap(v3PoolId, true, 10_001e6, minOut);
    }

    function test_slippageBoundAdminAndGuardian() public {
        vm.prank(admin);
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        vault.setMaxSwapSlippageBps(1_001);
        vm.prank(guardian);
        vault.lowerMaxSwapSlippageBps(100);
        assertEq(vault.maxSwapSlippageBps(), 100);
        vm.prank(guardian);
        vm.expectRevert(AsyncBatchVault.NotLower.selector);
        vault.lowerMaxSwapSlippageBps(200);
        _expectUnauthorized(guardian, vault.DEFAULT_ADMIN_ROLE());
        vm.prank(guardian);
        vault.setMaxSwapSlippageBps(200);
    }

    function test_unlockCallbackOnlyFromPoolManagerDuringSwap() public {
        vm.expectRevert(AbyssiaVault.OnlyPoolManager.selector);
        vault.unlockCallback("");
        vm.prank(v4.poolManager);
        vm.expectRevert(VaultSwaps.UnexpectedCallback.selector);
        vault.unlockCallback("");
    }

    // ---------------------------------------------------------------------
    // Settlement
    // ---------------------------------------------------------------------

    /// Fees earned between settlements are harvested before pricing, so they raise the
    /// share price the next batch settles at.
    function test_settlementHarvestsFeesIntoSharePrice() public {
        // 700 USDC + 700 USDC of MEME per pool: 2,800 of the 3,000 class limit.
        _openInRange(v3PoolId, 700e6);
        _openInRange(v4PoolId, 700e6);
        for (uint256 i = 0; i < 5; i++) {
            _traderSwapV3(address(meme), 500e6);
            _traderSwapV3(address(usdc), 500e6);
            _traderSwapV4(address(meme), 500e6);
            _traderSwapV4(address(usdc), 500e6);
        }
        // Same pool prices before and after: the only difference is the harvested fees.
        uint256 priceBefore = vault.sharePrice();
        uint256 idleBefore = vault.idleAssets();
        _settle();
        assertGt(vault.idleAssets(), idleBefore, "USDC fees harvested");
        assertGt(vault.tokenBalance(address(meme)), 0, "MEME fees harvested");
        assertGt(vault.lastSharePrice(), priceBefore, "share price includes fees");
    }

    /// Settlement never swaps: a redemption larger than idle USDC reverts until the
    /// keeper unwinds, then settles.
    function test_redemptionNeedsKeeperUnwind() public {
        uint256 id = _openInRange(v3PoolId, 1_400e6);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares * 9 / 10);
        vm.warp(block.timestamp + vault.minSettleInterval());
        uint256 price = vault.sharePrice();
        vm.prank(keeper);
        vm.expectPartialRevert(AsyncBatchVault.InsufficientIdle.selector);
        vault.settle(price);

        (,,,,,,, uint128 liq,,,,) = vault.npm().positions(id);
        vm.startPrank(keeper);
        vault.withdrawPosition(P3, VaultOps.Removal(id, liq, 0, 0, block.timestamp));
        vm.stopPrank();
        _keeperSwap(v3PoolId, false, vault.tokenBalance(address(meme)));
        _settle();
        assertGt(vault.claimableAssets(), 8_900e6);
    }

    /// A position whose token is frozen cannot be harvested; settlement skips it instead
    /// of reverting.
    function test_frozenTokenHarvestIsSkipped() public {
        MockFreezableERC20 frozen = new MockFreezableERC20("Frozen", "FRZ");
        (, bytes32 poolId) = _addV4Pool(address(frozen));
        uint256 id = _openInRange(poolId, 500e6);
        _traderSwapV4Key(poolId, address(frozen), 500e6); // fees in the frozen token
        frozen.freeze();

        vm.expectEmit(true, true, false, false, address(vault));
        emit AbyssiaVault.HarvestSkipped(P4, id);
        _settle();
    }

    function test_harvestForIsSelfOnly() public {
        vm.expectRevert(AbyssiaVault.OnlySelf.selector);
        vault.harvestFor(P3, 1);
        vm.prank(address(vault));
        vm.expectRevert(AbyssiaVault.OnlySelf.selector); // not during settlement
        vault.harvestFor(P3, 1);
    }

    // ---------------------------------------------------------------------

    function _traderSwapV4Key(bytes32 poolId, address tokenIn, uint256 amountIn) internal {
        PoolKey memory key = registry.getPool(poolId).v4Key;
        bool zeroForOne = tokenIn == key.currency0;
        _mint(tokenIn, address(swapper), amountIn);
        swapper.swap(
            key,
            zeroForOne,
            amountIn,
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            trader
        );
    }
}
