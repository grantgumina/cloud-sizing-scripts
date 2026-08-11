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
# backup, recent, encrypted, and vault-lock were all uncollected on this fixture -> excluded, not failed.
Assert-CV 'four signals excluded as unknown'                 $ev.UnknownCount 4

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

Write-Host "`n[7] Empty AWS environment -> null score, no error"
Assert-CV 'empty score helper -> null' ($null -eq (Get-CVControlScore -Results @())) $true

Write-Host ("`n======  {0} passed, {1} failed  ======`n" -f $script:Pass, $script:Fail) `
           -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
