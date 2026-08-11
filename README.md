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

Each script loads the shared console/diagnostics layer from `common/` automatically. Add `-NonInteractive` for plain, pipe-safe output (CI / automation). First time here? Work through [Setup & installation](#setup--installation) below; full parameter details are in the per-cloud docs.

## Setup & installation

Every run needs three things: **PowerShell 7**, the **cloud vendor's CLI/SDK** (installed and authenticated), and a set of **PowerShell modules**. The steps below are the same on Windows, macOS and Linux except where called out.

| | AWS | Azure | Google Cloud |
|---|---|---|---|
| PowerShell 7+ | Required | Required | Required |
| Vendor CLI | **AWS CLI v2** — required (credential profiles, SSO, EKS kubeconfig) | Azure CLI **not** required — Azure runs on the Az PowerShell modules | **gcloud CLI** — required, including the `gsutil` and `bq` components |
| PowerShell modules | `AWS.Tools.*`, `ImportExcel` | `Az.*` | none (beyond the shared console UI) |
| Interactive console UI | `PwshSpectreConsole` (not needed with `-NonInteractive`) | same | same |
| `kubectl` | Auto-installed when needed | Auto-installed when needed | Auto-installed when needed |

The AWS and Azure scripts are deliberately opinionated: **every** module in their list is required, so a run is never a silently partial inventory. The preflight fails fast and names exactly what to install.

### Step 1 — Install PowerShell 7

PowerShell 7 (`pwsh`) is cross-platform and installs alongside the Windows PowerShell 5.1 that ships with Windows — it does not replace it.

**Windows**
```powershell
winget install --id Microsoft.PowerShell --source winget
```
[Installing PowerShell on Windows](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)

**macOS**
```bash
brew install powershell/tap/powershell
```
[Installing PowerShell on macOS](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-macos)

**Linux** — packages differ per distro (apt, dnf, snap, tarball): [Installing PowerShell on Linux](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux)

Verify, then start a PowerShell 7 session — on macOS/Linux `pwsh` is the shell you run the scripts from:
```bash
pwsh -Version   # must report 7.x
pwsh
```

### Step 2 — Install and configure your cloud's CLI

Install only the CLI for the cloud you are sizing, then **authenticate** — the scripts use whatever credentials the CLI/SDK has already established; they never prompt for keys. Vendor docs are the source of truth for each platform's installer:

**AWS — AWS CLI v2**
- Install (Windows / macOS / Linux): [Installing or updating the AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- Configure credentials: [Configuration basics](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-quickstart.html) — or, for IAM Identity Center / SSO: [Configuring IAM Identity Center authentication](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html)
- Confirm: `aws sts get-caller-identity`

**Azure — Az PowerShell modules**
Azure is the exception: the script talks to Azure through the `Az` PowerShell modules (installed in step 3), not the `az` CLI, so **the Azure CLI is optional**. Install it only if you want `az` for other work.
- Az PowerShell install/overview: [Install the Azure Az PowerShell module](https://learn.microsoft.com/powershell/azure/install-azure-powershell)
- Sign in: `Connect-AzAccount` — [Sign in with Azure PowerShell](https://learn.microsoft.com/powershell/azure/authenticate-azureps)
- (Optional) Azure CLI: [Install the Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
- Confirm: `Get-AzSubscription`

**Google Cloud — gcloud CLI**
- Install (Windows / macOS / Linux): [Install the gcloud CLI](https://cloud.google.com/sdk/docs/install)
- Initialize and sign in: [Initializing the gcloud CLI](https://cloud.google.com/sdk/docs/initializing) — `gcloud init`, or `gcloud auth login` if already initialized
- The script requires `gsutil` (bucket sizing) and `bq` (BigQuery sizing) in addition to `gcloud`. They ship with the SDK; if the preflight reports either missing, add them with [`gcloud components install gsutil bq`](https://cloud.google.com/sdk/docs/components)
- Confirm: `gcloud auth list` and `gcloud projects list`

**Permissions:** read-only access is enough everywhere — AWS: the IAM policy in [docs/AWS.md](docs/AWS.md); Azure: **Reader** on each target subscription; GCP: **Viewer** on each target project.

### Step 3 — Install the PowerShell modules

Run these inside a PowerShell 7 session (`pwsh`). `-Scope CurrentUser` avoids needing admin/root.

**Shared (all clouds)** — the interactive console UI. Skip it if you will always pass `-NonInteractive`:
```powershell
Install-Module PwshSpectreConsole -Scope CurrentUser -Force
```

**AWS**
```powershell
Install-Module ImportExcel,AWS.Tools.Installer -Scope CurrentUser -Force -Confirm:$false
Install-AWSToolsModule -Name AWS.Tools.Common,AWS.Tools.EC2,AWS.Tools.S3,AWS.Tools.SecurityToken,AWS.Tools.IdentityManagement,AWS.Tools.CloudWatch,AWS.Tools.RDS,AWS.Tools.DynamoDBv2,AWS.Tools.Redshift,AWS.Tools.FSx,AWS.Tools.ElasticFileSystem,AWS.Tools.EKS,AWS.Tools.DocDB,AWS.Tools.ElastiCache,AWS.Tools.Backup,AWS.Tools.ResourceGroupsTaggingAPI -Scope CurrentUser -CleanUp -Force -Confirm:$false
```

**Azure**
```powershell
Install-Module Az.Accounts,Az.Compute,Az.Storage,Az.Monitor,Az.Resources,Az.NetAppFiles,Az.CosmosDB,Az.Sql,Az.MySql,Az.PostgreSql,Az.Aks,Az.RecoveryServices,Az.VMware,Az.Network,Az.ResourceGraph -Scope CurrentUser -Force
```

**Google Cloud** — no cloud-specific modules; the gcloud CLI from step 2 is all that is needed.

The last module in each list covers the Cloud Rewind pass (`AWS.Tools.ResourceGroupsTaggingAPI`; `Az.Network` plus the optional `Az.ResourceGraph`). On GCP that pass instead needs the **Cloud Asset API** enabled per project — `gcloud services enable cloudasset.googleapis.com`. Pass `-SkipCloudRewind` to run without any of them.

### Step 4 — Clone and run

```powershell
git clone <repo-url>
cd dy-cloud-sizing-scripts/src

./CVAzureCloudSizingScript.ps1     # run the script for your cloud
```

Run the scripts from `src/` — they load their shared layer from `common/` next to them.

**Windows, first run:** if you see *"cannot be loaded because it is not digitally signed"*, PowerShell's execution policy is blocking the unsigned script. Allow it for the current session only:
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```
[About execution policies](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_execution_policies)

**macOS / Linux, first run:** no execution policy to change. Either run from inside `pwsh` as above, or invoke directly with `pwsh ./CVAzureCloudSizingScript.ps1`. To run as `./script.ps1` from a POSIX shell, mark it executable first: `chmod +x CVAzureCloudSizingScript.ps1`.

Each script's preflight validates every requirement before doing any work and prints the exact install command for anything missing — so the fastest way to confirm your setup is simply to run it.

## Running the Scripts

Every AWS/Azure/GCP run performs **two independent passes by default**:

1. **Data Protection sizing** — the per-service resource inventory (VMs, storage, databases, …), protection columns, and the cyber-resilience posture report.
2. **Cloud Rewind sizing** — counts the resources Commvault **Cloud Rewind** (Appranix) bills for. It runs its own lightweight sweep (Azure `Get-AzResource`, AWS Resource Groups Tagging API, GCP Cloud Asset Inventory), classifies each resource billable / non-billable and Data / Config, and writes:
   - `<cloud>_cloudrewind_<ts>.csv` — one row per **billable** resource: account/region/resource group scope, resource name and native type, why it is billable, and topology. The two widest columns (`ResourceId`, then the flattened `Tags` blob) are last so they don't crowd out the rest in a spreadsheet; a `-Tags` filter adds one narrow `Tag_<key>` column per filtered key just before `Tags`.
   - `<cloud>_cloudrewind_summary_<ts>.csv` — per-account `BillableDataResources` / `BillableConfigResources` / `NonBillableDataResources` / `NonBillableConfigResources` plus totals. Every number is a **count of resources, not a size** — hence the `...Resources` suffix, since these sit alongside per-service CSVs full of `SizeGB`/`UsedTiB` columns. `TotalBillableResources` is the figure that maps to Cloud Rewind licensing; `TotalClassifiedResources` counts only resources matching the taxonomy, so it is *not* the account's total resource count.

### How to Use

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

## Cyber resilience signals

Alongside the inventory, every run exports the resilience-relevant configuration of each discovered resource to
`Output/<cloud>_<timestamp>/<cloud>_resilience_signals_<timestamp>.csv` — one row per resource, one column per
signal, using the values read from the cloud API.

The file is deliberately **judgement-free**: it carries the values, not verdicts about them. There is no score, no
risk weight and no pass/fail column, because scoring is owned by the backend and can be re-tuned there without
reissuing reports.

See **[CYBER_RESILIENCE_REPORT.md](CYBER_RESILIENCE_REPORT.md)** for the full schema and every signal, per cloud
and per resource type.

Skip the pass entirely with `-SkipResilienceReport`.

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
CYBER_RESILIENCE_REPORT.md   Resilience signal export: schema + every signal per cloud/resource type
tests/               Dependency-free test suite for the shared console layer
tools/               Show-CVConsoleDemo.ps1 - visual demo of the console layer
k8s/                 Dockerfiles, entrypoints and Job manifests for containerized runs
Output/              Run output (CSV/JSON/Excel + ZIP), one timestamped subfolder per run   (git-ignored)
Logs/                Run logs, one file per run                                              (git-ignored)
```

Every run writes its output to `Output/<cloud>_<timestamp>/` (with the ZIP beside it) and its log to `Logs/<cloud>_<timestamp>.log`, at the repository top level.

Outside a repository — a copied-out `src/` folder, a container image — those folders are created **next to the script** rather than in the current directory, so the location does not depend on where you happened to `cd`. Pass `-OutputDirectory <path>` to any of the sizing scripts to choose the root explicitly (the OCI script takes `--output-dir=<path>`).

> **Changed:** earlier versions used the current working directory outside a repository, which scattered output across wherever the shell was and failed outright from a non-writable directory. Runs from inside a checkout are unaffected.