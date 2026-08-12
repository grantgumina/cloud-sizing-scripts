#requires -Version 7.2
<#  Dependency-free tests for the AWS control catalog (src/common/CVSizing.Resilience.AWS.ps1).

    The point of these is the Unknown boundary. An AWS Backup list we failed to read, or an EFS backup policy
    that came back 'Unknown', must NOT score as a gap - reporting a customer as unprotected on evidence we never
    collected is worse than reporting nothing.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.AWS.ps1')
. (Join-Path $PSScriptRoot 'CVTestControlEvaluator.ps1')

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }

$C = Get-CVAwsResilienceControls
function Outcome { param($Set, $Id, $Row)
    $ev = Invoke-CVResilience -Resource $Row -Controls $Set
    ($ev.Results | Where-Object Id -eq $Id).Outcome }

Write-Host "`n[1] Catalog shape"
Assert-CV 'resource types present' (($C.Keys | Sort-Object) -join ',') 'DynamoDB,EBS,EC2,EFS,RDS,Redshift,S3'
Assert-CV 'no Clean Recovery controls (matches GCP/Azure)' `
          (@($C.Values | ForEach-Object { $_ } | Where-Object { $_.Category -eq 'CleanRecovery' }).Count) 0

Write-Host "`n[2] EC2 - protected vs gap vs unknown"
$prot = [pscustomobject]@{ ProtectionStatus='Protected'; AWSBackupProtected=$true;  EBSSnapshotCount=3; DaysSinceLastBackup=1; AllVolumesEncrypted=$true }
$gap  = [pscustomobject]@{ ProtectionStatus='Unprotected'; AWSBackupProtected=$false; EBSSnapshotCount=0; DaysSinceLastBackup=$null; AllVolumesEncrypted=$false }
Assert-CV 'ec2-backup met'          (Outcome $C.EC2 'ec2-backup'    $prot) 'Met'
Assert-CV 'ec2-snapshots met'       (Outcome $C.EC2 'ec2-snapshots' $prot) 'Met'
Assert-CV 'ec2-recent met (1 day)'  (Outcome $C.EC2 'ec2-recent'    $prot) 'Met'
Assert-CV 'ec2-backup gap'          (Outcome $C.EC2 'ec2-backup'    $gap)  'Gap'
Assert-CV 'ec2-snapshots gap'       (Outcome $C.EC2 'ec2-snapshots' $gap)  'Gap'
Assert-CV 'ec2-recent unknown (never backed up -> not measurable)' (Outcome $C.EC2 'ec2-recent' $gap) 'Unknown'

Write-Host "`n[3] EC2 - an unreadable AWS Backup list is Unknown, never a gap"
# This is the regression that mattered: a wrong cmdlet name made every instance look unprotected.
$unk = [pscustomobject]@{ ProtectionStatus='Unknown'; AWSBackupProtected=$false; EBSSnapshotCount=0; DaysSinceLastBackup=$null; AllVolumesEncrypted=$null }
Assert-CV 'ec2-backup unknown when lookup failed' (Outcome $C.EC2 'ec2-backup'    $unk) 'Unknown'
Assert-CV 'ec2-encrypted unknown when unread'     (Outcome $C.EC2 'ec2-encrypted' $unk) 'Unknown'
$ev = Invoke-CVResilience -Resource $unk -Controls $C.EC2
Assert-CV 'snapshot gap still scored (that signal WAS read)' $ev.GapCount 1
# 4, not 3: ec2-vaultlock was added and this synthetic row carries no BackupVaultAnyLocked, so it is Unknown
# too. The point of the assertion is unchanged - unread signals are EXCLUDED, never counted as gaps.
Assert-CV 'unread signals excluded as unknown'                $ev.UnknownCount 4
Assert-CV 'and still exactly one real gap'                    $ev.GapCount 1

Write-Host "`n[4] RDS retention boundary + Multi-AZ"
$r34 = [pscustomobject]@{ AutomatedBackupsEnabled=$true; BackupRetentionDays=34; PITREnabled=$true; MultiAZ=$false; StorageEncrypted=$true; DeletionProtection=$true }
$r35 = [pscustomobject]@{ AutomatedBackupsEnabled=$true; BackupRetentionDays=35; PITREnabled=$true; MultiAZ=$true;  StorageEncrypted=$true; DeletionProtection=$true }
Assert-CV 'retention 34 -> Gap' (Outcome $C.RDS 'rds-retention' $r34) 'Gap'
Assert-CV 'retention 35 -> Met' (Outcome $C.RDS 'rds-retention' $r35) 'Met'
Assert-CV 'multi-az gap'        (Outcome $C.RDS 'rds-multiaz'   $r34) 'Gap'
Assert-CV 'retention unknown when field absent' (Outcome $C.RDS 'rds-retention' ([pscustomobject]@{})) 'Unknown'

Write-Host "`n[5] S3 - versioning string, public access, encryption"
$b = [pscustomobject]@{ VersioningStatus='Enabled'; ReplicationEnabled=$false; ServerSideEncryption='AES256'; PublicAccessBlocked=$true; LifecycleRuleCount=0 }
Assert-CV 's3-versioning met'  (Outcome $C.S3 's3-versioning' $b) 'Met'
Assert-CV 's3-xregion gap'     (Outcome $C.S3 's3-xregion'    $b) 'Gap'
Assert-CV 's3-encrypted met'   (Outcome $C.S3 's3-encrypted'  $b) 'Met'
Assert-CV 's3-public met'      (Outcome $C.S3 's3-public'     $b) 'Met'
Assert-CV 's3-lifecycle gap'   (Outcome $C.S3 's3-lifecycle'  $b) 'Gap'
Assert-CV 's3-encrypted gap when None' (Outcome $C.S3 's3-encrypted' ([pscustomobject]@{ ServerSideEncryption='None' })) 'Gap'
Assert-CV 's3-versioning unknown when unread' (Outcome $C.S3 's3-versioning' ([pscustomobject]@{})) 'Unknown'

Write-Host "`n[6] EFS - the literal string 'Unknown' must not score as a gap"
Assert-CV 'efs-backup met'     (Outcome $C.EFS 'efs-backup' ([pscustomobject]@{ BackupPolicyStatus='ENABLED' }))  'Met'
Assert-CV 'efs-backup gap'     (Outcome $C.EFS 'efs-backup' ([pscustomobject]@{ BackupPolicyStatus='DISABLED' })) 'Gap'
Assert-CV 'efs-backup unknown' (Outcome $C.EFS 'efs-backup' ([pscustomobject]@{ BackupPolicyStatus='Unknown' }))  'Unknown'

Write-Host "`n[7] The new signals: string enums must not be read through Get-CVTri"
<#
    Same trap as Azure's vault immutability: Get-CVTri is [bool]$Value and EVERY non-empty string is truthy, so
    Get-CVTri 'Disabled' is $true. Redshift reports MultiAZ as a STRING, S3 Object Lock as 'Enabled'/'None', and
    EFS replication as 'Configured'/'None'. Production never executes these Test blocks, so nothing else catches
    an inversion here.
#>
Assert-CV 'Get-CVTri on a string is truthy (the trap)' (Get-CVTri 'Disabled') $true

# S3 Object Lock - WORM. 'None' is MEASURED (S3 throws when unconfigured); 'Unknown' means the call failed.
Assert-CV 's3-objectlock Enabled -> Met'     (Outcome $C.S3 's3-objectlock' ([pscustomobject]@{ ObjectLockEnabled='Enabled' })) 'Met'
Assert-CV 's3-objectlock None -> Gap'        (Outcome $C.S3 's3-objectlock' ([pscustomobject]@{ ObjectLockEnabled='None' }))    'Gap'
Assert-CV 's3-objectlock Unknown -> Unknown' (Outcome $C.S3 's3-objectlock' ([pscustomobject]@{ ObjectLockEnabled='Unknown' })) 'Unknown'
Assert-CV 's3-objectlock blank -> Unknown'   (Outcome $C.S3 's3-objectlock' ([pscustomobject]@{})) 'Unknown'

# The four public-access booleans are published separately, so a partial configuration is visible.
$partial = [pscustomobject]@{ BlockPublicAcls=$true; BlockPublicPolicy=$false; IgnorePublicAcls=$true; RestrictPublicBuckets=$true }
Assert-CV 's3-pab-acls met'            (Outcome $C.S3 's3-pab-acls'     $partial) 'Met'
Assert-CV 's3-pab-policy gap (the one that is off)' (Outcome $C.S3 's3-pab-policy' $partial) 'Gap'
Assert-CV 's3-pab-restrict met'        (Outcome $C.S3 's3-pab-restrict' $partial) 'Met'
Assert-CV 's3-pab unread -> Unknown'   (Outcome $C.S3 's3-pab-acls' ([pscustomobject]@{})) 'Unknown'
Assert-CV 's3-mfadelete off -> Gap'    (Outcome $C.S3 's3-mfadelete' ([pscustomobject]@{ MfaDeleteEnabled=$false })) 'Gap'

# Redshift Multi-AZ is a STRING, which is exactly why it cannot use Get-CVTri.
Assert-CV 'rs-multiaz Enabled -> Met'   (Outcome $C.Redshift 'rs-multiaz' ([pscustomobject]@{ MultiAZ='Enabled' }))  'Met'
Assert-CV 'rs-multiaz Disabled -> Gap'  (Outcome $C.Redshift 'rs-multiaz' ([pscustomobject]@{ MultiAZ='Disabled' })) 'Gap'
Assert-CV 'rs-multiaz blank -> Unknown' (Outcome $C.Redshift 'rs-multiaz' ([pscustomobject]@{ MultiAZ='' }))         'Unknown'
# -1 is Redshift's "retain indefinitely" sentinel - the STRONGEST setting, so it must not read as a gap.
Assert-CV 'rs-manualret -1 (indefinite) -> Met' (Outcome $C.Redshift 'rs-manualret' ([pscustomobject]@{ ManualSnapshotRetentionDays=-1 })) 'Met'
Assert-CV 'rs-manualret 0 -> Gap'               (Outcome $C.Redshift 'rs-manualret' ([pscustomobject]@{ ManualSnapshotRetentionDays=0 }))  'Gap'

# EFS cross-region replication.
Assert-CV 'efs-xregion Configured -> Met' (Outcome $C.EFS 'efs-xregion' ([pscustomobject]@{ ReplicationStatus='Configured' })) 'Met'
Assert-CV 'efs-xregion None -> Gap'       (Outcome $C.EFS 'efs-xregion' ([pscustomobject]@{ ReplicationStatus='None' }))       'Gap'
Assert-CV 'efs-xregion Unknown -> Unknown' (Outcome $C.EFS 'efs-xregion' ([pscustomobject]@{ ReplicationStatus='Unknown' }))   'Unknown'

# DynamoDB: encryption is ALWAYS on, so FALSE means "no customer-managed key", not "unencrypted".
Assert-CV 'ddb-encrypted KMS -> Met'   (Outcome $C.DynamoDB 'ddb-encrypted' ([pscustomobject]@{ SSEType='KMS' }))  'Met'
Assert-CV 'ddb-encrypted None -> Gap'  (Outcome $C.DynamoDB 'ddb-encrypted' ([pscustomobject]@{ SSEType='None' })) 'Gap'
Assert-CV 'ddb-xregion replica -> Met' (Outcome $C.DynamoDB 'ddb-xregion' ([pscustomobject]@{ ReplicaRegionCount=2 })) 'Met'
Assert-CV 'ddb-xregion none -> Gap'    (Outcome $C.DynamoDB 'ddb-xregion' ([pscustomobject]@{ ReplicaRegionCount=0 })) 'Gap'
# The signal that was entirely absent from the DynamoDB row before this change.
Assert-CV 'ddb-vault protected -> Met' (Outcome $C.DynamoDB 'ddb-vault' ([pscustomobject]@{ AWSBackupProtected=$true }))  'Met'
Assert-CV 'ddb-vault unread -> Unknown' (Outcome $C.DynamoDB 'ddb-vault' ([pscustomobject]@{})) 'Unknown'

# Vault Lock - AWS's backup immutability, absent before. Declared on every type carrying AWS Backup coverage.
foreach ($pair in @(@{S=$C.EC2;I='ec2-vaultlock'}, @{S=$C.RDS;I='rds-vaultlock'},
                    @{S=$C.DynamoDB;I='ddb-vaultlock'}, @{S=$C.EFS;I='efs-vaultlock'})) {
    Assert-CV "$($pair.I) locked -> Met"    (Outcome $pair.S $pair.I ([pscustomobject]@{ BackupVaultAnyLocked=$true }))  'Met'
    Assert-CV "$($pair.I) unlocked -> Gap"  (Outcome $pair.S $pair.I ([pscustomobject]@{ BackupVaultAnyLocked=$false })) 'Gap'
    Assert-CV "$($pair.I) unread -> Unknown" (Outcome $pair.S $pair.I ([pscustomobject]@{}))                            'Unknown'
}

# [7] used to assert that an empty AWS environment produced a null overall score. It went with the scoring
# engine - an overall score is the backend's to compute, so there is no contract here to pin.

Write-Host ("`n======  {0} passed, {1} failed  ======`n" -f $script:Pass, $script:Fail) `
           -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
