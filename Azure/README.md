# Azure Cloud Sizing Script (Python)

`CVAzureCloudSizingScript.py` discovers Azure resources across one or more
subscriptions and produces Excel workbooks summarizing provisioned/used capacity.
It is the cross-platform Python replacement for the original
`CVAzureCloudSizingScript.ps1` and shares its terminal UX, Excel output, and CLI
with the AWS tool via the repo-root `cloudsizing_common.py` module.

Unlike AWS, Azure enumerates resources at **subscription scope** (each resource
carries its own region), so the run is subscription → workload rather than
account → region → workload.

## What it inventories

| Workload | Service(s) | Sizing source |
|----------|-----------|----------------|
| `vm` | Virtual machines + managed disks | Sum of OS + data disk provisioned sizes |
| `storage_account` | Storage accounts (blob) | Azure Monitor `BlobCapacity` (+ `BlobCount`, `ContainerCount`) |
| `file_share` | Azure Files shares | Share quota + `shareUsageBytes` (stats) |
| `netapp_volume` | Azure NetApp Files volumes | Provisioned (`usageThreshold`) + Monitor `VolumeLogicalSize` |
| `sql_database` | Azure SQL databases | `maxSizeBytes` + Monitor `storage` |
| `sql_managed_instance` | SQL Managed Instances | `storageSizeInGB` + Monitor `storage_space_used_mb` |
| `mysql_server` | MySQL (flexible + single) | Provisioned storage + Monitor `storage_used` |
| `postgresql_server` | PostgreSQL (flexible + single) | Provisioned storage + Monitor `storage_used` |
| `cosmosdb_account` | Cosmos DB accounts | Monitor `DataUsage` (+ `DocumentCount`) |
| `aks_cluster` | AKS clusters | PVC capacity + node count via `kubectl` |

Sizes are reported in both binary (GiB/TiB) and decimal (GB/TB) units. Azure
Monitor metrics use Maximum aggregation over a 1-hour lookback (NetApp uses
Average), mirroring the original PowerShell behavior.

## Output

- `Metrics/<subscription>_summary_<timestamp>.xlsx` — one workbook per subscription.
- `Metrics/comprehensive_all_azure_subscriptions_<timestamp>.xlsx` — combined workbook (only when more than one subscription is processed).
- `Logs/azure_sizing_<timestamp>.log` — full timestamped execution log.

Each workbook has an **Info** sheet (one row per resource) and a **Summary**
sheet (per-region counts/totals with a bold grand-total row) per workload.

## Prerequisites

- Python 3.12+
- Dependencies: `openpyxl`, `rich`, and the `azure-identity` / `azure-mgmt-*`
  SDKs. Install any one way:
  - `pip install -r ../requirements.txt` (the repo-wide requirements file), or
  - `pip install -e .` from this directory (uses `pyproject.toml`).
  - The script also auto-installs its dependencies on first run.
- Azure credentials (see below). RBAC: **Reader** on the target subscriptions;
  **Reader and Data Access** is also helpful for storage-account metrics; for
  `aks_cluster`, **Azure Kubernetes Service Cluster User** plus `kubectl` on
  `PATH` (AAD-integrated clusters may additionally need `kubelogin`).

### Verify credentials before running

The script authenticates through `DefaultAzureCredential` — it does not prompt
for secrets. Before a real run, confirm credentials resolve:

```bash
az account show                       # should print your subscription/tenant
# or, without collecting anything:
python CVAzureCloudSizingScript.py --validate-only
```

On startup the script runs a **credential preflight**. If nothing authenticates
it prints setup guidance and exits `1` instead of emitting a wall of errors.

## Authentication

`DefaultAzureCredential` tries, in order: environment service principal
(`AZURE_CLIENT_ID` / `AZURE_CLIENT_SECRET` / `AZURE_TENANT_ID`), workload/managed
identity (when running in Azure), and the Azure CLI (`az login`). Choose one:

```bash
# Azure CLI (laptop)
az login
python CVAzureCloudSizingScript.py

# Service principal (CI / automation)
export AZURE_CLIENT_ID=... AZURE_CLIENT_SECRET=... AZURE_TENANT_ID=...
python CVAzureCloudSizingScript.py --no-input

# Inside Azure (Cloud Shell / VM / AKS managed identity) — nothing to configure
python CVAzureCloudSizingScript.py
```

By default every accessible **Enabled** subscription is processed; subscriptions
that fail to authenticate are skipped with a warning while the valid ones run.

When run interactively (a terminal, no `--subscriptions`/`--tenant`, no
`--no-input`) and more than one subscription is found, the script first shows a
numbered picker so you can choose which subscriptions to scan. Pass
`--subscriptions=...` or `--no-input` to skip it (e.g. in CI).

## Common options

| Option | Description |
|--------|-------------|
| `--subscriptions=ID,NAME` | Only these subscription IDs or names (default: all accessible) |
| `--tenant=TENANT_ID` | Only subscriptions in this tenant |
| `--regions=r1,r2` | Regions to collect resources from (default: all). `--locations` is accepted as an alias |
| `--workload=vm,storage_account,...` | Limit to specific workloads (default: `all`) |
| `--validate-only` | Run the credential preflight, report the subscriptions/regions that would be collected, then exit without collecting |
| `--json` | Emit a machine-readable summary to **stdout** (for `jq`/scripting) |
| `-q`, `--quiet` | Only warnings and errors; no progress or summary |
| `-v`, `--verbose` | Verbose console output (timestamps, debug, tracebacks) |
| `--no-color` | Disable colored output (also honors `NO_COLOR`) |
| `--no-input` | Never prompt; for non-interactive / CI use |
| `--version` | Print the version and exit |

Run `python CVAzureCloudSizingScript.py --help` for the full grouped list.

## Terminal output

Like the AWS tool, the script is TTY-aware and separates streams: **stderr**
carries human output (progress, summary table, warnings/errors) while **stdout**
carries only machine output (the written workbook paths, or `--json`). Exit
codes: `0` success · `1` runtime/credential failure · `2` usage error · `130`
interrupted (Ctrl-C).

```bash
# Machine-readable totals, piped to jq
python CVAzureCloudSizingScript.py --json --subscriptions=Prod | jq '.combined'
```
