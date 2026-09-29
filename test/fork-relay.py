#!/usr/bin/env python3
"""A local JSON-RPC relay between anvil and the public endpoint it forks, for test/fork-drill.sh only.

A fork reads every storage slot it has not seen yet from the public endpoint while it executes a transaction, and
anvil gives up on the first dropped connection: the transaction then sticks in the fork's pool and the drill measures
the network instead of the keeper. The relay forwards each request on a fresh connection and retries a failed one
(a dropped connection, a timeout, HTTP 429 or 5xx) with a growing pause, so a passing flake never reaches anvil.

    python3 test/fork-relay.py <port> <upstream url>

It honours https_proxy like any urllib client. It never sends anything but what anvil asks it to read.
"""
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
UPSTREAM = sys.argv[2]
TRIES = 8


class Relay(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        pause = 1.0
        status, data, err = 502, b"", ""
        for attempt in range(TRIES):
            try:
                # the endpoint's CDN refuses urllib's default User-Agent (HTTP 403, "error code: 1010")
                headers = {"Content-Type": "application/json", "User-Agent": "claw-keeper-fork-drill"}
                req = urllib.request.Request(UPSTREAM, data=body, headers=headers)
                with urllib.request.urlopen(req, timeout=40) as r:
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
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", PORT), Relay).serve_forever()
