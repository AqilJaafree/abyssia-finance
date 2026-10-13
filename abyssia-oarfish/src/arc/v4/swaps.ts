import { DecodedV4Swap } from './decode';
import { V4PoolMeta } from './metadata';

export interface V4PoolAggregate {
  poolId: string;
  token: string;
  volumeEth: bigint; // Σ |ETH-leg amount| over the window, in wei
  swaps: number;
  traders: Set<string>;
  feesEth: bigint; // Σ |ETH-leg amount| * eventFee / 1e6 (fee as a fraction of notional)
  lastSqrtPriceX96: bigint; // sqrtPriceX96 of the most recent swap in the window
  lastBlock: number; // block of the most recent swap in the window
}

export function abs(x: bigint): bigint {
  return x < 0n ? -x : x;
}

// v4 amounts are int128 with a sign convention we don't rely on: the ETH-leg
// notional is |amount|, which is correct whether ETH is the input or output side.
// The per-swap fee comes straight from the Swap event (word 5), so dynamic-fee
// pools value correctly with no extra RPC. Fee value ≈ notional * fee/1e6 (fee is
// charged on the input, whose value equals the ETH-leg notional either way).
export function aggregateV4Swaps(
  decoded: { poolId: string; swap: DecodedV4Swap; block?: number }[],
  metaById: Map<string, V4PoolMeta>
): Map<string, V4PoolAggregate> {
  const out = new Map<string, V4PoolAggregate>();
  for (const { poolId, swap, block } of decoded) {
    const meta = metaById.get(poolId);
    if (!meta) continue;
    let agg = out.get(poolId);
    if (!agg) {
      agg = {
        poolId,
        token: meta.token,
        volumeEth: 0n,
        swaps: 0,
        traders: new Set<string>(),
        feesEth: 0n,
        lastSqrtPriceX96: 0n,
        lastBlock: 0,
      };
      out.set(poolId, agg);
    }
    const ethAmt = abs(meta.ethIsCurrency0 ? swap.amount0 : swap.amount1);
    agg.volumeEth += ethAmt;
    agg.swaps += 1;
    agg.traders.add(swap.sender);
    agg.lastSqrtPriceX96 = swap.sqrtPriceX96; // last swap in block/log order wins
    agg.lastBlock = block ?? 0; // last swap in block/log order wins
    // A real v4 swap fee is a pip value < 1e6. Guard against the 0x800000 dynamic
    // flag ever leaking through so it can't be mistaken for a 838% fee.
    if (swap.fee < 1_000_000n) agg.feesEth += (ethAmt * swap.fee) / 1_000_000n;
  }
  return out;
}

export interface V4RankedPool {
  poolId: string;
  token: string;
  volumeEth: bigint;
  swaps: number;
  traders: number;
  feesEth: bigint;
}

export function rankV4TopN(
  aggregates: Map<string, V4PoolAggregate>,
  topN: number
): V4RankedPool[] {
  return [...aggregates.values()]
    .map((a) => ({
      poolId: a.poolId,
      token: a.token,
      volumeEth: a.volumeEth,
      swaps: a.swaps,
      traders: a.traders.size,
      feesEth: a.feesEth,
    }))
    .sort((x, y) =>
      y.volumeEth > x.volumeEth ? 1 : y.volumeEth < x.volumeEth ? -1 : 0
    )
    .slice(0, topN);
}
