#!/usr/bin/env bash
# Claw keeper: one pass over every vault of the claw factory on one chain.
#
# For each vault the factory has made, the same steps as the vault repository's reviewed sweep (Play STEP=sweep), in
# two rounds, so that no vault's overdue scan ever holds back another vault's settles:
#   1. Every vault's settle queue, from its head. While the head shot's anchor block is mined (READY, status 4) or
#      its anchor's hash has left the history window (spent, status 6), settleFallback(head): one transaction per
#      shot, strictly in queue order, each with an explicit gas limit (SETTLE_GAS, 3,000,000), never the node's bare
#      estimate — the vault refuses to pay a win without the gas to deliver it. A ready shot is settled and paid to
#      its shooter; when that transfer fails (the quote token, or the shooter's side, refuses it), the vault keeps
#      the win as owed to the shooter, who collects it with withdrawOwed. A spent one is closed and pays nothing. At
#      most SWEEP_MAX shots a vault a pass; the next pass goes on.
#   2. Every vault's overdue shots. From the vault's low-water mark (kept in STATE_DIR) towards nextShotId, reading
#      at most ARM_MAX shots a vault a pass, every shot that still has no anchor STALE (6 h) after its fire (status 2)
#      gets armFallback. The new mark is the first id that had no anchor in this pass, or the id where the scan
#      stopped (ARM_MAX reached, or a read that kept failing) if that is lower: every shot below it is anchored or
#      closed, for good. A lost state file only makes the next passes rescan from shot 1, ARM_MAX shots a pass.
#
# It spends gas only: winnings always go to each shot's shooter. It is idempotent and safe next to the Trigger
# Service, players and other keepers: a transaction that loses a race is checked against the chain, and a shot that
# someone else closed or armed first counts as done, not as a failure. A transaction that comes back without a receipt
# (cast gave up waiting, or the node answered with an error after taking it) is judged the same way after watching the
# chain for 30 s; only a shot still open then is a failure. One that never left (cast's gas estimate failed or
# reverted, or the node refused it outright: no funds, a used nonce) is judged at once, without the wait. A failure
# says why, for settles and arms alike: the revert reason in the receipt (cast replays the transaction as of its own
# block), else whether it used all of its gas limit, else the same call simulated as of that block, never a later one.
#
# Environment:
#   CHAIN_ID     56 or 97 (required)
#   KEEPER_PK    the keeper wallet's private key (required unless DRY_RUN=1); it pays gas and nothing else
#   RPC          RPC URL (default: a public endpoint for the chain). Never printed: a URL can carry an API key, so
#                the keeper's messages, and the node errors they quote, show it (its host, and every long token of
#                its path, query or user part) as <rpc>, and any other URL as <url>.
#   FACTORY      claw factory (default: the one deployed on the chain)
#   STATE_DIR    where the low-water marks are kept (default: ./state)
#   SETTLE_GAS   gas limit of every settleFallback (default 3000000)
#   SWEEP_MAX    most queue shots handled per vault per pass (default 500)
#   ARM_MAX      most shots read per vault per pass in the overdue scan (default 500)
#   LOW_BALANCE  wei; when the keeper's balance is below it, the pass prints a top-up warning, and exits 3 if it had
#                no failure, so the run shows as failed (default 0.005 BNB on 56, 0.001 test BNB on 97; 0 turns the
#                check off)
#   DRY_RUN      1: read only, print what would be sent, send nothing, keep the marks; 0 or empty: a normal pass;
#                anything else is a configuration error
#   ETH_GAS_PRICE  read by cast (legacy gas price, e.g. 0.1gwei); default: the node's eth_gasPrice
#
# Exit codes:
#   0  the pass completed without a failure (including nothing to do, races lost to others, and a keeper balance
#      that could not be read)
#   1  a failure: the RPC unreachable or serving another chain, STATE_DIR or a temporary file that cannot be created,
#      an RPC read that kept failing, a transaction that did not go through while its shot stayed open, or a mark
#      that could not be written. Past a failure in one vault the pass goes on with the other vaults and the other
#      round, then exits 1; the low-balance warning is printed all the same.
#   2  configuration error (CHAIN_ID, KEEPER_PK, DRY_RUN, FACTORY, SETTLE_GAS, SWEEP_MAX, ARM_MAX, LOW_BALANCE, cast
#      missing); nothing was sent
#   3  no failure, but the keeper balance is below LOW_BALANCE
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
ARM_MAX="${ARM_MAX:-500}"
LOW_BALANCE="${LOW_BALANCE:-$DEFAULT_LOW}"
DRY_RUN="${DRY_RUN:-0}"

case "$DRY_RUN" in
  0 | 1) ;;
  *) die "DRY_RUN must be 1 (read only), 0 or empty" ;;
esac
whole() { case "$2" in '' | *[!0-9]*) die "$1 must be a whole number" ;; esac; }
whole SETTLE_GAS "$SETTLE_GAS"
whole SWEEP_MAX "$SWEEP_MAX"
whole ARM_MAX "$ARM_MAX"
whole LOW_BALANCE "$LOW_BALANCE"
[ "$SETTLE_GAS" -ge 1000000 ] || die "SETTLE_GAS must be at least 1000000 (the reviewed policy uses 3000000)"
[ "$ARM_MAX" -ge 1 ] || die "ARM_MAX must be at least 1"
case "$FACTORY" in 0x*) ;; *) die "FACTORY is not an address" ;; esac
case "${FACTORY#0x}" in *[!0-9a-fA-F]*) die "FACTORY is not an address" ;; esac
[ "${#FACTORY}" -eq 42 ] || die "FACTORY is not an address"
command -v cast >/dev/null 2>&1 || die "cast (Foundry) is not installed"

# The RPC URL is never printed (see RPC above): the pass names it by RPC_SAYS, and every error it quotes goes through
# scrub first.
if [ "$RPC" = "$DEFAULT_RPC" ]; then RPC_SAYS="the default public RPC"; else RPC_SAYS="the RPC set in RPC (not shown)"; fi
# scrub: stdin to stdout with the RPC URL shown as <rpc>: first the URL itself, then any URL at all as <url> (a node
# may quote the RPC URL rewritten: a slash added, the host in lower case), then its host (with and without the port)
# and every token of 8 or more letters, digits, - or _ in its path, query or user part (an API key quoted alone).
scrub() {
  SCRUB_RPC="$RPC" awk '
    function cut(s, t,   i, out) {
      if (t == "") return s
      out = ""
      while ((i = index(s, t)) > 0) { out = out substr(s, 1, i - 1) "<rpc>"; s = substr(s, i + length(t)) }
      return out s
    }
    BEGIN {
      url = ENVIRON["SCRUB_RPC"]
      rest = url
      sub(/^[A-Za-z][A-Za-z0-9+.-]*:\/\//, "", rest)
      auth = rest
      sub(/[\/?#].*$/, "", auth)
      tail = substr(rest, length(auth) + 1)
      host = auth
      sub(/^.*@/, "", host)
      user = substr(auth, 1, length(auth) - length(host))
      name = host
      sub(/:[0-9]*$/, "", name)
      # a host name too short to be told from an ordinary word ("node") is left alone: it carries no key
      if (length(host) < 6) host = ""
      if (length(name) < 6) name = ""
      n = split(tail " " user, part, /[^A-Za-z0-9_-]+/)
      k = 0
      for (j = 1; j <= n; j++) if (length(part[j]) >= 8) token[++k] = part[j]
    }
    {
      s = cut($0, url)
      gsub(/[A-Za-z][A-Za-z0-9+.-]*:\/\/[^ \t<>()"]+/, "<url>", s)
      s = cut(cut(s, host), name)
      for (j = 1; j <= k; j++) s = cut(s, token[j])
      print s
    }'
}

# Event topics (from the vault's ABI).
T_SETTLED=0x5ff90b03a22f6659909036f685d15b0ffeb0302d111f4b79c5655b27787a39d4 # Settled(uint256,address,uint256,uint8,bytes32,uint256,uint256[])
T_OWED=0x7393c924ac30f9256e6cebcfb78841b1e7ef11bf8b09d87c2257b32b8063c979    # Owed(address,uint256)

FAILURES=0
LOST=0    # races lost: another settler or arm came first (our transaction reverted, or never left)
UNSEEN=0  # transactions with no receipt whose shot was closed or anchored anyway (by others, or by that transaction)
LAST_ERR=""
SEND_ERR=""
NOSEND_WAIT=30 # seconds to watch the chain after a transaction that came back without a receipt

# cast's standard error goes to this file, apart from its answer, so a warning never spoils a value it read.
ERRF="$(mktemp "${TMPDIR:-/tmp}/claw-keeper.XXXXXX")" || die "cannot create a temporary file" 1
trap 'rm -f "$ERRF"' EXIT
# err_of <answer>: the error of the cast command that just failed: its standard error, else its answer.
err_of() {
  local e
  e="$(cat "$ERRF" 2>/dev/null)"
  if [ -n "$e" ]; then printf '%s' "$e"; else printf '%s' "$1"; fi
}

# The last line of an error, scrubbed, one line, at most 240 characters.
short_err() { printf '%s\n' "$1" | tr '\r' '\n' | scrub | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-240; }

# rd <to> <sig> [args and cast options...]: eth_call (latest block unless --block is given); sets RD to the raw
# return data. Three tries, 2 s apart. On failure sets LAST_ERR and returns 1. (No subshell: callers see LAST_ERR.)
rd() {
  local out err n=0
  RD=""
  while :; do
    if out="$(cast call "$@" --rpc-url "$RPC" 2>"$ERRF")"; then
      case "$out" in 0x*) RD="$out"; return 0 ;; esac
      err="not ABI data: $out"
    else
      err="$(err_of "$out")"
    fi
    n=$((n + 1))
    if [ "$n" -ge 3 ]; then LAST_ERR="$(short_err "$err")"; return 1; fi
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

# rdnum <to> <sig> [args and cast options...]: a call returning one small number; sets NUM.
rdnum() {
  local w
  NUM=""
  rd "$@" || return 1
  w="$(word "$RD" 0)" || { LAST_ERR="short return data from $2"; return 1; }
  NUM="$(small "$w")"
}

# shot_state <vault> <id> [cast options...]: sets ST (live status) and ANCHOR (anchor block, 0 if none) from
# shotState(id): 1 pending, 2 overdue, 3 anchored (block not mined), 4 ready, 5 settled, 6 spent.
shot_state() {
  local v="$1" id="$2" w0 w5
  shift 2
  rd "$v" "shotState(uint256)" "$id" "$@" || return 1
  if ! w0="$(word "$RD" 0)" || ! w5="$(word "$RD" 5)"; then
    LAST_ERR="short return data from shotState($id)"
    return 1
  fi
  ST="$(small "$w0")"
  ANCHOR="$(small "$w5")"
}

# send <to> <sig> [args and cast options...]: sign and send from the keeper, wait for the receipt.
# Sets TX_HASH, TX_OK (1 mined and succeeded, 0 otherwise), TX_GAS, TX_BLOCK and TX_JSON. Returns 1 when nothing
# came back mined (not sent, or no receipt), with SEND_ERR (cast's whole error, scrubbed) and LAST_ERR (its last
# line): the caller re-reads the chain to learn what happened.
send() {
  local out
  TX_HASH="" TX_OK=0 TX_GAS="" TX_BLOCK="" TX_JSON="" SEND_ERR=""
  if ! out="$(cast send "$@" --legacy --private-key "$KEEPER_PK" --rpc-url "$RPC" --json 2>"$ERRF")"; then
    out="$(err_of "$out")"
    SEND_ERR="$(printf '%s\n' "$out" | tr '\r' '\n' | scrub)"
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
  if [ -z "$TX_HASH" ]; then
    SEND_ERR="no receipt in cast's answer: $(printf '%s\n' "$out" | tr '\r' '\n' | scrub)"
    LAST_ERR="no receipt in cast's answer: $(short_err "$out")"
    return 1
  fi
  return 0
}

# may_be_out: whether a transaction that came back without a receipt may still have gone out (cast gave up waiting
# for it, or the node took it and answered with an error): anything but an error that proves it never left. cast
# estimates the gas of a send that has no gas limit by running the call first, and stops before signing when that
# fails or reverts; a node refuses outright a transaction it cannot pay for or whose nonce is used.
may_be_out() {
  case "$SEND_ERR" in
    *"Failed to estimate gas"* | *"failed to estimate gas"* | *"execution reverted"*) return 1 ;;
    *"insufficient funds"* | *"nonce too low"* | *"intrinsic gas too low"*) return 1 ;;
    *"invalid private key"* | *"Invalid private key"*) return 1 ;;
  esac
  return 0
}

# at_tx_block: the cast option that reads the chain as of the last transaction's block (empty when it has none),
# so a re-check after a failed transaction never asks a node that has not seen that block yet.
at_tx_block() { [ -z "$TX_BLOCK" ] || printf '%s %s' --block "$TX_BLOCK"; }

# revert_reason <to> <sig> <id>: sets WHY, why the last transaction (mined, reverted) failed: the revertReason in the
# receipt cast printed (a node's receipt carries none; cast replays the transaction as of its block); else "out of
# gas" when it used all of its gas limit; else the same call simulated as of that block, never at a later one.
revert_reason() {
  local r lim
  r="$(printf '%s' "$TX_JSON" | sed -n -E 's/.*"revertReason":"(([^"\\]|\\.)*)".*/\1/p' | head -1)"
  r="${r%%, data: *}"
  if [ -n "$r" ]; then
    WHY="$(printf '%s\n' "$r" | sed 's/\\"/"/g' | scrub | cut -c1-240)"
    return 0
  fi
  lim="$(cast tx "$TX_HASH" gas --rpc-url "$RPC" 2>/dev/null)" || lim=""
  if [ -n "$TX_GAS" ] && [ "$TX_GAS" = "$lim" ]; then
    WHY="out of gas: it used all $lim of its gas limit"
    return 0
  fi
  # shellcheck disable=SC2046 # at_tx_block is empty or two words by design
  if r="$(cast call "$1" "$2" "$3" --from "$KEEPER" $(at_tx_block) --rpc-url "$RPC" 2>&1)"; then
    WHY="no reason in the receipt, and the same call succeeds as of that block"
  else
    WHY="no reason in the receipt; the same call as of that block: $(short_err "$r" | sed 's/, data: .*//')"
  fi
}

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
  local v="$1" head tail id newhead waited out tried=0 cursor="" resent="" stale="" floor=0 behind=0
  Q_CLOSED=0 Q_TXS=0 Q_NOTE=""
  while :; do
    if [ "$tried" -ge "$SWEEP_MAX" ]; then
      Q_NOTE="SWEEP_MAX ($SWEEP_MAX) reached; the next pass goes on"
      break
    fi
    if [ -n "$cursor" ]; then
      head="$cursor" # DRY_RUN: walk the queue without moving it
    elif rdnum "$v" "queueHead()"; then
      head="$NUM"
    else
      log "  read failed: $LAST_ERR"
      Q_NOTE="stopped on a read failure"
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
    rdnum "$v" "queueTail()" || { log "  read failed: $LAST_ERR"; Q_NOTE="stopped on a read failure"; return 1; }
    tail="$NUM"
    if [ "$head" -ge "$tail" ]; then
      Q_NOTE="queue empty"
      break
    fi
    rdnum "$v" "queuedShot(uint256)" "$head" || { log "  read failed: $LAST_ERR"; Q_NOTE="stopped on a read failure"; return 1; }
    id="$NUM"
    shot_state "$v" "$id" || { log "  read failed: $LAST_ERR"; Q_NOTE="stopped on a read failure"; return 1; }
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
    # Reverted, never left, or no receipt: is shot $id closed anyway? A mined transaction is judged at its own block,
    # one that never left at once. One without a receipt may still be on its way (see may_be_out): the head is
    # watched for NOSEND_WAIT seconds before it counts as a failure.
    out=0
    [ -z "$TX_HASH" ] && may_be_out && out=1
    # shellcheck disable=SC2046 # at_tx_block is empty or two words by design
    rdnum "$v" "queueHead()" $(at_tx_block) || { log "  read failed: $LAST_ERR"; Q_NOTE="stopped on a read failure"; return 1; }
    newhead="$NUM"
    if [ "$out" = 1 ] && [ "$newhead" -le "$head" ]; then
      log "  settleFallback($id): no receipt ($LAST_ERR); watching the chain for up to $NOSEND_WAIT s"
      waited=0
      while [ "$newhead" -le "$head" ] && [ "$waited" -lt "$NOSEND_WAIT" ]; do
        sleep 3
        waited=$((waited + 3))
        rdnum "$v" "queueHead()" || { log "  read failed: $LAST_ERR"; Q_NOTE="stopped on a read failure"; return 1; }
        newhead="$NUM"
      done
    fi
    if [ "$newhead" -gt "$head" ]; then
      if [ -n "$TX_HASH" ]; then
        log "  settleFallback($id) $TX_HASH: shot $id was closed by someone else first; going on"
        LOST=$((LOST + 1))
      elif [ "$out" = 1 ]; then
        log "  settleFallback($id) came back without a receipt ($LAST_ERR), but shot $id is closed now (by someone else, or by that transaction); going on"
        UNSEEN=$((UNSEEN + 1))
      else
        log "  settleFallback($id) not sent ($LAST_ERR), and shot $id is closed now, by someone else; going on"
        LOST=$((LOST + 1))
      fi
      floor="$newhead"
      continue
    fi
    if [ -z "$TX_HASH" ] && [ "$resent" != "$id" ]; then
      if [ "$out" = 1 ]; then
        log "  settleFallback($id): still no receipt, and shot $id is still the queue head; sending once more"
      else
        log "  settleFallback($id) not sent ($LAST_ERR); trying once more"
      fi
      resent="$id"
      tried=$((tried - 1))
      continue
    fi
    Q_NOTE="stopped on a failure"
    if [ -n "$TX_HASH" ]; then
      revert_reason "$v" "settleFallback(uint256)" "$id"
      log "  FAILED: settleFallback($id) tx $TX_HASH reverted ($WHY); shot $id is still the queue head"
    else
      log "  FAILED: settleFallback($id) not sent: $LAST_ERR; shot $id is still the queue head"
    fi
    return 1
  done
  return 0
}

# ------------------------------------------------------------------------------------------------ overdue shots

# arm_overdue <vault> <mark file>: arm every overdue shot from the mark, reading at most ARM_MAX shots; write the new
# mark, also when the scan stopped early. Sets A_ARMED, A_TXS (transactions mined, a failed one included), A_MARK
# and A_NOTE; returns 1 on a failure.
arm_overdue() {
  local v="$1" mf="$2" from next id low waited out nread=0 bad=0 rfail=0
  A_ARMED=0 A_TXS=0 A_NOTE=""
  from="$(cat "$mf" 2>/dev/null || true)"
  case "$from" in '' | *[!0-9]*) from=1 ;; esac
  [ "$from" -lt 1 ] && from=1
  A_MARK="$from"
  rdnum "$v" "nextShotId()" || { log "  read failed: $LAST_ERR (mark kept at $from)"; return 1; }
  next="$NUM"
  low="$next"
  id="$from"
  while [ "$id" -lt "$next" ]; do
    if [ "$nread" -ge "$ARM_MAX" ]; then
      A_NOTE="ARM_MAX ($ARM_MAX) reached at shot $id; the next pass goes on from there"
      break
    fi
    nread=$((nread + 1))
    if ! shot_state "$v" "$id"; then
      log "  read failed at shot $id: $LAST_ERR"
      rfail=1
      break
    fi
    if [ "$ANCHOR" != 0 ] || [ "$ST" = 5 ] || [ "$ST" = 6 ]; then id=$((id + 1)); continue; fi # queued, or closed
    [ "$low" -eq "$next" ] && low="$id"
    if [ "$ST" = 2 ]; then
      if [ "$DRY_RUN" = 1 ]; then
        log "  DRY RUN: would armFallback($id) (no anchor 6 h after its fire)"
      elif send "$v" "armFallback(uint256)" "$id" && [ "$TX_OK" = 1 ]; then
        A_ARMED=$((A_ARMED + 1))
        A_TXS=$((A_TXS + 1))
        log "  armFallback($id) tx $TX_HASH gas $TX_GAS: anchored; a later pass settles it once the anchor is mined"
      else
        # the same judgement as for a settle: at the transaction's block, at once when it never left, or watched for
        # a while without a receipt
        [ -n "$TX_HASH" ] && A_TXS=$((A_TXS + 1))
        out=0
        [ -z "$TX_HASH" ] && may_be_out && out=1
        # shellcheck disable=SC2046 # at_tx_block is empty or two words by design
        if ! shot_state "$v" "$id" $(at_tx_block); then
          log "  read failed at shot $id: $LAST_ERR"
          rfail=1
          break
        fi
        if [ "$out" = 1 ] && [ "$ANCHOR" = 0 ] && [ "$ST" != 5 ] && [ "$ST" != 6 ]; then
          log "  armFallback($id): no receipt ($LAST_ERR); watching the chain for up to $NOSEND_WAIT s"
          waited=0
          while [ "$ANCHOR" = 0 ] && [ "$ST" != 5 ] && [ "$ST" != 6 ] && [ "$waited" -lt "$NOSEND_WAIT" ]; do
            sleep 3
            waited=$((waited + 3))
            if ! shot_state "$v" "$id"; then
              log "  read failed at shot $id: $LAST_ERR"
              rfail=1
              break 2
            fi
          done
        fi
        if [ "$ANCHOR" != 0 ] || [ "$ST" = 5 ] || [ "$ST" = 6 ]; then
          if [ -n "$TX_HASH" ]; then
            log "  armFallback($id) $TX_HASH: anchored by someone else first; going on"
            LOST=$((LOST + 1))
          elif [ "$out" = 1 ]; then
            log "  armFallback($id) came back without a receipt ($LAST_ERR), but shot $id is anchored now (by someone else, or by that transaction); going on"
            UNSEEN=$((UNSEEN + 1))
          else
            log "  armFallback($id) not sent ($LAST_ERR), and shot $id is anchored now, by someone else; going on"
            LOST=$((LOST + 1))
          fi
        else
          if [ -n "$TX_HASH" ]; then
            revert_reason "$v" "armFallback(uint256)" "$id"
            log "  FAILED: armFallback($id) tx $TX_HASH reverted ($WHY)"
          else
            log "  FAILED: armFallback($id) not sent: $LAST_ERR"
          fi
          bad=1
        fi
      fi
    fi
    id=$((id + 1))
  done
  # Every shot below `id` was read in this pass, and every one below `low` had an anchor or was closed; neither ever
  # goes away. So the lower of the two is a right mark however the scan stopped (the end, ARM_MAX, a read that kept
  # failing), even after a failed arm (that shot is at or above `low`), and whichever of two concurrent passes
  # writes last.
  [ "$id" -lt "$low" ] && low="$id"
  A_MARK="$low"
  [ "$rfail" = 1 ] && A_NOTE="stopped on a read failure; the mark keeps what was read"
  if [ "$DRY_RUN" != 1 ]; then
    if ! { printf '%s\n' "$low" >"$mf.tmp.$$" && mv -f "$mf.tmp.$$" "$mf"; }; then
      log "  FAILED: cannot write $mf"
      return 1
    fi
  fi
  [ "$rfail" = 0 ] && [ "$bad" = 0 ]
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

chain="$(cast chain-id --rpc-url "$RPC" 2>"$ERRF")" || die "RPC unreachable ($RPC_SAYS): $(short_err "$(err_of "$chain")")" 1
[ "$chain" = "$CHAIN_ID" ] || die "the RPC ($RPC_SAYS) serves chain $(short_err "$chain" | cut -c1-40), not $CHAIN_ID" 1
mkdir -p "$STATE_DIR" || die "cannot create STATE_DIR $STATE_DIR" 1

rdnum "$FACTORY" "vaultCount()" || die "factory $FACTORY: vaultCount() failed: $LAST_ERR" 1
count="$NUM"
block="$(cast block-number --rpc-url "$RPC" 2>/dev/null || echo ?)"
mode=""
[ "$DRY_RUN" = 1 ] && mode=" (DRY RUN: nothing is sent)"
log "pass at block $block: factory $FACTORY, $count vault(s), keeper $KEEPER, via $RPC_SAYS$mode"

VAULTS="" # "index:address" of every vault read, in the factory's order
i=0
while [ "$i" -lt "$count" ]; do
  if ! rd "$FACTORY" "vaults(uint256)" "$i"; then
    log "vault #$i: read failed: $LAST_ERR"
    FAILURES=$((FAILURES + 1))
  elif ! w="$(word "$RD" 0)"; then
    log "vault #$i: read failed: short return data"
    FAILURES=$((FAILURES + 1))
  else
    VAULTS="$VAULTS $i:$(addr "$w")"
  fi
  i=$((i + 1))
done

TOTAL_CLOSED=0 TOTAL_TXS=0 TOTAL_ARMED=0
# Round 1: every vault's settle queue first. Settles are the ones with a deadline (the anchor hash's window).
for e in $VAULTS; do
  i="${e%%:*}"
  v="${e#*:}"
  log "vault #$i $v: settle queue"
  Q_CLOSED=0 Q_TXS=0 Q_NOTE="not read"
  settle_queue "$v" || FAILURES=$((FAILURES + 1))
  TOTAL_CLOSED=$((TOTAL_CLOSED + Q_CLOSED))
  TOTAL_TXS=$((TOTAL_TXS + Q_TXS))
  log "  queue done: closed $Q_CLOSED in $Q_TXS tx ($Q_NOTE)"
done
# Round 2: every vault's overdue shots.
for e in $VAULTS; do
  i="${e%%:*}"
  v="${e#*:}"
  log "vault #$i $v: overdue shots"
  A_MARK="?" A_ARMED=0 A_TXS=0 A_NOTE=""
  arm_overdue "$v" "$STATE_DIR/claw-$CHAIN_ID-$v.from" || FAILURES=$((FAILURES + 1))
  TOTAL_ARMED=$((TOTAL_ARMED + A_ARMED))
  TOTAL_TXS=$((TOTAL_TXS + A_TXS))
  log "  overdue done: armed $A_ARMED in $A_TXS tx, low-water mark $A_MARK${A_NOTE:+ ($A_NOTE)}"
done

rc=0
[ "$FAILURES" -gt 0 ] && rc=1
bal="?"
if [ "$DRY_RUN" != 1 ]; then
  wei="$(cast balance "$KEEPER" --rpc-url "$RPC" 2>/dev/null)" || wei=""
  case "$wei" in
    '' | *[!0-9]*) bal="unreadable" ;;
    *)
      # printed whatever the exit code; it sets the exit code only for a pass without a failure
      if awk -v a="$wei" -v b="$LOW_BALANCE" 'BEGIN { exit !(a + 0 < b + 0) }'; then
        log "WARNING: keeper balance $(cast from-wei "$wei") BNB is below LOW_BALANCE $(cast from-wei "$LOW_BALANCE") BNB: top it up"
        [ "$rc" = 0 ] && rc=3
      fi
      bal="$(cast from-wei "$wei") BNB"
      ;;
  esac
fi
if [ "$TOTAL_CLOSED" -eq 0 ] && [ "$TOTAL_ARMED" -eq 0 ] && [ "$TOTAL_TXS" -eq 0 ] && [ "$FAILURES" -eq 0 ] && [ "$LOST" -eq 0 ] && [ "$UNSEEN" -eq 0 ]; then
  log "SUMMARY: nothing to do; vaults $count, keeper balance $bal, exit $rc"
else
  log "SUMMARY: vaults $count, closed $TOTAL_CLOSED from the queues, armed $TOTAL_ARMED, transactions $TOTAL_TXS, races lost to others $LOST, done without a receipt $UNSEEN, failures $FAILURES, keeper balance $bal, exit $rc"
fi
exit "$rc"
