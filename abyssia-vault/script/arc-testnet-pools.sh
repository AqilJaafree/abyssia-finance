#!/usr/bin/env bash
# TESTNET ONLY (Arc testnet, 5042002): TestPools' setup with cast instead of forge script.
# Forge runs a script in a local EVM before broadcasting, and Arc USDC (0x3600...) relies on
# an Arc precompile that local EVM lacks, so every USDC transfer reverts there. These cast
# transactions run only on the chain. Creates TMEME (fixed supply), its USDC 0.3% v3 pool
# (observation capacity 1,500) and hookless v4 pool at 1 TMEME = 0.01 USDC, seeds both full
# range with SEED_USDC each, and leaves no allowance behind.
# Usage: DEPLOYER_PRIVATE_KEY=0x... SEED_USDC=1000000 script/arc-testnet-pools.sh
set -euo pipefail
: "${DEPLOYER_PRIVATE_KEY:?}" "${SEED_USDC:?}"
R=${ARC_TESTNET_RPC_URL:-https://rpc.testnet.arc.network}
U=0x3600000000000000000000000000000000000000
F=0x6a87032589b837935b1A393Dc905c84E908c6974     # Abyssia's v3 factory (DeployAbyssia pins)
NPM=0x9c58491817B883840737aF8E49C92eDcFF4bFf40
PM=0x8366a39CC670B4001A1121B8F6A443A643e40951    # Uniswap v4 PoolManager
POSM=0x6049c9a0e26405C0985f9E3685C87d0aE917f82B
P2=0x000000000022D473030F116dDEE9F6B43aC78BA3
Z=0x0000000000000000000000000000000000000000
D=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")
TOKEN_SEED=$(( SEED_USDC * 100000000000000 ))     # TMEME worth SEED_USDC at 0.01 USDC

# cast send with retries: the public RPC is load-balanced and rate-limited.
s() {
  local out
  for _ in 1 2 3 4; do
    out=$(cast send "$@" --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$R" 2>&1 || true)
    if grep -qE '^status +1' <<<"$out"; then echo "ok: $2"; return 0; fi
    grep -qE 'beyond head block|nonce too low|-32005' <<<"$out" || break
    sleep 3
  done
  echo "FAILED: $2" >&2; grep -iE 'error|status' <<<"$out" >&2 || true; return 1
}

T=$(forge create script/TestPools.s.sol:AbyssiaTestToken --rpc-url "$R" \
  --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast --constructor-args "$D" $(( 2 * TOKEN_SEED )) \
  | awk '/Deployed to:/{print $3}')
echo "TMEME $T"
if [[ $(tr 'A-F' 'a-f' <<<"$U") < $(tr 'A-F' 'a-f' <<<"$T") ]]; then
  T0=$U; T1=$T; A0=$SEED_USDC; A1=$TOKEN_SEED; ZERO=true
else
  T0=$T; T1=$U; A0=$TOKEN_SEED; A1=$SEED_USDC; ZERO=false
fi
PARAMS=$(forge script script/PoolParams.s.sol --tc PoolParams --sig "run(bool,uint256)" "$ZERO" "$SEED_USDC")
SQ=$(awk '/sqrtP/{print $2}' <<<"$PARAMS"); LIQ=$(awk '/liquidity/{print $2}' <<<"$PARAMS")
DL=$(( $(date +%s) + 3600 ))

# v3: create, initialize, observation capacity (chunks stay under Arc's 30M block gas),
# seed full range with 99% minimums (initialize and mint are separate transactions).
s $F "createPool(address,address,uint24)" "$T0" "$T1" 3000
P=$(cast call $F "getPool(address,address,uint24)(address)" "$T0" "$T1" 3000 --rpc-url "$R")
echo "v3 pool $P"
s "$P" "initialize(uint160)" "$SQ"
for n in 500 1000 1500; do s "$P" "increaseObservationCardinalityNext(uint16)" $n; done
s "$T0" "approve(address,uint256)" $NPM "$A0"
s "$T1" "approve(address,uint256)" $NPM "$A1"
s $NPM "mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))" \
  "($T0,$T1,3000,-887220,887220,$A0,$A1,$(( A0 * 99 / 100 )),$(( A1 * 99 / 100 )),$D,$DL)"
s "$T0" "approve(address,uint256)" $NPM 0
s "$T1" "approve(address,uint256)" $NPM 0

# v4: initialize a hookless pool; mint full range through Permit2 (capped by the maximums).
KEY="($T0,$T1,3000,60,$Z)"
s $PM "initialize((address,address,uint24,int24,address),uint160)" "$KEY" "$SQ"
s "$T0" "approve(address,uint256)" $P2 "$A0"
s "$T1" "approve(address,uint256)" $P2 "$A1"
s $P2 "approve(address,address,uint160,uint48)" "$T0" $POSM "$A0" "$DL"
s $P2 "approve(address,address,uint160,uint48)" "$T1" $POSM "$A1" "$DL"
MINT=$(cast abi-encode "f((address,address,uint24,int24,address),int24,int24,uint256,uint128,uint128,address,bytes)" \
  "$KEY" -887220 887220 "$LIQ" "$A0" "$A1" "$D" 0x)
SETTLE=$(cast abi-encode "f(address,address)" "$T0" "$T1")
s $POSM "modifyLiquidities(bytes,uint256)" "$(cast abi-encode "f(bytes,bytes[])" 0x020d "[$MINT,$SETTLE]")" "$DL"
s $P2 "approve(address,address,uint160,uint48)" "$T0" $POSM 0 0
s $P2 "approve(address,address,uint160,uint48)" "$T1" $POSM 0 0
s "$T0" "approve(address,uint256)" $P2 0
s "$T1" "approve(address,uint256)" $P2 0
echo "v4 pool id $(cast keccak "$(cast abi-encode "f(address,address,uint24,int24,address)" "$T0" "$T1" 3000 60 $Z)")"
echo "Wait ~10 minutes for the v3 TWAP window, then run DeployAbyssia with ALLOW_TOKEN=$T."
