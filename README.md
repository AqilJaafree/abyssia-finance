# Abyssia Finance

Monorepo for Abyssia Finance services on Circle's Arc network.

| Package | Description |
|---|---|
| [`abyssia-oarfish`](./abyssia-oarfish) | Read-only Telegram bot posting Uniswap v3/v4 USDC Top Movers signal boards for Arc mainnet. |
| [`abyssia-vault`](./abyssia-vault) | Solidity (Foundry) USDC liquidity vaults that provide concentrated liquidity to allowlisted Uniswap v3/v4 pools. Work in progress, unaudited. |

## Workspace

pnpm workspace. Each package keeps its own `pnpm-lock.yaml` (`shared-workspace-lockfile=false`) so it can be built and deployed from its own directory.

```sh
pnpm install   # from the repo root
pnpm test      # runs every package's tests
pnpm build     # builds every package
pnpm lint      # lints every package
```

`abyssia-vault` needs [Foundry](https://getfoundry.sh) (`forge`) installed.

## abyssia-vault

- `src/AbyssiaVault.sol`: the deployable vault. Keeper-run Uniswap v3/v4 positions (hookless v4 pools only) and oracle-bounded swaps within the registry's class limits, fee harvesting before each settlement, an in-kind exit that survives hostile tokens (IOUs), and ERC-7540 operators. Most logic lives in `src/libraries/`.
- `src/AsyncBatchVault.sol`: ERC-4626 USDC vault with batched async deposits/redemptions and an instant in-kind exit.
- `src/registry/VaultRegistry.sol`: per-asset-class risk limits and the allowlist of Uniswap v3/v4 USDC pools, administered through a timelock with an instant-tightening guardian role.
- `src/v3/V3Positions.sol`: Uniswap v3 position management through the NonfungiblePositionManager.
- `src/v4/V4Positions.sol`: Uniswap v4 position management through the PositionManager, paid via Permit2.
- `script/DeployUniswapV3.s.sol`: deploys Uniswap v3 to Arc testnet, where it isn't officially deployed.

Fork tests against Arc testnet/mainnet run only when `ARC_TESTNET_RPC_URL` / `ARC_MAINNET_RPC_URL` are set (see `abyssia-vault/.env.example`); otherwise they are skipped.

## Configuration

Each package is configured through environment variables. See the package's `.env.example` for the keys it needs.
