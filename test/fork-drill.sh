#!/usr/bin/env bash
# Fork drill: runs keeper.sh against a local anvil fork of BNB Chain testnet (97) and checks what it did.
# Every transaction goes to the local fork; nothing is sent to a live chain.
#
#   test/fork-drill.sh                                        (starts anvil on a free port, stops it at the end)
#   ANVIL_RPC=http://127.0.0.1:8545 test/fork-drill.sh        (uses an anvil fork of 97 that is already running)
#
# SHOOTER_PK (optional): the key that fires the shots on the fork; a fresh key is made when it is not set.
# The keeper and the rivals always get fresh keys. KEEPER_BASH picks the shell that runs keeper.sh (default: bash),
# KEEPER_SH the keeper under test (default: ./keeper.sh). DRILL_ONLY (optional) runs only the sections it names, e.g.
# DRILL_ONLY="J K" (each section fires its own shots; the setup and the closing checks always run).
# Needs anvil, cast, bc and python3 (test/fork-relay.py: anvil reads the public endpoint through it, with retries, so
# a dropped connection there does not strand a transaction in the fork's pool; in sections J to L and P a second relay
# with a fault rule, between the keeper and the fork, plays a node that answers one kind of call its own way, or a
# reader that lags behind the chain).
#
# The fork plays the Trigger Service's backend by impersonating the address that holds its TRIGGER_ROLE: it runs
# each shot's first request (the anchor) and never the second (the settle), which is exactly the case the keeper
# exists for. anvil (1.7.1, measured) writes each block's parent hash into the EIP-2935 history contract's ring as it
# mines, reading that ring slot from the public endpoint first; the drill writes an anchor block's hash into its slot
# (block % 8191) itself as well, so it does not depend on that.

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
FAULT_PID=""

fatal() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
say() {
  printf '\n== %s\n' "$*"
  if [ -n "$ANVIL_PID" ] && ! kill -0 "$ANVIL_PID" 2>/dev/null; then fatal "anvil (pid $ANVIL_PID) is gone; see $WORK/anvil.log"; fi
}
ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; }
check() { if [ "$1" = "$2" ]; then ok "$3 ($1)"; else bad "$3: got $1, want $2"; fi; }
want() { case " ${DRILL_ONLY:-all} " in *" all "* | *" $1 "*) return 0 ;; esac; return 1; } # want <section>

cleanup() { # only the processes this drill started
  if [ -n "$ANVIL_PID" ]; then kill "$ANVIL_PID" 2>/dev/null; fi
  if [ -n "$RELAY_PID" ]; then kill "$RELAY_PID" 2>/dev/null; fi
  if [ -n "$FAULT_PID" ]; then kill "$FAULT_PID" 2>/dev/null; fi
}
trap cleanup EXIT
free_port() { local p="$1"; while lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; do p=$((p + 1)); done; echo "$p"; }

if [ -n "${ANVIL_RPC:-}" ]; then
  A="$ANVIL_RPC"
else
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
# a failed anvil_mine goes on mining in the fork after cast gave up on it, under the drill's feet: stop there
mine() { c rpc anvil_mine "$(printf '0x%x' "${1:-1}")" >/dev/null || fatal "anvil_mine ${1:-1} failed"; }
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
# use_vault <index>: the shot helpers below work on this vault of the factory (vault 0 unless a section says so)
use_vault() {
  VAULT="$(num "$FACTORY" "vaults(uint256)(address)" "$1")"
  VAULT_LC="$(echo "$VAULT" | tr 'A-F' 'a-f')"
  TOKEN="$(num "$VAULT" "taxToken()(address)")"
  QUOTE="$(num "$VAULT" "vaultQuoteToken()(address)")"
  BULLET="$(num "$VAULT" "BULLET_TOKENS()(uint256)")"
  for x in "$VAULT" "$TOKEN" "$QUOTE" "$BULLET"; do [ -n "$x" ] || fatal "a read of vault #$1 came back empty"; done
}

use_vault 0
SERVICE="$(num "$VAULT" "triggerService()(address)")"
ROLE="$(num "$SERVICE" "TRIGGER_ROLE()(bytes32)")"
[ "$(num "$SERVICE" "hasRole(bytes32,address)(bool)" "$ROLE" "$OPERATOR")" = true ] || fatal "OPERATOR has no TRIGGER_ROLE"
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
# seed_history: set every slot of the EIP-2935 ring on the fork (to zero) in one batch. Mining a block reads its ring
# slot from the public endpoint first, about 0.4 s a block through the relay: 8,200 blocks would take an hour, far past
# cast's timeout. Once every slot is local they take seconds. The slots anvil then writes as it mines, and the ones
# fix_history writes, hold the real hashes; a slot left at zero only serves as a hash nobody asks for.
seed_history() {
  python3 - "$A" "$HISTORY" <<'EOF_SEED' || fatal "seeding the history ring failed"
import json, sys, urllib.request
url, history = sys.argv[1], sys.argv[2]
batch = [{"jsonrpc": "2.0", "id": i, "method": "anvil_setStorageAt", "params": [history, hex(i), "0x" + "00" * 32]}
         for i in range(8191)]
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
req = urllib.request.Request(url, data=json.dumps(batch).encode(), headers={"Content-Type": "application/json"})
with opener.open(req, timeout=300) as r:
    out = json.loads(r.read())
sys.exit(0 if len(out) == len(batch) and not [x for x in out if "error" in x] else 1)
EOF_SEED
}
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
mark() { cat "$WORK/state/claw-97-$VAULT_LC.from" 2>/dev/null; } # the keeper's low-water mark for the vault in use
set_mark() { printf '%s\n' "$1" >"$WORK/state/claw-97-$VAULT_LC.from"; }
six_hours() { c rpc evm_increaseTime "$(printf '0x%x' $((6 * 3600 + 5)))" >/dev/null; mine 1; }
word_of() { cast abi-encode "f(uint256)" "$1" | sed 's/^0x//'; } # a number as one ABI word, 64 hex digits
tx_of() { sed -En "s/.*$1 tx (0x[0-9a-f]+).*/\\1/p" "$2" | head -1; } # tx_of <call regex> <log>: its transaction
# rstatus <tx>: 1 if it succeeded, 0 if it reverted (cast 1.7.1 prints true or false; older releases 1 (success) or 0)
rstatus() {
  c receipt "$1" status 2>/dev/null | awk '{ s = $1 } END { if (s == "true" || s == "1") print 1; else if (s == "false" || s == "0") print 0; else print s }'
}
# fault_start <name> <method>:<call data prefix>[@<block>][=<result>|~<message>] [lag=<seconds>[@<block>]]: a second
# relay between the keeper and the fork, playing a node that answers that call its own way, and with lag= a reader
# that lags behind the chain (see test/fork-relay.py; an empty rule plays only the lagging reader); its own log is
# relay-<name>.log. Sets FAULT_URL, whose path is a made-up API key (FAULT_KEY) that must never appear in the keeper's
# log (the node's errors quote it). fault_stop stops it.
fault_start() {
  local n=0 name="$1"
  shift
  FAULT_PORT="$(free_port 28745)"
  FAULT_KEY="drill-secret-$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')"
  FAULT_URL="http://127.0.0.1:$FAULT_PORT/$FAULT_KEY"
  python3 test/fork-relay.py "$FAULT_PORT" "$A" "$@" 2>"$WORK/relay-$name.log" &
  FAULT_PID=$!
  until lsof -nP -iTCP:"$FAULT_PORT" -sTCP:LISTEN >/dev/null 2>&1; do
    n=$((n + 1))
    [ "$n" -gt 20 ] && fatal "the fault relay did not come up"
    sleep 0.5
  done
}
fault_stop() { kill "$FAULT_PID" 2>/dev/null; wait "$FAULT_PID" 2>/dev/null; FAULT_PID=""; }
yes_if() { if "$@"; then echo yes; else echo no; fi; } # yes_if <test...>: "yes" or "no", for check
grep_n() { local n; n="$(grep -c "$@" 2>/dev/null)"; echo "${n:-0}"; } # grep_n <grep args> <one file>: the count
lc() { tr 'A-F' 'a-f'; }
# took_tx <relay log>: the first transaction a ~ fault rule forwarded and the fork took
took_tx() { sed -En 's/.*forwarded eth_sendRawTransaction, and the upstream took it as (0x[0-9a-f]+).*/\1/p' "$1" | head -1; }
# state_via <id> <rpc>: the shot's status as the node at <rpc> reads it
state_via() {
  cast call "$VAULT" "shotState(uint256)(uint8,uint256,uint256,uint64,uint64,uint64,bool,uint256,uint256,uint256[])" "$1" \
    --rpc-url "$2" 2>&1 | awk '{ print $1; exit }'
}

# 0. before anything: the vault's queue is empty ------------------------------------------------------------------
if want 0; then
say "0. an empty queue and nothing overdue: the pass is a no-op"
check "$(qhead) $(qtail)" "$(qtail) $(qtail)" "the settle queue is empty (head = tail)"
nonce0="$(c nonce "$KEEPER")"
keeper Z0
check "$KRC" 0 "keeper exit code"
check "$(c nonce "$KEEPER")" "$nonce0" "no transaction sent"
check "$(grep -c "nothing to do" "$WORK/Z0.log")" 1 "the pass reports nothing to do"

fi

# A. the service anchors three shots and never delivers their settle requests -----------------------------------------
if want A; then
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

fi

# B. a shot the service never anchors ---------------------------------------------------------------------------------
if want B; then
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

fi

# C. nothing to do -----------------------------------------------------------------------------------------------------
if want C; then
say "C. rerun twice with an empty queue: no-ops"
check "$(qhead)" "$(qtail)" "the queue is empty"
nonce0="$(c nonce "$KEEPER")"
keeper C1
check "$KRC" 0 "keeper exit code"
keeper C2
check "$KRC" 0 "keeper exit code"
check "$(c nonce "$KEEPER")" "$nonce0" "no transaction sent"
check "$(cat "$WORK/C1.log" "$WORK/C2.log" | grep -c "nothing to do")" 2 "both passes report nothing to do"

fi

# D. thirty shots, anchored in three batches, SWEEP_MAX=20 --------------------------------------------------------------
if want D; then
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

fi

# E. spent shots ahead of a ready one -----------------------------------------------------------------------------------
if want E; then
say "E. two anchors that expired before the keeper ran, ahead of a ready shot: closed in order, no loop"
E1="$(fire 1 0)" || fatal "fire failed"
E2="$(fire 1 1)" || fatal "fire failed"
anchor_by_service "$E1" "$E2"
seed_history
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

fi

# F. races ------------------------------------------------------------------------------------------------------------
if want F; then
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
check "$(rstatus "$rtx")" 1 "the rival's settleFallback succeeded"
ktx="$(sed -En "s/.*settleFallback\\($raced\\) (0x[0-9a-f]+): shot $raced was closed by someone else first.*/\\1/p" "$WORK/F2.log")"
check "$(rstatus "$ktx")" 0 "the keeper's own transaction was mined and reverted"
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

fi

# G. an unanchored shot buried under later shots ----------------------------------------------------------------------
if want G; then
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

fi

# H. a real failure: a ready head the chain refuses to settle ----------------------------------------------------------
if want H; then
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

fi

# I. exit codes of the other outcomes ------------------------------------------------------------------------------------
if want I; then
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
fi

# J. a read that keeps failing part-way through the overdue scan ------------------------------------------------------
if want J; then
say "J. a read that keeps failing part-way through the overdue scan: the mark keeps what was read; ARM_MAX caps a pass"
J="$(fire_n 6)" || fatal "fire failed"
# shellcheck disable=SC2086
anchor_by_service $J
mine 2
# shellcheck disable=SC2086
fix_history_of $J
keeper J0
check "$KRC" 0 "keeper exit code"
# shellcheck disable=SC2086
check "$(count5 $J)" 6 "the six shots settled"
# shellcheck disable=SC2086
set -- $J
set_mark "$1" # a mark from before these six shots, as an older saved state holds
# a node that refuses every read of the fourth shot (shotState($4)), and quotes its own URL and key in the error
fault_start J "eth_call:0xa5153884$(word_of "$4")"
keeper J1 RPC="$FAULT_URL" LOW_BALANCE=1000000000000000000000
fault_stop
check "$(yes_if [ "$(grep_n "refused eth_call" "$WORK/relay-J.log")" -ge 1 ])" yes "the node refused the reads of shot $4"
check "$KRC" 1 "a read that kept failing: exit 1"
check "$(mark)" "$4" "the new mark is shot $4: the three shots read before the failure are not read again"
check "$(grep_n "stopped on a read failure" "$WORK/J1.log")" 1 "the log says the scan stopped on a read failure"
check "$(grep_n "top it up" "$WORK/J1.log")" 1 "the low-balance warning is printed on a failed pass too"
check "$(grep_n -e "$FAULT_KEY" -e "127.0.0.1" "$WORK/J1.log")" 0 "the node's error quoted the RPC URL and its key; the log shows neither"
check "$(yes_if [ "$(grep_n "drill fault at <rpc>; key <rpc>" "$WORK/J1.log")" -ge 1 ])" yes "it shows that error with both masked"
keeper J2 ARM_MAX=2
check "$KRC" 0 "keeper exit code"
check "$(mark)" "$6" "ARM_MAX=2: the pass read shots $4 and $5 only, and left the mark at shot $6"
check "$(grep_n "ARM_MAX (2) reached at shot $6" "$WORK/J2.log")" 1 "and said the next pass goes on from there"
keeper J3
check "$KRC" 0 "keeper exit code"
check "$(mark)" "$(num "$VAULT" "nextShotId()(uint256)")" "the next pass read on to the end"
fi

# K. arms that the node's gas estimate stops or starves ---------------------------------------------------------------
if want K; then
say "K. an arm that never left (its gas estimate reverted) is judged at once; one that ran out of gas says so"
K1="$(fire 1 0)" || fatal "fire failed"
six_hours
check "$(status "$K1")" 2 "shot $K1 overdue"
nonce0="$(c nonce "$KEEPER")"
fault_start K "eth_estimateGas:0xb992f766$(word_of "$K1")" # armFallback(K1): the estimate reverts
t0="$(date +%s)"
keeper K1 RPC="$FAULT_URL"
took=$(($(date +%s) - t0))
fault_stop
check "$(yes_if [ "$(grep_n "refused eth_estimateGas" "$WORK/relay-K.log")" -ge 1 ])" yes "the node refused the arm's gas estimate"
check "$KRC" 1 "exit 1: the shot is still overdue"
check "$(grep_n "FAILED: armFallback($K1) not sent" "$WORK/K1.log")" 1 "reported as not sent"
check "$(grep_n "watching the chain" "$WORK/K1.log")" 0 "judged at once: no 30 s watch for a transaction that never left"
check "$(yes_if [ "$took" -lt 30 ])" yes "the whole pass took $took s, less than the 30 s watch"
check "$(c nonce "$KEEPER") $(status "$K1")" "$nonce0 2" "nothing was sent; the shot is still overdue"
fault_start K2 "eth_estimateGas:0xb992f766$(word_of "$K1")=0x7530" # an estimate of 30,000 gas: too little
keeper K2 RPC="$FAULT_URL"
fault_stop
check "$KRC" 1 "exit 1: the arm failed and the shot is still overdue"
ktx="$(tx_of "FAILED: armFallback\\($K1\\)" "$WORK/K2.log")"
check "$(rstatus "$ktx") $(c tx "$ktx" gas 2>/dev/null)" "0 30000" \
  "the arm was mined with the 30,000 gas the node estimated, and failed"
check "$(grep_n "FAILED: armFallback($K1) tx $ktx reverted (out of gas" "$WORK/K2.log")" 1 "the log gives the reason: out of gas"
check "$(grep_n "SUMMARY: .* transactions 1, .* failures 1," "$WORK/K2.log")" 1 "the summary counts that failed transaction and the failure"
check "$(status "$K1")" 2 "shot $K1 still overdue"
keeper K3
check "$KRC" 0 "keeper exit code"
check "$(grep_n "armFallback($K1) tx" "$WORK/K3.log")" 1 "the next pass armed it"
mine 2
fix_history "$(anchor_of "$K1")"
keeper K4
check "$KRC" 0 "keeper exit code"
check "$(status "$K1")" 5 "and the pass after settled it"
fi

# L. the reason of a failed settle ------------------------------------------------------------------------------------
if want L; then
say "L. a failed settle's reason is the one its own block gives, not a later simulation's"
L1="$(fire 1 0)" || fatal "fire failed"
anchor_by_service "$L1"
mine 2
aL="$(anchor_of "$L1")"
c rpc anvil_setStorageAt "$HISTORY" "$(printf '0x%x' $((aL % 8191)))" 0x0000000000000000000000000000000000000000000000000000000000000000 >/dev/null
check "$(status "$L1")" 4 "shown ready (its anchor is mined), but its anchor hash is not served"
# a node whose simulation of settleFallback at the latest block fails with an error of its own; a call for a given
# block (a number, or the hash cast replays a failed transaction at) goes through
fault_start L "eth_call:0x3e4fc037@latest"
ctl="$(cast call "$VAULT" "settleFallback(uint256)" "$L1" --from "$KEEPER" --rpc-url "$FAULT_URL" 2>&1)"
check "$(printf '%s\n' "$ctl" | grep -c "drill fault")" 1 "control: a simulation at the latest block through this node gets the node's error"
keeper L1 RPC="$FAULT_URL"
fault_stop
check "$KRC" 1 "keeper exit code: a real failure"
check "$(grep_n "FAILED: settleFallback($L1) tx 0x[0-9a-f]* reverted (GameVault: anchor hash unavailable" "$WORK/L1.log")" 1 \
  "the reason is the vault's own, from the transaction's block"
check "$(grep_n "drill fault" "$WORK/L1.log")" 0 "not a later simulation's"
fix_history "$aL"
keeper L2
check "$KRC" 0 "keeper exit code once the hash is served"
check "$(status "$L1")" 5 "settled by the next pass"
fi

# M. two vaults ----------------------------------------------------------------------------------------------------------
if want M; then
say "M. two vaults: vault #1's ready shot is settled before vault #0's overdue shot is armed"
[ "$(num "$FACTORY" "vaultCount()(uint256)")" -ge 2 ] || fatal "the factory on the fork has fewer than two vaults"
use_vault 1
V1="$VAULT"
unlocked "$PORTAL" "$TOKEN" "transfer(address,uint256)" "$SHOOTER" "$(echo "$BULLET * 10" | bc)"
c send "$TOKEN" "approve(address,uint256)" "$VAULT" "$(echo "$BULLET * 10" | bc)" --private-key "$SHOOTER_PK" >/dev/null
use_vault 0
M0="$(fire 1 0)" || fatal "fire failed"
six_hours
use_vault 1
M1="$(fire 1 1)" || fatal "fire failed"
anchor_by_service "$M1"
mine 2
fix_history_of "$M1"
check "$(status "$M1")" 4 "vault #1: shot $M1 ready"
use_vault 0
check "$(status "$M0")" 2 "vault #0: shot $M0 overdue"
keeper M1
check "$KRC" 0 "keeper exit code"
stx="$(tx_of "settleFallback\\($M1\\)" "$WORK/M1.log")"
atx="$(tx_of "armFallback\\($M0\\)" "$WORK/M1.log")"
check "$(c tx "$stx" to 2>/dev/null | tr 'A-F' 'a-f') $(c tx "$atx" to 2>/dev/null | tr 'A-F' 'a-f')" "$(echo "$V1 $VAULT" | tr 'A-F' 'a-f')" \
  "one settle on vault #1, one arm on vault #0"
sn="$(c tx "$stx" nonce 2>/dev/null)"
an="$(c tx "$atx" nonce 2>/dev/null)"
check "$(yes_if [ "${sn:-x}" -lt "${an:-x}" ] 2>/dev/null)" yes "vault #1's settle went out before vault #0's arm (nonce ${sn:-?}, then ${an:-?})"
mine 2
fix_history "$(anchor_of "$M0")"
keeper M2
check "$KRC" 0 "keeper exit code"
check "$(status "$M0")" 5 "vault #0's shot settled on the next pass"
use_vault 1
check "$(status "$M1")" 5 "vault #1's shot stays settled"
use_vault 0
fi

# N. DRY_RUN -------------------------------------------------------------------------------------------------------------
if want N; then
say "N. DRY_RUN is 1 (read only), 0 or empty; anything else is a configuration error, with a ready shot waiting"
N1="$(fire 1 0)" || fatal "fire failed"
anchor_by_service "$N1"
mine 2
fix_history_of "$N1"
nonce0="$(c nonce "$KEEPER")"
keeper N1 DRY_RUN=true
check "$KRC" 2 "DRY_RUN=true: configuration error, exit 2"
check "$(c nonce "$KEEPER") $(status "$N1")" "$nonce0 4" "nothing sent: the ready shot is still open"
keeper N2 DRY_RUN=yes
check "$KRC" 2 "DRY_RUN=yes: exit 2 as well"
keeper N3 DRY_RUN=
check "$KRC" 0 "DRY_RUN empty: a normal pass"
check "$(status "$N1")" 5 "which settled the ready shot"
fi

# O. a warning on cast's standard error ----------------------------------------------------------------------------------
if want O; then
say "O. a warning cast prints on its standard error (a nightly build does, on every call) spoils no value it read"
mkdir -p "$WORK/warncast"
printf '#!/bin/sh\necho "Warning: This is a nightly build of Foundry (the drill'"'"'s stand-in)" >&2\nexec "%s" "$@"\n' "$(command -v cast)" >"$WORK/warncast/cast"
chmod +x "$WORK/warncast/cast"
check "$(PATH="$WORK/warncast:$PATH" cast chain-id --rpc-url "$A" 2>&1 >/dev/null | grep -c "nightly build")" 1 "control: the stand-in cast prints the warning"
O1="$(fire 1 0)" || fatal "fire failed"
anchor_by_service "$O1"
mine 2
fix_history_of "$O1"
keeper O1 PATH="$WORK/warncast:$PATH"
check "$KRC" 0 "keeper exit code"
check "$(grep_n -e "failed" -e "ERROR" "$WORK/O1.log")" 0 "no read failed, no error"
check "$(status "$O1")" 5 "the ready shot settled"
fi

# P. a node that takes a transaction and answers "nonce too low"; arms the vault refuses as already done ---------------
if want P; then
say "P1. an own settle the node took, then answered \"nonce too low\": watched, found closed, not sent twice"
P1="$(fire 1 0)" || fatal "fire failed"
anchor_by_service "$P1"
mine 2
fix_history_of "$P1"
check "$(status "$P1")" 4 "shot $P1 ready"
nonce0="$(c nonce "$KEEPER")"
# a node that forwards settleFallback(P1) to the fork and answers "nonce too low" all the same, and whose eth_call at
# the latest block answers as of the block before that transaction for 9 s after it (a reader that lags behind)
fault_start P1 "eth_sendRawTransaction:0x3e4fc037$(word_of "$P1")~nonce too low" lag=9
keeper P1 RPC="$FAULT_URL"
fault_stop
ptx="$(took_tx "$WORK/relay-P1.log")"
check "$(grep_n "forwarded eth_sendRawTransaction, and the upstream took it" "$WORK/relay-P1.log")" 1 \
  "the node took settleFallback($P1) once, and answered nonce too low"
check "$(rstatus "$ptx") $(c tx "$ptx" from 2>/dev/null | lc)" "1 $(echo "$KEEPER" | lc)" \
  "control: that was the keeper's own transaction, and it went through"
check "$(yes_if [ "$(grep_n "answered eth_call as of block" "$WORK/relay-P1.log")" -ge 1 ])" yes \
  "control: the node's reads lagged behind that transaction"
check "$KRC" 0 "keeper exit code"
check "$(status "$P1")" 5 "shot $P1 settled"
check "$(($(c nonce "$KEEPER") - nonce0))" 1 "one transaction: settleFallback($P1) was not sent a second time"
check "$(grep_n "settleFallback($P1) came back without a receipt (.*nonce too low.*), but shot $P1 is closed now" "$WORK/P1.log")" 1 \
  "counted as closed after watching the chain"
check "$(grep_n -e "not sent" -e "FAILED" "$WORK/P1.log")" 0 "no line calls it not sent, or a failure"
check "$(grep_n "SUMMARY: .* done without a receipt 1, failures 0," "$WORK/P1.log")" 1 "the summary counts it done without a receipt"

say "P2. an own arm the node took, then answered \"nonce too low\": watched, found anchored"
P2="$(fire 1 1)" || fatal "fire failed"
six_hours
check "$(status "$P2")" 2 "shot $P2 overdue"
nonce0="$(c nonce "$KEEPER")"
fault_start P2 "eth_sendRawTransaction:0xb992f766$(word_of "$P2")~nonce too low" lag=9
keeper P2 RPC="$FAULT_URL"
fault_stop
ptx="$(took_tx "$WORK/relay-P2.log")"
check "$(grep_n "forwarded eth_sendRawTransaction, and the upstream took it" "$WORK/relay-P2.log")" 1 \
  "the node took armFallback($P2) once, and answered nonce too low"
check "$(rstatus "$ptx") $(c tx "$ptx" from 2>/dev/null | lc) $(anchor_of "$P2")" \
  "1 $(echo "$KEEPER" | lc) $(($(c receipt "$ptx" blockNumber 2>/dev/null) + 1))" \
  "control: that was the keeper's own transaction, and it anchored the shot at the block after its own"
check "$(yes_if [ "$(grep_n "answered eth_call as of block" "$WORK/relay-P2.log")" -ge 1 ])" yes \
  "control: the node's reads lagged behind that transaction"
check "$KRC" 0 "keeper exit code"
check "$(($(c nonce "$KEEPER") - nonce0))" 1 "one transaction"
check "$(grep_n "armFallback($P2) came back without a receipt (.*nonce too low.*), but shot $P2 is anchored now" "$WORK/P2.log")" 1 \
  "counted as anchored after watching the chain"
check "$(grep_n -e "not sent" -e "FAILED" "$WORK/P2.log")" 0 "no line calls it not sent, or a failure"
check "$(grep_n "SUMMARY: .* done without a receipt 1, failures 0," "$WORK/P2.log")" 1 "the summary counts it done without a receipt"
mine 2
fix_history "$(anchor_of "$P2")"
keeper P2b
check "$KRC $(status "$P2")" "0 5" "the next pass settled shot $P2"

say "P3. an arm the vault refuses as already anchored (a rival anchored it first), through a reader that lags behind"
P3="$(fire 1 2)" || fatal "fire failed"
six_hours
check "$(status "$P3")" 2 "shot $P3 overdue"
lagb="$(c block-number)"
c send "$VAULT" "armFallback(uint256)" "$P3" --private-key "$RIVAL_PK" >/dev/null
check "$(yes_if [ "$(anchor_of "$P3")" != 0 ])" yes "a rival anchored shot $P3 first"
nonce0="$(c nonce "$KEEPER")"
# a node whose eth_call at the latest block answers as of the block before the rival's arm; its gas estimates are
# the chain's own
fault_start P3 "" "lag=600@$lagb"
check "$(state_via "$P3" "$FAULT_URL")" 2 "control: through this node, shot $P3 still looks overdue"
keeper P3 RPC="$FAULT_URL"
fault_stop
check "$KRC" 0 "exit 0: a race lost to someone else, not a failure"
check "$(grep_n "armFallback($P3) not sent (.*already anchored.*): the vault refused it, so shot $P3 was anchored or closed by someone else first" "$WORK/P3.log")" 1 \
  "counted as lost to someone else, on the vault's own refusal"
check "$(grep_n "FAILED" "$WORK/P3.log")" 0 "no failure reported"
check "$(grep_n "SUMMARY: .* races lost to others 1, .* failures 0," "$WORK/P3.log")" 1 "the summary counts one race lost"
check "$(c nonce "$KEEPER")" "$nonce0" "nothing sent"
check "$(mark)" "$P3" "the mark stays at shot $P3, which the reader still showed overdue"
mine 2
fix_history "$(anchor_of "$P3")"
keeper P3b
check "$KRC $(status "$P3") $(mark)" "0 5 $(num "$VAULT" "nextShotId()(uint256)")" \
  "the next pass, reading the chain as it is, settled shot $P3 and moved the mark past it"

say "P4. an arm the vault refuses as already settled (a rival armed and settled it first), through a reader that lags behind"
P4="$(fire 1 0)" || fatal "fire failed"
six_hours
lagb="$(c block-number)"
c send "$VAULT" "armFallback(uint256)" "$P4" --private-key "$RIVAL_PK" >/dev/null
mine 2
fix_history "$(anchor_of "$P4")"
c send "$VAULT" "settleFallback(uint256)" "$P4" --gas-limit 3000000 --private-key "$RIVAL_PK" >/dev/null
check "$(status "$P4")" 5 "a rival armed and settled shot $P4 first"
nonce0="$(c nonce "$KEEPER")"
fault_start P4 "" "lag=600@$lagb"
check "$(state_via "$P4" "$FAULT_URL")" 2 "control: through this node, shot $P4 still looks overdue"
keeper P4 RPC="$FAULT_URL"
fault_stop
check "$KRC" 0 "exit 0: a race lost to someone else, not a failure"
check "$(grep_n "armFallback($P4) not sent (.*already settled.*): the vault refused it, so shot $P4 was anchored or closed by someone else first" "$WORK/P4.log")" 1 \
  "counted as lost to someone else, on the vault's own refusal"
check "$(grep_n "FAILED" "$WORK/P4.log") $(c nonce "$KEEPER") $(mark)" "0 $nonce0 $P4" "no failure, nothing sent, and the mark stays at shot $P4"
keeper P4b
check "$KRC $(mark)" "0 $(num "$VAULT" "nextShotId()(uint256)")" "the next pass moved the mark past it"
fi

# closing checks: every keeper log -------------------------------------------------------------------------------
leak=0
urls=0
for f in "$WORK"/*.log; do
  case "$f" in "$WORK/anvil.log" | "$WORK"/relay*.log) continue ;; esac
  if grep -q -i -F -e "${KEEPER_PK#0x}" -e "${SHOOTER_PK#0x}" "$f"; then leak=1; fi
  # every RPC of the drill is on 127.0.0.1 (the fork, the fault relays with their made-up keys, an unreachable port)
  if grep -q -F -e "127.0.0.1" -e "drill-secret-" "$f"; then urls=$((urls + 1)); echo "  RPC URL shown in $f"; fi
done
check "$leak" 0 "no private key appears in any keeper log"
check "$urls" 0 "no RPC URL or key appears in any keeper log"

flaky="$(grep -l "Fork Error" "$WORK"/*.log 2>/dev/null | grep -c -v -e anvil.log -e relay.log)"
check "$flaky" 0 "no keeper pass met a fork upstream error (a failure here is the network's, not the keeper's: rerun)"
echo "  relay: $(grep_n "failed" "$WORK/relay.log") upstream attempt(s) retried"

say "result: $PASS passed, $FAIL failed (logs in $WORK)"
[ "$FAIL" -eq 0 ]
