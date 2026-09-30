#!/usr/bin/env python3
"""A local JSON-RPC relay for test/fork-drill.sh only, in two roles.

1. Between anvil and the public endpoint it forks. A fork reads every storage slot it has not seen yet from the public
   endpoint while it executes a transaction, and anvil gives up on the first dropped connection: the transaction then
   sticks in the fork's pool and the drill measures the network instead of the keeper. The relay forwards each
   request on a fresh connection and retries a failed one (a dropped connection, a timeout, HTTP 429 or 5xx) with a
   growing pause, so a passing flake never reaches anvil.

2. Between keeper.sh and the fork, with a fault rule, to play a node that answers one kind of call its own way. A
   request for <method> whose first parameter's call data starts with <hex prefix> (for eth_sendRawTransaction: the
   call data of the signed transaction) is not forwarded. With @<block> only a request for that block is taken
   (@latest: a call that names no block, or "latest"; a call for a block number or a block hash goes through). With
   =<result> it gets that result (eth_estimateGas with =0x7530: an estimate too low for the call, so the transaction
   runs out of gas); with ~<message> it is forwarded all the same, so a transaction really lands on the fork, and then
   gets a JSON-RPC error (code -32000) with that message, as a load-balanced node may take a transaction and still
   answer with an error (~nonce too low); with neither, a JSON-RPC error, the way a node gives it (eth_estimateGas as
   a revert, code 3; anything else code -32000). The error's message quotes the URL the request came to, then that
   URL's path on its own, as some nodes' errors do, so the drill can check that the keeper prints neither.

   With lag=<seconds>[@<block>] it also plays a reader that lags behind the chain: for <seconds> seconds, every
   eth_call at the latest block (one that names no block, "latest" or "pending") is answered as of an older block:
   as of <block> from the start, or, without @<block>, as of the block before the first transaction a ~ rule
   forwarded, from that transaction on. Each answer it makes up or reads as of an older block is logged to stderr.

    python3 test/fork-relay.py <port> <upstream url> [<method>:<hex prefix>[@<block>][=<result>|~<message>]]
                               [lag=<seconds>[@<block>]]

It honours https_proxy like any urllib client, except towards an upstream on this machine (role 2), which it always
reaches directly. It never sends anything but what its client asks it to, and, for a lagging reader, the block
number it reads before forwarding a transaction.
"""
import json
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
UPSTREAM = sys.argv[2]
RULE_ARG, LAG_ARG = "", ""
for arg in sys.argv[3:]:
    if arg.startswith("lag="):
        LAG_ARG = arg[len("lag="):]
    else:
        RULE_ARG = arg
RULE_METHOD, _, RULE = RULE_ARG.partition(":")
RULE, _, RULE_ERROR = RULE.partition("~")  # the message keeps its case
RULE, _, RULE_RESULT = RULE.lower().partition("=")
RULE_PREFIX, _, RULE_BLOCK = RULE.partition("@")
LAG_SECONDS, _, LAG_FROM = LAG_ARG.partition("@")
TRIES = 8

# the lagging reader: the block its eth_call at the latest block is answered as of, and until when (time.monotonic)
LOCK = threading.Lock()
LAG = {"block": None, "until": 0.0}
if LAG_ARG and LAG_FROM:
    LAG["block"] = hex(int(LAG_FROM, 0))
    LAG["until"] = time.monotonic() + float(LAG_SECONDS)

if urllib.parse.urlsplit(UPSTREAM).hostname in ("127.0.0.1", "localhost", "::1"):
    OPEN = urllib.request.build_opener(urllib.request.ProxyHandler({})).open
else:
    OPEN = urllib.request.urlopen


def rlp(b, i=0):
    """The RLP item at b[i] (bytes, or a list of items) and the index past it."""
    p = b[i]
    if p < 0x80:
        return b[i:i + 1], i + 1
    if p < 0xB8:
        return b[i + 1:i + 1 + p - 0x80], i + 1 + p - 0x80
    if p < 0xC0:
        m = p - 0xB7
        n = int.from_bytes(b[i + 1:i + 1 + m], "big")
        return b[i + 1 + m:i + 1 + m + n], i + 1 + m + n
    if p < 0xF8:
        start, n = i + 1, p - 0xC0
    else:
        m = p - 0xF7
        start, n = i + 1 + m, int.from_bytes(b[i + 1:i + 1 + m], "big")
    items, j = [], start
    while j < start + n:
        item, j = rlp(b, j)
        items.append(item)
    return items, start + n


def tx_input(raw):
    """The call data of a signed transaction (legacy, or typed as in EIP-2718), as 0x-hex; "" if it cannot be read."""
    try:
        b = bytes.fromhex(raw[2:] if raw.startswith("0x") else raw)
        if b[0] >= 0xC0:  # legacy: nonce, gasPrice, gas, to, value, data, v, r, s
            return "0x" + rlp(b)[0][5].hex()
        # type 1: chainId, nonce, gasPrice, gas, to, value, data, ...; types 2 to 4: chainId, nonce, tip, maxFee, gas,
        # to, value, data, ...
        return "0x" + rlp(b, 1)[0][6 if b[0] == 1 else 7].hex()
    except (ValueError, IndexError, TypeError, AttributeError):
        return ""


def matched(body):
    """The request, if the fault rule takes it; None otherwise."""
    if not RULE_METHOD:
        return None
    try:
        req = json.loads(body)
    except ValueError:
        return None
    if not isinstance(req, dict) or req.get("method") != RULE_METHOD:
        return None
    params = req.get("params") or []
    first = params[0] if params else None
    if RULE_METHOD == "eth_sendRawTransaction" and isinstance(first, str):
        data = tx_input(first)
    else:
        call = first if isinstance(first, dict) else {}
        data = str(call.get("input") or call.get("data") or "")
    if not data.lower().startswith(RULE_PREFIX):
        return None
    if RULE_BLOCK:
        block = params[1] if len(params) > 1 and params[1] is not None else "latest"
        if not isinstance(block, str) or block.lower() != RULE_BLOCK:
            return None
    return req


def lagging(body):
    """The request rewritten to read as of the lagging reader's block, if it is an eth_call at the latest block while
    the reader lags; None otherwise."""
    with LOCK:
        block, until = LAG["block"], LAG["until"]
    if block is None or time.monotonic() >= until:
        return None
    try:
        req = json.loads(body)
    except ValueError:
        return None
    if not isinstance(req, dict) or req.get("method") != "eth_call":
        return None
    params = list(req.get("params") or [])
    if not params:
        return None
    tag = params[1] if len(params) > 1 else None
    if tag is not None and (not isinstance(tag, str) or tag.lower() not in ("latest", "pending")):
        return None
    if len(params) > 1:
        params[1] = block
    else:
        params.append(block)
    req["params"] = params
    sys.stderr.write("relay: answered eth_call as of block %d, not the latest (the drill's lagging reader)\n"
                     % int(block, 16))
    sys.stderr.flush()
    return json.dumps(req).encode()


def forward(body):
    """The upstream's answer to the request: (HTTP status, body)."""
    pause = 1.0
    status, data, err = 502, b"", ""
    for attempt in range(TRIES):
        try:
            # the endpoint's CDN refuses urllib's default User-Agent (HTTP 403, "error code: 1010")
            headers = {"Content-Type": "application/json", "User-Agent": "claw-keeper-fork-drill"}
            up = urllib.request.Request(UPSTREAM, data=body, headers=headers)
            with OPEN(up, timeout=40) as r:
                status, data = r.status, r.read()
            break
        except urllib.error.HTTPError as e:
            status, data, err = e.code, e.read(), "HTTP %d" % e.code
            if e.code != 429 and e.code < 500:
                break
        except Exception as e:  # a dropped connection or a timeout
            status, data, err = 502, b"", repr(e)
        sys.stderr.write("relay: attempt %d failed (%s); retrying in %.0f s\n" % (attempt + 1, err, pause))
        sys.stderr.flush()
        time.sleep(pause)
        pause = min(pause * 2, 8.0)
    return status, data


def upstream_block():
    """The upstream's latest block number, as 0x-hex; None if it cannot be read."""
    _, data = forward(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_blockNumber", "params": []}).encode())
    try:
        return hex(int(json.loads(data)["result"], 16))
    except (ValueError, KeyError, TypeError):
        return None


class Relay(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def answer(self, status, data):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        req = matched(body)
        if req is not None:
            where = "http://127.0.0.1:%d%s" % (PORT, self.path)
            said = "drill fault at %s; key %s" % (where, self.path.strip("/"))
            if RULE_ERROR:
                # forwarded first: the transaction lands on the fork, and only the answer is the node's own
                before = upstream_block() if LAG_ARG and not LAG_FROM else None
                _, data = forward(body)
                try:
                    got = json.loads(data)
                except ValueError:
                    got = None
                if isinstance(got, dict) and "result" in got:
                    took = "took it as %s" % got["result"]
                elif isinstance(got, dict):
                    took = "refused it: %s" % json.dumps(got.get("error"))
                else:
                    took = "answered %r" % data[:200]
                with LOCK:
                    if before is not None and LAG["block"] is None:
                        LAG["block"], LAG["until"] = before, time.monotonic() + float(LAG_SECONDS)
                        took += "; eth_call now lags at block %d for %s s" % (int(before, 16), LAG_SECONDS)
                error = {"code": -32000, "message": "%s (%s)" % (RULE_ERROR, said)}
                reply = {"jsonrpc": "2.0", "id": req.get("id"), "error": error}
                sys.stderr.write("relay: forwarded %s, and the upstream %s; answered the client: %s (the drill's "
                                 "fault rule)\n" % (RULE_METHOD, took, RULE_ERROR))
            elif RULE_RESULT:
                reply = {"jsonrpc": "2.0", "id": req.get("id"), "result": RULE_RESULT}
                sys.stderr.write("relay: answered %s with %s (the drill's fault rule)\n" % (RULE_METHOD, RULE_RESULT))
            else:
                if RULE_METHOD == "eth_estimateGas":
                    error = {"code": 3, "message": "execution reverted: " + said, "data": "0x"}
                else:
                    error = {"code": -32000, "message": said}
                reply = {"jsonrpc": "2.0", "id": req.get("id"), "error": error}
                sys.stderr.write("relay: refused %s (the drill's fault rule)\n" % RULE_METHOD)
            sys.stderr.flush()
            self.answer(200, json.dumps(reply).encode())
            return
        status, data = forward(lagging(body) or body)
        self.answer(status, data)

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", PORT), Relay).serve_forever()
