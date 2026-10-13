// --- Arc Uniswap v3/v4 USDC Top Movers boards ---
export interface MoversRow {
  pool: string;        // pool address (v3) or bytes32 poolId (v4), lowercase
  token: string;        // non-USDC token address (lowercase)
  symbol: string;        // resolved token symbol (or short address fallback)
  volumeWeth: bigint;    // Σ |USDC-side amount| over the window, in USDC base units (6dp)
  swaps: number;         // number of Swap events
  traders: number;       // unique trader addresses
  feesWeth: bigint;      // fees generated, valued in USDC base units
  feeTier?: string;      // pool fee tier for display, e.g. "0.3%" or "dynamic"
  rsi?: number;                           // RSI on strategy-sized candles; undefined = warming up
  rsiLabel?: 'oversold' | 'overbought';   // extreme label, if any
  // Total-supply x pool-price FDV in USD. undefined = no cap known -> Danger Zone.
  marketCapUsd?: number;
  // Arcscan contract-verification status, folded together with Arcscan's own
  // standard.erc20 classification: true only when BOTH the contract is
  // verified AND Arcscan classifies it as a standard ERC-20. undefined =
  // lookup failed/retrying this cycle -> no badge rendered, distinct from a
  // settled true/false.
  verified?: boolean;
  // True when Arcscan flags this token as an unverified lookalike or as
  // name-squatting a reserved name (e.g. impersonating "USDC"/"WETH") — a
  // scam-token signal independent of `verified` (a lookalike can itself be
  // "verified" while still copying a real token's name).
  lookalike?: boolean;
}

export interface MoversBoard {
  rows: MoversRow[];   // top N, sorted by volume desc
  block: number;        // toBlock of this window
  fromBlock: number;
  // Which board this is. 'danger' renders the Danger Zone header and posts to the
  // shared DANGER_ZONE_TOPIC_ID instead of the board's own topic.
  variant?: 'main' | 'danger';
  // Origin label for the Danger Zone header, e.g. "Uniswap v3". Both boards share
  // one Danger Zone topic, so each message has to say where it came from.
  label?: string;
}
