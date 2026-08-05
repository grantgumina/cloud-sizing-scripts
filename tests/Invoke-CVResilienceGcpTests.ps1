#requires -Version 7.2
<#  Tests the GCP resilience control definitions against synthetic inventory rows. #>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.GCP.ps1')

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }

$ctl = Get-CVGcpResilienceControls
function Outcome { param($ev,$id) (@($ev.Results | Where-Object Id -eq $id)[0]).Outcome }

Write-Host "`n[1] Cloud SQL - fully protected -> 100, no gaps"
$good = [pscustomobject]@{ BackupEnabled=$true; RetainedBackups=35; TxLogRetentionDays=7; PitrEnabled=$true; HasReplica=$true; CmkEncrypted=$true; DeletionProtection=$true; PublicIPs='' }
$e = Invoke-CVResilience -Resource $good -Controls $ctl.Database
Assert-CV 'score 100' $e.Score 100
Assert-CV 'no gaps'   $e.Gaps.Count 0

Write-Host "`n[2] Cloud SQL - unprotected -> low score, correct gaps"
$bad = [pscustomobject]@{ BackupEnabled=$false; RetainedBackups=7; TxLogRetentionDays=1; PitrEnabled=$false; HasReplica=$false; CmkEncrypted=$false; DeletionProtection=$false; PublicIPs='34.1.2.3' }
$e = Invoke-CVResilience -Resource $bad -Controls $ctl.Database
Assert-CV 'score 0'                 $e.Score 0
Assert-CV 'backup is a gap'         (Outcome $e 'db-backup') 'Gap'
Assert-CV 'retention <35 is a gap'  (Outcome $e 'db-retention') 'Gap'
Assert-CV 'public exposure is gap'  (Outcome $e 'db-notpublic') 'Gap'

Write-Host "`n[3] Retention heuristic boundary (35 count OR tx-log days)"
$r35 = Invoke-CVResilience -Resource ([pscustomobject]@{ RetainedBackups=35; TxLogRetentionDays=1 }) -Controls @($ctl.Database | Where-Object { $_.Id -eq 'db-retention' })
Assert-CV 'retained 35 -> Met' (Outcome $r35 'db-retention') 'Met'
$rTx = Invoke-CVResilience -Resource ([pscustomobject]@{ RetainedBackups=7; TxLogRetentionDays=35 }) -Controls @($ctl.Database | Where-Object { $_.Id -eq 'db-retention' })
Assert-CV 'tx-log 35 days -> Met' (Outcome $rTx 'db-retention') 'Met'

Write-Host "`n[4] Missing signals -> Unknown -> excluded (AlloyDB-style row: no fields)"
$alloy = [pscustomobject]@{ Type='alloydbcluster'; Name='c1' }
$e = Invoke-CVResilience -Resource $alloy -Controls $ctl.Database
Assert-CV 'all unknown -> null score' ($null -eq $e.Score) $true
Assert-CV 'db-backup unknown'         (Outcome $e 'db-backup') 'Unknown'

Write-Host "`n[5] Storage bucket - mixed posture; missing field is Unknown"
$b = [pscustomobject]@{ Versioning=$true; MultiRegion=$false; CmkEncrypted=$true; RetentionLocked=$false; PublicAccessBlocked=$true }  # SoftDeleteEnabled absent
$e = Invoke-CVResilience -Resource $b -Controls $ctl.Storage
Assert-CV 'versioning met'      (Outcome $e 'gcs-versioning') 'Met'
Assert-CV 'multiregion gap'     (Outcome $e 'gcs-xregion') 'Gap'
Assert-CV 'softdelete unknown'  (Outcome $e 'gcs-softdelete') 'Unknown'
# 3 Met (High=2 each=6) / (3 Met + 2 Gap[gcs-xregion,gcs-lock]=4 -> 10) = 60
Assert-CV 'score excludes unknown = 60' $e.Score 60

Write-Host "`n[6] Disk cross-region + no Clean Recovery control exists for GCP"
$e = Invoke-CVResilience -Resource ([pscustomobject]@{ XRegionBackup=$true }) -Controls @($ctl.Disk | Where-Object Id -eq 'pd-xregion')
Assert-CV 'pd-xregion met' (Outcome $e 'pd-xregion') 'Met'
$allIds = ($ctl.Values | ForEach-Object { $_ } | ForEach-Object { $_.Category }) | Sort-Object -Unique
Assert-CV 'no CleanRecovery controls for GCP' ($allIds -contains 'CleanRecovery') $false

Write-Host ("`n{0}  {1} passed, {2} failed  {0}" -f ('=' * 6), $script:Pass, $script:Fail) -ForegroundColor ($script:Fail ? 'Red' : 'Green')
exit ($script:Fail -gt 0 ? 1 : 0)
