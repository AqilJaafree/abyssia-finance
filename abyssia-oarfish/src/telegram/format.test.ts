import { describe, it, expect } from 'vitest';
import {
  formatMoversBoard, formatMoversBoardV4, formatDangerZoneBoard, formatHelpMessage,
  formatFeeTier, formatRsiTag, formatMarketCap, formatUsd, formatUsdcUnits,
  formatVerificationBadge,
} from './format';
import { MoversBoard, MoversRow } from '../types';

const row = (over: Partial<MoversRow> = {}): MoversRow => ({
  pool: '0xp1',
  token: '0x1f7d7550b1b028f7571e69a784071f0205fd2efa',
  symbol: 'WORTH',
  volumeWeth: 12_400_000_000n, // 12,400 USDC (6dp)
  swaps: 34,
  traders: 21,
  feesWeth: 124_000_000n, // 124 USDC
  ...over,
});

describe('formatMoversBoard', () => {
  it('renders medal, symbol, and all four metrics in USDC', () => {
    const board: MoversBoard = { fromBlock: 1000, block: 1234567, rows: [row({ feeTier: '0.3%' })] };
    const msg = formatMoversBoard(board);
    expect(msg).toContain('Arc Uniswap v3 — USDC Top Movers');
    expect(msg).toContain('🥇 <b>WORTH</b> (0.3%)');
    expect(msg).toContain('$12.4K vol');
    expect(msg).toContain('34 swaps');
    expect(msg).toContain('21 traders');
    expect(msg).toContain('$124 fees');
    expect(msg).toContain(
      '<a href="https://docs.arc-scan.org/token/0x1f7d7550b1b028f7571e69a784071f0205fd2efa">0x1f7d…2efa</a>' +
        ' · <a href="https://gmgn.ai/arc/token/0x1f7d7550b1b028f7571e69a784071f0205fd2efa">GMGN</a>'
    );
    expect(msg).toContain('1,234,567');
  });

  it('HTML-escapes token symbols', () => {
    const board: MoversBoard = { fromBlock: 1, block: 2, rows: [row({ symbol: 'A&B<C>' })] };
    const msg = formatMoversBoard(board);
    expect(msg).toContain('A&amp;B&lt;C&gt;');
    expect(msg).not.toContain('A&B<C>');
  });

  it('renders no verification badge while the lookup is unresolved', () => {
    const board: MoversBoard = { fromBlock: 1, block: 2, rows: [row()] };
    const msg = formatMoversBoard(board);
    expect(msg).not.toContain('✅');
    expect(msg).not.toContain('⚠️'); // Danger Zone header only, not on this board
  });

  it('renders a verified badge', () => {
    const board: MoversBoard = { fromBlock: 1, block: 2, rows: [row({ verified: true })] };
    expect(formatMoversBoard(board)).toContain('<b>WORTH</b> ✅');
  });

  it('renders an unverified badge', () => {
    const board: MoversBoard = { fromBlock: 1, block: 2, rows: [row({ verified: false })] };
    expect(formatMoversBoard(board)).toContain('<b>WORTH</b> ⚠️');
  });

  it('renders a lookalike badge, overriding a verified status', () => {
    const board: MoversBoard = {
      fromBlock: 1, block: 2, rows: [row({ verified: true, lookalike: true })],
    };
    const msg = formatMoversBoard(board);
    expect(msg).toContain('<b>WORTH</b> 🚨');
    expect(msg).not.toContain('<b>WORTH</b> ✅');
  });
});

describe('formatVerificationBadge', () => {
  it('renders nothing when the lookup has not resolved', () => {
    expect(formatVerificationBadge(undefined, undefined)).toBe('');
  });
  it('renders a check for verified, a warning for unverified', () => {
    expect(formatVerificationBadge(true, false)).toBe(' ✅');
    expect(formatVerificationBadge(false, false)).toBe(' ⚠️');
  });
  it('renders the lookalike badge above everything else, even a verified/undefined status', () => {
    expect(formatVerificationBadge(true, true)).toBe(' 🚨');
    expect(formatVerificationBadge(undefined, true)).toBe(' 🚨');
  });
});

describe('formatMoversBoardV4', () => {
  it('renders the v4 title', () => {
    const board: MoversBoard = { fromBlock: 1, block: 2, rows: [row()] };
    expect(formatMoversBoardV4(board)).toContain('Arc Uniswap v4 — USDC Top Movers');
  });
});

describe('formatDangerZoneBoard', () => {
  it('uses the Danger Zone header with the origin label', () => {
    const board: MoversBoard = {
      rows: [row({ marketCapUsd: 4_000 })], block: 9, fromBlock: 1,
      variant: 'danger', label: 'Uniswap v3',
    };
    const msg = formatDangerZoneBoard(board);
    expect(msg).toContain('⚠️');
    expect(msg).toContain('Danger Zone');
    expect(msg).toContain('Uniswap v3');
    expect(msg).toContain('MC $4.0K');
  });

  it('HTML-escapes the origin label', () => {
    const board: MoversBoard = { rows: [row()], block: 9, fromBlock: 1, variant: 'danger', label: 'A&B<C>' };
    expect(formatDangerZoneBoard(board)).toContain('A&amp;B&lt;C&gt;');
  });
});

describe('formatFeeTier', () => {
  it('renders pips as a percent', () => {
    expect(formatFeeTier(3000)).toBe('0.3%');
    expect(formatFeeTier(500)).toBe('0.05%');
    expect(formatFeeTier(10000)).toBe('1%');
  });
});

describe('formatRsiTag', () => {
  it('shows a dash when there is no RSI yet', () => {
    expect(formatRsiTag(undefined, undefined)).toBe('RSI —');
  });
  it('adds an oversold badge below 30', () => {
    expect(formatRsiTag(25, 'oversold')).toBe('RSI 25 🟢 Oversold');
  });
  it('adds an overbought badge above 70', () => {
    expect(formatRsiTag(80, 'overbought')).toBe('RSI 80 🔴 Overbought');
  });
});

describe('formatMarketCap', () => {
  it('formats known/unknown/sub-dollar values', () => {
    expect(formatMarketCap(4_044_409)).toBe('MC $4.0M');
    expect(formatMarketCap(undefined)).toBe('MC —');
    expect(formatMarketCap(0.004)).toBe('MC <$1');
    expect(formatMarketCap(1)).toBe('MC $1');
  });
});

describe('formatUsd / formatUsdcUnits', () => {
  it('abbreviates by magnitude', () => {
    expect(formatUsd(1_250_000)).toBe('$1.3M');
    expect(formatUsd(256)).toBe('$256');
  });
  it('converts USDC base units (6 decimals)', () => {
    expect(formatUsdcUnits(12_400_000_000n)).toBe('$12.4K');
    expect(formatUsdcUnits(0n)).toBe('$0.00');
  });
});

describe('gmgn link', () => {
  const board: MoversBoard = { fromBlock: 1, block: 2, rows: [row()] };

  it.each([
    ['v3', formatMoversBoard],
    ['v4', formatMoversBoardV4],
    ['danger zone', (b: MoversBoard) => formatDangerZoneBoard({ ...b, variant: 'danger', label: 'Uniswap v3' })],
  ])('sits beside the contract address on the %s board', (_name, format) => {
    expect(format(board)).toContain(
      '<a href="https://docs.arc-scan.org/token/0x1f7d7550b1b028f7571e69a784071f0205fd2efa">0x1f7d…2efa</a>' +
        ' · <a href="https://gmgn.ai/arc/token/0x1f7d7550b1b028f7571e69a784071f0205fd2efa">GMGN</a>'
    );
  });

  it('is named in the /help legend', () => {
    expect(formatHelpMessage()).toContain('GMGN');
  });
});

describe('formatHelpMessage', () => {
  const help = formatHelpMessage();
  it('covers RSI, market cap, and the danger zone, and is HTML-formatted', () => {
    expect(help).toContain('RSI');
    expect(help).toContain('MC');
    expect(help).toContain('Danger Zone');
    expect(help).toContain('<b>');
  });
  it('explains the verification badge and that it is not a safety audit', () => {
    expect(help).toContain('✅');
    expect(help).toContain('⚠️');
    expect(help.toLowerCase()).toContain('not a safety audit');
  });

  it('explains the lookalike/name-squatter badge', () => {
    expect(help).toContain('🚨');
    expect(help.toLowerCase()).toContain('lookalike');
  });

  it('does not claim a fuller risk/audit scan (out of scope for v1)', () => {
    expect(help).not.toContain('Audit');
    expect(help.toLowerCase()).not.toContain('risk light');
  });
});
