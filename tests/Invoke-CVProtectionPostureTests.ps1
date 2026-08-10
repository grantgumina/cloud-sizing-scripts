#requires -Version 7.2
<#  Dependency-free tests for the JSON protection posture (src/common/CVSizing.Resilience.ps1
    Get-CVProtectionPosture) and the shared emitter (src/common/CVSizing.Console.ps1 Export-CVSizingJson).

    The posture is a headline, consistent-terminology view of controls that already ran. The things that
    matter here are the same ones the resilience engine protects: Unknown/NA must surface as 'NotAssessed'
    (never a negative label), the public-access control must invert cleanly, retention comes through as a
    number, and the overall label follows the documented rule.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.AWS.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.Azure.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.GCP.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Console.ps1')

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }

# Attach Ctl_* columns exactly as the sizing scripts do, so posture reads real engine outcomes off the row.
function Enrich { param($Row, $Set)
    $ev = Invoke-CVResilience -Resource $Row -Controls $Set
    foreach ($kv in (ConvertTo-CVResilienceColumns -Evaluation $ev).GetEnumerator()) {
        Add-Member -InputObject $Row -NotePropertyName $kv.Key -NotePropertyValue $kv.Value -Force
    }
    $Row }

$AWS = Get-CVAwsResilienceControls
$AZ  = Get-CVAzureResilienceControls
$GCP = Get-CVGcpResilienceControls

Write-Host "`n[1] AWS EC2 - protected; PITR/public are NotAssessed (N/A to a VM), not negative"
$ec2 = Enrich ([pscustomobject]@{ ProtectionStatus='Protected'; AWSBackupProtected=$true; EBSSnapshotCount=3; DaysSinceLastBackup=1; AllVolumesEncrypted=$true }) $AWS.EC2
$p = Get-CVProtectionPosture -Resource $ec2 -Cloud aws -ResourceType EC2
Assert-CV 'ec2 backup Protected'        $p.backup          'Protected'
Assert-CV 'ec2 pitr NotAssessed'        $p.pitr            'NotAssessed'
Assert-CV 'ec2 public NotAssessed'      $p.public_exposure 'NotAssessed'
Assert-CV 'ec2 immutability NotAssessed'$p.immutability    'NotAssessed'
Assert-CV 'ec2 overall Protected'       $p.overall         'Protected'

Write-Host "`n[2] AWS S3 - public-access inversion + cross-region"
$s3bad = Enrich ([pscustomobject]@{ PublicAccessBlocked=$false; VersioningStatus='Enabled'; ReplicationEnabled=$true; ServerSideEncryption='AES256'; LifecycleRuleCount=1 }) $AWS.S3
$p = Get-CVProtectionPosture -Resource $s3bad -Cloud aws -ResourceType S3
Assert-CV 's3 exposed -> Public'        $p.public_exposure 'Public'
Assert-CV 's3 xregion -> Protected'     $p.cross_region    'Protected'
Assert-CV 's3 overall PartiallyProtected' $p.overall       'PartiallyProtected'
$s3ok = Enrich ([pscustomobject]@{ PublicAccessBlocked=$true }) $AWS.S3
Assert-CV 's3 blocked -> NotPublic'     (Get-CVProtectionPosture -Resource $s3ok -Cloud aws -ResourceType S3).public_exposure 'NotPublic'
$s3blank = Enrich ([pscustomobject]@{}) $AWS.S3
Assert-CV 's3 unread -> NotAssessed'    (Get-CVProtectionPosture -Resource $s3blank -Cloud aws -ResourceType S3).public_exposure 'NotAssessed'

Write-Host "`n[3] AWS RDS - retention number + PITR"
$rds = Enrich ([pscustomobject]@{ AutomatedBackupsEnabled=$true; BackupRetentionDays=35; PITREnabled=$true; MultiAZ=$true; StorageEncrypted=$true; DeletionProtection=$true; AWSBackupProtected=$true }) $AWS.RDS
$p = Get-CVProtectionPosture -Resource $rds -Cloud aws -ResourceType RDS
Assert-CV 'rds backup Protected'  $p.backup         'Protected'
Assert-CV 'rds pitr Enabled'      $p.pitr           'Enabled'
Assert-CV 'rds retention_days 35' $p.retention_days 35

Write-Host "`n[3b] AWS immutability - S3 Object Lock + AWS Backup Vault Lock"
$s3lock = Enrich ([pscustomobject]@{ ObjectLockEnabled=$true; PublicAccessBlocked=$true }) $AWS.S3
Assert-CV 's3 object-lock -> Immutable' (Get-CVProtectionPosture -Resource $s3lock -Cloud aws -ResourceType S3).immutability 'Immutable'
$rdsLocked = Enrich ([pscustomobject]@{ AutomatedBackupsEnabled=$true; BackupRetentionDays=35; PITREnabled=$true; AWSBackupProtected=$true; BackupVaultLocked=$true }) $AWS.RDS
Assert-CV 'rds vault-lock -> Immutable'          (Get-CVProtectionPosture -Resource $rdsLocked -Cloud aws -ResourceType RDS).immutability 'Immutable'
$ec2NoLock = Enrich ([pscustomobject]@{ ProtectionStatus='Protected'; AWSBackupProtected=$true; EBSSnapshotCount=1; DaysSinceLastBackup=1; AllVolumesEncrypted=$true; BackupVaultLocked=$false }) $AWS.EC2
Assert-CV 'ec2 vault not locked -> NotImmutable'  (Get-CVProtectionPosture -Resource $ec2NoLock -Cloud aws -ResourceType EC2).immutability 'NotImmutable'
$ec2NoLockField = Enrich ([pscustomobject]@{ ProtectionStatus='Protected'; AWSBackupProtected=$true; EBSSnapshotCount=1; DaysSinceLastBackup=1; AllVolumesEncrypted=$true }) $AWS.EC2
Assert-CV 'ec2 vault-lock uncollected -> NotAssessed' (Get-CVProtectionPosture -Resource $ec2NoLockField -Cloud aws -ResourceType EC2).immutability 'NotAssessed'

Write-Host "`n[4] Azure SQL PITR + Storage immutability gap"
$sql = Enrich ([pscustomobject]@{ PITR_Days=7 }) $AZ.SQL
$p = Get-CVProtectionPosture -Resource $sql -Cloud azure -ResourceType SQL
Assert-CV 'az-sql pitr Enabled'      $p.pitr           'Enabled'
Assert-CV 'az-sql retention_days 7'  $p.retention_days 7
Assert-CV 'az-sql backup Protected'  $p.backup         'Protected'
$st = Enrich ([pscustomobject]@{ ImmutabilityLocked=$false }) $AZ.Storage
Assert-CV 'az-storage immutability NotImmutable' (Get-CVProtectionPosture -Resource $st -Cloud azure -ResourceType Storage).immutability 'NotImmutable'

Write-Host "`n[5] Azure FlexDB - backup derived from retention (no boolean backup control)"
$fx = Enrich ([pscustomobject]@{ BackupRetentionDays=14; GeoRedundant=$true }) $AZ.FlexDB
$p = Get-CVProtectionPosture -Resource $fx -Cloud azure -ResourceType FlexDB
Assert-CV 'az-flexdb backup Protected (retention>0)' $p.backup         'Protected'
Assert-CV 'az-flexdb retention_days 14'              $p.retention_days 14

Write-Host "`n[6] GCP Database - db-notpublic inversion; backup gap -> Unprotected overall"
$gPub = Enrich ([pscustomobject]@{ PublicIPs='1.2.3.4'; BackupEnabled=$false }) $GCP.Database
$p = Get-CVProtectionPosture -Resource $gPub -Cloud gcp -ResourceType Database
Assert-CV 'gcp-db public Public'       $p.public_exposure 'Public'
Assert-CV 'gcp-db backup Unprotected'  $p.backup          'Unprotected'
Assert-CV 'gcp-db overall Unprotected' $p.overall         'Unprotected'
$gPriv = Enrich ([pscustomobject]@{ PublicIPs=''; BackupEnabled=$true }) $GCP.Database
Assert-CV 'gcp-db not public -> NotPublic' (Get-CVProtectionPosture -Resource $gPriv -Cloud gcp -ResourceType Database).public_exposure 'NotPublic'

Write-Host "`n[7] Unknown-not-a-gap: an unassessed signal is NotAssessed, never a negative"
$unk = Enrich ([pscustomobject]@{}) $GCP.VM   # every VM control reads a null field -> Unknown
$p = Get-CVProtectionPosture -Resource $unk -Cloud gcp -ResourceType VM
Assert-CV 'gcp-vm backup NotAssessed'   $p.backup       'NotAssessed'
Assert-CV 'gcp-vm immutability NotAssessed' $p.immutability 'NotAssessed'
Assert-CV 'gcp-vm overall NotAssessed'  $p.overall      'NotAssessed'

Write-Host "`n[8] overall rule - Protected + a negative assessed signal -> PartiallyProtected"
$partial = Enrich ([pscustomobject]@{ BackupEnabled=$true; BackupImmutable=$false; BackupCrossRegion=$true }) $AZ.VM
$p = Get-CVProtectionPosture -Resource $partial -Cloud azure -ResourceType VM
Assert-CV 'az-vm backup Protected'          $p.backup       'Protected'
Assert-CV 'az-vm immutability NotImmutable'  $p.immutability 'NotImmutable'
Assert-CV 'az-vm overall PartiallyProtected' $p.overall     'PartiallyProtected'

Write-Host "`n[9] Fallback - no Ctl_* on the row, but a ControlSet re-evaluates in-memory"
$raw = [pscustomobject]@{ PublicAccessBlocked=$false }   # deliberately NOT enriched
$p = Get-CVProtectionPosture -Resource $raw -Cloud aws -ResourceType S3 -ControlSet $AWS.S3
Assert-CV 'fallback s3 public Public' $p.public_exposure 'Public'
$rawNoSet = Get-CVProtectionPosture -Resource ([pscustomobject]@{ PublicAccessBlocked=$false }) -Cloud aws -ResourceType S3
Assert-CV 'no ctl + no controlset -> NotAssessed' $rawNoSet.public_exposure 'NotAssessed'

Write-Host "`n[10] Export-CVSizingJson - shape, attached protection, summary + rollup"
$rows = @(
    (Enrich ([pscustomobject]@{ InstanceId='i-1'; SizeGB=100; ProtectionStatus='Protected'; AWSBackupProtected=$true; EBSSnapshotCount=1; DaysSinceLastBackup=1; AllVolumesEncrypted=$true }) $AWS.EC2)
    (Enrich ([pscustomobject]@{ InstanceId='i-2'; SizeGB=50;  ProtectionStatus='Unprotected'; AWSBackupProtected=$false; EBSSnapshotCount=0; DaysSinceLastBackup=$null; AllVolumesEncrypted=$false }) $AWS.EC2)
)
$wl = [ordered]@{ aws_ec2 = @{ Items=$rows; Type='EC2'; PostureType='EC2'; SizeField='SizeGB' } }
$outDir = Join-Path ([System.IO.Path]::GetTempPath()) ("cvposturetest_" + $PID)
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
try {
    $path = Export-CVSizingJson -Cloud aws -OutputDir $outDir -TimeStamp 'test' `
        -Metadata ([ordered]@{ accounts = @('123456789012') }) -Workloads $wl -Controls $AWS
    $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-CV 'json schema_version 3.0'        $doc.metadata.schema_version '3.0'
    Assert-CV 'json cloud aws'                 $doc.metadata.cloud          'aws'
    Assert-CV 'json summary EC2 count 2'       $doc.summary.EC2.count       2
    Assert-CV 'json summary EC2 gb 150'        $doc.summary.EC2.total_storage_gb 150
    Assert-CV 'resource carries protection'    $doc.workloads.aws_ec2[0].protection.backup 'Protected'
    Assert-CV 'rollup total 2'                 $doc.protection_summary._overall.total       2
    Assert-CV 'rollup protected 1'             $doc.protection_summary._overall.protected   1
    Assert-CV 'rollup unprotected 1'           $doc.protection_summary._overall.unprotected 1
    Assert-CV 'rollup coverage 50%'            $doc.protection_summary._overall.coverage_pct 50
} finally {
    Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("`n======  {0} passed, {1} failed  ======`n" -f $script:Pass, $script:Fail) `
           -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
