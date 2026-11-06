data "terraform_remote_state" "base" {
  backend = "local"
  config = {
    path = var.base_state_path
  }
}

locals {
  base = data.terraform_remote_state.base.outputs
}

# ------------------------------------------------------------------ Spoke gateway
# single_ip_snat = true gives the VPC local egress through the gateway's EIP, and the
# controller programs 0.0.0.0/0 -> spoke gateway into the VPC's private route tables.
# That is what forces the host's traffic through DCF.
resource "aviatrix_spoke_gateway" "this" {
  cloud_type   = 1
  account_name = var.aws_account_name
  gw_name      = var.gw_name
  vpc_id       = local.base.vpc_id
  vpc_reg      = local.base.region
  gw_size      = var.gw_size
  subnet       = local.base.public_subnet_cidr

  ha_subnet  = local.base.public_ha_subnet_cidr
  ha_gw_size = var.gw_size

  single_ip_snat = true
}

# Optional transit attachment. Not needed for local egress + DCF.
resource "aviatrix_spoke_transit_attachment" "this" {
  count           = var.transit_gw_name == "" ? 0 : 1
  spoke_gw_name   = aviatrix_spoke_gateway.this.gw_name
  transit_gw_name = var.transit_gw_name
}

output "spoke_gw_name" {
  value = aviatrix_spoke_gateway.this.gw_name
}
output "spoke_gw_private_ip" {
  value = aviatrix_spoke_gateway.this.private_ip
}
output "spoke_gw_eip" {
  value = aviatrix_spoke_gateway.this.eip
}
