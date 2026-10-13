# Vendored build artifacts

## SwapRouter02.json

- **Source:** npm package `@uniswap/swap-router-contracts@1.3.1`, file
  `artifacts/contracts/SwapRouter02.sol/SwapRouter02.json`. The package is
  deprecated on npm (and pulls in hardhat), so only the creation bytecode is
  vendored here; every other artifact field was dropped.
- **License:** GPL-2.0-or-later (Uniswap Labs).
- **npm `dist.integrity`:**
  `sha512-mh/YNbwKb7Mut96VuEtL+Z5bRe0xVIbjjiryn+iMMrK2sFKhR4duk/86mEz0UO5gSx4pQIw9G5276P5heY/7Rg==`
- **keccak256 of the creation bytecode (`.bytecode`):**
  `0x603dca716e6cc8be026ebc49ab95f5c163b4b2ec4019615e607ec91710734841`
  (pinned by `test/script/SwapRouter02Artifact.t.sol`).
- The artifact has no link references.

**Usage:** read ONLY by the testnet deploy script (`script/DeployUniswapV3.s.sol`)
and the tests that reuse it. It is never linked into, imported by, or deployed
alongside vault code; Arc mainnet always uses Uniswap's real SwapRouter02.
