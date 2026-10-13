// Arc-chain constants for the Uniswap v4 Top Movers board. Env-overridable.
import { ARC_USDC, nonNegativeIntEnv } from '../config';

// v4 PoolManager singleton on Arc. Confirmed live via Uniswap's own UniswapX
// integration playbook (Uniswap/UniswapX, playbook/chains/arc.md) — the same
// address as Robinhood Chain's PoolManager, which is expected: v4 core is
// deployed deterministically via CREATE2 across chains.
export const V4_POOL_MANAGER = (
  process.env.ARC_V4_POOL_MANAGER ??
  '0x8366a39cc670b4001a1121b8f6a443a643e40951'
).toLowerCase();

// keccak256 event signatures — part of v4's standard PoolManager bytecode,
// chain-agnostic, unchanged from nautilus's Robinhood-chain deployment.
// Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)
export const V4_SWAP_TOPIC0 =
  '0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f';
// Initialize(bytes32,address,address,uint24,int24,address,uint160,int24)
export const V4_INITIALIZE_TOPIC0 =
  '0xdd466e674ea557f56295e2d0218a125ea4b4f0f6f3307b95f85e6110838d6438';

// The v4 currency set this board matches against. Deliberately ARC_USDC ONLY
// — native currency (address(0), the 18-decimal representation of the same
// USDC balance) is never matched. See src/arc/config.ts's naming note and the
// spec's "Key architectural decision" section: mixing the two decimal
// representations is Arc's #1 documented integration risk.
export const ETH_CURRENCIES = new Set([ARC_USDC]);

// Same blank-env-var guard as everything else in this codebase (see
// src/arc/config.ts) — a raw `parseInt(x ?? default)` would silently read
// NaN from a Railway var that's defined but empty.
export const V4_TOP_N = nonNegativeIntEnv(
  process.env.V4_MOVERS_TOP_N ?? process.env.MOVERS_TOP_N,
  5
);
export const V4_POLL_SECONDS = nonNegativeIntEnv(process.env.V4_MOVERS_POLL_SECONDS, 60);

// Paced repair budget for pre-existing incomplete registry entries — see
// nautilus's src/robinhood/v4/config.ts for the full rationale (repair reads
// are full-range getLogs and must not outlast the poll interval). Ported
// unchanged; oarfish has no LP path depending on these fields being complete,
// but the repair machinery is what keeps a board entry from being served with
// undefined tickSpacing/hooks forever, so it stays.
export const V4_META_REPAIR_PER_CYCLE = nonNegativeIntEnv(
  process.env.V4_META_REPAIR_PER_CYCLE,
  25
);
export const V4_META_REPAIR_MAX_MS = nonNegativeIntEnv(
  process.env.V4_META_REPAIR_MAX_MS,
  20_000
);
export const V4_MAX_LOOKBACK_BLOCKS = nonNegativeIntEnv(
  process.env.V4_MOVERS_MAX_LOOKBACK_BLOCKS,
  6000
);

// How far back resolveV4PoolMeta searches for a pool's Initialize event.
// NOT unbounded (i.e. NOT `fromBlock: 1`) — verified live 2026-09-16 that the
// Blockdaemon Arc RPC only serves eth_getLogs for roughly the last ~300k
// blocks; a query starting at block 1 always fails with "pruned history
// unavailable", regardless of range size. That failure was previously
// swallowed by this resolver's catch-all and returned as `null` — silently
// treating EVERY v4 pool as "not USDC-anchored" even when it genuinely was,
// because the lookup could never succeed at all. A pool initialized before
// this window is a real, unfixable gap on this RPC (its Initialize event is
// simply unreachable) — not something a smaller/larger default here changes.
export const V4_INITIALIZE_LOOKBACK_BLOCKS = nonNegativeIntEnv(
  process.env.V4_INITIALIZE_LOOKBACK_BLOCKS,
  250_000
);
