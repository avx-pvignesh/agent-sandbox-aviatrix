terraform {
  required_version = ">= 1.6"
  required_providers {
    aviatrix = {
      source  = "AviatrixSystems/aviatrix"
      version = ">= 9.0.0" # aviatrix_config_feature / aviatrix_dcf_mitm_ca; match your controller release
    }
  }
}

provider "aviatrix" {
  controller_ip           = var.controller_ip
  username                = var.username
  password                = var.password
  skip_version_validation = true
}
