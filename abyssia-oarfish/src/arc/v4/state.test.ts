import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { loadV4State, saveV4State, V4MoversState } from './state';

describe('loadV4State / saveV4State', () => {
  let file: string;

  beforeEach(() => {
    file = path.join(os.tmpdir(), `oarfish-v4state-${Date.now()}-${Math.random()}.json`);
  });

  afterEach(() => {
    if (fs.existsSync(file)) fs.unlinkSync(file);
  });

  it('returns defaults when the file does not exist', () => {
    expect(loadV4State(file)).toEqual({
      lastProcessedBlock: 0, registry: {}, symbols: {},
      supplies: {}, suppliesCheckedAt: {}, candles: {},
      verified: {}, verifiedCheckedAt: {},
    });
  });

  it('round-trips a saved state', () => {
    const state: V4MoversState = {
      lastProcessedBlock: 42,
      registry: {
        '0xpoolid': {
          poolId: '0xpoolid', token: '0xtok', ethIsCurrency0: false, fee: 3000,
          tickSpacing: 60, hooks: '0x0000000000000000000000000000000000000000',
          currency0: '0xtok', currency1: '0x3600000000000000000000000000000000000000',
        },
      },
      symbols: { '0xtok': 'FOO' },
      supplies: { '0xtok': { supply: '1000', decimals: 18 } },
      suppliesCheckedAt: { '0xtok': 999 },
      candles: {},
      verified: { '0xtok': { verified: false, isErc20: true, lookalike: false } },
      verifiedCheckedAt: { '0xtok': 999 },
    };
    saveV4State(file, state);
    expect(loadV4State(file)).toEqual(state);
  });

  it('returns defaults on malformed JSON', () => {
    fs.writeFileSync(file, '{not json');
    expect(loadV4State(file).lastProcessedBlock).toBe(0);
  });
});
