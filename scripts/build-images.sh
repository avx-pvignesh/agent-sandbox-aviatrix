#!/usr/bin/env bash
# Build proxy + agent images and pull the pinned target. SETUP PHASE ONLY (needs DCF rule 110).
set -euo pipefail
cd "$(dirname "$0")/.."

CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-2.1.308}"
TARGET_IMAGE="${TARGET_IMAGE:-bkimminich/juice-shop@sha256:42843723a7bf4246aa5d63c324978b17ef296ac78434aeddd34c427bfb5853f4}"

echo "==> base image digests (edit the Dockerfiles' PIN_ME with these)"
for img in python:3.12-slim node:22-bookworm-slim alpine:3.20; do
  docker pull -q "$img" >/dev/null
  echo "$img -> $(docker inspect --format='{{index .RepoDigests 0}}' "$img")"
done

# Allow building before you've pasted digests in (replace PIN_ME with the tag)
sed_pin(){ sed 's/@sha256:PIN_ME//' "$1" > "$1.build"; }
sed_pin proxies/credproxy/Dockerfile
sed_pin proxies/egressproxy/Dockerfile
sed_pin agent/Dockerfile

docker build -t agent-sandbox/credproxy:latest  -f proxies/credproxy/Dockerfile.build  proxies/credproxy
docker build -t agent-sandbox/egressproxy:latest -f proxies/egressproxy/Dockerfile.build proxies/egressproxy
docker build -t agent-sandbox/agent:latest --build-arg CLAUDE_CODE_VERSION="$CLAUDE_CODE_VERSION" \
             -f agent/Dockerfile.build agent
rm -f proxies/*/Dockerfile.build agent/Dockerfile.build

docker pull "$TARGET_IMAGE"
docker tag "$TARGET_IMAGE" agent-sandbox/target:latest

echo "==> agent CLI runs under kata-fc?"
docker run --rm --runtime kata-fc agent-sandbox/agent:latest 'claude --version'
echo "==> images ready. Record digests for the writeup:"
docker images --digests 'agent-sandbox/*'
