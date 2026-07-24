#requires -Version 7.2
<#
    Invoke-CVConsoleTests.ps1 - Dependency-free test suite for common/CVSizing.Console.ps1.

    Intentionally does NOT require Pester: these scripts run in cloud shells / containers where installing extra
    modules is exactly the friction we are trying to remove. Run with:

        pwsh -File tests/Invoke-CVConsoleTests.ps1

    Exit code 0 = all passed, 1 = one or more failed.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Console.ps1')
$helperPath = (Resolve-Path (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Console.ps1')).Path

$script:Pass = 0; $script:Fail = 0
function Assert-CV {
    param([string]$Name, [Parameter(Mandatory)]$Actual, [Parameter(Mandatory)]$Expected)
    if ($Actual -eq $Expected) { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name  (expected '$Expected', got '$Actual')" -ForegroundColor Red }
}
function Assert-True { param([string]$Name, [bool]$Condition) Assert-CV -Name $Name -Actual $Condition -Expected $true }
function New-TmpLog { Join-Path ([System.IO.Path]::GetTempPath()) "cvt_$([Guid]::NewGuid().ToString('N')).log" }

# ---------------------------------------------------------------------------
Write-Host "`n[1] Capability detection"
$c1 = Get-CVConsoleCapability -NonInteractive
Assert-CV 'NonInteractive -> Plain-Headless' $c1.Tier 'Plain-Headless'
$c2 = Get-CVConsoleCapability -ForceRich
Assert-CV 'ForceRich -> Spectre' $c2.Tier 'Spectre'
$c3 = Get-CVConsoleCapability -Quiet
Assert-True 'Quiet is headless' $c3.IsHeadless

# ---------------------------------------------------------------------------
Write-Host "`n[2] Diagnostics dedup + console suppression + full log detail"
$log = New-TmpLog
Initialize-CVConsole -Cloud AWS -LogPath $log -NonInteractive | Out-Null
$regions = 'us-east-1','us-west-2','eu-west-1','ap-south-1','sa-east-1'
# capture console output via the information stream
$out = & {
    foreach ($r in $regions) {
        Write-CVLog "Failed to get EC2 in region $r : timed out after 30000 ms" -Level Error -Source 'EC2' -Scope @{ Region = $r }
    }
} 6>&1 | Out-String
$diags = @(Get-CVDiagnostics)
Assert-CV 'dedup: 1 distinct signature' $diags.Count 1
Assert-CV 'dedup: aggregated count = 5' $diags[0].Count 5
Assert-CV 'dedup: 5 affected scopes' $diags[0].AffectedScopes.Count 5
Assert-CV 'dedup: categorized as Timeout' $diags[0].Category 'Timeout'
$consoleErrLines = @($out -split "`n" | Where-Object { $_ -match '\[ERROR\] \[EC2\]' }).Count
Assert-CV 'console: only 1 of 5 rendered' $consoleErrLines 1
$logErrLines = @(Get-Content $log | Where-Object { $_ -match 'Failed to get EC2 in region' }).Count
Assert-CV 'log: all 5 preserved' $logErrLines 5
Remove-Item $log -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Write-Host "`n[3] Scope substitution collapses different volatile values"
$log = New-TmpLog
Initialize-CVConsole -Cloud Azure -LogPath $log -NonInteractive | Out-Null
Write-CVLog "Error in subscription /subscriptions/11111111-1111-1111-1111-111111111111 processing SQL" -Level Warning -Source 'SQL' -Scope @{ Sub = '11111111-1111-1111-1111-111111111111' }
Write-CVLog "Error in subscription /subscriptions/22222222-2222-2222-2222-222222222222 processing SQL" -Level Warning -Source 'SQL' -Scope @{ Sub = '22222222-2222-2222-2222-222222222222' }
$d = @(Get-CVDiagnostics)
Assert-CV 'two subs -> one signature' $d.Count 1
Assert-CV 'two subs -> count 2' $d[0].Count 2
Remove-Item $log -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Write-Host "`n[4] Runspace safety: worker records replay + aggregate on parent"
$log = New-TmpLog
Initialize-CVConsole -Cloud GCP -LogPath $log -NonInteractive | Out-Null
$W = 6; $N = 40
$lists = 1..$W | ForEach-Object -ThrottleLimit 6 -Parallel {
    . $using:helperPath
    $l = [System.Collections.Generic.List[object]]::new()
    $log = New-CVWorkerLogger -RecordList $l
    $p = "proj-$_"
    for ($i = 0; $i -lt $using:N; $i++) { & $log "Failed to size bucket in $p : deadline exceeded" 'Error' 'Storage' @{ Project = $p } }
    ,$l
}
$replayed = 0
foreach ($l in $lists) { $replayed += $l.Count; Receive-CVWorkerRecords $l }
$d = @(Get-CVDiagnostics)
Assert-CV 'runspace: all records emitted' $replayed ($W * $N)
Assert-CV 'runspace: collapse to 1 signature' $d.Count 1
Assert-CV 'runspace: aggregated count' $d[0].Count ($W * $N)
Assert-CV 'runspace: distinct project scopes' $d[0].AffectedScopes.Count $W
Remove-Item $log -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Write-Host "`n[5] Off-owner-thread guard defers rendering"
$log = New-TmpLog
Initialize-CVConsole -Cloud AWS -LogPath $log -NonInteractive | Out-Null
$saved = $script:CVConsole.OwnerThreadId
$script:CVConsole.OwnerThreadId = -12345
Write-CVLog 'deferred' -Level Info -Source 'Guard'
Assert-CV 'guard: enqueued while off-thread' $script:CVConsole.Pending.Count 1
$script:CVConsole.OwnerThreadId = $saved
Sync-CVPending
Assert-CV 'guard: drained after sync' $script:CVConsole.Pending.Count 0
Remove-Item $log -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Write-Host "`n[6] Preflight: fatal vs degraded"
$log = New-TmpLog
Initialize-CVConsole -Cloud AWS -LogPath $log -NonInteractive | Out-Null
$okPresent = Assert-CVPreflight -FatalModules @('Microsoft.PowerShell.Management') -ExitOnFatal:$false
Assert-True 'preflight: present required -> true' $okPresent
$okMissing = Assert-CVPreflight -FatalModules @('No.Such.Module.XYZ') -ExitOnFatal:$false
Assert-CV 'preflight: missing required -> false' $okMissing $false
Remove-Item $log -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Write-Host "`n[7] Resolve-CVServicePlan skips services with missing modules"
$log = New-TmpLog
Initialize-CVConsole -Cloud Azure -LogPath $log -NonInteractive | Out-Null
$map = @{ VM = @('Microsoft.PowerShell.Management'); NETAPP = @('Az.NetAppFiles.Missing'); COSMOS = @('Az.CosmosDB.Missing') }
$plan = Resolve-CVServicePlan -ServiceModuleMap $map -Selected @('VM','NETAPP','COSMOS')
Assert-CV 'plan: 1 runnable' $plan.Runnable.Count 1
Assert-CV 'plan: runnable is VM' $plan.Runnable[0] 'VM'
Assert-CV 'plan: 2 skipped' $plan.Skipped.Count 2
Remove-Item $log -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Write-Host "`n[8] Spectre-absent fallback does not throw"
$log = New-TmpLog
$threw = $false
try {
    Initialize-CVConsole -Cloud AWS -LogPath $log -ForceRich | Out-Null
    Write-CVSection 'Rich [with] brackets'
    Write-CVLog 'rich line [x]' -Level Warning -Source 'X'
    Write-CVSummary
} catch { $threw = $true }
Assert-CV 'spectre fallback: no throw' $threw $false
Remove-Item $log -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Write-Host ("`n{0}  {1} passed, {2} failed  {0}" -f ('=' * 6), $script:Pass, $script:Fail) -ForegroundColor ($script:Fail ? 'Red' : 'Green')
exit ($script:Fail -gt 0 ? 1 : 0)
