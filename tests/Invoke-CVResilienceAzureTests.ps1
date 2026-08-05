#requires -Version 7.2
<#  Tests the Azure resilience control definitions against synthetic inventory rows. #>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.Azure.ps1')

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }
$ctl = Get-CVAzureResilienceControls
function Outcome { param($ev,$id) (@($ev.Results | Where-Object Id -eq $id)[0]).Outcome }

Write-Host "`n[1] Geo-SKU detection"
Assert-CV 'Standard_GRS -> geo'    (Test-CVAzureGeoSku 'Standard_GRS')   $true
Assert-CV 'Standard_RAGRS -> geo'  (Test-CVAzureGeoSku 'Standard_RAGRS') $true
Assert-CV 'Standard_GZRS -> geo'   (Test-CVAzureGeoSku 'Standard_GZRS')  $true
Assert-CV 'Standard_LRS -> not geo' (Test-CVAzureGeoSku 'Standard_LRS')  $false
Assert-CV 'empty sku -> unknown'   ($null -eq (Test-CVAzureGeoSku ''))   $true

Write-Host "`n[2] VM - backup enabled from inventory, cross-region unknown"
$e = Invoke-CVResilience -Resource ([pscustomobject]@{ BackupEnabled=$true }) -Controls $ctl.VM
Assert-CV 'vm-backup Met'          (Outcome $e 'vm-backup') 'Met'
Assert-CV 'vm-xregion Unknown'     (Outcome $e 'vm-xregion') 'Unknown'
Assert-CV 'score 100 (only backup assessed)' $e.Score 100

Write-Host "`n[3] Azure SQL - PITR/retention from inventory"
$sqlGood = [pscustomobject]@{ PITR_Days=35; LTRWeeklyRetention='P4W'; LTRMonthlyRetention=''; LTRYearlyRetention='' }
$e = Invoke-CVResilience -Resource $sqlGood -Controls $ctl.SQL
Assert-CV 'db-backup Met (SQL PaaS)'  (Outcome $e 'db-backup') 'Met'
Assert-CV 'db-pitr Met'               (Outcome $e 'db-pitr') 'Met'
Assert-CV 'db-retention Met (>=35)'   (Outcome $e 'db-retention') 'Met'
$sqlShort = [pscustomobject]@{ PITR_Days=7; LTRWeeklyRetention=''; LTRMonthlyRetention=''; LTRYearlyRetention='' }
Assert-CV 'db-retention Gap (7d, no LTR)' (Outcome (Invoke-CVResilience -Resource $sqlShort -Controls $ctl.SQL) 'db-retention') 'Gap'
$sqlLtr = [pscustomobject]@{ PITR_Days=7; LTRWeeklyRetention=''; LTRMonthlyRetention='P12M'; LTRYearlyRetention='' }
Assert-CV 'db-retention Met via LTR'  (Outcome (Invoke-CVResilience -Resource $sqlLtr -Controls $ctl.SQL) 'db-retention') 'Met'

Write-Host "`n[4] Storage - geo from SKU, enriched fields"
$st = [pscustomobject]@{ StorageAccountSkuName='Standard_LRS'; BlobVersioning=$true; PublicAccessBlocked=$true; CmkEncrypted=$false; SoftDeleteEnabled=$true }  # ImmutabilityLocked absent
$e = Invoke-CVResilience -Resource $st -Controls $ctl.Storage
Assert-CV 'st-xregion Gap (LRS)'      (Outcome $e 'st-xregion') 'Gap'
Assert-CV 'st-versioning Met'         (Outcome $e 'st-versioning') 'Met'
Assert-CV 'st-public Met'             (Outcome $e 'st-public') 'Met'
Assert-CV 'st-cmek Gap'               (Outcome $e 'st-cmek') 'Gap'
Assert-CV 'st-immutable Unknown'      (Outcome $e 'st-immutable') 'Unknown'

Write-Host "`n[5] FileShare - geo + encrypted"
$fs = [pscustomobject]@{ StorageAccountSkuName='Standard_RAGRS'; EncryptedAtRest=$true }  # HasBackup absent
$e = Invoke-CVResilience -Resource $fs -Controls $ctl.FileShare
Assert-CV 'fs-xregion Met'   (Outcome $e 'fs-xregion') 'Met'
Assert-CV 'fs-encrypted Met' (Outcome $e 'fs-encrypted') 'Met'
Assert-CV 'fs-backup Unknown' (Outcome $e 'fs-backup') 'Unknown'

Write-Host "`n[6] Empty environment + no Clean Recovery controls"
Assert-CV 'empty summary null'  ($null -eq (Get-CVResilienceSummary -Results @()).OverallScore) $true
$cats = ($ctl.Values | ForEach-Object { $_ } | ForEach-Object { $_.Category }) | Sort-Object -Unique
Assert-CV 'no CleanRecovery for Azure' ($cats -contains 'CleanRecovery') $false

Write-Host ("`n{0}  {1} passed, {2} failed  {0}" -f ('=' * 6), $script:Pass, $script:Fail) -ForegroundColor ($script:Fail ? 'Red' : 'Green')
exit ($script:Fail -gt 0 ? 1 : 0)
