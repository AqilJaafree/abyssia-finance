# abyssia-vault

Solidity contracts for Abyssia's USDC liquidity vaults on Circle's Arc network. Depositors put in USDC; the vault provides concentrated liquidity to allowlisted Uniswap v3/v4 USDC pools.

> **Status: work in progress, unaudited. Not deployed. Do not use with real funds.**

## Implemented so far

### `src/AbyssiaVault.sol` — the vault

The deployable vault: `AsyncBatchVault` plus Uniswap v3 and v4 positions in registry-allowlisted USDC pools.

- **Keeper operations.** `openPosition`, `withdrawPosition`, `collectPositionFees`, `closePosition` and `swap` (USDC ⇄ a pool's token, in that pool). Every new exposure must pass the registry: the pool is usable, v4 pools are **hookless only**, the asset class isn't frozen, the range width and ranges per pool are within the class limits, the pool is deep enough, and afterwards the pool and its class stay within `maxAllocationBps` / `maxClassBps` of NAV. One cap of `MAX_POSITIONS` (20) covers v3 and v4 together. The keeper can only ever move assets between the vault and Uniswap.
- **Swaps.** `minOut` must be at least the amount at the pool's current price minus `maxSwapSlippageBps` (hard cap 10%). This bounds price impact; the keeper's own `minOut` from an off-chain fair price protects against a manipulated pool price. Settlement never swaps: the keeper unwinds into USDC before redemptions settle.
- **Accounting.** Idle USDC and every token held (`tokenBalance`) are tracked internally, never read from `balanceOf`. Every credit is the smaller of the balance change and Uniswap's own figure (for v4 fees, from StateView fee growth), so a token that lies about balances can't inflate NAV.
- **Valuation.** NAV = idle USDC + each position's principal + token inventory, at each pool's current price. Settlement first harvests every position's fees (each in its own gas-capped call, so a frozen token can't block settlement), then the `maxCycleMoveBps` guard bounds the price.
- **In-kind exit.** One loop over every v3 and v4 position and every inventory token, each in a gas-capped self-call. A receiver that refuses a token gets an IOU (`owed`, claimable with `claimOwed`); a token that can't move at all, or burns gas, is skipped and stays with the remaining holders. Receivers that would lose the slice (the vault itself, the Uniswap contracts) are rejected. The measured worst case (20 positions, 18 of them hostile) is ~15.5M gas, under Arc's 30M block limit.
- **Operators and smart accounts.** ERC-7540 operators (`setOperator`) can cancel and claim on a user's behalf (`*For` functions). Approving an operator is full trust over those requests: it can choose the receiver. Nothing checks whether a caller is a contract, so smart accounts (Safe, ERC-4337, EIP-7702) work on every path.
- Code lives mostly in external libraries to stay under the 24 KB contract limit: `src/libraries/VaultBook.sol` (position/inventory book, valuation, exposure checks), `src/libraries/VaultOps.sol` (position, swap and inventory operations), `src/libraries/VaultSwaps.sol` (v3 swaps through SwapRouter02, v4 swaps through the PoolManager), `src/libraries/PoolPrice.sol` (USDC ⇄ token at a sqrt price).

Not yet built: liquidity shapes and rebalancing, stop-loss, fees, the factory and deployment.

### `src/AsyncBatchVault.sol` — vault core

Abstract ERC-4626 share token over 6-decimal USDC with ERC-7540-style batched settlement.

- **Async deposits and redemptions.** Users call `requestDeposit` / `requestRedeem`; requests can be cancelled until the batch settles. A keeper calls `settle()` to price the whole batch at one share price (O(1) in the number of users), then users `claimDeposit` / `claimRedeem`. The synchronous ERC-4626 `deposit` / `mint` / `withdraw` / `redeem` entry points are disabled.
- **Price guard.** `settle()` reverts if the share price moved more than `maxCycleMoveBps` since the last settlement. For a genuine market move, `settleAcceptingPriceMove(expectedPrice, toleranceBps)` lets the guardian accept a reviewed price, and only if the live price is still within tolerance of it.
- **Instant in-kind exit.** `redeemInKind` burns shares for a pro-rata slice of idle USDC plus every position, with no price involved, so nothing can be manipulated against remaining holders. Always available, even while paused.
- **Donation-proof accounting.** Idle USDC is tracked internally (`idleAssets`), never read from `balanceOf`, so donations cannot move the share price. `sweepSurplus` sends out anything beyond the vault's accounting.
- **Limits and roles.** Minimum deposit, total-assets cap and price-move limit (the minimum deposit and price-move limit are bounded by hard caps in code). `DEFAULT_ADMIN_ROLE` (intended: a timelock owned by a multisig) loosens; `GUARDIAN_ROLE` can only tighten (pause, lower the cap) and acts instantly; `KEEPER_ROLE` settles.
- **Operators (ERC-7540).** `setOperator` / `isOperator`; operators can `cancelDepositRequestFor`, `cancelRedeemRequestFor`, `claimDepositFor`, `claimRedeemFor`.
- LP-position logic plugs in through internal hooks (`_deployedValue`, `_ensureIdle`, `_redeemPositionsInKind`, `_beforeSettle`, `_reservedAssets`).

### `src/registry/VaultRegistry.sol` — risk configuration

- **Per-asset-class parameters** (Stable, Bluechip, Volatile, Memecoin): max allocation per pool and per class, allowed liquidity shapes (Spot / Curve / Bid-Ask), max ranges, range width bounds, mandatory stop-loss, rebalance cooldown, minimum pool liquidity. Every value is validated against hard caps in code.
- **Pool allowlist.** v3 pools are resolved through the Uniswap v3 factory and must be initialized; v4 pools are added by `PoolKey`, must be USDC pairs, cannot use native currency, and may only use explicitly allowed hooks.
- **Admin vs guardian.** Admin changes go through the timelock. The guardian can instantly reduce allocations, disable shapes, disable pools and revoke hooks.

### `src/v3/V3Positions.sol` — Uniswap v3 adapter

External library (delegatecalled, so the vault owns every position NFT) that works through Uniswap's `NonfungiblePositionManager`:

- `open`, `withdraw` (principal only), `collectFees`, `close`, `positionAmounts` (valuation at the current pool price), capped at `MAX_POSITIONS`.
- `withdrawSlice` for in-kind exits: each position is handled separately and gas-capped, so one frozen, blacklisting or gas-wasting token cannot block a holder's exit; tokens that can't be delivered are held as claimable IOUs.

### `src/v4/V4Positions.sol` — Uniswap v4 adapter

External library, same model as the v3 adapter, working through Uniswap's v4 `PositionManager` (`modifyLiquidities`), paying through Permit2:

- `open` (liquidity computed from the desired amounts at the current price; Permit2 allowances are exact, expire the same block and are reset), `withdraw`, `collectFees`, `close`, `positionAmounts`, capped at `MAX_POSITIONS`. ERC-20 pools only; native currency is rejected.
- v4 pays out all accrued fees on any liquidity change, so every withdrawal first harvests fees to the vault, then sends only principal to the recipient. Returned amounts are balance deltas (fee-on-transfer safe).
- Every reported amount is capped by Uniswap's own math (fees from StateView fee growth, principal from the pool formula).
- `withdrawSlice` for in-kind exits, with the same per-position isolation, gas cap and IOU fallback as v3.

### `script/DeployUniswapV3.s.sol` — testnet only

Uniswap v3 isn't deployed on Arc testnet, so this script deploys Uniswap's official v3 Factory, NonfungiblePositionManager and SwapRouter02 there. It refuses to run on any other chain. See `script/artifacts/README.md` for the vendored router bytecode's provenance and hash.

## Setup

Requires [Foundry](https://getfoundry.sh) and pnpm. Dependencies (OpenZeppelin, Uniswap, forge-std) are installed from npm into `node_modules`:

```sh
pnpm install      # from this directory or the repo root
forge build
```

`AbyssiaVault` and `VaultOps` (and the tests that import them) compile with the IR pipeline (`via_ir`, set per file in `foundry.toml`); everything else uses the default pipeline. A full build takes about a minute.

## Testing

```sh
forge test                 # all tests (fork suites skip without RPC URLs)
pnpm test                  # same, via the package script
forge fmt --check          # formatting (pnpm lint)
```

Run a subset:

```sh
forge test --match-path "test/AsyncBatchVault.*"   # vault core
forge test --match-path "test/registry/*"          # registry
forge test --match-path "test/v3/*"                # v3 adapter
forge test --match-path "test/v4/*"                # v4 adapter
forge test --match-path "test/vault/*"             # the vault (AbyssiaVault)
forge test --match-test testFuzz -vv               # fuzz tests only (1000 runs each)
forge test --gas-report                            # gas usage per function
```

### Test layout

| Path | Covers |
|---|---|
| `test/AsyncBatchVault.*.t.sol` | Deposits, redemptions, settlement and the price guard, in-kind exits, parameters, events, edge cases, hardening, fuzzing |
| `test/registry/` | Class parameters, pool allowlist, hardening, timelocked admin vs instant guardian |
| `test/v3/` | v3 adapter against a real local Uniswap v3 deployment, in-kind exits with frozen and gas-burning tokens, fuzzing |
| `test/v4/` | v4 adapter against Uniswap's official v4 bytecode deployed locally (PoolManager, PositionManager, StateView, Permit2), fee harvesting, in-kind exits with hostile tokens, fuzzing |
| `test/vault/` | `AbyssiaVault` on local v3 + v4: keeper operations and every registry check, swaps, settlement with fee harvesting, in-kind exits with hostile tokens and IOUs, worst-case exit gas at the position cap, operators, a smart account using every path, and a fuzz test that the books always match real balances |
| `test/script/` | Pins the vendored SwapRouter02 bytecode hash |
| `test/fork/` | Fork tests against Arc testnet and mainnet |
| `test/mocks/`, `test/harness/` | Mock tokens/pools and test harnesses |

### Fork tests

Fork tests only run when their RPC URL is set; otherwise they are skipped. Nothing is broadcast.

```sh
cp .env.example .env       # forge auto-loads .env
forge test --match-path "test/fork/*" -vv
```

- `ARC_TESTNET_RPC_URL`: the registry, the v4 adapter and the vault end to end against the real Uniswap v4 deployment, and a rehearsal of the v3 deploy script.
- `ARC_MAINNET_RPC_URL`: the v3 adapter against Uniswap's real v3 position manager and router.

Notes:

- With `.env` present, a plain `forge test` also hits the network. The public testnet RPC is rate-limited; fork tests pin a block to keep results reproducible.
- Arc's USDC can't be transferred inside a Foundry fork (it relies on an Arc precompile), so fork tests use a 6-decimal mock USDC.

## Deploying Uniswap v3 to Arc testnet

```sh
DEPLOYER_PRIVATE_KEY=0x... forge script script/DeployUniswapV3.s.sol \
  --rpc-url $ARC_TESTNET_RPC_URL --broadcast
```

Pass the key through the environment; never commit it.
