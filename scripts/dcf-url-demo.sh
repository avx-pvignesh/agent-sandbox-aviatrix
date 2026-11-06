#!/usr/bin/env bash
# "The proxy fails, DCF holds."  Blog demo for DCF URL filtering (TLS decryption) at the spoke gateway.
#
# The credential proxy's path check is deliberately broad (prefix match). This script sends requests
# that the proxy WRONGLY forwards, and shows the Aviatrix spoke gateway denying them by URL.
#
#   sudo scripts/dcf-url-demo.sh                          # PROVIDER=bedrock (default)
#   sudo PROVIDER=anthropic scripts/dcf-url-demo.sh
#   sudo scripts/dcf-url-demo.sh discover                 # one real call; prints the EXACT path the
#                                                         # gateway will see, for the URL WebGroup
# Bedrock vars: AWS_REGION, PROFILE_ARN (our application inference profile), OTHER_MODEL_ID
# Run with the URL-phase DCF policy committed (rules 90 / 970 / 980). Needs no image pulls.
set -uo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-demo}"
PROVIDER="${PROVIDER:-bedrock}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CRED_FILE="${CRED_FILE:-/etc/agent-sandbox/credential}"
CRED_IP=172.30.0.12          # demo credproxy, distinct from a live run's 172.30.0.10
CLIENT_IP=172.30.0.250       # plays the part of the agent
DCF_CA=/usr/local/share/ca-certificates/agent-sandbox-dcf-ca.crt
STAMP=$(date -u +%FT%TZ)
HOST_IP=$(hostname -I | awk '{print $1}')

[[ -r "$CRED_FILE" ]] || { echo "credential $CRED_FILE unreadable"; exit 2; }
[[ -f "$DCF_CA" ]] || echo "WARN: DCF CA not installed on host; decrypted flows will fail TLS verification."
# Send model IDs the way the agent does. Claude Code sent them unencoded in run-02
# (/model/us.anthropic...-v1:0/...). Set ENCODE=1 only if your credproxy log shows %3A / %2F.
enc(){ if [[ "${ENCODE:-0}" == 1 ]]; then python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; else printf '%s' "$1"; fi; }

case "$PROVIDER" in
  bedrock)
    [[ "$AWS_REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]] || { echo "bad AWS_REGION"; exit 2; }
    PROVIDER_HOST="bedrock-runtime.$AWS_REGION.amazonaws.com"; AUTH_MODE=bearer; PREFIX="/model/"
    # Either our application inference profile ARN (account-bound) or the geo profile ID (no IT needed).
    PROFILE_ARN="${PROFILE_ARN:?set PROFILE_ARN=<application-inference-profile ARN or global.anthropic.claude-sonnet-5-5>}"
    OTHER_MODEL_ID="${OTHER_MODEL_ID:-us.anthropic.claude-sonnet-5-5}"   # same model via the US geo profile: a different URL, not the one DCF permits
    FOREIGN_ARN="arn:aws:bedrock:$AWS_REGION:999999999999:application-inference-profile/attacker0000"
    BODY='{"anthropic_version":"bedrock-2023-05-31","max_tokens":8,"messages":[{"role":"user","content":"ping"}]}'
    GOOD="POST /model/$(enc "$PROFILE_ARN")/invoke-with-response-stream"
    BAD1="POST /model/$(enc "$OTHER_MODEL_ID")/invoke-with-response-stream"     # proxy allows any /model/: not our profile
    BAD2="POST /model/$(enc "$FOREIGN_ARN")/invoke-with-response-stream"        # another account's profile
    BAD1_WHY="a model that is not our inference profile"
    BAD2_WHY="another AWS account's inference profile" ;;
  anthropic)
    PROVIDER_HOST=api.anthropic.com; AUTH_MODE=api_key; PREFIX="/v1/messages"
    MODEL="${MODEL:-claude-haiku-4-5}"
    BODY="{\"model\":\"$MODEL\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}"
    GOOD="POST /v1/messages"
    BAD1="GET /v1/messages/batches"                         # Message Batches API sits under the prefix
    BAD2="GET /v1/messages/batches?limit=100"
    BAD1_WHY="the Message Batches API (reads other jobs' results)"
    BAD2_WHY="the same, with a query string" ;;
  *) echo "unknown PROVIDER"; exit 2 ;;
esac

CA_ARGS=()
[[ -f "$DCF_CA" ]] && CA_ARGS=(-v /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro
                               -e SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt)

cleanup(){ docker logs credproxy-demo > runs/dcf-url-demo-credproxy.log 2>&1; docker rm -f credproxy-demo >/dev/null 2>&1; }
trap cleanup EXIT
mkdir -p runs
docker rm -f credproxy-demo >/dev/null 2>&1 || true
docker run -d --name credproxy-demo --network agents --ip "$CRED_IP" \
  --read-only --tmpfs /run/secret:rw,mode=0700,size=64k --cap-drop ALL --security-opt no-new-privileges \
  -e PROVIDER_HOST="$PROVIDER_HOST" -e AUTH_MODE="$AUTH_MODE" -e ALLOWED_PREFIXES="$PREFIX" \
  -e ALLOWED_CLIENTS="$CLIENT_IP" "${CA_ARGS[@]}" agent-sandbox/credproxy:latest >/dev/null
docker network connect bridge credproxy-demo
docker exec -i credproxy-demo sh -c 'umask 077; cat > /run/secret/credential' < "$CRED_FILE"
sleep 1

# Client runs on the agents network, like the agent. Reuses the credproxy image (no pulls under deny-all).
call(){  # call "METHOD /path"
  local m="${1%% *}" p="${1#* }"
  docker run --rm --network agents --ip "$CLIENT_IP" --entrypoint python3 agent-sandbox/credproxy:latest -I -c '
import http.client,sys
m,p,b=sys.argv[1],sys.argv[2],sys.argv[3].encode()
c=http.client.HTTPConnection(sys.argv[4],8080,timeout=30)
try:
    c.request(m,p,body=b if m=="POST" else None,headers={"content-type":"application/json","anthropic-version":"2023-06-01"})
    r=c.getresponse(); print(r.status, r.read(160).decode(errors="replace").replace("\n"," "))
except Exception as e: print("ERR", type(e).__name__)
' "$m" "$p" "$BODY" "$CRED_IP"
}

if [[ "$MODE" == discover ]]; then
  echo "== one real call; the path below is what the gateway sees:"
  echo "   $PROVIDER_HOST${GOOD#* }"
  if [[ "$PROVIDER" == bedrock && "$PROFILE_ARN" == arn:* ]]; then
    PID="${PROFILE_ARN##*/}"
    echo "   URL WebGroups reject ':' so the exact path cannot be entered. Use the wildcard form"
    echo "   (profile IDs are AWS-generated and unique, so matching on the ID is still account-specific):"
    echo "     $PROVIDER_HOST/model/*application-inference-profile/$PID/invoke-with-response-stream"
    echo "     $PROVIDER_HOST/model/*application-inference-profile/$PID/invoke"
  fi
  echo "-- call result (expect 200):"
  call "$GOOD"
  exit 0
fi

echo "== $STAMP  DCF URL demo  provider=$PROVIDER  host=$HOST_IP"
printf '\n[1] Legit model call (proxy forwards, DCF permits)\n    %s\n    -> ' "$GOOD"; call "$GOOD"
printf '\n[2] Proxy bug: %s\n    %s\n    -> ' "$BAD1_WHY" "$BAD1"; call "$BAD1"
printf '\n[3] Proxy bug: %s\n    %s\n    -> ' "$BAD2_WHY" "$BAD2"; call "$BAD2"
printf '\n[4] Direct bypass from the host, model domain, wrong path\n    -> '
curl -s -o /dev/null -w 'HTTP %{http_code}\n' --max-time 8 "https://$PROVIDER_HOST/" || echo "blocked (expected)"
printf '\n[5] Direct bypass from the host, arbitrary site\n    -> '
curl -s -o /dev/null -w 'HTTP %{http_code}\n' --max-time 8 https://example.com/ || echo "blocked (expected)"

echo; echo "== credproxy view (it FORWARDED 2 and 3; that is the inner-lock failure):"
docker logs credproxy-demo 2>&1 | grep -v "waiting for\|credential loaded" | sed 's/^/    /'

cat <<EOF

== Expected
  [1] 200 with a model reply                 CoPilot: Permit  permit-model-api     URL ...${GOOD#* }
  [2] blocked (403 with empty body / reset)  CoPilot: Deny    default-deny-all
  [3] blocked                                CoPilot: Deny    default-deny-all
  [4] blocked                                CoPilot: Deny    default-deny-all
  [5] blocked                                CoPilot: Deny    default-deny-all
  A DCF block never carries a provider response body. If [2] or [3] returns 200, or a 403 whose body is a provider
  error (e.g. AccessDeniedException), the request reached the provider and the URL rule is not deciding: check that
  the permit rule's WebGroup is URL-type and TLS Decryption is on.

== CoPilot: Security > Distributed Cloud Firewall > Monitor, source $HOST_IP, time >= $STAMP
  Screenshot [1]-[5] in one view. Headline for the blog: the proxy forwarded [2] and [3]; the gateway stopped them.
EOF
