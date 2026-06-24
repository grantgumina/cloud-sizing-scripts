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
| `virtual-machines` | Virtual machines + managed disks | Sum of OS + data disk provisioned sizes |
| `storage-accounts` | Storage accounts (blob) | Azure Monitor `BlobCapacity` (+ `BlobCount`, `ContainerCount`) |
| `azure-files` | Azure Files shares | Share quota + `shareUsageBytes` (stats) |
| `azure-netapp-files` | Azure NetApp Files volumes | Provisioned (`usageThreshold`) + Monitor `VolumeLogicalSize` |
| `azure-sql-database` | Azure SQL databases | `maxSizeBytes` + Monitor `storage` |
| `azure-sql-managed-instance` | SQL Managed Instances | `storageSizeInGB` + Monitor `storage_space_used_mb` |
| `azure-database-mysql` | MySQL (flexible + single) | Provisioned storage + Monitor `storage_used` |
| `azure-database-postgresql` | PostgreSQL (flexible + single) | Provisioned storage + Monitor `storage_used` |
| `azure-cosmos-db` | Cosmos DB accounts | Monitor `DataUsage` (+ `DocumentCount`) |
| `aks` | Azure Kubernetes Service clusters | PVC capacity + node count via `kubectl` |
| `cloud-rewind-quote` | Cloud Rewind view | Resource classification into billable/non-billable and data/config (with exclusions for unattached/unused network & disk resources) |

Sizes are reported in both binary (GiB/TiB) and decimal (GB/TB) units. Azure
Monitor metrics use Maximum aggregation over a 1-hour lookback (NetApp uses
Average), mirroring the original PowerShell behavior.

## Backup detection

By default the script also reports whether each discovered resource is **already
protected by an Azure-native mechanism** — useful for deciding what still needs
Commvault protection. Every workload's **Info** sheet gains the columns
`Native Backup` (Yes/No), `Backup Type`, `Backup Vault`, `Backup Policy`,
`Last Backup`, and `Snapshot Count`, and the run-summary gains a **Backup
coverage** section (protected vs unprotected per workload). Three sources are
detected:

- **Azure Backup service** — both classic **Recovery Services vaults** and the
  newer DataProtection **Backup vaults** (VMs, Azure Files, disks, blobs, AKS,
  PostgreSQL, …). `Backup Type` is `RSV` or `Backup Vault`.
- **Snapshots** — managed-disk snapshots (mapped to their VM). `Backup Type` is
  `Snapshot`. Note a snapshot proves a point-in-time copy exists, **not** an
  ongoing/scheduled backup.
- **Built-in PaaS backup** — always-on automated backups for SQL (PITR),
  MySQL/PostgreSQL (retention), and Cosmos DB (backup policy). `Backup Type` is
  `Built-in`. These are nearly always on, so those workloads almost always show
  as protected.

Detection runs **Azure Resource Graph (ARG)** queries (the `RecoveryServicesResources`
and `Resources` tables) scoped per subscription — **Reader** already covers them,
no extra role is needed. Pass `--no-backup-status` to skip it (faster, no ARG
calls). Detection is **best-effort**: if the Resource Graph provider/package is
unavailable or RBAC denies the query, the backup columns are simply left blank
and the run still produces its workbooks.

Caveats: ARG reflects current protection *state* but recovery-point/job data can
lag (ARG keeps ~14 days of job history), so `Last Backup` is best-effort;
classic (ASM) resources and data-plane blob snapshots are not covered;
soft-deleted/stopped protection is reported with its state shown in `Backup Type`.

## Output

A run writes per-subscription workbooks to `Metrics/<subscription>_summary_<timestamp>.xlsx` (plus a
combined `comprehensive_all_azure_subscriptions_<timestamp>.xlsx` when more than one subscription is
processed) and a log to `Logs/azure_sizing_<timestamp>.log`. Each workbook has an **Info** sheet (one
row per resource — including the six backup columns described above) and a **Summary** sheet
(per-region totals with a bold grand-total row) per workload.

See **[Understanding the output](../README.md#output)** in the root README for the full, shared
reference — the CLI summary (including the **Backup coverage** rollup), the `--json` shape, and the
spreadsheet sheet/column layout.

## Prerequisites

- Python 3.12+ and [uv](https://docs.astral.sh/uv/). Install from the repo root with
  `uv sync --extra azure` (or `uv sync --all-extras`) — see the [root README](../README.md#setup).
  This tool adds the `azure-identity` / `azure-mgmt-*` SDKs; the shared `openpyxl`/`rich` come from
  the root. Then run it with `uv run python CVAzureCloudSizingScript.py …` from this directory (or
  `uv run python Azure/CVAzureCloudSizingScript.py …` from the repo root). (If an Azure-only sync
  hits `ModuleNotFoundError: No module named 'six'`, use `uv sync --all-extras` — see the root
  [Troubleshooting](../README.md#troubleshooting).)
- Azure credentials (see below). RBAC: **Reader** on the target subscriptions
  (also covers the Azure Resource Graph backup-detection queries — no extra role
  needed); **Reader and Data Access** is also helpful for storage-account
  metrics; for `aks_cluster`, **Azure Kubernetes Service Cluster User** plus
  `kubectl` on `PATH` (AAD-integrated clusters may additionally need `kubelogin`).

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
| `--no-backup-status` | Skip detecting existing Azure-native backup protection (on by default; uses Azure Resource Graph, needs Reader) |
| `--validate-only` | Run the credential preflight, report the subscriptions/regions that would be collected, then exit without collecting |
| `--json` | Emit a machine-readable summary to **stdout** (for `jq`/scripting) |
| `-q`, `--quiet` | Only warnings and errors; no progress or summary |
| `-v`, `--verbose` | Verbose console output (timestamps, debug, tracebacks) |
| `--no-color` | Disable colored output (also honors `NO_COLOR`) |
| `--no-input` | Never prompt; for non-interactive / CI use |
| `--version` | Print the version and exit |

Run `python CVAzureCloudSizingScript.py --help` for the full grouped list.

## Terminal output

stderr carries human output (progress, summary table, the **Backup coverage** rollup,
warnings/errors); stdout carries only machine output (the written workbook paths, or `--json`). See
**[CLI summary](../README.md#cli-summary)** in the root README for the full reference (streams,
`--json` shape, exit codes).

```bash
# Machine-readable totals, piped to jq
python CVAzureCloudSizingScript.py --json --subscriptions=Prod | jq '.combined'
```
