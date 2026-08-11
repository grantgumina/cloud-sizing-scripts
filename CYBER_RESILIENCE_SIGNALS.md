# Cyber Resilience Signal Export

This is a reference for the resilience data produced by the AWS, Azure and Google Cloud scripts.

See [README.md](README.md) for installation and how to run the scripts.

Each run writes `Output/<cloud>_<timestamp>/<cloud>_resilience_signals_<timestamp>.csv` — **one row per resource**
of an assessed type with the relevant configuration values read from the cloud API.

## Reading the file

| Column | Meaning |
|---|---|
| `Scope` | Subscription (Azure), project (GCP) or account (AWS) |
| `ResourceGroup` | Resource group / equivalent grouping. Blank where the resource has none |
| `ResourceType` | Classification of the resource
| `ResourceName` | Resource name |
| `ParentResource` | Server for a database, storage account for a file share. Blank otherwise. |
| `Region` | Region / location |
| `ResourceId` | ARM ID (Azure), ARN (AWS), self-link (GCP). Blank where the type does not expose one |
| `SizeGB` / `SizeTB` | Size. **Blank means unmeasured, not zero** — a resource we could not size is not a small one |
| `BackupDataStatus` | Whether backup collection succeeded for this scope: `Ok` / `Failed` / `Skipped` |
| `SnapshotDataStatus` | Same for snapshot collection |
| *signal columns* | The raw configuration values, named exactly as collected. See the tables below |

**A blank signal means the value was not collected** — the API was not reachable, permission was denied, the
service was not requested via `-Types`, or the signal does not apply to that resource type. `FALSE` and blank are distinct.

**The schema is fixed.** Every column below is emitted on every run regardless of what resource type, so the
header is identical between runs. Because one file contains information for every resource type, most cells are blank
by design — e.g. a VM row populates only the VM signals.

## Signals by cloud and resource type


### Azure

| Resource type | Signal | Collected | Values / meaning |
|---|---|---|---|
| **VM** | `BackupEnabled` | ✅ | `TRUE`/`FALSE` — protected by a Recovery Services vault backup item |
| | `BackupCrossRegion` | ❌ not yet | Needs the vault's cross-region-restore setting |
| | `BackupImmutable` | ❌ not yet | Needs the vault's immutability setting |
| **Disk** | `CmkEncrypted` | ✅ | `TRUE`/`FALSE` — from `Encryption.Type`; both `…WithCustomerKey` and `…WithPlatformAndCustomerKeys` count as CMK. Blank if the disk exposes no encryption block |
| **Storage** | `BlobVersioning` | ✅ | `TRUE`/`FALSE` — prior blob versions survive overwrite |
| | `SoftDeleteEnabled` | ✅ | `TRUE`/`FALSE` — deleted blobs are recoverable |
| | `ImmutabilityLocked` | ✅ | `TRUE` only when a **locked** policy is in force; an unlocked policy can be removed, so it is not WORM |
| | `StorageAccountSkuName` | ✅ | e.g. `Standard_LRS`, `Standard_GRS`, `Standard_RAGRS`, `Standard_GZRS` — `GRS`/`GZRS` indicate geo-redundancy |
| | `CmkEncrypted` | ✅ | `TRUE`/`FALSE` |
| | `PublicAccessBlocked` | ✅ | `TRUE` = public blob access is disabled (note the polarity) |
| **FileShare** | `HasBackup` | ✅ | `TRUE`/`FALSE` — share enrolled in a backup plan |
| | `StorageAccountSkuName` | ✅ | As above, for the parent account |
| | `EncryptedAtRest` | ✅ | `TRUE`/`FALSE` (Azure Files is SSE-encrypted by default) |
| **SQL** | `PITR_Days` | ✅ | Integer days of point-in-time recovery. `0`/blank means none |
| | `LTRWeeklyRetention` / `LTRMonthlyRetention` | ✅ | ISO-8601 durations, e.g. `P4W`, `P12M` |
| | `LTRYearlyRetention` | ❌ not yet | The cmdlet returns it; the inventory row does not capture it |
| | `BackupStorageRedundancy` | ✅ | `Local` / `Zone` / `Geo` / `GeoZone` |
| | `CmkEncrypted` | ✅ | `TRUE`/`FALSE` — TDE protector is a **server**-level setting (`AzureKeyVault` vs `ServiceManaged`), so every database on a server carries the same value |
| | `DeletionProtected` | ❌ not yet | Needs `Get-AzResourceLock` |
| **FlexDB** (MySQL / PostgreSQL) | `BackupRetentionDays` | ✅ | Integer days |
| | `GeoRedundantBackup` | ✅ | `Enabled` / `Disabled` |
| | `CmkEncrypted` | ⚠️ module-dependent | `TRUE`/`FALSE` where the installed `Az.MySql`/`Az.PostgreSql` exposes data encryption (`DataEncryptionType` or `DataEncryption.Type`), **blank where it does not** — several current versions expose no encryption property on the flexible-server model at all. Blank means unread, not platform-key |
| **Cosmos** | `BackupPolicyBackupType` | ✅ | `Periodic` / `Continuous` — continuous is PITR |
| | `BackupPolicyBackupStorageRedundancy` | ✅ | `Local` / `Zone` / `Geo`. Blank on continuous-backup accounts, where it does not apply |
| | `CmkEncrypted` | ✅ | `TRUE`/`FALSE` — derived from `KeyVaultKeyUri`, which is present only for CMK accounts |
| | `DeletionProtected` | ❌ not yet | Needs `Get-AzResourceLock` |
| **AKS** | `HasBackupPlan` | ✅ | `TRUE`/`FALSE` — persistent volumes enrolled in a backup plan |
| | `SecretsEncryptionCmk` | ❌ not yet | Needs `SecurityProfile.AzureKeyVaultKms` |

### AWS

Every AWS signal is collected today.

| Resource type | Signal | Values / meaning |
|---|---|---|
| **EC2** | `AWSBackupProtected` | `TRUE`/`FALSE` — the instance ARN appears in the region's AWS Backup protected-resource list |
| | `ProtectionStatus` | `Protected` / `Snapshot-Only` / `Unprotected` / `Unknown`. `Unknown` means the AWS Backup list could not be read |
| | `EBSSnapshotCount` | Integer count of snapshots of the attached volumes |
| | `DaysSinceLastBackup` | Integer days since the newest snapshot. Blank when none exist |
| | `AllVolumesEncrypted` | `TRUE`/`FALSE` across every attached volume |
| **EBS** | `Encrypted` | `TRUE`/`FALSE` — includes unattached volumes |
| **RDS** | `AutomatedBackupsEnabled` | `TRUE`/`FALSE` |
| | `BackupRetentionDays` | Integer days |
| | `PITREnabled` | `TRUE`/`FALSE` |
| | `AWSBackupProtected` | `TRUE`/`FALSE` — covered by AWS Backup in addition to native automated backups |
| | `MultiAZ` | `TRUE`/`FALSE` |
| | `StorageEncrypted` | `TRUE`/`FALSE` |
| | `DeletionProtection` | `TRUE`/`FALSE` |
| **S3** | `VersioningStatus` | `Enabled` / `Suspended` / blank |
| | `ReplicationEnabled` | `TRUE`/`FALSE` — cross-region replication configured |
| | `ServerSideEncryption` | e.g. `AES256`, `aws:kms`, `None` |
| | `PublicAccessBlocked` | `TRUE` = public access blocked (note the polarity) |
| | `LifecycleRuleCount` | Integer count of lifecycle rules |
| **EFS** | `BackupPolicyStatus` | `ENABLED` / `DISABLED` / `Unknown` |
| | `Encrypted` | `TRUE`/`FALSE` |
| **DynamoDB** | `PITREnabled` | `TRUE`/`FALSE` |
| | `AWSBackupProtected` | `TRUE`/`FALSE` |
| **Redshift** | `Encrypted` | `TRUE`/`FALSE` |
| | `AutomatedSnapshotRetentionDays` | Integer days |

### Google Cloud

| Resource type | Signal | Collected | Values / meaning |
|---|---|---|---|
| **VM** | `XRegionBackup` | ✅ | `TRUE`/`FALSE` — a snapshot of one of its disks is stored outside the disk's region |
| | `DeletionProtection` | ✅ | `TRUE`/`FALSE` — instance deletion protection |
| | `HasSnapshotSchedule` | ❌ not yet | Needs the disk's `resourcePolicies`. Distinct from snapshots merely existing |
| | `BackupImmutable` | ❌ not yet | GCP exposes no per-disk snapshot immutability |
| **Disk** | `XRegionBackup` | ✅ | As above, per disk |
| | `CmkEncrypted` | ✅ | `TRUE`/`FALSE` — customer-managed encryption key |
| | `HasSnapshotSchedule` | ❌ not yet | Needs `resourcePolicies` |
| | `SurvivesVmDelete` | ❌ not yet | Needs the instance attachment's `autoDelete` flag |
| **Storage** (GCS) | `Versioning` | ✅ | `TRUE`/`FALSE` — object versioning |
| | `SoftDeleteEnabled` | ✅ | `TRUE`/`FALSE` — soft-delete retention configured |
| | `RetentionLocked` | ✅ | `TRUE`/`FALSE` — Bucket Lock retention policy is locked (WORM) |
| | `MultiRegion` | ✅ | `TRUE` when the location type is multi-region or dual-region |
| | `CmkEncrypted` | ✅ | `TRUE`/`FALSE` |
| | `PublicAccessBlocked` | ✅ | `TRUE` = public access prevention enforced (note the polarity) |
| **Database** (Cloud SQL) | `BackupEnabled` | ✅ | `TRUE`/`FALSE` — automated backups |
| | `RetainedBackups` | ✅ | Integer count of retained automated backups |
| | `TxLogRetentionDays` | ✅ | Integer days of transaction-log retention |
| | `PitrEnabled` | ✅ | `TRUE`/`FALSE` |
| | `HasReplica` | ✅ | `TRUE`/`FALSE` — a cross-region replica exists |
| | `CmkEncrypted` | ✅ | `TRUE`/`FALSE` |
| | `DeletionProtection` | ✅ | `TRUE`/`FALSE` |
| | `PublicIPs` | ✅ | Semicolon-separated public IPs. **Empty string means none** — distinct from blank (not collected) |
| **Filestore** | `HasBackup` | ✅ | `TRUE`/`FALSE` — a Filestore backup exists in the project |
| | `EncryptedAtRest` | ✅ | `TRUE`/`FALSE` (encrypted by default) |
| | `BackupXRegion` | ❌ not yet | Needs backup location vs instance location |
| **GKE** | `HasBackupPlan` | ✅ | `TRUE`/`FALSE` — Backup for GKE plan covers the cluster |
| | `BackupXRegion` | ❌ not yet | Needs the backup plan's region |
| | `SecretsEncryptionCmk` | ❌ not yet | Needs `databaseEncryption` from cluster describe |


## Where this lives in the code

Signal definitions come from the control catalog in `src/common/CVSizing.Resilience.{Azure,AWS,GCP}.ps1`. The
export derives its columns by reading each control's `Test` block, so **adding a control automatically adds its
signal column** — there is no second list to keep in step. The export itself is
`New-CVSignalRow` / `Get-CVSignalColumns` / `Sort-CVSignalRows` in `src/common/CVSizing.Resilience.ps1`.

The controls' pass/fail thresholds (for example "retention ≥ 35 days") remain in those files as a record of intent
for the backend to implement. The scripts no longer evaluate them.

Skip the pass entirely with `-SkipResilienceReport`.
