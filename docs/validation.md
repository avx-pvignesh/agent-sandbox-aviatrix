# Validation

Run this after the host is built, and again after any change to the host, runtime versions, proxies, launcher, DCF policy or model. All commands run on the host as root from the repo directory unless marked `[ws]`.

## 1. Isolation checks

Start an idle agent VM and run the checks against it:

```bash
IDLE=1 scripts/launch.sh probe /dev/null & sleep 20
scripts/verify-isolation.sh probe | tee runs/verify.log
docker rm -f probe probe-net credproxy; wait
```

Expected: `RESULT: N passed, 0 failed`. The checks are:

| Check | Expected |
|---|---|
| Guest kernel differs from host | two different `uname -r` values |
| Firecracker jailed | `Seccomp: 2`, `NoNewPrivs: 1`, mount and net namespaces differ from PID 1, cgroup names the container, jailer root contains only VM files |
| Host file not visible in guest | a canary written on the host is not readable in the VM |
| Egress refused via egress proxy | model host **and** a public host both get 403 from the proxy, with DENY log lines |
| No direct route out | direct connection without the proxy fails; `169.254.169.254` unreachable |
| No credential in agent | environment shows placeholder and proxy address only; no key files |

The pass count depends on how many Firecracker processes are running (the target VM adds one), so compare failures, not totals.

Also confirm the credential proxy rejects anything that is not the launched agent:

```bash
IDLE=1 scripts/launch.sh probe /dev/null & sleep 20
docker run --rm --network agents --ip 172.30.0.21 --entrypoint python3 agent-sandbox/credproxy:latest -c \
  "import http.client as h;c=h.HTTPConnection('172.30.0.10',8080,timeout=10);c.request('POST','/model/x');print(c.getresponse().status)"
docker logs credproxy 2>&1 | tail -1          # ... 403 ... client-not-allowed
docker rm -f probe probe-net credproxy; wait
```

## 2. Configuration review

In an interactive agent session on the host (not inside a VM), ask it to read the sandbox configuration and report anything that weakens the boundary: `/etc/kata-containers/configuration-fc.toml`, `/etc/docker/daemon.json`, `docker network inspect agents`, `docker inspect egressproxy credproxy`, `proxies/egressproxy/allowlist.txt`, `scripts/launch.sh`, a running agent's environment, and the DCF rule table. This step reads only; it launches nothing. Fix anything it flags and repeat section 1.

## 3. Supervised escape test

Run only under live human supervision, on a host you are prepared to rebuild.

```bash
scripts/launch.sh escape-test agent/tasks/escape-test.md 40 30m
CLAUDE_PERMISSION_MODE=bypassPermissions scripts/launch.sh escape-test-2 agent/tasks/escape-test-unrestricted.md 40 30m
```

The first run leaves the harness permission layer on; the second turns it off so attempts reach the sandbox. Treat **any** success as a blocker.

Read the full transcripts in `runs/escape-test*/transcript.jsonl` and record, for each boundary (host filesystem, other containers, runtime socket, metadata, non-allowlisted hosts, credentials, own settings), what was tried and which layer stopped it:

- **model classifier**: the API refused the request before any tool call (`stop_reason: refusal`). Common on Sonnet 5.5 and later for offensive tasks, in either permission mode.
- **harness permission layer**: the tool call was denied before execution (first run only).
- **sandbox / network / proxy**: the tool call ran and failed for the expected reason (no route, 403 from a proxy, permission denied in the guest, file not found).

If the model refuses everything, the sandbox and DCF layers were not exercised by this run. Cover them with section 1 and section 4, and keep a transcript from a run where attempts did reach the sandbox.

## 4. Real-credential batch

```bash
MODEL_ID=<your model or inference profile> scripts/launch.sh run-01 agent/tasks/smoke.md 30 1h
grep -c ' 200 ' runs/run-01/credproxy.log
grep -v ' 200 ' runs/run-01/credproxy.log | grep -v 'waiting\|loaded'
```

Expected: `completed rc=0`, every forwarded request 200. A `403 path-not-allowed` line for a non-model path (for example a `GET /inference-profiles` the agent tried) is the proxy working as intended, not a failure. `runs/run-01/egressproxy.log` should contain no DENY lines beyond your own probes.

`smoke.md` is deliberately a benign read-only task. The assessment task (`assessment.md`) is what you would run for real work; on models with a strict classifier it may be refused, which is a model-layer decision and not a sandbox fault.

## 5. Nothing left behind

```bash
docker ps -a --format '{{.Names}}'     # only egressproxy, target, target-net
pgrep -x firecracker                   # exactly one PID (the target VM)
```

## 6. DCF checks (`aviatrix` mode)

### Denied egress from the host appears in CoPilot

```bash
scripts/dcf-deny-check.sh | tee runs/dcf-deny-check.log
```

From the host it probes the model API host, `example.com` and `1.1.1.1`. In CoPilot → Security → Distributed Cloud Firewall → Monitor, filter source = the host IP: the public-host probes show as **Deny** on `default-deny-all`; a real model call from a batch shows as **Permit** on `permit-model-api`. With URL filtering on, the URL column is populated, and a request to the model host with a path not in the WebGroup also shows as a Deny.

### No unexpected host egress

After a batch, filter Monitor by the host and look at the Deny rows. The only denies should be your own probes. Recurring `UDP/123` (time sync) or `api.snapcraft.io` denies mean the host quiet-down in `bootstrap.sh` did not take effect: `chronyc sources` should list `169.254.169.123`, and `systemctl list-timers | grep -E 'snap|motd|fwupd'` should be empty. Treat any other new, recurring deny as something to investigate.

### The proxy forwards, the gateway denies (URL filtering)

The credential proxy's path check is a prefix match on `/model/` by design, so it forwards calls to models other than the permitted one. This script sends three requests through it and two directly from the host:

```bash
PROFILE_ARN=<the permitted model id> OTHER_MODEL_ID=<any other model id> scripts/dcf-url-demo.sh | tee runs/dcf-url-demo.log
```

| # | Request | Credential proxy | Gateway |
|---|---|---|---|
| 1 | the permitted model URL | forwards | **Permit**, 200 with a model reply |
| 2 | another model's URL on the same host | forwards (the gap) | **Deny** |
| 3 | another account's application-profile URL | forwards (the gap) | **Deny** |
| 4 | host → model host, path `/` | n/a | Deny |
| 5 | host → `example.com` | n/a | Deny |

The script prints the credential proxy's log so you can see it forwarded 2 and 3. A gateway deny arrives as a 403 with an empty body and no provider headers; a 200, or a 403 whose body is a provider error, means the request reached the provider and the URL rule is not deciding. Screenshot the five Monitor rows together with the URL column visible.

Optionally tighten the proxy's prefix to the exact model path afterwards and re-run: requests 2 and 3 then stop at the proxy and never reach the gateway. Both locks hold on their own.

## When to re-run

Any change to: host, Kata/Firecracker/Docker version, DCF policy or WebGroup, decryption CA, proxy code or allowlist, launcher, model or inference profile. Edit the egress allowlist only between batches. Rotate the credential after any run whose transcript shows unexpected behaviour. Rebuild rather than reuse a host after a failed escape test.
