# Cloud Sizing Scripts

Cross-platform **Python** tools that discover cloud resources across one or more AWS accounts and
Azure subscriptions and produce Excel workbooks summarizing provisioned/used capacity. They help
Commvault representatives inventory what may need protection and estimate the cost of protecting it.

Two cloud tools share one engine:

- **AWS** — [`AWS/CVAWSCloudSizingScript.py`](AWS/CVAWSCloudSizingScript.py)
- **Azure** — [`Azure/CVAzureCloudSizingScript.py`](Azure/CVAzureCloudSizingScript.py)

Both delegate their terminal UX, Excel output, and CLI to the shared driver
[`cloudsizing_common.py`](cloudsizing_common.py), so the **output looks identical for both clouds**
(documented once, below). The runs are read-only; nothing is modified in your cloud.

> The original PowerShell versions have been retired; they now live in [`old/`](old/) for reference.

## Repository layout

```
cloud-sizing-scripts/
├── cloudsizing_common.py     # shared driver: Excel output, terminal UX, CLI, summaries
├── pyproject.toml            # uv workspace root (members: AWS, Azure)
├── uv.lock
├── AWS/
│   ├── CVAWSCloudSizingScript.py
│   ├── pyproject.toml        # boto3
│   └── README.md             # AWS-specific: workloads, auth, IAM
├── Azure/
│   ├── CVAzureCloudSizingScript.py
│   ├── pyproject.toml        # azure-identity / azure-mgmt-*
│   └── README.md             # Azure-specific: workloads, auth, RBAC, backup detection
├── Metrics/                  # output workbooks land here (created on run)
├── Logs/                     # per-run execution logs land here (created on run)
└── old/                      # retired PowerShell scripts
```

## Prerequisites

- **Python ≥ 3.12**
- **[uv](https://docs.astral.sh/uv/)** — used to manage the workspace and dependencies.
- **Cloud credentials** for whichever cloud you target:
  - AWS — a configured profile, environment variables, an instance/CloudShell role, or a
    cross-account role (boto3's standard credential chain). See [AWS/README.md](AWS/README.md#authentication-modes).
  - Azure — `az login`, an environment service principal, or a managed identity
    (`DefaultAzureCredential`). See [Azure/README.md](Azure/README.md#authentication).
- **Optional, only for the Kubernetes workloads** (`eks` / `aks`): `kubectl` on `PATH`.

## Setup

This is a **uv workspace** (`[tool.uv] workspace.members = ["AWS", "Azure"]`). The root provides the
shared dependencies (`openpyxl`, `rich`); each cloud's SDKs come from an extra.

```bash
# Both clouds (simplest, recommended)
uv sync --all-extras

# Or just one cloud
uv sync --extra aws
uv sync --extra azure
```

`uv sync` creates a single `.venv/` at the repo root with the locked dependencies. (There is no
separate `requirements.txt`, and the scripts do **not** self-install anything — `uv` handles it.)

## Usage

Run either script through `uv run` from the repo root:

```bash
# AWS — e.g. two regions, machine-readable summary
uv run python AWS/CVAWSCloudSizingScript.py --regions=us-east-1,us-west-2

# Azure — e.g. one subscription, VMs + storage only
uv run python Azure/CVAzureCloudSizingScript.py --subscriptions=Prod --workload=virtual-machines,storage-accounts

# Check credentials without collecting anything (recommended first run)
uv run python AWS/CVAWSCloudSizingScript.py --validate-only
uv run python Azure/CVAzureCloudSizingScript.py --validate-only
```

Flags common to both tools: `--workload=<list>` (limit workloads), `--validate-only`, `--json`,
`-q/--quiet`, `-v/--verbose`, `--no-color`, `--no-input` (never prompt; for CI). Each cloud adds its
own scope/auth flags — run `--help`, or see the per-cloud READMEs:

- **[AWS/README.md](AWS/README.md)** — accounts/profiles/roles, regions, partitions, IAM permissions.
- **[Azure/README.md](Azure/README.md)** — subscriptions/tenant, regions, RBAC, and **backup
  detection** (whether each resource is already protected by Azure-native backup).

When run interactively with more than one account/subscription and no explicit scope flags, the tool
shows a numbered picker so you can choose which to scan; `--no-input` (or passing the scope flags)
skips it.

## What it inventories

Each tool collects a set of **workloads**; sizing is read from native APIs (and CloudWatch / Azure
Monitor where used metrics are available). Full tables with the exact sizing source per workload are
in the per-cloud READMEs.

- **AWS** (10 workload types): EC2 (+ attached EBS), unattached EBS, S3, EFS, FSx (+ ONTAP SVMs),
  RDS, DocumentDB, DynamoDB, Redshift, EKS. → [details](AWS/README.md#what-it-inventories)
- **Azure** (10 workload types + a Cloud Rewind quote view): Virtual Machines (+ managed disks),
  Storage Accounts, Azure Files, NetApp Files, SQL Database, SQL Managed Instance, MySQL, PostgreSQL,
  Cosmos DB, AKS, and `cloud-rewind-quote`. Azure runs also annotate each resource with existing
  **backup protection**. → [details](Azure/README.md#what-it-inventories)

## Output

A run produces two things: a **live terminal summary** (for the human running it) and **Excel
workbooks** plus a **log file** (the deliverables). Streams are kept separate so the tool composes
in pipelines:

- **stderr** — everything human-facing (banner, progress bar, summary table, warnings/errors).
- **stdout** — machine output only: the written workbook path(s), or the full `--json` summary.
- **`Logs/<aws|azure>_sizing_<timestamp>.log`** — the complete, timestamped run log regardless of
  console verbosity.

### CLI summary

What you see in the terminal during and after a run:

1. **Banner** — the tool name + version, the scopes (accounts/subscriptions) being scanned, and the
   workloads to be collected.
2. **Progress bar** — a transient Rich bar (spinner, current scope/workload, `X/Y` completed,
   elapsed time). It disappears when done and is auto-disabled when output is piped, under
   `--quiet`, or not a terminal.
3. **`Wrote Metrics/…xlsx`** — one line per workbook written.
4. **Sizing summary** — a table of per-workload resource counts and total sizes:

   ```
   Sizing summary
   ┏━━━━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━━━━━┓
   ┃ Workload                ┃              Resource Count ┃ Total (TB) ┃
   ┡━━━━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━━━━━┩
   │ Azure VM                │                          12 │     3.4000 │
   │ Azure Storage Account   │                           5 │     1.2000 │
   │ Backup coverage         │                             │            │   ← Azure only
   │   ├─ Azure VM           │ 9 protected / 3 unprotected │            │
   │   ├─ Azure Storage …    │ 4 protected / 1 unprotected │            │
   │   └─ Total              │ 13 protected / 4 unprotect… │            │
   └─────────────────────────┴─────────────────────────────┴────────────┘
   ```

   Counts/totals are aggregated across every scope in the run. Azure adds two extra sections when
   applicable: a **Cloud Rewind** breakdown (Discovered vs Protectable resources) and the **Backup
   coverage** rollup shown above (protected vs unprotected per workload — see
   [Azure/README.md](Azure/README.md#backup-detection)).

**`--json`** replaces the human summary on stdout with a machine-readable object:

```json
{
  "version": "0.1.0",
  "cloud": "azure",
  "scopes": [
    {
      "id": "00000000-0000-0000-0000-000000000000",
      "name": "Prod",
      "workbook": "Metrics/Prod_summary_2026-06-24_120530.xlsx",
      "workloads": {
        "virtual-machines": { "count": 12, "size_gb": 3400.0, "size_tb": 3.4 }
      }
    }
  ],
  "combined": {
    "virtual-machines": { "count": 12, "size_gb": 3400.0, "size_tb": 3.4 }
  },
  "comprehensive_workbook": null,
  "backup_coverage": { "Azure VM": "9 protected / 3 unprotected", "Total": "13 protected / 4 unprotected" }
}
```

(`backup_coverage` is Azure-only; `comprehensive_workbook` is populated only when more than one scope
is processed.)

**Exit codes:** `0` success · `1` runtime/credential failure · `2` usage error · `130` interrupted
(Ctrl-C).

### Excel workbooks

Workbooks are written to `Metrics/`:

| File | When |
|------|------|
| `Metrics/<scope>_summary_<YYYY-MM-DD_HHMMSS>.xlsx` | one per account (AWS) / subscription (Azure) |
| `Metrics/comprehensive_<all_aws_accounts \| all_azure_subscriptions>_<timestamp>.xlsx` | only when more than one scope is processed (combined view) |

Each workbook contains **two sheets per non-empty workload** — an **Info** sheet and a **Summary**
sheet:

**Info sheet — one row per resource.** Columns are the scope identity, then resource-specific detail,
then sizes, then (Azure) backup status. Every size appears as **four columns** — GiB and TiB
(binary) plus GB and TB (decimal) — so you can use whichever unit your sizing model expects. Example
(`Azure VM Info`):

| Subscription ID | Subscription Name | Resource Group | Region | VM Name | VM Size | OS | Disk Count | Size (GiB) | Size (TiB) | Size (GB) | Size (TB) | Disk Details | Tags | Native Backup | Backup Type | Backup Vault | Backup Policy | Last Backup | Snapshot Count |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| …-0001 | Prod | rg-app | eastus | vm-app-01 | Standard_D4s_v5 | Linux | 2 | 256 | 0.25 | 274.9 | 0.27 | osdisk:128GiB; data:128GiB | {env:prod} | Yes | RSV | rsv-prod | DailyPolicy | 2026-06-23T01:10Z | 0 |

The AWS Info sheets follow the same shape with AWS identity columns (`Account ID`, `Account Alias`,
`Region`) — e.g. `EC2 Info` has Instance ID / Instance Type / State / size columns / Volume Details /
Tags. (Azure's six backup columns — `Native Backup`, `Backup Type`, `Backup Vault`, `Backup Policy`,
`Last Backup`, `Snapshot Count` — are Azure-only.)

**Summary sheet — a per-region rollup.** A **bold grand-total row sits at the top**, followed by one
row per region. Example (`Azure VM Summary`):

| Region | Count | Total Size (GB) | Total Size (TB) |
|---|---|---|---|
| **Total Azure VMs** | **12** | **3400.0** | **3.4** |
| eastus | 8 | 2200.0 | 2.2 |
| westus2 | 4 | 1200.0 | 1.2 |

(The `cloud-rewind-quote` workload uses its own summary columns — billable/non-billable and
protectable counts — rather than size totals.)

**Formatting:** header rows are bold with a light-gray fill, and columns are auto-sized to their
content (capped at a sensible width). Open the workbook in Excel, Google Sheets, or LibreOffice.

## Troubleshooting

- **`ModuleNotFoundError: No module named 'six'` (Azure-only installs)** — `azure-mgmt-sql` needs
  `six` transitively; it isn't pulled by `--extra azure` alone. Use `uv sync --all-extras` (it
  arrives via the AWS deps) or `uv pip install six`.
- **No credentials / nothing authenticates** — the startup preflight prints setup guidance and exits
  `1` rather than erroring out. Confirm with `--validate-only` (`aws sts get-caller-identity` /
  `az account show`).
- **"No resources found" / no workbook for a scope** — that account/subscription had nothing for the
  selected workloads; the run continues and skips the empty workbook.

## See also

- **[AWS/README.md](AWS/README.md)** — AWS workloads, authentication modes, options, and the
  read-only IAM permissions required.
- **[Azure/README.md](Azure/README.md)** — Azure workloads, authentication, RBAC, options, and
  backup-protection detection.
