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
    $l = [System.Collections.Generic.List[psobject]]::new()
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
Write-Host "`n[8] Export-CVCsv never silently drops a column"
# Export-Csv builds its header from the FIRST object only. Our rows are heterogeneous (Tag_* is flattened per
# resource; error paths emit a short object), so one untagged first row erased every Tag_ column in the file -
# which reads as "the tool doesn't collect tags".
$csv  = [IO.Path]::Combine([IO.Path]::GetTempPath(), "cv-csv-$([guid]::NewGuid().ToString('N').Substring(0,8)).csv")
$few  = [pscustomobject]@{ Name = 'a'; Type = 'x' }
$many = [pscustomobject]@{ Name = 'b'; Type = 'x'; Tag_env = 'prod'; StorageGB = 10 }
$mid  = [pscustomobject]@{ Name = 'c'; Type = 'y' }

@($few, $many) | Export-CVCsv -Path $csv
$hdr = (Get-Content $csv)[0]
Assert-CV 'first row with FEWER props keeps later columns' $hdr '"Name","Type","Tag_env","StorageGB"'
Assert-CV 'all rows written' ((Get-Content $csv).Count) 3

@($few, $many, $mid) | Export-CVCsv -Path $csv
Assert-CV 'extra property on a MIDDLE row is kept' ((Get-Content $csv)[0]) '"Name","Type","Tag_env","StorageGB"'

@($few, $many) | Export-CVCsv -Path $csv -PreferredOrder @('Type','Name')
Assert-CV '-PreferredOrder fixes leading column order' ((Get-Content $csv)[0]) '"Type","Name","Tag_env","StorageGB"'

@($few, $many) | Export-CVCsv -Path $csv -PreferredOrder @('Type','NeverPresent','Name')
Assert-CV 'preferred names absent from all rows are dropped' ((Get-Content $csv)[0]) '"Type","Name","Tag_env","StorageGB"'

@() | Export-CVCsv -Path $csv -PreferredOrder @('Name','Type')
Assert-CV 'empty input writes a header-only file' ((Get-Content $csv) -join '|') '"Name","Type"'

# Round-trip the values, not just the header.
@($few, $many) | Export-CVCsv -Path $csv
$back = Import-Csv $csv
Assert-CV 'row 1 Tag_env is empty, not missing' ($null -ne $back[0].PSObject.Properties['Tag_env']) $true
Assert-CV 'row 2 Tag_env survived'              $back[1].Tag_env 'prod'
Assert-CV 'row 2 StorageGB survived'            $back[1].StorageGB '10'

# Reported from the field: cloud tag keys preserve case, so an estate tagging some resources 'owner' and others
# 'Owner' produced one "the property ... already exists" error PER ROW. OrderedDictionary defaults to a
# case-SENSITIVE comparer while Select-Object resolves properties case-insensitively, so case variants were
# admitted as separate columns and then rejected. The CSV was still correct - the errors were pure noise - but
# a screen of red during output writing reads like data loss.
$caseA = [pscustomobject]@{ VMName = 'vm1'; Tag_Demoroom = 'yes'; Tag_owner = 'grant' }
$caseB = [pscustomobject]@{ VMName = 'vm2'; Tag_demoroom = 'no';  Tag_Owner = 'chris' }
$err = $null
@($caseA, $caseB) | Export-CVCsv -Path $csv -ErrorVariable err -ErrorAction SilentlyContinue
Assert-CV 'case-variant tag keys emit no errors' (@($err).Count) 0
$hdr = (Get-Content $csv)[0]
Assert-CV 'collapsed to one column per tag, first casing wins' $hdr '"VMName","Tag_Demoroom","Tag_owner"'
# Collapsing must not lose the other row's value - property lookup is case-insensitive, so it still resolves.
$rt = Import-Csv $csv
Assert-CV 'row 1 value kept'                    $rt[0].Tag_Demoroom 'yes'
Assert-CV 'row 2 differently-cased value kept'  $rt[1].Tag_Demoroom 'no'
Assert-CV 'row 2 differently-cased owner kept'  $rt[1].Tag_owner 'chris'
# Same collision via -PreferredOrder rather than between rows.
$err = $null
@($caseB) | Export-CVCsv -Path $csv -PreferredOrder @('VMName','Tag_Demoroom') -ErrorVariable err -ErrorAction SilentlyContinue
Assert-CV 'preferred-order casing collision is clean' (@($err).Count) 0
Assert-CV 'preferred casing wins over row casing' ((Get-Content $csv)[0]) '"VMName","Tag_Demoroom","Tag_Owner"'
Remove-Item $csv -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Write-Host "`n[9] Runspace workers can log without the parent's functions"
# The GCP bucket-sizing worker called the parent's Write-Log, which is NOT in scope inside a runspace built from
# [InitialSessionState]::CreateDefault() - so every bucket whose gsutil du failed threw CommandNotFoundException
# instead of warning. The fix passes a ConcurrentQueue by argument; this proves that pattern works end to end.
$log = New-TmpLog
Initialize-CVConsole -Cloud GCP -LogPath $log -NonInteractive | Out-Null
$q = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$worker = {
    param($queue)
    function Write-Log { param([string]$Message, [string]$Level = 'INFO') if ($queue) { $queue.Enqueue("[$Level] $Message") } }
    Write-Log -Level WARN -Message 'gsutil du failed for bucket-a'
    Write-Log -Level WARN -Message 'gsutil du failed for bucket-b'
    'done'
}
$iss  = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$pool = [RunspaceFactory]::CreateRunspacePool(1, 1, $iss, $Host); $pool.Open()
$ps   = [PowerShell]::Create().AddScript($worker).AddArgument($q); $ps.RunspacePool = $pool
$res  = Get-CVRunspaceResult $ps.EndInvoke($ps.BeginInvoke())
$ps.Dispose(); $pool.Close(); $pool.Dispose()
Assert-CV 'worker completed'            $res 'done'
Assert-CV 'worker enqueued both lines'  $q.Count 2
$threw = $false
$drained = 0; $line = $null
try {
    while ($q.TryDequeue([ref]$line)) { $drained++; Receive-CVWorkerRecords $line }
} catch { $threw = $true }
Assert-CV 'parent drained the queue'    $drained 2
Assert-CV 'raw strings replay without throwing' $threw $false
Remove-Item $log -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Write-Host "`n[10] Multi-line CLI stderr does not garble the terminal"
# gcloud hard-wraps its PERMISSION_DENIED text, and workers hand that raw string straight to Write-CVLog. A
# multi-line Write-Host paints several full-width rows; the native progress pane repaints over them but erases
# only $PSStyle.Progress.MaxWidth (default 120) columns, so the tail of every wrapped row survived on screen and
# scrolled into history glued onto unrelated lines. Console render must flatten; the log file must not.
$log = New-TmpLog
Initialize-CVConsole -Cloud GCP -LogPath $log -NonInteractive | Out-Null
$gcloudErr = "ERROR: (gcloud.filestore.instances.list) PERMISSION_DENIED: Cloud Filestore API has not been used`n" +
             "in project pm-ai-agents-customer-demo before or it is disabled.`r`n" +
             "  Enable it by visiting https://console.developers.google.com/apis/api/file.googleapis.com then retry."
$out = & { Write-CVLog $gcloudErr -Level Warning -Source 'FS' -Scope @{ Project = 'demo' } } 6>&1 | Out-String
$rendered = @($out -split "`r?`n" | Where-Object { $_ -match '\[FS\]' })
Assert-CV 'console: 3-line stderr renders as 1 row' $rendered.Count 1
Assert-True 'console: head of message kept'   ($rendered[0] -match 'PERMISSION_DENIED')
Assert-True 'console: tail of message kept'   ($rendered[0] -match 'then retry\.$')
Assert-True 'console: no interior newline'    ($rendered[0] -notmatch "`r|`n")
Assert-True 'log: full untruncated text kept' (@(Get-Content $log | Where-Object { $_ -match 'file\.googleapis\.com' }).Count -eq 1)
Remove-Item $log -ErrorAction SilentlyContinue

# The other half of the fix: the progress pane must erase the full terminal row, not 120 columns of it.
$before = $PSStyle.Progress.MaxWidth
$PSStyle.Progress.MaxWidth = 120
Set-CVProgressWidth
$want = try { $Host.UI.RawUI.WindowSize.Width } catch { 120 }
if ($want -ge 18) { Assert-CV 'progress pane erases the full terminal width' $PSStyle.Progress.MaxWidth $want }
else              { Assert-CV 'narrow/absent RawUI leaves the default alone'  $PSStyle.Progress.MaxWidth 120 }
$PSStyle.Progress.MaxWidth = $before

# ---------------------------------------------------------------------------
Write-Host "`n[11] Az.Accounts conflict detection (the 'Assembly with same name is already loaded' trap)"
# Hermetic: PSModulePath is REPLACED with a fake tree, so results do not depend on what Az happens to be
# installed on the machine running the tests. Restored in the finally block.
$fakeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "cvmod_$([Guid]::NewGuid().ToString('N'))"
$savedPSModulePath = $env:PSModulePath
function New-FakeModule {
    param([string]$Name, [string]$Version, [string]$AccountsMinimum)
    $dir = Join-Path $fakeRoot (Join-Path $Name $Version)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $list = if ($AccountsMinimum) { "ModuleList = @(@{ModuleName = 'Az.Accounts'; ModuleVersion = '$AccountsMinimum'; })" } else { '' }
    @"
@{
    ModuleVersion = '$Version'
    GUID = '$([Guid]::NewGuid())'
    Author = 'test'
    Description = 'fake module for CV console tests'
    FunctionsToExport = @()
    CmdletsToExport = @()
    RequiredModules = @()
    $list
}
"@ | Set-Content -Path (Join-Path $dir "$Name.psd1") -Encoding utf8
    return $dir
}
try {
    New-FakeModule -Name 'Az.Accounts' -Version '5.5.2' | Out-Null
    New-FakeModule -Name 'Az.Network'  -Version '8.1.0' -AccountsMinimum '5.5.2' | Out-Null
    New-FakeModule -Name 'Az.Sql'      -Version '7.0.0' -AccountsMinimum '5.5.0' | Out-Null
    $env:PSModulePath = $fakeRoot

    # The floor is the MAX of the declared minimums, and it names which module set it.
    $floor = Get-CVAzAccountsFloor -Name @('Az.Accounts','Az.Network','Az.Sql')
    Assert-CV 'floor: max of declared minimums' $floor.Version '5.5.2'
    Assert-CV 'floor: attributed to the demanding module' $floor.By 'Az.Network'

    # Satisfied floor, single copy -> completely silent.
    $clean = Test-CVAzModuleConflict -Name @('Az.Accounts','Az.Network','Az.Sql')
    Assert-CV 'clean install: no fatal' $clean.Fatal.Count 0
    Assert-CV 'clean install: no warning' $clean.Warning.Count 0

    # Non-Az runs (AWS/GCP) must not pay for this check at all.
    $awsOnly = Test-CVAzModuleConflict -Name @('AWS.Tools.EC2','AWS.Tools.S3')
    Assert-CV 'non-Az module set: no-op' ($awsOnly.Fatal.Count + $awsOnly.Warning.Count) 0

    # A second copy on PSModulePath is a WARNING, not fatal: importing Az.Accounts first (as the scripts do)
    # makes it harmless, so blocking here would fail machines that work today.
    # Sibling, NOT a child of $fakeRoot: a second scope nested inside the first stays discoverable after
    # $env:PSModulePath is narrowed back, which silently defeats the below-floor cases that follow.
    $second = "${fakeRoot}_scope2"
    New-Item -ItemType Directory -Force -Path (Join-Path $second 'Az.Accounts/5.5.2') | Out-Null
    Copy-Item (Join-Path $fakeRoot 'Az.Accounts/5.5.2/Az.Accounts.psd1') (Join-Path $second 'Az.Accounts/5.5.2/') -Force
    $env:PSModulePath = "$fakeRoot$([IO.Path]::PathSeparator)$second"
    $dupe = Test-CVAzModuleConflict -Name @('Az.Accounts','Az.Network')
    Assert-CV 'duplicate copies: warns' $dupe.Warning.Count 1
    Assert-CV 'duplicate copies: not fatal' $dupe.Fatal.Count 0
    Assert-True 'duplicate warning names the real error' ($dupe.Warning[0] -match 'Assembly with same name is already loaded')
    $env:PSModulePath = $fakeRoot

    # Newest installed below the floor -> fatal, because no import order can rescue it.
    Remove-Item (Join-Path $fakeRoot 'Az.Accounts/5.5.2') -Recurse -Force
    New-FakeModule -Name 'Az.Accounts' -Version '5.0.0' | Out-Null
    $tooOld = Test-CVAzModuleConflict -Name @('Az.Accounts','Az.Network')
    Assert-CV 'installed below floor: fatal' $tooOld.Fatal.Count 1
    Assert-True 'below-floor message names both versions' ($tooOld.Fatal[0] -match '5\.0\.0' -and $tooOld.Fatal[0] -match '5\.5\.2')

    # ...and Assert-CVPreflight refuses the run rather than letting it die inside Import-Module.
    $log = New-TmpLog
    Initialize-CVConsole -Cloud Azure -LogPath $log -NonInteractive | Out-Null
    $blocked = Assert-CVPreflight -FatalModules @('Az.Accounts','Az.Network') -ExitOnFatal:$false
    Assert-CV 'preflight blocks the conflicting run' $blocked $false
    Remove-Item $log -ErrorAction SilentlyContinue

    # Poisoned session: a too-old Az.Accounts already IMPORTED. This is the case with no in-process repair, and
    # the one that previously surfaced as an unreadable wall of loader errors.
    #
    # Runs in a CHILD process on purpose. This session cannot host the case: Initialize-CVConsole -Cloud Azure
    # (section [7] above) probes `Get-Command Update-AzConfig`, and that command discovery auto-imports the real
    # Az.Accounts off the machine. With a newer real copy loaded alongside the fake, the check correctly sees a
    # satisfied floor and the assertion would be testing the wrong branch.
    $childScript = Join-Path $fakeRoot 'poisoned.ps1'
    @"
. '$helperPath'
`$env:PSModulePath = '$fakeRoot'
Import-Module '$(Join-Path $fakeRoot 'Az.Accounts/5.0.0/Az.Accounts.psd1')' -Force
if (@(Get-Module -Name Az.Accounts).Count -ne 1) { 'SETUP-DIRTY'; exit 1 }
(Test-CVAzModuleConflict -Name @('Az.Accounts','Az.Network')).Fatal -join ' | '
"@ | Set-Content -Path $childScript -Encoding utf8
    $childOut = (& pwsh -NoProfile -File $childScript 2>&1 | Out-String)
    Assert-True 'poisoned-session setup: only the fake Az.Accounts is loaded' ($childOut -notmatch 'SETUP-DIRTY')
    Assert-True 'loaded-too-old says the session cannot be repaired' ($childOut -match 'already loaded in this session')
    Assert-True 'loaded-too-old names the version actually loaded'   ($childOut -match '5\.0\.0')
}
finally {
    $env:PSModulePath = $savedPSModulePath
    Remove-Item $fakeRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "${fakeRoot}_scope2" -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
Write-Host ("`n{0}  {1} passed, {2} failed  {0}" -f ('=' * 6), $script:Pass, $script:Fail) -ForegroundColor ($script:Fail ? 'Red' : 'Green')
exit ($script:Fail -gt 0 ? 1 : 0)
