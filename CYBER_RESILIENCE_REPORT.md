# Cloud Resilience Control Catalog

Reference for the native-protection signals the AWS, Azure and Google Cloud sizing scripts collect, and how they
roll up into the raw `protection` data in the sizing output.

See [README.md](README.md) for installation and how to run the scripts.

Every run evaluates each discovered resource against this control catalog and records **raw protection data** —
the customer's current native cloud configuration, as-is. It is not a Commvault plan state and says nothing about
what Commvault would do; it describes what exists today. All scoring, gap-severity ranking, and interpretation are
owned by the downstream **report generator**, so the sizing deliverables stay raw and stable.

## What the output carries

Each resource carries the raw protection fields **that apply to its workload type** — flat columns on the
inventory CSV/Excel rows and a nested `protection` object in `<cloud>_sizing_<timestamp>.json`:

| Field | Type | Derived from (control category) | Applies to |
|---|---|---|---|
| `backup_enabled` | bool / null | enrolled in a native backup/snapshot plan (RecoveryReady) | backup-capable types |
| `backup_retention_days` | int / null | retention of that backup, when the API reports a day count | types with a retention concept (mostly DBs) |
| `backup_immutable` | bool / null | recovery target is locked — vault immutability / object-lock / bucket-lock (Immutability) | types with a lock/vault control |
| `pitr_enabled` | bool / null | point-in-time recovery available (RecoveryReady) | **DB types only** |
| `public_access_blocked` | bool / null | resource is **not** publicly reachable (DataExposure) | **object storage / DBs only** |
| `cross_region_backup` | bool / null | backups reach a second region, surviving a regional outage (Availability) | types with a cross-region control |

A field is emitted **only for workload types where it applies** — i.e. where the type's control catalog (below)
defines a control feeding it. Inapplicable fields are **omitted entirely**, not shown as `null` (a VM has no
`pitr_enabled`, a database server has no `public_access_blocked` only when its catalog lacks that control). A type
with no applicable fields (e.g. an unattached EBS volume) gets no `protection` object at all.

For an applicable field the values are raw: `true` = the control was satisfied, `false` = checked and not
satisfied, `null` = **measured nothing** (the API call could not be made / the signal was not collected). `null`
is never a negative — treating "we could not look" as "not protected" would overstate exposure, so an unmeasured
applicable signal stays `null`, not `false`. There is no score, severity, or overall label in the output; the
report generator derives those from these raw fields plus the control catalog below.

The catalog below is the reference for how each field is derived and which severity the report generator should
attach. Controls fall into four categories: **RecoveryReady** (can you restore at all), **Availability** (does a
regional failure take the data with it), **Immutability** (can it be deleted or encrypted by an attacker), and
**DataExposure** (is it readable by the wrong people). A fifth, **CleanRecovery** (recovery points scanned for
threats), has no native cloud signal — it is a Commvault capability, not scored here.


## The controls

### Azure

| Resource | Control | Sev | Category | What it checks |
|---|---|---|---|---|
| VM | `vm-backup` | High | RecoveryReady | Enrolled in a Recovery Services vault backup plan |
| VM | `vm-xregion` | High | Availability | Backups replicated to a secondary region |
| VM | `vm-immutable` | High | Immutability | Vault immutability enabled, so recovery points cannot be deleted |
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

Control definitions live in `src/common/CVSizing.Resilience.{Azure,AWS,GCP}.ps1`; the shared engine is `src/common/CVSizing.Resilience.ps1`, where `Get-CVProtectionData` maps these control outcomes to the six raw fields (see [What the output carries](#what-the-output-carries)): `Met → true`, `Gap → false`, `Unknown`/`NA` → `null`. Skip the whole pass with `-SkipResilienceReport`.

The `Severity` column above is not emitted anywhere in the output — it is documentation for the report generator, which owns all scoring and severity ranking.
