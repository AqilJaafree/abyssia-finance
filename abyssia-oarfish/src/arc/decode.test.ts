import { describe, it, expect } from 'vitest';
import {
  decodeSwapLog,
  decodeSymbol,
  wordAt,
  hasWords,
  addressFromTopic,
} from './decode';
import { SWAP_TOPIC0 } from './config';

// Independent encoder helpers (encode-side, to validate the decode-side).
function toWord(v: bigint): string {
  const mod = 1n << 256n;
  const u = ((v % mod) + mod) % mod;
  return u.toString(16).padStart(64, '0');
}
function addrTopic(a: string): string {
  return '0x' + a.slice(2).toLowerCase().padStart(64, '0');
}

const A = '0x1111111111111111111111111111111111111111';
const B = '0x2222222222222222222222222222222222222222';

describe('decodeSwapLog', () => {
  it('decodes signed amounts, sqrtPrice, and indexed addresses', () => {
    const log = {
      address: '0xpool',
      topics: [SWAP_TOPIC0, addrTopic(A), addrTopic(B)],
      data:
        '0x' +
        toWord(1_000_000n) + // amount0 (positive input)
        toWord(-500n) + // amount1 (negative output)
        toWord(79228162514264337593543950336n) + // sqrtPriceX96 = 2^96
        toWord(12345n) + // liquidity
        toWord(-100n), // tick
    };
    const d = decodeSwapLog(log);
    expect(d.amount0).toBe(1_000_000n);
    expect(d.amount1).toBe(-500n);
    expect(d.sqrtPriceX96).toBe(79228162514264337593543950336n);
    expect(d.recipient).toBe(B);
    expect(d.sender).toBe(A);
  });
});

describe('decodeSymbol', () => {
  it('decodes an ABI-encoded string', () => {
    const result =
      '0x' +
      toWord(32n) + // offset
      toWord(4n) + // length
      Buffer.from('WETH').toString('hex').padEnd(64, '0');
    expect(decodeSymbol(result)).toBe('WETH');
  });
  it('returns empty string on garbage', () => {
    expect(decodeSymbol('0x')).toBe('');
  });
});

describe('helpers', () => {
  it('wordAt reads the nth 32-byte word', () => {
    const data = '0x' + toWord(7n) + toWord(9n);
    expect(wordAt(data, 0)).toBe(7n);
    expect(wordAt(data, 1)).toBe(9n);
  });
  it('addressFromTopic takes the low 20 bytes', () => {
    expect(addressFromTopic(addrTopic(A))).toBe(A);
  });
});

describe('hasWords', () => {
  const w = (n: number) => '0x' + '0'.repeat(64 * n);

  it('accepts a response carrying exactly the requested words', () => {
    expect(hasWords(w(1), 1)).toBe(true);
    expect(hasWords(w(12), 8)).toBe(true);
  });

  it('rejects an empty 0x response — the case wordAt would decode as 0n', () => {
    expect(hasWords('0x', 1)).toBe(false);
  });

  it('rejects a response one word short of what the ABI promises', () => {
    expect(hasWords(w(1), 2)).toBe(false);
    expect(hasWords(w(7), 8)).toBe(false);
  });

  // rpcCall types its return as T but hands back whatever `json.result` was, so an
  // absent or null result arrives here as undefined/null rather than a string. That is
  // the reason the parameter is `unknown` — decoding it would throw a TypeError deep in
  // wordAt and be logged as something else entirely.
  it('rejects a non-string result', () => {
    expect(hasWords(undefined, 1)).toBe(false);
    expect(hasWords(null, 1)).toBe(false);
    expect(hasWords(0, 1)).toBe(false);
  });
});
