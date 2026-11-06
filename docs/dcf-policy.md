# DCF policy

The host has one path out: the Aviatrix spoke gateway. The base stack creates two public subnets for the spoke gateway and its HA peer and leaves the host route table without a default route. Applying `terraform/aviatrix` then creates the spoke gateway with `single_ip_snat = true`; the controller programs `0.0.0.0/0` to the gateway in the host route table, and DCF decides what leaves.

The policy, in priority order:

| Pri | Name | Match | Action | When |
|---|---|---|---|---|
| 10 | `permit-model-api` | host → Public Internet, WebGroup `wg-model-api` (SNI) or `wg-model-api-urls` (URL) | Permit, logged | always |
| 20 | `permit-setup-pkg-sources` | host → package/registry hosts, 80/443 | Permit, logged | `setup_phase = true` only |
| 900 | `default-deny-all` | anything → anything | Deny, logged | always |

Set `setup_phase = false` and re-apply before running agents. Rule 20 disappears and the host can reach nothing but the model API.

The source SmartGroup (`sg-agent-host`) matches instances tagged `Role=agent-host`, which the base stack sets on the host. A rebuilt host is covered with no rule change. Set `smartgroup_by_cidr = true` to match the host subnet instead. Put any test target in its own SmartGroup, permit it only from the host's group, and deny its outbound traffic; the repo defines the host group only.

### SNI filtering (`url_filtering = false`)

The permit rule matches the TLS SNI, i.e. the hostname. No decryption. This contains the host to the model-API domain and is enough to show a denied egress attempt in CoPilot.

Its limit: on a multi-tenant endpoint like Bedrock the hostname is the same for every customer. What identifies the account and model is in the URL path, which SNI filtering cannot see. An agent with its own stolen cloud credential could call the same host with a different profile in the path and exfiltrate to another account.

### URL filtering (`url_filtering = true`)

The permit rule uses a URL-type WebGroup and has TLS decryption enabled. The gateway terminates TLS with a private CA, inspects host + path, permits only the listed endpoints, and re-encrypts. Everything else on the model domain falls to rule 900 and is logged with the full URL.

Requirements:

1. A private CA. `scripts/dcf-ca.sh gen ./dcf-ca` produces `ca.pem` and `ca-key.pem`. Either set `decryption_ca_cert_path` / `decryption_ca_key_path` in the aviatrix stack, or upload both in CoPilot (Security → Distributed Cloud Firewall → Settings → Decryption CA Certificate). Set enforcement to Strict.
2. Trust the CA certificate on the host: `sudo scripts/dcf-ca.sh install ca.pem`. The launcher mounts the host trust bundle into the credential proxy automatically. The agent microVM does not need it; it only speaks plain HTTP to the proxy.
3. URL entries. No scheme, and the controller rejects entries containing `:`. Model identifiers with a colon (`...-v1:0`, ARNs) cannot be entered literally. Use an identifier without colons (geo/global inference profile IDs such as `global.anthropic.claude-sonnet-5-5` work), or on controller 8.1+ wildcard the colon-bearing segment, e.g. `<host>/model/*application-inference-profile/<id>/invoke-with-response-stream`.
4. The exact paths your agent sends. Run one agent batch with SNI filtering and read them from the credential proxy log: `grep -o 'POST [^ ]*' runs/<run>/credproxy.log | sort -u`. Put each one in `model_api_urls`.

### Account binding

Pinning the URL to *your* account needs a model identifier that contains an account-scoped component, i.e. an application inference profile (`arn:aws:bedrock:<region>:<account>:application-inference-profile/<id>`). Creating one requires `bedrock:CreateInferenceProfile`.

If you can only use a shared system profile, URL filtering still denies every other model and path, but it cannot tell your account from another using the same profile ID. State that limitation; it is a strong interim control and the application profile closes the gap.

Concretely: the URL rule below pins the model path, so other models and other paths are denied. Pinning *your account* needs the application inference profile. A colon-bearing ARN cannot be entered literally; wildcard the segment (controller 8.1+) and keep the profile ID, which is unique to your account. With a shared profile (`global.*`) the gateway cannot distinguish your account from another account calling the same profile.

### Reading a block correctly

A DCF deny on a decrypted flow returns an HTTP 403 with an empty body and no provider headers (no `x-amzn-RequestId`). The provider's own 403 for a missing or rejected credential carries a JSON/XML body and provider headers. Check the body and headers, not just the status code, before concluding the gateway blocked something. CoPilot's Monitor view is the authoritative record either way.
