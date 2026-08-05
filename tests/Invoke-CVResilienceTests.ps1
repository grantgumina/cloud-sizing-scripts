#requires -Version 7.2
<#  Dependency-free tests for the resilience scoring engine (src/common/CVSizing.Resilience.ps1). #>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.ps1')

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }

# Controls exercising every outcome + severity.
$controls = @(
    New-CVControl -Id 'enc-cmk'  -Title 'CMK encryption'   -Category DataExposure  -Severity High     -Test { param($r) $r.Cmk }
    New-CVControl -Id 'backup'   -Title 'Managed backup'   -Category RecoveryReady -Severity Critical -Test { param($r) $r.Backup }
    New-CVControl -Id 'xregion'  -Title 'Secondary region' -Category Availability   -Severity Medium   -Test { param($r) $r.XRegion }
    New-CVControl -Id 'versioning' -Title 'Versioning'     -Category Immutability   -Severity High     -Test { param($r) $null }   # Unknown
)

Write-Host "`n[1] Scoring math (Unknown excluded, severity-weighted)"
# Cmk=Met(High,2), Backup=Gap(Critical,3), XRegion=Met(Medium,1), versioning=Unknown(excluded)
# den = 2+3+1 = 6 ; num(Met) = 2+1 = 3 -> 50
$e = Invoke-CVResilience -Resource ([pscustomobject]@{ Cmk=$true; Backup=$false; XRegion=$true }) -Controls $controls
Assert-CV 'weighted score = 50' $e.Score 50
Assert-CV 'met count = 2'       $e.MetCount 2
Assert-CV 'gap count = 1'       $e.GapCount 1
Assert-CV 'unknown count = 1'   $e.UnknownCount 1
Assert-CV 'gap is the Critical' ($e.Gaps -join ',') 'Critical:backup'

Write-Host "`n[2] All-unknown resource -> null score (nothing assessed)"
$e2 = Invoke-CVResilience -Resource ([pscustomobject]@{}) -Controls @(
    New-CVControl -Id x -Title x -Category DataExposure -Severity High -Test { $null } )
Assert-CV 'score is null' ($null -eq $e2.Score) $true

Write-Host "`n[3] N/A excluded like Unknown"
$e3 = Invoke-CVResilience -Resource ([pscustomobject]@{ A=$true }) -Controls @(
    New-CVControl -Id a -Title a -Category Immutability -Severity High -Test { param($r) $r.A }
    New-CVControl -Id b -Title b -Category Immutability -Severity Critical -Test { 'NA' } )
Assert-CV 'NA does not lower score (100)' $e3.Score 100

Write-Host "`n[4] Flatten to inventory columns"
$cols = ConvertTo-CVResilienceColumns -Evaluation $e
Assert-CV 'per-control column present' $cols['Ctl_enc-cmk'] 'Met'
Assert-CV 'ResilienceScore column'    $cols['ResilienceScore'] 50
Assert-CV 'ResilienceGaps column'     $cols['ResilienceGaps'] 'Critical:backup'

Write-Host "`n[5] Cross-resource summary (category posture + top gaps)"
# 3 resources: backup Gap on all 3 (Critical), cmk Met on 2 of 3.
$all = @()
foreach ($rc in @(
    [pscustomobject]@{ Cmk=$true;  Backup=$false; XRegion=$true },
    [pscustomobject]@{ Cmk=$true;  Backup=$false; XRegion=$false },
    [pscustomobject]@{ Cmk=$false; Backup=$false; XRegion=$true })) {
    $all += (Invoke-CVResilience -Resource $rc -Controls $controls).Results
}
$sum = Get-CVResilienceSummary -Results $all
$rr = @($sum.ByCategory | Where-Object Category -eq 'RecoveryReady')[0]
Assert-CV 'RecoveryReady 0% met (all backups gap)' $rr.PercentMet 0
$de = @($sum.ByCategory | Where-Object Category -eq 'DataExposure')[0]
Assert-CV 'DataExposure 67% met (2 of 3 CMK)' $de.PercentMet 67
Assert-CV 'top gap is backup'      $sum.TopGaps[0].Id 'backup'
Assert-CV 'top gap counted 3x'     $sum.TopGaps[0].Count 3
Assert-CV 'versioning excluded from summary' (@($sum.ByCategory | Where-Object Category -eq 'Immutability').Count) 0

Write-Host "`n[6] Empty environment (0 resources) -> null score, no error"
$empty = Get-CVResilienceSummary -Results @()
Assert-CV 'empty summary: OverallScore null' ($null -eq $empty.OverallScore) $true
Assert-CV 'empty summary: ByCategory empty'  $empty.ByCategory.Count 0
Assert-CV 'empty summary: TopGaps empty'     $empty.TopGaps.Count 0
Assert-CV 'empty score helper -> null'       ($null -eq (Get-CVControlScore -Results @())) $true

Write-Host ("`n{0}  {1} passed, {2} failed  {0}" -f ('=' * 6), $script:Pass, $script:Fail) -ForegroundColor ($script:Fail ? 'Red' : 'Green')
exit ($script:Fail -gt 0 ? 1 : 0)
