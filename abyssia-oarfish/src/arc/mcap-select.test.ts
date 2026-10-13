import { describe, it, expect, vi } from 'vitest';
import { selectByMarketCap } from './mcap-select';

// Minimal shape the selector needs: anything with a `token`.
const ranked = (n: number) =>
  Array.from({ length: n }, (_, i) => ({ token: `t${i}`, volume: 100 - i }));

const OPTS = { minUsd: 50_000, perGroup: 5, maxLookups: 25 };

describe('selectByMarketCap', () => {
  it('routes tokens at or above the threshold to main, below it to danger', async () => {
    const caps: Record<string, number> = { t0: 1_000_000, t1: 4_000, t2: 50_000, t3: 49_999 };
    const out = await selectByMarketCap(ranked(4), async (row) => caps[row.token], OPTS);
    expect(out.main.map((r) => r.token)).toEqual(['t0', 't2']);
    expect(out.danger.map((r) => r.token)).toEqual(['t1', 't3']);
  });

  it('attaches the resolved cap to each row', async () => {
    const out = await selectByMarketCap(ranked(1), async () => 750_000, OPTS);
    expect(out.main[0].marketCapUsd).toBe(750_000);
  });

  it('preserves the incoming volume order within each group', async () => {
    const caps: Record<string, number> = { t0: 1_000, t1: 900_000, t2: 2_000, t3: 800_000 };
    const out = await selectByMarketCap(ranked(4), async (row) => caps[row.token], OPTS);
    expect(out.main.map((r) => r.token)).toEqual(['t1', 't3']);
    expect(out.danger.map((r) => r.token)).toEqual(['t0', 't2']);
  });

  // An unknown cap is not evidence of a cap >= threshold, so it must not pass
  // the gate. Fail-safe, per the spec.
  it('routes an unresolved cap to danger with marketCapUsd undefined', async () => {
    const out = await selectByMarketCap(ranked(1), async () => undefined, OPTS);
    expect(out.danger).toHaveLength(1);
    expect(out.main).toHaveLength(0);
    expect(out.danger[0].marketCapUsd).toBeUndefined();
  });

  it('caps each group at perGroup', async () => {
    const out = await selectByMarketCap(ranked(20), async () => 1_000_000, { ...OPTS, perGroup: 3 });
    expect(out.main).toHaveLength(3);
  });

  // The whole point: stop walking once both groups are full.
  it('stops resolving as soon as both groups are full', async () => {
    const resolve = vi.fn(async (row: { token: string }) =>
      Number(row.token.slice(1)) % 2 === 0 ? 1_000_000 : 1_000
    );
    const out = await selectByMarketCap(ranked(100), resolve, { ...OPTS, perGroup: 2 });
    expect(out.main).toHaveLength(2);
    expect(out.danger).toHaveLength(2);
    expect(resolve).toHaveBeenCalledTimes(4);
    expect(out.capped).toBe(false);
  });

  it('stops at maxLookups and reports capped so the caller can log it', async () => {
    const resolve = vi.fn(async () => 1_000_000);
    const out = await selectByMarketCap(ranked(100), resolve, { ...OPTS, maxLookups: 7 });
    expect(resolve).toHaveBeenCalledTimes(7);
    expect(out.lookups).toBe(7);
    expect(out.capped).toBe(true);
  });

  it('is not capped when the ranking runs out naturally', async () => {
    const out = await selectByMarketCap(ranked(3), async () => 1_000_000, OPTS);
    expect(out.capped).toBe(false);
    expect(out.lookups).toBe(3);
  });

  it('handles an empty ranking', async () => {
    const out = await selectByMarketCap([], async () => 1_000_000, OPTS);
    expect(out).toMatchObject({ main: [], danger: [], lookups: 0, capped: false });
  });

  // Fail-safe applies to a failed lookup too: a rejection must not crash the
  // walk and discard everything accumulated so far.
  it('routes a rejected lookup to danger with marketCapUsd undefined, and continues the walk', async () => {
    const resolve = vi.fn(async (row: { token: string }) => {
      if (row.token === 't1') throw new Error('resolver blew up');
      return 1_000_000;
    });
    const out = await selectByMarketCap(ranked(3), resolve, OPTS);
    expect(out.danger.map((r) => r.token)).toEqual(['t1']);
    expect(out.danger[0].marketCapUsd).toBeUndefined();
    expect(out.main.map((r) => r.token)).toEqual(['t0', 't2']);
  });

  it('still counts a rejected lookup toward lookups', async () => {
    const resolve = vi.fn(async (row: { token: string }) => {
      if (row.token === 't0') throw new Error('resolver blew up');
      return 1_000_000;
    });
    const out = await selectByMarketCap(ranked(2), resolve, OPTS);
    expect(out.lookups).toBe(2);
  });

  // Two fee-tier pools of the same token are two rows in the ranking (that's
  // intended — see the module comment). Without memoization each row calls the
  // resolver independently, and a transient failure on one row + a success on
  // the other would split one token across both boards in the same cycle.
  describe('memoizes per token within one call', () => {
    const twoPoolsSameToken = [
      { token: 'shared', pool: 'poolA', volume: 100 },
      { token: 'shared', pool: 'poolB', volume: 90 },
    ];

    it('resolves a token shared by two rows only once, and both rows get the same cap', async () => {
      const resolve = vi.fn(async () => 500_000);
      const out = await selectByMarketCap(twoPoolsSameToken, resolve, OPTS);
      expect(resolve).toHaveBeenCalledTimes(1);
      const all = [...out.main, ...out.danger];
      expect(all).toHaveLength(2);
      expect(all.every((r) => r.marketCapUsd === 500_000)).toBe(true);
    });

    it('a shared token that fails to resolve lands both rows in danger, never split across boards', async () => {
      const resolve = vi.fn(async () => {
        throw new Error('transient timeout');
      });
      const out = await selectByMarketCap(twoPoolsSameToken, resolve, OPTS);
      expect(resolve).toHaveBeenCalledTimes(1);
      expect(out.main).toHaveLength(0);
      expect(out.danger).toHaveLength(2);
      expect(out.danger.every((r) => r.marketCapUsd === undefined)).toBe(true);
    });

    it('a memoized repeat does not increment lookups', async () => {
      const resolve = vi.fn(async () => 500_000);
      const out = await selectByMarketCap(twoPoolsSameToken, resolve, OPTS);
      // One resolver call, but two rows walked — lookups must reflect the former.
      expect(out.lookups).toBe(1);
    });

    it('distinct tokens still resolve independently (not over-memoised)', async () => {
      const resolve = vi.fn(async (row: { token: string }) => (row.token === 't0' ? 1_000_000 : 1_000));
      const out = await selectByMarketCap(ranked(2), resolve, OPTS);
      expect(resolve).toHaveBeenCalledTimes(2);
      expect(out.lookups).toBe(2);
      expect(out.main.map((r) => r.token)).toEqual(['t0']);
      expect(out.danger.map((r) => r.token)).toEqual(['t1']);
    });
  });
});
