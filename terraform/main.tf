# The Logic App rebuild of the legacy function app (preserved in the `legacy` tag): a weekly
# workflow with a system-assigned managed identity that publishes public IP feeds as one CSV per
# source into a private storage container. Sources:
#   Azure service tags (AzureCloud, AzureDevOps, WindowsVirtualDesktop,
#   MicrosoftDefenderForEndpoint by default, any tag works) via the ARM Service Tag Discovery API.
#   Microsoft 365 endpoint sets per service area (Common, Exchange, SharePoint, Skype) via the
#   endpoints.office.com web service (anonymous by design).
# Identity plumbing dogfoods the estate: a CUSTOM role definition carrying only
# Microsoft.Network/locations/serviceTags/read (role-assignment module), Storage Blob Data
# Contributor on the account, and the account firewall attached by the storage-account-network-rules
# module with a resource instance rule for the workflow, so the account stays deny-by-default while
# this one workflow may write. Blocks are ordered by dependency, top to bottom.
locals {
  location        = lookup(var.regions, var.loc, "uksouth")
  rg_name         = "rg-${var.short}-${var.loc}-${var.env}-ips-001"
  wf_name         = "logic-${var.short}-${var.loc}-${var.env}-ips-weekly-001"
  sa_name         = "st${var.short}${var.loc}ips${substr(sha1(data.azurerm_subscription.current.subscription_id), 0, 6)}"
  archive_sa_name = "st${var.short}${var.loc}iparc${substr(sha1(data.azurerm_subscription.current.subscription_id), 0, 6)}"
  container       = "ip-feeds"

  custom_role_name = "Service Tag Reader (${var.short}-${var.loc}-${var.env})"

  # The map keyed by feed name flattens to an array for the workflow parameter; the key becomes the
  # blob name (custom/<name>.csv).
  custom_feeds_list = [for k, v in var.custom_feeds : merge(v, { name = k })]
}

data "azurerm_subscription" "current" {}

data "azurerm_client_config" "current" {}

# The applier's egress public IP, allow-listed on both accounts so the human who deploys can also
# read the feeds (the workflow itself gets through on its resource instance rule, not an IP).
module "get_ip" {
  source  = "libre-devops/get-ip-address/external"
  version = "~> 4.0"
}

module "tags" {
  source  = "libre-devops/tags/azurerm"
  version = "~> 4.0"

  cost_centre     = var.cost_centre
  owner           = var.owner
  additional_tags = { Application = "get-azure-microsoft-ips" }
}

module "rg" {
  source  = "libre-devops/rg/azurerm"
  version = "~> 4.0"

  resource_groups = [{ name = local.rg_name, location = local.location, tags = module.tags.tags }]
}

# The feed destination. Inline network rules are off (manage_network_rules = false) so the
# storage-account-network-rules module below can own the firewall, including the resource instance
# rule that admits the workflow.
module "storage" {
  source  = "libre-devops/storage-account/azurerm"
  version = ">= 4.1.0, < 5.0.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  storage_accounts = merge(
    {
      (local.sa_name) = {
        manage_network_rules = false
        # No keys, enforced rather than aspirational: the workflow writes with its managed identity,
        # humans read via Entra RBAC, and nothing can fall back to a shared key or SAS.
        shared_access_key_enabled       = false
        default_to_oauth_authentication = true
        # Object replication requires versioning and change feed on the source.
        blob_properties = {
          versioning_enabled  = true
          change_feed_enabled = true
        }
      }
    },
    var.enable_archive_replication ? {
      (local.archive_sa_name) = {
        # The long-term copy: object replication delivers every feed here, and the lifecycle tiers
        # the dated history down (cool at 30 days, archive at 180) while latest stays hot.
        shared_access_key_enabled       = false
        default_to_oauth_authentication = true
        network_rules = {
          ip_rules = [module.get_ip.public_ip_address]
        }
        blob_properties = {
          versioning_enabled  = true
          change_feed_enabled = true
        }
        management_policy = {
          rules = [
            {
              name    = "tier-history-down"
              filters = { blob_types = ["blockBlob"], prefix_match = ["${local.container}/history/"] }
              actions = {
                base_blob = {
                  tier_to_cool_after_days_since_modification_greater_than    = 30
                  tier_to_archive_after_days_since_modification_greater_than = 180
                }
              }
            }
          ]
        }
      }
    } : {}
  )
}

resource "azurerm_storage_container" "feeds" {
  name                  = local.container
  storage_account_id    = module.storage.ids[local.sa_name]
  container_access_type = "private"
}

resource "azurerm_storage_container" "feeds_archive" {
  count = var.enable_archive_replication ? 1 : 0

  name                  = local.container
  storage_account_id    = module.storage.ids[local.archive_sa_name]
  container_access_type = "private"
}

# Blob object replication: every feed write lands in the archive account minutes later, giving the
# long-term copy a life of its own (and its own lifecycle tiering) without the workflow knowing.
resource "azurerm_storage_object_replication" "feeds" {
  count = var.enable_archive_replication ? 1 : 0

  source_storage_account_id      = module.storage.ids[local.sa_name]
  destination_storage_account_id = module.storage.ids[local.archive_sa_name]

  rules {
    source_container_name      = azurerm_storage_container.feeds.name
    destination_container_name = azurerm_storage_container.feeds_archive[0].name
    copy_blobs_created_after   = "Everything"
  }
}

module "logic_app_workflow" {
  source  = "libre-devops/logic-app-workflow/azurerm"
  version = "~> 4.0"

  resource_group_id = module.rg.ids[local.rg_name]
  location          = local.location
  tags              = module.tags.tags

  workflows = {
    (local.wf_name) = {
      title = "Recurrence - Weekly public IP feeds: one CSV per Azure service tag and M365 service area"

      parameters = {
        subscription_id = {
          type        = "String"
          value       = data.azurerm_subscription.current.subscription_id
          description = "Subscription the service tag discovery API is called against."
        }
        discovery_location = {
          type        = "String"
          value       = var.discovery_location
          description = "Region anchoring the discovery API call; the response is the full public cloud tag set."
        }
        storage_account_name = {
          type        = "String"
          value       = local.sa_name
          description = "Storage account the CSV feeds land in."
        }
        container_name = {
          type        = "String"
          value       = local.container
          description = "Blob container the CSV feeds land in."
        }
        service_tags = {
          type        = "Array"
          value       = jsonencode(var.service_tags)
          description = "Azure service tags that each get their own CSV of address prefixes."
        }
        m365_instance = {
          type        = "String"
          value       = var.m365_instance
          description = "Microsoft 365 endpoints instance (Worldwide, USGovDoD, USGovGCCHigh, China, Germany)."
        }
        m365_service_areas = {
          type        = "Array"
          value       = jsonencode(var.m365_service_areas)
          description = "Microsoft 365 service areas that each get their own CSV of endpoint sets."
        }
        github_ip_groups = {
          type        = "Array"
          value       = jsonencode(var.github_ip_groups)
          description = "GitHub meta IP groups that each get their own CSV (actions = hosted runners)."
        }
        custom_feeds = {
          type        = "Array"
          value       = jsonencode(local.custom_feeds_list)
          description = "Out-of-band feeds: url, collection, optional value_property/filter/headers per entry."
        }
      }
    }
  }
}

# The account firewall, attached AFTER the workflow exists so the resource instance rule can admit
# it by id: deny by default, Azure services bypass, and precisely this workflow trusted to write.
module "storage_network_rules" {
  source  = "libre-devops/storage-account-network-rules/azurerm"
  version = "~> 4.0"

  network_rules = {
    "feeds" = {
      storage_account_id = module.storage.ids[local.sa_name]
      ip_rules           = [module.get_ip.public_ip_address]
      private_link_access = [
        {
          endpoint_resource_id = module.logic_app_workflow.ids[local.wf_name]
        }
      ]
    }
  }
}

# Least-privilege identity plumbing via the role-assignment module: a custom role carrying ONLY the
# service tag discovery read (define-then-assign in one call), plus blob write on the one account.
module "role_assignment" {
  source  = "libre-devops/role-assignment/azurerm"
  version = "~> 4.1"

  role_definitions = {
    (local.custom_role_name) = {
      scope       = data.azurerm_subscription.current.id
      description = "Reads the Azure service tag discovery API and nothing else."
      permissions = {
        actions = ["Microsoft.Network/locations/serviceTags/read"]
      }
    }
  }

  role_assignments = {
    feed-reader-deployer = {
      # A user principal: skip_service_principal_aad_check must stay off here, since the provider
      # sends principalType ServicePrincipal whenever it is set (caught live).
      scope         = module.storage.ids[local.sa_name]
      principal_ids = [data.azurerm_client_config.current.object_id]
      role_names    = ["Storage Blob Data Reader"]
    }
    service-tag-reader = {
      scope                            = data.azurerm_subscription.current.id
      principal_ids                    = [module.logic_app_workflow.identities[local.wf_name].principal_id]
      role_definition_keys             = [local.custom_role_name]
      principal_type                   = "ServicePrincipal"
      skip_service_principal_aad_check = true
    }
    feed-writer = {
      scope                            = module.storage.ids[local.sa_name]
      principal_ids                    = [module.logic_app_workflow.identities[local.wf_name].principal_id]
      role_names                       = ["Storage Blob Data Contributor"]
      principal_type                   = "ServicePrincipal"
      skip_service_principal_aad_check = true
    }
  }
}

# ------------------------------------------------------------------------------------------------
# Workflow content (raw resources, per the standard). Chain: weekly recurrence -> fetch every
# service tag -> one CSV per requested tag -> fetch the M365 endpoint sets -> one CSV per service
# area. The nested loop bodies live in templates; Terraform only wires action names and parameters.
# ------------------------------------------------------------------------------------------------

resource "azurerm_logic_app_trigger_recurrence" "weekly" {
  name         = "Recurrence_-_Every_Monday_at_06_00_UTC"
  logic_app_id = module.logic_app_workflow.ids[local.wf_name]

  frequency = "Week"
  interval  = 1
  time_zone = "UTC"

  schedule {
    on_these_days    = ["Monday"]
    at_these_hours   = [6]
    at_these_minutes = [0]
  }
}

resource "azurerm_logic_app_action_custom" "run_date" {
  name         = "Compose_-_The_runs_date_stamp"
  logic_app_id = module.logic_app_workflow.ids[local.wf_name]

  body = jsonencode({
    description = "One date stamp for the whole run, so every dated history path in this run agrees even across midnight."
    type        = "Compose"
    inputs      = "@{formatDateTime(utcNow(), 'yyyy-MM-dd')}"
    runAfter    = {}
  })

  depends_on = [azurerm_logic_app_trigger_recurrence.weekly]
}

resource "azurerm_logic_app_action_custom" "get_service_tags" {
  name         = "HTTP_-_Get_every_Azure_service_tag"
  logic_app_id = module.logic_app_workflow.ids[local.wf_name]

  body = jsonencode({
    description = "The full public cloud service tag set from the ARM discovery API, with the workflow's managed identity (the custom Service Tag Reader role is exactly this call)."
    type        = "Http"
    inputs = {
      method         = "GET"
      uri            = "https://management.azure.com/subscriptions/@{parameters('subscription_id')}/providers/Microsoft.Network/locations/@{parameters('discovery_location')}/serviceTags"
      queries        = { "api-version" = "2024-05-01" }
      authentication = { type = "ManagedServiceIdentity", audience = "https://management.azure.com/" }
      retryPolicy    = { type = "fixed", count = 3, interval = "PT30S" }
    }
    runAfter = {
      (azurerm_logic_app_action_custom.run_date.name) = ["Succeeded"]
    }
  })
}

resource "azurerm_logic_app_action_custom" "publish_tag_csvs" {
  name         = "For_each_-_Publish_a_CSV_per_service_tag"
  logic_app_id = module.logic_app_workflow.ids[local.wf_name]

  body = templatefile("${path.module}/templates/publish-service-tag-csvs.json.tftpl", {
    self_name               = "For_each_-_Publish_a_CSV_per_service_tag"
    get_service_tags_action = azurerm_logic_app_action_custom.get_service_tags.name
    run_date_action         = azurerm_logic_app_action_custom.run_date.name
  })
}

resource "azurerm_logic_app_action_custom" "get_m365_endpoints" {
  name         = "HTTP_-_Get_the_M365_endpoint_sets"
  logic_app_id = module.logic_app_workflow.ids[local.wf_name]

  body = jsonencode({
    description = "The Microsoft 365 endpoint sets from the endpoints.office.com web service (anonymous by design; the clientrequestid is a per-run GUID as the service requires)."
    type        = "Http"
    inputs = {
      method      = "GET"
      uri         = "https://endpoints.office.com/endpoints/@{parameters('m365_instance')}"
      queries     = { clientrequestid = "@{guid()}" }
      retryPolicy = { type = "fixed", count = 3, interval = "PT30S" }
    }
    runAfter = {
      (azurerm_logic_app_action_custom.publish_tag_csvs.name) = ["Succeeded"]
    }
  })
}

resource "azurerm_logic_app_action_custom" "publish_m365_csvs" {
  name         = "For_each_-_Publish_a_CSV_per_M365_service_area"
  logic_app_id = module.logic_app_workflow.ids[local.wf_name]

  body = templatefile("${path.module}/templates/publish-m365-area-csvs.json.tftpl", {
    self_name            = "For_each_-_Publish_a_CSV_per_M365_service_area"
    get_endpoints_action = azurerm_logic_app_action_custom.get_m365_endpoints.name
    run_date_action      = azurerm_logic_app_action_custom.run_date.name
  })
}

resource "azurerm_logic_app_action_custom" "get_github_meta" {
  name         = "HTTP_-_Get_the_GitHub_ip_ranges"
  logic_app_id = module.logic_app_workflow.ids[local.wf_name]

  body = jsonencode({
    description = "GitHub's published IP ranges from api.github.com/meta (anonymous; the User-Agent header is mandatory or GitHub returns 403). actions is the hosted runner set and changes with no fixed cadence."
    type        = "Http"
    inputs = {
      method = "GET"
      uri    = "https://api.github.com/meta"
      headers = {
        "User-Agent" = "libre-devops-ip-feeds"
        Accept       = "application/vnd.github+json"
      }
      retryPolicy = { type = "fixed", count = 3, interval = "PT30S" }
    }
    runAfter = {
      (azurerm_logic_app_action_custom.publish_m365_csvs.name) = ["Succeeded"]
    }
  })
}

resource "azurerm_logic_app_action_custom" "publish_github_csvs" {
  name         = "For_each_-_Publish_a_CSV_per_GitHub_ip_group"
  logic_app_id = module.logic_app_workflow.ids[local.wf_name]

  body = templatefile("${path.module}/templates/publish-github-ip-csvs.json.tftpl", {
    self_name       = "For_each_-_Publish_a_CSV_per_GitHub_ip_group"
    get_meta_action = azurerm_logic_app_action_custom.get_github_meta.name
    run_date_action = azurerm_logic_app_action_custom.run_date.name
  })
}

resource "azurerm_logic_app_action_custom" "publish_custom_feed_csvs" {
  name         = "For_each_-_Publish_a_CSV_per_custom_feed"
  logic_app_id = module.logic_app_workflow.ids[local.wf_name]

  body = templatefile("${path.module}/templates/publish-custom-feed-csvs.json.tftpl", {
    self_name        = "For_each_-_Publish_a_CSV_per_custom_feed"
    run_after_action = azurerm_logic_app_action_custom.publish_github_csvs.name
    run_date_action  = azurerm_logic_app_action_custom.run_date.name
  })
}
