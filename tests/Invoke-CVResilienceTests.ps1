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

Write-Host "`n[4] Per-control outcomes exposed on the evaluation (raw, for Get-CVProtectionData)"
Assert-CV 'enc-cmk outcome Met' (($e.Results | Where-Object Id -eq 'enc-cmk').Outcome) 'Met'
Assert-CV 'backup outcome Gap'  (($e.Results | Where-Object Id -eq 'backup').Outcome)  'Gap'

Write-Host "`n[5] Empty environment (0 resources) -> null score, no error"
Assert-CV 'empty score helper -> null' ($null -eq (Get-CVControlScore -Results @())) $true

Write-Host ("`n{0}  {1} passed, {2} failed  {0}" -f ('=' * 6), $script:Pass, $script:Fail) -ForegroundColor ($script:Fail ? 'Red' : 'Green')
exit ($script:Fail -gt 0 ? 1 : 0)
