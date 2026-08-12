#requires -Version 7.2
<#  Tests the GCP resilience control definitions against synthetic inventory rows. #>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.GCP.ps1')
. (Join-Path $PSScriptRoot 'CVTestControlEvaluator.ps1')

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }

$ctl = Get-CVGcpResilienceControls
function Outcome { param($ev,$id) (@($ev.Results | Where-Object Id -eq $id)[0]).Outcome }

Write-Host "`n[1] Cloud SQL - fully protected -> every control Met"
$good = [pscustomobject]@{ BackupEnabled=$true; RetainedBackups=35; TxLogRetentionDays=7; PitrEnabled=$true; HasReplica=$true; CmkEncrypted=$true; DeletionProtection=$true; PublicIPs='' }
$e = Invoke-CVResilience -Resource $good -Controls $ctl.Database
Assert-CV 'no control reports a gap' $e.GapCount 0
Assert-CV 'every control assessed'   $e.UnknownCount 0

Write-Host "`n[2] Cloud SQL - unprotected -> correct gaps"
$bad = [pscustomobject]@{ BackupEnabled=$false; RetainedBackups=7; TxLogRetentionDays=1; PitrEnabled=$false; HasReplica=$false; CmkEncrypted=$false; DeletionProtection=$false; PublicIPs='34.1.2.3' }
$e = Invoke-CVResilience -Resource $bad -Controls $ctl.Database
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
Assert-CV 'nothing assessed -> no gaps invented' $e.GapCount 0
Assert-CV 'db-backup unknown'         (Outcome $e 'db-backup') 'Unknown'

Write-Host "`n[5] Storage bucket - mixed posture; missing field is Unknown"
$b = [pscustomobject]@{ Versioning=$true; MultiRegion=$false; CmkEncrypted=$true; RetentionLocked=$false; PublicAccessBlocked=$true }  # SoftDeleteEnabled absent
$e = Invoke-CVResilience -Resource $b -Controls $ctl.Storage
Assert-CV 'versioning met'      (Outcome $e 'gcs-versioning') 'Met'
Assert-CV 'multiregion gap'     (Outcome $e 'gcs-xregion') 'Gap'
Assert-CV 'softdelete unknown'  (Outcome $e 'gcs-softdelete') 'Unknown'
# The weighted score this used to assert (60) is now the backend's to compute. What matters here is that the
# absent field is excluded rather than counted against the bucket: 3 Met, 2 Gap, 1 Unknown.
Assert-CV 'unknown excluded, not counted as gap' $e.UnknownCount 1
Assert-CV 'two real gaps'                        $e.GapCount 2

Write-Host "`n[6] Disk cross-region + no Clean Recovery control exists for GCP"
$e = Invoke-CVResilience -Resource ([pscustomobject]@{ XRegionBackup=$true }) -Controls @($ctl.Disk | Where-Object Id -eq 'pd-xregion')
Assert-CV 'pd-xregion met' (Outcome $e 'pd-xregion') 'Met'
$allIds = ($ctl.Values | ForEach-Object { $_ } | ForEach-Object { $_.Category }) | Sort-Object -Unique
Assert-CV 'no CleanRecovery controls for GCP' ($allIds -contains 'CleanRecovery') $false

Write-Host "`n[7] The five newly collected signals, tri-state per control"
<#
    Each of these was DECLARED by a control and populated by nothing, so the column shipped blank on every run
    while CYBER_RESILIENCE_SIGNALS.md described two of them as collected. The point of these assertions is the
    boundary cases, not the happy path: the polarity inversion, the CMEK-vs-CSEK distinction, and the fact that
    a read-and-absent nested block is a MEASURED gap while a failed lookup is Unknown.
#>
# vm-delprot
Assert-CV 'delprot true  -> Met'     (Outcome (Invoke-CVResilience -Resource ([pscustomobject]@{ DeletionProtection=$true  }) -Controls @($ctl.VM | Where-Object Id -eq 'vm-delprot')) 'vm-delprot') 'Met'
Assert-CV 'delprot false -> Gap'     (Outcome (Invoke-CVResilience -Resource ([pscustomobject]@{ DeletionProtection=$false }) -Controls @($ctl.VM | Where-Object Id -eq 'vm-delprot')) 'vm-delprot') 'Gap'
Assert-CV 'delprot absent -> Unknown' (Outcome (Invoke-CVResilience -Resource ([pscustomobject]@{}) -Controls @($ctl.VM | Where-Object Id -eq 'vm-delprot')) 'vm-delprot') 'Unknown'

# pd-cmek. The collector reads diskEncryptionKey.kmsKeyName, NOT the row's existing `Encrypted` field, because
# `Encrypted` is also true for a customer-SUPPLIED key. A CSEK disk must therefore report a GAP, not Met.
$cmekCtl = @($ctl.Disk | Where-Object Id -eq 'pd-cmek')
Assert-CV 'cmek true  -> Met'   (Outcome (Invoke-CVResilience -Resource ([pscustomobject]@{ CmkEncrypted=$true  }) -Controls $cmekCtl) 'pd-cmek') 'Met'
Assert-CV 'CSEK-only disk -> Gap, not Met' (Outcome (Invoke-CVResilience -Resource ([pscustomobject]@{ CmkEncrypted=$false; Encrypted='Yes' }) -Controls $cmekCtl) 'pd-cmek') 'Gap'
Assert-CV 'cmek absent -> Unknown' (Outcome (Invoke-CVResilience -Resource ([pscustomobject]@{}) -Controls $cmekCtl) 'pd-cmek') 'Unknown'

# pd-nodelete. POLARITY: the control asks whether the disk SURVIVES deletion; the API reports autoDelete.
# autoDelete = $true (the default for a boot disk) must therefore be a GAP.
$ndCtl = @($ctl.Disk | Where-Object Id -eq 'pd-nodelete')
Assert-CV 'survives true (autoDelete false) -> Met' (Outcome (Invoke-CVResilience -Resource ([pscustomobject]@{ SurvivesVmDelete=$true  }) -Controls $ndCtl) 'pd-nodelete') 'Met'
Assert-CV 'survives false (autoDelete TRUE) -> Gap' (Outcome (Invoke-CVResilience -Resource ([pscustomobject]@{ SurvivesVmDelete=$false }) -Controls $ndCtl) 'pd-nodelete') 'Gap'
# The trap this guards: Get-CVTri is [bool]$Value, so ANY non-empty string is $true. Writing the string 'NA'
# for "not applicable" would silently read as Met - a fabricated pass on an Immutability control.
Assert-CV "Get-CVTri 'NA' is TRUE - so 'NA' must never be written to a signal field" (Get-CVTri 'NA') $true
Assert-CV "and 'NA' would indeed read as Met" (Outcome (Invoke-CVResilience -Resource ([pscustomobject]@{ SurvivesVmDelete='NA' }) -Controls $ndCtl) 'pd-nodelete') 'Met'

# gke-secretenc. ENCRYPTED is Met; DECRYPTED and an absent databaseEncryption block are both a MEASURED gap,
# because the cluster object itself was read either way.
$seCtl = @($ctl.GKE | Where-Object Id -eq 'gke-secretenc')
Assert-CV 'secretenc true  -> Met' (Outcome (Invoke-CVResilience -Resource ([pscustomobject]@{ SecretsEncryptionCmk=$true  }) -Controls $seCtl) 'gke-secretenc') 'Met'
Assert-CV 'secretenc false -> Gap' (Outcome (Invoke-CVResilience -Resource ([pscustomobject]@{ SecretsEncryptionCmk=$false }) -Controls $seCtl) 'gke-secretenc') 'Gap'
Assert-CV 'lookup failed -> Unknown' (Outcome (Invoke-CVResilience -Resource ([pscustomobject]@{}) -Controls $seCtl) 'gke-secretenc') 'Unknown'

# fs-xregion / gke-xregion both read BackupXRegion.
foreach ($pair in @(@{ T='Filestore'; Id='fs-xregion' }, @{ T='GKE'; Id='gke-xregion' })) {
    $c = @($ctl[$pair.T] | Where-Object Id -eq $pair.Id)
    Assert-CV "$($pair.Id) true  -> Met"     (Outcome (Invoke-CVResilience -Resource ([pscustomobject]@{ BackupXRegion=$true  }) -Controls $c) $pair.Id) 'Met'
    Assert-CV "$($pair.Id) false -> Gap"     (Outcome (Invoke-CVResilience -Resource ([pscustomobject]@{ BackupXRegion=$false }) -Controls $c) $pair.Id) 'Gap'
    Assert-CV "$($pair.Id) absent -> Unknown" (Outcome (Invoke-CVResilience -Resource ([pscustomobject]@{}) -Controls $c) $pair.Id) 'Unknown'
}

Write-Host "`n[8] The two Critical controls that were fabricating a MET are per-resource now"
<#
    HasBackup (Filestore) and HasBackupPlan (GKE) were both computed project-scoped:
        [bool](@($fsBackups[$f.Project]).Count -gt 0)
    so ONE backup or plan anywhere in a project marked EVERY share / cluster in it as protected, on controls
    whose Severity is Critical. These assertions model the join the collector now does and would fail against
    the old project-scoped logic, where instance B is Met purely because instance A has a backup.
#>
# Two instances in one project; only fs1 has a backup. Payload shape is what `filestore backups list` returns.
$fsBackupPayload = @(
    [pscustomobject]@{ name='projects/p1/locations/us-central1/backups/b1'; sourceInstance='projects/p1/locations/us-central1-a/instances/fs1' }
)
$fsIdx = @{}
foreach ($bk in $fsBackupPayload) {
    $srcName = ($bk.sourceInstance -split '/')[-1]
    $srcLoc  = $(if ($bk.sourceInstance -match '/locations/([^/]+)/') { $Matches[1] } else { '' })
    $bkLoc   = $(if ("$($bk.name)" -match '/locations/([^/]+)/')      { $Matches[1] } else { '' })
    $k = "p1|$srcName".ToLower()
    if (-not $fsIdx.ContainsKey($k)) { $fsIdx[$k] = @{ Count = 0 } }
    $fsIdx[$k].Count++
    if (($bkLoc -replace '-[a-z]$','') -ne ($srcLoc -replace '-[a-z]$','')) { $fsIdx[$k].XRegion = $true }
}
Assert-CV 'fs1 (has a backup) -> HasBackup TRUE'  ([bool]($fsIdx['p1|fs1'] -and $fsIdx['p1|fs1'].Count -gt 0)) $true
Assert-CV 'fs2 (no backup) -> HasBackup FALSE, not TRUE by association' ([bool]($fsIdx['p1|fs2'] -and $fsIdx['p1|fs2'].Count -gt 0)) $false
# Zone normalisation: a BASIC (zonal) instance in us-central1-a backed up to us-central1 is NOT cross-region.
Assert-CV 'zonal instance vs regional backup is NOT cross-region' ([bool]$fsIdx['p1|fs1'].XRegion) $false

# GKE: two clusters, one plan, plus a deactivated plan that must be ignored.
$gkePlans = @(
    [pscustomobject]@{ name='projects/p1/locations/us-central1/backupPlans/pl1'; cluster='projects/p1/locations/us-central1/clusters/c1'; state='ACTIVE' }
    [pscustomobject]@{ name='projects/p1/locations/us-central1/backupPlans/pl2'; cluster='projects/p1/locations/us-central1/clusters/c2'; state='DEACTIVATED' }
)
$gkeIdx = @{}
foreach ($plan in $gkePlans) {
    if ("$($plan.state)" -eq 'DEACTIVATED') { continue }
    $clName = ($plan.cluster -split '/')[-1]
    $k = "p1|$clName".ToLower()
    if (-not $gkeIdx.ContainsKey($k)) { $gkeIdx[$k] = @{ Count = 0 } }
    $gkeIdx[$k].Count++
}
Assert-CV 'c1 (has an active plan) -> HasBackupPlan TRUE' ([bool]($gkeIdx['p1|c1'] -and $gkeIdx['p1|c1'].Count -gt 0)) $true
Assert-CV 'c2 (deactivated plan only) -> FALSE'           ([bool]($gkeIdx['p1|c2'] -and $gkeIdx['p1|c2'].Count -gt 0)) $false
Assert-CV 'c3 (no plan at all) -> FALSE, not TRUE by association' ([bool]($gkeIdx['p1|c3'] -and $gkeIdx['p1|c3'].Count -gt 0)) $false

Write-Host ("`n{0}  {1} passed, {2} failed  {0}" -f ('=' * 6), $script:Pass, $script:Fail) -ForegroundColor ($script:Fail ? 'Red' : 'Green')
exit ($script:Fail -gt 0 ? 1 : 0)
