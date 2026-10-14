// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {V4Positions} from "../../src/v4/V4Positions.sol";
import {IV4PositionManager} from "../../src/interfaces/IV4PositionManager.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";
import {IStateView} from "../../src/interfaces/IStateView.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";

/// @dev Stands in for the vault: holds the library state, the NFTs and the tokens.
/// `inKindExit` / `sliceTo` / `claimOwed` are the REFERENCE implementation of the
/// in-kind exit pattern for v4 positions (Plan 5 copies it into the vault). It already
/// uses the Plan 5 fallback rule: retry with the vault as recipient ONLY if the first
/// attempt failed cheaply (<= FALLBACK_MAX_BPS of SLICE_GAS); anything that burned more
/// is skipped. The `probe*` entrypoints at the bottom are test-only probes, NOT part of
/// the pattern.
contract V4PositionsHarness {
    using SafeERC20 for IERC20;
    using TransientSlot for bytes32;
    using TransientSlot for TransientSlot.Bytes32Slot;

    V4Positions.State internal s;
    IV4PositionManager public immutable posm;
    IPermit2 public immutable permit2;
    IStateView public immutable stateView;

    /// @dev Slices collected to the vault because they could not be delivered to the
    /// receiver; claimable via `claimOwed`. Not part of the vault's own assets.
    mapping(address receiver => mapping(address token => uint256)) public owed;
    /// @dev Sum of `owed[*][token]`. A vault must exclude it from `sweepSurplus` and
    /// from any balance-based valuation / NAV: these tokens belong to exited holders.
    mapping(address token => uint256) public owedTotal;
    /// @dev Fees harvested into the vault during exits. A vault credits these to its
    /// inventory / idle in the same transaction.
    mapping(address token => uint256) public harvested;

    /// @dev Gas budget of ONE slice attempt (a normal v4 slice, fee harvest included, uses
    /// ~170k; a failure on a blocked receiver ~155k).
    uint256 public constant SLICE_GAS = 500_000;
    /// @dev Kept back on top of SLICE_GAS * 64/63 for the call itself and bookkeeping.
    uint256 public constant GAS_RESERVE = 50_000;
    /// @dev Retry with the vault as recipient only if the failed attempt used at most
    /// this share of SLICE_GAS. An honest failure (receiver blocked, token paused)
    /// reverts early; a gas burner uses (nearly) everything, at any call depth.
    uint256 public constant FALLBACK_MAX_BPS = 6000;
    /// @dev Transient slot binding `sliceTo` to the exit in progress:
    /// keccak256(abi.encode(shares, supply, receiver)), zero outside an exit.
    bytes32 internal constant EXIT_BINDING = keccak256("abyssia.V4PositionsHarness.exitBinding");

    event SliceSkipped(uint256 indexed tokenId);

    error OnlySelf();
    error UnboundSlice();
    error ExitInProgress();
    error InsufficientGasForSlice();
    error InvalidReceiver();

    constructor(IV4PositionManager posm_, IPermit2 permit2_, IStateView stateView_) {
        posm = posm_;
        permit2 = permit2_;
        stateView = stateView_;
    }

    function open(V4Positions.OpenParams calldata p)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 spent0, uint256 spent1)
    {
        return V4Positions.open(s, posm, permit2, stateView, p);
    }

    function withdraw(uint256 tokenId, uint128 liquidity, address recipient)
        external
        returns (uint256, uint256, uint256, uint256)
    {
        return V4Positions.withdraw(s, posm, stateView, tokenId, liquidity, 0, 0, block.timestamp, recipient);
    }

    function withdrawWithMins(uint256 tokenId, uint128 liquidity, uint256 min0, uint256 min1)
        external
        returns (uint256, uint256, uint256, uint256)
    {
        return V4Positions.withdraw(
            s, posm, stateView, tokenId, liquidity, min0, min1, block.timestamp, address(this)
        );
    }

    function collectFees(uint256 tokenId) external returns (uint256, uint256) {
        return V4Positions.collectFees(s, posm, stateView, tokenId, block.timestamp);
    }

    function close(uint256 tokenId) external {
        V4Positions.close(s, posm, tokenId, block.timestamp);
    }

    /// @notice In-kind exit across every position. Per position: deliver the slice to
    /// `receiver`; if that failed cheaply, collect it to this contract and record an IOU;
    /// if even that fails (or the first attempt burned its gas), leave the slice in the
    /// position and emit SliceSkipped.
    /// @param supply total share supply BEFORE the exiting shares were burned.
    function inKindExit(uint256 shares, uint256 supply, address receiver) external {
        _checkReceiver(receiver);
        // No nested exit (a token callback re-entering here would clobber the binding).
        if (_exitBinding() != bytes32(0)) revert ExitInProgress();
        EXIT_BINDING.asBytes32().tstore(keccak256(abi.encode(shares, supply, receiver)));
        uint256 n = V4Positions.count(s);
        for (uint256 i = 0; i < n; i++) {
            _exitPosition(V4Positions.tokenIdAt(s, i), shares, supply, receiver);
        }
        EXIT_BINDING.asBytes32().tstore(bytes32(0));
    }

    /// @dev All bookkeeping (harvested fees, IOUs) happens INSIDE the gas-capped `sliceTo`
    /// frame: token-reported balance deltas are untrusted, so an overflow they cause only
    /// fails that one attempt (-> fallback / skip), never the whole exit.
    function _exitPosition(uint256 tokenId, uint256 shares, uint256 supply, address receiver) private {
        _requireSliceGas();
        uint256 gasBefore = gasleft();
        try this.sliceTo{gas: SLICE_GAS}(tokenId, shares, supply, receiver, receiver) {
            return;
        } catch {}
        // Only a cheap failure earns a second attempt: a gas burner (at any call depth)
        // costs one SLICE_GAS, never two.
        if (gasBefore - gasleft() > SLICE_GAS * FALLBACK_MAX_BPS / 10_000) {
            emit SliceSkipped(tokenId);
            return;
        }
        _requireSliceGas();
        try this.sliceTo{gas: SLICE_GAS}(tokenId, shares, supply, receiver, address(this)) {}
        catch {
            emit SliceSkipped(tokenId);
        }
    }

    /// @dev A slice sent to any of these would be lost or unaccounted: to the vault it
    /// lands with no IOU, to the PositionManager anyone can SWEEP it, to the PoolManager
    /// it is stranded, and 0..2 are rejected by the library anyway.
    function _checkReceiver(address receiver) private view {
        if (
            uint160(receiver) <= 2 || receiver == address(this) || receiver == address(posm)
                || receiver == posm.poolManager() || receiver == address(permit2)
        ) revert InvalidReceiver();
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

    function _recordHarvest(PoolKey memory key, uint256 fee0, uint256 fee1) private {
        harvested[key.currency0] += fee0;
        harvested[key.currency1] += fee1;
    }

    /// @dev Self-call only, and only for the exit in progress: its own call frame makes
    /// the fee harvest + decrease + take revert atomically when a token transfer fails.
    /// `(shares, supply, receiver)` must match the transient binding written by
    /// `inKindExit`, and the slice can only go to that receiver or to this contract (the
    /// IOU fallback). The library returns balance deltas measured inside this gas-capped
    /// frame, so untrusted `balanceOf` calls stay under SLICE_GAS and fee-on-transfer
    /// tokens cannot over-credit an IOU. Harvested fees and (for the vault-recipient
    /// fallback) the IOU are recorded here too, so a token reporting an absurd delta
    /// can only fail this attempt.
    function sliceTo(uint256 tokenId, uint256 shares, uint256 supply, address receiver, address recipient)
        external
        returns (uint256 fee0, uint256 fee1, uint256 got0, uint256 got1)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        if (
            _exitBinding() != keccak256(abi.encode(shares, supply, receiver))
                || (recipient != receiver && recipient != address(this))
        ) revert UnboundSlice();
        (fee0, fee1, got0, got1) = V4Positions.withdrawSlice(
            s, posm, stateView, tokenId, shares, supply, recipient, block.timestamp
        );
        (PoolKey memory key,) = posm.getPoolAndPositionInfo(tokenId);
        _recordHarvest(key, fee0, fee1);
        if (recipient == address(this)) {
            _recordOwed(receiver, key.currency0, got0);
            _recordOwed(receiver, key.currency1, got1);
        }
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
        return V4Positions.count(s);
    }

    function tokenIdAt(uint256 i) external view returns (uint256) {
        return V4Positions.tokenIdAt(s, i);
    }

    function positionAmounts(uint256 tokenId) external view returns (uint256, uint256) {
        return V4Positions.positionAmounts(posm, stateView, tokenId);
    }

    // ---------------------------------------------------------------------------------
    // TEST-ONLY probes (not part of the reference pattern; a vault must not have these).
    // ---------------------------------------------------------------------------------

    /// @dev Self-calls `sliceTo` with no exit binding in place.
    function probeUnboundSelfSlice(uint256 tokenId, uint256 shares, uint256 supply, address receiver)
        external
        returns (uint256, uint256, uint256, uint256)
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
    ) external returns (uint256 f0, uint256 f1, uint256 a0, uint256 a1) {
        EXIT_BINDING.asBytes32().tstore(keccak256(abi.encode(bShares, bSupply, bReceiver)));
        (f0, f1, a0, a1) = this.sliceTo(tokenId, shares, supply, receiver, recipient);
        EXIT_BINDING.asBytes32().tstore(bytes32(0));
    }
}
