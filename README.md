# agent-sandbox-aviatrix

Reference implementation of Anthropic's [agent containment / sandboxing guidance]() on AWS, with an optional second egress control: an Aviatrix spoke gateway running Distributed Cloud Firewall (DCF) at the VPC edge.

Each agent runs in its own Firecracker microVM (Kata Containers) on an internal Docker network with no route out. A credential proxy holds the model-API key and forwards only model calls; an egress proxy denies everything else. In `aviatrix` mode the host's entire egress is also forced through a spoke gateway that permits only the model API and logs every denied attempt. With URL filtering on, the gateway decrypts TLS and permits only the exact model endpoint path.

![architecture](docs/img/two-locks.png)

## What you get

| Mode | Egress path | Egress control | Purpose |
|---|---|---|---|
| `nat` | NAT gateway | In-host credential proxy + egress proxy | The baseline design. One lock. |
| `aviatrix` | Aviatrix spoke gateway | In-host proxies **and** DCF default-deny at the VPC edge, logged in CoPilot | Two independent locks. A bug or bypass in a proxy is still contained. |

Both modes deploy the same host, microVM runtime, proxies, sample agent and vulnerable target. The only difference is the Terraform `egress_mode` and whether the `terraform/aviatrix` stack is applied.

## Layout

```
terraform/base/       VPC, private host subnet, SSM endpoints, IAM, EC2 host. egress_mode = nat | aviatrix
terraform/aviatrix/   Spoke gateway + DCF policy (SNI or URL filtering). Apply after base, aviatrix mode only.
host/                 bootstrap.sh: Docker + containerd (devmapper) + Kata + Firecracker, hardened
proxies/              credproxy (holds the key, path-restricted) and egressproxy (allowlist, empty by default)
agent/                Sample agent image (Claude Code) and task files, incl. the supervised escape tests
scripts/              Build images, start proxies/target, launch an agent run, validation and DCF demo scripts
docs/                 deploy.md, validation.md, egress-modes.md, architecture.md
```

## Quick start

```bash
# 1. Network + host
cd terraform/base
cp terraform.tfvars.example terraform.tfvars   # set egress_mode, profile, instance type
terraform init && terraform apply

# 2. (aviatrix mode only) spoke gateway + DCF, setup-phase policy
cd ../aviatrix
cp terraform.tfvars.example terraform.tfvars   # controller, account name, model API host
terraform init && terraform apply

# 3. On the host (SSM), build the runtime and images
$(terraform -chdir=../base output -raw ssm_connect)
sudo KATA_VERSION=3.x.y KATA_SHA256=<digest> host/bootstrap.sh
scripts/build-images.sh
scripts/start-egress-proxy.sh && scripts/start-target.sh

# 4. (aviatrix mode) close the setup-phase holes, then validate and run
terraform -chdir=terraform/aviatrix apply -var setup_phase=false
scripts/verify-isolation.sh probe        # see docs/validation.md
scripts/launch.sh run-01 agent/tasks/smoke.md 30 1h
```

Full steps, including copying files to a host that has no inbound path, are in [docs/deploy.md](docs/deploy.md).

## Requirements

- An AWS account you can dedicate to this. The host holds a model-API credential and runs adversarial tests; don't share it with other workloads.
- An EC2 type that exposes KVM: a nested-virtualisation family (`c8i`, `m8i`, `r8i`) or any `*.metal`.
- A model-API credential scoped only to agent runs (Bedrock API key, Anthropic API key, or Vertex). Pick one provider.
- `aviatrix` mode: an Aviatrix Controller/CoPilot (7.1.1710+ for a private decryption CA; 8.1+ if you need path wildcards in URL WebGroups) with an access account for the AWS account above.
- Terraform >= 1.6, AWS CLI with Session Manager plugin.

## Documents

- [docs/architecture.md](docs/architecture.md): components, trust boundaries, why two locks
- [docs/deploy.md](docs/deploy.md): end-to-end deployment, both modes
- [docs/egress-modes.md](docs/egress-modes.md): nat vs aviatrix, SNI vs URL filtering, the account-binding caveat
- [docs/validation.md](docs/validation.md): isolation checks, supervised escape test, and the "proxy forwards, gateway denies" demo

## Notes

- The model-API host is never added to the agents' egress allowlist. Agents reach the model only through the credential proxy.
- The credential never enters an agent container. It is written into the credential proxy's tmpfs per launch.
- Treat the host as disposable. Rebuild rather than reuse after a failed escape test.
