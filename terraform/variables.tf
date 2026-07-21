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
