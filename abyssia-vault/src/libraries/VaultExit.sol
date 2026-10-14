// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {V3Positions} from "../v3/V3Positions.sol";
import {V4Positions} from "../v4/V4Positions.sol";
import {VaultBook} from "./VaultBook.sol";
import {VaultOps} from "./VaultOps.sol";

/// @dev The vault's gas-capped self-call targets, as VaultExit calls them.
interface IVaultSelfCalls {
    function exitSlice(
        VaultBook.Protocol protocol,
        uint256 tokenId,
        VaultExit.Exit calldata x,
        address recipient
    ) external;
    function exitTransfer(address token, uint256 amount, VaultExit.Exit calldata x) external;
    function harvestFor(VaultBook.Protocol protocol, uint256 tokenId) external;
}

/// @title VaultExit
/// @notice The vault's loops over every position: the in-kind exit and the settlement
/// harvest, as an EXTERNAL library (delegatecalled, so `address(this)` is the vault). Each
/// step is a gas-capped call back into the vault, so a frozen or hostile token can only
/// skip its own step.
library VaultExit {
    uint256 internal constant BPS = 10_000;
    /// @dev Gas budget of ONE in-kind slice attempt (a normal slice uses ~170-200k).
    uint256 internal constant SLICE_GAS = 500_000;
    /// @dev Gas budget of ONE inventory-token transfer in an in-kind exit.
    uint256 internal constant TOKEN_GAS = 100_000;
    /// @dev Gas budget of ONE fee harvest at settlement.
    uint256 internal constant HARVEST_GAS = 400_000;
    /// @dev Kept back on top of a capped call's budget * 64/63.
    uint256 internal constant GAS_RESERVE = 50_000;
    /// @dev Retry an in-kind slice with the vault as recipient only if the failed attempt
    /// used at most this share of SLICE_GAS: an honest refusal fails early, a gas burner
    /// uses nearly everything at any call depth.
    uint256 internal constant FALLBACK_MAX_BPS = 6_000;

    /// @notice One in-kind exit: `shares` of `supply` (before the burn), paid to `receiver`,
    /// IOUs owed to `owner` (the holder whose shares were burned).
    struct Exit {
        uint256 shares;
        uint256 supply;
        address receiver;
        address owner;
    }

    event SliceSkipped(VaultBook.Protocol indexed protocol, uint256 indexed tokenId);
    event HarvestSkipped(VaultBook.Protocol indexed protocol, uint256 indexed tokenId);

    error InsufficientGas();

    /// @notice Per position and per inventory token: deliver the slice to `x.receiver`; if
    /// that failed cheaply, take it into the vault and record an IOU for the owner; if even
    /// that fails (or the first attempt burned its gas), leave it to the remaining holders.
    /// The vault binds `x` (transient storage) before calling and checks it in each step.
    function redeemInKind(VaultBook.Book storage b, Exit memory x) external {
        uint256 n3 = V3Positions.count(b.v3);
        uint256 n = n3 + V4Positions.count(b.v4);
        for (uint256 i = 0; i < n; i++) {
            (VaultBook.Protocol protocol, uint256 tokenId) = _positionAt(b, n3, i);
            _exitPosition(protocol, tokenId, x);
        }
        uint256 nt = b.tokens.length;
        for (uint256 i = 0; i < nt; i++) {
            _exitToken(b, b.tokens[i], x);
        }
    }

    /// @notice Harvest every position's fees into the vault, each in a gas-capped self-call.
    function harvestAll(VaultBook.Book storage b) external {
        uint256 n3 = V3Positions.count(b.v3);
        uint256 n = n3 + V4Positions.count(b.v4);
        for (uint256 i = 0; i < n; i++) {
            (VaultBook.Protocol protocol, uint256 tokenId) = _positionAt(b, n3, i);
            _requireGas(HARVEST_GAS);
            try IVaultSelfCalls(address(this)).harvestFor{gas: HARVEST_GAS}(protocol, tokenId) {}
            catch {
                emit HarvestSkipped(protocol, tokenId);
            }
        }
    }

    function _exitPosition(VaultBook.Protocol protocol, uint256 tokenId, Exit memory x) private {
        _requireGas(SLICE_GAS);
        uint256 gasBefore = gasleft();
        try IVaultSelfCalls(address(this)).exitSlice{gas: SLICE_GAS}(protocol, tokenId, x, x.receiver) {
            return;
        } catch {}
        if (gasBefore - gasleft() > SLICE_GAS * FALLBACK_MAX_BPS / BPS) {
            emit SliceSkipped(protocol, tokenId);
            return;
        }
        _requireGas(SLICE_GAS);
        try IVaultSelfCalls(address(this)).exitSlice{gas: SLICE_GAS}(protocol, tokenId, x, address(this)) {}
        catch {
            emit SliceSkipped(protocol, tokenId);
        }
    }

    /// @dev Inventory share: debited first; if the transfer fails it is owed instead (the
    /// tokens never left, so the IOU is exact).
    function _exitToken(VaultBook.Book storage b, address token, Exit memory x) private {
        uint256 amount = Math.mulDiv(b.tokenBalance[token], x.shares, x.supply);
        if (amount == 0) return;
        b.tokenBalance[token] -= amount;
        _requireGas(TOKEN_GAS);
        try IVaultSelfCalls(address(this)).exitTransfer{gas: TOKEN_GAS}(token, amount, x) {}
        catch {
            VaultOps.recordOwed(b, x.owner, token, amount);
        }
    }

    function _positionAt(VaultBook.Book storage b, uint256 n3, uint256 i)
        private
        view
        returns (VaultBook.Protocol, uint256)
    {
        return i < n3
            ? (VaultBook.Protocol.V3, V3Positions.tokenIdAt(b.v3, i))
            : (VaultBook.Protocol.V4, V4Positions.tokenIdAt(b.v4, i - n3));
    }

    /// @dev EIP-150: a CALL forwards at most 63/64 of the remaining gas. Revert rather than
    /// let a capped call fail for lack of gas (which would silently skip a step).
    function _requireGas(uint256 budget) private view {
        if (gasleft() < budget * 64 / 63 + GAS_RESERVE) revert InsufficientGas();
    }
}
