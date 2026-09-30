#!/usr/bin/env python3
"""A local JSON-RPC relay for test/fork-drill.sh only, in two roles.

1. Between anvil and the public endpoint it forks. A fork reads every storage slot it has not seen yet from the public
   endpoint while it executes a transaction, and anvil gives up on the first dropped connection: the transaction then
   sticks in the fork's pool and the drill measures the network instead of the keeper. The relay forwards each
   request on a fresh connection and retries a failed one (a dropped connection, a timeout, HTTP 429 or 5xx) with a
   growing pause, so a passing flake never reaches anvil.

2. Between keeper.sh and the fork, with a fault rule, to play a node that answers one kind of call its own way. A
   request for <method> whose first parameter's call data starts with <hex prefix> is not forwarded. With @<block>
   only a request for that block is taken (@latest: a call that names no block, or "latest"; a call for a block
   number or a block hash goes through). With =<result> it gets that result (eth_estimateGas with =0x7530: an estimate
   too low for the call, so the transaction runs out of gas); without, a JSON-RPC error, the way a node gives it
   (eth_estimateGas as a revert, code 3; anything else code -32000). The error's message quotes the URL the request
   came to, then that URL's path on its own, as some nodes' errors do, so the drill can check that the keeper prints
   neither. Each answer it makes up is logged to stderr.

    python3 test/fork-relay.py <port> <upstream url> [<method>:<hex prefix>[@<block>][=<result>]]

It honours https_proxy like any urllib client, except towards an upstream on this machine (role 2), which it always
reaches directly. It never sends anything but what its client asks it to.
"""
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
UPSTREAM = sys.argv[2]
RULE_METHOD, _, RULE = (sys.argv[3] if len(sys.argv) > 3 else "").partition(":")
RULE, _, RULE_RESULT = RULE.lower().partition("=")
RULE_PREFIX, _, RULE_BLOCK = RULE.partition("@")
TRIES = 8

if urllib.parse.urlsplit(UPSTREAM).hostname in ("127.0.0.1", "localhost", "::1"):
    OPEN = urllib.request.build_opener(urllib.request.ProxyHandler({})).open
else:
    OPEN = urllib.request.urlopen


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
    call = params[0] if params and isinstance(params[0], dict) else {}
    data = str(call.get("input") or call.get("data") or "").lower()
    if not data.startswith(RULE_PREFIX):
        return None
    if RULE_BLOCK:
        block = params[1] if len(params) > 1 and params[1] is not None else "latest"
        if not isinstance(block, str) or block.lower() != RULE_BLOCK:
            return None
    return req


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
            if RULE_RESULT:
                reply = {"jsonrpc": "2.0", "id": req.get("id"), "result": RULE_RESULT}
                sys.stderr.write("relay: answered %s with %s (the drill's fault rule)\n" % (RULE_METHOD, RULE_RESULT))
            else:
                where = "http://127.0.0.1:%d%s" % (PORT, self.path)
                said = "drill fault at %s; key %s" % (where, self.path.strip("/"))
                if RULE_METHOD == "eth_estimateGas":
                    error = {"code": 3, "message": "execution reverted: " + said, "data": "0x"}
                else:
                    error = {"code": -32000, "message": said}
                reply = {"jsonrpc": "2.0", "id": req.get("id"), "error": error}
                sys.stderr.write("relay: refused %s (the drill's fault rule)\n" % RULE_METHOD)
            sys.stderr.flush()
            self.answer(200, json.dumps(reply).encode())
            return
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
        self.answer(status, data)

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", PORT), Relay).serve_forever()
