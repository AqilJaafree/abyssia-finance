import { RawLog } from '../decode';
import { decodeV4InitializeLog } from './decode';
import { V4_INITIALIZE_TOPIC0, ETH_CURRENCIES, V4_INITIALIZE_LOOKBACK_BLOCKS } from './config';

export interface V4PoolMeta {
  poolId: string; // bytes32
  token: string; // the non-USDC currency address (lowercase)
  ethIsCurrency0: boolean; // true if the USDC leg is currency0
  fee: number; // Initialize fee: a static tier (pips), or 0x800000 = dynamic-fee flag
  tickSpacing?: number;
  hooks?: string;
  currency0?: string;
  currency1?: string;
}

export interface RepairBudget {
  left: number;
  deferred?: number;
  failed?: number;
}

export type LogFetcher = (params: {
  address?: string[];
  topics: (string | null)[];
  fromBlock: number;
  toBlock: number;
}) => Promise<RawLog[]>;

// Resolve a PoolId's anchor-paired metadata from its Initialize event, cache-first.
// v4 pools are not contracts, so the currencies live only in the Initialize log.
//
// `anchors` defaults to ETH_CURRENCIES ({ARC_USDC} on this chain — see
// src/arc/v4/config.ts). NOTE: `ethIsCurrency0` means "anchor is currency0" —
// the name is inherited from the ported nautilus code; the value is correct.
export async function resolveV4PoolMeta(
  poolId: string,
  cache: Record<string, V4PoolMeta | null>,
  getLogs: LogFetcher,
  currentBlock: number,
  anchors: Set<string> = ETH_CURRENCIES,
  repairBudget?: RepairBudget
): Promise<V4PoolMeta | null> {
  const cached = cache[poolId];
  if (cached !== undefined && (cached === null || isComplete(cached))) return cached;
  // The budget gates BOTH a repair (cached !== undefined, incomplete) and a
  // first sighting (cached === undefined) — each is one getLogs call of equal
  // cost, and a burst of brand-new pools can flood a cycle exactly as badly
  // as a burst of incomplete old ones. Verified live 2026-09-16: a single
  // ~60s Arc polling window can carry 260+ distinct v4 pools, and this check
  // used to apply ONLY to repairs, so every one of those pools got an
  // unbudgeted lookup — the v4 loop never finished a cycle. Deferring a first
  // sighting returns `undefined` (via `cached`, which already IS undefined
  // here) rather than caching anything, so it's retried next cycle.
  if (repairBudget) {
    if (repairBudget.left <= 0) {
      repairBudget.deferred = (repairBudget.deferred ?? 0) + 1;
      return cached;
    }
    repairBudget.left--;
  }
  try {
    const logs = await getLogs({
      topics: [V4_INITIALIZE_TOPIC0, poolId],
      // Bounded, not genesis (`fromBlock: 1`) — see V4_INITIALIZE_LOOKBACK_BLOCKS
      // in ./config for why: an unbounded query always fails on this chain's
      // RPC, which silently made every pool look non-USDC-anchored.
      fromBlock: Math.max(1, currentBlock - V4_INITIALIZE_LOOKBACK_BLOCKS),
      toBlock: currentBlock,
    });
    if (logs.length === 0) {
      if (repairBudget) {
        repairBudget.failed = (repairBudget.failed ?? 0) + 1;
      }
      return cached ?? null;
    }
    const init = decodeV4InitializeLog(logs[0]);
    const c0IsEth = anchors.has(init.currency0);
    const c1IsEth = anchors.has(init.currency1);
    if (!c0IsEth && !c1IsEth) {
      if (cached !== undefined) {
        if (repairBudget) repairBudget.failed = (repairBudget.failed ?? 0) + 1;
        return null;
      }
      cache[poolId] = null;
      return null;
    }
    const meta: V4PoolMeta = {
      poolId,
      token: c0IsEth ? init.currency1 : init.currency0,
      ethIsCurrency0: c0IsEth,
      fee: Number(init.fee),
      tickSpacing: init.tickSpacing,
      hooks: init.hooks,
      currency0: init.currency0,
      currency1: init.currency1,
    };
    cache[poolId] = meta;
    return meta;
  } catch {
    if (repairBudget) {
      repairBudget.failed = (repairBudget.failed ?? 0) + 1;
    }
    return cached ?? null;
  }
}

function isComplete(meta: V4PoolMeta): boolean {
  return (
    meta.tickSpacing !== undefined &&
    meta.hooks !== undefined &&
    meta.currency0 !== undefined &&
    meta.currency1 !== undefined
  );
}
