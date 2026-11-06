terraform {
  required_version = ">= 1.6"
  required_providers {
    aviatrix = {
      source  = "AviatrixSystems/aviatrix"
      version = ">= 3.2.0"
    }
  }
}

provider "aviatrix" {
  controller_ip           = var.controller_ip
  username                = var.username
  password                = var.password
  skip_version_validation = true
}
