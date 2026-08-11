#requires -Version 7.2
<#  Control catalog <-> documentation consistency.

    The per-resource gap report was removed (the sizing outputs are now raw protection data - no scoring,
    no severity). What still matters is that every control the code defines is documented in
    CYBER_RESILIENCE_REPORT.md, and that Critical controls are marked Critical there: the doc is the
    reference report-generator authors use to understand what each raw protection field is derived from.
    Module lists in docs/ have silently drifted from the code before; this stops the same happening here.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }

$repoRoot = Split-Path -Parent (Join-Path $PSScriptRoot '..' 'src')
$docPath  = Join-Path $repoRoot 'CYBER_RESILIENCE_REPORT.md'
Assert-CV 'CYBER_RESILIENCE_REPORT.md exists' (Test-Path -LiteralPath $docPath) $true
$readme = Get-Content -Raw $docPath

. (Join-Path $repoRoot 'src' 'common' 'CVSizing.Resilience.ps1')
$defined = @()
foreach ($spec in @(@{c='Azure';f='Get-CVAzureResilienceControls'},
                    @{c='GCP';  f='Get-CVGcpResilienceControls'},
                    @{c='AWS';  f='Get-CVAwsResilienceControls'})) {
    . (Join-Path $repoRoot 'src' 'common' "CVSizing.Resilience.$($spec.c).ps1")
    $sets = & $spec.f
    foreach ($t in $sets.Keys) { foreach ($c in $sets[$t]) { $defined += [pscustomobject]@{ Cloud=$spec.c; Id=$c.Id; Severity=$c.Severity } } }
}
$defined = @($defined | Sort-Object Cloud, Id -Unique)
Assert-CV 'controls exist to document' ([bool]($defined.Count -gt 0)) $true

$undocumented = @($defined | Where-Object { $readme -notmatch [regex]::Escape('`' + $_.Id + '`') })
Assert-CV 'every control id appears in the doc' $undocumented.Count 0
if ($undocumented.Count) { $undocumented | ForEach-Object { Write-Host "        undocumented: $($_.Cloud) $($_.Id)" -ForegroundColor DarkYellow } }

$ids   = @($defined.Id | Sort-Object -Unique)
$inDoc = @([regex]::Matches($readme, '\|\s*`([a-z0-9]+-[a-z0-9]+)`\s*\|') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$stale = @($inDoc | Where-Object { $ids -notcontains $_ })
Assert-CV 'doc describes no control that no longer exists' $stale.Count 0
if ($stale.Count) { Write-Host "        stale: $($stale -join ', ')" -ForegroundColor DarkYellow }

# Severity is not emitted anywhere anymore, but the doc still records it for the report generator - keep it honest.
$sevWrong = @($defined | Where-Object { $_.Severity -eq 'Critical' -and
                $readme -notmatch ('`' + [regex]::Escape($_.Id) + '`[^\r\n]*\*\*Critical\*\*') })
Assert-CV 'Critical controls are marked Critical in the doc' $sevWrong.Count 0
if ($sevWrong.Count) { $sevWrong | ForEach-Object { Write-Host "        severity not shown: $($_.Cloud) $($_.Id)" -ForegroundColor DarkYellow } }

Write-Host ("`n======  {0} passed, {1} failed  ======`n" -f $script:Pass, $script:Fail) `
           -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
