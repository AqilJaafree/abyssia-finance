// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {V3Positions} from "../../src/v3/V3Positions.sol";
import {INonfungiblePositionManager as INPM} from "../../src/interfaces/INonfungiblePositionManager.sol";

/// @dev Stands in for the vault: holds the library state, the NFTs and the tokens.
/// `inKindExit` / `sliceTo` / `claimOwed` are the REFERENCE implementation of the
/// in-kind exit pattern required by V3Positions (see its NatSpec) for Plan 5. The
/// `probe*` entrypoints at the bottom are test-only probes, NOT part of the pattern.
contract V3PositionsHarness {
    using SafeERC20 for IERC20;
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.Bytes32Slot;

    V3Positions.State internal s;
    INPM public immutable npm;

    /// @dev Slices collected to the vault because they could not be delivered to the
    /// receiver; claimable via `claimOwed`. Not part of the vault's own assets.
    mapping(address receiver => mapping(address token => uint256)) public owed;
    /// @dev Sum of `owed[*][token]`. A vault must exclude it from `sweepSurplus` and
    /// from any balance-based valuation / NAV: these tokens belong to exited holders.
    mapping(address token => uint256) public owedTotal;

    /// @dev Gas budget of ONE slice attempt (a normal slice uses ~200k): bounds what a
    /// gas-burning token can take from the exit loop.
    uint256 public constant SLICE_GAS = 500_000;
    /// @dev Kept back on top of SLICE_GAS * 64/63 for the call itself and bookkeeping.
    uint256 public constant GAS_RESERVE = 50_000;
    /// @dev A failed attempt that used >= 90% of SLICE_GAS is treated as out-of-gas.
    /// Not 95%: the burning transfer runs 4 calls below `sliceTo` (library -> position
    /// manager -> pool -> token), each keeping back 1/64 of its gas, so a real OOG shows
    /// only ~94.8% used (measured). Honest slices that revert use well under 50%. A
    /// token that nests deeper to evade this only earns one extra SLICE_GAS attempt
    /// (the fallback), so the per-position cost stays bounded at 2 x SLICE_GAS.
    uint256 internal constant OOG_THRESHOLD_BPS = 9000;
    /// @dev Transient slot binding `sliceTo` to the exit in progress:
    /// keccak256(abi.encode(shares, supply, receiver)), zero outside an exit.
    bytes32 internal constant EXIT_BINDING = keccak256("abyssia.V3PositionsHarness.exitBinding");

    event SliceSkipped(uint256 indexed tokenId);

    error OnlySelf();
    error UnboundSlice();
    error ExitInProgress();
    error InsufficientGasForSlice();
    error InvalidReceiver();

    constructor(INPM npm_) {
        npm = npm_;
    }

    function open(V3Positions.OpenParams calldata p)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        return V3Positions.open(s, npm, p);
    }

    function withdraw(uint256 tokenId, uint128 liquidity, address recipient)
        external
        returns (uint256, uint256)
    {
        return V3Positions.withdraw(s, npm, tokenId, liquidity, 0, 0, block.timestamp, recipient);
    }

    function withdrawWithMins(uint256 tokenId, uint128 liquidity, uint256 min0, uint256 min1)
        external
        returns (uint256, uint256)
    {
        return V3Positions.withdraw(s, npm, tokenId, liquidity, min0, min1, block.timestamp, address(this));
    }

    function collectFees(uint256 tokenId, address recipient) external returns (uint256, uint256) {
        return V3Positions.collectFees(s, npm, tokenId, recipient);
    }

    function close(uint256 tokenId) external {
        V3Positions.close(s, npm, tokenId);
    }

    /// @notice In-kind exit across every position. Per position: deliver the slice to
    /// `receiver`; if a token transfer fails, collect it to this contract and record an
    /// IOU; if even that fails (or the first attempt ran out of gas), leave the slice in
    /// the position and emit SliceSkipped.
    /// @param supply total share supply BEFORE the exiting shares were burned.
    function inKindExit(uint256 shares, uint256 supply, address receiver) external {
        // A slice sent to the vault itself would land with no IOU (lost to the holder).
        if (receiver == address(0) || receiver == address(this) || receiver == address(npm)) {
            revert InvalidReceiver();
        }
        // No nested exit (a token callback re-entering here would clobber the binding).
        if (_exitBinding() != bytes32(0)) revert ExitInProgress();
        EXIT_BINDING.asBytes32().tstore(keccak256(abi.encode(shares, supply, receiver)));
        uint256 n = V3Positions.count(s);
        for (uint256 i = 0; i < n; i++) {
            _exitPosition(V3Positions.tokenIdAt(s, i), shares, supply, receiver);
        }
        EXIT_BINDING.asBytes32().tstore(bytes32(0));
    }

    function _exitPosition(uint256 tokenId, uint256 shares, uint256 supply, address receiver) private {
        _requireSliceGas();
        uint256 gasBefore = gasleft();
        try this.sliceTo{gas: SLICE_GAS}(tokenId, shares, supply, receiver, receiver) {
            return;
        } catch {}
        // The attempt burned (nearly) its whole budget: treat it as a gas-burning token
        // and do not hand it a second SLICE_GAS through the fallback.
        if (gasBefore - gasleft() >= SLICE_GAS * OOG_THRESHOLD_BPS / 10_000) {
            emit SliceSkipped(tokenId);
            return;
        }
        _requireSliceGas();
        // The IOU is recorded inside sliceTo: an overflow from an absurd token-reported
        // delta then only fails this attempt, never the whole exit.
        try this.sliceTo{gas: SLICE_GAS}(tokenId, shares, supply, receiver, address(this)) {}
        catch {
            emit SliceSkipped(tokenId);
        }
    }

    /// @dev EIP-150: a CALL forwards at most 63/64 of the remaining gas, so without this
    /// a caller sending too little gas would make every slice fail and be silently
    /// skipped (forfeited). Revert instead so the caller retries with more gas.
    function _requireSliceGas() private view {
        if (gasleft() < SLICE_GAS * 64 / 63 + GAS_RESERVE) revert InsufficientGasForSlice();
    }

    function _recordOwed(address receiver, address token, uint256 amount) private {
        if (amount == 0) return;
        owed[receiver][token] += amount;
        owedTotal[token] += amount;
    }

    /// @dev Self-call only, and only for the exit in progress: its own call frame makes
    /// decrease+collect revert atomically when a token transfer fails. `(shares, supply,
    /// receiver)` must match the transient binding written by `inKindExit`, and the
    /// slice can only go to that receiver or to this contract (the IOU fallback).
    /// When `recipient == address(this)` it returns this contract's BALANCE DELTA per
    /// token (not the position manager's reported amounts), so fee-on-transfer tokens
    /// cannot over-credit an IOU, and records that IOU. Measuring and recording inside this
    /// gas-capped frame keeps the untrusted `balanceOf` calls under SLICE_GAS and lets an
    /// absurd reported delta fail only this attempt.
    function sliceTo(uint256 tokenId, uint256 shares, uint256 supply, address receiver, address recipient)
        external
        returns (uint256, uint256)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        if (
            _exitBinding() != keccak256(abi.encode(shares, supply, receiver))
                || (recipient != receiver && recipient != address(this))
        ) revert UnboundSlice();
        if (recipient != address(this)) {
            return V3Positions.withdrawSlice(s, npm, tokenId, shares, supply, recipient, block.timestamp);
        }
        (,, address token0, address token1,,,,,,,,) = npm.positions(tokenId);
        uint256 before0 = IERC20(token0).balanceOf(address(this));
        uint256 before1 = IERC20(token1).balanceOf(address(this));
        V3Positions.withdrawSlice(s, npm, tokenId, shares, supply, recipient, block.timestamp);
        uint256 got0 = IERC20(token0).balanceOf(address(this)) - before0;
        uint256 got1 = IERC20(token1).balanceOf(address(this)) - before1;
        _recordOwed(receiver, token0, got0);
        _recordOwed(receiver, token1, got1);
        return (got0, got1);
    }

    function claimOwed(address token) external {
        uint256 amount = owed[msg.sender][token];
        owed[msg.sender][token] = 0;
        owedTotal[token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function _exitBinding() private view returns (bytes32) {
        return EXIT_BINDING.asBytes32().tload();
    }

    function count() external view returns (uint256) {
        return V3Positions.count(s);
    }

    function tokenIdAt(uint256 i) external view returns (uint256) {
        return V3Positions.tokenIdAt(s, i);
    }

    function positionAmounts(uint256 tokenId) external view returns (uint256, uint256) {
        return V3Positions.positionAmounts(npm, tokenId);
    }

    // ---------------------------------------------------------------------------------
    // TEST-ONLY probes (not part of the reference pattern; a vault must not have these).
    // ---------------------------------------------------------------------------------

    /// @dev Self-calls `sliceTo` with no exit binding in place.
    function probeUnboundSelfSlice(uint256 tokenId, uint256 shares, uint256 supply, address receiver)
        external
        returns (uint256, uint256)
    {
        return this.sliceTo(tokenId, shares, supply, receiver, receiver);
    }

    /// @dev Binds `(bShares, bSupply, bReceiver)` as an exit would, then self-calls
    /// `sliceTo` with the given arguments, and clears the binding.
    function probeBoundSelfSlice(
        uint256 bShares,
        uint256 bSupply,
        address bReceiver,
        uint256 tokenId,
        uint256 shares,
        uint256 supply,
        address receiver,
        address recipient
    ) external returns (uint256 a0, uint256 a1) {
        EXIT_BINDING.asBytes32().tstore(keccak256(abi.encode(bShares, bSupply, bReceiver)));
        (a0, a1) = this.sliceTo(tokenId, shares, supply, receiver, recipient);
        EXIT_BINDING.asBytes32().tstore(bytes32(0));
    }
}
