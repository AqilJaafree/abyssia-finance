import { describe, it, expect } from 'vitest';
import { computeRSI } from './rsi';

// Test fixture only — not the deployed strategy value.
const PERIOD = 5;

describe('computeRSI', () => {
  it('returns 50 when buffer has fewer than period + 1 prices', () => {
    const prices = Array.from({ length: PERIOD }, (_, i) => 100 + i);
    expect(computeRSI(prices, PERIOD)).toBe(50);
  });

  it('returns 0 when all periods are losses', () => {
    const prices = Array.from({ length: PERIOD + 2 }, (_, i) => 100 - i);
    expect(computeRSI(prices, PERIOD)).toBe(0);
  });

  it('returns 100 when all periods are gains', () => {
    const prices = Array.from({ length: PERIOD + 2 }, (_, i) => 85 + i);
    expect(computeRSI(prices, PERIOD)).toBe(100);
  });

  it('returns ~50 for alternating gains and losses of equal size', () => {
    const prices = Array.from({ length: 16 }, (_, i) => 100 + (i % 2));
    const rsi = computeRSI(prices, PERIOD);
    expect(rsi).toBeGreaterThan(40);
    expect(rsi).toBeLessThan(60);
  });
});
