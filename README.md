# Cloud Sizing Scripts

This repository contains scripts for cloud resource discovery. They help Commvault representatives gather information about cloud resources that may need protection and estimate the cost of protecting them.

## Quick start

Clone the repo and run the script for your cloud from `src/` — no build step required:

```powershell
git clone <repo-url>
cd dy-cloud-sizing-scripts/src

# install the prerequisites for your cloud first (see docs/), then:
./CVAWSCloudSizingScript.ps1    -DefaultProfile -Regions "us-east-1"
./CVAzureCloudSizingScript.ps1  -Types VM,Storage
./CVGoogleCloudSizingScript.ps1 -Types VM,Storage
```

Each script loads the shared console/diagnostics layer from `common/` automatically. Add `-NonInteractive` for plain, pipe-safe output (CI / automation). Setup and full parameter details are in the per-cloud docs below.

## Two sizing passes: Data Protection + Cloud Rewind

Every AWS/Azure/GCP run performs **two independent passes by default**:

1. **Data Protection sizing** — the per-service resource inventory (VMs, storage, databases, …), protection columns, and the cyber-resilience posture report.
2. **Cloud Rewind sizing** — counts the resources Commvault **Cloud Rewind** (Appranix) bills for. It runs its own lightweight sweep (Azure `Get-AzResource`, AWS Resource Groups Tagging API, GCP Cloud Asset Inventory), classifies each resource billable / non-billable and Data / Config, and writes:
   - `<cloud>_cloudrewind_<ts>.csv` — one row per **billable** resource: account/region/resource group scope, resource name and native type, why it is billable, and topology. The two widest columns (`ResourceId`, then the flattened `Tags` blob) are last so they don't crowd out the rest in a spreadsheet; a `-Tags` filter adds one narrow `Tag_<key>` column per filtered key just before `Tags`.
   - `<cloud>_cloudrewind_summary_<ts>.csv` — per-account `BillableDataResources` / `BillableConfigResources` / `NonBillableDataResources` / `NonBillableConfigResources` plus totals. Every number is a **count of resources, not a size** — hence the `...Resources` suffix, since these sit alongside per-service CSVs full of `SizeGB`/`UsedTiB` columns. `TotalBillableResources` is the figure that maps to Cloud Rewind licensing; `TotalClassifiedResources` counts only resources matching the taxonomy, so it is *not* the account's total resource count.

### Choosing passes and scope

```powershell
./CVAzureCloudSizingScript.ps1                                  # both passes (default)
./CVAzureCloudSizingScript.ps1 -SkipDataProtection             # Cloud Rewind only
./CVAzureCloudSizingScript.ps1 -SkipCloudRewind                # Data Protection only

# Scope the run (filters both passes where supported)
./CVAzureCloudSizingScript.ps1 -ResourceGroups rg1,rg2 -Tags Environment=Production
./CVAWSCloudSizingScript.ps1   -DefaultProfile -Tags Environment=Production
./CVGoogleCloudSizingScript.ps1 -Projects my-proj -Labels env=production
```

Filters are `Key=Value` (union: a resource matches if it is in **any** listed resource group **or** carries **any** listed tag/label). `-ResourceGroups`/`-Tags` apply on Azure & AWS; `-Labels` on GCP.

**Accuracy note:** the **Azure** billable taxonomy is authoritative (Cloud Rewind support article 89349). The **AWS and GCP** taxonomies are **derived** by applying the same pattern to the public supported-resource lists — verify the billable arrays in `src/common/CVSizing.CloudRewind.{AWS,GCP}.ps1` against your Cloud Rewind billing before relying on those counts. Attach/exclusion refinements (unattached volumes/IPs) and per-resource topology columns are AWS/GCP follow-ups.

**Extra prerequisites for the Cloud Rewind pass:** AWS needs `AWS.Tools.ResourceGroupsTaggingAPI`; Azure needs `Az.Resources` + `Az.Network`; GCP needs the **Cloud Asset API** (`cloudasset.googleapis.com`) enabled. Add `-SkipCloudRewind` to run without them.

## Repository layout

```
src/                 All sizing scripts (run these directly)
  CVAWSCloudSizingScript.ps1
  CVAzureCloudSizingScript.ps1
  CVGoogleCloudSizingScript.ps1
  CVM365SizingScript.ps1
  FetchAllAccountCreds.ps1          AWS multi-account SSO helper
  common/CVSizing.Console.ps1       Shared console/diagnostics layer (loaded by the scripts)
  OCI/                              Oracle Cloud sizing (Python subproject)
docs/                Per-cloud setup & run instructions (AWS.md, Azure.md, GoogleCloud.md)
tests/               Dependency-free test suite for the shared console layer
tools/               Show-CVConsoleDemo.ps1 - visual demo of the console layer
k8s/                 Dockerfiles, entrypoints and Job manifests for containerized runs
Output/              Run output (CSV/JSON/Excel + ZIP), one timestamped subfolder per run   (git-ignored)
Logs/                Run logs, one file per run                                              (git-ignored)
```

Every run writes its output to `Output/<cloud>_<timestamp>/` (with the ZIP beside it) and its log to `Logs/<cloud>_<timestamp>.log`, at the repository top level. When a script is run outside a repository, those folders are created in the current directory instead.

## Scripts

| Cloud | Script | Setup |
|---|---|---|
| **AWS** | `src/CVAWSCloudSizingScript.ps1` | [docs/AWS.md](docs/AWS.md) |
| **Azure** | `src/CVAzureCloudSizingScript.ps1` | [docs/Azure.md](docs/Azure.md) |
| **Google Cloud** | `src/CVGoogleCloudSizingScript.ps1` | [docs/GoogleCloud.md](docs/GoogleCloud.md) |
| **OCI** | `src/OCI/CVOracleCloudSizingScript.py` | [src/OCI/README.md](src/OCI/README.md) |
| **M365** | `src/CVM365SizingScript.ps1` | (inline `-?` help) |

The AWS/Azure/GCP PowerShell scripts share a polished terminal UI and unified error handling via `src/common/CVSizing.Console.ps1`. `PwshSpectreConsole` is required for the interactive UI; runs started with `-NonInteractive` fall back to plain, pipe-safe output (used by the containerized Jobs in `k8s/`).
