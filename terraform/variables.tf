variable "custom_feeds" {
  description = <<-EOT
    The out-of-band extension point: any public JSON feed of IP ranges becomes its own CSV at
    custom/<key>.csv without touching the workflow. Each feed needs the url and the collection
    (the payload property holding the array). When the array holds objects, value_property picks
    the CIDR field and filter_property/filter_equals optionally narrow the rows (AWS by service,
    for example); when it holds plain strings (Zscaler), leave value_property empty. headers adds
    request headers for feeds that demand them. See the README for ready-made AWS and Zscaler
    entries.
  EOT
  type = map(object({
    url             = string
    collection      = string
    value_property  = optional(string, "")
    filter_property = optional(string, "")
    filter_equals   = optional(string, "")
    headers         = optional(map(string), {})
  }))
  default = {}

  validation {
    condition     = alltrue([for f in values(var.custom_feeds) : can(regex("^https://", f.url))])
    error_message = "Every custom feed url must be https."
  }

  validation {
    condition     = alltrue([for f in values(var.custom_feeds) : f.filter_property == "" || f.value_property != ""])
    error_message = "A filter only makes sense on object feeds: set value_property when setting filter_property."
  }
}

variable "discovery_location" {
  description = "Azure region used by the service tag discovery API call (the API returns the full public cloud tag set regardless; the location only anchors the request)."
  type        = string
  default     = "uksouth"
}

variable "env" {
  description = "Environment code used in resource names."
  type        = string
  default     = "dev"
}

variable "github_ip_groups" {
  description = "GitHub IP range groups from api.github.com/meta that each get their own CSV: actions (hosted runners), hooks, web, api, git, packages, pages, codespaces, copilot, and friends. Empty list disables the GitHub source."
  type        = list(string)
  default     = ["actions"]
}

variable "loc" {
  description = "Outfix: short Azure region code used in resource names."
  type        = string
  default     = "uks"
}

variable "m365_instance" {
  description = "Microsoft 365 endpoints instance to query: Worldwide, USGovDoD, USGovGCCHigh, China, or Germany."
  type        = string
  default     = "Worldwide"
}

variable "m365_service_areas" {
  description = "Microsoft 365 service areas that each get their own CSV: any of Common, Exchange, SharePoint, Skype."
  type        = list(string)
  default     = ["Common", "Exchange", "SharePoint", "Skype"]
}

variable "regions" {
  description = "Map of short region codes to Azure region slugs."
  type        = map(string)
  default = {
    uks = "uksouth"
    ukw = "ukwest"
    eus = "eastus"
    euw = "westeurope"
  }
}

variable "service_tags" {
  description = "Azure service tags that each get their own CSV of address prefixes. Any tag the discovery API knows works; the defaults cover Azure itself, Azure DevOps, Azure Virtual Desktop, and Defender for Endpoint."
  type        = list(string)
  default     = ["AzureCloud", "AzureDevOps", "WindowsVirtualDesktop", "MicrosoftDefenderForEndpoint"]
}

variable "short" {
  description = "Infix: short product code used in resource names."
  type        = string
  default     = "ldo"
}
