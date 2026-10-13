// v4 log decoders. Reuses the v3 word/address helpers — the ABI word layout is
// identical, only the event shapes differ.
import { RawLog, wordAt, toInt256, addressFromTopic, addressAt } from '../decode';

export interface DecodedV4Swap {
  poolId: string; // bytes32 pool identifier (topics[1], kept as 0x-hex)
  sender: string; // swapper (topics[2]); v4 has no separate recipient
  amount0: bigint; // int128 currency0 delta (sign-extended in its 32-byte word)
  amount1: bigint; // int128 currency1 delta
  sqrtPriceX96: bigint;
  fee: bigint; // uint24 pips actually charged on this swap (dynamic pools resolve here)
}

// v4 Swap data words: [amount0, amount1, sqrtPriceX96, liquidity, tick, fee].
export function decodeV4SwapLog(log: RawLog): DecodedV4Swap {
  return {
    poolId: log.topics[1],
    sender: addressFromTopic(log.topics[2]),
    amount0: toInt256(wordAt(log.data, 0)),
    amount1: toInt256(wordAt(log.data, 1)),
    sqrtPriceX96: wordAt(log.data, 2),
    fee: wordAt(log.data, 5),
  };
}

export interface DecodedV4Initialize {
  poolId: string; // topics[1]
  currency0: string; // topics[2] (indexed) — address(0) for native ETH
  currency1: string; // topics[3] (indexed)
  fee: bigint; // data word 0 — may be the 0x800000 dynamic-fee flag, not a literal rate
  // Data word 1. A v4 pool's tick spacing is CHOSEN AT CREATION and bears no relation to
  // its fee — nothing may infer one from the other, so it's captured straight from the
  // Initialize event rather than a fee-tier lookup table.
  tickSpacing: number;
  // Data word 2. address(0) means no hook. Anything else is arbitrary code running on
  // every mint, swap and burn in that pool.
  hooks: string;
}

export function decodeV4InitializeLog(log: RawLog): DecodedV4Initialize {
  return {
    poolId: log.topics[1],
    currency0: addressFromTopic(log.topics[2]),
    currency1: addressFromTopic(log.topics[3]),
    fee: wordAt(log.data, 0),
    // int24, stored SIGN-EXTENDED into a full word. Read as an unsigned bigint a negative
    // spacing becomes ~1.6e7, which would pass a `> 0` check and align a range to a grid
    // the pool does not have.
    tickSpacing: Number(toInt256(wordAt(log.data, 1))),
    hooks: addressAt(log.data, 2),
  };
}
