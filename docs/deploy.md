# Deployment

Two phases. **Setup** builds the host and images and needs package sources reachable. **Run** is when agents execute; the host can reach nothing but the model API. In `aviatrix` mode the phase is a Terraform variable (`setup_phase`). In `nat` mode there is no network-layer difference between the phases; the in-host proxies are the only control.

Notation: `[ws]` your workstation, `[host]` a Session Manager shell on the EC2 host as root, `[copilot]` the Aviatrix CoPilot UI.

## 0. Prerequisites

- A dedicated AWS account (or at least a dedicated VPC) and a CLI profile for it.
- Terraform >= 1.6. AWS CLI with the Session Manager plugin.
- A model-API credential scoped to agent runs. For Bedrock, a Bedrock API key (bearer token) is the simplest; keep its IAM policy limited to the one inference profile you will use.
- `aviatrix` mode: Controller IP, admin credentials, and the access-account name for this AWS account.

## 1. Network and host

```bash
cd terraform/base
cp terraform.tfvars.example terraform.tfvars
# set: aws_profile, egress_mode ("aviatrix" or "nat"), instance_type
terraform init
terraform apply
terraform output
```

Outputs include `host_instance_id`, `host_private_ip` and a ready-made `ssm_connect` command. The host has no public IP and no inbound rules; SSM through the interface endpoints is the only way in.

Check from the AWS console or CLI that the host subnet's route table has **no** route to the internet gateway. In `nat` mode it should have `0.0.0.0/0 → nat-...`. In `aviatrix` mode it has no default route yet.

## 2. Aviatrix spoke gateway and DCF (`aviatrix` mode only)

```bash
cd terraform/aviatrix
cp terraform.tfvars.example terraform.tfvars
# set: controller_ip, password, aws_account_name, model_api_fqdns. Leave url_filtering=false and setup_phase=true for now.
terraform init
terraform apply
```

This reads the base stack's state from `../base/terraform.tfstate`. After apply, confirm in the AWS console that the host route table now has `0.0.0.0/0` pointing at the spoke gateway's ENI; the controller programs this when SNAT is enabled. In CoPilot, Security → Distributed Cloud Firewall → Rules should show `permit-model-api`, `permit-setup-pkg-sources`, `default-deny-all`.

Quick sanity from the host once it is up (step 3): `curl -sI https://download.docker.com | head -1` succeeds; `curl -s --max-time 8 https://example.com` fails and appears as a Deny in CoPilot Monitor.

## 3. Get the repo onto the host

The host has no inbound path and, in `aviatrix` mode, only package sources and the model API outbound. Two ways that work:

**Through SSM `send-command`** (no interactive paste; good for ~100 KB):

```bash
# [ws]
tar czf /tmp/sandbox.tgz host proxies agent scripts
B64=$(base64 < /tmp/sandbox.tgz | tr -d '\n')        # macOS: base64 -i /tmp/sandbox.tgz | tr -d '\n'
ID=$(terraform -chdir=terraform/base output -raw host_instance_id)
CMD=$(aws ssm send-command --instance-ids "$ID" --document-name AWS-RunShellScript \
  --parameters "commands=[\"echo '$B64' | base64 -d > /tmp/sandbox.tgz\",\"mkdir -p /root/agent-sandbox && tar xzf /tmp/sandbox.tgz -C /root/agent-sandbox && chmod +x /root/agent-sandbox/scripts/*.sh /root/agent-sandbox/host/*\"]" \
  --query Command.CommandId --output text)
sleep 5; aws ssm get-command-invocation --command-id "$CMD" --instance-id "$ID" --query '[Status,StandardErrorContent]' --output text
```

**Or** clone from GitHub on the host during the setup phase (`github.com` is in the setup-phase package list).

## 4. Bootstrap the host

```bash
# [host]
sudo -i
cd /root/agent-sandbox
```

Pick a Kata 3.x release (Go runtime + Firecracker) and its tarball digest from the GitHub release page, then:

```bash
KATA_VERSION=3.x.y KATA_SHA256=<digest> host/bootstrap.sh
```

The script: checks KVM and CPU mitigations, disables swap, points time sync at the Amazon Time Sync Service (169.254.169.123) and turns off snap refresh and Ubuntu update-check timers (otherwise the host's own NTP and snap traffic shows up as default-deny hits), loads `vhost_vsock`/`dm_thin_pool`, installs Docker CE and containerd, builds an LVM thin pool on the second EBS volume and configures the devmapper snapshotter, installs Kata (digest-verified), applies the pinned Firecracker settings with `host/kata-harden.py`, makes the guest kernel and image immutable, registers the `kata-fc` runtime, creates the internal `agents` network, and runs a guest-vs-host kernel smoke test.

Checks after it finishes:

```bash
docker run --rm --runtime kata-fc alpine:3.20 uname -r        # differs from `uname -r`
docker network inspect agents -f '{{.Internal}}'               # true
lsattr /opt/kata/share/kata-containers/vmlinux*.container      # 'i' flag present
grep . /sys/devices/system/cpu/vulnerabilities/* | grep -i vulnerable   # no output
```

## 5. Images, credential, proxies, target

```bash
# [host]
scripts/build-images.sh
```

It prints the base-image digests; paste them into the three Dockerfiles' `PIN_ME` placeholders and re-run so every image is pinned. Set `CLAUDE_CODE_VERSION` and the target image digest as needed. The script ends by confirming the agent CLI runs under `kata-fc`.

```bash
install -d -m 700 /etc/agent-sandbox
umask 077; printf '%s' '<model-api-credential>' > /etc/agent-sandbox/credential
scripts/start-egress-proxy.sh      # log shows: allowlist ... EMPTY (deny all)
scripts/start-target.sh            # target up at 172.30.0.20:3000 in its own microVM
```

Nothing else on the host holds a secret. The credential file is read by the launcher and written into the credential proxy's tmpfs at each launch.

## 6. Close the setup-phase holes (`aviatrix` mode)

```bash
# [ws]
terraform -chdir=terraform/aviatrix apply -var setup_phase=false
```

From the host, `curl -sI https://download.docker.com` now fails; the model API host still answers. The deny appears in CoPilot.

## 7. Optional: URL filtering

Once the host is built and a smoke run has shown the exact paths the agent uses (`grep -o 'POST [^ ]*' runs/<run>/credproxy.log | sort -u`):

```bash
# [ws] generate the CA; keep ca-key.pem off the host
scripts/dcf-ca.sh gen ./dcf-ca

# [host] trust the certificate only
sudo scripts/dcf-ca.sh install ca.pem

# [ws] switch the permit rule to URL matching with decryption
terraform -chdir=terraform/aviatrix apply \
  -var url_filtering=true \
  -var 'model_api_urls=["<host>/model/<id>/invoke","<host>/model/<id>/invoke-with-response-stream"]' \
  -var decryption_ca_cert_path=./dcf-ca/ca.pem -var decryption_ca_key_path=./dcf-ca/ca-key.pem
```

See [egress-modes.md](egress-modes.md) for the URL-entry rules (no colons) and the account-binding caveat. Then re-run the validation in [validation.md](validation.md); any DCF change means re-validating.

## 8. Run an agent

```bash
# [host]
scripts/launch.sh <run-name> agent/tasks/<task>.md [MAX_TURNS] [TIME_LIMIT]
# e.g.
scripts/launch.sh run-01 agent/tasks/smoke.md 30 1h
```

The launcher refuses to start unless the `kata-fc` runtime is registered, `/dev/kvm` exists, the egress proxy is running and the `agents` network is internal. It starts a fresh credential proxy bound to this run's IP, a companion container for the network namespace, then the agent microVM with a hard turn limit and a wall-clock kill. Transcript and proxy logs land in `runs/<run-name>/`. Everything except the egress proxy and target is removed at the end.

Provider and model are environment variables on `launch.sh`: `PROVIDER=bedrock|anthropic`, `MODEL_ID=<inference profile or model>`, `AWS_REGION`. Two fallback behaviours are disabled in the agent environment so a refused or denied model fails on the pinned model instead of switching to one your policy may not allow.

## Teardown

```bash
terraform -chdir=terraform/aviatrix destroy     # aviatrix mode
terraform -chdir=terraform/base destroy
```

Rotate the model-API credential afterwards.
