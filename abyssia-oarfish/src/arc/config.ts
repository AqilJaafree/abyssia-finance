// All Arc-chain constants for the Top Movers boards. Env-overridable.
//
// NAMING: several fields ported from nautilus below keep "weth"/"eth" in their
// names (wethIsToken0, volumeWeth, ethIsCurrency0, ETH_CURRENCIES-equivalent).
// There is no WETH or native ETH concept anywhere on Arc — the anchor asset in
// every one of those names is ARC_USDC. This is a deliberate port-time decision
// (see the plan's header note): renaming would touch a dozen already-tested
// files for zero functional benefit.

// Chain id 5042 (0x13b2), confirmed 2026-09-15 via three independent GitHub
// sources (viem chain definitions, ethereum-lists/chains, Uniswap's own
// UniswapX integration playbook). See docs/superpowers/specs/ for the full
// verification trail. No public RPC endpoint exists yet (mainnet opens
// 2026-09-16), so this has NO DEFAULT — index.ts refuses to start the loops
// without it, rather than silently pointing at nothing.
export const ARC_RPC_URL = process.env.ARC_RPC_URL ?? '';

// Optional second RPC endpoint, tried after ARC_RPC_URL exhausts its own
// retries — see rpc.ts's failover wrapper. Different providers have
// different limits: verified live 2026-09-16 that Blockdaemon's endpoint
// prunes eth_getLogs history beyond ~300k blocks back (any fromBlock older
// than that fails outright, not just slowly) while dRPC's free tier caps a
// single eth_getLogs call to a 10k-block range but has no pruning. Neither
// limitation is fixed by the other being present — this is redundancy against
// one provider being down or rate-limiting, not a router between them.
export const ARC_RPC_URL_FALLBACK = process.env.ARC_RPC_URL_FALLBACK ?? '';

// Parsed through a guard, not `parseInt(x ?? fallback)`: a Railway variable
// defined with a blank value is not undefined, so `??` never fires and
// `parseInt('')` is NaN. This exact hole shipped twice in nautilus
// (LP_GAS_RESERVE_ETH, LP_MIN_DEPOSIT_ETH) — every numeric constant below
// goes through this rather than a raw parseInt.
export function nonNegativeIntEnv(raw: string | undefined, fallback: number): number {
  if (raw === undefined || raw.trim() === '') return fallback;
  const n = parseInt(raw, 10);
  return Number.isFinite(n) && n >= 0 ? n : fallback;
}

// Per-request deadline for every JSON-RPC call — see rpc.ts for why this
// exists at all (fetch has no timeout of its own).
export const ARC_RPC_TIMEOUT_MS = nonNegativeIntEnv(process.env.ARC_RPC_TIMEOUT_MS, 30000);

// The 6-decimal ERC-20 interface predeploy over Arc's native USDC balance.
// Deliberately the ONLY USDC representation this project ever matches against
// — the native 18-decimal representation (address 0x0) is never matched, even
// though it is the same underlying balance. See the spec's "Key architectural
// decision" section: Uniswap's own Arc integration notes call mixing the two
// representations the #1 integration risk on this chain.
export const ARC_USDC = (
  process.env.ARC_USDC ?? '0x3600000000000000000000000000000000000000'
).toLowerCase();
export const ARC_USDC_DECIMALS = nonNegativeIntEnv(process.env.ARC_USDC_DECIMALS, 6);

export const TOP_N = nonNegativeIntEnv(process.env.MOVERS_TOP_N, 5);
export const POLL_SECONDS = nonNegativeIntEnv(process.env.MOVERS_POLL_SECONDS, 60);
export const MAX_LOOKBACK_BLOCKS = nonNegativeIntEnv(process.env.MOVERS_MAX_LOOKBACK_BLOCKS, 6000);

// --- Market-cap gate (both boards share one Danger Zone topic) ---
// The cap THRESHOLD itself is a strategy parameter — see src/strategy.ts.
export const MCAP_MAX_LOOKUPS = nonNegativeIntEnv(process.env.MOVERS_MCAP_MAX_LOOKUPS, 25);

// Candle width, RSI period/thresholds and the RSI volume floor are strategy
// parameters with no in-code defaults — see src/strategy.ts.

// keccak256 event signature (well-known Uniswap v3 constant, chain-agnostic).
export const SWAP_TOPIC0 =
  '0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67';

// eth_call 4-byte selectors (well-known ERC-20 / UniswapV3Pool constants).
export const SEL_SLOT0 = '0x3850c7bd'; // slot0()
export const SEL_SYMBOL = '0x95d89b41'; // symbol()
export const SEL_TOKEN0 = '0x0dfe1681'; // token0()
export const SEL_TOKEN1 = '0xd21220a7'; // token1()
export const SEL_FEE = '0xddca3f43'; // fee()

// --- Contract verification (Arcscan) ---
// Verified live 2026-09-16: api.arc-scan.org/v1/address/<address> returns a
// real `verified: boolean` field for both the USDC predeploy and an ordinary
// ERC-20. This is verification status ONLY — not the fuller heuristic risk
// scan (mint/blacklist/tax/proxy detection) nautilus's Robinhood-chain boards
// also do; that's a separate, much larger feature this does not attempt.
export const ARC_SCAN_API_BASE = (
  process.env.ARC_SCAN_API_BASE ?? 'https://api.arc-scan.org/v1'
).replace(/\/$/, '');
export const ARC_SCAN_TIMEOUT_MS = nonNegativeIntEnv(process.env.ARC_SCAN_TIMEOUT_MS, 10_000);
// How long a verification verdict is cached before re-checking. Long-lived —
// a contract's verification status essentially never reverts from true to
// false, and rarely flips false to true either, so this is mostly protecting
// against re-querying every unverified token every cycle forever.
export const ARC_SCAN_TTL_MS = nonNegativeIntEnv(
  process.env.MOVERS_VERIFICATION_TTL_MS,
  6 * 60 * 60 * 1000
);
