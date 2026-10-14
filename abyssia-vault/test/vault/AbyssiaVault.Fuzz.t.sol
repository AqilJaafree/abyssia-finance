// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AbyssiaVaultTestBase} from "./AbyssiaVaultTestBase.sol";
import {VaultOps} from "../../src/libraries/VaultOps.sol";

contract AbyssiaVaultFuzzTest is AbyssiaVaultTestBase {
    address internal receiver = makeAddr("receiver");

    /// @dev Through swaps, positions in both protocols, outside trading, settlement and
    /// an in-kind exit, the vault's internal books always match what it really holds:
    /// USDC = idle + pending deposits + claimable + IOUs; MEME = inventory + IOUs.
    function testFuzz_booksMatchBalances(
        uint256 depositAmt,
        uint256 posAmt,
        uint256 tradeAmt,
        uint256 exitBps
    ) public {
        depositAmt = bound(depositAmt, 1_000e6, 100_000e6);
        // Total MEME-class exposure ~4.5 x posAmt: keep it under the 30% class limit.
        posAmt = bound(posAmt, 1e6, depositAmt / 20);
        tradeAmt = bound(tradeAmt, 1e6, 50_000e6);
        exitBps = bound(exitBps, 1, 10_000);

        _deposit(alice, depositAmt);
        _openInRange(v3PoolId, posAmt);
        _openInRange(v4PoolId, posAmt);
        _keeperSwap(v4PoolId, true, posAmt / 2);
        _traderSwapV3(address(meme), tradeAmt);
        _traderSwapV4(address(usdc), tradeAmt);
        _requestDeposit(bob, 1_000e6);
        _assertBooks();

        _settle();
        _assertBooks();

        uint256 shares = vault.balanceOf(alice) * exitBps / 10_000;
        if (shares > 0) {
            vm.prank(alice);
            vault.redeemInKind(shares, receiver);
        }
        _assertBooks();
    }

    function _assertBooks() internal view {
        assertEq(
            usdc.balanceOf(address(vault)),
            vault.idleAssets() + vault.pendingDepositAssets() + vault.claimableAssets()
                + vault.owedTotal(address(usdc)),
            "USDC books"
        );
        assertEq(
            meme.balanceOf(address(vault)),
            vault.tokenBalance(address(meme)) + vault.owedTotal(address(meme)),
            "MEME books"
        );
    }
}
