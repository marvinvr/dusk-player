#!/usr/bin/env python3
"""Logging, read-mostly proxy in front of plex.tv and plex-demo for G6
(docs/jellyfin/05-plan.md §3).

The Debug app runs in screenshot mode with `-DuskScreenshotPlexTV
http://127.0.0.1:<port>`, so it signs in with the fake screenshot token. This
proxy:

  * signs in to plex.tv as the comparison user (or takes the token gate.py
    got, from DUSK_PARITY_PLEX_TOKEN), login from
    ~/.config/jellyfin-demo/compare-plex-login, password from
    ~/.config/jellyfin-demo/compare-password; the token stays in memory and is
    never logged) and swaps it in for the fake token on every plex.tv request;
  * rewrites `/api/v2/resources` so the one server named --server is reached
    through this proxy (port + 1), which forwards to --upstream;
  * lets through GET/HEAD and only the writes a smoke run needs (timeline,
    scrobble/unscrobble, play queues, transcode decisions); every other write
    is answered 403 and logged as blocked, so the shared server is not changed;
  * answers the remux ladder's part stream selection (`PUT /library/parts/<id>`)
    itself with 200, logged as local and never forwarded: the ladder goes on to
    its decision request, and plex-demo's stored selection stays as it is;
  * appends every request to --log as JSON lines (same format as
    parity_mock.py), tokens removed.
"""
import argparse
import http.client
import json
import os
import re
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FAKE_TOKEN = "dusk-screenshot-demo-token"
ALLOWED_WRITES = re.compile(
    r"^/(:/(timeline|scrobble|unscrobble|progress)|playQueues|video/:/transcode/|music/:/transcode/"
    r"|api/v2/pins)")
# Answered here with 200 and never forwarded (see the module docstring).
LOCAL_WRITES = re.compile(r"^/library/parts/\d+$")
HOP_HEADERS = {"connection", "keep-alive", "proxy-connection", "transfer-encoding", "te", "trailer", "upgrade",
               "host", "content-length"}
TOKEN_QUERY = re.compile(r"(X-Plex-Token=)[^&]*", re.IGNORECASE)
LOG_LOCK = threading.Lock()


class State:
    account_token = None
    server_tokens = set()
    log = None
    args = None


def sign_in(args):
    login = open(os.path.expanduser(args.login_file)).read().strip()
    password = open(os.path.expanduser(args.password_file)).read().strip()
    request = urllib.request.Request(
        "https://plex.tv/api/v2/users/signin",
        data=urllib.parse.urlencode({"login": login, "password": password}).encode(),
        headers={"Accept": "application/json", "X-Plex-Client-Identifier": "dusk-parity-smoke-proxy",
                 "X-Plex-Product": "Dusk Parity"})
    return json.load(urllib.request.urlopen(request, timeout=30))["authToken"]


def scrub(text):
    text = TOKEN_QUERY.sub(r"\1<token>", text)
    for token in [State.account_token, *State.server_tokens]:
        if token:
            text = text.replace(token, "<token>")
    return text


class Proxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    role = None

    def log_message(self, fmt, *args):
        pass

    def record(self, status, blocked=False, local=False):
        entry = {"time": round(time.time(), 3), "role": self.role, "method": self.command,
                 "target": scrub(self.path), "status": status}
        if blocked:
            entry["blocked"] = True
        if local:
            entry["local"] = True
        with LOG_LOCK:
            State.log.write(json.dumps(entry) + "\n")
            State.log.flush()

    def do_GET(self):
        self.forward()

    do_HEAD = do_POST = do_PUT = do_DELETE = do_PATCH = do_GET

    def forward(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        path = urllib.parse.urlparse(self.path).path
        if self.command == "PUT" and self.role != "plextv" and LOCAL_WRITES.match(path):
            self.record(200, local=True)
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.command not in ("GET", "HEAD") and not ALLOWED_WRITES.match(path):
            self.record(403, blocked=True)
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        target = self.path.replace(FAKE_TOKEN, State.account_token)
        headers = {k: v.replace(FAKE_TOKEN, State.account_token) for k, v in self.headers.items()
                   if k.lower() not in HOP_HEADERS}
        if self.role == "plextv":
            if target.startswith("/discover/"):
                host, target = "discover.provider.plex.tv", target[len("/discover"):]
            else:
                host = "plex.tv"
            connection = http.client.HTTPSConnection(host, timeout=60, context=ssl.create_default_context())
        else:
            upstream = urllib.parse.urlparse(State.args.upstream)
            host = upstream.netloc
            connection = http.client.HTTPConnection(upstream.hostname, upstream.port or 80, timeout=120)
        headers["Host"] = host
        rewrite = self.role == "plextv" and path.rstrip("/") == "/api/v2/resources"
        if rewrite:
            headers["Accept"] = "application/json"
            headers.pop("Accept-Encoding", None)
        try:
            connection.request(self.command, target, body=body, headers=headers)
            response = connection.getresponse()
        except OSError as error:
            self.record(502)
            self.send_response(502)
            message = str(error).encode()
            self.send_header("Content-Length", str(len(message)))
            self.end_headers()
            self.wfile.write(message)
            return
        self.record(response.status)
        if rewrite and response.status == 200:
            payload = self.rewrite_resources(json.loads(response.read()))
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_response(response.status, response.reason)
        for key, value in response.getheaders():
            if key.lower() not in HOP_HEADERS:
                self.send_header(key, value)
        size = response.getheader("Content-Length")
        if size is not None:
            self.send_header("Content-Length", size)
            self.end_headers()
            if self.command != "HEAD":
                self.stream(response)
        else:
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            while chunk := response.read(64 * 1024):
                self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
        connection.close()

    def stream(self, response):
        try:
            while chunk := response.read(256 * 1024):
                self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def rewrite_resources(self, resources):
        port = State.args.port + 1
        kept = []
        for resource in resources:
            if resource.get("name") != State.args.server:
                continue
            if resource.get("accessToken"):
                State.server_tokens.add(resource["accessToken"])
            resource["connections"] = [{"protocol": "http", "address": "127.0.0.1", "port": port,
                                        "uri": f"http://127.0.0.1:{port}", "local": True, "relay": False,
                                        "IPv6": False}]
            resource["publicAddress"] = "127.0.0.1"
            resource["httpsRequired"] = False
            kept.append(resource)
        return json.dumps(kept).encode()


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, required=True, help="plex.tv side; the server side is port + 1")
    parser.add_argument("--log", required=True)
    parser.add_argument("--upstream", default="http://storage:10012")
    parser.add_argument("--server", default="plex-demo", help="resource name to keep")
    parser.add_argument("--login-file", default="~/.config/jellyfin-demo/compare-plex-login")
    parser.add_argument("--password-file", default="~/.config/jellyfin-demo/compare-password")
    State.args = parser.parse_args()
    # gate.py signs in once per run and hands the token over in the
    # environment (plex.tv rate-limits a sign-in per screen).
    State.account_token = os.environ.pop("DUSK_PARITY_PLEX_TOKEN", None) or sign_in(State.args)
    State.log = open(State.args.log, "a", buffering=1)
    for role, port in (("plextv", State.args.port), ("pms", State.args.port + 1)):
        server = Server(("127.0.0.1", port), type("P", (Proxy,), {"role": role}))
        threading.Thread(target=server.serve_forever, daemon=True).start()
    print(f"smoke proxy ready on :{State.args.port}/:{State.args.port + 1} -> {State.args.upstream}", flush=True)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as error:
        sys.exit(f"smoke proxy failed: plex.tv sign-in answered HTTP {error.code}")
    except (OSError, KeyError, ValueError) as error:
        sys.exit(f"smoke proxy failed: {type(error).__name__}")
