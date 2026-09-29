#!/usr/bin/env bash
# Claw keeper: one pass over every vault of the claw factory on one chain.
#
# For each vault the factory has made, the same pass as the vault repository's reviewed sweep (Play STEP=sweep):
#   1. The settle queue, from its head. While the head shot's anchor block is mined (READY, status 4) or its anchor's
#      hash has left the history window (spent, status 6), settleFallback(head): one transaction per shot, strictly
#      in queue order, each with an explicit gas limit (SETTLE_GAS, 3,000,000), never the node's bare estimate — the
#      vault refuses to pay a win without the gas to deliver it. A ready shot is settled and paid to its shooter; a
#      spent one is closed and pays nothing. At most SWEEP_MAX shots a vault a pass; the next pass goes on.
#   2. The overdue shots. From the vault's low-water mark (kept in STATE_DIR) up to nextShotId, every shot that
#      still has no anchor STALE (6 h) after its fire (status 2) gets armFallback. The new mark is the first id that
#      had no anchor in this pass; every shot below it is anchored or closed, for good. A lost state file only makes
#      the next pass rescan from shot 1.
#
# It spends gas only: winnings always go to each shot's shooter. It is idempotent and safe next to the Trigger
# Service, players and other keepers: a transaction that loses a race is checked against the chain, and a shot that
# someone else closed or armed first counts as done, not as a failure. A transaction that comes back without a receipt
# (cast gave up waiting, or the node answered with an error after taking it) is judged the same way after watching the
# chain for 30 s; only a shot still open then is a failure.
#
# Environment:
#   CHAIN_ID     56 or 97 (required)
#   KEEPER_PK    the keeper wallet's private key (required unless DRY_RUN=1); it pays gas and nothing else
#   RPC          RPC URL (default: a public endpoint for the chain)
#   FACTORY      claw factory (default: the one deployed on the chain)
#   STATE_DIR    where the low-water marks are kept (default: ./state)
#   SETTLE_GAS   gas limit of every settleFallback (default 3000000)
#   SWEEP_MAX    most queue shots handled per vault per pass (default 500)
#   LOW_BALANCE  wei; below it the pass still runs, then exits 3 so the run shows as failed
#                (default 0.005 BNB on 56, 0.001 test BNB on 97; 0 turns the check off)
#   DRY_RUN=1    read only: print what would be sent, send nothing, keep the marks
#   ETH_GAS_PRICE  read by cast (legacy gas price, e.g. 0.1gwei); default: the node's eth_gasPrice
#
# Exit codes: 0 done (including nothing to do and races lost to others), 1 an RPC read that kept failing or a
# transaction that did not go through while its shot stayed open, 2 configuration error (CHAIN_ID, KEEPER_PK, cast
# missing), 3 keeper balance below LOW_BALANCE (the pass itself completed).
#
# Needs bash (3.2 or later) and cast from Foundry. Nothing else.

set -u
set -o pipefail

TAG="[${CHAIN_ID:-?}]"
log() { printf '%s %s %s\n' "$(date -u +%H:%M:%S)" "$TAG" "$*"; }
die() { log "ERROR: $1" >&2; exit "${2:-2}"; } # die <message> [exit code, default 2]

case "${CHAIN_ID:-}" in
  56) DEFAULT_FACTORY=0x8305F4F217AAac4e54Fa5C6bc5dfB7098d92e85f; DEFAULT_RPC=https://bsc-mainnet.public.blastapi.io; DEFAULT_LOW=5000000000000000 ;;
  97) DEFAULT_FACTORY=0xd675158707aFE1165d84A0e478FD02BF9f3Ddc5b; DEFAULT_RPC=https://bsc-testnet-rpc.publicnode.com; DEFAULT_LOW=1000000000000000 ;;
  *) die "set CHAIN_ID to 56 (BNB Chain) or 97 (BNB Chain testnet)" ;;
esac
RPC="${RPC:-$DEFAULT_RPC}"
FACTORY="${FACTORY:-$DEFAULT_FACTORY}"
STATE_DIR="${STATE_DIR:-./state}"
SETTLE_GAS="${SETTLE_GAS:-3000000}"
SWEEP_MAX="${SWEEP_MAX:-500}"
LOW_BALANCE="${LOW_BALANCE:-$DEFAULT_LOW}"
DRY_RUN="${DRY_RUN:-0}"

whole() { case "$2" in '' | *[!0-9]*) die "$1 must be a whole number" ;; esac; }
whole SETTLE_GAS "$SETTLE_GAS"
whole SWEEP_MAX "$SWEEP_MAX"
whole LOW_BALANCE "$LOW_BALANCE"
[ "$SETTLE_GAS" -ge 1000000 ] || die "SETTLE_GAS must be at least 1000000 (the reviewed policy uses 3000000)"
case "$FACTORY" in 0x*) ;; *) die "FACTORY is not an address" ;; esac
case "${FACTORY#0x}" in *[!0-9a-fA-F]*) die "FACTORY is not an address" ;; esac
[ "${#FACTORY}" -eq 42 ] || die "FACTORY is not an address"
command -v cast >/dev/null 2>&1 || die "cast (Foundry) is not installed"

# Event topics (from the vault's ABI).
T_SETTLED=0x5ff90b03a22f6659909036f685d15b0ffeb0302d111f4b79c5655b27787a39d4 # Settled(uint256,address,uint256,uint8,bytes32,uint256,uint256[])
T_OWED=0x7393c924ac30f9256e6cebcfb78841b1e7ef11bf8b09d87c2257b32b8063c979    # Owed(address,uint256)

FAILURES=0
LOST=0    # transactions mined and reverted because another settler or arm came first
UNSEEN=0  # transactions with no receipt whose shot was closed or anchored anyway (by others, or by that transaction)
LAST_ERR=""
NOSEND_WAIT=30 # seconds to watch the chain after a transaction that came back without a receipt

# The last line of an error, one line, at most 240 characters.
short_err() { printf '%s' "$1" | tr '\r' '\n' | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-240; }

# rd <to> <sig> [args and cast options...]: eth_call (latest block unless --block is given), raw return data on
# stdout. Three tries, 2 s apart.
rd() {
  local out n=0
  while :; do
    if out="$(cast call "$@" --rpc-url "$RPC" 2>&1)"; then
      case "$out" in 0x*) printf '%s' "$out"; return 0 ;; esac
    fi
    n=$((n + 1))
    if [ "$n" -ge 3 ]; then LAST_ERR="$(short_err "$out")"; return 1; fi
    sleep 2
  done
}

# word <hex> <i>: the i-th 32-byte word of ABI data (64 hex characters, no 0x); fails if the data is too short.
word() {
  local h="${1#0x}"
  local off=$((64 * $2))
  [ "${#h}" -ge $((off + 64)) ] || return 1
  printf '%s' "${h:$off:64}"
}
# small <word>: a word as a decimal number (values below 2^63: counts, ids, block numbers, statuses).
small() { printf '%d' "$((16#${1:48:16}))"; }
# addr <word>: the address in a word, lower case.
addr() { printf '0x%s' "$(printf '%s' "${1:24:40}" | tr '[:upper:]' '[:lower:]')"; }
short() { printf '%s…%s' "${1:0:6}" "${1:38:4}"; }

# rdnum <to> <sig> [args and cast options...]: a call returning one small number.
rdnum() {
  local raw w
  raw="$(rd "$@")" || return 1
  w="$(word "$raw" 0)" || { LAST_ERR="short return data from $2"; return 1; }
  small "$w"
}

# shot_state <vault> <id> [cast options...]: sets ST (live status) and ANCHOR (anchor block, 0 if none) from
# shotState(id): 1 pending, 2 overdue, 3 anchored (block not mined), 4 ready, 5 settled, 6 spent.
shot_state() {
  local v="$1" id="$2" raw w0 w5
  shift 2
  raw="$(rd "$v" "shotState(uint256)" "$id" "$@")" || return 1
  if ! w0="$(word "$raw" 0)" || ! w5="$(word "$raw" 5)"; then
    LAST_ERR="short return data from shotState($id)"
    return 1
  fi
  ST="$(small "$w0")"
  ANCHOR="$(small "$w5")"
}

# send <to> <sig> [args and cast options...]: sign and send from the keeper, wait for the receipt.
# Sets TX_HASH, TX_OK (1 mined and succeeded, 0 otherwise), TX_GAS, TX_BLOCK and TX_JSON. Returns 1 when nothing
# came back mined (not sent, or no receipt): the caller re-reads the chain to learn what happened.
send() {
  local out
  TX_HASH="" TX_OK=0 TX_GAS="" TX_BLOCK="" TX_JSON=""
  if ! out="$(cast send "$@" --legacy --private-key "$KEEPER_PK" --rpc-url "$RPC" --json 2>&1)"; then
    LAST_ERR="$(short_err "$out")"
    return 1
  fi
  TX_JSON="$out"
  TX_HASH="$(printf '%s' "$out" | sed -n 's/.*"transactionHash":"\(0x[0-9a-fA-F]*\)".*/\1/p' | head -1)"
  TX_GAS="$(printf '%s' "$out" | sed -n 's/.*"gasUsed":"\(0x[0-9a-fA-F]*\)".*/\1/p' | head -1)"
  TX_BLOCK="$(printf '%s' "$out" | sed -n 's/.*"blockNumber":"\(0x[0-9a-fA-F]*\)".*/\1/p' | head -1)"
  [ -n "$TX_GAS" ] && TX_GAS="$((16#${TX_GAS#0x}))"
  [ -n "$TX_BLOCK" ] && TX_BLOCK="$((16#${TX_BLOCK#0x}))"
  case "$out" in *'"status":"0x1"'*) TX_OK=1 ;; esac
  if [ -z "$TX_HASH" ]; then LAST_ERR="no receipt in cast's answer: $(short_err "$out")"; return 1; fi
  return 0
}

# may_be_out: whether a transaction that came back without a receipt may still have gone out (cast gave up waiting
# for it, or the node took it and answered with an error): anything but an error that proves it was never accepted.
may_be_out() {
  case "$LAST_ERR" in
    *"insufficient funds"* | *"invalid private key"* | *"Invalid private key"*) return 1 ;;
  esac
  return 0
}

# at_tx_block: the cast option that reads the chain as of the last transaction's block (empty when it has none),
# so a re-check after a failed transaction never asks a node that has not seen that block yet.
at_tx_block() { [ -z "$TX_BLOCK" ] || printf '%s %s' --block "$TX_BLOCK"; }

# report_settled <vault>: one line on the shot the last transaction closed, from its Settled log (and Owed, for a
# delivery the shooter's side refused, held for pickup). Sets REPORT (empty if the receipt's logs cannot be read).
report_settled() {
  local v="$1" logs line t0 t1 t2 data via payout who owed=" "
  REPORT=""
  logs="$(printf '%s' "$TX_JSON" | tr 'A-F' 'a-f' | tr '{' '\n' | grep -F "\"address\":\"$v\"")" || return 0
  while IFS= read -r line; do
    read -r t0 t1 t2 _ <<EOT
$(printf '%s' "$line" | sed -n 's/.*"topics":\["\([^]]*\)"\].*/\1/p' | sed 's/0x//g; s/","/ /g')
EOT
    [ "0x${t0:-}" = "$T_OWED" ] && owed="$owed$(addr "$t1") "
  done <<EOL
$logs
EOL
  while IFS= read -r line; do
    read -r t0 t1 t2 _ <<EOT
$(printf '%s' "$line" | sed -n 's/.*"topics":\["\([^]]*\)"\].*/\1/p' | sed 's/0x//g; s/","/ /g')
EOT
    [ "0x${t0:-}" = "$T_SETTLED" ] || continue
    data="$(printf '%s' "$line" | sed -n 's/.*"data":"\(0x[0-9a-f]*\)".*/\1/p')"
    via="$(small "$(word "$data" 0)")"
    payout="$(cast to-dec "0x$(word "$data" 2)" 2>/dev/null || printf '?')"
    who="$(addr "$t2")"
    if [ "$via" = 3 ]; then
      REPORT="shot $(small "$t1") spent (its anchor's hash had left the history): closed, pays nothing"
    elif [ "$payout" = 0 ]; then
      REPORT="shot $(small "$t1") settled: no win"
    else
      case "$owed" in
        *" $who "*) REPORT="shot $(small "$t1") settled: payout $(cast from-wei "$payout" 2>/dev/null) to shooter $(short "$who"), held in the vault for the shooter (Owed; withdrawOwed collects it)" ;;
        *) REPORT="shot $(small "$t1") settled: payout $(cast from-wei "$payout" 2>/dev/null) delivered to shooter $(short "$who")" ;;
      esac
    fi
  done <<EOL
$logs
EOL
}

# ------------------------------------------------------------------------------------------------ the settle queue

# settle_queue <vault>: close ready and spent shots from the head, one settleFallback each. Sets Q_CLOSED (closed by
# this keeper), Q_TXS (transactions mined) and Q_NOTE (why the pass stopped); returns 1 on a failure.
settle_queue() {
  local v="$1" head tail id newhead why waited tried=0 cursor="" resent="" stale="" floor=0 behind=0
  Q_CLOSED=0 Q_TXS=0 Q_NOTE=""
  while :; do
    if [ "$tried" -ge "$SWEEP_MAX" ]; then
      Q_NOTE="SWEEP_MAX ($SWEEP_MAX) reached; the next pass goes on"
      break
    fi
    if [ -n "$cursor" ]; then
      head="$cursor" # DRY_RUN: walk the queue without moving it
    elif ! head="$(rdnum "$v" "queueHead()")"; then
      log "  read failed: $LAST_ERR"
      return 1
    fi
    # The head only moves forward, and the keeper's own last transaction put it at `floor` or beyond. A lower head
    # comes from a load-balanced RPC node that has not seen that block yet: wait for it rather than resend a shot
    # that is already closed.
    if [ "$head" -lt "$floor" ]; then
      behind=$((behind + 1))
      if [ "$behind" -gt 5 ]; then
        Q_NOTE="the RPC still shows the queue head before the keeper's own last settle; left to the next pass"
        break
      fi
      sleep 2
      continue
    fi
    behind=0
    tail="$(rdnum "$v" "queueTail()")" || { log "  read failed: $LAST_ERR"; return 1; }
    if [ "$head" -ge "$tail" ]; then
      Q_NOTE="queue empty"
      break
    fi
    id="$(rdnum "$v" "queuedShot(uint256)" "$head")" || { log "  read failed: $LAST_ERR"; return 1; }
    shot_state "$v" "$id" || { log "  read failed: $LAST_ERR"; return 1; }
    case "$ST" in
      4 | 6) ;;
      3) # the head's anchor is not mined yet: nor is any behind it (anchors are fixed in queue order)
        Q_NOTE="head shot $id: anchor block $ANCHOR not mined yet"
        break
        ;;
      5) # closed by someone else between the two reads: look at the new head (an RPC that keeps answering like this
        # is lagging behind itself: leave the rest to the next pass)
        if [ "$stale" = "$id" ]; then
          Q_NOTE="the RPC still shows settled shot $id at the head; left to the next pass"
          break
        fi
        stale="$id"
        sleep 1
        continue
        ;;
      *)
        Q_NOTE="head shot $id status $ST"
        break
        ;;
    esac
    tried=$((tried + 1))

    if [ "$DRY_RUN" = 1 ]; then
      log "  DRY RUN: would settleFallback($id) (status $ST, queue position $head)"
      Q_CLOSED=$((Q_CLOSED + 1))
      cursor=$((head + 1))
      continue
    fi

    if send "$v" "settleFallback(uint256)" "$id" --gas-limit "$SETTLE_GAS" && [ "$TX_OK" = 1 ]; then
      # the head was shot $id and settleFallback($id) succeeded, so it closed exactly that shot
      Q_TXS=$((Q_TXS + 1))
      Q_CLOSED=$((Q_CLOSED + 1))
      floor=$((head + 1))
      report_settled "$v"
      log "  settleFallback($id) tx $TX_HASH gas $TX_GAS: ${REPORT:-shot $id closed (no Settled log read from the receipt)}"
      continue
    fi
    [ -n "$TX_HASH" ] && Q_TXS=$((Q_TXS + 1))
    # Reverted, or no receipt: is shot $id closed anyway? A mined transaction is judged at its own block. One without a
    # receipt may still be on its way (see may_be_out): the head is watched for NOSEND_WAIT seconds before it counts
    # as a failure.
    # shellcheck disable=SC2046 # at_tx_block is empty or two words by design
    newhead="$(rdnum "$v" "queueHead()" $(at_tx_block))" || { log "  read failed: $LAST_ERR"; return 1; }
    if [ -z "$TX_HASH" ] && may_be_out; then
      waited=0
      while [ "$newhead" -le "$head" ] && [ "$waited" -lt "$NOSEND_WAIT" ]; do
        sleep 3
        waited=$((waited + 3))
        newhead="$(rdnum "$v" "queueHead()")" || { log "  read failed: $LAST_ERR"; return 1; }
      done
    fi
    if [ "$newhead" -gt "$head" ]; then
      if [ -n "$TX_HASH" ]; then
        log "  settleFallback($id) $TX_HASH: shot $id was closed by someone else first; going on"
        LOST=$((LOST + 1))
      else
        log "  settleFallback($id) came back without a receipt ($LAST_ERR), but shot $id is closed now (by someone else, or by that transaction); going on"
        UNSEEN=$((UNSEEN + 1))
      fi
      floor="$newhead"
      continue
    fi
    if [ -z "$TX_HASH" ] && [ "$resent" != "$id" ]; then
      log "  settleFallback($id) not sent ($LAST_ERR); trying once more"
      resent="$id"
      tried=$((tried - 1))
      continue
    fi
    Q_NOTE="stopped on a failure"
    if [ -n "$TX_HASH" ]; then
      # why: the same call simulated now (the reason a reverted transaction's receipt does not carry)
      if why="$(cast call "$v" "settleFallback(uint256)" "$id" --from "$KEEPER" --rpc-url "$RPC" 2>&1)"; then
        why="it simulates fine now; the next pass retries"
      else
        why="$(short_err "$why" | sed 's/, data: .*//')"
      fi
      log "  FAILED: settleFallback($id) tx $TX_HASH reverted ($why); shot $id is still the queue head"
    else
      log "  FAILED: settleFallback($id) not sent: $LAST_ERR; shot $id is still the queue head"
    fi
    return 1
  done
  return 0
}

# ------------------------------------------------------------------------------------------------ overdue shots

# arm_overdue <vault> <mark file>: arm every overdue shot from the mark; write the new mark. Sets A_ARMED, A_MARK.
arm_overdue() {
  local v="$1" mf="$2" from next id low waited bad=0
  A_ARMED=0
  from="$(cat "$mf" 2>/dev/null || true)"
  case "$from" in '' | *[!0-9]*) from=1 ;; esac
  [ "$from" -lt 1 ] && from=1
  next="$(rdnum "$v" "nextShotId()")" || { log "  read failed: $LAST_ERR"; return 1; }
  A_MARK="$from"
  low="$next"
  id="$from"
  while [ "$id" -lt "$next" ]; do
    shot_state "$v" "$id" || { log "  read failed at shot $id: $LAST_ERR (mark kept at $from)"; return 1; }
    if [ "$ANCHOR" != 0 ] || [ "$ST" = 5 ] || [ "$ST" = 6 ]; then id=$((id + 1)); continue; fi # queued, or closed
    [ "$low" -eq "$next" ] && low="$id"
    if [ "$ST" = 2 ]; then
      if [ "$DRY_RUN" = 1 ]; then
        log "  DRY RUN: would armFallback($id) (no anchor 6 h after its fire)"
      elif send "$v" "armFallback(uint256)" "$id" && [ "$TX_OK" = 1 ]; then
        A_ARMED=$((A_ARMED + 1))
        log "  armFallback($id) tx $TX_HASH gas $TX_GAS: anchored; a later pass settles it once the anchor is mined"
      else
        # the same judgement as for a settle: at the transaction's block, or watched for a while without a receipt
        # shellcheck disable=SC2046 # at_tx_block is empty or two words by design
        shot_state "$v" "$id" $(at_tx_block) || { log "  read failed at shot $id: $LAST_ERR"; return 1; }
        if [ -z "$TX_HASH" ] && may_be_out; then
          waited=0
          while [ "$ANCHOR" = 0 ] && [ "$ST" != 5 ] && [ "$ST" != 6 ] && [ "$waited" -lt "$NOSEND_WAIT" ]; do
            sleep 3
            waited=$((waited + 3))
            shot_state "$v" "$id" || { log "  read failed at shot $id: $LAST_ERR"; return 1; }
          done
        fi
        if [ "$ANCHOR" != 0 ] || [ "$ST" = 5 ] || [ "$ST" = 6 ]; then
          if [ -n "$TX_HASH" ]; then
            log "  armFallback($id) $TX_HASH: anchored by someone else first; going on"
            LOST=$((LOST + 1))
          else
            log "  armFallback($id) came back without a receipt ($LAST_ERR), but shot $id is anchored now (by someone else, or by that transaction); going on"
            UNSEEN=$((UNSEEN + 1))
          fi
        else
          if [ -n "$TX_HASH" ]; then log "  FAILED: armFallback($id) tx $TX_HASH reverted"; else log "  FAILED: armFallback($id) not sent: $LAST_ERR"; fi
          bad=1
        fi
      fi
    fi
    id=$((id + 1))
  done
  A_MARK="$low"
  if [ "$DRY_RUN" != 1 ]; then
    # every shot below `low` had an anchor or was closed when read, and neither ever goes away, so the mark is right
    # even after a failed arm (that shot is at or above it) and whichever of two concurrent passes writes last
    if ! { printf '%s\n' "$low" >"$mf.tmp.$$" && mv -f "$mf.tmp.$$" "$mf"; }; then
      log "  FAILED: cannot write $mf"
      return 1
    fi
  fi
  [ "$bad" = 0 ]
}

# ------------------------------------------------------------------------------------------------ the pass

KEEPER=""
if [ "$DRY_RUN" = 1 ]; then
  KEEPER_PK=""
  KEEPER="(none: dry run)"
else
  [ -n "${KEEPER_PK:-}" ] || die "KEEPER_PK is not set (the keeper wallet's private key)"
  KEEPER="$(cast wallet address --private-key "$KEEPER_PK" 2>/dev/null)" || die "KEEPER_PK is not a valid private key"
fi

chain="$(cast chain-id --rpc-url "$RPC" 2>&1)" || die "RPC unreachable: $(short_err "$chain")" 1
[ "$chain" = "$CHAIN_ID" ] || die "the RPC serves chain $chain, not $CHAIN_ID" 1
mkdir -p "$STATE_DIR" || die "cannot create STATE_DIR $STATE_DIR" 1

count="$(rdnum "$FACTORY" "vaultCount()")" || die "factory $FACTORY: vaultCount() failed: $LAST_ERR" 1
block="$(cast block-number --rpc-url "$RPC" 2>/dev/null || echo ?)"
mode=""
[ "$DRY_RUN" = 1 ] && mode=" (DRY RUN: nothing is sent)"
log "pass at block $block: factory $FACTORY, $count vault(s), keeper $KEEPER$mode"

TOTAL_CLOSED=0 TOTAL_TXS=0 TOTAL_ARMED=0
i=0
while [ "$i" -lt "$count" ]; do
  if ! raw="$(rd "$FACTORY" "vaults(uint256)" "$i")" || ! w="$(word "$raw" 0)"; then
    log "vault #$i: read failed: ${LAST_ERR:-short return data}"
    FAILURES=$((FAILURES + 1))
    i=$((i + 1))
    continue
  fi
  v="$(addr "$w")"
  log "vault #$i $v"
  Q_CLOSED=0 Q_TXS=0 Q_NOTE="not read"
  if settle_queue "$v"; then :; else FAILURES=$((FAILURES + 1)); fi
  TOTAL_CLOSED=$((TOTAL_CLOSED + Q_CLOSED))
  TOTAL_TXS=$((TOTAL_TXS + Q_TXS))
  A_MARK="?"
  A_ARMED=0
  if arm_overdue "$v" "$STATE_DIR/claw-$CHAIN_ID-$v.from"; then :; else FAILURES=$((FAILURES + 1)); fi
  TOTAL_ARMED=$((TOTAL_ARMED + A_ARMED))
  TOTAL_TXS=$((TOTAL_TXS + A_ARMED))
  log "  vault done: closed $Q_CLOSED from the queue in $Q_TXS tx ($Q_NOTE), armed $A_ARMED, low-water mark $A_MARK"
  i=$((i + 1))
done

rc=0
[ "$FAILURES" -gt 0 ] && rc=1
bal="?"
if [ "$DRY_RUN" != 1 ]; then
  if bal="$(cast balance "$KEEPER" --rpc-url "$RPC" 2>/dev/null)"; then
    if [ "$rc" = 0 ] && awk -v a="$bal" -v b="$LOW_BALANCE" 'BEGIN { exit !(a + 0 < b + 0) }'; then
      log "WARNING: keeper balance $(cast from-wei "$bal") BNB is below LOW_BALANCE $(cast from-wei "$LOW_BALANCE") BNB: top it up"
      rc=3
    fi
    bal="$(cast from-wei "$bal") BNB"
  else
    bal="unreadable"
  fi
fi
if [ "$TOTAL_CLOSED" -eq 0 ] && [ "$TOTAL_ARMED" -eq 0 ] && [ "$TOTAL_TXS" -eq 0 ] && [ "$FAILURES" -eq 0 ] && [ "$LOST" -eq 0 ] && [ "$UNSEEN" -eq 0 ]; then
  log "SUMMARY: nothing to do; vaults $count, keeper balance $bal, exit $rc"
else
  log "SUMMARY: vaults $count, closed $TOTAL_CLOSED from the queues, armed $TOTAL_ARMED, transactions $TOTAL_TXS, races lost to others $LOST, done without a receipt $UNSEEN, failures $FAILURES, keeper balance $bal, exit $rc"
fi
exit "$rc"
