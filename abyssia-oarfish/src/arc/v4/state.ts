import fs from 'fs';
import { V4PoolMeta } from './metadata';
import { CandleState } from '../candles';
import { TokenMeta } from '../onchain-mcap';
import { VerificationResult } from '../verification';

export interface V4MoversState {
  lastProcessedBlock: number;
  registry: Record<string, V4PoolMeta | null>; // poolId -> anchor metadata, or null
  symbols: Record<string, string>; // token -> symbol
  supplies: Record<string, TokenMeta>; // token -> { supply (string), decimals }, cache-first
  suppliesCheckedAt: Record<string, number>; // token -> ms epoch of that lookup
  candles: Record<string, CandleState>; // poolId -> candle state
  verified: Record<string, VerificationResult>; // token -> Arcscan verification, cache-first
  verifiedCheckedAt: Record<string, number>; // token -> ms epoch of that lookup
}

export function loadV4State(file: string): V4MoversState {
  try {
    const s = JSON.parse(fs.readFileSync(file, 'utf8')) as Partial<V4MoversState>;
    return {
      lastProcessedBlock: s.lastProcessedBlock ?? 0,
      registry: s.registry ?? {},
      symbols: s.symbols ?? {},
      supplies: s.supplies ?? {},
      suppliesCheckedAt: s.suppliesCheckedAt ?? {},
      candles: s.candles ?? {},
      verified: s.verified ?? {},
      verifiedCheckedAt: s.verifiedCheckedAt ?? {},
    };
  } catch {
    return {
      lastProcessedBlock: 0, registry: {}, symbols: {},
      supplies: {}, suppliesCheckedAt: {}, candles: {},
      verified: {}, verifiedCheckedAt: {},
    };
  }
}

export function saveV4State(file: string, state: V4MoversState): void {
  fs.writeFileSync(file, JSON.stringify(state));
}
