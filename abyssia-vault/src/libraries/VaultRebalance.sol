// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultRegistry} from "../registry/VaultRegistry.sol";
import {V3Positions} from "../v3/V3Positions.sol";
import {V4Positions} from "../v4/V4Positions.sol";
import {VaultBook} from "./VaultBook.sol";
import {VaultOps} from "./VaultOps.sol";
import {Shapes} from "./Shapes.sol";
import {PoolOracle} from "./PoolOracle.sol";

/// @title VaultRebalance
/// @notice Atomic per-pool rebalancing into a liquidity shape, and the verified stop-loss,
/// as an EXTERNAL library (delegatecalled by the vault, like VaultOps). Returns USDC
/// amounts; the vault moves idle USDC and runs the allocation check.
library VaultRebalance {
    uint256 internal constant BPS = 10_000;

    struct Args {
        bytes32 poolId;
        Shapes.Spec spec;
        uint256 usdcAmount; // from idle USDC
        uint256 tokenAmount; // from token inventory (after the unwind)
        int24 expectedTick; // the keeper's view of the pool's current tick
        uint256 deadline;
    }

    /// @dev The vault's price guards.
    struct Limits {
        int24 maxTickDeviation; // current tick vs Args.expectedTick
        uint32 twapWindow; // v3 only
        int24 maxTwapDeviation; // v3 only: current tick vs TWAP
    }

    event Rebalanced(
        bytes32 indexed poolId, uint8 shape, uint8 side, uint8 ranges, int24 width, uint256 entryValue
    );
    event StopLossTriggered(bytes32 indexed poolId, uint256 entryValue, uint256 value);

    error ShapeNotAllowed(uint8 shape);
    error CooldownActive(uint256 until);
    error TickNotAsExpected(int24 tick, int24 expectedTick);
    error NoEntryValue(bytes32 poolId);
    error StopLossNotReached(uint256 value, uint256 trigger);

    /// @notice Withdraw every range the vault has in `a.poolId` (principal and fees into the
    /// vault, NFTs burned), then open `a.spec` from `a.usdcAmount` USDC and `a.tokenAmount`
    /// of the token. Enforces the class's allowed shapes, max ranges, range width (per
    /// range, via VaultOps.open) and rebalance cooldown; the pool's current tick must be
    /// within `l.maxTickDeviation` of `a.expectedTick` and, for v3, near its TWAP.
    /// @param idle the vault's idle USDC before the call
    /// @return usdcIn USDC the unwind returned (credit it to idle)
    /// @return usdcSpent USDC the new ranges took (debit it from idle)
    /// @return x the pool's class, for the vault's allocation check
    function rebalance(
        VaultBook.Book storage b,
        VaultBook.Env memory e,
        Args memory a,
        Limits memory l,
        uint256 idle
    ) external returns (uint256 usdcIn, uint256 usdcSpent, VaultOps.Exposure memory x) {
        VaultBook.PoolMeta memory m;
        (m, x.params, x.cls) = VaultBook.usablePool(b, e, a.poolId);
        if (a.spec.shape & x.params.allowedShapes == 0) revert ShapeNotAllowed(a.spec.shape);
        if (a.spec.ranges > x.params.maxRanges) revert VaultBook.TooManyRanges(a.poolId);
        uint256 last = b.lastRebalance[a.poolId];
        if (last != 0 && block.timestamp < last + x.params.rebalanceCooldown) {
            revert CooldownActive(last + x.params.rebalanceCooldown);
        }
        int24 tick = _checkPrice(e, m, a, l);

        usdcIn = _unwind(b, e, a.poolId);
        Shapes.Range[] memory ranges =
            Shapes.layout(a.spec, tick, m.tickSpacing, m.usdcIsToken0, a.usdcAmount, a.tokenAmount);
        uint256 available = idle + usdcIn;
        for (uint256 i = 0; i < ranges.length; i++) {
            if (ranges[i].usdc == 0 && ranges[i].token == 0) continue;
            (, uint256 spent,) = VaultOps.open(
                b,
                e,
                VaultOps.OpenArgs(
                    a.poolId,
                    ranges[i].tickLower,
                    ranges[i].tickUpper,
                    ranges[i].usdc,
                    ranges[i].token,
                    0,
                    0,
                    a.deadline
                ),
                available - usdcSpent
            );
            usdcSpent += spent;
        }
        uint256 entry = VaultBook.poolPositionsValue(b, e, a.poolId);
        b.entryValue[a.poolId] = entry;
        b.lastRebalance[a.poolId] = block.timestamp;
        emit Rebalanced(a.poolId, a.spec.shape, a.spec.side, a.spec.ranges, a.spec.width, entry);
    }

    /// @notice Pull all liquidity out of `poolId` into the vault (no swap), but only if its
    /// positions are worth at least the class's stopLossBps less than right after the last
    /// rebalance.
    /// @return usdcIn USDC the unwind returned (credit it to idle)
    function stopLoss(VaultBook.Book storage b, VaultBook.Env memory e, bytes32 poolId)
        external
        returns (uint256 usdcIn)
    {
        uint256 entry = b.entryValue[poolId];
        if (entry == 0) revert NoEntryValue(poolId);
        uint256 value = VaultBook.poolPositionsValue(b, e, poolId);
        VaultRegistry.AssetClass cls = e.registry.getPool(poolId).assetClass;
        uint256 trigger = entry * (BPS - e.registry.classParams(cls).stopLossBps) / BPS;
        if (value > trigger) revert StopLossNotReached(value, trigger);
        usdcIn = _unwind(b, e, poolId);
        b.entryValue[poolId] = 0;
        emit StopLossTriggered(poolId, entry, value);
    }

    /// @dev The pool's tick, after checking it against the keeper's expectation and (v3) the TWAP.
    function _checkPrice(VaultBook.Env memory e, VaultBook.PoolMeta memory m, Args memory a, Limits memory l)
        private
        view
        returns (int24 tick)
    {
        tick = VaultBook.currentTick(m, e.stateView, a.poolId);
        int24 dev = tick > a.expectedTick ? tick - a.expectedTick : a.expectedTick - tick;
        if (dev > l.maxTickDeviation) revert TickNotAsExpected(tick, a.expectedTick);
        if (m.protocol == VaultBook.Protocol.V3) {
            PoolOracle.requireNearTwap(m.v3Pool, l.twapWindow, l.maxTwapDeviation);
        }
    }

    /// @dev Withdraw, harvest and burn every position the vault has in `poolId`.
    function _unwind(VaultBook.Book storage b, VaultBook.Env memory e, bytes32 poolId)
        private
        returns (uint256 usdcIn)
    {
        (VaultBook.Protocol protocol, uint256[] memory ids) = _positionsIn(b, poolId);
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            uint128 liq =
                protocol == VaultBook.Protocol.V3 ? _v3Liquidity(e, id) : e.posm.getPositionLiquidity(id);
            if (liq > 0) {
                usdcIn += VaultOps.withdraw(b, e, protocol, VaultOps.Removal(id, liq, 0, 0, block.timestamp));
            }
            // v3 keeps fees in the position until collected; v4 paid them with the withdrawal.
            if (protocol == VaultBook.Protocol.V3) usdcIn += VaultOps.harvest(b, e, protocol, id);
            VaultOps.close(b, e, protocol, id);
        }
    }

    /// @dev Snapshot of the vault's position ids in `poolId` (a pool is one protocol).
    function _positionsIn(VaultBook.Book storage b, bytes32 poolId)
        private
        view
        returns (VaultBook.Protocol protocol, uint256[] memory ids)
    {
        protocol = b.poolMeta[poolId].protocol;
        bool v3 = protocol == VaultBook.Protocol.V3;
        uint256 n = v3 ? V3Positions.count(b.v3) : V4Positions.count(b.v4);
        uint256[] memory all = new uint256[](n);
        uint256 k;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = v3 ? V3Positions.tokenIdAt(b.v3, i) : V4Positions.tokenIdAt(b.v4, i);
            if (b.positionPool[protocol][id] == poolId) all[k++] = id;
        }
        ids = new uint256[](k);
        for (uint256 i = 0; i < k; i++) {
            ids[i] = all[i];
        }
    }

    function _v3Liquidity(VaultBook.Env memory e, uint256 id) private view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = e.npm.positions(id);
    }
}
