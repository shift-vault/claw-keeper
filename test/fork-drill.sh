#!/usr/bin/env bash
# Fork drill: runs keeper.sh against a local anvil fork of BNB Chain testnet (97) and checks what it did.
# Every transaction goes to the local fork; nothing is sent to a live chain.
#
#   test/fork-drill.sh                                        (starts anvil on a free port, stops it at the end)
#   ANVIL_RPC=http://127.0.0.1:8545 test/fork-drill.sh        (uses an anvil fork of 97 that is already running)
#
# SHOOTER_PK (optional): the key that fires the shots on the fork; a fresh key is made when it is not set.
# The keeper and the rivals always get fresh keys. KEEPER_BASH picks the shell that runs keeper.sh (default: bash).
# Needs anvil, cast, bc and python3 (test/fork-relay.py: anvil reads the public endpoint through it, with retries, so
# a dropped connection there does not strand a transaction in the fork's pool).
#
# The fork plays the Trigger Service's backend by impersonating the address that holds its TRIGGER_ROLE: it runs
# each shot's first request (the anchor) and never the second (the settle), which is exactly the case the keeper
# exists for. anvil does not write block hashes into the EIP-2935 history contract, so after an anchor block is mined
# the drill writes that block's hash into the contract's ring slot (block % 8191), as the chain itself does.

set -u
set -o pipefail
cd "$(dirname "$0")/.." || exit 2

FORK_URL="${FORK_URL:-https://bsc-testnet-rpc.publicnode.com}"
# a fork fetches untouched state from FORK_URL on demand, which a public endpoint can make slower than cast's
# default 45 s per request
export ETH_RPC_TIMEOUT="${ETH_RPC_TIMEOUT:-180}"
KEEPER_SH="${KEEPER_SH:-./keeper.sh}" # the keeper under test
KEEPER_BASH="${KEEPER_BASH:-bash}"
FACTORY=0xd675158707aFE1165d84A0e478FD02BF9f3Ddc5b
OPERATOR="${OPERATOR:-0x1e95Ba5b1005f7ccCE440A8845d7Dc74A66D4058}" # TRIGGER_ROLE holder of the 97 service (checked below)
PORTAL=0x5bEacaF7ABCbB3aB280e80D007FD31fcE26510e9                  # holds the curve's unsold tokens on 97
HISTORY=0x0000F90827F1C53a10cb7A02335B175320002935                 # EIP-2935 block hash history
WORK="$(mktemp -d "${TMPDIR:-/tmp}/claw-keeper-drill.XXXXXX")"
PASS=0
FAIL=0
ANVIL_PID=""
RELAY_PID=""

fatal() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
say() {
  printf '\n== %s\n' "$*"
  if [ -n "$ANVIL_PID" ] && ! kill -0 "$ANVIL_PID" 2>/dev/null; then fatal "anvil (pid $ANVIL_PID) is gone; see $WORK/anvil.log"; fi
}
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
check() { if [ "$1" = "$2" ]; then ok "$3 ($1)"; else bad "$3: got $1, want $2"; fi; }

cleanup() { # only the processes this drill started
  if [ -n "$ANVIL_PID" ]; then kill "$ANVIL_PID" 2>/dev/null; fi
  if [ -n "$RELAY_PID" ]; then kill "$RELAY_PID" 2>/dev/null; fi
}
trap cleanup EXIT

if [ -n "${ANVIL_RPC:-}" ]; then
  A="$ANVIL_RPC"
else
  free_port() { local p="$1"; while lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; do p=$((p + 1)); done; echo "$p"; }
  rport="$(free_port "${RELAY_PORT:-28645}")"
  python3 test/fork-relay.py "$rport" "$FORK_URL" 2>"$WORK/relay.log" &
  RELAY_PID=$!
  n=0
  until lsof -nP -iTCP:"$rport" -sTCP:LISTEN >/dev/null 2>&1; do
    n=$((n + 1))
    [ "$n" -gt 20 ] && fatal "the relay did not come up"
    sleep 0.5
  done
  port="$(free_port "${ANVIL_PORT:-28545}")"
  anvil --fork-url "http://127.0.0.1:$rport" --port "$port" --chain-id 97 --retries 30 --timeout 300000 --no-rate-limit >"$WORK/anvil.log" 2>&1 &
  ANVIL_PID=$!
  A="http://127.0.0.1:$port"
  n=0
  until cast chain-id --rpc-url "$A" >/dev/null 2>&1; do
    n=$((n + 1))
    [ "$n" -gt 60 ] && fatal "anvil did not come up: $(tail -3 "$WORK/anvil.log" | tr "\n" " ")"
    sleep 1
  done
  echo "anvil (pid $ANVIL_PID) forking 97 on $A at block $(cast block-number --rpc-url "$A"), through the relay (pid $RELAY_PID) on port $rport"
fi
[ "$(cast chain-id --rpc-url "$A")" = 97 ] || fatal "not a fork of 97"

c() { cast "$@" --rpc-url "$A"; }
# rcall <cast call args...>: a read on the fork, retried: the fork fetches untouched state from the public endpoint,
# which sometimes times out
rcall() {
  local out n=0
  while :; do
    if out="$(c call "$@" 2>&1)" && [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
    n=$((n + 1))
    if [ "$n" -ge 6 ]; then
      printf 'read failed: %s: %s\n' "$*" "$(printf '%s' "$out" | tail -1)" >&2
      return 1
    fi
    sleep 3
  done
}
num() { rcall "$@" | awk '{ print $1; exit }'; }
mine() { c rpc anvil_mine "$(printf '0x%x' "${1:-1}")" >/dev/null; }
fund() { c rpc anvil_setBalance "$1" 0xde0b6b3a7640000 >/dev/null; } # 1 BNB, on the fork
unlocked() { # unlocked <from> <to> <sig> [args...]
  local from="$1"
  shift
  c rpc anvil_impersonateAccount "$from" >/dev/null
  # a send the fork could not execute (its upstream timed out) was not mined: safe to repeat
  c send --unlocked --from "$from" "$@" >/dev/null || c send --unlocked --from "$from" "$@" >/dev/null ||
    fatal "impersonated call failed: $*"
  c rpc anvil_stopImpersonatingAccount "$from" >/dev/null
}
newkey() { cast wallet new | sed -n 's/^Private key: *//p'; }

VAULT="$(num "$FACTORY" "vaults(uint256)(address)" 0)"
VAULT_LC="$(echo "$VAULT" | tr 'A-F' 'a-f')"
TOKEN="$(num "$VAULT" "taxToken()(address)")"
QUOTE="$(num "$VAULT" "vaultQuoteToken()(address)")"
SERVICE="$(num "$VAULT" "triggerService()(address)")"
ROLE="$(num "$SERVICE" "TRIGGER_ROLE()(bytes32)")"
[ "$(num "$SERVICE" "hasRole(bytes32,address)(bool)" "$ROLE" "$OPERATOR")" = true ] || fatal "OPERATOR has no TRIGGER_ROLE"
BULLET="$(num "$VAULT" "BULLET_TOKENS()(uint256)")"
for x in "$VAULT" "$TOKEN" "$QUOTE" "$SERVICE" "$ROLE" "$BULLET"; do [ -n "$x" ] || fatal "a setup read came back empty"; done
echo "factory $FACTORY: $(num "$FACTORY" "vaultCount()(uint256)") vault(s); vault $VAULT"
echo "token $TOKEN  quote $QUOTE  service $SERVICE  pool $(num "$VAULT" "pool()(uint256)")"

KEEPER_PK="$(newkey)"
KEEPER="$(cast wallet address --private-key "$KEEPER_PK")"
RIVAL_PK="$(newkey)"
RIVAL="$(cast wallet address --private-key "$RIVAL_PK")"
if [ -z "${SHOOTER_PK:-}" ]; then SHOOTER_PK="$(newkey)"; fi
SHOOTER="$(cast wallet address --private-key "$SHOOTER_PK")"
for w in "$KEEPER" "$RIVAL" "$SHOOTER" "$OPERATOR"; do fund "$w"; done
c rpc anvil_setCode "$SHOOTER" 0x >/dev/null # a fork-only precaution: no delegated code on the shooter
unlocked "$PORTAL" "$TOKEN" "transfer(address,uint256)" "$SHOOTER" "$(echo "$BULLET * 400" | bc)"
c send "$TOKEN" "approve(address,uint256)" "$VAULT" "$(echo "$BULLET * 400" | bc)" --private-key "$SHOOTER_PK" >/dev/null
echo "keeper $KEEPER  shooter $SHOOTER  rival $RIVAL"

# shot helpers ---------------------------------------------------------------------------------------------------
st() { rcall "$VAULT" "shotState(uint256)(uint8,uint256,uint256,uint64,uint64,uint64,bool,uint256,uint256,uint256[])" "$1" | awk '{ print $1 }' | tr '\n' ' '; }
status() { st "$1" | awk '{ print $1 }'; }
anchor_of() { st "$1" | awk '{ print $6 }'; }
payout_of() { st "$1" | awk '{ print $9 }'; }
r1_of() { st "$1" | awk '{ print $2 }'; }
r2_of() { st "$1" | awk '{ print $3 }'; }
qbal() { num "$QUOTE" "balanceOf(address)(uint256)" "$1"; }
qhead() { num "$VAULT" "queueHead()(uint64)"; }
qtail() { num "$VAULT" "queueTail()(uint64)"; }

# fire <bullets> <choice>: prints the new shot id
fire() {
  local id fee
  id="$(num "$VAULT" "nextShotId()(uint256)")"
  fee="$(num "$VAULT" "triggerFee()(uint256)")"
  if ! c send "$VAULT" "fire(uint256,uint8)" "$(echo "$BULLET * $1" | bc)" "$2" --value "$fee" --private-key "$SHOOTER_PK" >/dev/null; then
    [ "$(num "$VAULT" "nextShotId()(uint256)")" = "$id" ] || return 1 # it went through after all: not safe to guess
    echo "  (fire not sent: the fork's upstream was slow; once more)" >&2
    c send "$VAULT" "fire(uint256,uint8)" "$(echo "$BULLET * $1" | bc)" "$2" --value "$fee" --private-key "$SHOOTER_PK" >/dev/null || return 1
  fi
  echo "$id"
}
fire_n() { # fire_n <count>: fires <count> one-bullet shots, prints their ids
  local i=0 out=""
  while [ "$i" -lt "$1" ]; do
    out="$out $(fire 1 $((i % 3)))" || return 1
    i=$((i + 1))
  done
  echo "$out"
}
# anchor_by_service <ids...>: the backend runs the shots' anchor requests (first requests) in one triggerMultiple
anchor_by_service() {
  local list="" id
  for id in "$@"; do list="$list${list:+,}$(r1_of "$id")"; done
  c rpc evm_increaseTime 0x2 >/dev/null
  mine 1
  unlocked "$OPERATOR" "$SERVICE" "triggerMultiple(uint256[])" "[$list]"
}
# fix_history <block>: write the block's hash into the EIP-2935 ring, as the chain does at every block
fix_history() {
  local h
  h="$(c block "$1" --field hash)"
  c rpc anvil_setStorageAt "$HISTORY" "$(printf '0x%x' $(($1 % 8191)))" "$h" >/dev/null
}
fix_history_of() { local id; for id in "$@"; do fix_history "$(anchor_of "$id")"; done; }
# keeper <log name> [VAR=value...]: one keeper.sh pass against the fork, output kept in $WORK/<name>.log
keeper() {
  local name="$1"
  shift
  env CHAIN_ID=97 RPC="$A" FACTORY="$FACTORY" KEEPER_PK="$KEEPER_PK" STATE_DIR="$WORK/state" LOW_BALANCE=0 "$@" \
    "$KEEPER_BASH" "$KEEPER_SH" >"$WORK/$name.log" 2>&1
  KRC=$?
  sed 's/^/    | /' "$WORK/$name.log"
}
words() { tr '\n' ' ' | tr -s ' ' | sed 's/^ //; s/ $//'; } # one line, single spaces
sum_payouts() { local s=0 id; for id in "$@"; do s="$(echo "$s + $(payout_of "$id")" | bc)"; done; echo "$s"; }
settled_order() { sed -En 's/.*settleFallback\([0-9]+\) tx 0x[0-9a-f]+ gas [0-9]+: shot ([0-9]+) (settled|spent).*/\1/p' "$@" | words; }
count5() { local n=0 id; for id in "$@"; do [ "$(status "$id")" = 5 ] && n=$((n + 1)); done; echo "$n"; }
queue_ids() { local s="$1" out=""; while [ "$s" -lt "$2" ]; do out="$out $(num "$VAULT" "queuedShot(uint256)(uint256)" "$s")"; s=$((s + 1)); done; echo "$out" | words; }

# 0. before anything: the vault's queue is empty ------------------------------------------------------------------
say "0. an empty queue and nothing overdue: the pass is a no-op"
check "$(qhead) $(qtail)" "$(qtail) $(qtail)" "the settle queue is empty (head = tail)"
nonce0="$(c nonce "$KEEPER")"
keeper Z0
check "$KRC" 0 "keeper exit code"
check "$(c nonce "$KEEPER")" "$nonce0" "no transaction sent"
check "$(grep -c "nothing to do" "$WORK/Z0.log")" 1 "the pass reports nothing to do"

# A. the service anchors three shots and never delivers their settle requests -----------------------------------------
say "A. three ready shots (10, 10 and 100 bullets) whose settle callback never comes"
A1="$(fire 10 0)" || fatal "fire failed"
A2="$(fire 10 1)" || fatal "fire failed"
A3="$(fire 100 2)" || fatal "fire failed" # the most bullets a shot may carry: the heaviest settle
anchor_by_service "$A1" "$A2" "$A3"
mine 2
fix_history_of "$A1" "$A2" "$A3"
check "$(status "$A1") $(status "$A2") $(status "$A3")" "4 4 4" "shots $A1 $A2 $A3 ready before the keeper"
nonce0="$(c nonce "$KEEPER")"
keeper A0 DRY_RUN=1
check "$KRC" 0 "a dry run first: exit code"
check "$(grep -c "DRY RUN: would settleFallback" "$WORK/A0.log")" 3 "it lists the three shots"
check "$(c nonce "$KEEPER") $(status "$A1") $(status "$A2") $(status "$A3")" "$nonce0 4 4 4" "and sends nothing"
shooter0="$(qbal "$SHOOTER")"
keeperq0="$(qbal "$KEEPER")"
keeperbnb0="$(c balance "$KEEPER")"
keeper A1
check "$KRC" 0 "keeper exit code"
check "$(status "$A1") $(status "$A2") $(status "$A3")" "5 5 5" "all three settled"
check "$(settled_order "$WORK/A1.log")" "$A1 $A2 $A3" "settled from the head, in queue order"
check "$(($(c nonce "$KEEPER") - nonce0))" 3 "one settleFallback transaction per shot"
sumA="$(sum_payouts "$A1" "$A2" "$A3")"
check "$(echo "$(qbal "$SHOOTER") - $shooter0" | bc)" "$sumA" "the shooter received exactly the three payouts"
check "$(num "$VAULT" "owed(address)(uint256)" "$SHOOTER")" 0 "nothing held for pickup: every win delivered"
check "$(qbal "$KEEPER")" "$keeperq0" "the keeper received none of the winnings"
check "$(echo "$(c balance "$KEEPER") < $keeperbnb0" | bc)" 1 "the keeper paid the gas (its BNB fell)"
won=0
for id in "$A1" "$A2" "$A3"; do [ "$(payout_of "$id")" != 0 ] && won=$((won + 1)); done
if [ "$won" -gt 0 ]; then ok "$won of the three won and were paid ($sumA in total)"; else bad "no winner among the three (a rare draw); rerun"; fi
check "$(c call "$SERVICE" "getRequest(uint256)((address,uint64,uint8,uint128))" "$(r2_of "$A1")" | tr -d '()' | awk -F', ' '{ print $3 }')" 0 \
  "the service never ran the settle request (still PENDING): the keeper settled"
for id in "$A1" "$A2" "$A3"; do
  tx="$(sed -En "s/.*settleFallback\\($id\\) tx (0x[0-9a-f]+).*/\\1/p" "$WORK/A1.log")"
  check "$(c tx "$tx" gas)" 3000000 "shot $id: settleFallback sent with the explicit 3,000,000 gas limit"
done

# B. a shot the service never anchors ---------------------------------------------------------------------------------
say "B. a shot never anchored: armed 6 h after its fire, settled on the next pass"
B1="$(fire 1 0)" || fatal "fire failed"
mine 1
keeper B1
check "$KRC" 0 "keeper exit code"
check "$(status "$B1")" 1 "still pending: the service has 6 h"
check "$(cat "$WORK/state/claw-97-$VAULT_LC.from")" "$B1" "the low-water mark stays at the unanchored shot"
c rpc evm_increaseTime "$(printf '0x%x' $((6 * 3600 + 5)))" >/dev/null
mine 1
check "$(status "$B1")" 2 "overdue after 6 h"
keeper B2
check "$KRC" 0 "keeper exit code"
check "$(grep -c "armFallback($B1) tx" "$WORK/B2.log")" 1 "the keeper armed it"
anchorB="$(anchor_of "$B1")"
armtx="$(sed -En "s/.*armFallback\\($B1\\) tx (0x[0-9a-f]+).*/\\1/p" "$WORK/B2.log")"
check "$anchorB" "$(($(c receipt "$armtx" blockNumber) + 1))" "anchored at the block after the arm's own block"
mine 2
fix_history "$anchorB"
check "$(status "$B1")" 4 "ready once its anchor is mined"
keeper B3
check "$KRC" 0 "keeper exit code"
check "$(status "$B1")" 5 "settled by the next pass"
check "$(cat "$WORK/state/claw-97-$VAULT_LC.from")" "$(num "$VAULT" "nextShotId()(uint256)")" "the mark moved past it"

# C. nothing to do -----------------------------------------------------------------------------------------------------
say "C. rerun twice with an empty queue: no-ops"
check "$(qhead)" "$(qtail)" "the queue is empty"
nonce0="$(c nonce "$KEEPER")"
keeper C1
check "$KRC" 0 "keeper exit code"
keeper C2
check "$KRC" 0 "keeper exit code"
check "$(c nonce "$KEEPER")" "$nonce0" "no transaction sent"
check "$(cat "$WORK/C1.log" "$WORK/C2.log" | grep -c "nothing to do")" 2 "both passes report nothing to do"

# D. thirty shots, anchored in three batches, SWEEP_MAX=20 --------------------------------------------------------------
say "D. thirty shots, settled from the head in queue order, 20 a pass (SWEEP_MAX=20), the rest on the next pass"
D="$(fire_n 30)" || fatal "fire failed"
# shellcheck disable=SC2086
set -- $D
anchor_by_service "${1}" "${2}" "${3}" "${4}" "${5}" "${6}" "${7}" "${8}" "${9}" "${10}"
anchor_by_service "${11}" "${12}" "${13}" "${14}" "${15}" "${16}" "${17}" "${18}" "${19}" "${20}"
anchor_by_service "${21}" "${22}" "${23}" "${24}" "${25}" "${26}" "${27}" "${28}" "${29}" "${30}"
mine 2
# shellcheck disable=SC2086
fix_history_of $D
head0="$(qhead)"
tail0="$(qtail)"
check "$((tail0 - head0))" 30 "thirty shots in the settle queue"
QORDER="$(queue_ids "$head0" "$tail0")"
shooter0="$(qbal "$SHOOTER")"
nonce0="$(c nonce "$KEEPER")"
keeper D1 SWEEP_MAX=20
check "$KRC" 0 "keeper exit code"
check "$(($(qhead) - head0))" 20 "the first pass closed SWEEP_MAX = 20 from the head"
check "$(grep -c "SWEEP_MAX (20) reached" "$WORK/D1.log")" 1 "and said the next pass goes on"
keeper D2 SWEEP_MAX=20
check "$KRC" 0 "keeper exit code"
check "$(qhead)" "$tail0" "the second pass emptied the queue"
# shellcheck disable=SC2086
check "$(count5 $D)" 30 "all thirty settled"
check "$(settled_order "$WORK/D1.log" "$WORK/D2.log")" "$QORDER" "settled in queue order across both passes"
check "$(($(c nonce "$KEEPER") - nonce0))" 30 "thirty transactions, one per shot"
# shellcheck disable=SC2086
check "$(echo "$(qbal "$SHOOTER") - $shooter0" | bc)" "$(sum_payouts $D)" "the shooter received every payout"
check "$(num "$VAULT" "owed(address)(uint256)" "$SHOOTER")" 0 "nothing held for pickup"
echo "  gas per settleFallback: $(sed -En 's/.* gas ([0-9]+): shot.*/\1/p' "$WORK/D1.log" "$WORK/D2.log" | sort -n | uniq -c | awk '{ printf "%s x %s, ", $1, $2 }')"

# E. spent shots ahead of a ready one -----------------------------------------------------------------------------------
say "E. two anchors that expired before the keeper ran, ahead of a ready shot: closed in order, no loop"
E1="$(fire 1 0)" || fatal "fire failed"
E2="$(fire 1 1)" || fatal "fire failed"
anchor_by_service "$E1" "$E2"
mine 8200
E3="$(fire 1 2)" || fatal "fire failed"
anchor_by_service "$E3"
mine 2
fix_history_of "$E3"
check "$(status "$E1") $(status "$E2") $(status "$E3")" "6 6 4" "spent, spent, ready"
nonce0="$(c nonce "$KEEPER")"
keeper E1
check "$KRC" 0 "keeper exit code"
check "$(settled_order "$WORK/E1.log")" "$E1 $E2 $E3" "closed in queue order"
check "$(grep -c "spent (its anchor" "$WORK/E1.log")" 2 "the two spent shots closed, paying nothing"
check "$(status "$E1") $(status "$E2") $(status "$E3")" "6 6 5" "stored as spent, spent, settled"
check "$(($(c nonce "$KEEPER") - nonce0))" 3 "three transactions: no loop"
keeper E2
check "$KRC" 0 "keeper exit code"
check "$(($(c nonce "$KEEPER") - nonce0))" 3 "the next pass sends nothing"
check "$(grep -c "nothing to do" "$WORK/E2.log")" 1 "and reports nothing to do"

# F. races ------------------------------------------------------------------------------------------------------------
say "F1. the head settled by someone else just before the pass"
F="$(fire_n 3)" || fatal "fire failed"
# shellcheck disable=SC2086
anchor_by_service $F
mine 2
# shellcheck disable=SC2086
fix_history_of $F
# shellcheck disable=SC2086
set -- $F
c send "$VAULT" "settleFallback(uint256)" "$1" --gas-limit 3000000 --private-key "$RIVAL_PK" >/dev/null
check "$(status "$1")" 5 "the rival settled shot $1"
keeper F1
check "$KRC" 0 "keeper exit code"
check "$(status "$1") $(status "$2") $(status "$3")" "5 5 5" "all settled"
check "$(settled_order "$WORK/F1.log")" "$2 $3" "the keeper settled the other two"

say "F2. a real mempool race: the rival settles the keeper's target first, in the same block"
G="$(fire_n 6)" || fatal "fire failed"
# shellcheck disable=SC2086
anchor_by_service $G
mine 2
# shellcheck disable=SC2086
fix_history_of $G
c rpc evm_setAutomine false >/dev/null
env CHAIN_ID=97 RPC="$A" FACTORY="$FACTORY" KEEPER_PK="$KEEPER_PK" STATE_DIR="$WORK/state" LOW_BALANCE=0 "$KEEPER_BASH" "$KEEPER_SH" >"$WORK/F2.log" 2>&1 &
KPID=$!
raced=""
t=0
while kill -0 "$KPID" 2>/dev/null && [ "$t" -lt 600 ]; do
  pool="$(c rpc txpool_content 2>/dev/null | tr 'A-F' 'a-f')"
  input="$(printf '%s' "$pool" | grep -o '"input":"0x3e4fc037[0-9a-f]*"' | head -1 | sed 's/.*"0x3e4fc037\([0-9a-f]*\)"/\1/')"
  if [ -n "$input" ] && [ -z "$raced" ]; then
    raced="$(cast to-dec "0x$input")"
    gp="$(c gas-price)"
    c send "$VAULT" "settleFallback(uint256)" "$raced" --gas-limit 3000000 --gas-price "$((gp * 10))" --legacy --async --private-key "$RIVAL_PK" >"$WORK/rival.tx"
    echo "  the keeper's settleFallback($raced) is in the mempool; the rival sends the same at 10x the gas price"
  fi
  if printf '%s' "$pool" | grep -q '"hash"'; then c rpc evm_mine >/dev/null; fi
  sleep 0.2
  t=$((t + 1))
done
wait "$KPID"
KRC=$?
c rpc evm_setAutomine true >/dev/null
sed 's/^/    | /' "$WORK/F2.log"
check "$KRC" 0 "keeper exit code after losing the race"
if [ -n "$raced" ]; then ok "the race happened on shot $raced"; else bad "no race happened"; fi
rtx="$(cat "$WORK/rival.tx" 2>/dev/null)"
check "$(c receipt "$rtx" status 2>/dev/null | awk '{ print $1 }')" 1 "the rival's settleFallback succeeded"
ktx="$(sed -En "s/.*settleFallback\\($raced\\) (0x[0-9a-f]+): shot $raced was closed by someone else first.*/\\1/p" "$WORK/F2.log")"
check "$(c receipt "$ktx" status 2>/dev/null | awk '{ print $1 }')" 0 "the keeper's own transaction was mined and reverted"
check "$(c receipt "$ktx" blockNumber 2>/dev/null)" "$(c receipt "$rtx" blockNumber 2>/dev/null)" "in the same block as the rival's"
check "$(grep -c "closed by someone else first" "$WORK/F2.log")" 1 "the keeper saw it lose, counted no failure and went on"
# shellcheck disable=SC2086
check "$(count5 $G)" 6 "all six settled"

say "F3. two keepers with different wallets at the same time"
KEEPER2_PK="$(newkey)"
fund "$(cast wallet address --private-key "$KEEPER2_PK")"
H="$(fire_n 12)" || fatal "fire failed"
# shellcheck disable=SC2086
anchor_by_service $H
mine 2
# shellcheck disable=SC2086
fix_history_of $H
env CHAIN_ID=97 RPC="$A" FACTORY="$FACTORY" KEEPER_PK="$KEEPER_PK" STATE_DIR="$WORK/state" LOW_BALANCE=0 "$KEEPER_BASH" "$KEEPER_SH" >"$WORK/F3a.log" 2>&1 &
P1=$!
env CHAIN_ID=97 RPC="$A" FACTORY="$FACTORY" KEEPER_PK="$KEEPER2_PK" STATE_DIR="$WORK/state2" LOW_BALANCE=0 "$KEEPER_BASH" "$KEEPER_SH" >"$WORK/F3b.log" 2>&1 &
P2=$!
wait "$P1"
R1=$?
wait "$P2"
R2=$?
sed 's/^/    a | /' "$WORK/F3a.log"
sed 's/^/    b | /' "$WORK/F3b.log"
check "$R1 $R2" "0 0" "both keepers exit 0"
# shellcheck disable=SC2086
check "$(count5 $H)" 12 "all twelve settled"
check "$(settled_order "$WORK/F3a.log" "$WORK/F3b.log" | tr ' ' '\n' | sort -n | words)" "$(echo "$H" | tr ' ' '\n' | sort -n | words)" "each shot settled exactly once between them"

# G. an unanchored shot buried under later shots ----------------------------------------------------------------------
say "G. an unanchored shot buried under twenty later shots is still armed 6 h on, from the low-water mark"
V="$(fire 1 0)" || fatal "fire failed"
L="$(fire_n 20)" || fatal "fire failed"
# shellcheck disable=SC2086
anchor_by_service $L
mine 2
# shellcheck disable=SC2086
fix_history_of $L
keeper G1
check "$KRC" 0 "keeper exit code"
check "$(status "$V")" 1 "the buried shot is still pending (the service has 6 h)"
check "$(cat "$WORK/state/claw-97-$VAULT_LC.from")" "$V" "the mark holds at it"
c rpc evm_increaseTime "$(printf '0x%x' $((6 * 3600 + 5)))" >/dev/null
mine 1
check "$(status "$V")" 2 "overdue after 6 h, with $(($(num "$VAULT" "nextShotId()(uint256)") - V - 1)) shots fired after it"
keeper G2
check "$KRC" 0 "keeper exit code"
check "$(grep -c "armFallback($V) tx" "$WORK/G2.log")" 1 "the keeper armed it from its low-water mark"
mine 2
fix_history "$(anchor_of "$V")"
keeper G3
check "$KRC" 0 "keeper exit code"
check "$(status "$V")" 5 "settled on the next pass"

# H. a real failure: a ready head the chain refuses to settle ----------------------------------------------------------
say "H. a ready head whose anchor hash the history contract does not serve: one failed transaction, exit 1, no loop"
H1="$(fire 1 0)" || fatal "fire failed"
anchor_by_service "$H1"
mine 2
aH="$(anchor_of "$H1")"
c rpc anvil_setStorageAt "$HISTORY" "$(printf '0x%x' $((aH % 8191)))" 0x0000000000000000000000000000000000000000000000000000000000000000 >/dev/null
check "$(status "$H1")" 4 "shown ready (its anchor is mined)"
nonce0="$(c nonce "$KEEPER")"
keeper H1
check "$KRC" 1 "keeper exit code: a real failure"
check "$(grep -c "FAILED: settleFallback($H1)" "$WORK/H1.log")" 1 "reported once"
check "$(grep -c "anchor hash unavailable" "$WORK/H1.log")" 1 "with the vault's reason"
check "$(($(c nonce "$KEEPER") - nonce0))" 1 "one transaction, no retry loop"
fix_history "$aH"
keeper H2
check "$KRC" 0 "keeper exit code once the hash is served"
check "$(status "$H1")" 5 "settled by the next pass"

# I. exit codes of the other outcomes ------------------------------------------------------------------------------------
say "I. the other exit codes"
keeper I1 LOW_BALANCE=1000000000000000000000
check "$KRC" 3 "balance below LOW_BALANCE: the pass completes, then exit 3"
check "$(grep -c "top it up" "$WORK/I1.log")" 1 "with a top-up warning"
keeper I2 KEEPER_PK=
check "$KRC" 2 "no KEEPER_PK: configuration error, exit 2"
keeper I3 CHAIN_ID=56
check "$KRC" 1 "an RPC that serves another chain: exit 1"
keeper I4 RPC=http://127.0.0.1:1
check "$KRC" 1 "an unreachable RPC: exit 1"
keeper I5 DRY_RUN=1 KEEPER_PK=
check "$KRC" 0 "a dry run needs no key and exits 0"
leak=0
for f in "$WORK"/*.log; do
  [ "$f" = "$WORK/anvil.log" ] && continue
  if grep -q -i -F -e "${KEEPER_PK#0x}" -e "${SHOOTER_PK#0x}" "$f"; then leak=1; fi
done
check "$leak" 0 "no private key appears in any keeper log"

flaky="$(grep -l "Fork Error" "$WORK"/*.log 2>/dev/null | grep -c -v -e anvil.log -e relay.log)"
check "$flaky" 0 "no keeper pass met a fork upstream error (a failure here is the network's, not the keeper's: rerun)"
echo "  relay: $(grep -c "failed" "$WORK/relay.log" 2>/dev/null || echo 0) upstream attempt(s) retried"

say "result: $PASS passed, $FAIL failed (logs in $WORK)"
[ "$FAIL" -eq 0 ]
