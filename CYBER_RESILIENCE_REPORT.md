# Cyber Resilience Gap Report

Reference for the resilience posture assessment produced by the AWS, Azure and Google Cloud
sizing scripts — how to read the report, how it is scored, and what every control checks.

See [README.md](README.md) for installation and how to run the scripts.

Alongside the inventory, every run scores each discovered resource against the **Cloud Resilience Control Catalog** and writes `Output/<cloud>_<timestamp>/<cloud>_resilience_gaps_<timestamp>.csv` — one row per resource that has at least one gap, or that could not be fully assessed.

This measures the customer's **current native cloud configuration**, as-is. It is not a Commvault plan state and says nothing about what Commvault would do; it describes the exposure that exists today.

## Reading the file

Each row is a resource. Each control is a column named `Gap_<id>`, and those columns are **three-valued**:

| Value | Meaning |
|---|---|
| `True` | Gap — we checked, and the control is not satisfied |
| `False` | Clean — we checked, and the control is satisfied |
| *(blank)* | **Not assessed** — we could not evaluate it, or it does not apply to that resource type |

Blank is never a pass. A control goes blank when the signal was not collected — a permission the caller lacks, a disabled API, or a service simply not requested via `-Types`. Treating "we could not look" as "no problem found" would overstate the customer's posture, so those cells stay empty and are excluded from scoring rather than counted as either result.

Key columns:

| Column | What it tells you |
|---|---|
| `Status` | `Gap` (at least one control failed) or `NotAssessed` (nothing could be evaluated) |
| `SizeGB` / `SizeTB` | Data at risk. **Blank means unmeasured, not zero** — a resource we could not size is not a small resource |
| `WorstSeverity` | Highest severity among the gaps found |
| `GapCount`, `CriticalGaps`, `HighGaps`, `MediumGaps` | Gap counts, total and by severity |
| `GapCategories`, `GapTitles` | Human-readable summary of what failed, for pasting into a report |
| `AssessedControls` | Controls that produced a verdict (non-blank `Gap_*` cells) |
| `UnassessedControls` | Controls with no verdict (blank cells) — effectively a to-do list of permissions/APIs needed for a complete picture |
| `AssessmentComplete` | `False` whenever `UnassessedControls > 0` |
| `ResourceId` | ARM ID (Azure), ARN (AWS), or self-link (GCP). Blank where the resource type does not expose one |

`AssessedControls` and `UnassessedControls` exist so `GapCount` is not misread as a complete audit. "1 gap of 3 controls checked" and "1 gap, 2 controls we could not evaluate" are very different findings.

Note the **column set follows the estate**: a run with no storage accounts has no `Gap_st-*` columns. The order is fixed by catalog order, but two runs over different scopes are not necessarily column-for-column comparable.

## Severity and scoring

Each control carries a severity:

| Severity | Weight |
|---|---|
| Critical | 3 |
| High | 2 |
| Medium | 1 |

**The report does not publish a score or a risk weight.** Scoring is owned by the backend so the model can be tuned without reissuing reports; a number baked into the CSV would compete with it and go stale the moment the model changed. The file carries the raw observations instead — the per-control `Gap_<id>` results and the severity counts — which is everything needed to recompute any weighting downstream.

Rows are still *ordered* severity-first, then by data at risk, so the top of the file is a usable priority list. That ordering is derived at write time from the severity counts; it is a presentation choice, not a published judgment.

The console run summary still prints an overall score and a per-category breakdown for the operator watching the run. The same caveat applies to any such number: it is a percentage of what was **assessed**. A resource where only one control could be evaluated, and it passed, scores 100 — which is why `AssessedControls` / `UnassessedControls` matter more than any single figure. Unknown and N/A outcomes are excluded from both numerator and denominator, never counted as failures.

Controls fall into four categories: **RecoveryReady** (can you restore at all), **Availability** (does a regional failure take the data with it), **Immutability** (can it be deleted or encrypted by an attacker), and **DataExposure** (is it readable by the wrong people). A fifth category, **CleanRecovery** (are recovery points scanned for threats), has no native signal in any cloud — it is a Commvault capability, so it is reported as "requires Commvault" and never scored.

## The controls

### Azure

| Resource | Control | Sev | Category | What it checks |
|---|---|---|---|---|
| VM | `vm-backup` | High | RecoveryReady | Enrolled in a Recovery Services vault backup plan |
| VM | `vm-xregion` | High | Availability | Backups replicated to a secondary region |
| VM | `vm-immutable` | High | Immutability | Vault immutability enabled, so recovery points cannot be deleted |
| Disk | `disk-schedule` | High | RecoveryReady | Automated snapshot/backup schedule configured |
| Disk | `disk-cmek` | High | DataExposure | Encrypted with a customer-managed key |
| Storage | `st-versioning` | High | Immutability | Blob versioning on — prior versions survive overwrite |
| Storage | `st-softdelete` | High | Immutability | Blob soft delete on — deletions are recoverable |
| Storage | `st-immutable` | High | Immutability | Locked immutable-storage (WORM) policy |
| Storage | `st-xregion` | High | Availability | Geo-redundant (GRS/RA-GRS) rather than LRS |
| Storage | `st-cmek` | High | DataExposure | Customer-managed key encryption |
| Storage | `st-public` | High | DataExposure | Public blob access disabled |
| FileShare | `fs-backup` | **Critical** | RecoveryReady | Share enrolled in a backup plan / snapshots |
| FileShare | `fs-xregion` | High | Availability | Geo-redundant storage |
| FileShare | `fs-encrypted` | **Critical** | DataExposure | Encrypted at rest |
| SQL | `db-backup` | High | RecoveryReady | Automated backups enabled |
| SQL | `db-retention` | High | RecoveryReady | Retention ≥ 35 days |
| SQL | `db-pitr` | High | RecoveryReady | Point-in-time recovery available |
| SQL | `db-xregion` | High | Availability | Geo-redundant backup or geo-replica |
| SQL | `db-cmek` | High | DataExposure | TDE with a customer-managed key |
| SQL | `db-delprot` | High | Immutability | Deletion protection / resource lock |
| FlexDB (MySQL/PostgreSQL) | `fx-retention` | High | RecoveryReady | Retention ≥ 35 days |
| FlexDB | `fx-xregion` | High | Availability | Geo-redundant backup |
| FlexDB | `fx-cmek` | High | DataExposure | Customer-managed key encryption |
| Cosmos | `cos-pitr` | **Critical** | RecoveryReady | Continuous backup / PITR (vs periodic only) |
| Cosmos | `cos-xregion` | High | Availability | Geo-redundant / multi-region |
| Cosmos | `cos-cmek` | **Critical** | DataExposure | Customer-managed key encryption |
| Cosmos | `cos-delprot` | High | Immutability | Deletion protection / resource lock |
| AKS | `aks-backup` | **Critical** | RecoveryReady | Persistent volumes enrolled in a backup plan |
| AKS | `aks-secretenc` | High | DataExposure | etcd secrets encrypted at rest (CMK) |

### AWS

| Resource | Control | Sev | Category | What it checks |
|---|---|---|---|---|
| EC2 | `ec2-backup` | High | RecoveryReady | Covered by an AWS Backup plan |
| EC2 | `ec2-snapshots` | High | RecoveryReady | EBS snapshots exist for the attached volumes |
| EC2 | `ec2-recent` | High | RecoveryReady | Most recent recovery point < 7 days old |
| EC2 | `ec2-encrypted` | High | DataExposure | Every attached EBS volume encrypted |
| EC2 | `ec2-vaultlock` | High | Immutability | Recovery points held in a locked (immutable) AWS Backup vault |
| EBS | `ebs-encrypted` | High | DataExposure | Volume encrypted at rest (includes unattached volumes) |
| RDS | `rds-backup` | **Critical** | RecoveryReady | Automated backups enabled |
| RDS | `rds-retention` | High | RecoveryReady | Retention ≥ 35 days |
| RDS | `rds-pitr` | High | RecoveryReady | Point-in-time recovery available |
| RDS | `rds-vault` | Medium | RecoveryReady | Also covered by AWS Backup, beyond native automated backups |
| RDS | `rds-multiaz` | High | Availability | Multi-AZ deployment |
| RDS | `rds-encrypted` | High | DataExposure | Storage encrypted at rest |
| RDS | `rds-delprot` | High | Immutability | Deletion protection enabled |
| RDS | `rds-vaultlock` | High | Immutability | Recovery points held in a locked (immutable) AWS Backup vault (RDS / Aurora / DocumentDB) |
| S3 | `s3-versioning` | High | Immutability | Object versioning on |
| S3 | `s3-xregion` | High | Availability | Cross-region replication configured |
| S3 | `s3-encrypted` | High | DataExposure | Default server-side encryption |
| S3 | `s3-public` | **Critical** | DataExposure | Public access blocked |
| S3 | `s3-objectlock` | High | Immutability | Object Lock (WORM) enabled — objects cannot be deleted or overwritten |
| S3 | `s3-lifecycle` | Medium | RecoveryReady | A lifecycle policy exists |
| EFS | `efs-backup` | **Critical** | RecoveryReady | AWS Backup policy enabled on the file system |
| EFS | `efs-encrypted` | **Critical** | DataExposure | Encrypted at rest |
| DynamoDB | `ddb-pitr` | **Critical** | RecoveryReady | Point-in-time recovery enabled |
| DynamoDB | `ddb-vault` | Medium | RecoveryReady | Covered by an AWS Backup plan |
| DynamoDB | `ddb-vaultlock` | High | Immutability | Recovery points held in a locked (immutable) AWS Backup vault |
| Redshift | `rs-encrypted` | High | DataExposure | Cluster encrypted at rest |
| Redshift | `rs-retention` | High | RecoveryReady | Automated snapshot retention ≥ 7 days |

### Google Cloud

| Resource | Control | Sev | Category | What it checks |
|---|---|---|---|---|
| VM | `vm-backup` | High | RecoveryReady | Automated snapshot/backup schedule attached |
| VM | `vm-xregion` | High | Availability | Snapshots stored in a secondary region |
| VM | `vm-immutable` | High | Immutability | Recovery points protected by immutability |
| VM | `vm-delprot` | High | Immutability | Instance deletion protection enabled |
| Disk | `pd-schedule` | High | RecoveryReady | Automated snapshot schedule configured |
| Disk | `pd-xregion` | High | Availability | Snapshots replicated to a secondary region |
| Disk | `pd-cmek` | High | DataExposure | Customer-managed encryption key |
| Disk | `pd-nodelete` | High | Immutability | Data disk survives deletion of its VM |
| Storage | `gcs-versioning` | High | Immutability | Object versioning on |
| Storage | `gcs-softdelete` | High | Immutability | Soft delete retention configured |
| Storage | `gcs-lock` | High | Immutability | Locked Bucket Lock retention policy (WORM) |
| Storage | `gcs-xregion` | High | Availability | Multi-region or dual-region bucket |
| Storage | `gcs-cmek` | High | DataExposure | Customer-managed encryption key |
| Storage | `gcs-public` | High | DataExposure | Public access prevention enforced |
| Database | `db-backup` | High | RecoveryReady | Automated backups enabled |
| Database | `db-retention` | High | RecoveryReady | Retention ≥ 35 days (retained backups or tx-log days) |
| Database | `db-pitr` | High | RecoveryReady | Point-in-time recovery enabled |
| Database | `db-xregion` | High | Availability | Cross-region replica for DR |
| Database | `db-cmek` | High | DataExposure | Customer-managed encryption key |
| Database | `db-delprot` | High | Immutability | Deletion protection enabled |
| Database | `db-notpublic` | High | DataExposure | No public IP exposure |
| Filestore | `fs-backup` | **Critical** | RecoveryReady | Enrolled in a Filestore backup plan |
| Filestore | `fs-xregion` | High | Availability | Backups stored in a secondary region |
| Filestore | `fs-encrypted` | **Critical** | DataExposure | Encrypted at rest |
| GKE | `gke-backup` | **Critical** | RecoveryReady | Persistent volumes enrolled in a Backup for GKE plan |
| GKE | `gke-xregion` | High | Availability | Backups stored in a secondary region |
| GKE | `gke-secretenc` | High | DataExposure | Secrets encrypted at rest with CMEK |

Control definitions live in `src/common/CVSizing.Resilience.{Azure,AWS,GCP}.ps1`; the shared scoring engine is `src/common/CVSizing.Resilience.ps1`. Adding a control there automatically adds a `Gap_<id>` column to the report. Skip the whole pass with `-SkipResilienceReport`.

## JSON protection summary

The sizing JSON (`<cloud>_sizing_<timestamp>.json`, written by default — see the OutputFormat note in the README) carries a **headline** view of the same controls, so a downstream cloud posture report can read protection without parsing every `Gap_<id>`. Every resource in `workloads` gets a `protection` object using one shared vocabulary across all workload types and clouds — a status **word**, not a bare flag:

| Field | Category | Values |
|---|---|---|
| `backup` | RecoveryReady | `Protected` / `Unprotected` / `NotAssessed` |
| `retention_days` | RecoveryReady | integer, or `null` when unmeasured |
| `immutability` | Immutability | `Immutable` / `NotImmutable` / `NotAssessed` |
| `pitr` | RecoveryReady | `Enabled` / `NotEnabled` / `NotAssessed` |
| `public_exposure` | DataExposure | `Public` / `NotPublic` / `NotAssessed` |
| `cross_region` | Availability | `Protected` / `NotProtected` / `NotAssessed` |
| `overall` | — | `Protected` / `PartiallyProtected` / `Unprotected` / `NotAssessed` |

The mapping from control outcome to label is fixed: a satisfied control (Clean) → the positive word, a failed control (Gap) → the negative word, and Unknown / not-applicable → `NotAssessed`. As in the CSV, **`NotAssessed` is never a pass** — a signal that does not apply to a type, or that could not be evaluated, is never reported as a negative. `overall` is `Unprotected` when there is no native backup, `Protected` when backup is present and no assessed signal is negative, and `PartiallyProtected` otherwise. A top-level `protection_summary` rolls these up per workload type and overall (`coverage_pct` counts only resources whose backup was actually assessed). This catalog remains the single source of truth for the terminology.
