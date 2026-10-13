import { describe, it, expect, vi } from 'vitest';
import { resolvePoolMeta } from './metadata';
import { PoolMeta } from './swaps';
import { SEL_TOKEN0, SEL_TOKEN1, SEL_FEE, ARC_USDC } from './config';

const TOKEN = '0x1111111111111111111111111111111111111111';
const POOL = '0xpool';

// eth_call returns a 32-byte word; encode an address in the low 20 bytes.
function addrWord(a: string): string {
  return '0x' + a.slice(2).toLowerCase().padStart(64, '0');
}
function u24Word(n: number): string {
  return '0x' + n.toString(16).padStart(64, '0');
}

describe('resolvePoolMeta', () => {
  it('returns a cached value without calling', async () => {
    const cache: Record<string, PoolMeta | null> = {
      [POOL]: { pool: POOL, token: TOKEN, fee: 3000, wethIsToken0: false },
    };
    const call = vi.fn();
    const meta = await resolvePoolMeta(POOL, cache, call);
    expect(meta).toEqual(cache[POOL]);
    expect(call).not.toHaveBeenCalled();
  });

  it('returns a cached null (known non-USDC) without calling', async () => {
    const cache: Record<string, PoolMeta | null> = { [POOL]: null };
    const call = vi.fn();
    expect(await resolvePoolMeta(POOL, cache, call)).toBeNull();
    expect(call).not.toHaveBeenCalled();
  });

  it('resolves USDC-as-token1 and caches PoolMeta', async () => {
    const cache: Record<string, PoolMeta | null> = {};
    const call = vi.fn(async (_to: string, data: string) => {
      if (data === SEL_TOKEN0) return addrWord(TOKEN);
      if (data === SEL_TOKEN1) return addrWord(ARC_USDC);
      if (data === SEL_FEE) return u24Word(500);
      throw new Error('unexpected');
    });
    const meta = await resolvePoolMeta(POOL, cache, call);
    expect(meta).toEqual({ pool: POOL, token: TOKEN, fee: 500, wethIsToken0: false });
    expect(cache[POOL]).toEqual(meta);
  });

  it('resolves USDC-as-token0', async () => {
    const cache: Record<string, PoolMeta | null> = {};
    const call = vi.fn(async (_to: string, data: string) => {
      if (data === SEL_TOKEN0) return addrWord(ARC_USDC);
      if (data === SEL_TOKEN1) return addrWord(TOKEN);
      if (data === SEL_FEE) return u24Word(3000);
      throw new Error('unexpected');
    });
    const meta = await resolvePoolMeta(POOL, cache, call);
    expect(meta).toEqual({ pool: POOL, token: TOKEN, fee: 3000, wethIsToken0: true });
  });

  it('caches null for a confirmed non-USDC pool (no fee() call)', async () => {
    const cache: Record<string, PoolMeta | null> = {};
    const call = vi.fn(async (_to: string, data: string) => {
      if (data === SEL_TOKEN0) return addrWord(TOKEN);
      if (data === SEL_TOKEN1) return addrWord('0x2222222222222222222222222222222222222222');
      throw new Error('fee() should not be called');
    });
    expect(await resolvePoolMeta(POOL, cache, call)).toBeNull();
    expect(POOL in cache).toBe(true);
    expect(cache[POOL]).toBeNull();
  });

  it('returns null WITHOUT caching on a transient RPC error', async () => {
    const cache: Record<string, PoolMeta | null> = {};
    const call = vi.fn(async () => {
      throw new Error('HTTP 429');
    });
    expect(await resolvePoolMeta(POOL, cache, call)).toBeNull();
    expect(POOL in cache).toBe(false); // not cached -> retried next cycle
  });

  // The USDG board reuses this resolver with a custom anchor (4th arg).
  const USDG = '0x5fc5360d0400a0fd4f2af552add042d716f1d168';

  it('filters on a custom anchor: keeps USDG pools, sets anchor-is-token0', async () => {
    const cache: Record<string, PoolMeta | null> = {};
    const call = vi.fn(async (_to: string, data: string) => {
      if (data === SEL_TOKEN0) return addrWord(USDG);
      if (data === SEL_TOKEN1) return addrWord(TOKEN);
      if (data === SEL_FEE) return u24Word(3000);
      throw new Error('unexpected');
    });
    const meta = await resolvePoolMeta(POOL, cache, call, USDG);
    // wethIsToken0 here means "anchor (USDG) is token0" — true.
    expect(meta).toEqual({ pool: POOL, token: TOKEN, fee: 3000, wethIsToken0: true });
  });

  it('caches null for a pool that lacks the custom anchor (USDC pool under USDG anchor)', async () => {
    const cache: Record<string, PoolMeta | null> = {};
    const call = vi.fn(async (_to: string, data: string) => {
      if (data === SEL_TOKEN0) return addrWord(ARC_USDC);
      if (data === SEL_TOKEN1) return addrWord(TOKEN);
      throw new Error('fee() should not be called');
    });
    expect(await resolvePoolMeta(POOL, cache, call, USDG)).toBeNull();
    expect(cache[POOL]).toBeNull();
  });
});
