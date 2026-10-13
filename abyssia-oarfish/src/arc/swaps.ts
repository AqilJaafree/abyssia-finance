import { DecodedSwap } from './decode';

export interface PoolMeta {
  pool: string; // lowercase pool address
  token: string; // non-WETH token address
  fee: number; // fee tier in hundredths of a bip (e.g. 3000 = 0.30%)
  wethIsToken0: boolean;
}

export interface PoolAggregate {
  pool: string;
  token: string;
  volumeWeth: bigint;
  swaps: number;
  traders: Set<string>;
  fees0: bigint;
  fees1: bigint;
  lastSqrtPriceX96: bigint; // sqrtPriceX96 of the most recent swap in the window
  lastBlock: number; // block of the most recent swap in the window
}

export function abs(x: bigint): bigint {
  return x < 0n ? -x : x;
}

export function aggregateSwaps(
  decoded: { pool: string; swap: DecodedSwap; block?: number }[],
  metaByPool: Map<string, PoolMeta>
): Map<string, PoolAggregate> {
  const out = new Map<string, PoolAggregate>();
  for (const { pool, swap, block } of decoded) {
    const meta = metaByPool.get(pool);
    if (!meta) continue;
    let agg = out.get(pool);
    if (!agg) {
      agg = {
        pool,
        token: meta.token,
        volumeWeth: 0n,
        swaps: 0,
        traders: new Set<string>(),
        fees0: 0n,
        fees1: 0n,
        lastSqrtPriceX96: 0n,
        lastBlock: 0,
      };
      out.set(pool, agg);
    }
    const wethAmt = meta.wethIsToken0 ? swap.amount0 : swap.amount1;
    agg.volumeWeth += abs(wethAmt);
    agg.swaps += 1;
    agg.traders.add(swap.recipient);
    agg.lastSqrtPriceX96 = swap.sqrtPriceX96; // last swap in block/log order wins
    agg.lastBlock = block ?? 0; // last swap in block/log order wins
    const feePips = BigInt(meta.fee);
    // Fee is taken from the input (positive) side of the swap.
    if (swap.amount0 > 0n) agg.fees0 += (swap.amount0 * feePips) / 1_000_000n;
    if (swap.amount1 > 0n) agg.fees1 += (swap.amount1 * feePips) / 1_000_000n;
  }
  return out;
}

const Q192 = 1n << 192n;

// Value both fee sides in WETH wei using the pool's spot price (sqrtPriceX96).
// price = (sqrtP/2^96)^2 = token1/token0 in raw base units.
export function feesToWeth(
  fees0: bigint,
  fees1: bigint,
  sqrtPriceX96: bigint,
  wethIsToken0: boolean
): bigint {
  const p2 = sqrtPriceX96 * sqrtPriceX96;
  if (wethIsToken0) {
    // WETH = token0. token1 fees valued as fees1 / price = fees1 * 2^192 / p2.
    const fromToken1 = p2 === 0n ? 0n : (fees1 * Q192) / p2;
    return fees0 + fromToken1;
  }
  // WETH = token1. token0 fees valued as fees0 * price = fees0 * p2 / 2^192.
  const fromToken0 = (fees0 * p2) / Q192;
  return fees1 + fromToken0;
}
