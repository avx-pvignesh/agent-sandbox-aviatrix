#!/usr/bin/env bash
# Launch ONE agent run inside a Kata/Firecracker microVM, the only supported way to start an agent.
#
#   scripts/launch.sh <run-name> <task.md> [MAX_TURNS] [TIME_LIMIT]
#   IDLE=1 scripts/launch.sh probe /dev/null        # agent container that just sleeps (for hand checks)
#
# Credential: /etc/agent-sandbox/credential (mode 0600, root). Never in env, never in the agent.
set -euo pipefail
cd "$(dirname "$0")/.."

RUN="${1:?run name}"; TASK="${2:?task file}"
MAX_TURNS="${3:-${MAX_TURNS:-30}}"
TIME_LIMIT="${4:-${TIME_LIMIT:-1h}}"
CRED_FILE="${CRED_FILE:-/etc/agent-sandbox/credential}"
PROVIDER="${PROVIDER:-bedrock}"                # bedrock | anthropic
AWS_REGION="${AWS_REGION:-us-east-1}"
MODEL_ID="${MODEL_ID:-global.anthropic.claude-sonnet-5-5}"   # or our application inference profile ARN
case "$PROVIDER" in
  bedrock)
    # Region is checked against a strict pattern so a malformed value cannot send the credential elsewhere.
    [[ "$AWS_REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]] || { echo "bad AWS_REGION"; exit 2; }
    PROVIDER_HOST="bedrock-runtime.${AWS_REGION}.amazonaws.com"
    AUTH_MODE="bearer"; ALLOWED_PREFIXES="/model/" ;;
  anthropic)
    PROVIDER_HOST="api.anthropic.com"; AUTH_MODE="api_key"; ALLOWED_PREFIXES="/v1/messages" ;;
  *) echo "unknown PROVIDER $PROVIDER"; exit 2 ;;
esac
CRED_IP="${CRED_IP:-172.30.0.10}"
EGRESS_IP="${EGRESS_IP:-172.30.0.11}"
AGENT_IP="${AGENT_IP:-172.30.0.$((100 + RANDOM % 100))}"
RUNDIR="runs/$RUN"; mkdir -p "$RUNDIR"
# DCF TLS decryption: if the interception CA is installed on the host, credproxy must trust it.
DCF_CA="${DCF_CA:-/usr/local/share/ca-certificates/agent-sandbox-dcf-ca.crt}"
CA_ARGS=()
if [[ -f "$DCF_CA" ]]; then
  CA_ARGS=(-v /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro
           -e SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt)
fi

die(){ echo "LAUNCH REFUSED: $*" >&2; echo "refused: $*" > "$RUNDIR/status"; exit 2; }

# ---------------------------------------------------------------- preflight (refuse to run otherwise)
docker info --format '{{json .Runtimes}}' | grep -q '"kata-fc"' || die "kata-fc runtime not registered"
[[ -c /dev/kvm ]]                                               || die "/dev/kvm missing"
docker inspect -f '{{.State.Running}}' egressproxy 2>/dev/null | grep -q true || die "egress proxy not running"
docker network inspect agents -f '{{.Internal}}' | grep -q true || die "agents network not internal"
[[ "$MAX_TURNS" =~ ^[0-9]+$ && "$MAX_TURNS" -gt 0 ]]            || die "MAX_TURNS unreadable"
[[ "$TIME_LIMIT" =~ ^[0-9]+[smh]$ ]]                            || die "TIME_LIMIT unreadable"
[[ -r "$CRED_FILE" ]] || [[ "${IDLE:-0}" == 1 ]]                || die "credential file $CRED_FILE unreadable"
# leftovers from a killed run
for c in credproxy "$RUN" "$RUN-net"; do docker rm -f "$c" >/dev/null 2>&1 || true; done

cleanup(){
  set +e
  docker logs credproxy > "$RUNDIR/credproxy.log" 2>&1
  docker logs egressproxy > "$RUNDIR/egressproxy.log" 2>&1
  docker rm -f "$RUN" "$RUN-net" credproxy >/dev/null 2>&1
  echo "teardown complete: $RUNDIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------- credential proxy: fresh per launch, trusted side (runc)
docker run -d --name credproxy \
  --network agents --ip "$CRED_IP" \
  --read-only --tmpfs /run/secret:rw,mode=0700,size=64k \
  --cap-drop ALL --security-opt no-new-privileges \
  -e PROVIDER_HOST="$PROVIDER_HOST" -e AUTH_MODE="$AUTH_MODE" -e ALLOWED_PREFIXES="$ALLOWED_PREFIXES" \
  -e ALLOWED_CLIENTS="$AGENT_IP" "${CA_ARGS[@]}" \
  agent-sandbox/credproxy:latest >/dev/null
docker network connect bridge credproxy          # direct route to the provider; NOT via egress proxy
if [[ "${IDLE:-0}" != 1 ]]; then
  docker exec -i credproxy sh -c 'umask 077; cat > /run/secret/credential' < "$CRED_FILE"
else
  echo placeholder | docker exec -i credproxy sh -c 'umask 077; cat > /run/secret/credential'
fi
sleep 1; docker logs credproxy 2>&1 | grep -q "credential loaded" || die "credential proxy did not start"

# ---------------------------------------------------------------- companion netns + agent microVM
docker run -d --name "$RUN-net" --network agents --ip "$AGENT_IP" alpine:3.20 sleep infinity >/dev/null

AGENT_ENV=(
  -e HTTP_PROXY="http://$EGRESS_IP:3128" -e HTTPS_PROXY="http://$EGRESS_IP:3128"
  -e NO_PROXY="$CRED_IP,172.30.0.20"
  -e MAX_TURNS="$MAX_TURNS"
  -e DISABLE_TELEMETRY=1 -e DISABLE_AUTOUPDATER=1 -e DISABLE_ERROR_REPORTING=1
  -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
  # A classifier refusal or a model the SCP denies must fail fast, not silently switch to
  # a different (and here, SCP-denied) model and spin on 403s. Keeps the run on the pinned model.
  # ACCESS fallback = model disabled mid-session; REFUSAL fallback = safety classifier flag.
  # Both must be off, since our only SCP-allowed model is the pinned one (no valid fallback target).
  -e CLAUDE_CODE_DISABLE_MODEL_ACCESS_FALLBACK=1
  -e CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK=1
)
if [[ "$PROVIDER" == bedrock ]]; then
  # Article's Bedrock route: proxy address, skip-auth flag, region. No AWS credential in the container.
  AGENT_ENV+=(
    -e CLAUDE_CODE_USE_BEDROCK=1
    -e ANTHROPIC_BEDROCK_BASE_URL="http://$CRED_IP:8080"
    -e CLAUDE_CODE_SKIP_BEDROCK_AUTH=1
    -e AWS_REGION="$AWS_REGION"
    -e ANTHROPIC_MODEL="$MODEL_ID"
  )
else
  AGENT_ENV+=(
    -e ANTHROPIC_BASE_URL="http://$CRED_IP:8080"
    -e ANTHROPIC_API_KEY="placeholder-held-by-credential-proxy"
  )
fi
[[ -n "${CLAUDE_PERMISSION_MODE:-}" ]] && AGENT_ENV+=(-e CLAUDE_PERMISSION_MODE="$CLAUDE_PERMISSION_MODE")

CMD=()
[[ "${IDLE:-0}" == 1 ]] && CMD=("sleep infinity")
# Engagement allowlist: pre-approve only what the task needs; the classifier still decides everything else.
#   ALLOWED_TOOLS='Bash(curl:*),Bash(head:*),Bash(grep:*),Bash(jq:*),Read,Write,Edit'
if [[ "${IDLE:-0}" != 1 && -n "${ALLOWED_TOOLS:-}" ]]; then
  CMD=("claude -p \"\$(cat /task/task.md)\" --max-turns $MAX_TURNS --allowedTools '$ALLOWED_TOOLS' --output-format stream-json --verbose")
fi

echo "run=$RUN agent_ip=$AGENT_IP turns=$MAX_TURNS time=$TIME_LIMIT task=$TASK"
echo "started $(date -u +%FT%TZ)" > "$RUNDIR/status"

# Hard time limit: kill the container from the host, run is final.
set +e
timeout --signal=KILL "$TIME_LIMIT" \
  docker run --name "$RUN" --runtime kata-fc --network "container:$RUN-net" \
    --memory 4g --cpus 4 \
    --cap-drop ALL --security-opt no-new-privileges \
    -v "$(readlink -f "$TASK"):/task/task.md:ro" \
    "${AGENT_ENV[@]}" \
    agent-sandbox/agent:latest "${CMD[@]}" \
  | tee "$RUNDIR/transcript.jsonl"
RC=${PIPESTATUS[0]}
set -e
# Kata can return 255 on VM teardown after the agent exits cleanly; a final result line means it finished.
if [[ $RC -ne 0 && $RC -ne 137 ]] && grep -q '"type":"result"' "$RUNDIR/transcript.jsonl" 2>/dev/null; then RC=0; fi
case $RC in
  0)   echo "completed rc=0" >> "$RUNDIR/status" ;;
  137) echo "FAILED: time limit hit, killed" >> "$RUNDIR/status" ;;
  *)   echo "FAILED rc=$RC" >> "$RUNDIR/status" ;;
esac
cat "$RUNDIR/status"
