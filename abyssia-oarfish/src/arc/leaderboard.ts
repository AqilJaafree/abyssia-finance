import { PoolAggregate } from './swaps';

export interface RankedPool {
  pool: string;
  token: string;
  volumeWeth: bigint;
  swaps: number;
  traders: number;
  fees0: bigint;
  fees1: bigint;
}

export function rankTopN(
  aggregates: Map<string, PoolAggregate>,
  topN: number
): RankedPool[] {
  return [...aggregates.values()]
    .map((a) => ({
      pool: a.pool,
      token: a.token,
      volumeWeth: a.volumeWeth,
      swaps: a.swaps,
      traders: a.traders.size,
      fees0: a.fees0,
      fees1: a.fees1,
    }))
    .sort((x, y) =>
      y.volumeWeth > x.volumeWeth ? 1 : y.volumeWeth < x.volumeWeth ? -1 : 0
    )
    .slice(0, topN);
}
