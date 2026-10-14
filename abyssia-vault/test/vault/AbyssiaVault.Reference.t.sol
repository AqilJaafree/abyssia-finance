// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {AbyssiaVaultTestBase} from "./AbyssiaVaultTestBase.sol";
import {AbyssiaVault} from "../../src/AbyssiaVault.sol";
import {VaultBook} from "../../src/libraries/VaultBook.sol";
import {VaultRebalance} from "../../src/libraries/VaultRebalance.sol";
import {Shapes} from "../../src/libraries/Shapes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// v4 reference ticks, the reference-priced stop-loss and the guardian's emergency unwind.
contract AbyssiaVaultReferenceTest is AbyssiaVaultTestBase {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 10_000e6);
    }

    // ---------------------------------------------------------------------
    // Reference ticks
    // ---------------------------------------------------------------------

    /// The guardian posts the first; after that keeper or guardian move it at most
    /// maxTwapDeviation ticks, at most once per twapWindow.
    function test_referencePostingRules() public {
        (,, VaultBook.ReferenceTick memory r) = vault.poolState(v4PoolId);
        assertTrue(r.set);
        assertEq(r.tick, 0);

        vm.prank(keeper);
        vault.postReferenceTick(v4PoolId, 500); // a full step, a window after the first post
        (,, r) = vault.poolState(v4PoolId);
        assertEq(r.tick, 500);
        assertEq(r.updatedAt, block.timestamp);

        uint256 next = block.timestamp + vault.twapWindow();
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(VaultBook.ReferenceTooSoon.selector, next));
        vault.postReferenceTick(v4PoolId, 400);
        vm.warp(block.timestamp + vault.twapWindow());
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(VaultBook.ReferenceStepTooLarge.selector, int24(500), int24(-1))
        );
        vault.postReferenceTick(v4PoolId, -1);
        vm.prank(guardian);
        vault.postReferenceTick(v4PoolId, 0);

        _expectUnauthorized(alice, vault.KEEPER_ROLE());
        vm.prank(alice);
        vault.postReferenceTick(v4PoolId, 0);
    }

    /// Only the guardian can post a pool's first reference; v3 pools (TWAP) and ticks out of
    /// range are rejected.
    function test_firstReferenceIsTheGuardians() public {
        MockERC20 other = new MockERC20("Other", "OTH");
        (, bytes32 poolId) = _addV4PoolUnposted(address(other));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(VaultBook.NoReferencePrice.selector, poolId));
        vault.postReferenceTick(poolId, 0);
        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(VaultBook.InvalidReference.selector, v3PoolId, int24(0)));
        vault.postReferenceTick(v3PoolId, 0);
        vm.expectRevert(
            abi.encodeWithSelector(VaultBook.InvalidReference.selector, poolId, TickMath.MAX_TICK + 1)
        );
        vault.postReferenceTick(poolId, TickMath.MAX_TICK + 1);
        vault.postReferenceTick(poolId, 0);
        vm.stopPrank();
    }

    /// A v4 pool with no reference fails closed: no rebalance, no swap.
    function test_v4ActionsNeedAReference() public {
        MockERC20 other = new MockERC20("Other", "OTH");
        (, bytes32 poolId) = _addV4PoolUnposted(address(other));
        VaultRebalance.Args memory a =
            _rebalanceArgs(poolId, _spec(Shapes.SPOT, Shapes.USDC_ONLY, 1, 60), 1e6, 0);
        bytes memory noRef = abi.encodeWithSelector(VaultBook.NoReferencePrice.selector, poolId);
        vm.prank(keeper);
        vm.expectRevert(noRef);
        vault.rebalance(a);
        vm.prank(keeper);
        vm.expectRevert(noRef);
        vault.swap(poolId, true, 1e6, 0);
    }

    /// A v4 pool pushed far from its reference: the keeper can neither rebalance nor swap
    /// there (the v4 analogue of the v3 TWAP check).
    function test_v4ActionsRequireSpotNearReference() public {
        _traderSwapV4(address(usdc), 200_000e6);
        VaultRebalance.Args memory a =
            _rebalanceArgs(v4PoolId, _spec(Shapes.SPOT, Shapes.USDC_ONLY, 1, 60), 1e6, 0);
        vm.prank(keeper);
        vm.expectPartialRevert(VaultBook.PriceOffReference.selector);
        vault.rebalance(a);
        uint256 minOut = _floor(v4PoolId, true, 1e6);
        vm.prank(keeper);
        vm.expectPartialRevert(VaultBook.PriceOffReference.selector);
        vault.swap(v4PoolId, true, 1e6, minOut);
        // Once the reference has followed, the keeper can act at the new price.
        _walkReference(v4PoolId, _tick(v4PoolId));
        _rebalance(v4PoolId, _spec(Shapes.SPOT, Shapes.USDC_ONLY, 1, 60), 1e6, 0);
    }

    // ---------------------------------------------------------------------
    // Stop-loss
    // ---------------------------------------------------------------------

    /// L3: exits shrink the positions but not their value at entry vs reference price, so
    /// an in-kind exit of half the vault no longer looks like a 50% loss.
    function test_stopLossIgnoresExits() public {
        _rebalance(v4PoolId, _spec(Shapes.SPOT, Shapes.USDC_ONLY, 3, 600), 3_000e6, 0);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeemInKind(shares / 2, alice);
        vm.prank(keeper);
        vm.expectPartialRevert(VaultRebalance.StopLossNotReached.selector);
        vault.stopLoss(v4PoolId);
    }

    /// L4: pushing a v3 pool's spot price does not trigger the stop-loss: it values the
    /// positions at the TWAP.
    function test_v3StopLossUsesTheTwap() public {
        uint256 got = _keeperSwap(v3PoolId, true, 1_000e6);
        _rebalance(v3PoolId, _spec(Shapes.SPOT, Shapes.TOKEN_ONLY, 3, 600), 0, got);
        _traderSwapV3(address(meme), 600_000e6); // spot crashes, the TWAP barely moves
        vm.prank(keeper);
        vm.expectPartialRevert(VaultRebalance.StopLossNotReached.selector);
        vault.stopLoss(v3PoolId);
        // A sustained crash moves the TWAP, and the stop-loss then triggers.
        vm.warp(block.timestamp + vault.twapWindow());
        vm.prank(keeper);
        vault.stopLoss(v3PoolId);
        (uint256 n3,) = vault.positionCount();
        assertEq(n3, 0);
    }

    /// L5: the guardian can unwind a pool with no price check, even while paused.
    function test_emergencyUnwind() public {
        _rebalance(v4PoolId, _spec(Shapes.SPOT, Shapes.USDC_ONLY, 3, 600), 3_000e6, 0);
        uint256 nav = vault.totalAssets();
        _expectUnauthorized(keeper, vault.GUARDIAN_ROLE());
        vm.prank(keeper);
        vault.emergencyUnwind(v4PoolId);
        vm.startPrank(guardian);
        vault.pause();
        vm.expectEmit(true, false, false, false, address(vault));
        emit VaultRebalance.PoolUnwound(v4PoolId);
        vault.emergencyUnwind(v4PoolId);
        vm.stopPrank();
        (, uint256 n4) = vault.positionCount();
        assertEq(n4, 0);
        (uint160 entry,,) = vault.poolState(v4PoolId);
        assertEq(entry, 0);
        assertApproxEqAbs(vault.idleAssets(), nav, 10);
    }

    /// @dev A v4 pool without its first reference tick.
    function _addV4PoolUnposted(address token) internal returns (bytes32 key, bytes32 poolId) {
        address saved = address(vault);
        // _addV4Pool posts the first reference when the vault exists; post nothing here.
        vault = AbyssiaVault(address(0));
        (, poolId) = _addV4Pool(token);
        vault = AbyssiaVault(saved);
        key = poolId;
    }
}
