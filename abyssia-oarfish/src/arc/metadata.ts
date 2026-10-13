import { PoolMeta } from './swaps';
import { addressAt, wordAt } from './decode';
import { ARC_USDC, SEL_TOKEN0, SEL_TOKEN1, SEL_FEE } from './config';

export type Caller = (to: string, data: string) => Promise<string>;

// Resolve a pool's anchor-paired metadata, cache-first. Caches `null` for pools
// that don't contain the anchor token so they aren't re-resolved. On a transient
// RPC error, returns `null` WITHOUT caching, so the next cycle retries.
//
// `anchor` defaults to ARC_USDC. NOTE: the returned `PoolMeta.wethIsToken0`
// field means "anchor is token0" — the name is inherited from the ported
// nautilus code (see src/arc/config.ts's naming note); the value is correct.
export async function resolvePoolMeta(
  pool: string,
  cache: Record<string, PoolMeta | null>,
  call: Caller,
  anchor: string = ARC_USDC
): Promise<PoolMeta | null> {
  if (pool in cache) return cache[pool];
  try {
    const token0 = addressAt(await call(pool, SEL_TOKEN0), 0);
    const token1 = addressAt(await call(pool, SEL_TOKEN1), 0);
    if (token0 !== anchor && token1 !== anchor) {
      cache[pool] = null; // confirmed no-anchor pool — cache the negative
      return null;
    }
    const wethIsToken0 = token0 === anchor;
    const fee = Number(wordAt(await call(pool, SEL_FEE), 0));
    const meta: PoolMeta = {
      pool,
      token: wethIsToken0 ? token1 : token0,
      fee,
      wethIsToken0,
    };
    cache[pool] = meta;
    return meta;
  } catch {
    return null; // transient — do not cache, retry next cycle
  }
}
