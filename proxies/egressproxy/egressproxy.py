#!/usr/bin/env python3
"""Egress allowlist proxy. Stdlib only. Deny-by-default.

Allowlist file: one `host:port` per line (# comments ok). EMPTY by default.
Changing it requires a restart (drops live agent connections) -- do it between batches.

- HTTPS: CONNECT host:port -> allowed? tunnel : 403 + "DENY" line
- HTTP:  parse Host header -> allowed? forward : 403 + "DENY" line
- Log: ts client ALLOW|DENY host:port

Never add the model-API host here. Agents reach the model only via the credential proxy.
"""
import http.client
import http.server
import os
import select
import socket
import socketserver
import time

ALLOWLIST_FILE = os.environ.get("ALLOWLIST_FILE", "/etc/egress/allowlist.txt")
PORT = int(os.environ.get("LISTEN_PORT", "3128"))

def load_allowlist():
    s = set()
    try:
        with open(ALLOWLIST_FILE) as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                if line:
                    s.add(line.lower())
    except FileNotFoundError:
        pass
    return frozenset(s)

ALLOW = load_allowlist()

def log(*parts):
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), *parts, flush=True)

def relay(a, b):
    socks = [a, b]
    while True:
        r, _, x = select.select(socks, [], socks, 300)
        if x or not r:
            return
        for s in r:
            data = s.recv(65536)
            if not data:
                return
            (b if s is a else a).sendall(data)

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "egressproxy/1.0"
    sys_version = ""

    def log_message(self, *a):
        pass

    def _deny(self, target):
        body = b"egress denied by allowlist\n"
        self.send_response(403)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True
        log(self.client_address[0], "DENY", target)

    def do_CONNECT(self):
        target = self.path.lower()
        if target not in ALLOW:
            return self._deny(target)
        host, port = target.rsplit(":", 1)
        try:
            up = socket.create_connection((host, int(port)), timeout=15)
        except OSError as e:
            return self._deny(f"{target} (connect-failed:{type(e).__name__})")
        self.send_response(200, "Connection established")
        self.send_header("Connection", "close")
        self.end_headers()
        log(self.client_address[0], "ALLOW", target)
        try:
            relay(self.connection, up)
        finally:
            up.close()
            self.close_connection = True

    def _http(self):
        host = (self.headers.get("Host") or "").lower()
        if ":" not in host:
            host = f"{host}:80"
        if host not in ALLOW:
            return self._deny(host)
        h, p = host.rsplit(":", 1)
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        path = self.path
        if path.startswith("http://"):
            path = "/" + path.split("/", 3)[3] if path.count("/") >= 3 else "/"
        conn = http.client.HTTPConnection(h, int(p), timeout=60)
        try:
            hdrs = {k: v for k, v in self.headers.items() if k.lower() not in ("proxy-connection", "connection")}
            conn.request(self.command, path, body=body, headers=hdrs)
            resp = conn.getresponse()
            data = resp.read()
            self.send_response(resp.status)
            for k, v in resp.getheaders():
                if k.lower() not in ("transfer-encoding", "content-length", "connection"):
                    self.send_header(k, v)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(data)
            log(self.client_address[0], "ALLOW", host, resp.status)
        finally:
            conn.close()
            self.close_connection = True

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = do_HEAD = _http

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

if __name__ == "__main__":
    log(f"allowlist loaded from {ALLOWLIST_FILE}: {sorted(ALLOW) or 'EMPTY (deny all)'}")
    Server(("0.0.0.0", PORT), Handler).serve_forever()
