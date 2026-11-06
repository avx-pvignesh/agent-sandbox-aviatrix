#!/usr/bin/env bash
# (Re)start the egress allowlist proxy. Dual-homed: agents net (internal) + default bridge (route out).
# Run between batches only; restarting drops live agent connections.
set -euo pipefail
cd "$(dirname "$0")/.."
EGRESS_IP="${EGRESS_IP:-172.30.0.11}"

docker rm -f egressproxy >/dev/null 2>&1 || true
docker run -d --name egressproxy --restart unless-stopped \
  --network agents --ip "$EGRESS_IP" \
  --read-only --cap-drop ALL --security-opt no-new-privileges \
  -v "$PWD/proxies/egressproxy/allowlist.txt:/etc/egress/allowlist.txt:ro" \
  agent-sandbox/egressproxy:latest
docker network connect bridge egressproxy

sleep 1
echo "==> egress proxy loaded:"
docker logs egressproxy 2>&1 | tail -1
