import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { loadState, saveState, MoversState } from './state';

describe('loadState / saveState', () => {
  let file: string;

  beforeEach(() => {
    file = path.join(os.tmpdir(), `oarfish-state-${Date.now()}-${Math.random()}.json`);
  });

  afterEach(() => {
    if (fs.existsSync(file)) fs.unlinkSync(file);
  });

  it('returns defaults when the file does not exist', () => {
    const s = loadState(file);
    expect(s).toEqual({
      lastProcessedBlock: 0, meta: {}, symbols: {},
      supplies: {}, suppliesCheckedAt: {}, candles: {},
      verified: {}, verifiedCheckedAt: {},
    });
  });

  it('round-trips a saved state', () => {
    const state: MoversState = {
      lastProcessedBlock: 100,
      meta: { '0xpool': { pool: '0xpool', token: '0xtok', fee: 3000, wethIsToken0: true } },
      symbols: { '0xtok': 'FOO' },
      supplies: { '0xtok': { supply: '1000000', decimals: 18 } },
      suppliesCheckedAt: { '0xtok': 12345 },
      candles: { '0xpool': { bucket: 1, close: 1.5, closes: [1.1, 1.2] } },
      verified: { '0xtok': { verified: true, isErc20: true, lookalike: false } },
      verifiedCheckedAt: { '0xtok': 12345 },
    };
    saveState(file, state);
    expect(loadState(file)).toEqual(state);
  });

  it('defaults missing fields on a partial/old file', () => {
    fs.writeFileSync(file, JSON.stringify({ lastProcessedBlock: 5 }));
    const s = loadState(file);
    expect(s.lastProcessedBlock).toBe(5);
    expect(s.meta).toEqual({});
    expect(s.supplies).toEqual({});
    expect(s.candles).toEqual({});
    expect(s.verified).toEqual({});
  });

  it('returns defaults on malformed JSON', () => {
    fs.writeFileSync(file, 'not json');
    expect(loadState(file).lastProcessedBlock).toBe(0);
  });
});
