import { describe, it, expect } from 'vitest';
import { rsiForSeries, rsiMinSamples } from './rsi-tag';
import { RsiStrategy } from '../strategy';

// Test fixture only — not the deployed strategy values.
const CFG: RsiStrategy = { period: 5, oversold: 25, overbought: 75 };

describe('rsiForSeries', () => {
  it('needs period + 1 samples', () => {
    expect(rsiMinSamples(CFG)).toBe(CFG.period + 1);
  });

  it('returns undefined below the minimum sample count', () => {
    const series = Array.from({ length: rsiMinSamples(CFG) - 1 }, (_, i) => i);
    expect(rsiForSeries(series, CFG)).toBeUndefined();
  });

  it('flags a strictly rising series as overbought (RSI 100)', () => {
    const series = Array.from({ length: 20 }, (_, i) => 100 + i);
    const tag = rsiForSeries(series, CFG)!;
    expect(tag.rsi).toBeCloseTo(100, 6);
    expect(tag.label).toBe('overbought');
  });

  it('flags a strictly falling series as oversold (RSI 0)', () => {
    const series = Array.from({ length: 20 }, (_, i) => 100 - i);
    const tag = rsiForSeries(series, CFG)!;
    expect(tag.rsi).toBeCloseTo(0, 6);
    expect(tag.label).toBe('oversold');
  });

  it('leaves an oscillating series neutral (no label)', () => {
    const series = Array.from({ length: 20 }, (_, i) => 100 + (i % 2));
    const tag = rsiForSeries(series, CFG)!;
    expect(tag.rsi).toBeGreaterThan(CFG.oversold);
    expect(tag.rsi).toBeLessThan(CFG.overbought);
    expect(tag.label).toBeUndefined();
  });

  it('labels strictly against the configured thresholds', () => {
    const series = Array.from({ length: 20 }, (_, i) => 100 + (i % 2));
    const rsi = rsiForSeries(series, CFG)!.rsi;
    expect(rsiForSeries(series, { ...CFG, overbought: rsi - 1 })!.label).toBe('overbought');
    expect(rsiForSeries(series, { ...CFG, oversold: rsi + 1 })!.label).toBe('oversold');
    expect(rsiForSeries(series, { ...CFG, oversold: rsi, overbought: rsi + 1 })!.label).toBeUndefined();
  });

  it('treats a completely flat series as neutral, not overbought', () => {
    const series = Array.from({ length: 20 }, () => 42);
    const tag = rsiForSeries(series, CFG)!;
    expect(tag.rsi).toBe(50);
    expect(tag.label).toBeUndefined();
  });

  it('returns an integer RSI (rounded) so display and label agree', () => {
    const series = Array.from({ length: 20 }, (_, i) => 100 + (i % 2));
    const tag = rsiForSeries(series, CFG)!;
    expect(Number.isInteger(tag.rsi)).toBe(true);
  });
});
