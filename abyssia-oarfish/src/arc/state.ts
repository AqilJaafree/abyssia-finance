import fs from 'fs';
import { PoolMeta } from './swaps';
import { CandleState } from './candles';
import { TokenMeta } from './onchain-mcap';
import { VerificationResult } from './verification';

export interface MoversState {
  lastProcessedBlock: number;
  meta: Record<string, PoolMeta | null>; // pool -> anchor metadata, or null (non-anchor)
  symbols: Record<string, string>; // token -> symbol
  supplies: Record<string, TokenMeta>; // token -> { supply (string), decimals }, cache-first
  suppliesCheckedAt: Record<string, number>; // token -> ms epoch of that lookup (TTLs ALL entries)
  candles: Record<string, CandleState>; // pool -> candle state
  verified: Record<string, VerificationResult>; // token -> Arcscan verification, cache-first
  verifiedCheckedAt: Record<string, number>; // token -> ms epoch of that lookup (TTLs ALL entries)
}

export function loadState(file: string): MoversState {
  try {
    const s = JSON.parse(fs.readFileSync(file, 'utf8')) as Partial<MoversState>;
    return {
      lastProcessedBlock: s.lastProcessedBlock ?? 0,
      meta: s.meta ?? {},
      symbols: s.symbols ?? {},
      supplies: s.supplies ?? {},
      suppliesCheckedAt: s.suppliesCheckedAt ?? {},
      candles: s.candles ?? {},
      // Absent in files written before verification existed; defaulting to {}
      // means every token reads as never-checked, i.e. resolved next cycle.
      verified: s.verified ?? {},
      verifiedCheckedAt: s.verifiedCheckedAt ?? {},
    };
  } catch {
    return {
      lastProcessedBlock: 0, meta: {}, symbols: {},
      supplies: {}, suppliesCheckedAt: {}, candles: {},
      verified: {}, verifiedCheckedAt: {},
    };
  }
}

export function saveState(file: string, state: MoversState): void {
  fs.writeFileSync(file, JSON.stringify(state));
}
