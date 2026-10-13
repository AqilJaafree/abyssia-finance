// RSI is invariant to a positive constant scale factor, so token decimals are
// irrelevant here — only the raw price ratio in the correct orientation matters.
// price ratio (sqrtP/2^96)^2 = token1/token0 in raw base units.
const Q96 = 2 ** 96;

// Convert a pool's sqrtPriceX96 into a "quote per token" price series value.
// tokenIsToken0: is the tracked (non-anchor) token currency0 of the pool?
export function sqrtPriceToSeriesValue(
  sqrtPriceX96: bigint,
  tokenIsToken0: boolean
): number {
  const s = Number(sqrtPriceX96) / Q96;
  const ratio = s * s; // token1 / token0
  return tokenIsToken0 ? ratio : 1 / ratio;
}
