variable "region" {
  type    = string
  default = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile for the dedicated sandbox account. Leave null to use the default credential chain."
  type        = string
  default     = null
}

variable "name_prefix" {
  type    = string
  default = "agent-sandbox"
}

# ---- Network ----
variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}
variable "host_subnet_cidr" {
  type    = string
  default = "10.20.1.0/24"
}
variable "public_subnet_cidr" {
  description = "Public subnet for the Aviatrix spoke gateway."
  type        = string
  default     = "10.20.0.0/26"
}
variable "public_ha_subnet_cidr" {
  description = "Second public subnet for the spoke gateway HA peer ."
  type        = string
  default     = "10.20.0.64/26"
}

# ---- Host ----
variable "instance_type" {
  description = "Must expose KVM: a nested-virtualisation family (c8i/m8i/r8i) or a *.metal type."
  type        = string
  default     = "m8i.4xlarge"
}
variable "root_volume_gb" {
  type    = number
  default = 100
}
variable "thinpool_volume_gb" {
  description = "Dedicated EBS volume for the containerd devmapper thin pool."
  type        = number
  default     = 300
}
variable "ami_name_filter" {
  description = "Ubuntu 24.04 by default. The bootstrap script targets Ubuntu."
  type        = string
  default     = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
}

variable "tags" {
  type    = map(string)
  default = {}
}
