// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultRegistry} from "../registry/VaultRegistry.sol";
import {V3Positions} from "../v3/V3Positions.sol";
import {V4Positions} from "../v4/V4Positions.sol";
import {VaultBook} from "./VaultBook.sol";
import {VaultOps} from "./VaultOps.sol";
import {Shapes} from "./Shapes.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

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
        uint256 tokenAmount; // from token inventory after the unwind; type(uint256).max = all of it
        int24 expectedTick; // the keeper's view of the pool's current tick
        uint256 deadline;
    }

    /// @dev The vault's price guards.
    struct Limits {
        int24 maxTickDeviation; // current tick vs Args.expectedTick
        uint32 twapWindow; // v3 only
        int24 maxTwapDeviation; // current tick vs the reference (v3 TWAP, v4 posted tick)
        uint16 minObservations; // v3 only: the pool's observation capacity floor
    }

    event Rebalanced(
        bytes32 indexed poolId, uint8 shape, uint8 side, uint8 ranges, int24 width, uint160 entrySqrtPrice
    );
    event StopLossTriggered(bytes32 indexed poolId, uint256 valueAtEntry, uint256 value);
    event PoolUnwound(bytes32 indexed poolId);

    error ShapeNotAllowed(uint8 shape);
    error CooldownActive(uint256 until);
    error TickNotAsExpected(int24 tick, int24 expectedTick);
    error NoEntryValue(bytes32 poolId);
    error StopLossNotReached(uint256 value, uint256 trigger);

    /// @notice Withdraw every range the vault has in `a.poolId` (principal and fees into the
    /// vault, NFTs burned), then open `a.spec` from `a.usdcAmount` USDC and `a.tokenAmount`
    /// of the token. Enforces the class's allowed shapes, max ranges, range width (per
    /// range, via VaultOps.open) and rebalance cooldown; the pool's current tick must be
    /// within `l.maxTickDeviation` of `a.expectedTick` and near its reference (v3: TWAP;
    /// v4: the posted reference tick).
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
        int24 tick = _checkPrice(b, e, m, a, l);

        usdcIn = _unwind(b, e, a.poolId);
        if (a.tokenAmount == type(uint256).max) a.tokenAmount = b.tokenBalance[m.token];
        Shapes.Range[] memory ranges =
            Shapes.layout(a.spec, tick, m.tickSpacing, m.usdcIsToken0, a.usdcAmount, a.tokenAmount);
        uint256 available = idle + usdcIn;
        for (uint256 i = 0; i < ranges.length; i++) {
            if (_skip(ranges[i], tick)) continue;
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
        _recordEntry(b, e, a);
    }

    /// @dev The pool's price now becomes its stop-loss basis.
    function _recordEntry(VaultBook.Book storage b, VaultBook.Env memory e, Args memory a) private {
        uint160 entry = VaultBook.sqrtPrice(b.poolMeta[a.poolId], e.stateView, a.poolId);
        b.entrySqrtPrice[a.poolId] = entry;
        b.lastRebalance[a.poolId] = block.timestamp;
        emit Rebalanced(a.poolId, a.spec.shape, a.spec.side, a.spec.ranges, a.spec.width, entry);
    }

    /// @notice Pull all liquidity out of `poolId` into the vault (no swap), but only if its
    /// positions, valued at the pool's reference price (v3: TWAP; v4: the posted reference
    /// tick), are worth at least the class's stopLossBps less than the same positions valued
    /// at the price of the last rebalance. Comparing the same liquidity at two prices makes
    /// it a loss from the price move alone, unaffected by exits and withdrawals since, and
    /// the reference price stops a pushed spot price from triggering it.
    /// @return usdcIn USDC the unwind returned (credit it to idle)
    function stopLoss(VaultBook.Book storage b, VaultBook.Env memory e, bytes32 poolId, Limits memory l)
        external
        returns (uint256 usdcIn)
    {
        uint160 entry = b.entrySqrtPrice[poolId];
        if (entry == 0) revert NoEntryValue(poolId);
        VaultBook.PoolMeta memory m = b.poolMeta[poolId];
        uint160 ref = TickMath.getSqrtPriceAtTick(
            VaultBook.referenceTick(b, m, poolId, l.twapWindow, l.minObservations)
        );
        uint256 atEntry = VaultBook.poolPositionsValueAt(b, e, poolId, entry);
        uint256 value = VaultBook.poolPositionsValueAt(b, e, poolId, ref);
        VaultRegistry.AssetClass cls = e.registry.getPool(poolId).assetClass;
        uint256 trigger = atEntry * (BPS - e.registry.classParams(cls).stopLossBps) / BPS;
        if (value > trigger) revert StopLossNotReached(value, trigger);
        usdcIn = unwind(b, e, poolId);
        emit StopLossTriggered(poolId, atEntry, value);
    }

    /// @notice Withdraw, harvest and burn every position the vault has in `poolId`, into
    /// the vault (no swap, no price check), and clear its stop-loss basis.
    /// @return usdcIn USDC the unwind returned (credit it to idle)
    function unwind(VaultBook.Book storage b, VaultBook.Env memory e, bytes32 poolId)
        public
        returns (uint256 usdcIn)
    {
        usdcIn = _unwind(b, e, poolId);
        b.entrySqrtPrice[poolId] = 0;
        emit PoolUnwound(poolId);
    }

    /// @dev The pool's tick, after checking it against the keeper's expectation and the
    /// pool's reference.
    function _checkPrice(
        VaultBook.Book storage b,
        VaultBook.Env memory e,
        VaultBook.PoolMeta memory m,
        Args memory a,
        Limits memory l
    ) private view returns (int24 tick) {
        tick = VaultBook.currentTick(m, e.stateView, a.poolId);
        int24 dev = tick > a.expectedTick ? tick - a.expectedTick : a.expectedTick - tick;
        if (dev > l.maxTickDeviation) revert TickNotAsExpected(tick, a.expectedTick);
        VaultBook.requireNearReference(
            b, m, a.poolId, tick, l.twapWindow, l.maxTwapDeviation, l.minObservations
        );
    }

    /// @dev Nothing to deploy; or the range containing the price is missing one token, so it
    /// would take zero liquidity (e.g. a BOTH layout from USDC only): skip it.
    function _skip(Shapes.Range memory r, int24 tick) private pure returns (bool) {
        if (r.usdc == 0 && r.token == 0) return true;
        bool containsPrice = r.tickLower <= tick && tick < r.tickUpper;
        return containsPrice && (r.usdc == 0 || r.token == 0);
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
