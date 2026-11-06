#!/usr/bin/env bash
# Check: a denied egress attempt FROM THE HOST shows up in CoPilot DCF logs.
# Run with the attack-phase policy active (setup rule removed). Note the timestamps.
set -uo pipefail
MODEL_HOST="${MODEL_HOST:-bedrock-runtime.${AWS_REGION:-us-east-1}.amazonaws.com}"
DENY_HOST="${DENY_HOST:-example.com}"
STAMP=$(date -u +%FT%TZ)

echo "== $STAMP  host egress probes (source: $(hostname -I | awk '{print $1}'))"
echo "-- model host, path '/': PERMITTED with SNI-only filtering; DENIED when URL filtering is on (path not in the WebGroup):"
curl -s -o /dev/null -w "  https://$MODEL_HOST  -> HTTP %{http_code}\n" --max-time 10 "https://$MODEL_HOST/" || echo "  $MODEL_HOST -> blocked (expected in URL phase; unexpected in domain phase)"
echo "-- should be DENIED by default-deny-all:"
for i in 1 2 3; do
  curl -s -o /dev/null -w "  https://$DENY_HOST  -> HTTP %{http_code}\n" --max-time 8 "https://$DENY_HOST/" \
    || echo "  https://$DENY_HOST -> blocked/timed out (expected)"
done
# Plain HTTP: DCF terminates the flow and answers 403 itself, so judge by status code, not curl's exit code.
C=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://1.1.1.1/ || true)
case "$C" in
  000|403) echo "  http://1.1.1.1 -> HTTP $C, blocked (expected; 403 = DCF block response)" ;;
  *)       echo "  http://1.1.1.1 -> HTTP $C (UNEXPECTED: check DCF)" ;;
esac

cat <<EOF

== Now confirm in CoPilot
  Security -> Distributed Cloud Firewall -> Monitor  (or Logs)
  Filter:  Action = Deny,  Policy = default-deny-all,  time >= $STAMP
  Expect:  source $(hostname -I | awk '{print $1}')  dst $DENY_HOST / 1.1.1.1  :443/:80  DENY
  Contrast: Action = Permit, Policy = permit-model-api -> a real model call carries the allowed URL (visible when URL filtering is on).
Screenshot both for the writeup.
EOF
