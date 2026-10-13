import { logger } from '../logger';
import { ARC_SCAN_API_BASE, ARC_SCAN_TIMEOUT_MS, ARC_SCAN_TTL_MS } from './config';

export interface VerificationResult {
  verified: boolean;
  // Arcscan's own token-standard classification, taken from the SAME response
  // as `verified` (no second request). A ✅ badge folds this in — a "verified"
  // contract that Arcscan itself can't classify as standard.erc20 is not a
  // clean signal to show as a plain checkmark.
  isErc20: boolean;
  // True if Arcscan flags this token as an unverified lookalike OR as
  // sharing a reserved name (e.g. squatting "USDC"/"WETH") — a scam-token
  // signal distinct from, and worse than, plain unverified.
  lookalike: boolean;
}

// Injectable so tests never hit the real network — see resolveVerification's
// default, which is the one production caller actually uses.
export type Fetcher = (url: string) => Promise<{ ok: boolean; json: () => Promise<unknown> }>;

async function defaultFetch(url: string): Promise<{ ok: boolean; json: () => Promise<unknown> }> {
  const res = await fetch(url, { signal: AbortSignal.timeout(ARC_SCAN_TIMEOUT_MS) });
  return { ok: res.ok, json: () => res.json() };
}

interface AddressResponse {
  verified?: unknown;
  token?: {
    standard?: unknown;
    unverified_lookalike?: unknown;
    shares_reserved_name?: unknown;
  };
}

// Resolve a token's verification + standard + lookalike status from
// Arcscan's address endpoint, cache-first with a long TTL (verification
// essentially never flips back to false, and rarely flips to true — no need
// to re-check every cycle). Returns undefined on any failure (bad status,
// malformed body, network error) WITHOUT caching, so the next cycle retries
// rather than rendering a wrong badge.
export async function resolveVerification(
  token: string,
  cache: Record<string, VerificationResult>,
  checkedAt: Record<string, number>,
  now: number = Date.now(),
  fetchFn: Fetcher = defaultFetch
): Promise<VerificationResult | undefined> {
  const hit = cache[token];
  if (hit && now - (checkedAt[token] ?? 0) < ARC_SCAN_TTL_MS) return hit;
  try {
    const res = await fetchFn(`${ARC_SCAN_API_BASE}/address/${token}`);
    if (!res.ok) return undefined;
    const body = (await res.json()) as AddressResponse;
    if (typeof body.verified !== 'boolean') return undefined;
    const result: VerificationResult = {
      verified: body.verified,
      isErc20: body.token?.standard === 'erc20',
      lookalike: body.token?.unverified_lookalike === true || body.token?.shares_reserved_name === true,
    };
    cache[token] = result;
    checkedAt[token] = now;
    return result;
  } catch (err) {
    logger.warn({ err, token }, 'movers: verification lookup failed');
    return undefined;
  }
}
