// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AbyssiaVaultTestBase} from "./AbyssiaVaultTestBase.sol";
import {AbyssiaVault} from "../../src/AbyssiaVault.sol";
import {AsyncBatchVault} from "../../src/AsyncBatchVault.sol";
import {VaultRegistry} from "../../src/registry/VaultRegistry.sol";
import {VaultBook} from "../../src/libraries/VaultBook.sol";
import {VaultOps} from "../../src/libraries/VaultOps.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface IPoolManagerInitH {
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24);
}

/// @dev Regressions for the Plan 5a security review.
contract AbyssiaVaultHardeningTest is AbyssiaVaultTestBase {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 10_000e6);
    }

    // ---------------------------------------------------------------------
    // H1: settlement is bound to the keeper's expected (fair) price
    // ---------------------------------------------------------------------

    /// A sandwich that pumps the pool pricing the vault's inventory right before the
    /// keeper's settle makes the settle revert instead of settling at the inflated NAV.
    function test_settleRevertsWhenPoolPricesAreMovedAroundIt() public {
        _keeperSwap(v3PoolId, true, 2_500e6); // MEME inventory priced via the v3 pool
        _requestDeposit(bob, 1_000e6);
        uint256 fair = vault.sharePrice();

        _traderSwapV3(address(usdc), 200_000e6); // pump MEME
        uint256 live = vault.sharePrice();
        assertGt(live, fair * 10_050 / 10_000);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AsyncBatchVault.PriceNotAsExpected.selector, fair, live));
        vault.settle(fair);
    }

    function test_settleRejectsZeroExpectedPrice() public {
        vm.prank(keeper);
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        vault.settle(0);
    }

    function test_settleToleranceAdminCapAndGuardianTightening() public {
        assertEq(vault.settleToleranceBps(), 50);
        vm.startPrank(admin);
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        vault.setSettleToleranceBps(201);
        vm.expectRevert(AsyncBatchVault.ParamOutOfBounds.selector);
        vault.setSettleToleranceBps(0);
        vault.setSettleToleranceBps(200);
        vm.stopPrank();
        vm.startPrank(guardian);
        vault.lowerSettleToleranceBps(25);
        vm.expectRevert(AsyncBatchVault.NotLower.selector);
        vault.lowerSettleToleranceBps(30);
        vm.expectRevert(AsyncBatchVault.NotLower.selector);
        vault.lowerSettleToleranceBps(0);
        vm.stopPrank();
        assertEq(vault.settleToleranceBps(), 25);
    }

    // ---------------------------------------------------------------------
    // M1: limits cannot be escaped by buying a token through a second pool
    // ---------------------------------------------------------------------

    /// The first buy prices MEME via the v3 pool; buying more through the v4 pool still
    /// counts every MEME held against the v4 pool's limit (and the v3 pool's).
    function test_poolCapCountsAllInventoryOfTheToken() public {
        _keeperSwap(v3PoolId, true, 10e6);
        uint256 minOut = _floor(v4PoolId, true, 3_100e6);
        vm.prank(keeper);
        vm.expectPartialRevert(VaultBook.AllocationExceeded.selector);
        vault.swap(v4PoolId, true, 3_100e6, minOut);
    }

    /// The second pool of the same token sits in a looser class: buying through it is still
    /// checked against the class of the pool that prices the inventory (Memecoin, 30%).
    function test_classCapCannotBeEscapedViaAPoolInAnotherClass() public {
        VaultRegistry.ClassParams memory loose = _classParams();
        loose.maxAllocationBps = 5_000;
        loose.maxClassBps = 6_000;
        vm.startPrank(admin);
        registry.setClassParams(VaultRegistry.AssetClass.Volatile, loose);
        registry.setPoolClass(v4PoolId, VaultRegistry.AssetClass.Volatile);
        vm.stopPrank();

        _keeperSwap(v3PoolId, true, 10e6); // MEME priced via the Memecoin-class v3 pool
        uint256 minOut = _floor(v4PoolId, true, 4_000e6);
        vm.prank(keeper);
        vm.expectPartialRevert(VaultBook.AllocationExceeded.selector);
        vault.swap(v4PoolId, true, 4_000e6, minOut);
    }

    // ---------------------------------------------------------------------
    // M2: buying a token needs a deep enough pool
    // ---------------------------------------------------------------------

    function test_swapIntoTokenRespectsMinPoolLiquidity() public {
        VaultRegistry.ClassParams memory p = _classParams();
        p.minPoolLiquidity = type(uint128).max;
        vm.prank(admin);
        registry.setClassParams(MEMECOIN, p);
        uint256 minOut = _floor(v4PoolId, true, 100e6);
        vm.prank(keeper);
        vm.expectPartialRevert(VaultBook.PoolTooThin.selector);
        vault.swap(v4PoolId, true, 100e6, minOut);
    }

    // ---------------------------------------------------------------------
    // M3: a full token list never freezes a position or skips its exit slice
    // ---------------------------------------------------------------------

    function test_openReservesTheTokenSlot() public {
        (int24 lo, int24 hi) = _usdcSide();
        _open(v4PoolId, lo, hi, 100e6, 0); // USDC only: no MEME held yet
        assertEq(vault.tokenPool(address(meme)), v4PoolId);
        assertEq(vault.inventoryTokens().length, 1);
    }

    function test_fullTokenListNeverBlocksAPositionsCredits() public {
        // A position in MEME (its slot reserved), then fill the list with bought tokens.
        uint256 id = _openInRange(v4PoolId, 200e6);
        uint256 cap = vault.MAX_TOKENS();
        bytes32 lastPool;
        for (uint256 i = vault.inventoryTokens().length; i < cap; i++) {
            (, lastPool) = _addV3Pool(address(new MockERC20("T", "T")));
            _keeperSwap(lastPool, true, 5e6);
        }
        assertEq(vault.inventoryTokens().length, cap);
        (, bytes32 extra) = _addV3Pool(address(new MockERC20("X", "X")));
        uint256 minOut = _floor(extra, true, 5e6);
        vm.prank(keeper);
        vm.expectRevert(VaultOps.TooManyTokens.selector);
        vault.swap(extra, true, 5e6, minOut);

        // The MEME position still earns, harvests, exits in kind and withdraws.
        _traderSwapV4(address(meme), 1_000e6);
        _settle();
        address receiver = makeAddr("receiver");
        uint128 before = vault.posm().getPositionLiquidity(id);
        uint256 shares = vault.balanceOf(alice) / 10;
        vm.prank(alice);
        vault.redeemInKind(shares, receiver);
        assertLt(vault.posm().getPositionLiquidity(id), before);
        uint128 liq = vault.posm().getPositionLiquidity(id);
        vm.prank(keeper);
        vault.withdrawPosition(P4, VaultOps.Removal(id, liq, 0, 0, block.timestamp));
        assertEq(vault.posm().getPositionLiquidity(id), 0);
    }

    // ---------------------------------------------------------------------
    // Lows
    // ---------------------------------------------------------------------

    /// L1: selling inventory goes through hookless pools only.
    function test_sellingThroughAHookedPoolIsRejected() public {
        address hook = address(uint160(1 << 20)); // no permission flags
        vm.prank(admin);
        registry.setHookAllowed(hook, true);
        (address c0, address c1) = _sorted(address(meme));
        PoolKey memory key = PoolKey(c0, c1, 0x800000, SPACING, hook);
        IPoolManagerInitH(v4.poolManager).initialize(key, TickMath.getSqrtPriceAtTick(0));
        vm.prank(admin);
        bytes32 hooked = registry.addV4Pool(key, MEMECOIN);
        uint256 got = _keeperSwap(v3PoolId, true, 100e6);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(VaultBook.HookedPoolNotAllowed.selector, hooked));
        vault.swap(hooked, false, got, 0);
    }

    /// L3: USDC is never paid to the vault itself (it would become sweepable surplus).
    function test_usdcCannotBePaidToTheVault() public {
        _requestDeposit(bob, 100e6);
        vm.prank(bob);
        vm.expectRevert(AsyncBatchVault.ZeroAddress.selector);
        vault.cancelDepositRequestFor(bob, address(vault));
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(shares / 10);
        uint256 id = vault.currentBatchId();
        _settle();
        vm.prank(alice);
        vm.expectRevert(AsyncBatchVault.ZeroAddress.selector);
        vault.claimRedeem(id, address(vault));
    }

    /// L4: stray tokens beyond the books can be recovered, never inventory or IOUs.
    function test_sweepTokenSurplus() public {
        uint256 got = _keeperSwap(v3PoolId, true, 100e6);
        meme.mint(address(vault), 5e18);
        vm.prank(admin);
        assertEq(vault.sweepTokenSurplus(address(meme), admin), 5e18);
        assertEq(meme.balanceOf(address(vault)), got);
        vm.prank(admin);
        vm.expectRevert(AsyncBatchVault.ZeroAddress.selector);
        vault.sweepTokenSurplus(address(usdc), admin);
    }

    function _usdcSide() internal view returns (int24 lo, int24 hi) {
        return address(usdc) < address(meme) ? (int24(600), int24(1200)) : (int24(-1200), int24(-600));
    }
}
