import { describe, it, expect } from 'vitest';
import { resolveV4PoolMeta, V4PoolMeta, LogFetcher, RepairBudget } from './metadata';
import { V4_INITIALIZE_TOPIC0 } from './config';
import { ARC_USDC } from '../config';
import { RawLog } from '../decode';

const POOL = '0x' + 'cc'.repeat(32);
const USDC = ARC_USDC;
const NATIVE = '0x0000000000000000000000000000000000000000';
const TOKEN = '0x882f08f34083ca963200cbdc5767d61695120b07';

function topicAddr(a: string): string {
  return '0x' + a.slice(2).padStart(64, '0');
}
function initLog(c0: string, c1: string): RawLog {
  return {
    address: '0xpoolmanager',
    topics: [V4_INITIALIZE_TOPIC0, POOL, topicAddr(c0), topicAddr(c1)],
    data: '0x' + '00'.repeat(160),
  };
}

describe('resolveV4PoolMeta', () => {
  it('resolves a USDC pair and caches it', async () => {
    const cache: Record<string, V4PoolMeta | null> = {};
    let calls = 0;
    const getLogs: LogFetcher = async () => {
      calls++;
      return [initLog(USDC, TOKEN)];
    };
    const meta = await resolveV4PoolMeta(POOL, cache, getLogs, 100);
    expect(meta).toEqual({
      poolId: POOL, token: TOKEN, ethIsCurrency0: true, fee: 0,
      tickSpacing: 0, hooks: NATIVE, currency0: USDC, currency1: TOKEN,
    });
    // Second call is served from cache (no extra getLogs).
    await resolveV4PoolMeta(POOL, cache, getLogs, 100);
    expect(calls).toBe(1);
  });

  // Regression: this resolver used to query `fromBlock: 1` unconditionally.
  // Verified live 2026-09-16 against Arc mainnet that the RPC in use rejects
  // any eth_getLogs starting at block 1 with "pruned history unavailable" —
  // which this resolver's catch-all silently turned into "not a USDC pool"
  // for every single v4 pool, no matter how much real volume it had. The fix
  // bounds fromBlock to V4_INITIALIZE_LOOKBACK_BLOCKS behind currentBlock.
  it('bounds fromBlock instead of querying from block 1', async () => {
    const cache: Record<string, V4PoolMeta | null> = {};
    let seenFromBlock: number | undefined;
    const getLogs: LogFetcher = async (params) => {
      seenFromBlock = params.fromBlock;
      return [initLog(USDC, TOKEN)];
    };
    const currentBlock = 21_101_401; // a real-scale Arc block height
    await resolveV4PoolMeta(POOL, cache, getLogs, currentBlock);
    expect(seenFromBlock).toBeGreaterThan(1);
    expect(seenFromBlock).toBe(currentBlock - 250_000);
  });

  it('does not treat the native currency sentinel as the USDC anchor', async () => {
    // currency0 = native sentinel (0x0...0), currency1 = an arbitrary non-USDC
    // token. Arc has no native-ETH-as-anchor concept — ETH_CURRENCIES in
    // src/arc/v4/config.ts is ARC_USDC only, so this pair must resolve to null.
    const cache: Record<string, V4PoolMeta | null> = {};
    const other = '0x' + '33'.repeat(20);
    const getLogs: LogFetcher = async () => [initLog(NATIVE, other)];
    const meta = await resolveV4PoolMeta(POOL, cache, getLogs, 100);
    expect(meta).toBeNull();
    expect(cache[POOL]).toBeNull();
  });

  it('caches null for a confirmed non-USDC pair', async () => {
    const cache: Record<string, V4PoolMeta | null> = {};
    const other = '0x' + '33'.repeat(20);
    const getLogs: LogFetcher = async () => [initLog(other, TOKEN)];
    expect(await resolveV4PoolMeta(POOL, cache, getLogs, 100)).toBeNull();
    expect(cache[POOL]).toBeNull();
  });

  it('does NOT cache when the Initialize log is not found (retryable)', async () => {
    const cache: Record<string, V4PoolMeta | null> = {};
    const getLogs: LogFetcher = async () => [];
    expect(await resolveV4PoolMeta(POOL, cache, getLogs, 100)).toBeNull();
    expect(POOL in cache).toBe(false);
  });

  it('does NOT cache on a transient RPC error (retryable)', async () => {
    const cache: Record<string, V4PoolMeta | null> = {};
    const getLogs: LogFetcher = async () => {
      throw new Error('log query timed out');
    };
    expect(await resolveV4PoolMeta(POOL, cache, getLogs, 100)).toBeNull();
    expect(POOL in cache).toBe(false);
  });

  // resolveV4PoolMeta's default anchor set is ETH_CURRENCIES ({ARC_USDC} only —
  // see src/arc/v4/config.ts), but any caller can override it with a custom
  // anchor set (5th arg). This exercises that override mechanism directly.
  const CUSTOM_ANCHOR = '0x5fc5360d0400a0fd4f2af552add042d716f1d168';

  it('with a custom anchor set: keeps custom-anchor pairs and skips USDC pairs', async () => {
    const anchors = new Set([CUSTOM_ANCHOR]);
    // A CUSTOM_ANCHOR/TOKEN pool is kept.
    const customCache: Record<string, V4PoolMeta | null> = {};
    const customLogs: LogFetcher = async () => [initLog(CUSTOM_ANCHOR, TOKEN)];
    expect(await resolveV4PoolMeta(POOL, customCache, customLogs, 100, anchors)).toEqual({
      poolId: POOL,
      token: TOKEN,
      ethIsCurrency0: true, // "anchor (CUSTOM_ANCHOR) is currency0"
      fee: 0,
      tickSpacing: 0,
      hooks: NATIVE,
      currency0: CUSTOM_ANCHOR,
      currency1: TOKEN,
    });
    // A USDC/TOKEN pool is NOT the custom anchor → cached null.
    const usdcCache: Record<string, V4PoolMeta | null> = {};
    const usdcLogs: LogFetcher = async () => [initLog(USDC, TOKEN)];
    expect(await resolveV4PoolMeta(POOL, usdcCache, usdcLogs, 100, anchors)).toBeNull();
    expect(usdcCache[POOL]).toBeNull();
  });
});

describe('resolveV4PoolMeta — PoolKey fields', () => {
  // A pool whose Initialize really carries a fee, a spacing and a hook — the fixture
  // above is all zeroes, which cannot tell "decoded 0" from "did not decode".
  function realInitLog(c0: string, c1: string): RawLog {
    const word = (v: bigint) => v.toString(16).padStart(64, '0');
    const hook = '0xe5e702641ea86f4ae6cc3cdaed2b886f976be044';
    return {
      address: '0xpoolmanager',
      topics: [V4_INITIALIZE_TOPIC0, POOL, topicAddr(c0), topicAddr(c1)],
      data:
        '0x' + word(27885n) + word(279n) +
        hook.slice(2).padStart(64, '0') + word(1n) + word(2n),
    };
  }

  it('carries tickSpacing, hooks and both currencies onto the cached meta', async () => {
    const cache: Record<string, V4PoolMeta | null> = {};
    const meta = await resolveV4PoolMeta(POOL, cache, async () => [realInitLog(USDC, TOKEN)], 100);
    expect(meta?.fee).toBe(27885);
    expect(meta?.tickSpacing).toBe(279);
    expect(meta?.hooks).toBe('0xe5e702641ea86f4ae6cc3cdaed2b886f976be044');
    expect(meta?.currency0).toBe(USDC);
    expect(meta?.currency1).toBe(TOKEN);
    // and they survive into the CACHE, which is what a future LP-style eligibility
    // gate would read — not the return value.
    expect(cache[POOL]?.tickSpacing).toBe(279);
    expect(cache[POOL]?.hooks).toBe('0xe5e702641ea86f4ae6cc3cdaed2b886f976be044');
  });

  // A registry written before those fields existed carries an entry that any future
  // eligibility gate must refuse — a guessed tickSpacing aligns a range to a grid
  // the pool does not have. Cache-first made that refusal PERMANENT in nautilus's
  // ported source: `if (poolId in cache)` returned the incomplete entry forever,
  // nothing was ever pruned, and the file persists on disk between runs.
  it('RE-RESOLVES a cached entry that predates the PoolKey fields', async () => {
    const stale: V4PoolMeta = {
      poolId: POOL, token: TOKEN, ethIsCurrency0: true, fee: 27885,
      // tickSpacing, hooks, currency0 and currency1 all absent — exactly what the old
      // decoder wrote.
    };
    const cache: Record<string, V4PoolMeta | null> = { [POOL]: stale };
    let calls = 0;
    const meta = await resolveV4PoolMeta(
      POOL, cache,
      async () => { calls++; return [realInitLog(USDC, TOKEN)]; },
      100
    );
    expect(calls).toBe(1);
    expect(meta?.tickSpacing).toBe(279);
    expect(cache[POOL]?.tickSpacing).toBe(279);
    expect(cache[POOL]?.currency0).toBe(USDC);
  });

  it('serves a COMPLETE cached entry without a second log read', async () => {
    // The repair must not turn every cycle into a full-range getLogs per pool.
    const cache: Record<string, V4PoolMeta | null> = {};
    let calls = 0;
    const getLogs: LogFetcher = async () => { calls++; return [realInitLog(USDC, TOKEN)]; };
    await resolveV4PoolMeta(POOL, cache, getLogs, 100);
    await resolveV4PoolMeta(POOL, cache, getLogs, 100);
    await resolveV4PoolMeta(POOL, cache, getLogs, 100);
    expect(calls).toBe(1);
  });

  it('still serves a cached NULL without a second log read', async () => {
    // `null` means "confirmed not an anchor pair" — a settled verdict with no fields to
    // be missing. Re-reading it would re-scan every non-anchor pool on the chain, every
    // cycle, forever.
    const cache: Record<string, V4PoolMeta | null> = { [POOL]: null };
    let calls = 0;
    expect(await resolveV4PoolMeta(POOL, cache, async () => { calls++; return []; }, 100))
      .toBeNull();
    expect(calls).toBe(0);
  });

  it('falls back to the stale entry when the re-read finds nothing', async () => {
    // A node that answered nothing has said nothing about the pool. The movers board
    // reads only `token` / `ethIsCurrency0` / `fee`, all of which the stale entry has —
    // so returning null here would drop a live pool off the board over a fault that has
    // nothing to do with it. Any future eligibility gate still refuses the entry for
    // want of a tickSpacing, and the next cycle re-reads.
    const stale: V4PoolMeta = { poolId: POOL, token: TOKEN, ethIsCurrency0: true, fee: 27885 };
    const cache: Record<string, V4PoolMeta | null> = { [POOL]: stale };
    expect(await resolveV4PoolMeta(POOL, cache, async () => [], 100)).toBe(stale);
    expect(cache[POOL]).toBe(stale);
  });

  it('falls back to the stale entry when the re-read throws', async () => {
    const stale: V4PoolMeta = { poolId: POOL, token: TOKEN, ethIsCurrency0: true, fee: 27885 };
    const cache: Record<string, V4PoolMeta | null> = { [POOL]: stale };
    const boom: LogFetcher = async () => { throw new Error('log query timed out'); };
    expect(await resolveV4PoolMeta(POOL, cache, boom, 100)).toBe(stale);
    expect(cache[POOL]).toBe(stale);
  });

  // A registry full of pre-repair entries would try to repair all of them at once —
  // sequential full-range getLogs against a shared RPC. The repair is a one-time
  // migration, so it is paced rather than raced: a budget per cycle, and an entry
  // that misses out is served stale exactly as before and repaired on a later tick.
  it('spends at most its repair budget on incomplete entries in one cycle', async () => {
    const stale = (id: string): V4PoolMeta =>
      ({ poolId: id, token: TOKEN, ethIsCurrency0: true, fee: 27885 });
    const ids = ['0x' + 'a1'.repeat(32), '0x' + 'a2'.repeat(32), '0x' + 'a3'.repeat(32)];
    const cache: Record<string, V4PoolMeta | null> = Object.fromEntries(
      ids.map((id) => [id, stale(id)])
    );
    let calls = 0;
    const getLogs: LogFetcher = async () => { calls++; return [realInitLog(USDC, TOKEN)]; };
    const budget = { left: 2 };
    for (const id of ids) await resolveV4PoolMeta(id, cache, getLogs, 100, undefined, budget);
    expect(calls).toBe(2);
    expect(budget.left).toBe(0);
    // The two that fitted are repaired; the third is untouched and still stale.
    expect(cache[ids[0]]?.tickSpacing).toBe(279);
    expect(cache[ids[1]]?.tickSpacing).toBe(279);
    expect(cache[ids[2]]?.tickSpacing).toBeUndefined();
  });

  // Reversed 2026-09-16: nautilus's original comment here argued a first
  // sighting must NEVER be paced, since it is "the read this resolver exists
  // to make." That held for a chain where new v4 pools appear in the single
  // digits per cycle. Verified live against Arc mainnet that a single ~60s
  // polling window can carry 260+ distinct v4 pools — an unbudgeted first
  // sighting for every one of them meant the v4 loop never finished a single
  // cycle. A first sighting now costs budget exactly like a repair; see the
  // comment in resolveV4PoolMeta.
  it('spends the budget on a pool it has never seen, deferring past it when exhausted', async () => {
    const cache: Record<string, V4PoolMeta | null> = {};
    let calls = 0;
    const budget: RepairBudget = { left: 0 };
    const meta = await resolveV4PoolMeta(
      POOL, cache, async () => { calls++; return [realInitLog(USDC, TOKEN)]; }, 100,
      undefined, budget
    );
    expect(calls).toBe(0);
    expect(meta).toBeUndefined();
    expect(cache[POOL]).toBeUndefined(); // not cached either way — retried next cycle
    expect(budget.deferred).toBe(1);
  });

  it('still resolves a first sighting immediately when budget is available', async () => {
    const cache: Record<string, V4PoolMeta | null> = {};
    let calls = 0;
    const budget = { left: 1 };
    const meta = await resolveV4PoolMeta(
      POOL, cache, async () => { calls++; return [realInitLog(USDC, TOKEN)]; }, 100,
      undefined, budget
    );
    expect(calls).toBe(1);
    expect(meta?.tickSpacing).toBe(279);
    expect(budget.left).toBe(0);
  });

  // `deferred` only fires when there are MORE stale entries than budget. A registry with
  // a handful left, whose re-reads all fail, would then spend a request per pool per
  // cycle and log nothing at all — a stalled repair indistinguishable from a finished
  // one. Counting the failures is what makes that branch speak.
  it('counts a repair whose read throws', async () => {
    const stale: V4PoolMeta = { poolId: POOL, token: TOKEN, ethIsCurrency0: true, fee: 27885 };
    const cache: Record<string, V4PoolMeta | null> = { [POOL]: stale };
    const budget = { left: 5 };
    const boom: LogFetcher = async () => { throw new Error('log query timed out'); };
    expect(await resolveV4PoolMeta(POOL, cache, boom, 100, undefined, budget)).toBe(stale);
    expect((budget as { failed?: number }).failed).toBe(1);
    // The request was still made, so the budget is still spent.
    expect(budget.left).toBe(4);
  });

  it('counts a repair whose read finds nothing', async () => {
    const stale: V4PoolMeta = { poolId: POOL, token: TOKEN, ethIsCurrency0: true, fee: 27885 };
    const cache: Record<string, V4PoolMeta | null> = { [POOL]: stale };
    const budget = { left: 5 };
    expect(await resolveV4PoolMeta(POOL, cache, async () => [], 100, undefined, budget))
      .toBe(stale);
    expect((budget as { failed?: number }).failed).toBe(1);
  });

  it('does not count a repair that succeeds', async () => {
    const stale: V4PoolMeta = { poolId: POOL, token: TOKEN, ethIsCurrency0: true, fee: 27885 };
    const cache: Record<string, V4PoolMeta | null> = { [POOL]: stale };
    const budget = { left: 5 };
    await resolveV4PoolMeta(
      POOL, cache, async () => [realInitLog(USDC, TOKEN)], 100, undefined, budget
    );
    expect((budget as { failed?: number }).failed).toBeUndefined();
  });

  it('repairs without limit when no budget is supplied', async () => {
    const stale: V4PoolMeta = { poolId: POOL, token: TOKEN, ethIsCurrency0: true, fee: 27885 };
    const cache: Record<string, V4PoolMeta | null> = { [POOL]: stale };
    const meta = await resolveV4PoolMeta(POOL, cache, async () => [realInitLog(USDC, TOKEN)], 100);
    expect(meta?.tickSpacing).toBe(279);
  });

  // A repair must never DOWNGRADE a positive entry to a permanent negative. `null` is
  // exempt from re-reading and nothing prunes the registry, so caching one here would
  // make a wrong `anchors` set destructive to persisted state — and the default anchor
  // set is built from `ARC_USDC`, i.e. `process.env.ARC_USDC ?? <default>`, a plain `??`
  // fallback that a defined-but-blank env var bypasses (see src/arc/config.ts's
  // nonNegativeIntEnv comment for the general shape of this hole). Blank it and every
  // incomplete USDC entry that came up for repair would be erased from the board
  // forever, surviving the fix to the env var. The window is exactly the migration this
  // feature exists for.
  //
  // So the verdict is honoured for this cycle and not written down. An operator who
  // genuinely changed the anchor set clears the state file; everyone else keeps theirs.
  it('does NOT cache a negative over an entry it already held', async () => {
    const stale: V4PoolMeta = { poolId: POOL, token: TOKEN, ethIsCurrency0: true, fee: 27885 };
    const cache: Record<string, V4PoolMeta | null> = { [POOL]: stale };
    const other = '0x' + '33'.repeat(20);
    const budget = { left: 5 };
    expect(
      await resolveV4PoolMeta(
        POOL, cache, async () => [initLog(other, TOKEN)], 100, undefined, budget
      )
    ).toBeNull();
    expect(cache[POOL]).toBe(stale);
    // Counted, so a registry permanently disagreeing with the anchor set is visible
    // rather than a silent budget drain every cycle.
    expect((budget as { failed?: number }).failed).toBe(1);
  });

  it('still caches a negative for a pool it has NEVER held', async () => {
    // The first-sighting negative is a genuine verdict about a pool nothing is invested
    // in, and caching it is what stops a re-scan of every non-anchor pool on the chain.
    const cache: Record<string, V4PoolMeta | null> = {};
    const other = '0x' + '33'.repeat(20);
    expect(await resolveV4PoolMeta(POOL, cache, async () => [initLog(other, TOKEN)], 100))
      .toBeNull();
    expect(cache[POOL]).toBeNull();
  });
});
