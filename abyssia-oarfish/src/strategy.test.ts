import { describe, it, expect } from 'vitest';
import { loadStrategy, STRATEGY_ENV_KEYS } from './strategy';

// Test fixtures only — not the deployed strategy values.
const VALID = {
  STRATEGY_RSI_PERIOD: '5',
  STRATEGY_RSI_OVERSOLD: '25',
  STRATEGY_RSI_OVERBOUGHT: '75',
  STRATEGY_BLOCKS_PER_CANDLE: '100',
  STRATEGY_MAX_CLOSES: '12',
  STRATEGY_MIN_MARKET_CAP_USD: '50000',
  STRATEGY_RSI_MIN_VOLUME_USDC: '0',
};

describe('loadStrategy', () => {
  it('parses a complete, valid env', () => {
    const r = loadStrategy(VALID);
    expect(r).toEqual({
      ok: true,
      strategy: {
        rsi: { period: 5, oversold: 25, overbought: 75 },
        blocksPerCandle: 100,
        maxCloses: 12,
        minMarketCapUsd: 50000,
        rsiMinVolumeUsdc: 0n,
      },
    });
  });

  it('has no in-code defaults: an empty env reports every key', () => {
    const r = loadStrategy({});
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.invalid.sort()).toEqual([...STRATEGY_ENV_KEYS].sort());
  });

  it('treats a blank (cleared Railway field) value as missing', () => {
    const r = loadStrategy({ ...VALID, STRATEGY_RSI_PERIOD: '  ' });
    expect(r).toEqual({ ok: false, invalid: ['STRATEGY_RSI_PERIOD'] });
  });

  it('rejects malformed and out-of-range values', () => {
    expect(loadStrategy({ ...VALID, STRATEGY_RSI_PERIOD: '2.5' }).ok).toBe(false);
    expect(loadStrategy({ ...VALID, STRATEGY_RSI_OVERBOUGHT: '101' }).ok).toBe(false);
    expect(loadStrategy({ ...VALID, STRATEGY_BLOCKS_PER_CANDLE: '0' }).ok).toBe(false);
    expect(loadStrategy({ ...VALID, STRATEGY_MIN_MARKET_CAP_USD: 'abc' }).ok).toBe(false);
    expect(loadStrategy({ ...VALID, STRATEGY_RSI_MIN_VOLUME_USDC: '-1' }).ok).toBe(false);
  });

  it('rejects inverted RSI thresholds', () => {
    const r = loadStrategy({ ...VALID, STRATEGY_RSI_OVERSOLD: '80', STRATEGY_RSI_OVERBOUGHT: '20' });
    expect(r).toEqual({ ok: false, invalid: ['STRATEGY_RSI_OVERSOLD', 'STRATEGY_RSI_OVERBOUGHT'] });
  });

  it('rejects a history cap too short to ever compute RSI', () => {
    const r = loadStrategy({ ...VALID, STRATEGY_MAX_CLOSES: '4' });
    expect(r).toEqual({ ok: false, invalid: ['STRATEGY_MAX_CLOSES'] });
  });

  it('never echoes a value in its result — only key names', () => {
    const r = loadStrategy({ ...VALID, STRATEGY_MIN_MARKET_CAP_USD: 'secret-123' });
    expect(JSON.stringify(r)).not.toContain('secret-123');
  });
});
