# Abyssia Finance

Monorepo for Abyssia Finance services.

| Package | Description |
|---|---|
| [`abyssia-oarfish`](./abyssia-oarfish) | Read-only Telegram bot posting Uniswap v3/v4 USDC Top Movers signal boards for Arc mainnet. |

## Workspace

pnpm workspace. Each package keeps its own `pnpm-lock.yaml` (`shared-workspace-lockfile=false`) so it can be built and deployed from its own directory.

```sh
pnpm install   # from the repo root
pnpm test      # runs every package's tests
```

## Secrets and strategy

Signal-strategy parameters are **never** committed. Each package reads them from the environment with no in-code defaults — see the package's `.env.example` for the required keys.
