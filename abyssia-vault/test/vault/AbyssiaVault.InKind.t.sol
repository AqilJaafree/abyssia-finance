// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AbyssiaVaultTestBase} from "./AbyssiaVaultTestBase.sol";
import {AbyssiaVault} from "../../src/AbyssiaVault.sol";
import {VaultBook} from "../../src/libraries/VaultBook.sol";
import {VaultRegistry} from "../../src/registry/VaultRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFreezableERC20} from "../mocks/MockFreezableERC20.sol";
import {MockGasBurnerERC20} from "../mocks/MockGasBurnerERC20.sol";
import {MockTwoStageBurnerERC20} from "../mocks/MockTwoStageBurnerERC20.sol";

contract AbyssiaVaultInKindTest is AbyssiaVaultTestBase {
    address internal receiver = makeAddr("receiver");
    uint256 internal id3;
    uint256 internal id4;

    function setUp() public override {
        super.setUp();
        _deposit(alice, 10_000e6);
        id3 = _openInRange(v3PoolId, 500e6);
        id4 = _openInRange(v4PoolId, 500e6);
        _keeperSwap(v3PoolId, true, 300e6); // MEME inventory
    }

    /// Burning a quarter of the shares pays a quarter of idle USDC, of every position's
    /// liquidity and of the token inventory, without any price.
    function test_inKindExitTakesShareOfEverything() public {
        uint256 shares = vault.balanceOf(alice) / 4;
        uint256 supply = vault.totalSupply();
        uint256 idle = vault.idleAssets();
        uint256 inv = vault.tokenBalance(address(meme));
        uint128 l3 = _liq3(id3);
        uint128 l4 = _liq4(id4);

        vm.prank(alice);
        uint256 idleOut = vault.redeemInKind(shares, receiver);

        assertEq(idleOut, idle * shares / supply);
        assertEq(_liq3(id3), l3 - uint128(uint256(l3) * shares / supply));
        assertEq(_liq4(id4), l4 - uint128(uint256(l4) * shares / supply));
        assertEq(vault.tokenBalance(address(meme)), inv - inv * shares / supply);
        assertGt(usdc.balanceOf(receiver), idleOut); // idle + the positions' USDC side
        assertGt(meme.balanceOf(receiver), inv * shares / supply); // inventory + positions
        assertEq(vault.balanceOf(alice), shares * 3); // 4 equal quarters minus the one burned
    }

    function test_invalidReceiversRejected() public {
        address[8] memory bad = [
            address(0),
            address(1),
            address(2),
            address(vault),
            v3.positionManager,
            v4.positionManager,
            v4.poolManager,
            v4.permit2
        ];
        uint256 shares = vault.balanceOf(alice);
        for (uint256 i = 0; i < bad.length; i++) {
            vm.prank(alice);
            vm.expectRevert(AbyssiaVault.InvalidReceiver.selector);
            vault.redeemInKind(1e12, bad[i]);
        }
        assertEq(vault.balanceOf(alice), shares);
    }

    /// The receiver is blocked on one token: that pool's slice is taken into the vault and
    /// owed to the share OWNER (both sides, including USDC), who claims it to any address;
    /// sweepSurplus never touches it.
    function test_blockedReceiverGetsIouAndSurplusExcludesIt() public {
        MockFreezableERC20 hostile = new MockFreezableERC20("Hostile", "HOS");
        (, bytes32 poolId) = _addV4Pool(address(hostile));
        _openInRange(poolId, 300e6);
        hostile.setBlocked(receiver, true);

        uint256 half = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        vault.redeemInKind(half, receiver);

        assertEq(vault.owed(receiver, address(usdc)), 0);
        uint256 owedUsdc = vault.owed(alice, address(usdc));
        uint256 owedHostile = vault.owed(alice, address(hostile));
        assertGt(owedUsdc, 0);
        assertGt(owedHostile, 0);
        assertEq(vault.owedTotal(address(usdc)), owedUsdc);

        // A donation is surplus; the IOU USDC is not.
        usdc.mint(address(vault), 7e6);
        vm.prank(admin);
        assertEq(vault.sweepSurplus(admin), 7e6);

        uint256 aliceUsdc = usdc.balanceOf(alice);
        vm.startPrank(alice);
        vault.claimOwed(address(usdc), alice);
        assertEq(usdc.balanceOf(alice), aliceUsdc + owedUsdc);
        assertEq(vault.owedTotal(address(usdc)), 0);
        // Still blocked for the receiver, so the owner claims the token elsewhere.
        vault.claimOwed(address(hostile), alice);
        vm.stopPrank();
        assertEq(hostile.balanceOf(alice), owedHostile);
    }

    /// An inventory token the receiver cannot take is owed instead (exact amount).
    function test_blockedInventoryTokenIsOwed() public {
        MockFreezableERC20 hostile = new MockFreezableERC20("Hostile", "HOS");
        (, bytes32 poolId) = _addV3Pool(address(hostile));
        uint256 got = _keeperSwap(poolId, true, 300e6);
        hostile.setBlocked(receiver, true);
        uint256 supply = vault.totalSupply();
        uint256 shares = vault.balanceOf(alice) / 2;

        vm.prank(alice);
        vault.redeemInKind(shares, receiver);

        assertEq(vault.owed(alice, address(hostile)), got * shares / supply);
        assertEq(vault.tokenBalance(address(hostile)), got - got * shares / supply);
    }

    /// A frozen token: its slice is skipped (stays with the remaining holders); the exit
    /// still pays everything else.
    function test_frozenTokenSliceSkippedOthersPaid() public {
        MockFreezableERC20 frozen = new MockFreezableERC20("Frozen", "FRZ");
        (, bytes32 poolId) = _addV3Pool(address(frozen));
        uint256 idF = _openInRange(poolId, 300e6);
        uint128 lF = _liq3(idF);
        frozen.freeze();
        uint128 l4 = _liq4(id4);

        vm.expectEmit(true, true, false, false, address(vault));
        emit AbyssiaVault.SliceSkipped(P3, idF);
        uint256 half = vault.balanceOf(alice) / 2;
        vm.prank(alice);
        vault.redeemInKind(half, receiver);

        assertEq(_liq3(idF), lF);
        assertLt(_liq4(id4), l4);
        assertGt(meme.balanceOf(receiver), 0);
    }

    /// A gas-burning token costs one SLICE_GAS and is skipped without a fallback attempt.
    function test_gasBurnerSkippedWithBoundedGas() public {
        MockGasBurnerERC20 burner = new MockGasBurnerERC20("Burner", "BRN");
        (, bytes32 poolId) = _addV4Pool(address(burner));
        uint256 idB = _openInRange(poolId, 300e6);
        burner.setBurn(true);

        uint256 shares = vault.balanceOf(alice) / 2;
        vm.expectCall(
            address(vault),
            abi.encodeCall(
                vault.exitSlice,
                (P4, idB, AbyssiaVault.Exit(shares, vault.totalSupply(), receiver, alice), address(vault))
            ),
            uint64(0)
        );
        uint256 g = gasleft();
        vm.prank(alice);
        vault.redeemInKind(shares, receiver);
        emit log_named_uint("redeemInKind gas (3 positions + inventory, 1 burner)", g - gasleft());
        assertLt(g - gasleft(), 3_000_000);
    }

    function test_insufficientGasRevertsNotSkips() public {
        uint128 l3 = _liq3(id3);
        vm.prank(alice);
        (bool ok, bytes memory ret) =
            address(vault).call{gas: 400_000}(abi.encodeCall(vault.redeemInKind, (1e12, receiver)));
        assertFalse(ok);
        assertEq(bytes4(ret), AbyssiaVault.InsufficientGas.selector);
        assertEq(_liq3(id3), l3);
    }

    function test_exitEntrypointsAreSelfAndBoundOnly() public {
        vm.expectRevert(AbyssiaVault.OnlySelf.selector);
        vault.exitSlice(P3, id3, AbyssiaVault.Exit(1, 2, receiver, alice), receiver);
        vm.expectRevert(AbyssiaVault.OnlySelf.selector);
        vault.exitTransfer(address(meme), 1, AbyssiaVault.Exit(1, 2, receiver, alice));
        vm.startPrank(address(vault)); // self, but no exit in progress
        vm.expectRevert(AbyssiaVault.UnboundSlice.selector);
        vault.exitSlice(P3, id3, AbyssiaVault.Exit(1, 2, receiver, alice), receiver);
        vm.expectRevert(AbyssiaVault.UnboundSlice.selector);
        vault.exitTransfer(address(meme), 1, AbyssiaVault.Exit(1, 2, receiver, alice));
        vm.stopPrank();
    }

    /// Worst case at the cap: MAX_POSITIONS positions across v3 and v4, every token a
    /// two-stage burner that fails just under the fallback threshold to the receiver and
    /// then burns the whole budget on the vault fallback, and every burner also held as
    /// inventory (its transfer burns TOKEN_GAS). Must stay well under Arc's 30M.
    function test_worstCaseExitGasAtMaxPositions() public {
        // A larger NAV so 20 small positions fit the class allocation limit.
        _deposit(bob, 100_000e6);
        uint256 cap = vault.MAX_POSITIONS();
        (uint256 n3, uint256 n4) = vault.positionCount();
        MockTwoStageBurnerERC20[] memory ts = new MockTwoStageBurnerERC20[](cap);
        uint256 k;
        uint256 firstBurnerId;
        for (uint256 i = n3 + n4; i < cap; i++) {
            ts[k] = new MockTwoStageBurnerERC20();
            bytes32 poolId;
            if (i % 2 == 0) (, poolId) = _addV3Pool(address(ts[k]));
            else (, poolId) = _addV4Pool(address(ts[k]));
            uint256 id = _openInRange(poolId, 50e6);
            _keeperSwap(poolId, true, 5e6); // also held as inventory: a hostile transfer in the token loop
            if (k == 0) firstBurnerId = id;
            k++;
        }
        (n3, n4) = vault.positionCount();
        assertEq(n3 + n4, cap);
        // 120k: under 60% of SLICE_GAS once the slice's own cost before the transfer is added.
        for (uint256 i = 0; i < k; i++) {
            ts[i].arm(receiver, address(vault), 120_000);
        }

        uint256 shares = vault.balanceOf(bob) / 10;
        // Really the worst case: the cheap failure earns the (all-gas-burning) vault fallback.
        vm.expectCall(
            address(vault),
            abi.encodeCall(
                vault.exitSlice,
                (
                    P3,
                    firstBurnerId,
                    AbyssiaVault.Exit(shares, vault.totalSupply(), receiver, bob),
                    address(vault)
                )
            ),
            uint64(1)
        );
        uint256 g = gasleft();
        vm.prank(bob);
        vault.redeemInKind(shares, receiver);
        uint256 used = g - gasleft();
        emit log_named_uint(
            "worst-case redeemInKind gas (20 positions + inventory, 18 two-stage burners)", used
        );
        assertLt(used, 20_000_000);
    }

    function _liq3(uint256 id) internal view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = vault.npm().positions(id);
    }

    function _liq4(uint256 id) internal view returns (uint128) {
        return vault.posm().getPositionLiquidity(id);
    }
}
