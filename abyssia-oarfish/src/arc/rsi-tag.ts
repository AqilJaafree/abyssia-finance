import { computeRSI } from '../engine/rsi';
import { RsiStrategy } from '../strategy';

export interface RsiTag {
  rsi: number;
  label?: 'oversold' | 'overbought';
}

// RSI needs period + 1 closes before it is meaningful. Below that, the row
// shows "warming up" rather than a fabricated value.
export function rsiMinSamples(cfg: RsiStrategy): number {
  return cfg.period + 1;
}

// Undefined => not enough history yet (render as "RSI —").
export function rsiForSeries(series: number[], cfg: RsiStrategy): RsiTag | undefined {
  if (series.length < rsiMinSamples(cfg)) return undefined;
  // A perfectly flat series has no gains and no losses; computeRSI's avgLoss===0
  // short-circuit would otherwise report 100 (overbought) for zero movement.
  if (series.every((v) => v === series[0])) return { rsi: 50 };
  const rsi = Math.round(computeRSI(series, cfg.period));
  const label = rsi < cfg.oversold ? 'oversold' : rsi > cfg.overbought ? 'overbought' : undefined;
  return { rsi, label };
}
