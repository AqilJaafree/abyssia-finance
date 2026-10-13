export interface RawLog {
  address: string;
  topics: string[];
  data: string;
  blockNumber?: string; // hex block number from eth_getLogs (present at runtime)
  // Which transaction emitted this log. Present at runtime from eth_getLogs, and optional
  // here for the same reason blockNumber is: the swap decoders never needed it. The PnL
  // reader does — grouping a position's events BY TRANSACTION is what separates a fee
  // claim from a principal withdrawal (see pnl.ts).
  transactionHash?: string;
}

export interface DecodedSwap {
  sender: string;
  recipient: string;
  amount0: bigint;
  amount1: bigint;
  sqrtPriceX96: bigint;
}

// Does this eth_call result actually carry the words the ABI says it does?
//
// `wordAt` below returns 0n for a word that is not there, which is the right default for
// log decoding but a trap for contract reads: a node can answer 200 OK with `0x` — no
// return data, no JSON-RPC error, nothing for rpcCall to throw on — and the caller then
// gets a confident zero. On the LP money path that zero has meant "this wallet owns no
// positions", "this position has no liquidity", and "the pool's tick is 0", each of which
// spends real money on a fact nobody established.
//
// Length is the only thing separating a genuine zero (a full 32-byte word of zeroes) from
// silence, so callers that turn a read into a decision check it BEFORE decoding. It is a
// necessary condition, not a sufficient one — a response can be long enough and still be
// junk (revert data, for instance) — so it belongs with, not instead of, the range checks
// each caller already makes.
export function hasWords(data: unknown, n: number): data is string {
  return typeof data === 'string' && data.length >= 2 + n * 64;
}

// Read the nth 32-byte word of a 0x-prefixed hex blob as an unsigned bigint.
export function wordAt(data: string, index: number): bigint {
  const body = data.slice(2);
  const word = body.slice(index * 64, index * 64 + 64);
  return word.length ? BigInt('0x' + word) : 0n;
}

// Interpret an unsigned 256-bit word as a signed two's-complement int256.
export function toInt256(word: bigint): bigint {
  const MAX = 1n << 255n;
  const MOD = 1n << 256n;
  return word >= MAX ? word - MOD : word;
}

// A 32-byte topic/word -> checksum-agnostic lowercase address (low 20 bytes).
export function addressFromTopic(topic: string): string {
  return ('0x' + topic.slice(-40)).toLowerCase();
}

// The nth 32-byte word of `data` interpreted as an address.
export function addressAt(data: string, index: number): string {
  const body = data.slice(2);
  const word = body.slice(index * 64, index * 64 + 64);
  return ('0x' + word.slice(24)).toLowerCase();
}

export function decodeSwapLog(log: RawLog): DecodedSwap {
  return {
    sender: addressFromTopic(log.topics[1]),
    recipient: addressFromTopic(log.topics[2]),
    amount0: toInt256(wordAt(log.data, 0)),
    amount1: toInt256(wordAt(log.data, 1)),
    sqrtPriceX96: wordAt(log.data, 2),
  };
}

// Decode the return value of a `symbol()` eth_call (ABI string). Fallback ''.
export function decodeSymbol(result: string): string {
  try {
    const body = result.slice(2);
    if (body.length < 128) return '';
    const len = Number(BigInt('0x' + body.slice(64, 128)));
    const dataHex = body.slice(128, 128 + len * 2);
    return Buffer.from(dataHex, 'hex').toString('utf8');
  } catch {
    return '';
  }
}
