import { describe, it, expect } from 'vitest';
import { rankTopN } from './leaderboard';
import { PoolAggregate } from './swaps';

function agg(pool: string, volumeWeth: bigint, traders: string[]): PoolAggregate {
  return {
    pool,
    token: pool + '-tok',
    volumeWeth,
    swaps: traders.length,
    traders: new Set(traders),
    fees0: 0n,
    fees1: 0n,
    lastSqrtPriceX96: 0n,
    lastBlock: 0,
  };
}

describe('rankTopN', () => {
  it('sorts by WETH volume desc and truncates to N', () => {
    const map = new Map<string, PoolAggregate>([
      ['a', agg('a', 30n, ['x'])],
      ['b', agg('b', 100n, ['x', 'y'])],
      ['c', agg('c', 5n, ['x'])],
      ['d', agg('d', 50n, ['x'])],
    ]);
    const top = rankTopN(map, 2);
    expect(top.map((r) => r.pool)).toEqual(['b', 'd']);
    expect(top[0].volumeWeth).toBe(100n);
    expect(top[0].traders).toBe(2); // Set size -> number
  });

  it('returns fewer than N when there are fewer pools', () => {
    const map = new Map([['a', agg('a', 1n, ['x'])]]);
    expect(rankTopN(map, 5)).toHaveLength(1);
  });
});
