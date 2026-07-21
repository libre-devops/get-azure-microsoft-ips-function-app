<div align="center">
  <a href="https://libredevops.org">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://libredevops.org/assets/libre-devops-white.png">
      <img alt="Libre DevOps" src="https://libredevops.org/assets/libre-devops-black.png" width="300">
    </picture>
  </a>
</div>

# Get Azure and Microsoft public IPs

A weekly Logic App that publishes Microsoft's public IP feeds as one CSV per source into a private
storage container: Azure service tags (Azure itself, Azure DevOps, Azure Virtual Desktop, Defender
for Endpoint by default, any tag works) and the Microsoft 365 endpoint sets per service area.

[![CI](https://github.com/libre-devops/get-azure-microsoft-ips/actions/workflows/ci.yml/badge.svg)](https://github.com/libre-devops/get-azure-microsoft-ips/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/libre-devops/get-azure-microsoft-ips)](./LICENSE)

---

## Overview

This repo used to be a Python Azure Function App (a fork of
[groovy-sky/azure-office-ip](https://github.com/groovy-sky/azure-office-ip); that whole world is
preserved in the [`legacy`](../../tree/legacy) tag). It is now a single Terraform stack, built from
the Libre DevOps registry modules, deploying one consumption Logic App workflow with a
system-assigned managed identity and no secrets anywhere:

- **Azure service tags** come from the ARM Service Tag Discovery API, called with the workflow's
  identity. Every tag in `var.service_tags` gets its own CSV of address prefixes (IPv4 and IPv6) at
  `azure-service-tags/<tag>.csv`. Any tag the discovery API knows is fair game; the defaults cover
  `AzureCloud`, `AzureDevOps`, `WindowsVirtualDesktop`, and `MicrosoftDefenderForEndpoint`.
- **Microsoft 365 endpoint sets** come from the endpoints.office.com web service (anonymous by
  design). Every service area in `var.m365_service_areas` gets its own CSV at `m365/<area>.csv`,
  one row per endpoint set with the ips and urls collections semicolon-joined so Microsoft's
  grouping (and the ports and required flags) survive the flattening.
- **GitHub IP ranges** come from `api.github.com/meta` (anonymous, mandatory User-Agent). Every
  group in `var.github_ip_groups` gets its own CSV at `github/<group>.csv`; `actions` (the hosted
  runner set, roughly seven thousand CIDRs) is the default, and `hooks`, `web`, `api`, `git`,
  `packages`, `pages`, `codespaces`, `copilot`, and friends all work.
- **Any other public JSON feed** via `var.custom_feeds`, the out-of-band extension point: each
  entry names a url, the payload property holding the array, and (for object arrays) which field
  is the CIDR plus an optional filter. Every entry lands at `custom/<key>.csv` and `.json`.

Every feed is written twice: `<name>.csv` (flattened, one value per row) and `<name>.json`
(source-shaped, full fidelity; the M365 JSON keeps the proper ips, urls, and port arrays the CSV
has to semicolon-join). Azure **Table storage is deliberately not offered**: tables have no bulk
write, so a weekly run would mean tens of thousands of sequential entity inserts (AzureCloud alone
is ~15,000 prefixes) for a row-query capability IP-feed consumers rarely want; if row-level
querying ever matters, ingest the blobs into Log Analytics or ADX instead.

The workflow runs every Monday at 06:00 UTC and overwrites last week's feeds. The cadence matches
the sources: Azure service tags publish weekly, the M365 endpoint sets version monthly (start of
month, occasional out-of-band changes), and GitHub's ranges change with no fixed cadence, so a
weekly floor keeps everything at most a few days stale. CSVs land in blob
storage; an Azure Table variant would slot in beside the blob writes if row-level querying ever
earns its keep.

**No storage keys, no SAS, anywhere, enforced**: every Graph-of-storage byte moves under Entra ID.
The workflow authenticates its blob writes with its managed identity (`ManagedServiceIdentity`
authentication on the HTTP actions; there is no connection string or SAS token in any action, and
nothing to rotate or leak), and the account itself has `shared_access_key_enabled = false`, so
key-based access is impossible rather than merely unused. Humans read the feeds through RBAC (the
deployer gets Storage Blob Data Reader): `az storage blob list --auth-mode login ...`.

The identity plumbing dogfoods the estate deliberately:

- a **custom role definition** carrying only `Microsoft.Network/locations/serviceTags/read`,
  defined and assigned in one call by the `role-assignment` module (no Reader over-grant);
- **Storage Blob Data Contributor** scoped to the one account;
- the account firewall attached by the `storage-account-network-rules` module: deny by default,
  AzureServices bypass, and a **resource instance rule** admitting exactly this workflow, so the
  account never opens to the world for the sake of the writer.

## Deploy

```bash
cd terraform
az login
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform init
terraform apply
```

The stack includes the role definition and role assignments, so the applier needs to be able to
write those at subscription scope (Owner). State is local and gitignored; this is a
personal-tenant stack, not a shared pipeline.

Run it immediately instead of waiting for Monday with the command in the `run_now_command` output,
then browse the container from the `container_url` output.

## Tuning

- `service_tags`: add any service tag, including regional variants (`AzureCloud.uksouth`,
  `Storage.UKSouth`, `Sql`, `AzureFrontDoor.Backend`); each becomes its own CSV and JSON. Matching
  is case-insensitive on purpose: Microsoft's regional casing is inconsistent across families
  (`AzureCloud.uksouth` but `Storage.UKSouth`), and exact matching would silently miss. A tag the
  API does not know produces an empty file rather than a failed run.
- A correctness note from validating the feeds: the well-known `13.107.6.0/24` and `13.107.9.0/24`
  Azure DevOps blocks are NOT in the `AzureDevOps` service tag; dev.azure.com rides the Microsoft
  365 edge, and those ranges arrive through the M365 `Common` and `Exchange` feeds this stack also
  publishes. Take the tag plus the M365 feeds together for complete DevOps coverage.
- `m365_service_areas`: any of `Common`, `Exchange`, `SharePoint`, `Skype`.
- `m365_instance`: `Worldwide` by default; the sovereign instances work too.
- `github_ip_groups`: any key of `api.github.com/meta` that holds CIDR ranges; an empty list
  disables the GitHub source.
- `custom_feeds`: the extension point, no code required. Ready-made entries, shapes verified
  against the live feeds:

  ```hcl
  custom_feeds = {
    # AWS, everything (10,000+ prefixes) and a per-service slice
    aws-all = {
      url            = "https://ip-ranges.amazonaws.com/ip-ranges.json"
      collection     = "prefixes"
      value_property = "ip_prefix"
    }
    aws-ec2 = {
      url             = "https://ip-ranges.amazonaws.com/ip-ranges.json"
      collection      = "prefixes"
      value_property  = "ip_prefix"
      filter_property = "service"
      filter_equals   = "EC2"
    }

    # Zscaler recommended hub ranges (swap zscaler.net for your cloud: zscalertwo.net, zscloud.net ...)
    zscaler-hub = {
      url        = "https://config.zscaler.com/api/zscaler.net/hubs/cidr/json/recommended"
      collection = "hubPrefixes"
    }
  }
  ```
