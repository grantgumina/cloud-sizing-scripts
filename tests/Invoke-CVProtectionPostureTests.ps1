#requires -Version 7.2
<#  Dependency-free tests for the RAW protection data (src/common/CVSizing.Resilience.ps1
    Get-CVProtectionData) and the shared emitter (src/common/CVSizing.Console.ps1 Export-CVSizingJson).

    Two things under test: (1) only the fields APPLICABLE to a workload type are emitted - PITR only on DB
    types, public-access only on object storage / DBs, etc. - inapplicable fields are omitted, not null; and
    (2) applicable-but-unmeasured stays $null (never $false), and public-access reads through as "blocked = true".
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.AWS.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.Azure.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.GCP.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Console.ps1')

$script:Pass = 0; $script:Fail = 0
# Stringified compare distinguishes $true("True") / $false("False") / $null("") cleanly.
function Assert-CV { param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }
function Has  { param($P, [string]$K) $P.Contains($K) }

$AWS = Get-CVAwsResilienceControls
$AZ  = Get-CVAzureResilienceControls
$GCP = Get-CVGcpResilienceControls
function PD { param($Row, $Cloud, $Type, $Set) Get-CVProtectionData -Resource $Row -Cloud $Cloud -ResourceType $Type -ControlSet $Set }

Write-Host "`n[1] AWS EC2 - backup + immutability apply; PITR/public/cross-region do NOT"
$ec2 = [pscustomobject]@{ ProtectionStatus='Protected'; AWSBackupProtected=$true; EBSSnapshotCount=3; DaysSinceLastBackup=1; AllVolumesEncrypted=$true }
$p = PD $ec2 aws EC2 $AWS.EC2
Assert-CV 'ec2 has backup_enabled'        (Has $p 'backup_enabled')        $true
Assert-CV 'ec2 backup_enabled = true'     $p['backup_enabled']             $true
Assert-CV 'ec2 has backup_immutable'      (Has $p 'backup_immutable')      $true
Assert-CV 'ec2 OMITS pitr_enabled'        (Has $p 'pitr_enabled')          $false
Assert-CV 'ec2 OMITS public_access_blocked' (Has $p 'public_access_blocked') $false
Assert-CV 'ec2 OMITS cross_region_backup' (Has $p 'cross_region_backup')   $false
Assert-CV 'ec2 OMITS backup_retention_days' (Has $p 'backup_retention_days') $false

Write-Host "`n[2] AWS S3 - immutable/public/cross-region apply; backup/pitr do NOT"
$s3bad = [pscustomobject]@{ PublicAccessBlocked=$false; ReplicationEnabled=$true }
$p = PD $s3bad aws S3 $AWS.S3
Assert-CV 's3 OMITS backup_enabled'       (Has $p 'backup_enabled')        $false
Assert-CV 's3 OMITS pitr_enabled'         (Has $p 'pitr_enabled')          $false
Assert-CV 's3 public_access_blocked=false' $p['public_access_blocked']     $false
Assert-CV 's3 cross_region_backup=true'   $p['cross_region_backup']        $true
Assert-CV 's3 blocked=true'  (PD ([pscustomobject]@{ PublicAccessBlocked=$true }) aws S3 $AWS.S3)['public_access_blocked'] $true
Assert-CV 's3 unread=null (applicable, unmeasured)' (PD ([pscustomobject]@{}) aws S3 $AWS.S3)['public_access_blocked'] $null
Assert-CV 's3 object-lock -> immutable true' (PD ([pscustomobject]@{ ObjectLockEnabled=$true }) aws S3 $AWS.S3)['backup_immutable'] $true

Write-Host "`n[3] AWS RDS - backup/retention/immutable/pitr apply; public/cross-region do NOT"
$rds = [pscustomobject]@{ AutomatedBackupsEnabled=$true; BackupRetentionDays=35; PITREnabled=$true; AWSBackupProtected=$true; BackupVaultLocked=$true }
$p = PD $rds aws RDS $AWS.RDS
Assert-CV 'rds backup_enabled=true'       $p['backup_enabled']             $true
Assert-CV 'rds pitr_enabled=true'         $p['pitr_enabled']               $true
Assert-CV 'rds backup_retention_days=35'  $p['backup_retention_days']      35
Assert-CV 'rds backup_immutable=true'     $p['backup_immutable']           $true
Assert-CV 'rds OMITS public_access_blocked' (Has $p 'public_access_blocked') $false
Assert-CV 'rds OMITS cross_region_backup' (Has $p 'cross_region_backup')   $false

Write-Host "`n[4] AWS Redshift - backup (from retention) + retention only"
$rs = [pscustomobject]@{ AutomatedSnapshotRetentionPeriod=7; Encrypted=$true }
$p = PD $rs aws Redshift $AWS.Redshift
Assert-CV 'redshift backup_enabled=true (retention>0)' $p['backup_enabled']  $true
Assert-CV 'redshift backup_retention_days=7' $p['backup_retention_days']     7
Assert-CV 'redshift OMITS pitr_enabled'   (Has $p 'pitr_enabled')           $false
Assert-CV 'redshift OMITS backup_immutable' (Has $p 'backup_immutable')     $false

Write-Host "`n[5] Azure SQL / Storage / FlexDB applicability"
$sql = PD ([pscustomobject]@{ PITR_Days=7 }) azure SQL $AZ.SQL
Assert-CV 'az-sql pitr_enabled=true'      $sql['pitr_enabled']             $true
Assert-CV 'az-sql backup_retention_days=7' $sql['backup_retention_days']   7
Assert-CV 'az-sql OMITS backup_immutable' (Has $sql 'backup_immutable')    $false
Assert-CV 'az-sql OMITS public_access_blocked' (Has $sql 'public_access_blocked') $false
$st = PD ([pscustomobject]@{ ImmutabilityLocked=$false }) azure Storage $AZ.Storage
Assert-CV 'az-storage backup_immutable=false' $st['backup_immutable']      $false
Assert-CV 'az-storage OMITS backup_enabled' (Has $st 'backup_enabled')     $false
$fx = PD ([pscustomobject]@{ BackupRetentionDays=14 }) azure FlexDB $AZ.FlexDB
Assert-CV 'az-flexdb backup_enabled=true (retention>0)' $fx['backup_enabled'] $true
Assert-CV 'az-flexdb backup_retention_days=14' $fx['backup_retention_days'] 14
Assert-CV 'az-flexdb OMITS pitr_enabled'  (Has $fx 'pitr_enabled')         $false
Assert-CV 'az-flexdb backup=false when retention 0' (PD ([pscustomobject]@{ BackupRetentionDays=0 }) azure FlexDB $AZ.FlexDB)['backup_enabled'] $false

Write-Host "`n[6] GCP Database - public-access applies (public IP); immutability does NOT"
$gPub = PD ([pscustomobject]@{ PublicIPs='1.2.3.4'; BackupEnabled=$false }) gcp Database $GCP.Database
Assert-CV 'gcp-db public_access_blocked=false' $gPub['public_access_blocked'] $false
Assert-CV 'gcp-db backup_enabled=false'   $gPub['backup_enabled']          $false
Assert-CV 'gcp-db OMITS backup_immutable' (Has $gPub 'backup_immutable')   $false
Assert-CV 'gcp-db private -> blocked true' (PD ([pscustomobject]@{ PublicIPs=''; BackupEnabled=$true }) gcp Database $GCP.Database)['public_access_blocked'] $true

Write-Host "`n[7] GCP VM - applicable fields stay null when unmeasured (never false); pitr omitted"
$p = PD ([pscustomobject]@{}) gcp VM $GCP.VM
Assert-CV 'gcp-vm has backup_enabled'     (Has $p 'backup_enabled')        $true
Assert-CV 'gcp-vm backup_enabled=null'    $p['backup_enabled']             $null
Assert-CV 'gcp-vm has backup_immutable'   (Has $p 'backup_immutable')      $true
Assert-CV 'gcp-vm has cross_region_backup' (Has $p 'cross_region_backup')  $true
Assert-CV 'gcp-vm OMITS pitr_enabled'     (Has $p 'pitr_enabled')          $false

Write-Host "`n[8] Export-CVSizingJson - nests only applicable fields, no flat copies, no summary"
# S3-style row: only its applicable protection fields present (as the pass would attach).
$row = [pscustomobject]@{ BucketName='b1'; SizeGB=10
    backup_immutable=$true; public_access_blocked=$false; cross_region_backup=$true }
$wl = [ordered]@{ aws_s3 = @{ Items=@($row); Type='S3'; SizeField='SizeGB' } }
$outDir = Join-Path ([System.IO.Path]::GetTempPath()) ("cvprot_" + $PID)
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
try {
    $path = Export-CVSizingJson -Cloud aws -OutputDir $outDir -TimeStamp 'test' `
        -Metadata ([ordered]@{ accounts = @('123456789012') }) -Workloads $wl
    $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-CV 'schema_version 4.0'            $doc.metadata.schema_version '4.0'
    Assert-CV 'no protection_summary'         ($null -eq $doc.protection_summary) $true
    $r = $doc.workloads.aws_s3[0]
    Assert-CV 'nested backup_immutable true'  $r.protection.backup_immutable $true
    Assert-CV 'nested public_access_blocked false' $r.protection.public_access_blocked $false
    Assert-CV 'nested OMITS backup_enabled'   ($null -eq $r.protection.PSObject.Properties['backup_enabled']) $true
    Assert-CV 'nested OMITS pitr_enabled'     ($null -eq $r.protection.PSObject.Properties['pitr_enabled']) $true
    Assert-CV 'flat backup_immutable removed from top' ($null -eq $r.PSObject.Properties['backup_immutable']) $true
    Assert-CV 'non-protection field survives'  $r.BucketName 'b1'
} finally {
    Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("`n======  {0} passed, {1} failed  ======`n" -f $script:Pass, $script:Fail) `
           -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
