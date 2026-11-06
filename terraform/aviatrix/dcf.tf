# Distributed Cloud Firewall: deny-by-default egress for the host, everything logged.

locals {
  # Aviatrix built-in SmartGroups
  sg_anywhere        = "def000ad-0000-0000-0000-000000000000"
  sg_public_internet = "def000ad-0000-0000-0000-000000000001"

  upload_ca = var.url_filtering && var.decryption_ca_cert_path != "" && var.decryption_ca_key_path != ""
}

# DCF is a controller-wide feature (feature name "microseg"). Most controllers that will run this
# already have it on, so the stack does not manage it by default: destroying a resource that owns
# the feature would turn DCF off for every gateway on the controller. Set manage_dcf_feature = true
# only on a dedicated lab controller.
resource "aviatrix_config_feature" "dcf" {
  count        = var.manage_dcf_feature ? 1 : 0
  feature_name = "microseg"
  is_enabled   = true
}

# Private CA the gateway uses to re-sign model-API certificates when decrypting.
# Trust its certificate on the host (scripts/dcf-ca.sh install). Only one MITM CA is active per
# controller, so the selection below replaces whatever CA was active before.
resource "aviatrix_dcf_mitm_ca" "this" {
  count             = local.upload_ca ? 1 : 0
  name              = var.decryption_ca_name
  key               = file(var.decryption_ca_key_path)
  certificate_chain = file(var.decryption_ca_cert_path)
}

resource "aviatrix_dcf_mitm_ca_selection" "this" {
  count = local.upload_ca ? 1 : 0
  ca_id = aviatrix_dcf_mitm_ca.this[0].ca_id
}

# ------------------------------------------------------------------ SmartGroups
# Default: match by instance tag, so a rebuilt host is covered with no rule change. The base
# stack tags the host Role=agent-host. Set smartgroup_by_cidr=true to match the host subnet instead.
resource "aviatrix_smart_group" "agent_host" {
  name = "sg-agent-host"
  selector {
    dynamic "match_expressions" {
      for_each = var.smartgroup_by_cidr ? [] : [1]
      content {
        type   = "vm"
        region = local.base.region
        tags   = { Role = "agent-host" }
      }
    }
    dynamic "match_expressions" {
      for_each = var.smartgroup_by_cidr ? [1] : []
      content {
        cidr = local.base.host_subnet_cidr
      }
    }
  }
}

# ------------------------------------------------------------------ WebGroups
# SNI (domain) match: the permit rule decides on hostname only.
resource "aviatrix_web_group" "model_api_sni" {
  count = var.url_filtering ? 0 : 1
  name  = "wg-model-api"
  selector {
    dynamic "match_expressions" {
      for_each = var.model_api_fqdns
      content {
        snifilter = match_expressions.value
      }
    }
  }
}

# URL match: the permit rule decides on host + path. Needs TLS decryption on the rule.
resource "aviatrix_web_group" "model_api_url" {
  count = var.url_filtering ? 1 : 0
  name  = "wg-model-api-urls"
  selector {
    dynamic "match_expressions" {
      for_each = var.model_api_urls
      content {
        urlfilter = match_expressions.value
      }
    }
  }
}

resource "aviatrix_web_group" "pkg_sources" {
  name = "wg-setup-pkg-sources"
  selector {
    dynamic "match_expressions" {
      for_each = var.setup_pkg_fqdns
      content {
        snifilter = match_expressions.value
      }
    }
  }
}

# ------------------------------------------------------------------ Policy list
resource "aviatrix_distributed_firewalling_policy_list" "egress" {
  depends_on = [aviatrix_config_feature.dcf, aviatrix_dcf_mitm_ca_selection.this]

  # 10: host -> model API. SNI or URL match depending on url_filtering.
  policies {
    name     = "permit-model-api"
    action   = "PERMIT"
    priority = 10
    protocol = "TCP"
    logging  = true
    watch    = false
    # URL WebGroups only match decrypted HTTPS, so both of these are required for url_filtering.
    flow_app_requirement = var.url_filtering ? "TLS_REQUIRED" : null
    decrypt_policy       = var.url_filtering ? "DECRYPT_ALLOWED" : null
    src_smart_groups     = [aviatrix_smart_group.agent_host.uuid]
    dst_smart_groups     = [local.sg_public_internet]
    web_groups           = [var.url_filtering ? aviatrix_web_group.model_api_url[0].uuid : aviatrix_web_group.model_api_sni[0].uuid]
    port_ranges {
      lo = 443
    }
  }

  # 20: package sources. Present only while setup_phase = true.
  dynamic "policies" {
    for_each = var.setup_phase ? [1] : []
    content {
      name             = "permit-setup-pkg-sources"
      action           = "PERMIT"
      priority         = 20
      protocol         = "TCP"
      logging          = true
      watch            = false
      src_smart_groups = [aviatrix_smart_group.agent_host.uuid]
      dst_smart_groups = [local.sg_public_internet]
      web_groups       = [aviatrix_web_group.pkg_sources.uuid]
      port_ranges {
        lo = 443
      }
      port_ranges {
        lo = 80
      }
    }
  }

  # 900: default deny, logged. These are the entries you look for in CoPilot.
  policies {
    name             = "default-deny-all"
    action           = "DENY"
    priority         = 900
    protocol         = "ANY"
    logging          = true
    watch            = false
    src_smart_groups = [local.sg_anywhere]
    dst_smart_groups = [local.sg_anywhere]
  }
}
