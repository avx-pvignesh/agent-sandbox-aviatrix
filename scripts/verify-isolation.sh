#!/usr/bin/env bash
# Host isolation checks, as a script. Run as root on the host
# while an IDLE probe agent is up:   IDLE=1 scripts/launch.sh probe /dev/null &
set -uo pipefail
AGENT="${1:-probe}"
EGRESS_IP="${EGRESS_IP:-172.30.0.11}"
PASS=0; FAIL=0
ok(){ echo "  PASS: $*"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

echo "== 1. Separate guest kernel"
HK=$(uname -r); GK=$(docker exec "$AGENT" uname -r)
echo "  host=$HK guest=$GK"
[[ "$HK" != "$GK" ]] && ok "kernels differ" || bad "same kernel"

echo "== 2. VM monitor jailed on the host"
PIDS=$(pgrep -x firecracker || true)
[[ -z "$PIDS" ]] && bad "no firecracker process found"
for p in $PIDS; do
  ROOT=$(readlink /proc/$p/root)
  echo "  pid=$p root=$ROOT"
  echo "  root contents: $(ls /proc/$p/root 2>/dev/null | tr '\n' ' ')"
  SEC=$(awk '/^Seccomp:/{print $2}' /proc/$p/status); NNP=$(awk '/^NoNewPrivs:/{print $2}' /proc/$p/status)
  [[ "$SEC" == 2 ]] && ok "Seccomp: 2" || bad "Seccomp: $SEC"
  [[ "$NNP" == 1 ]] && ok "NoNewPrivs: 1" || bad "NoNewPrivs: $NNP"
  [[ "$(readlink /proc/$p/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ]] && ok "mount ns differs from host" || bad "mount ns == host"
  [[ "$(readlink /proc/$p/ns/net)" != "$(readlink /proc/1/ns/net)" ]] && ok "net ns differs from host"   || bad "net ns == host"
  CG=$(cat /proc/$p/cgroup); echo "  cgroup: $CG"
  CID=$(docker inspect -f '{{.Id}}' "$AGENT")
  echo "$CG" | grep -q "${CID:0:12}" && ok "cgroup names the container" || echo "  NOTE: cgroup path does not contain container id; confirm manually"
done

echo "== 3. Host file not visible inside"
echo canary-$RANDOM > /root/host-canary.txt
if docker exec "$AGENT" cat /root/host-canary.txt >/dev/null 2>&1; then bad "host file readable in guest"; else ok "host file not found in guest"; fi
rm -f /root/host-canary.txt

echo "== 4. Egress refused via egress proxy (model host AND a public host)"
MODEL_HOST="${MODEL_HOST:-bedrock-runtime.${AWS_REGION:-us-east-1}.amazonaws.com}"
for h in "$MODEL_HOST" example.com; do
  # HTTPS via proxy: the proxy's answer to CONNECT is in %{http_connect}, not %{http_code}
  CODE=$(docker exec "$AGENT" curl -s -o /dev/null -w '%{http_connect}' --max-time 10 -x "http://$EGRESS_IP:3128" "https://$h/" || true)
  [[ "$CODE" == 403 ]] && ok "$h -> 403" || bad "$h -> '$CODE' (expected 403)"
done
echo "  egress proxy deny lines:"; docker logs egressproxy 2>&1 | grep DENY | tail -2 | sed 's/^/    /'
echo "== 4b. No direct route out of the guest (bypassing the proxy)"
if docker exec "$AGENT" env -u HTTPS_PROXY -u HTTP_PROXY curl -s --max-time 8 https://example.com >/dev/null 2>&1; then bad "direct egress worked"; else ok "direct egress fails (internal network)"; fi
if docker exec "$AGENT" curl -s --max-time 5 http://169.254.169.254/ >/dev/null 2>&1; then bad "metadata reachable"; else ok "metadata unreachable"; fi

echo "== 5. No credential in the agent container"
docker exec "$AGENT" env | grep -iE 'anthropic|claude|aws_|google|vertex|bedrock|token|key' | sed 's/^/  /'
if docker exec "$AGENT" env | grep -iE '^(ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN)=' | grep -vq placeholder; then bad "real-looking credential in env"; else ok "placeholder only"; fi
docker exec "$AGENT" sh -c 'ls -la ~/.aws ~/.ssh .env /run/secret 2>&1' | sed 's/^/  /' | grep -q "No such" && ok "no credential files" || echo "  NOTE: check listed paths"

echo; echo "RESULT: $PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]
