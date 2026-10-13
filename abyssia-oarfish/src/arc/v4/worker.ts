import { logger } from '../../logger';
import * as rpc from '../rpc';
import { decodeSymbol } from '../decode';
import { SEL_SYMBOL, MCAP_MAX_LOOKUPS, ARC_USDC_DECIMALS } from '../config';
import { decodeV4SwapLog } from './decode';
import { aggregateV4Swaps, rankV4TopN } from './swaps';
import { resolveV4PoolMeta, V4PoolMeta, RepairBudget } from './metadata';
import { loadV4State, saveV4State, V4MoversState } from './state';
import { sendMoversBoardV4, postDangerZoneBoard } from '../../telegram/sender';
import { formatFeeTier } from '../../telegram/format';
import { MoversRow } from '../../types';
import {
  V4_POOL_MANAGER, V4_SWAP_TOPIC0, V4_TOP_N, V4_MAX_LOOKBACK_BLOCKS,
  V4_META_REPAIR_PER_CYCLE, V4_META_REPAIR_MAX_MS,
} from './config';
import { sqrtPriceToSeriesValue } from '../price';
import { recordSwapPrice } from '../candles';
import { rsiForSeries } from '../rsi-tag';
import { resolveTokenMeta, computeFdvUsd } from '../onchain-mcap';
import { selectByMarketCap } from '../mcap-select';
import { resolveVerification } from '../verification';

import { Strategy } from '../../strategy';

let stateFile = '';
let strategy: Strategy;
let state: V4MoversState;

export function initMoversV4(file: string, cfg: Strategy): void {
  stateFile = file;
  strategy = cfg;
  state = loadV4State(file);
}

async function resolveSymbol(token: string): Promise<string> {
  const cached = state.symbols[token];
  if (cached) return cached;
  try {
    const decoded = decodeSymbol(await rpc.call(token, SEL_SYMBOL));
    if (decoded) {
      state.symbols[token] = decoded;
      return decoded;
    }
  } catch (err) {
    logger.warn({ err, token }, 'movers-v4: symbol() failed, using address fallback');
  }
  return token.slice(0, 8);
}

let cycleRunning = false;

// USDC is already the USD unit — no anchor-to-USD lookup needed.
const ANCHOR_USD = 1;

export async function moversCycleV4(): Promise<void> {
  if (cycleRunning) {
    logger.warn('movers-v4: previous cycle still running, skipping this tick');
    return;
  }
  cycleRunning = true;
  try {
    const currentBlock = await rpc.blockNumber();

    let fromBlock = state.lastProcessedBlock + 1;
    if (
      state.lastProcessedBlock === 0 ||
      currentBlock - state.lastProcessedBlock > V4_MAX_LOOKBACK_BLOCKS
    ) {
      fromBlock = Math.max(1, currentBlock - V4_MAX_LOOKBACK_BLOCKS + 1);
      if (state.lastProcessedBlock > 0 && fromBlock > state.lastProcessedBlock + 1) {
        logger.warn(
          { skippedFrom: state.lastProcessedBlock + 1, resumedFrom: fromBlock },
          'movers-v4: downtime clamp, skipping blocks'
        );
      }
    }
    if (currentBlock < fromBlock) {
      saveV4State(stateFile, state);
      return;
    }

    const logs = await rpc.getLogs({
      address: [V4_POOL_MANAGER], topics: [V4_SWAP_TOPIC0], fromBlock, toBlock: currentBlock,
    });
    const usable = logs.filter((log) => log.topics.length >= 3);
    if (usable.length !== logs.length) {
      logger.warn({ dropped: logs.length - usable.length }, 'movers-v4: skipped malformed Swap logs');
    }
    const decoded = usable.map((log) => ({
      poolId: log.topics[1],
      swap: decodeV4SwapLog(log),
      block: log.blockNumber ? Number(BigInt(log.blockNumber)) : 0,
    }));

    const repair: RepairBudget = { left: V4_META_REPAIR_PER_CYCLE };
    const repairDeadline = Date.now() + V4_META_REPAIR_MAX_MS;
    const metaById = new Map<string, V4PoolMeta>();
    for (const poolId of new Set(decoded.map((d) => d.poolId))) {
      if (repair.left > 0 && Date.now() > repairDeadline) repair.left = 0;
      const meta = await resolveV4PoolMeta(poolId, state.registry, rpc.getLogs, currentBlock, undefined, repair);
      if (meta) metaById.set(poolId, meta);
    }
    if (repair.deferred || repair.failed) {
      logger.info(
        { deferred: repair.deferred ?? 0, failed: repair.failed ?? 0, spent: V4_META_REPAIR_PER_CYCLE - repair.left },
        'movers-v4: pool metadata still being repaired'
      );
    }

    const aggregates = aggregateV4Swaps(decoded, metaById);
    if (aggregates.size === 0) {
      state.lastProcessedBlock = currentBlock;
      saveV4State(stateFile, state);
      logger.info({ fromBlock, currentBlock }, 'movers-v4: no USDC swaps in window, skipping post');
      return;
    }

    for (const [poolId, agg] of aggregates) {
      if (agg.lastSqrtPriceX96 <= 0n) continue;
      const m = metaById.get(poolId)!;
      const price = sqrtPriceToSeriesValue(agg.lastSqrtPriceX96, !m.ethIsCurrency0);
      recordSwapPrice(
        state.candles, poolId, Math.floor(agg.lastBlock / strategy.blocksPerCandle), price, strategy.maxCloses
      );
    }

    const ranked = rankV4TopN(aggregates, aggregates.size);
    const selection = await selectByMarketCap(
      ranked,
      async (r) => {
        const agg = aggregates.get(r.poolId);
        const meta = metaById.get(r.poolId);
        if (!agg || !meta) return undefined;
        const tm = await resolveTokenMeta(r.token, state.supplies, state.suppliesCheckedAt, rpc.call);
        if (!tm) return undefined;
        return computeFdvUsd({
          supply: tm.supply,
          tokenDecimals: tm.decimals,
          sqrtPriceX96: agg.lastSqrtPriceX96,
          tokenIsToken0: !meta.ethIsCurrency0,
          anchorDecimals: ARC_USDC_DECIMALS,
          anchorUsd: ANCHOR_USD,
        });
      },
      { minUsd: strategy.minMarketCapUsd, perGroup: V4_TOP_N, maxLookups: MCAP_MAX_LOOKUPS }
    );
    if (selection.capped) {
      logger.warn(
        { lookups: selection.lookups, main: selection.main.length, danger: selection.danger.length },
        'movers-v4: market-cap lookup ceiling reached, board may be incomplete'
      );
    }

    const buildRows = async (picked: typeof selection.main): Promise<MoversRow[]> => {
      const out: MoversRow[] = [];
      for (const r of picked) {
        const meta = metaById.get(r.poolId)!;
        const feeTier = meta.fee >= 0x800000 ? 'dynamic' : formatFeeTier(meta.fee);
        const candle = state.candles[r.poolId];
        const series = candle ? [...candle.closes, candle.close] : [];
        const tag = r.volumeEth >= strategy.rsiMinVolumeUsdc ? rsiForSeries(series, strategy.rsi) : undefined;
        const verification = await resolveVerification(r.token, state.verified, state.verifiedCheckedAt);
        out.push({
          pool: r.poolId,
          token: r.token,
          symbol: await resolveSymbol(r.token),
          volumeWeth: r.volumeEth,
          swaps: r.swaps,
          traders: r.traders,
          feesWeth: r.feesEth,
          feeTier,
          rsi: tag?.rsi,
          rsiLabel: tag?.label,
          marketCapUsd: r.marketCapUsd,
          verified: verification ? verification.verified && verification.isErc20 : undefined,
          lookalike: verification?.lookalike,
        });
      }
      return out;
    };
    const mainRows = await buildRows(selection.main);
    const dangerRows = await buildRows(selection.danger);

    if (mainRows.length >= 1) {
      await sendMoversBoardV4({ rows: mainRows, block: currentBlock, fromBlock });
    }
    if (dangerRows.length >= 1) {
      await postDangerZoneBoard({
        rows: dangerRows, block: currentBlock, fromBlock, variant: 'danger', label: 'Uniswap v4',
      });
    }
    state.lastProcessedBlock = currentBlock;
    saveV4State(stateFile, state);
    logger.info(
      { main: mainRows.length, danger: dangerRows.length, lookups: selection.lookups, fromBlock, currentBlock },
      'movers-v4: cycle posted'
    );
  } catch (err) {
    logger.error({ err }, 'movers-v4: cycle error');
  } finally {
    cycleRunning = false;
  }
}
