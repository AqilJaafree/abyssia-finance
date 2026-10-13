// Splits a volume-ranked list into a main board and a Danger Zone board by market
// cap, resolving caps LAZILY so a busy window cannot hammer Blockscout.
//
// The naive alternative — price every token that traded, then filter — costs one
// lookup per token per cycle (~100 tokens x 4 boards x every 60s). Blockscout's v1
// API already 429s on nearly every call; v2 is healthy and must stay that way.
//
// Generic over the row shape so both the v3 (`RankedPool`) and v4 (`V4RankedPool`)
// rankings can use it unchanged — all this needs is a `token`.

export interface McapSelectOptions {
  minUsd: number;      // rows at or above this go to main
  perGroup: number;    // max rows per group (the board's TOP_N)
  maxLookups: number;  // hard ceiling on resolver calls per cycle
}

export interface McapSelection<T> {
  main: Array<T & { marketCapUsd?: number }>;
  danger: Array<T & { marketCapUsd?: number }>;
  lookups: number;   // how many resolver calls were made
  capped: boolean;   // true if maxLookups stopped the walk early
}

export async function selectByMarketCap<T extends { token: string }>(
  ranked: T[],
  // A rejection is tolerated, not just an `undefined` resolution: this module's
  // fail-safe policy applies equally to a failed lookup, so a rejected call is
  // caught here and treated exactly like an unknown cap rather than aborting
  // the walk and discarding everything accumulated so far.
  //
  // Takes the whole row, not just the token: a token must be priced from its OWN
  // pool (its sqrtPriceX96, its pool's meta), which the row carries and a bare
  // token string does not.
  resolve: (row: T) => Promise<number | undefined>,
  opts: McapSelectOptions
): Promise<McapSelection<T>> {
  const main: Array<T & { marketCapUsd?: number }> = [];
  const danger: Array<T & { marketCapUsd?: number }> = [];
  let lookups = 0;
  let capped = false;

  // A token can trade on more than one fee-tier pool, producing two rows here.
  // resolveTokenMeta (the workers' resolver) deliberately does NOT cache a
  // transient failure (so the next cycle retries it), which means two rows for
  // the same token can get two DIFFERENT verdicts within the same walk if each
  // called resolve() itself —
  // e.g. pool A times out (unknown -> danger) while pool B, resolved moments
  // later, clears the threshold (-> main). Same token, same cycle, both boards,
  // contradicting itself. Memoizing per token within this one call keeps every
  // row of a token on one consistent side. Memoized on the promise (not the
  // resolved value) so two rows can't both kick off an in-flight request —
  // belt-and-braces, since the walk below is sequential anyway.
  const memo = new Map<string, Promise<number | undefined>>();
  const resolveOnce = (row: T): Promise<number | undefined> => {
    let cached = memo.get(row.token);
    if (!cached) {
      lookups++; // only a real resolver call counts against the cycle's lookup budget
      // A rejected call still counts as an attempted lookup and still leaves the
      // cap unknown — caught here so it degrades exactly like an `undefined`
      // resolution instead of throwing away every row accumulated so far.
      cached = resolve(row).catch(() => undefined);
      memo.set(row.token, cached);
    }
    return cached;
  };

  for (const row of ranked) {
    // Both groups full — everything further down the ranking is lower volume and
    // could not displace what we already hold.
    if (main.length >= opts.perGroup && danger.length >= opts.perGroup) break;
    // A memoized token doesn't consume a fresh lookup, but the budget check must
    // still run before an UNSEEN token could push lookups past maxLookups.
    if (!memo.has(row.token) && lookups >= opts.maxLookups) {
      capped = true;
      break;
    }
    const marketCapUsd = await resolveOnce(row);
    // `undefined` (unknown) is NOT >= minUsd, so it lands in danger. Fail-safe:
    // an unknown cap is not evidence of a qualifying one.
    const group = marketCapUsd != null && marketCapUsd >= opts.minUsd ? main : danger;
    // A full group still consumes a lookup on its way past — lookups can
    // legitimately exceed main.length + danger.length. That's expected, not a bug.
    if (group.length < opts.perGroup) group.push({ ...row, marketCapUsd });
  }

  return { main, danger, lookups, capped };
}
