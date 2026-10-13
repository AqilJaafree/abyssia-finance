# abyssia-oarfish — Arc Mainnet Uniswap Top Movers Signal Boards

## Project purpose
Read-only Telegram bot: discovers Uniswap v3/v4 swaps on Circle's Arc mainnet
(chain id 5042), ranks pools by USDC volume, tags each with an RSI reading, and
posts Top-N boards to two Telegram forum topics plus a shared Danger Zone topic
for tokens below the market-cap floor. Part of the `abyssia-finance` monorepo.

## Signal strategy is PRIVATE
All signal-shaping parameters (RSI period and oversold/overbought thresholds,
candle width, candle history depth, market-cap floor, RSI volume floor) live in
`STRATEGY_*` env vars parsed by `src/strategy.ts`.
- No in-code defaults. Do not add any.
- Never commit real values (`.env.example` keeps them blank; tests use
  obviously-fixture values).
- Never log or render a strategy value — not in logs, not in Telegram text,
  not in `/help`. Validation errors report key NAMES only.
- Missing/invalid strategy -> both loops refuse to start (`src/index.ts`).

## Explicitly out of scope (do not add without a new design doc)
- No LP auto-bot — this project never signs or broadcasts a transaction.
- No heuristic risk scan (mint/blacklist/tax/proxy detection) — only
  contract-VERIFICATION status (`src/arc/verification.ts`, Arcscan's
  `verified` field). A ✅ badge means the source is public, not that the
  code is safe.
- No anchor asset other than USDC.

## Architecture
`src/strategy.ts` — required strategy env loader/validator.
`src/arc/` — v3 board (swap discovery, ranking, RSI, market-cap gate).
`src/arc/v4/` — v4 board (singleton PoolManager, same pipeline).
`src/telegram/` — message formatting (`format.ts`) and bot send (`sender.ts`).
Entry point: `src/index.ts` — health server + two independent cron loops.

## Naming
Several ported fields/constants keep `weth`/`eth` naming (`wethIsToken0`,
`volumeWeth`, `ethIsCurrency0`) even though the anchor is `ARC_USDC`, never
WETH or native ETH. See the comment at the top of `src/arc/config.ts` before
renaming anything — deliberate port-time decision.

## Key conventions
- All USDC amounts as bigint base units (6 decimals). Format via
  `formatUsdcUnits`/`formatUsd` in `src/telegram/format.ts` — do not inline.
- Env vars via `process.env` only. Never hardcode. See `.env.example`.
- Never use `console.log` — use the pino logger from `src/logger.ts`.
- `ARC_RPC_URL` has no default — both loops refuse to start without it.
- Loop arming (`ARC_V3_ENABLED`/`ARC_V4_ENABLED`) is opt-out: unset/blank
  means ON. See `src/flags.ts`.

## Testing
- vitest. Unit tests colocated: `src/arc/rpc.test.ts` etc.
- Run: `pnpm test`
