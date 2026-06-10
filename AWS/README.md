# AWS Cloud Sizing Script (Python)

`CVAWSCloudSizingScript.py` discovers AWS cloud resources across one or more
accounts and regions and produces Excel workbooks summarizing provisioned/used
capacity. It is the cross-platform Python replacement for the original
`CVAWSCloudSizingScript.ps1` and runs identically on Linux, macOS, Windows, and
AWS CloudShell.

## What it inventories

| Workload | Service(s) | Sizing source |
|----------|-----------|----------------|
| `ec2` | EC2 instances + attached EBS | Sum of attached EBS volume sizes |
| `ebs-unattached` | EBS volumes in `available` state | Provisioned volume size |
| `s3` | S3 buckets | CloudWatch `BucketSizeBytes` (per storage class) + `NumberOfObjects`; object-enumeration fallback |
| `efs` | EFS file systems | `SizeInBytes` or CloudWatch `StorageBytes` |
| `fsx` | FSx file systems + ONTAP SVMs/volumes | Provisioned storage capacity |
| `rds` | RDS instances | Allocated storage; Aurora used via CloudWatch `VolumeBytesUsed` |
| `documentdb` | DocumentDB clusters + instances | CloudWatch `VolumeBytesUsed` |
| `dynamodb` | DynamoDB tables | `TableSizeBytes` + item count |
| `redshift` | Redshift clusters | `TotalStorageCapacityInMegaBytes` |
| `eks` | EKS clusters | PVC capacity + node count via `kubectl` |

Every size is reported in both binary (GiB/TiB) and decimal (GB/TB) units.

## Output

- `Metrics/<account>_summary_<timestamp>.xlsx` — one workbook per account.
- `Metrics/comprehensive_all_aws_accounts_<timestamp>.xlsx` — combined workbook (only when more than one account is processed).
- `Logs/aws_sizing_<timestamp>.log` — execution log.

Each workbook has an **Info** sheet (one row per resource) and a **Summary**
sheet (per-region counts/totals with a bold grand-total row) per workload.

## Prerequisites

- Python 3.12+
- Dependencies: `boto3`, `openpyxl`, `rich`. Install any one way:
  - `pip install -r ../requirements.txt` (the repo-wide requirements file for all tools), or
  - `pip install boto3 openpyxl rich` (just this tool's deps; the script also auto-installs these on first run).
- AWS credentials (a configured profile, environment variables, an instance/CloudShell role, or a cross-account role).
- For the `eks` workload: `kubectl` and the AWS CLI (`aws`) on `PATH`, and the running identity must be permitted in each cluster's access config (`aws-auth`/access entries).

### Verify credentials before running

The script authenticates entirely through boto3's standard credential chain — it
does not prompt for keys or perform an interactive login. Before a real run,
confirm credentials resolve:

```bash
aws sts get-caller-identity          # should print your account/ARN
# or, without collecting anything:
python CVAWSCloudSizingScript.py --validate-only
```

On startup the script runs a **credential preflight** (`sts:GetCallerIdentity`).
If no credentials authenticate, it prints setup guidance and exits `1` instead of
emitting a wall of errors. In multi-account / multi-profile runs, sessions that
fail to authenticate are skipped with a warning and the valid ones still run.

When run interactively (a terminal, no account/profile flags, no `--no-input`)
and more than one account is resolved, the script first shows a numbered picker
so you can choose which accounts to scan. Passing `--profiles`/`--accounts`/etc.
or `--no-input` skips it.

## Authentication modes

```bash
# Default credential chain (CloudShell / instance role / env / default profile)
python CVAWSCloudSizingScript.py --default-profile --regions=us-east-1

# Named local profiles
python CVAWSCloudSizingScript.py --profiles=prod,dev --regions=us-east-1,us-west-2

# Every profile in a custom credentials file
python CVAWSCloudSizingScript.py --all-local-profiles --profile-location=./Creds.txt

# Cross-account role assumption
python CVAWSCloudSizingScript.py \
    --cross-account-role=InventoryRole \
    --accounts=123456789012,987654321098 \
    --regions=us-east-1
```

## Common options

| Option | Description |
|--------|-------------|
| `--regions=r1,r2` | Regions to query (default: all enabled regions) |
| `--workload=ec2,s3,...` | Limit to specific workloads (default: `all`) |
| `--partition=GovCloud` | Use the AWS GovCloud partition |
| `--skip-bucket-tags` | Skip fetching S3 bucket tags (faster) |
| `--no-s3-enumerate` | Disable object-enumeration fallback for S3 sizing |
| `--external-id=ID` | External ID for cross-account role assumption |
| `--role-session-name=NAME` | STS session name (default: `CVAWS-Cost-Sizing`) |
| `--validate-only` | Run the credential preflight, report the accounts/regions/workloads that would be collected, then exit without collecting |
| `--json` | Emit a machine-readable summary to **stdout** (for `jq`/scripting) |
| `-q`, `--quiet` | Only warnings and errors; no progress bar or summary table |
| `-v`, `--verbose` | Verbose console output (timestamps, debug, full tracebacks) |
| `--no-color` | Disable colored output (also honors the `NO_COLOR` env var) |
| `--no-input` | Never prompt; for non-interactive / CI use |
| `--version` | Print the version and exit |

Run `python CVAWSCloudSizingScript.py --help` for the full grouped list with examples.

## Terminal output

The script is TTY-aware and separates streams so it composes well in pipelines:

- **stderr** — human-facing output: a live progress display (per account/region/
  workload, plus the S3 object-enumeration counter), status lines, the summary
  table, and warnings/errors. Color and progress animation are disabled
  automatically when output is not a terminal, when `NO_COLOR`/`--no-color` is
  set, or under `--quiet`.
- **stdout** — machine output only: the written workbook path(s) by default, or a
  full JSON summary with `--json`. Nothing else is written to stdout, so
  `... --json | jq .` and `... > files.txt` work cleanly.
- **`Logs/aws_sizing_<ts>.log`** — the complete, timestamped run log (unchanged
  format) for later analysis, regardless of console verbosity.

```bash
# Machine-readable totals for two regions, piped to jq
python CVAWSCloudSizingScript.py --json --regions=us-east-1,us-west-2 | jq '.combined'

# Quiet run in CI: only the workbook paths reach stdout
python CVAWSCloudSizingScript.py --quiet --no-input > artifacts.txt
```

Exit codes: `0` success · `1` runtime/credential failure · `2` usage error ·
`130` interrupted (Ctrl-C).

## Required IAM permissions (read-only)

`sts:GetCallerIdentity`, `sts:AssumeRole` (cross-account only), `iam:ListAccountAliases`,
`ec2:Describe*`, `s3:ListAllMyBuckets`, `s3:GetBucketLocation`, `s3:GetBucketTagging`,
`s3:ListBucket`, `cloudwatch:GetMetricStatistics`, `elasticfilesystem:Describe*`,
`fsx:Describe*`, `rds:Describe*`, `rds:ListTagsForResource`, `dynamodb:ListTables`,
`dynamodb:DescribeTable`, `dynamodb:ListTagsOfResource`, `redshift:DescribeClusters`,
`redshift:DescribeTags`, `documentdb:Describe*`, `eks:ListClusters`, `eks:DescribeCluster`.
