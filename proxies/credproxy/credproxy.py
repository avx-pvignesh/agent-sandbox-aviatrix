#!/usr/bin/env python3
"""Credential proxy (trusted side). Stdlib only.

- Accepts requests from agent containers on the internal network.
- Refuses anything that is not a model call to the ONE configured provider path
  (403 + log line).
- Strips any auth headers the agent sent, injects the real credential, forwards
  over HTTPS with certificate verification, streams the response back.
- Logs: client, method, path, status, size. Never headers or bodies.
- The credential is read from SECRET_FILE (tmpfs), written in by the
  orchestrator via `docker exec`. It is never in env or argv.

Env:
  PROVIDER_HOST     api.anthropic.com   (derived from your credential mode; ignore host ANTHROPIC_BASE_URL)
  ALLOWED_PREFIXES  /v1/messages        (comma-separated path prefixes)
  AUTH_MODE         api_key | bearer
  SECRET_FILE       /run/secret/credential
  LISTEN_PORT       8080
  ALLOWED_CLIENTS   172.30.0.123        (comma-separated source IPs; empty = any. Keeps the lab
                                         target, which shares the agents network, off the proxy.)

NOTE (blog demo): the path check is a PREFIX match on purpose. It is the "inner lock" and is
known to be broader than needed (e.g. /model/<any model>/..., /v1/messages/batches). DCF URL
filtering at the spoke gateway is the outer lock that enforces the exact paths.
"""
import http.client
import http.server
import os
import socketserver
import ssl
import sys
import time

PROVIDER_HOST = os.environ.get("PROVIDER_HOST", "api.anthropic.com")
ALLOWED = tuple(p.strip() for p in os.environ.get("ALLOWED_PREFIXES", "/v1/messages").split(",") if p.strip())
AUTH_MODE = os.environ.get("AUTH_MODE", "api_key")
SECRET_FILE = os.environ.get("SECRET_FILE", "/run/secret/credential")
PORT = int(os.environ.get("LISTEN_PORT", "8080"))
CLIENTS = frozenset(c.strip() for c in os.environ.get("ALLOWED_CLIENTS", "").split(",") if c.strip())

STRIP_REQ = {"authorization", "x-api-key", "host", "connection", "proxy-authorization",
             "proxy-connection", "keep-alive", "transfer-encoding", "content-length"}
STRIP_RESP = {"transfer-encoding", "content-length", "connection", "keep-alive"}

def log(*parts):
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), *parts, flush=True)

def wait_for_secret():
    while True:
        try:
            with open(SECRET_FILE) as f:
                s = f.read().strip()
            if s:
                return s
        except FileNotFoundError:
            pass
        time.sleep(0.5)

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "credproxy/1.0"
    sys_version = ""

    def log_message(self, *a):  # silence default access log (it includes the full request line)
        pass

    def _deny(self, code, reason):
        body = b"forbidden\n"
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        log(self.client_address[0], self.command, self.path, code, len(body), reason)

    def _forward(self):
        path = self.path
        if CLIENTS and self.client_address[0] not in CLIENTS:
            return self._deny(403, "client-not-allowed")
        if not path.startswith(ALLOWED):
            return self._deny(403, "path-not-allowed")

        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""

        hdrs = {k: v for k, v in self.headers.items() if k.lower() not in STRIP_REQ}
        hdrs["Host"] = PROVIDER_HOST
        if AUTH_MODE == "bearer":
            hdrs["Authorization"] = f"Bearer {SECRET}"
        else:
            hdrs["x-api-key"] = SECRET
        if body:
            hdrs["Content-Length"] = str(len(body))

        ctx = ssl.create_default_context()  # verifies certs
        conn = http.client.HTTPSConnection(PROVIDER_HOST, 443, timeout=600, context=ctx)
        sent = 0
        try:
            conn.request(self.command, path, body=body, headers=hdrs)
            resp = conn.getresponse()
            self.send_response(resp.status)
            for k, v in resp.getheaders():
                if k.lower() not in STRIP_RESP:
                    self.send_header(k, v)
            self.send_header("Connection", "close")  # body is delimited by close
            self.end_headers()
            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
                sent += len(chunk)
            log(self.client_address[0], self.command, path, resp.status, sent)
        except Exception as e:  # upstream failure
            try:
                self._deny(502, f"upstream:{type(e).__name__}")
            except Exception:
                pass
        finally:
            conn.close()
            self.close_connection = True

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_HEAD = _forward

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

if __name__ == "__main__":
    log("waiting for credential at", SECRET_FILE)
    SECRET = wait_for_secret()
    log("credential loaded; provider", PROVIDER_HOST, "paths", ALLOWED, "mode", AUTH_MODE,
        "clients", sorted(CLIENTS) or "ANY")
    Server(("0.0.0.0", PORT), Handler).serve_forever()
