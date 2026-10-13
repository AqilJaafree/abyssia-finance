// Signal-strategy parameters. ALL of them come from the environment and NONE
// has a default in code — the tuned values are private and must never be
// committed, logged, or rendered in a Telegram message. A missing or malformed
// key keeps both board loops from starting (see src/index.ts); only the key
// NAMES are ever reported, never a value.
//
// Operational knobs (RPC, poll interval, lookback, top-N, lookup budgets) stay
// in src/arc/config.ts with ordinary defaults — they shape cost, not the signal.

export interface RsiStrategy {
  period: number;     // RSI lookback period (closes needed = period + 1)
  oversold: number;   // RSI strictly below this -> 'oversold'
  overbought: number; // RSI strictly above this -> 'overbought'
}

export interface Strategy {
  rsi: RsiStrategy;
  blocksPerCandle: number;     // candle width, in blocks
  maxCloses: number;           // finalized closes kept per pool
  minMarketCapUsd: number;     // below this (or unknown) -> Danger Zone
  rsiMinVolumeUsdc: bigint;    // RSI display floor, USDC base units (0 = off)
}

export const STRATEGY_ENV_KEYS = [
  'STRATEGY_RSI_PERIOD',
  'STRATEGY_RSI_OVERSOLD',
  'STRATEGY_RSI_OVERBOUGHT',
  'STRATEGY_BLOCKS_PER_CANDLE',
  'STRATEGY_MAX_CLOSES',
  'STRATEGY_MIN_MARKET_CAP_USD',
  'STRATEGY_RSI_MIN_VOLUME_USDC',
] as const;

export type StrategyResult =
  | { ok: true; strategy: Strategy }
  | { ok: false; invalid: string[] };

type Env = Record<string, string | undefined>;

function num(env: Env, key: string, invalid: string[], min: number, max = Infinity): number {
  const raw = env[key]?.trim();
  const n = raw ? Number(raw) : NaN;
  if (!Number.isFinite(n) || n < min || n > max) {
    invalid.push(key);
    return NaN;
  }
  return n;
}

function int(env: Env, key: string, invalid: string[], min: number): number {
  const n = num(env, key, invalid, min);
  if (!Number.isNaN(n) && !Number.isInteger(n)) {
    invalid.push(key);
    return NaN;
  }
  return n;
}

function bigUint(env: Env, key: string, invalid: string[]): bigint {
  const raw = env[key]?.trim();
  if (raw && /^\d+$/.test(raw)) return BigInt(raw);
  invalid.push(key);
  return 0n;
}

export function loadStrategy(env: Env = process.env): StrategyResult {
  const invalid: string[] = [];
  const period = int(env, 'STRATEGY_RSI_PERIOD', invalid, 1);
  const oversold = num(env, 'STRATEGY_RSI_OVERSOLD', invalid, 0, 100);
  const overbought = num(env, 'STRATEGY_RSI_OVERBOUGHT', invalid, 0, 100);
  const blocksPerCandle = int(env, 'STRATEGY_BLOCKS_PER_CANDLE', invalid, 1);
  const maxCloses = int(env, 'STRATEGY_MAX_CLOSES', invalid, 1);
  const minMarketCapUsd = num(env, 'STRATEGY_MIN_MARKET_CAP_USD', invalid, 0);
  const rsiMinVolumeUsdc = bigUint(env, 'STRATEGY_RSI_MIN_VOLUME_USDC', invalid);

  // Cross-field checks: inverted thresholds would label everything, and a
  // history cap shorter than the RSI window means RSI can never be computed.
  if (!invalid.length && oversold >= overbought) {
    invalid.push('STRATEGY_RSI_OVERSOLD', 'STRATEGY_RSI_OVERBOUGHT');
  }
  if (!invalid.length && maxCloses < period) invalid.push('STRATEGY_MAX_CLOSES');

  if (invalid.length) return { ok: false, invalid: [...new Set(invalid)] };
  return {
    ok: true,
    strategy: {
      rsi: { period, oversold, overbought },
      blocksPerCandle,
      maxCloses,
      minMarketCapUsd,
      rsiMinVolumeUsdc,
    },
  };
}
