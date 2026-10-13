import { MoversBoard, MoversRow } from '../types';
import { ARC_USDC_DECIMALS } from '../arc/config';

const MEDALS = ['🥇', '🥈', '🥉', '4️⃣', '5️⃣'];

// Arc's block explorer (Arcscan). Env-overridable. Verified live 2026-09-16
// against the real mainnet: arc-scan.io does not resolve at all (unregistered
// domain) despite looking like the obvious guess; docs.arc-scan.org is the
// actual working explorer (odd subdomain, but /token/<address> resolves real
// tokens, e.g. USDC's page renders correctly under chain id 5042).
const EXPLORER_BASE = (
  process.env.ARC_EXPLORER_BASE ?? 'https://docs.arc-scan.org'
).replace(/\/$/, '');

// GMGN's Arc chart page, linked beside the explorer on every board row — same
// treatment as nautilus's Robinhood-chain boards. Verified live 2026-09-16
// that gmgn.ai serves a real page (HTTP 200) under the "arc" chain slug.
const GMGN_TOKEN_BASE = 'https://gmgn.ai/arc/token';

function htmlEscape(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// 0x1f7d…2efa
function shortAddr(a: string): string {
  return a.length > 12 ? `${a.slice(0, 6)}…${a.slice(-4)}` : a;
}

// Convert USDC base units (bigint, ARC_USDC_DECIMALS) to an abbreviated $ string.
export function formatUsdcUnits(baseUnits: bigint, decimals = 6): string {
  const neg = baseUnits < 0n;
  const v = neg ? -baseUnits : baseUnits;
  const base = 10n ** BigInt(decimals);
  const usd = Number(v) / Number(base);
  return `${neg ? '-' : ''}${formatUsd(usd)}`;
}

// Abbreviate a USD amount: $1.3M, $128.4K, $256, $0.05.
export function formatUsd(n: number): string {
  const abs = Math.abs(n);
  if (abs >= 1e6) return `$${(n / 1e6).toFixed(1)}M`;
  if (abs >= 1e3) return `$${(n / 1e3).toFixed(1)}K`;
  if (abs >= 1) return `$${n.toFixed(0)}`;
  return `$${n.toFixed(2)}`;
}

// Format a Uniswap fee tier (pips = hundredths of a bip; 3000 -> "0.3%").
export function formatFeeTier(pips: number): string {
  return `${parseFloat((pips / 10000).toFixed(4))}%`;
}

// Compact RSI tag for a board row.
export function formatRsiTag(
  rsi: number | undefined,
  label: 'oversold' | 'overbought' | undefined
): string {
  if (rsi == null) return 'RSI —';
  const badge =
    label === 'oversold' ? ' 🟢 Oversold' : label === 'overbought' ? ' 🔴 Overbought' : '';
  return `RSI ${Math.round(rsi)}${badge}`;
}

// Compact market-cap tag for a board row.
export function formatMarketCap(usd: number | undefined): string {
  if (usd == null) return 'MC —';
  if (usd > 0 && usd < 1) return 'MC <$1';
  return `MC ${formatUsd(usd)}`;
}

// Verification badge right after the symbol: ✅ verified (and a standard
// ERC-20, per Arcscan's own classification) / ⚠️ unverified / 🚨 flagged as
// an unverified lookalike or reserved-name squatter. The lookalike flag
// takes priority over everything else — it can fire even on an otherwise
// "verified" contract (verified source, but still copying a real token's
// name), and that is a worse signal than plain unverified.
//
// Renders nothing when the lookup failed or hasn't completed this cycle
// (verified undefined) — an absent badge means "retrying", not "unverified".
// This is contract-verification status only, not a heuristic risk scan
// (mint/blacklist/tax detection); a ✅ here means the source code is public
// and Arcscan agrees it's a standard token, not that the code is safe.
export function formatVerificationBadge(
  verified: boolean | undefined,
  lookalike: boolean | undefined
): string {
  if (lookalike) return ' 🚨';
  if (verified === undefined) return '';
  return verified ? ' ✅' : ' ⚠️';
}

function renderMoversRows(board: MoversBoard): string[] {
  return board.rows.map((r: MoversRow, i) => {
    const medal = MEDALS[i] ?? `${i + 1}.`;
    const tier = r.feeTier ? ` (${r.feeTier})` : '';
    const link =
      `<a href="${EXPLORER_BASE}/token/${r.token}">${shortAddr(r.token)}</a>` +
      ` · <a href="${GMGN_TOKEN_BASE}/${r.token}">GMGN</a>`;
    return (
      `${medal} <b>${htmlEscape(r.symbol)}</b>${formatVerificationBadge(r.verified, r.lookalike)}${tier} · ${formatRsiTag(r.rsi, r.rsiLabel)} · ${formatMarketCap(r.marketCapUsd)}\n` +
      `    ${formatUsdcUnits(r.volumeWeth, ARC_USDC_DECIMALS)} vol · ${r.swaps} swaps · ${r.traders} traders · ${formatUsdcUnits(r.feesWeth, ARC_USDC_DECIMALS)} fees\n` +
      `    ↳ ${link}`
    );
  });
}

function formatBoard(title: string, board: MoversBoard): string {
  return [
    title,
    `<i>last ~60s · block ${board.block.toLocaleString('en-US')}</i>`,
    '',
    renderMoversRows(board).join('\n\n'),
  ].join('\n');
}

export function formatMoversBoard(board: MoversBoard): string {
  return formatBoard('🏆 <b>Arc Uniswap v3 — USDC Top Movers</b>', board);
}

export function formatMoversBoardV4(board: MoversBoard): string {
  return formatBoard('🦄 <b>Arc Uniswap v4 — USDC Top Movers</b>', board);
}

// Shared Danger Zone board — sub-threshold and unknown-market-cap tokens from
// both boards land in one topic, so the header carries the origin label.
export function formatDangerZoneBoard(board: MoversBoard): string {
  return formatBoard(`⚠️ <b>Danger Zone — ${htmlEscape(board.label ?? 'Uniswap')}</b>`, board);
}

// Legend the bot replies with on /help.
export function formatHelpMessage(): string {
  return [
    '📖 <b>How to read a Top Movers row</b>',
    '',
    '<code>🥇 DOPP ✅ (0.3%) · RSI 55 · MC $1.2M</code>',
    '<code>    $12.4K vol · 88 swaps · 41 traders · $37 fees</code>',
    '<code>    ↳ 0xc236…4ba3 · GMGN</code>',
    '',
    '<b>Badge after the symbol</b> — Arcscan contract verification: ✅ verified &amp; standard ERC-20 · ⚠️ unverified · 🚨 flagged as an unverified lookalike or name-squatter (e.g. impersonating USDC/WETH) · (no badge) lookup retrying.',
    'This is verification only, not a safety audit — ✅ means the source code is public and looks like a standard token, not that it is safe. 🚨 overrides ✅/⚠️: a lookalike can still have "verified" source. Always check the address on the last line.',
    '',
    '<b>RSI</b> — momentum on fixed-width candles:',
    '🟢 Oversold · 🔴 Overbought · <code>RSI —</code> warming up',
    '',
    '<b>Numbers</b> (latest ~1–2 min): vol = volume · swaps = trades · traders = unique wallets · fees = pool fees, all in USDC.',
    '',
    '<b>MC</b> — market cap. Tokens below the board\'s market-cap floor move off this board into the <b>⚠️ Danger Zone</b> topic, as does any token whose cap cannot be read (<code>MC —</code>).',
    'Computed on-chain: <b>total</b> supply × the token\'s price in its pool — a token with locked or vested supply reads higher here than its true circulating cap.',
    '',
    '<b>Last line</b> — the token address links to the explorer; <b>GMGN</b> beside it opens the same contract on gmgn.ai.',
    '',
    '⚠️ Not financial advice. Always verify the contract address on the last line — the same symbol can be many different contracts.',
  ].join('\n');
}
