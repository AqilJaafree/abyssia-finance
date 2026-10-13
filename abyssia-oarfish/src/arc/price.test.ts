import { describe, it, expect } from 'vitest';
import { sqrtPriceToSeriesValue } from './price';

const Q96 = 2n ** 96n;

describe('sqrtPriceToSeriesValue', () => {
  it('returns 1 for a 1:1 sqrtPriceX96 regardless of orientation', () => {
    expect(sqrtPriceToSeriesValue(Q96, true)).toBeCloseTo(1, 9);
    expect(sqrtPriceToSeriesValue(Q96, false)).toBeCloseTo(1, 9);
  });

  it('when token is token0, price = (sqrtP/2^96)^2', () => {
    expect(sqrtPriceToSeriesValue(2n * Q96, true)).toBeCloseTo(4, 6);
  });

  it('when token is token1, price is the reciprocal ratio', () => {
    expect(sqrtPriceToSeriesValue(2n * Q96, false)).toBeCloseTo(0.25, 6);
  });
});
