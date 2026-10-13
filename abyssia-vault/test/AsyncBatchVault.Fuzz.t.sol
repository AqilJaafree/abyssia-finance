// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./VaultTestBase.sol";

contract AsyncBatchVaultFuzzTest is VaultTestBase {
    /// @dev Claims from one batch never exceed what was minted for it.
    function testFuzz_batchClaimsNeverExceedMinted(uint256 a, uint256 b) public {
        a = bound(a, USDC, 400_000 * USDC);
        b = bound(b, USDC, 400_000 * USDC);
        _requestDeposit(alice, a);
        _requestDeposit(bob, b);
        _settle();
        vm.prank(alice);
        uint256 sa = vault.claimDeposit(1, alice);
        vm.prank(bob);
        uint256 sb = vault.claimDeposit(1, bob);
        (, uint128 minted,,,) = vault.batches(1);
        assertLe(sa + sb, minted);
    }

    /// @dev Deposit then redeem with no NAV change never returns more than deposited
    /// and loses at most 1 base unit to rounding.
    function testFuzz_roundTripNoProfitAtMostOneUnitLoss(uint256 seed, uint256 amount) public {
        seed = bound(seed, USDC, 400_000 * USDC);
        amount = bound(amount, USDC, 400_000 * USDC);
        _depositAndClaim(bob, seed); // existing depositor so supply/NAV are non-trivial
        uint256 shares = _depositAndClaim(alice, amount);
        vm.prank(alice);
        vault.requestRedeem(shares);
        uint256 id = vault.currentBatchId();
        _settle();
        vm.prank(alice);
        uint256 out = vault.claimRedeem(id, alice);
        assertLe(out, amount);
        assertGe(out + 1, amount);
    }

    /// @dev In-kind exit never pays more than the caller's pro-rata idle share.
    function testFuzz_inKindNeverOverpays(uint256 a, uint256 b, uint256 frac) public {
        a = bound(a, USDC, 400_000 * USDC);
        b = bound(b, USDC, 400_000 * USDC);
        uint256 sa = _depositAndClaim(alice, a);
        _depositAndClaim(bob, b);
        uint256 burn = bound(frac, 1, sa);
        uint256 navBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();
        vm.prank(alice);
        uint256 out = vault.redeemInKind(burn, alice);
        assertLe(out, (navBefore * burn) / supplyBefore);
    }
}
