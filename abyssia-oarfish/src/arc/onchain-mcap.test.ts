import { describe, it, expect, vi, beforeEach } from 'vitest';
import { computeFdvUsd, fdvFromSeriesValue, resolveTokenMeta, SUPPLY_TTL_MS, TokenMeta } from './onchain-mcap';
import { sqrtPriceToSeriesValue } from './price';

// A 1e9-supply, 18-decimal token paired with WETH at a price giving a known FDV.
const Q96 = 2n ** 96n;

describe('computeFdvUsd', () => {
  it('computes FDV for a token that is token0 against an 18-decimal anchor', () => {
    // ratio = 1e-6 WETH per token (raw, equal decimals) -> price 1e-6 ETH
    // sqrt(1e-6) * 2^96
    const sqrt = BigInt(Math.floor(Math.sqrt(1e-6) * Number(Q96)));
    const fdv = computeFdvUsd({
      supply: 10n ** 27n,         // 1e9 tokens at 18dp
      tokenDecimals: 18,
      sqrtPriceX96: sqrt,
      tokenIsToken0: true,
      anchorDecimals: 18,
      anchorUsd: 2000,
    });
    // 1e9 tokens * 1e-6 ETH * $2000 = $2,000,000
    expect(fdv).toBeGreaterThan(1_900_000);
    expect(fdv).toBeLessThan(2_100_000);
  });

  it('inverts the ratio when the token is token1', () => {
    const sqrt = BigInt(Math.floor(Math.sqrt(1e6) * Number(Q96)));
    const fdv = computeFdvUsd({
      supply: 10n ** 27n, tokenDecimals: 18, sqrtPriceX96: sqrt,
      tokenIsToken0: false, anchorDecimals: 18, anchorUsd: 2000,
    });
    expect(fdv).toBeGreaterThan(1_900_000);
    expect(fdv).toBeLessThan(2_100_000);
  });

  it('handles a 6-decimal anchor (USDG boards) with anchorUsd 1', () => {
    // token 18dp is token0, USDG 6dp is token1. raw ratio r maps to price r*1e12.
    const sqrt = BigInt(Math.floor(Math.sqrt(1e-12) * Number(Q96)));
    const fdv = computeFdvUsd({
      supply: 10n ** 27n, tokenDecimals: 18, sqrtPriceX96: sqrt,
      tokenIsToken0: true, anchorDecimals: 6, anchorUsd: 1,
    });
    // price = 1e-12 * 10^(18-6) = 1.0 USDG per token; 1e9 tokens -> $1e9
    expect(fdv).toBeGreaterThan(9e8);
    expect(fdv).toBeLessThan(1.1e9);
  });

  it('returns undefined for a zero or missing price', () => {
    expect(computeFdvUsd({ supply: 10n ** 27n, tokenDecimals: 18, sqrtPriceX96: 0n,
      tokenIsToken0: true, anchorDecimals: 18, anchorUsd: 2000 })).toBeUndefined();
  });

  it('returns undefined for zero supply', () => {
    const sqrt = BigInt(Math.floor(Math.sqrt(1e-6) * Number(Q96)));
    expect(computeFdvUsd({ supply: 0n, tokenDecimals: 18, sqrtPriceX96: sqrt,
      tokenIsToken0: true, anchorDecimals: 18, anchorUsd: 2000 })).toBeUndefined();
  });

  it('returns undefined when anchorUsd is not positive', () => {
    const sqrt = BigInt(Math.floor(Math.sqrt(1e-6) * Number(Q96)));
    expect(computeFdvUsd({ supply: 10n ** 27n, tokenDecimals: 18, sqrtPriceX96: sqrt,
      tokenIsToken0: true, anchorDecimals: 18, anchorUsd: 0 })).toBeUndefined();
  });

  it('returns undefined rather than a non-finite number', () => {
    expect(computeFdvUsd({ supply: 10n ** 60n, tokenDecimals: 0, sqrtPriceX96: 2n ** 160n,
      tokenIsToken0: true, anchorDecimals: 18, anchorUsd: 1e300 })).toBeUndefined();
  });
});

describe('resolveTokenMeta', () => {
  const NOW = 1_700_000_000_000;
  // totalSupply() -> 1e27, decimals() -> 18
  const SUPPLY = '0x' + (10n ** 27n).toString(16).padStart(64, '0');
  const DEC = '0x' + (18).toString(16).padStart(64, '0');

  beforeEach(() => vi.clearAllMocks());

  it('reads supply and decimals and caches both', async () => {
    const call = vi.fn(async (_to: string, data: string) =>
      data === '0x18160ddd' ? SUPPLY : DEC);
    const cache: Record<string, TokenMeta> = {};
    const checkedAt: Record<string, number> = {};
    const out = await resolveTokenMeta('0xabc', cache, checkedAt, call, NOW);
    expect(out).toEqual({ supply: 10n ** 27n, decimals: 18 });
    expect(checkedAt['0xabc']).toBe(NOW);
  });

  it('serves a fresh cache hit without calling', async () => {
    const call = vi.fn();
    const cache = { '0xabc': { supply: '5', decimals: 9 } };
    const out = await resolveTokenMeta('0xabc', cache, { '0xabc': NOW }, call, NOW);
    expect(out).toEqual({ supply: 5n, decimals: 9 });
    expect(call).not.toHaveBeenCalled();
  });

  // Supply is NOT immutable — mintable tokens change it, and a mint is exactly
  // the event that should move a token's cap.
  it('re-reads supply once the TTL has passed', async () => {
    const call = vi.fn(async (_to: string, data: string) =>
      data === '0x18160ddd' ? SUPPLY : DEC);
    const cache = { '0xabc': { supply: '5', decimals: 18 } };
    const stale = NOW - (SUPPLY_TTL_MS + 1000);
    const out = await resolveTokenMeta('0xabc', cache, { '0xabc': stale }, call, NOW);
    expect(call).toHaveBeenCalled();
    expect(out).toEqual({ supply: 10n ** 27n, decimals: 18 });
  });

  it('returns undefined and caches nothing when a call fails', async () => {
    const call = vi.fn(async () => { throw new Error('rpc down'); });
    const cache: Record<string, TokenMeta> = {};
    expect(await resolveTokenMeta('0xabc', cache, {}, call, NOW)).toBeUndefined();
    expect(cache['0xabc']).toBeUndefined();
  });

  it('treats an empty decimals response as undefined rather than 0 decimals', async () => {
    const call = vi.fn(async (_to: string, data: string) =>
      data === '0x18160ddd' ? SUPPLY : '0x');
    expect(await resolveTokenMeta('0xabc', {}, {}, call, NOW)).toBeUndefined();
  });
});

describe('fdvFromSeriesValue', () => {
  // 1_000_000 whole tokens (18 dp) at a series value of 1e-3 => 1000 ETH => $2M at $2000/ETH.
  const supply = 1_000_000n * 10n ** 18n;

  it('prices a token from its series value, supply and the anchor rate', () => {
    const fdv = fdvFromSeriesValue({
      seriesValue: 1e-3, supply, tokenDecimals: 18, anchorDecimals: 18, anchorUsd: 2000,
    });
    expect(fdv).toBeCloseTo(2_000_000, 0);
  });

  it('corrects for the decimal gap between the token and the anchor', () => {
    // Same economics, but a 6-dp token: the raw ratio is 1e12 larger, and the
    // 10**(6-18) correction must cancel it exactly.
    const smallSupply = 1_000_000n * 10n ** 6n;
    const fdv = fdvFromSeriesValue({
      seriesValue: 1e-3 * 10 ** 12, supply: smallSupply, tokenDecimals: 6,
      anchorDecimals: 18, anchorUsd: 2000,
    });
    expect(fdv).toBeCloseTo(2_000_000, 0);
  });

  it('returns undefined for a zero supply', () => {
    expect(fdvFromSeriesValue({
      seriesValue: 1e-3, supply: 0n, tokenDecimals: 18, anchorDecimals: 18, anchorUsd: 2000,
    })).toBeUndefined();
  });

  it('returns undefined for a zero anchor rate', () => {
    expect(fdvFromSeriesValue({
      seriesValue: 1e-3, supply, tokenDecimals: 18, anchorDecimals: 18, anchorUsd: 0,
    })).toBeUndefined();
  });

  it('returns undefined for a zero series value', () => {
    expect(fdvFromSeriesValue({
      seriesValue: 0, supply, tokenDecimals: 18, anchorDecimals: 18, anchorUsd: 2000,
    })).toBeUndefined();
  });

  it('returns undefined for a NaN series value', () => {
    expect(fdvFromSeriesValue({
      seriesValue: NaN, supply, tokenDecimals: 18, anchorDecimals: 18, anchorUsd: 2000,
    })).toBeUndefined();
  });

  it('agrees with computeFdvUsd on the same inputs — one formula, two callers', () => {
    const sqrtPriceX96 = 2n ** 96n / 1000n; // series value 1e-6 for token0
    const viaCompute = computeFdvUsd({
      supply, tokenDecimals: 18, sqrtPriceX96,
      tokenIsToken0: true, anchorDecimals: 18, anchorUsd: 2000,
    });
    const viaHelper = fdvFromSeriesValue({
      seriesValue: sqrtPriceToSeriesValue(sqrtPriceX96, true),
      supply, tokenDecimals: 18, anchorDecimals: 18, anchorUsd: 2000,
    });
    expect(viaHelper).toBe(viaCompute);
  });
});
