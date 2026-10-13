import { logger } from '../logger';
import { wordAt } from './decode';
import { sqrtPriceToSeriesValue } from './price';

// totalSupply() / decimals()
const SEL_TOTAL_SUPPLY = '0x18160ddd';
const SEL_DECIMALS = '0x313ce567';

// decimals() is immutable, but totalSupply() is NOT — a mintable token's supply
// changes, and a mint is exactly the event that should move its market cap. So the
// pair is re-read on a TTL rather than cached forever.
export const SUPPLY_TTL_MS = parseInt(
  process.env.MOVERS_SUPPLY_TTL_MS ?? String(60 * 60 * 1000),
  10
);

// bigint does not survive JSON, so the persisted cache holds supply as a string.
export interface TokenMeta { supply: string; decimals: number }

export type Caller = (to: string, data: string) => Promise<string>;

export interface FdvInputs {
  supply: bigint;
  tokenDecimals: number;
  sqrtPriceX96: bigint;
  tokenIsToken0: boolean;   // is the tracked token currency0 of the pool?
  anchorDecimals: number;   // 18 for WETH/native ETH, 6 for USDG
  anchorUsd: number;        // 1 on the USDG boards, live ETH/USD on the ETH boards
}

export interface SeriesFdvInputs {
  seriesValue: number;      // quote-per-token price, as returned by sqrtPriceToSeriesValue
  supply: bigint;
  tokenDecimals: number;
  anchorDecimals: number;   // 18 for WETH/native ETH, 6 for USDG
  anchorUsd: number;        // 1 on the USDG boards, live ETH/USD on the ETH boards
}

// The FDV formula itself, taking a series value (the quote-per-token price
// sqrtPriceToSeriesValue derives from a pool's sqrtPriceX96 — see price.ts) rather
// than the sqrtPriceX96 itself.
//
// Split out so the LP candidate gate can reuse it: the movers state persists each pool's
// close as an ALREADY-CONVERTED series value, not the sqrtPriceX96 it came from, and a
// second hand-rolled copy of this arithmetic on the money path is exactly the kind of
// drift that lets the two gates disagree about the same token.
//
// Named-field input rather than positional: tokenDecimals and anchorDecimals sit
// side by side with the same type, and a transposed pair scales the result by
// 10^(2x the decimal gap) — often not extreme enough to trip the finite/positive
// guard below, so a bad call could silently wave a sub-threshold token through.
export function fdvFromSeriesValue(i: SeriesFdvInputs): number | undefined {
  if (i.supply <= 0n || !(i.anchorUsd > 0) || !(i.seriesValue > 0)) return undefined;
  // Scale-free ratio in the token's favour, then correct for the decimal gap
  // between the two sides: raw amounts are in base units, humans price whole tokens.
  const priceAnchor = i.seriesValue * 10 ** (i.tokenDecimals - i.anchorDecimals);
  const wholeSupply = Number(i.supply) / 10 ** i.tokenDecimals;
  const fdv = wholeSupply * priceAnchor * i.anchorUsd;
  // An overflow or a degenerate pool can produce Infinity/NaN. Never let that reach
  // the threshold comparison, where every comparison against NaN is false and the
  // row would silently fall through with a garbage figure rendered.
  return Number.isFinite(fdv) && fdv > 0 ? fdv : undefined;
}

// Fully-diluted valuation in USD, computed from the pool the token actually trades
// in. Returns undefined for any input that cannot produce a meaningful number, so
// callers get the same "unknown" signal they already fail-safe on.
export function computeFdvUsd(i: FdvInputs): number | undefined {
  if (i.sqrtPriceX96 <= 0n) return undefined;
  return fdvFromSeriesValue({
    seriesValue: sqrtPriceToSeriesValue(i.sqrtPriceX96, i.tokenIsToken0),
    supply: i.supply,
    tokenDecimals: i.tokenDecimals,
    anchorDecimals: i.anchorDecimals,
    anchorUsd: i.anchorUsd,
  });
}

// Read a token's supply and decimals, cache-first. Transient failures return
// undefined WITHOUT caching so the next cycle retries.
export async function resolveTokenMeta(
  token: string,
  cache: Record<string, TokenMeta>,
  checkedAt: Record<string, number>,
  call: Caller,
  now: number = Date.now()
): Promise<{ supply: bigint; decimals: number } | undefined> {
  const hit = cache[token];
  if (hit && now - (checkedAt[token] ?? 0) < SUPPLY_TTL_MS) {
    return { supply: BigInt(hit.supply), decimals: hit.decimals };
  }
  try {
    const supplyRaw = await call(token, SEL_TOTAL_SUPPLY);
    const decRaw = await call(token, SEL_DECIMALS);
    // wordAt returns 0n for a short/empty response, which for decimals is
    // indistinguishable from a real 0-decimal token — so reject the empty case
    // outright rather than silently pricing the token 1e18x wrong.
    if (!supplyRaw || supplyRaw.length < 66 || !decRaw || decRaw.length < 66) return undefined;
    const supply = wordAt(supplyRaw, 0);
    const decimals = Number(wordAt(decRaw, 0));
    if (decimals > 36) return undefined; // not a plausible ERC20
    cache[token] = { supply: supply.toString(), decimals };
    checkedAt[token] = now;
    return { supply, decimals };
  } catch (err) {
    logger.warn({ err, token }, 'movers: token supply/decimals read failed');
    return undefined;
  }
}
