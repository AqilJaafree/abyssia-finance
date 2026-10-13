import { describe, it, expect } from 'vitest';
import { aggregateV4Swaps, rankV4TopN } from './swaps';
import { V4PoolMeta } from './metadata';
import { DecodedV4Swap } from './decode';

const POOL_A = '0x' + 'aa'.repeat(32);
const POOL_B = '0x' + 'bb'.repeat(32);
const TOKEN_A = '0x' + '11'.repeat(20);
const TOKEN_B = '0x' + '22'.repeat(20);

function swap(over: Partial<DecodedV4Swap>): DecodedV4Swap {
  return {
    poolId: POOL_A,
    sender: '0x' + 'ee'.repeat(20),
    amount0: 0n,
    amount1: 0n,
    sqrtPriceX96: 0n,
    fee: 3000n,
    ...over,
  };
}

describe('aggregateV4Swaps', () => {
  it('uses the ETH leg for volume, dedupes traders, and values fees from the event', () => {
    const metaById = new Map<string, V4PoolMeta>([
      [POOL_A, { poolId: POOL_A, token: TOKEN_A, ethIsCurrency0: true, fee: 3000 }],
    ]);
    const decoded = [
      // ETH is currency0 → use amount0. Two swaps, same sender → 1 trader.
      { poolId: POOL_A, swap: swap({ amount0: -1_000_000_000n, amount1: 5n, sender: '0xabc', fee: 3000n }) },
      { poolId: POOL_A, swap: swap({ amount0: 2_000_000_000n, amount1: -9n, sender: '0xabc', fee: 3000n }) },
    ];
    const agg = aggregateV4Swaps(decoded, metaById);
    const a = agg.get(POOL_A)!;
    expect(a.volumeEth).toBe(3_000_000_000n); // |−1e9| + |2e9|
    expect(a.swaps).toBe(2);
    expect(a.traders.size).toBe(1);
    // fees = (1e9 * 3000/1e6) + (2e9 * 3000/1e6) = 3e6 + 6e6
    expect(a.feesEth).toBe(9_000_000n);
  });

  it('skips pools with no resolved (ETH) metadata', () => {
    const decoded = [{ poolId: POOL_B, swap: swap({ poolId: POOL_B, amount0: 1n }) }];
    expect(aggregateV4Swaps(decoded, new Map()).size).toBe(0);
  });

  it('ignores the dynamic-fee flag so it cannot inflate fees', () => {
    const metaById = new Map<string, V4PoolMeta>([
      [POOL_A, { poolId: POOL_A, token: TOKEN_A, ethIsCurrency0: false, fee: 3000 }],
    ]);
    const decoded = [{ poolId: POOL_A, swap: swap({ amount1: 1_000_000n, fee: 0x800000n }) }];
    const a = aggregateV4Swaps(decoded, metaById).get(POOL_A)!;
    expect(a.volumeEth).toBe(1_000_000n);
    expect(a.feesEth).toBe(0n); // 0x800000 > 1e6 → not counted
  });
});

describe('aggregateV4Swaps lastSqrtPriceX96', () => {
  it('records the sqrtPriceX96 of the last swap for the pool', () => {
    const meta = new Map<string, V4PoolMeta>([
      ['0xpid', { poolId: '0xpid', token: '0xt', fee: 3000, ethIsCurrency0: true } as V4PoolMeta],
    ]);
    const decoded = [
      { poolId: '0xpid', swap: { poolId: '0xpid', sender: '0xa', amount0: 5n, amount1: -3n, sqrtPriceX96: 111n, fee: 3000n } },
      { poolId: '0xpid', swap: { poolId: '0xpid', sender: '0xb', amount0: -2n, amount1: 4n, sqrtPriceX96: 222n, fee: 3000n } },
    ];
    const agg = aggregateV4Swaps(decoded, meta).get('0xpid')!;
    expect(agg.lastSqrtPriceX96).toBe(222n);
  });
});

describe('aggregateV4Swaps lastBlock', () => {
  it('records the block of the last swap for the pool', () => {
    const meta = new Map<string, V4PoolMeta>([
      ['0xpid', { poolId: '0xpid', token: '0xt', fee: 3000, ethIsCurrency0: true } as V4PoolMeta],
    ]);
    const decoded = [
      { poolId: '0xpid', swap: { poolId: '0xpid', sender: '0xa', amount0: 5n, amount1: -3n, sqrtPriceX96: 111n, fee: 3000n }, block: 100 },
      { poolId: '0xpid', swap: { poolId: '0xpid', sender: '0xb', amount0: -2n, amount1: 4n, sqrtPriceX96: 222n, fee: 3000n }, block: 200 },
    ];
    const agg = aggregateV4Swaps(decoded, meta).get('0xpid')!;
    expect(agg.lastBlock).toBe(200);
  });
});

describe('rankV4TopN', () => {
  it('ranks by ETH volume desc and truncates to N', () => {
    const metaById = new Map<string, V4PoolMeta>([
      [POOL_A, { poolId: POOL_A, token: TOKEN_A, ethIsCurrency0: true, fee: 3000 }],
      [POOL_B, { poolId: POOL_B, token: TOKEN_B, ethIsCurrency0: true, fee: 3000 }],
    ]);
    const decoded = [
      { poolId: POOL_A, swap: swap({ amount0: 5n }) },
      { poolId: POOL_B, swap: swap({ poolId: POOL_B, amount0: 100n }) },
    ];
    const ranked = rankV4TopN(aggregateV4Swaps(decoded, metaById), 1);
    expect(ranked).toHaveLength(1);
    expect(ranked[0].poolId).toBe(POOL_B);
    expect(ranked[0].volumeEth).toBe(100n);
  });
});
