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
| `LockDataStatus` | **Azure only.** Resource-lock read (deletion protection). Blank column on AWS/GCP |
| `VaultSettingsDataStatus` | **Azure only.** Recovery Services vault posture read — tracked apart from `BackupDataStatus` because listing backup *items* and reading vault *settings* can fail independently |
| `LtrDataStatus` | **Azure only.** SQL long-term-retention policy read |
| `AksBackupDataStatus` | **Azure only.** DataProtection backup-instance read (Backup for AKS) |
| `VaultLockDataStatus` | **AWS only.** AWS Backup Vault Lock read (region-scoped) |
| `S3PostureDataStatus` | **AWS only.** Per-bucket posture reads: `Ok` (all six succeeded) / `Partial` / `Failed`. Six independent calls back the S3 signals, so one can fail while the rest succeed — this says which rows to distrust |
| *signal columns* | The raw configuration values, named exactly as collected. See the tables below |

**A blank signal means the value was not collected** — the API was not reachable, permission was denied, the
service was not requested via `-Types`, or the signal does not apply to that resource type. `FALSE` and blank are distinct.

Because blank carries that single meaning, **a measured absence is written as the token `None`**, never as an empty
cell. `ResourceLockLevel = None` means "we read the locks and none apply"; blank means we could not read them.

### Not applicable vs not collected

Some signals describe a *parent* the resource may not have. A VM's `BackupImmutabilityState` comes from the
Recovery Services vault protecting it, so an unprotected VM has no vault to describe. Read the pair:

| `BackupDataStatus` | `BackupEnabled` | Vault signal blank because… |
|---|---|---|
| `Ok` | `FALSE` | **Not applicable** — we looked, the VM has no backup vault |
| `Failed` / `Skipped` | blank | **Not collected** — we could not look |

Treating the first row as unassessed will overstate how much of the estate went unevaluated.

AWS has the same pattern in a different place. `DaysSinceLastBackup` blank can mean *no recovery point exists*
(measured) or *the AWS Backup protected-resource list could not be read*. `BackupDataStatus` on the same row
separates them, and `VaultLockDataStatus` does the same for `BackupVaultAnyLocked`:

| `BackupDataStatus` | `DaysSinceLastBackup` | Means |
|---|---|---|
| `Ok` | blank | **Measured** — no recovery point exists for this resource |
| `Failed` | blank | **Not collected** — the AWS Backup list could not be read |

**The schema is fixed.** Every column below is emitted on every run regardless of what resource type, so the
header is identical between runs. Because one file contains information for every resource type, most cells are blank
by design — e.g. a VM row populates only the VM signals.

## Signals by cloud and resource type


### Azure

| Resource type | Signal | Collected | Values / meaning |
|---|---|---|---|
| **VM** | `BackupEnabled` | ✅ | `TRUE`/`FALSE` — protected by a Recovery Services vault backup item |
| | `BackupCrossRegionRestore` | ✅ | `Enabled` / `Disabled` — from the vault that actually protects this VM. Blank when the VM has no vault (see *not applicable* above) |
| | `BackupImmutabilityState` | ✅ | `Disabled` / `Unlocked` / `Locked`. **Only `Locked` is WORM** — an `Unlocked` policy can simply be removed, the same standard `ImmutabilityLocked` applies to storage |
| | `BackupVaultSoftDeleteState` | ✅ | `Enabled` / `Disabled` / `AlwaysON`. `AlwaysON` cannot be turned off, so it is the strongest state |
| | `BackupVaultMultiUserAuth` | ✅ | Resource Guard state. This is the control that stops an attacker holding vault permissions from shortening retention and then deleting backups |
| | `BackupVaultStorageRedundancy` | ✅ | `GeoRedundant` / `ZoneRedundant` / `LocallyRedundant` |
| **Disk** | `CmkEncrypted` | ✅ | `TRUE`/`FALSE` — from `Encryption.Type`; both `…WithCustomerKey` and `…WithPlatformAndCustomerKeys` count as CMK. Blank if the disk exposes no encryption block |
| **Storage** | `BlobVersioning` | ✅ | `TRUE`/`FALSE` — prior blob versions survive overwrite |
| | `SoftDeleteEnabled` | ✅ | `TRUE`/`FALSE` — deleted blobs are recoverable |
| | `ImmutabilityLocked` | ✅ | `TRUE` only when a **locked** policy is in force; an unlocked policy can be removed, so it is not WORM |
| | `StorageAccountSkuName` | ✅ | e.g. `Standard_LRS`, `Standard_GRS`, `Standard_RAGRS`, `Standard_GZRS` — `GRS`/`GZRS` indicate geo-redundancy |
| | `CmkEncrypted` | ✅ | `TRUE`/`FALSE` |
| | `PublicAccessBlocked` | ✅ | `TRUE` = public blob access is disabled (note the polarity) |
| **FileShare** | `HasBackup` | ✅ | `TRUE`/`FALSE` — this **share** is enrolled in a Recovery Services backup plan. Attributed per share, not per storage account, so two shares in one account report independently |
| | `StorageAccountSkuName` | ✅ | As above, for the parent account |
| | `EncryptedAtRest` | ✅ | `TRUE`/`FALSE` (Azure Files is SSE-encrypted by default) |
| **SQL** | `PITR_Days` | ✅ | Integer days of point-in-time recovery. `0`/blank means none |
| | `LTRWeeklyRetention` / `LTRMonthlyRetention` | ✅ | ISO-8601 durations, e.g. `P4W`, `P12M` |
| | `LTRYearlyRetention` | ✅ | ISO-8601 duration, e.g. `P1Y`. Was always fetched and discarded before being captured |
| | `LTRTimeBasedImmutability` | ✅ | Long-term-retention backup immutability, from the same policy object |
| | `BackupStorageRedundancy` | ✅ | `Local` / `Zone` / `Geo` / `GeoZone` |
| | `CmkEncrypted` | ✅ | `TRUE`/`FALSE` — TDE protector is a **server**-level setting (`AzureKeyVault` vs `ServiceManaged`), so every database on a server carries the same value |
| | `ResourceLockLevel` | ✅ | `CanNotDelete` / `ReadOnly` / `None`, `;`-joined when locks at several scopes apply. Locks **inherit downward**, so a lock on the server, resource group or subscription protects the database. See the caveat below |
| **FlexDB** (MySQL / PostgreSQL) | `BackupRetentionDays` | ✅ | Integer days |
| | `GeoRedundantBackup` | ✅ | `Enabled` / `Disabled` |
| | `CmkEncrypted` | ⚠️ module-dependent | `TRUE`/`FALSE` where the installed `Az.MySql`/`Az.PostgreSql` exposes data encryption (`DataEncryptionType` or `DataEncryption.Type`), **blank where it does not** — several current versions expose no encryption property on the flexible-server model at all. Blank means unread, not platform-key |
| **Cosmos** | `BackupPolicyBackupType` | ✅ | `Periodic` / `Continuous` — continuous is PITR |
| | `BackupPolicyBackupStorageRedundancy` | ✅ | `Local` / `Zone` / `Geo`. Blank on continuous-backup accounts, where it does not apply |
| | `CmkEncrypted` | ✅ | `TRUE`/`FALSE` — derived from `KeyVaultKeyUri`, which is present only for CMK accounts |
| | `ResourceLockLevel` | ✅ | As for SQL above |
| **AKS** | `HasBackupPlan` | ✅ | `TRUE`/`FALSE` — a DataProtection **Backup vault** backup instance targets this cluster. A subscription with zero Backup vaults is a conclusive `FALSE`, not a guess |
| | `SecretsEncryptionCmk` | ✅ | `TRUE`/`FALSE` — `SecurityProfile.AzureKeyVaultKms.Enabled`. `FALSE` means **no customer-managed key**; AKS always encrypts etcd with a platform key, so it does not mean "unencrypted" |
| | `NodeDiskEncryptionSetId` | ✅ | Disk-encryption-set ARM ID, or `None` when node disks use platform keys |

#### `ResourceLockLevel = None` does not mean "deletable"

Azure blocks deletion by several mechanisms and only one of them is a lock. **Deny assignments** (from Blueprints
or managed applications) and Azure Policy **`DenyAction`** both prevent deletion with no lock present, and neither
appears here. Read `None` as "no resource lock applies", not as "this resource can be deleted".

Note also that Azure's real delete behaviour cascades: deleting a SQL server whose *database* carries
`CanNotDelete` fails. The export therefore publishes `ResourceLockScope` (the scope each matched lock is defined
at) and `ResourceLockCount` alongside the level, so ancestor, self and descendant locks can be told apart rather
than collapsed into one verdict here.

#### Azure permissions these signals need

All reads, all covered by the built-in **Reader** role at subscription scope. Nothing needs write access and
nothing needs a custom role. Where a permission is missing the run records it and leaves the column blank — it
never reports a gap it could not verify.

| Operation | Signals it feeds | Narrower built-in role that also covers it |
|---|---|---|
| `Microsoft.Authorization/locks/read` | `ResourceLockLevel` (SQL, Cosmos) | none — Reader, or a custom role |
| `Microsoft.RecoveryServices/vaults/read` | `BackupImmutabilityState`, `BackupCrossRegionRestore`, `BackupVault*` | Backup Reader |
| `Microsoft.DataProtection/backupVaults/read` and `.../backupInstances/read` | `HasBackupPlan` (AKS) | Backup Reader |
| `Microsoft.ContainerService/managedClusters/read` | `SecretsEncryptionCmk`, `NodeDiskEncryptionSetId` | already required |

### AWS

Every AWS signal is collected today.

| Resource type | Signal | Values / meaning |
|---|---|---|
| **EC2** | `AWSBackupProtected` | `TRUE`/`FALSE` — matched by AWS Backup `ResourceType` + exact ARN segment. Blank when the region's protected-resource list could not be read (never `FALSE`) |
| | `ProtectionStatus` | `Protected` / `Snapshot-Only` / `Unprotected` / `Unknown` |
| | `EBSSnapshotCount` | Integer count of snapshots of the attached volumes |
| | `DaysSinceLastBackup` | Integer days since the newest recovery point from **either** an EBS snapshot or AWS Backup. Blank when none exist |
| | `AwsBackupLastBackupUtc` | ISO-8601 UTC of the AWS Backup recovery point, from `ProtectedResource.LastBackupTime` |
| | `AllVolumesEncrypted` | `TRUE`/`FALSE` across every attached volume |
| | `BackupVaultAnyLocked` | `TRUE` when **any** AWS Backup vault in the region has Vault Lock enabled — see the note below |
| | `BackupVaultLockedCount` / `BackupVaultMinRetentionDays` | Locked vault count, and the shortest minimum retention among them |
| **EBS** | `Encrypted` | `TRUE`/`FALSE` — includes unattached volumes |
| **RDS** | `AutomatedBackupsEnabled` | `TRUE`/`FALSE`. Blank when `BackupRetentionPeriod` was not reported |
| | `BackupRetentionDays` | Integer days. **Blank, not 0**, when unreported — 0 would assert "no backups" |
| | `PITREnabled` | `TRUE`/`FALSE` — RDS PITR is active whenever automated backups are |
| | `AWSBackupProtected` | `TRUE`/`FALSE` — covered by AWS Backup in addition to native automated backups. Blank when the list could not be read |
| | `AwsBackupLastBackupUtc` | ISO-8601 UTC of the last AWS Backup recovery point |
| | `MultiAZ`, `StorageEncrypted`, `DeletionProtection` | `TRUE`/`FALSE`. **Blank, not `FALSE`**, when the API did not report the field |
| | `BackupVaultAnyLocked` etc. | As for EC2 |
| **S3** | `VersioningStatus` | `Enabled` / `Suspended` / `Off` / `Unknown`. The SDK reports never-versioned buckets as `Off` (measured); `Unknown` means the read failed |
| | `MfaDeleteEnabled` | `TRUE`/`FALSE` — MFA required to delete a version. From the same versioning response |
| | `PublicAccessBlocked` | `TRUE` only when all four blocks below are on (note the polarity). Kept as a rollup |
| | `BlockPublicAcls`, `BlockPublicPolicy`, `IgnorePublicAcls`, `RestrictPublicBuckets` | The four raw booleans. These say **which** protection is missing, which the rollup alone cannot |
| | `ReplicationEnabled` | `TRUE`/`FALSE` — cross-region replication. **Blank** when the read failed |
| | `ServerSideEncryption` | e.g. `AES256`, `aws:kms`, `None`, `Unknown`. `None` is measured; `Unknown` means the read failed |
| | `LifecycleRuleCount` | Integer count. **Blank, not 0**, when the read failed |
| | `ObjectLockEnabled` | `Enabled` / `None` / `Unknown` — **S3's WORM control**, and AWS's object-storage immutability signal |
| | `ObjectLockMode` / `ObjectLockRetentionDays` | `GOVERNANCE` or `COMPLIANCE`, and the default retention window |
| **EFS** | `BackupPolicyStatus` | `ENABLED` / `DISABLED` / `Unknown` |
| | `Encrypted` | `TRUE`/`FALSE` |
| | `AWSBackupProtected` / `AwsBackupLastBackupUtc` | AWS Backup coverage for the file system, matched on its ARN |
| | `ReplicationStatus` | `Configured` / `None` / `Unknown` — cross-region replication |
| | `BackupVaultAnyLocked` etc. | As for EC2 |
| **DynamoDB** | `PITREnabled` | `TRUE`/`FALSE`. **Blank** when the continuous-backups call failed |
| | `PITRRecoveryPeriodDays` | How far back PITR can restore, not merely whether it is on |
| | `AWSBackupProtected` / `AwsBackupLastBackupUtc` | AWS Backup coverage. **This was previously never set at all**, so the `ddb-vault` control was permanently Unknown |
| | `SSEType` / `SSEStatus` | `KMS` when a customer-managed key is used, `None` when only AWS-owned default encryption applies. DynamoDB is **always** encrypted, so `None` means "no CMK", not "unencrypted" |
| | `DeletionProtection` | `TRUE`/`FALSE` |
| | `ReplicaRegionCount` | Global-table replicas in other regions — DynamoDB's cross-region redundancy |
| | `BackupVaultAnyLocked` etc. | As for EC2 |
| **Redshift** | `Encrypted` | `TRUE`/`FALSE` |
| | `AutomatedSnapshotRetentionDays` | Integer days |
| | `ManualSnapshotRetentionDays` | Integer days. **`-1` means "retain indefinitely"** — the strongest setting, not a missing one |
| | `MultiAZ` | `Enabled` / `Disabled` — a **string**, not a boolean |

#### AWS Backup Vault Lock is region-scoped, not per resource

`BackupVaultAnyLocked` answers *"is any AWS Backup vault in this region locked"*, not *"are this resource's
recovery points immutable"*. A resource's recovery points can span vaults and the protected-resource list does not
say which vault holds them, so a per-resource answer would be a guess. Vault Lock in compliance mode prevents
recovery points being deleted or their retention shortened even by an administrator — the AWS equivalent of an
Azure Recovery Services vault with immutability **Locked**.

#### Two AWS-specific traps

**S3 signals absence by throwing.** `get-object-lock-configuration`, replication, lifecycle and default encryption
all raise a `...NotFound` error when the feature was never configured, rather than returning an empty object. Those
specific error codes are treated as a **measured** `None`; any other failure (`AccessDenied`, throttling) leaves
the signal blank. Getting this backwards in either direction is wrong: a blanket `FALSE` invents a gap, a blanket
blank hides a real one.

**Encryption polarity differs by service.** For S3 and EBS, `FALSE` means genuinely unencrypted. For DynamoDB it
means *no customer-managed key* — the table is still encrypted with an AWS-owned key. Same for AKS etcd on Azure.

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
