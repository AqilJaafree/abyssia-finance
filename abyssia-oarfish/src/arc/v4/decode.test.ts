import { describe, it, expect } from 'vitest';
import { decodeV4SwapLog, decodeV4InitializeLog } from './decode';
import { V4_SWAP_TOPIC0, V4_INITIALIZE_TOPIC0 } from './config';

function toWord(v: bigint): string {
  const mod = 1n << 256n;
  const u = ((v % mod) + mod) % mod;
  return u.toString(16).padStart(64, '0');
}
function addrTopic(a: string): string {
  return '0x' + a.slice(2).toLowerCase().padStart(64, '0');
}

const POOL_ID = '0xf16e5fc75dd3987c8cc25400a491c02459a43b98643082ee7bb5d21f106d443b';
const SENDER = '0x65050a9b7e5075a2ba5ced7b1b64ee66262c40dc';
const WETH = '0x0bd7d308f8e1639fab988df18a8011f41eacad73';
const TOKEN = '0x882f08f34083ca963200cbdc5767d61695120b07';

describe('decodeV4SwapLog', () => {
  it('decodes poolId, sender, signed int128 amounts, and per-swap fee', () => {
    const log = {
      address: '0xpoolmanager',
      topics: [V4_SWAP_TOPIC0, POOL_ID, addrTopic(SENDER)],
      data:
        '0x' +
        toWord(-1_000_000n) + // amount0 (int128, negative)
        toWord(500n) + // amount1
        toWord(79228162514264337593543950336n) + // sqrtPriceX96 = 2^96
        toWord(12345n) + // liquidity
        toWord(-100n) + // tick
        toWord(3000n), // fee (0.30%)
    };
    const d = decodeV4SwapLog(log);
    expect(d.poolId).toBe(POOL_ID);
    expect(d.sender).toBe(SENDER);
    expect(d.amount0).toBe(-1_000_000n);
    expect(d.amount1).toBe(500n);
    expect(d.sqrtPriceX96).toBe(79228162514264337593543950336n);
    expect(d.fee).toBe(3000n);
  });
});

describe('decodeV4InitializeLog', () => {
  it('decodes poolId and both indexed currencies', () => {
    const log = {
      address: '0xpoolmanager',
      topics: [V4_INITIALIZE_TOPIC0, POOL_ID, addrTopic(WETH), addrTopic(TOKEN)],
      data:
        '0x' +
        toWord(0x800000n) + // fee (dynamic-fee flag)
        toWord(200n) + // tickSpacing
        toWord(0n) + // hooks
        toWord(79228162514264337593543950336n) + // sqrtPriceX96
        toWord(0n), // tick
    };
    const d = decodeV4InitializeLog(log);
    expect(d.poolId).toBe(POOL_ID);
    expect(d.currency0).toBe(WETH);
    expect(d.currency1).toBe(TOKEN);
    expect(d.fee).toBe(0x800000n);
  });
});

describe('decodeV4InitializeLog — tickSpacing and hooks', () => {
  // Initialize(bytes32 id, address c0, address c1, uint24 fee, int24 tickSpacing,
  //            address hooks, uint160 sqrtPriceX96, int24 tick)
  // Data words: 0 fee, 1 tickSpacing, 2 hooks, 3 sqrtPriceX96, 4 tick.
  const USDG = '0x5fc5360d0400a0fd4f2af552add042d716f1d168';
  const AC = '0xac77646bcff9d52e99800534192e0290933f4094';

  const initLog = (fee: bigint, spacing: bigint, hooks: string) => ({
    address: '0x8366a39cc670b4001a1121b8f6a443a643e40951',
    topics: [V4_INITIALIZE_TOPIC0, POOL_ID, addrTopic(USDG), addrTopic(AC)],
    data:
      '0x' + toWord(fee) + toWord(spacing) +
      hooks.slice(2).toLowerCase().padStart(64, '0') +
      toWord(1n) + toWord(2n),
    blockNumber: '0x1',
    transactionHash: '0x' + '1'.padStart(64, '0'),
    logIndex: '0x0',
  });

  const ZERO = '0x0000000000000000000000000000000000000000';

  it('reads the real Robinhood-chain pool decoded from a live mint', () => {
    const d = decodeV4InitializeLog(initLog(27885n, 279n, ZERO));
    expect(d.fee).toBe(27885n);
    expect(d.tickSpacing).toBe(279);
    expect(d.hooks).toBe(ZERO);
    expect(d.currency0).toBe(USDG);
    expect(d.currency1).toBe(AC);
  });

  it('sign-extends a NEGATIVE tickSpacing rather than reading a huge positive', () => {
    // Nothing legitimate produces one, which is exactly why it must not read as ~1.6e7:
    // that would sail through a `> 0` check and align a range to a grid the pool has not
    // got. Read as -1 it fails the eligibility gate, which is the correct outcome.
    const d = decodeV4InitializeLog(initLog(3000n, -1n, ZERO));
    expect(d.tickSpacing).toBe(-1);
  });

  it('reads a non-zero hook address', () => {
    const hook = '0xe5e702641ea86f4ae6cc3cdaed2b886f976be044';
    expect(decodeV4InitializeLog(initLog(3000n, 60n, hook)).hooks).toBe(hook);
  });

  it('reads the dynamic-fee flag as itself, not as a rate', () => {
    expect(decodeV4InitializeLog(initLog(0x800000n, 60n, ZERO)).fee).toBe(0x800000n);
  });
});
