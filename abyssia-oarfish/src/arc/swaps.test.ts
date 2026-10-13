import { describe, it, expect } from 'vitest';
import { aggregateSwaps, feesToWeth, PoolMeta } from './swaps';
import { DecodedSwap } from './decode';

const POOL = '0xpool';
const TOKEN = '0xtoken';

function swap(partial: Partial<DecodedSwap>): DecodedSwap {
  return {
    sender: '0xsender',
    recipient: '0xr1',
    amount0: 0n,
    amount1: 0n,
    sqrtPriceX96: 0n,
    ...partial,
  };
}

describe('aggregateSwaps', () => {
  it('sums WETH-side volume, counts swaps and unique traders, computes fees', () => {
    // WETH is token1 (wethIsToken0 = false), fee tier 3000 (0.30%).
    const meta: PoolMeta = { pool: POOL, token: TOKEN, fee: 3000, wethIsToken0: false };
    const metaByPool = new Map([[POOL, meta]]);
    const decoded = [
      // swap A: token0 in (+1e6), WETH out (-2000). trader r1.
      { pool: POOL, swap: swap({ recipient: '0xr1', amount0: 1_000_000n, amount1: -2000n }) },
      // swap B: WETH in (+5000), token0 out (-1e6). trader r2.
      { pool: POOL, swap: swap({ recipient: '0xr2', amount0: -1_000_000n, amount1: 5000n }) },
      // swap C: same trader r1 again, WETH in (+1000).
      { pool: POOL, swap: swap({ recipient: '0xr1', amount0: -100n, amount1: 1000n }) },
    ];
    const agg = aggregateSwaps(decoded, metaByPool).get(POOL)!;
    expect(agg.volumeWeth).toBe(2000n + 5000n + 1000n); // |WETH side| each
    expect(agg.swaps).toBe(3);
    expect(agg.traders.size).toBe(2); // r1, r2
    // fees on the positive (input) side * 3000 / 1e6:
    // fees0: swap A amount0 1e6 -> 3000
    expect(agg.fees0).toBe((1_000_000n * 3000n) / 1_000_000n);
    // fees1: swap B 5000 -> 15 ; swap C 1000 -> 3  => 18
    expect(agg.fees1).toBe((5000n * 3000n) / 1_000_000n + (1000n * 3000n) / 1_000_000n);
  });

  it('skips swaps whose pool has no metadata', () => {
    const out = aggregateSwaps(
      [{ pool: '0xunknown', swap: swap({ amount0: 1n }) }],
      new Map()
    );
    expect(out.size).toBe(0);
  });
});

describe('aggregateSwaps lastSqrtPriceX96', () => {
  it('records the sqrtPriceX96 of the last swap for the pool', () => {
    const meta = new Map<string, PoolMeta>([
      ['0xp', { pool: '0xp', token: '0xt', fee: 3000, wethIsToken0: true }],
    ]);
    const decoded = [
      { pool: '0xp', swap: { sender: '0xa', recipient: '0xr1', amount0: 5n, amount1: -3n, sqrtPriceX96: 111n } },
      { pool: '0xp', swap: { sender: '0xb', recipient: '0xr2', amount0: -2n, amount1: 4n, sqrtPriceX96: 222n } },
    ];
    const agg = aggregateSwaps(decoded, meta).get('0xp')!;
    expect(agg.lastSqrtPriceX96).toBe(222n);
  });
});

describe('aggregateSwaps lastBlock', () => {
  it('records the block of the last swap for the pool', () => {
    const meta = new Map<string, PoolMeta>([
      ['0xp', { pool: '0xp', token: '0xt', fee: 3000, wethIsToken0: true }],
    ]);
    const decoded = [
      { pool: '0xp', swap: { sender: '0xa', recipient: '0xr1', amount0: 5n, amount1: -3n, sqrtPriceX96: 111n }, block: 100 },
      { pool: '0xp', swap: { sender: '0xb', recipient: '0xr2', amount0: -2n, amount1: 4n, sqrtPriceX96: 222n }, block: 200 },
    ];
    const agg = aggregateSwaps(decoded, meta).get('0xp')!;
    expect(agg.lastBlock).toBe(200);
  });
});

describe('feesToWeth', () => {
  const Q96 = 1n << 96n; // sqrtPriceX96 for price = 1

  it('at price 1, values the other-token fees 1:1', () => {
    // WETH token1: feesWeth = fees1 + fees0*price(=1)
    expect(feesToWeth(100n, 50n, Q96, false)).toBe(150n);
    // WETH token0: feesWeth = fees0 + fees1*(1/price)(=1)
    expect(feesToWeth(100n, 50n, Q96, true)).toBe(150n);
  });

  it('handles zero price safely', () => {
    expect(feesToWeth(100n, 50n, 0n, true)).toBe(100n); // token1 fees unvaluable -> dropped
  });
});
