# ---- Controller ----
variable "controller_ip" {
  type = string
}
variable "username" {
  type    = string
  default = "admin"
}
variable "password" {
  type      = string
  sensitive = true
}
variable "aws_account_name" {
  description = "Aviatrix access-account name registered for the sandbox AWS account."
  type        = string
}

# ---- Where the base stack's state lives ----
variable "base_state_path" {
  description = "Path to the base stack's local state file. Set when not using the default layout."
  type        = string
  default     = "../base/terraform.tfstate"
}

# ---- Gateway ----
variable "gw_name" {
  type    = string
  default = "spoke-agent-sandbox"
}
variable "gw_size" {
  type    = string
  default = "t3.medium"
}
variable "transit_gw_name" {
  description = "Optional existing transit gateway to attach the spoke to. Empty = standalone spoke with local egress."
  type        = string
  default     = ""
}

# ---- Egress policy ----
variable "model_api_fqdns" {
  description = "Model-API host(s). Pick one provider. Used for SNI filtering, and as the host part of URL entries."
  type        = list(string)
  default     = ["bedrock-runtime.us-east-1.amazonaws.com"]
}

variable "url_filtering" {
  description = <<-EOT
    false: the permit rule matches the model-API hostname (SNI). No decryption.
    true : the permit rule matches exact URLs (host + path) and TLS decryption is enabled on it,
           so only the listed model endpoint paths are allowed and every other path on the model
           domain is denied. Requires a decryption CA (see decryption_ca_*) trusted by the host.
  EOT
  type        = bool
  default     = false
}

variable "model_api_urls" {
  description = <<-EOT
    Exact URL entries (no scheme) for url_filtering = true. URL WebGroup entries cannot contain ':',
    so use a model identifier without colons (e.g. a global/geo inference profile ID), or wildcard the
    colon-bearing segment of an ARN, e.g. "<host>/model/*application-inference-profile/<id>/invoke".
  EOT
  type        = list(string)
  default = [
    "bedrock-runtime.us-east-1.amazonaws.com/model/global.anthropic.claude-sonnet-5-5/invoke",
    "bedrock-runtime.us-east-1.amazonaws.com/model/global.anthropic.claude-sonnet-5-5/invoke-with-response-stream",
  ]
}

variable "decryption_ca_cert_path" {
  description = "PEM certificate of the private CA the gateway signs with (url_filtering). Empty = upload in CoPilot instead."
  type        = string
  default     = ""
}
variable "decryption_ca_key_path" {
  description = "PEM private key for decryption_ca_cert_path."
  type        = string
  default     = ""
}

variable "setup_pkg_fqdns" {
  description = "Package and build sources permitted only while setup_phase = true."
  type        = list(string)
  default = [
    "archive.ubuntu.com",
    "security.ubuntu.com",
    "download.docker.com",
    "github.com",
    "objects.githubusercontent.com",
    "release-assets.githubusercontent.com",
    "registry-1.docker.io",
    "auth.docker.io",
    "production.cloudflare.docker.com",
    "registry.npmjs.org",
    "deb.nodesource.com",
    "pypi.org",
    "files.pythonhosted.org",
  ]
}

variable "setup_phase" {
  description = "true while building the host and images (package sources permitted). false for agent runs: model API only."
  type        = bool
  default     = true
}
