import { describe, it, expect } from 'vitest';
import { recordSwapPrice, MAX_TRACKED_POOLS, CandleState } from './candles';

// Test fixture only — not the deployed strategy value.
const MAX_CLOSES = 12;

describe('recordSwapPrice', () => {
  it('initializes a new pool with an empty closes array', () => {
    const s: Record<string, CandleState> = {};
    recordSwapPrice(s, 'p', 10, 1.5, MAX_CLOSES);
    expect(s['p']).toEqual({ bucket: 10, close: 1.5, closes: [] });
  });

  it('updates the forming candle close within the same bucket', () => {
    const s: Record<string, CandleState> = {};
    recordSwapPrice(s, 'p', 10, 1.5, MAX_CLOSES);
    recordSwapPrice(s, 'p', 10, 1.8, MAX_CLOSES);
    expect(s['p'].close).toBe(1.8);
    expect(s['p'].closes).toEqual([]);
  });

  it('finalizes the forming candle when the bucket advances by one', () => {
    const s: Record<string, CandleState> = {};
    recordSwapPrice(s, 'p', 10, 1.5, MAX_CLOSES);
    recordSwapPrice(s, 'p', 11, 2.0, MAX_CLOSES);
    expect(s['p'].closes).toEqual([1.5]);
    expect(s['p'].bucket).toBe(11);
    expect(s['p'].close).toBe(2.0);
  });

  it('forward-fills skipped buckets with the last close (uniform spacing)', () => {
    const s: Record<string, CandleState> = {};
    recordSwapPrice(s, 'p', 10, 1.5, MAX_CLOSES);
    recordSwapPrice(s, 'p', 13, 2.0, MAX_CLOSES); // buckets 11, 12 had no swaps
    expect(s['p'].closes).toEqual([1.5, 1.5, 1.5]); // finalize 10 + fill 11,12
    expect(s['p'].bucket).toBe(13);
    expect(s['p'].close).toBe(2.0);
  });

  it('ignores an out-of-order (older) bucket', () => {
    const s: Record<string, CandleState> = {};
    recordSwapPrice(s, 'p', 11, 2.0, MAX_CLOSES);
    recordSwapPrice(s, 'p', 10, 1.5, MAX_CLOSES); // stale / reorg
    expect(s['p'].bucket).toBe(11);
    expect(s['p'].close).toBe(2.0);
    expect(s['p'].closes).toEqual([]);
  });

  it('is idempotent for a repeated (bucket, price) in the same bucket', () => {
    const s: Record<string, CandleState> = {};
    recordSwapPrice(s, 'p', 10, 1.5, MAX_CLOSES);
    recordSwapPrice(s, 'p', 10, 1.5, MAX_CLOSES);
    recordSwapPrice(s, 'p', 10, 1.5, MAX_CLOSES);
    expect(s['p'].closes).toEqual([]);
    expect(s['p'].close).toBe(1.5);
  });

  it('caps closes at MAX_CLOSES across a huge bucket jump', () => {
    const s: Record<string, CandleState> = {};
    recordSwapPrice(s, 'p', 0, 1, MAX_CLOSES);
    recordSwapPrice(s, 'p', MAX_CLOSES + 100, 2, MAX_CLOSES);
    expect(s['p'].closes.length).toBe(MAX_CLOSES);
    expect(s['p'].bucket).toBe(MAX_CLOSES + 100);
  });

  it('evicts the least-recently-updated pool past MAX_TRACKED_POOLS', () => {
    const s: Record<string, CandleState> = {};
    for (let i = 0; i <= MAX_TRACKED_POOLS; i++) recordSwapPrice(s, `k${i}`, 1, 1, MAX_CLOSES);
    expect(Object.keys(s).length).toBe(MAX_TRACKED_POOLS);
    expect(s['k0']).toBeUndefined();
    expect(s[`k${MAX_TRACKED_POOLS}`]).toBeDefined();
  });
});
