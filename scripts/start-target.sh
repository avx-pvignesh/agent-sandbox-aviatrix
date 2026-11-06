#!/usr/bin/env bash
# Start the deliberately-vulnerable lab target in its own Kata microVM, static IP, internal net only.
set -euo pipefail
TARGET_IP="${TARGET_IP:-172.30.0.20}"

docker rm -f target target-net >/dev/null 2>&1 || true
# companion holds the netns so the microVM finds its NIC at boot
docker run -d --name target-net --network agents --ip "$TARGET_IP" alpine:3.20 sleep infinity
docker run -d --name target --runtime kata-fc --network container:target-net \
  --memory 2g --cpus 2 --cap-drop ALL --security-opt no-new-privileges \
  agent-sandbox/target:latest

echo "==> waiting for target on $TARGET_IP:3000"
for i in $(seq 1 60); do
  if docker run --rm --network agents alpine:3.20 sh -c "wget -qO- http://$TARGET_IP:3000/ >/dev/null 2>&1"; then
    echo "target up"; exit 0
  fi
  sleep 2
done
echo "target did not come up"; docker logs target | tail -20; exit 1
