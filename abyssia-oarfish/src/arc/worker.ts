import { logger } from '../logger';
import * as rpc from './rpc';
import { decodeSwapLog, decodeSymbol, wordAt } from './decode';
import { aggregateSwaps, feesToWeth, PoolMeta } from './swaps';
import { rankTopN } from './leaderboard';
import { resolvePoolMeta } from './metadata';
import { loadState, saveState, MoversState } from './state';
import { sendMoversBoard, postDangerZoneBoard } from '../telegram/sender';
import { formatFeeTier } from '../telegram/format';
import { MoversRow } from '../types';
import {
  SWAP_TOPIC0, SEL_SLOT0, SEL_SYMBOL, TOP_N, MAX_LOOKBACK_BLOCKS,
  MCAP_MAX_LOOKUPS,
  ARC_USDC_DECIMALS,
} from './config';
import { sqrtPriceToSeriesValue } from './price';
import { recordSwapPrice } from './candles';
import { rsiForSeries } from './rsi-tag';
import { resolveTokenMeta, computeFdvUsd } from './onchain-mcap';
import { selectByMarketCap } from './mcap-select';
import { resolveVerification } from './verification';

import { Strategy } from '../strategy';

let stateFile = '';
let strategy: Strategy;
let state: MoversState;

export function initMovers(file: string, cfg: Strategy): void {
  stateFile = file;
  strategy = cfg;
  state = loadState(file);
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
    logger.warn({ err, token }, 'movers: symbol() failed, using address fallback');
  }
  return token.slice(0, 8);
}

let cycleRunning = false;

// USDC is already the USD unit — there is no WETH/USDG-style anchor-to-USD
// lookup to perform, unlike nautilus's Robinhood-chain boards.
const ANCHOR_USD = 1;

export async function moversCycle(): Promise<void> {
  if (cycleRunning) {
    logger.warn('movers: previous cycle still running, skipping this tick');
    return;
  }
  cycleRunning = true;
  try {
    const currentBlock = await rpc.blockNumber();

    let fromBlock = state.lastProcessedBlock + 1;
    if (
      state.lastProcessedBlock === 0 ||
      currentBlock - state.lastProcessedBlock > MAX_LOOKBACK_BLOCKS
    ) {
      fromBlock = Math.max(1, currentBlock - MAX_LOOKBACK_BLOCKS + 1);
      if (state.lastProcessedBlock > 0 && fromBlock > state.lastProcessedBlock + 1) {
        logger.warn(
          { skippedFrom: state.lastProcessedBlock + 1, resumedFrom: fromBlock },
          'movers: downtime clamp, skipping blocks'
        );
      }
    }
    if (currentBlock < fromBlock) {
      saveState(stateFile, state);
      return;
    }

    const logs = await rpc.getLogs({ topics: [SWAP_TOPIC0], fromBlock, toBlock: currentBlock });
    const usable = logs.filter((log) => log.topics.length >= 3);
    if (usable.length !== logs.length) {
      logger.warn({ dropped: logs.length - usable.length }, 'movers: skipped malformed Swap logs');
    }
    const decoded = usable.map((log) => ({
      pool: log.address.toLowerCase(),
      swap: decodeSwapLog(log),
      block: log.blockNumber ? Number(BigInt(log.blockNumber)) : 0,
    }));

    const metaByPool = new Map<string, PoolMeta>();
    for (const pool of new Set(decoded.map((d) => d.pool))) {
      const meta = await resolvePoolMeta(pool, state.meta, rpc.call);
      if (meta) metaByPool.set(pool, meta);
    }

    const aggregates = aggregateSwaps(decoded, metaByPool);
    if (aggregates.size === 0) {
      state.lastProcessedBlock = currentBlock;
      saveState(stateFile, state);
      logger.info({ fromBlock, currentBlock }, 'movers: no USDC swaps in window, skipping post');
      return;
    }

    for (const [pool, agg] of aggregates) {
      if (agg.lastSqrtPriceX96 <= 0n) continue;
      const m = metaByPool.get(pool)!;
      const price = sqrtPriceToSeriesValue(agg.lastSqrtPriceX96, !m.wethIsToken0);
      const bucket = Math.floor(agg.lastBlock / strategy.blocksPerCandle);
      recordSwapPrice(state.candles, pool, bucket, price, strategy.maxCloses);
    }

    const ranked = rankTopN(aggregates, aggregates.size);
    const selection = await selectByMarketCap(
      ranked,
      async (r) => {
        const agg = aggregates.get(r.pool);
        const meta = metaByPool.get(r.pool);
        if (!agg || !meta) return undefined;
        const tm = await resolveTokenMeta(r.token, state.supplies, state.suppliesCheckedAt, rpc.call);
        if (!tm) return undefined;
        return computeFdvUsd({
          supply: tm.supply,
          tokenDecimals: tm.decimals,
          sqrtPriceX96: agg.lastSqrtPriceX96,
          tokenIsToken0: !meta.wethIsToken0,
          anchorDecimals: ARC_USDC_DECIMALS,
          anchorUsd: ANCHOR_USD,
        });
      },
      { minUsd: strategy.minMarketCapUsd, perGroup: TOP_N, maxLookups: MCAP_MAX_LOOKUPS }
    );
    if (selection.capped) {
      logger.warn(
        { lookups: selection.lookups, main: selection.main.length, danger: selection.danger.length },
        'movers: market-cap lookup ceiling reached, board may be incomplete'
      );
    }

    const buildRows = async (picked: typeof selection.main): Promise<MoversRow[]> => {
      const out: MoversRow[] = [];
      for (const r of picked) {
        const meta = metaByPool.get(r.pool)!;
        let feesWeth = 0n;
        try {
          const sqrtPriceX96 = wordAt(await rpc.call(r.pool, SEL_SLOT0), 0);
          feesWeth = feesToWeth(r.fees0, r.fees1, sqrtPriceX96, meta.wethIsToken0);
        } catch (err) {
          logger.warn({ err, pool: r.pool }, 'movers: slot0 fee valuation failed');
        }
        const candle = state.candles[r.pool];
        const series = candle ? [...candle.closes, candle.close] : [];
        const tag = r.volumeWeth >= strategy.rsiMinVolumeUsdc ? rsiForSeries(series, strategy.rsi) : undefined;
        const verification = await resolveVerification(r.token, state.verified, state.verifiedCheckedAt);
        out.push({
          pool: r.pool,
          token: r.token,
          symbol: await resolveSymbol(r.token),
          volumeWeth: r.volumeWeth,
          swaps: r.swaps,
          traders: r.traders,
          feesWeth,
          feeTier: formatFeeTier(meta.fee),
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
      await sendMoversBoard({ rows: mainRows, block: currentBlock, fromBlock });
    }
    if (dangerRows.length >= 1) {
      await postDangerZoneBoard({
        rows: dangerRows, block: currentBlock, fromBlock, variant: 'danger', label: 'Uniswap v3',
      });
    }
    state.lastProcessedBlock = currentBlock;
    saveState(stateFile, state);
    logger.info(
      { main: mainRows.length, danger: dangerRows.length, lookups: selection.lookups, fromBlock, currentBlock },
      'movers: cycle posted'
    );
  } catch (err) {
    logger.error({ err }, 'movers: cycle error');
  } finally {
    cycleRunning = false;
  }
}
