<#
    CVSizing.Console.ps1 - Shared console / diagnostics layer for the CV cloud-sizing scripts.

    One dot-sourceable helper used by the AWS / Azure / GCP sizing scripts. It owns:
      - console output & structured file logging (Write-CVLog / Write-CVSection)
      - progress reporting (Start/Update/Complete-CVProgress)
      - aggregated, de-duplicated diagnostics + an end-of-run summary (Add/Get-CVDiagnostic(s), Write-CVSummary)
      - dependency preflight (Test-CVModuleDependency / Test-CVCommandDependency / Resolve-CVServicePlan / Assert-CVPreflight)
      - native module noise suppression (Set-CVNativeNoiseSuppression)
      - runspace-safe worker logging (New-CVWorkerLogger / Receive-CVWorkerRecords)

    Rendering has two tiers, chosen once at Initialize-CVConsole:
      - Spectre         : PwshSpectreConsole present AND an interactive TTY -> rich rules / markup / summary panels.
      - Plain-Headless  : stdout redirected / container / CI / -NonInteractive / -Quiet -> plain structured lines, no progress.
    A "Plain-Interactive" style (native $PSStyle color + Write-Progress) is used when a TTY is present but Spectre is not.

    The live progress bar always uses native Write-Progress (styled by $PSStyle); Spectre is reserved for the
    scrolling-friendly polish (rules, colored status, summary panels/tables). This matches the "polished scrolling
    output" design goal rather than a screen-owning live dashboard.

    Requires PowerShell 7.2+ ($PSStyle). Safe to dot-source more than once.
#>

#region ---------------------------------------------------------------- State

# Module-scoped state object. Rebuilt by Initialize-CVConsole.
if (-not (Get-Variable -Name CVConsole -Scope Script -ErrorAction SilentlyContinue)) {
    $script:CVConsole = $null
}

#endregion

#region ---------------------------------------------------------- Capability detection

function Get-CVConsoleCapability {
    <#
      .SYNOPSIS  Decide the render tier from the environment. Pure / side-effect free (safe to unit-test).
      .OUTPUTS   pscustomobject with Tier + all raw signals + a human Reason.
    #>
    [CmdletBinding()]
    param(
        [switch]$ForcePlain,
        [switch]$ForceRich,
        [switch]$NonInteractive,
        [switch]$Quiet
    )

    # --- raw signals ---
    $redir     = [Console]::IsOutputRedirected -or [Console]::IsErrorRedirected
    $container = [bool]$env:KUBERNETES_SERVICE_HOST -or (Test-Path -LiteralPath '/.dockerenv' -ErrorAction SilentlyContinue) -or [bool]$env:CV_SIZING_HEADLESS
    $ci        = [bool]($env:CI -or $env:TF_BUILD -or $env:GITHUB_ACTIONS -or $env:BUILD_BUILDID)
    $noColor   = [bool]$env:NO_COLOR -or ($PSStyle -and $PSStyle.OutputRendering -eq 'PlainText')
    $spectre   = [bool](Get-Module -ListAvailable -Name PwshSpectreConsole -ErrorAction SilentlyContinue)
    $cloudShell = ($env:AWS_EXECUTION_ENV -like '*CloudShell*') -or
                  [bool]$env:AZUREPS_HOST_ENVIRONMENT -or [bool]$env:ACC_CLOUD -or
                  ($env:CLOUD_SHELL -eq 'true')

    $forcedPlain = $ForcePlain -or $NonInteractive -or $Quiet -or $redir -or $container -or $ci

    # --- decision ---
    if ($forcedPlain -and -not $ForceRich) {
        $tier = 'Plain-Headless'
        $reason =
            if     ($ForcePlain)     { 'ForcePlain' }
            elseif ($NonInteractive) { 'NonInteractive' }
            elseif ($Quiet)          { 'Quiet' }
            elseif ($container)      { 'Container' }
            elseif ($ci)             { 'CI' }
            elseif ($redir)          { 'OutputRedirected' }
            else                     { 'NonInteractive' }
    }
    elseif ($ForceRich -or ($spectre -and -not $noColor)) {
        $tier   = 'Spectre'
        $reason = if ($ForceRich) { 'ForceRich' } elseif ($cloudShell) { 'Spectre (cloud shell)' } else { 'Spectre (interactive)' }
    }
    else {
        $tier   = 'Plain-Interactive'
        $reason = if ($noColor) { 'NO_COLOR/PlainText' } else { 'Spectre module not available' }
    }

    [pscustomobject]@{
        Tier             = $tier
        IsInteractive    = -not ($redir -or $container -or $ci -or $NonInteractive -or $Quiet)
        IsHeadless       = ($tier -eq 'Plain-Headless')
        IsCloudShell     = [bool]$cloudShell
        SpectreAvailable = $spectre
        Quiet            = [bool]$Quiet
        RefreshHz        = if ($cloudShell) { 4 } else { 10 }
        Reason           = $reason
        # raw signals (for tests / diagnostics)
        Redirected       = $redir
        Container        = $container
        CI               = $ci
        NoColor          = $noColor
    }
}

#endregion

#region ---------------------------------------------------------------- Initialization

function Initialize-CVConsole {
    <#
      .SYNOPSIS  Set up the shared console state and pick a render tier. Call once, early, per script run.
    #>
    [CmdletBinding()]
    param(
        # Structured log file. Leave empty for console-only mode (e.g. GCP, where Start-Transcript owns the file).
        [string]$LogPath = '',
        [ValidateSet('AWS','Azure','GCP','M365','Generic')][string]$Cloud = 'Generic',
        [string]$Title,
        [switch]$NonInteractive,
        [switch]$Quiet,
        [switch]$ForcePlain,
        [switch]$ForceRich,
        [switch]$ShowDebug
    )

    $cap = Get-CVConsoleCapability -ForcePlain:$ForcePlain -ForceRich:$ForceRich `
                                   -NonInteractive:$NonInteractive -Quiet:$Quiet

    $script:CVConsole = [pscustomobject]@{
        Tier          = $cap.Tier
        Capability    = $cap
        LogPath       = $LogPath
        Cloud         = $Cloud
        Title         = $Title
        StartTime     = Get-Date
        OwnerThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId
        ShowDebug     = [bool]$ShowDebug                                       # console-render Debug lines?
        Diagnostics   = @{}                                                   # signature -> record (guarded by Lock)
        ProgressState = @{}                                                   # id -> @{ IntId; Last; Total; Count }
        ProgressSeq   = [ref]0
        Pending       = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        Lock          = [object]::new()
        Counts        = @{ Info = 0; Success = 0; Warning = 0; Error = 0; Debug = 0 }
    }

    # Quiet native module chatter as early as possible.
    Set-CVNativeNoiseSuppression -Provider $Cloud

    # Header banner (skipped when Quiet).
    if (-not $Quiet -and $Title) {
        Write-CVSection -Title $Title
    }
    Write-CVLog -Message "Console tier: $($cap.Tier) ($($cap.Reason)). Log: $LogPath" -Level Debug -Source 'Console'

    return $script:CVConsole
}

function Test-CVConsoleReady {
    [CmdletBinding()] param()
    return [bool]$script:CVConsole
}

# Internal: are we on the thread that owns the console?
function Test-CVOwnerThread {
    if (-not $script:CVConsole) { return $true }   # uninitialized -> treat caller as owner (best effort)
    return ([System.Threading.Thread]::CurrentThread.ManagedThreadId -eq $script:CVConsole.OwnerThreadId)
}

# Internal: drain any records enqueued by off-thread callers. Parent-thread only.
function Sync-CVPending {
    if (-not $script:CVConsole) { return }
    $rec = $null
    while ($script:CVConsole.Pending.TryDequeue([ref]$rec)) {
        Write-CVRecord -Record $rec
    }
}

#endregion

#region ---------------------------------------------------------------- Run output/log paths

function Get-CVBaseRoot {
    <#
      .SYNOPSIS  The repo top-level directory (nearest ancestor containing a .git), or the current directory when
                 run outside a repo (e.g. a script copied out and run standalone).
    #>
    [CmdletBinding()]
    param([string]$StartPath)
    if (-not $StartPath) { $StartPath = (Get-Location).Path }
    $dir = $StartPath
    while ($dir) {
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) { return $dir }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return (Get-Location).Path
}

function Initialize-CVRunPaths {
    <#
      .SYNOPSIS  Resolve + create this run's output/log locations under the repo top level (or CWD outside a repo):
                   Output/<cloud>_<timestamp>/   (CSVs / JSON / Excel, and the run's .zip sits beside it)
                   Logs/<cloud>_<timestamp>.log
      .OUTPUTS   pscustomobject { Root; RunName; OutputDir; LogsDir; LogPath; ZipPath }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cloud,
        [Parameter(Mandatory)][string]$TimeStamp,
        [string]$StartPath           # pass the calling script's $PSScriptRoot
    )
    $root      = Get-CVBaseRoot -StartPath $StartPath
    $runName   = ('{0}_{1}' -f $Cloud.ToLower(), $TimeStamp)
    $outputTop = Join-Path $root 'Output'
    $outputDir = Join-Path $outputTop $runName
    $logsDir   = Join-Path $root 'Logs'
    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    New-Item -ItemType Directory -Force -Path $logsDir   | Out-Null
    return [pscustomobject]@{
        Root      = $root
        RunName   = $runName
        OutputDir = $outputDir
        LogsDir   = $logsDir
        LogPath   = Join-Path $logsDir  ("$runName.log")
        ZipPath   = Join-Path $outputTop ("$runName.zip")   # sibling of OutputDir (avoids zipping the zip into itself)
    }
}

#endregion

#region ---------------------------------------------------------- Spectre helpers (internal)

# Escape Spectre markup metacharacters so arbitrary log text renders literally.
function ConvertTo-CVSpectreSafe {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace('[', '[[').Replace(']', ']]')
}

$script:CVSpectreColor = @{
    Info    = 'grey85'
    Success = 'green'
    Warning = 'yellow'
    Error   = 'red'
    Debug   = 'grey50'
}

# Native $PSStyle colors for the Plain-Interactive style.
function Get-CVAnsiColor {
    param([string]$Level)
    if (-not $PSStyle) { return '' }
    switch ($Level) {
        'Success' { $PSStyle.Foreground.Green }
        'Warning' { $PSStyle.Foreground.Yellow }
        'Error'   { $PSStyle.Foreground.Red }
        'Debug'   { $PSStyle.Foreground.BrightBlack }
        default   { '' }
    }
}

#endregion

#region ---------------------------------------------------------------- Logging

$script:CVLevels = 'Info','Success','Warning','Error','Debug'

function Write-CVLog {
    <#
      .SYNOPSIS  Primary output primitive. Always logs full detail to file; renders per tier; warnings/errors are aggregated.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [ValidateSet('Info','Success','Warning','Error','Debug')][string]$Level = 'Info',
        [string]$Source,
        [hashtable]$Scope,
        $Exception,
        [switch]$NoConsole
    )

    $rec = [pscustomobject]@{
        Kind      = 'Log'
        Time      = Get-Date
        Message   = $Message
        Level     = $Level
        Source    = $Source
        Scope     = $Scope
        NoConsole = [bool]$NoConsole
        Exception = $Exception
    }

    # Off-thread (e.g. a stray call from inside a runspace): enqueue for the parent, never render here.
    if (-not (Test-CVOwnerThread)) {
        $script:CVConsole.Pending.Enqueue($rec)
        return
    }
    Write-CVRecord -Record $rec
}

# Internal: render + persist one already-built record on the owner thread.
function Write-CVRecord {
    param([Parameter(Mandatory)][object]$Record)

    $level  = $Record.Level
    $msg    = $Record.Message
    $source = $Record.Source

    if ($script:CVConsole) { $script:CVConsole.Counts[$level]++ }

    # 1) Aggregate warnings/errors into the diagnostics buffer. $firstSeen gates console rendering so repeated
    #    failures (per-region / per-subscription floods) collapse to a single console line + the end summary.
    $firstSeen = $true
    if ($level -in 'Warning','Error') {
        $diag = Add-CVDiagnostic -Severity $level -Source ($source ? $source : 'General') `
                                 -Message $msg -Scope $Record.Scope -Exception $Record.Exception -NoLog
        $firstSeen = ($diag.Count -le 1)
    }

    # 2) Always append full detail to the log file (every occurrence, before any console suppression).
    Write-CVFileLine -Time $Record.Time -Level $level -Source $source -Message $msg -Exception $Record.Exception

    if ($Record.NoConsole) { return }

    # 3) Suppress repeated warnings/errors on the console; they are logged + counted for the summary.
    if (-not $firstSeen) { return }

    # Debug lines go to the log file only unless -ShowDebug was set.
    if ($level -eq 'Debug' -and $script:CVConsole -and -not $script:CVConsole.ShowDebug) { return }

    # 4) Console render, per tier.
    $tier = if ($script:CVConsole) { $script:CVConsole.Tier } else { 'Plain-Interactive' }
    $ts   = $Record.Time.ToString('HH:mm:ss')
    $tag  = if ($source) { "[$source] " } else { '' }

    switch ($tier) {
        'Spectre' {
            try {
                $color = $script:CVSpectreColor[$level]
                $safe  = ConvertTo-CVSpectreSafe -Text ("$tag$msg")
                Write-SpectreHost -Message "[grey58]$ts[/] [$color]$safe[/]"
                return
            } catch {
                # Spectre drift / unexpected failure -> fall through to plain.
            }
        }
    }

    if ($tier -eq 'Plain-Headless') {
        # No timestamps-with-color; plain, greppable, pipe-safe.
        Write-Host ("[{0}] [{1}]{2} {3}" -f $Record.Time.ToString('yyyy-MM-dd HH:mm:ss'), $level.ToUpper(), ($source ? " [$source]" : ''), $msg)
    }
    else {
        $c = Get-CVAnsiColor -Level $level
        $r = if ($PSStyle) { $PSStyle.Reset } else { '' }
        Write-Host ("[{0}] {1}{2}{3}{4}" -f $ts, $c, $tag, $msg, $r)
    }
}

# Internal: structured append to the log file. Best-effort; never throws into the caller.
function Write-CVFileLine {
    param([datetime]$Time, [string]$Level, [string]$Source, [string]$Message, $Exception)
    if (-not $script:CVConsole -or -not $script:CVConsole.LogPath) { return }
    try {
        $line = "[{0}] [{1}]{2} {3}" -f $Time.ToString('yyyy-MM-dd HH:mm:ss.fff'), $Level, ($Source ? " [$Source]" : ''), $Message
        if ($Exception) {
            $line += "`n    EXCEPTION: {0}" -f (Format-CVException $Exception)
        }
        Add-Content -LiteralPath $script:CVConsole.LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Last resort so a broken log path never aborts a long collection run.
        Write-Host "[log-write-failed] $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

function Format-CVException {
    param($Exception)
    if (-not $Exception) { return '' }
    $e = if ($Exception -is [System.Management.Automation.ErrorRecord]) { $Exception.Exception } else { $Exception }
    $stack = if ($Exception -is [System.Management.Automation.ErrorRecord]) { $Exception.ScriptStackTrace } else { $null }
    $t = $e.GetType().FullName
    $out = "${t}: $($e.Message)"
    if ($stack) { $out += " | at $($stack -replace "`r?`n", ' -> ')" }
    return $out
}

function Write-CVSection {
    <#
      .SYNOPSIS  A section divider / banner suited to scrolling output.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$Title)

    if (-not (Test-CVOwnerThread)) { return }
    Sync-CVPending

    Write-CVFileLine -Time (Get-Date) -Level 'Info' -Source $null -Message "=== $Title ==="

    $tier = if ($script:CVConsole) { $script:CVConsole.Tier } else { 'Plain-Interactive' }
    switch ($tier) {
        'Spectre' {
            try { Write-SpectreRule -Title (ConvertTo-CVSpectreSafe $Title) -Color 'blue' ; return } catch { }
        }
    }
    if ($tier -eq 'Plain-Headless') {
        Write-Host "=== $Title ==="
    } else {
        $c = if ($PSStyle) { $PSStyle.Foreground.BrightCyan } else { '' }
        $r = if ($PSStyle) { $PSStyle.Reset } else { '' }
        Write-Host ("{0}=== {1} ==={2}" -f $c, $Title, $r)
    }
}

#endregion

#region ---------------------------------------------------------------- Progress

# Live progress uses native Write-Progress (styled by $PSStyle) in both interactive tiers; suppressed when headless.
# Rendering is parent-thread only (Write-Progress from worker runspaces garbles the host).

function Resolve-CVProgressIntId {
    param([string]$Id)
    if (-not $script:CVConsole) { return 1 }
    if (-not $script:CVConsole.ProgressState.ContainsKey($Id)) {
        $script:CVConsole.ProgressState[$Id] = @{ IntId = (++$script:CVConsole.ProgressSeq.Value); Last = $null; Total = 0; Count = 0 }
    }
    return $script:CVConsole.ProgressState[$Id].IntId
}

function Start-CVProgress {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Activity, [int]$Total = 0, [string]$ParentId)
    if (-not (Test-CVOwnerThread) -or -not $script:CVConsole) { return }
    $ProgressPreference = 'Continue'   # local override: Set-CVNativeNoiseSuppression silences NATIVE progress globally
    if ($script:CVConsole.Tier -eq 'Plain-Headless') {
        Write-CVLog -Message "$Activity (starting$([string]($Total ? ", $Total items" : '')))" -Level Debug -Source 'Progress'
        return
    }
    $intId = Resolve-CVProgressIntId -Id $Id
    $script:CVConsole.ProgressState[$Id].Total = $Total
    $script:CVConsole.ProgressState[$Id].Count = 0
    $p = @{ Id = $intId; Activity = $Activity; Status = 'Starting...'; PercentComplete = 0 }
    if ($ParentId) { $p['ParentId'] = Resolve-CVProgressIntId -Id $ParentId }
    Write-Progress @p
}

function Update-CVProgress {
    <#
      .SYNOPSIS  Advance a progress bar. Throttled to ~300ms (matches the old Show-ScriptProgress behavior).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Activity,
        [string]$Status = '',
        [int]$PercentComplete = -1,
        [switch]$Increment
    )
    if (-not (Test-CVOwnerThread) -or -not $script:CVConsole) { return }
    if ($script:CVConsole.Tier -eq 'Plain-Headless') { return }
    $ProgressPreference = 'Continue'   # local override (see Set-CVNativeNoiseSuppression)

    $intId = Resolve-CVProgressIntId -Id $Id
    $state = $script:CVConsole.ProgressState[$Id]
    if ($Increment) { $state.Count++ }

    if ($PercentComplete -lt 0 -and $state.Total -gt 0) {
        $PercentComplete = [int](($state.Count / [double]$state.Total) * 100)
    }
    if ($PercentComplete -gt 100) { $PercentComplete = 100 } elseif ($PercentComplete -lt 0) { $PercentComplete = 0 }

    # Throttle: skip updates <300ms apart unless we've hit 100%.
    $now = Get-Date
    if ($state.Last -and ($now - $state.Last).TotalMilliseconds -lt 300 -and $PercentComplete -lt 100) { return }
    $state.Last = $now

    $p = @{ Id = $intId; Activity = ($Activity ? $Activity : ($script:CVConsole.Title ? $script:CVConsole.Title : 'Working')); PercentComplete = $PercentComplete }
    if ($Status) { $p['Status'] = $Status } else { $p['Status'] = "$($state.Count)$([string]($state.Total ? "/$($state.Total)" : '')) ($PercentComplete%)" }
    Write-Progress @p
}

function Complete-CVProgress {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)
    if (-not (Test-CVOwnerThread) -or -not $script:CVConsole) { return }
    if ($script:CVConsole.Tier -eq 'Plain-Headless') { return }
    if (-not $script:CVConsole.ProgressState.ContainsKey($Id)) { return }
    $ProgressPreference = 'Continue'   # local override (see Set-CVNativeNoiseSuppression)
    Write-Progress -Id $script:CVConsole.ProgressState[$Id].IntId -Completed
}

#endregion

#region ---------------------------------------------------------------- Diagnostics

# Normalize a concrete message into a signature template so per-region/per-subscription floods collapse to one record.
# The caller-supplied $Scope names the volatile dimension(s) (region/subscription/project/account); we substitute those
# exact values out first, then normalize any remaining volatile tokens (ids, GUIDs, ARNs, IPs, bare numbers).
function ConvertTo-CVTemplate {
    param([string]$Message, [hashtable]$Scope)
    if (-not $Message) { return '' }
    $t = $Message
    if ($Scope) {
        foreach ($k in $Scope.Keys) {
            $v = [string]$Scope[$k]
            if ($v -and $v.Length -ge 2) { $t = $t -replace [regex]::Escape($v), "<$k>" }
        }
    }
    $t = $t -replace 'arn:aws[^\s"'']+', 'arn:*'
    $t = $t -replace '/subscriptions/[0-9a-fA-F-]{36}', '/subscriptions/*'
    $t = $t -replace '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b', '*'
    $t = $t -replace '\b(i|vol|snap|ami|eni|sg|subnet|vpc)-[0-9a-fA-F]{8,}\b', '$1-*'
    $t = $t -replace '\b\d{1,3}(\.\d{1,3}){3}\b', '*'          # IPv4
    $t = $t -replace '\b\d+\b', '#'                            # bare numbers
    return $t.Trim()
}

function Get-CVCategory {
    param([string]$Message)
    switch -Regex ($Message) {
        'not recognized|is not installed|could not (load|find)|no module|missing module' { 'MissingModule'; break }
        'not enabled|SERVICE_DISABLED|has not been used|API .*disabled'                  { 'ApiDisabled'; break }
        'access[\s-]?denied|not authorized|permission|forbidden|\b403\b|unauthorized'    { 'Permission'; break }
        'credential|expired token|authenticat|Connect-Az|sso'                            { 'Auth'; break }
        'timed out|timeout|deadline'                                                     { 'Timeout'; break }
        'throttl|rate exceeded|too many requests|\b429\b|\b503\b'                        { 'Transient'; break }
        default                                                                          { 'Unknown' }
    }
}

function Add-CVDiagnostic {
    <#
      .SYNOPSIS  Record a warning/error into the aggregation buffer. Dedups by signature; tracks affected scopes + count.
      .NOTES     Thread-safe (guarded). Full concrete detail is written to the log unless -NoLog (caller already logged).
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Warning','Error','Fatal')][string]$Severity = 'Error',
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Scope,
        $Exception,
        [string]$Category,
        [switch]$NoLog
    )
    if (-not $script:CVConsole) { return }

    $cloud    = $script:CVConsole.Cloud
    $template = ConvertTo-CVTemplate -Message $Message -Scope $Scope
    $sig      = "$cloud|$Source|$template"
    if (-not $Category) { $Category = Get-CVCategory -Message $Message }

    $scopeStr = $null
    if ($Scope -and $Scope.Count) {
        $scopeStr = (($Scope.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ',')
    }

    [System.Threading.Monitor]::Enter($script:CVConsole.Lock)
    try {
        $rec = $script:CVConsole.Diagnostics[$sig]
        if (-not $rec) {
            $rec = [pscustomobject]@{
                Signature      = $sig
                Severity       = $Severity
                Category       = $Category
                Source         = $Source
                Cloud          = $cloud
                Template       = $template
                Message        = $Message
                Exception      = (Format-CVException $Exception)
                Count          = 0
                AffectedScopes = [System.Collections.Generic.HashSet[string]]::new()
                FirstSeen      = Get-Date
                LastSeen       = Get-Date
            }
            $script:CVConsole.Diagnostics[$sig] = $rec
        }
        $rec.Count++
        $rec.LastSeen = Get-Date
        # Escalate severity if a later occurrence is worse.
        if ($Severity -eq 'Fatal' -or ($Severity -eq 'Error' -and $rec.Severity -eq 'Warning')) { $rec.Severity = $Severity }
        if ($scopeStr) { [void]$rec.AffectedScopes.Add($scopeStr) }
    }
    finally {
        [System.Threading.Monitor]::Exit($script:CVConsole.Lock)
    }

    # Concrete detail to the log (unless the caller was Write-CVRecord, which already logged).
    if (-not $NoLog) {
        Write-CVFileLine -Time (Get-Date) -Level $Severity -Source $Source -Message $Message -Exception $Exception
    }

    return $rec
}

function Get-CVDiagnostics {
    <# .SYNOPSIS  Aggregated diagnostic records (for the summary panel + JSON embedding + tests). #>
    [CmdletBinding()] param()
    if (-not $script:CVConsole) { return @() }
    [System.Threading.Monitor]::Enter($script:CVConsole.Lock)
    try   { return @($script:CVConsole.Diagnostics.Values | Sort-Object @{E='Severity';Descending=$true}, @{E='Count';Descending=$true}) }
    finally { [System.Threading.Monitor]::Exit($script:CVConsole.Lock) }
}

function Write-CVSummary {
    <#
      .SYNOPSIS  End-of-run panel: warning/error totals + a table of aggregated issues (source x category x scope-count).
    #>
    [CmdletBinding()]
    param([hashtable[]]$ExtraRows, [string]$Title = 'Run Summary')

    if (-not $script:CVConsole) { return }
    Sync-CVPending

    $diags   = Get-CVDiagnostics
    $errors  = @($diags | Where-Object { $_.Severity -in 'Error','Fatal' })
    $warns   = @($diags | Where-Object { $_.Severity -eq 'Warning' })
    $errTot  = [int](($errors | Measure-Object Count -Sum).Sum)
    $warnTot = [int](($warns  | Measure-Object Count -Sum).Sum)
    $elapsed = (Get-Date) - $script:CVConsole.StartTime
    $elapsedStr = '{0:hh\:mm\:ss}' -f $elapsed

    # Rows for the issues table.
    $rows = foreach ($d in $diags) {
        [pscustomobject]@{
            Severity = $d.Severity
            Source   = $d.Source
            Category = $d.Category
            Count    = $d.Count
            Scopes   = $d.AffectedScopes.Count
            Detail   = if ($d.Message.Length -gt 80) { $d.Message.Substring(0,77) + '...' } else { $d.Message }
        }
    }

    $headline = "Elapsed $elapsedStr | Errors: $errTot ($($errors.Count) distinct) | Warnings: $warnTot ($($warns.Count) distinct)"
    Write-CVFileLine -Time (Get-Date) -Level 'Info' -Source 'Summary' -Message "=== $Title === $headline"

    $tier = $script:CVConsole.Tier
    if ($tier -eq 'Spectre') {
        try {
            Write-SpectreRule -Title (ConvertTo-CVSpectreSafe $Title) -Color 'blue'
            $color = if ($errors.Count) { 'red' } elseif ($warns.Count) { 'yellow' } else { 'green' }
            Write-SpectreHost "[$color]$headline[/]"
            if ($rows) {
                $rows | Format-SpectreTable -Border Rounded | Out-Host
            } else {
                Write-SpectreHost '[green]No warnings or errors recorded.[/]'
            }
            return
        } catch { }  # fall through to plain
    }

    # Plain (interactive or headless).
    if ($tier -eq 'Plain-Headless') {
        Write-Host "=== $Title ==="
        Write-Host $headline
    } else {
        $c = if ($errors.Count) { Get-CVAnsiColor Error } elseif ($warns.Count) { Get-CVAnsiColor Warning } else { Get-CVAnsiColor Success }
        $r = if ($PSStyle) { $PSStyle.Reset } else { '' }
        Write-CVSection -Title $Title
        Write-Host ("{0}{1}{2}" -f $c, $headline, $r)
    }
    if ($rows) {
        ($rows | Format-Table Severity, Source, Category, Count, Scopes, Detail -AutoSize | Out-String).TrimEnd() |
            ForEach-Object { Write-Host $_ }
    }
}

#endregion

#region ---------------------------------------------------------------- Preflight

function Test-CVModuleDependency {
    <# .SYNOPSIS  Which of the named PowerShell modules are NOT installed. #>
    [CmdletBinding()] param([Parameter(Mandatory)][string[]]$Name)
    return @($Name | Where-Object { -not (Get-Module -ListAvailable -Name $_ -ErrorAction SilentlyContinue) })
}

function Test-CVCommandDependency {
    <# .SYNOPSIS  Which of the named external CLIs are NOT on PATH. #>
    [CmdletBinding()] param([Parameter(Mandatory)][string[]]$Name)
    return @($Name | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) })
}

function Resolve-CVServicePlan {
    <#
      .SYNOPSIS  Given a service->required-modules map and which services are selected, split into Runnable vs Skipped.
      .DESCRIPTION Emits ONE summary line + one diagnostic per skipped service (Category=MissingModule) instead of
                   letting later cmdlet calls flood the console. This is the Azure warn-and-continue fix.
      .OUTPUTS   @{ Runnable = @('VM',...); Skipped = @{ NETAPP = 'Az.NetAppFiles missing'; ... } }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$ServiceModuleMap,
        [Parameter(Mandatory)][string[]]$Selected
    )
    $runnable = [System.Collections.Generic.List[string]]::new()
    $skipped  = @{}
    foreach ($svc in $Selected) {
        $needed = $ServiceModuleMap[$svc]
        if (-not $needed) { $runnable.Add($svc); continue }          # no declared deps -> assume CLI/other
        $missing = Test-CVModuleDependency -Name $needed
        if ($missing.Count) {
            $reason = "$($missing -join ', ') missing"
            $skipped[$svc] = $reason
            $null = Add-CVDiagnostic -Severity Warning -Source $svc -Category MissingModule `
                             -Message "Skipping $svc - required module(s) not installed: $($missing -join ', ')"
        } else {
            $runnable.Add($svc)
        }
    }
    if ($skipped.Count) {
        Write-CVLog -Message ("Skipping {0} service(s) due to missing modules: {1}" -f $skipped.Count, (($skipped.Keys | Sort-Object) -join ', ')) -Level Warning -Source 'Preflight' -NoConsole
        Write-CVLog -Message ("Running {0} service(s): {1}" -f $runnable.Count, ($runnable -join ', ')) -Level Info -Source 'Preflight'
    }
    return @{ Runnable = @($runnable); Skipped = $skipped }
}

# Install guidance for known external CLIs surfaced by preflight.
function Get-CVCommandInstallHint {
    param([string]$Command)
    switch -Regex ($Command) {
        '^(gcloud|gsutil|bq)$' { 'install the Google Cloud SDK - https://cloud.google.com/sdk/docs/install' }
        '^kubectl$'            { 'install kubectl - https://kubernetes.io/docs/tasks/tools/' }
        '^aws$'                { 'install the AWS CLI v2 - https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html' }
        '^az$'                 { 'install the Azure CLI - https://learn.microsoft.com/cli/azure/install-azure-cli' }
        default                { "ensure '$Command' is installed and on your PATH" }
    }
}

function Test-CVRuntimeCompatibility {
    <#
      .SYNOPSIS  Verify the PowerShell runtime still supports the collection idioms the sizing scripts rely on.
      .DESCRIPTION On PowerShell 7.6.3 / .NET 10.0.9, `@($list)` over a List[object] throws
                   "ArgumentException: Argument types do not match" from the engine's own array binder. The
                   scripts moved to List[psobject] to dodge it, but a future runtime could regress a different
                   type - and the failure mode is a mid-run abort swallowed into a one-line warning. Detecting
                   it here turns "the report is quietly missing" into "your pwsh build is not supported".
      .OUTPUTS   Array of human-readable incompatibility strings (empty when the runtime is good).
    #>
    [CmdletBinding()] param()
    $problems = @()
    foreach ($t in 'psobject','string','pscustomobject','hashtable') {
        try {
            $l = New-Object "System.Collections.Generic.List[$t]"
            $null = @($l)
            $l.Add(($(if ($t -eq 'string') { 'x' } elseif ($t -eq 'hashtable') { @{} } else { [pscustomobject]@{A=1} })))
            $null = @($l)
        } catch {
            $problems += "@() over List[$t] fails on this runtime ($($_.Exception.GetType().Name): $($_.Exception.Message))"
        }
    }
    # Plain return, NOT `,$problems`: the comma wrapper would emit an empty array as a single pipeline object,
    # so a healthy runtime would read as one unnamed problem and fire the warning on every run.
    return $problems
}

function Assert-CVPreflight {
    <#
      .SYNOPSIS  Fail fast on missing hard dependencies; report optional ones as degraded.
      .DESCRIPTION Renders in PLAIN (never assumes Spectre - it may itself be the missing module). Aggregates all
                   misses into a single message. Exits 1 on any fatal miss when -ExitOnFatal.
      .OUTPUTS   $true to continue; otherwise exits (or returns $false if -ExitOnFatal:$false).
    #>
    [CmdletBinding()]
    param(
        [string[]]$FatalModules,
        [string[]]$FatalCommands,
        [hashtable]$OptionalModules,        # label -> module name(s)
        [hashtable]$OptionalCommands,       # label -> command name(s)
        [switch]$ExitOnFatal
    )

    # Runtime sanity first: a broken collection binder corrupts results everywhere downstream, and no amount of
    # correct dependencies compensates for it.
    $runtimeIssues = @(Test-CVRuntimeCompatibility)
    if ($runtimeIssues.Count) {
        $rmsg = "Unsupported PowerShell runtime (pwsh $($PSVersionTable.PSVersion) / .NET $([System.Environment]::Version)): " +
                ($runtimeIssues -join '; ') + ". Results from this build cannot be trusted - run tests/Invoke-CVEnvironmentTests.ps1."
        if (Test-CVConsoleReady) { Write-CVLog -Message $rmsg -Level Error -Source 'Preflight' }
        else { Write-Host "[Preflight] $rmsg" -ForegroundColor Red }
    }

    $missingModules  = if ($FatalModules)  { @(Test-CVModuleDependency  -Name $FatalModules)  } else { @() }
    $missingCommands = if ($FatalCommands) { @(Test-CVCommandDependency -Name $FatalCommands) } else { @() }

    # Optional/degraded (one line each; does not abort).
    $degraded = @()
    foreach ($map in @($OptionalModules, $OptionalCommands)) {
        if (-not $map) { continue }
        $isModule = ($map -eq $OptionalModules)
        foreach ($label in $map.Keys) {
            $names = @($map[$label])
            $miss  = if ($isModule) { Test-CVModuleDependency -Name $names } else { Test-CVCommandDependency -Name $names }
            if ($miss.Count) { $degraded += "$label ($($miss -join ', '))" }
        }
    }

    if ($degraded.Count) {
        $dmsg = "Optional dependencies missing - related features will be skipped: $($degraded -join '; ')"
        if (Test-CVConsoleReady) { Write-CVLog -Message $dmsg -Level Warning -Source 'Preflight' }
        else { Write-Host "[Preflight] $dmsg" -ForegroundColor Yellow }
    }

    if ($missingModules.Count -or $missingCommands.Count) {
        $parts = @()
        if ($missingModules.Count)  { $parts += ($missingModules  | ForEach-Object { "module '$_'" }) }
        if ($missingCommands.Count) { $parts += ($missingCommands | ForEach-Object { "command '$_'" }) }
        $fmsg = "Required dependencies missing: $($parts -join ', ')."

        # Build copy-pasteable, actionable install instructions. Lines starting with 4 spaces are commands.
        $instructions = [System.Collections.Generic.List[string]]::new()
        if ($missingModules.Count) {
            $instructions.Add("To install the missing PowerShell module(s), run:")
            $instructions.Add("    Install-Module $($missingModules -join ',') -Scope CurrentUser -Force")
        }
        if ($missingCommands.Count) {
            $instructions.Add("To install the missing command-line tool(s):")
            foreach ($c in $missingCommands) { $instructions.Add("    $c  ->  $(Get-CVCommandInstallHint $c)") }
        }
        $instructions.Add("Then re-run this script.")

        # Plain output on purpose (a fatal miss may be PwshSpectreConsole itself).
        Write-Host ""
        Write-Host "  PREFLIGHT FAILED  " -ForegroundColor Red
        Write-Host $fmsg -ForegroundColor Red
        Write-Host ""
        foreach ($line in $instructions) {
            if ($line.StartsWith('    ')) { Write-Host $line -ForegroundColor Cyan }
            else { Write-Host "  $line" -ForegroundColor Yellow }
        }
        Write-Host ""

        if (Test-CVConsoleReady) {
            Write-CVFileLine -Time (Get-Date) -Level 'Fatal' -Source 'Preflight' -Message ("$fmsg`n" + ($instructions -join "`n"))
        }
        if ($ExitOnFatal) { exit 1 }
        return $false
    }
    return $true
}

#endregion

#region ---------------------------------------------------- Native module noise suppression

function Set-CVNativeNoiseSuppression {
    <#
      .SYNOPSIS  Quiet native module WARNING/progress chatter (Az breaking-change spam, native progress) WITHOUT
                 hiding real errors. Never touches $ErrorActionPreference - genuine failures still throw and are caught.
    #>
    [CmdletBinding()]
    param([ValidateSet('AWS','Azure','GCP','M365','Generic','None')][string]$Provider = 'Generic')

    switch ($Provider) {
        'Azure' {
            # The real Azure noise is the per-call breaking-change / deprecation WARNING flood the Az modules emit.
            # Suppress it at the source (env var works even before Az.Accounts loads; Update-AzConfig once it's available).
            # NB: we deliberately do NOT touch $ProgressPreference - the Azure script relies on native Write-Progress.
            $env:SuppressAzurePowerShellBreakingChangeWarnings = 'true'
            if (Get-Command Update-AzConfig -ErrorAction SilentlyContinue) {
                try { Update-AzConfig -DisplayBreakingChangeWarning $false -Scope Process -ErrorAction Stop | Out-Null } catch { }
            }
        }
        'AWS' {
            # AWS.Tools has little native progress noise; leave $ProgressPreference alone so existing bars still work.
            $env:AWS_PAGER = ''
        }
        'GCP' {
            # CLI-based: no PowerShell-module progress to suppress, and the script uses native Write-Progress directly.
            $env:CLOUDSDK_CORE_DISABLE_PROMPTS = '1'
        }
    }
}

#endregion

#region ------------------------------------------------------- Runspace-safe worker logging

function New-CVWorkerLogger {
    <#
      .SYNOPSIS  Build a self-contained logger closure for use INSIDE a runspace worker.
      .DESCRIPTION The returned scriptblock appends structured records to $RecordList and NEVER touches the host
                   ($Host / Write-Host / Spectre / Write-Progress). The worker returns $RecordList; the parent
                   replays it via Receive-CVWorkerRecords. This preserves runspace safety by construction.
      .EXAMPLE   $records = [System.Collections.Generic.List[psobject]]::new()
                 $log = New-CVWorkerLogger -RecordList $records
                 & $log 'started' 'Info' 'VM'      # inside the worker
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[psobject]]$RecordList)

    return {
        param([string]$Message, [string]$Level = 'Info', [string]$Source, [hashtable]$Scope, $Exception)
        $RecordList.Add([pscustomobject]@{
            Kind      = 'Log'
            Time      = Get-Date
            Message   = $Message
            Level     = $Level
            Source    = $Source
            Scope     = $Scope
            NoConsole = $false
            Exception = $Exception
        })
    }.GetNewClosure()
}

function Receive-CVWorkerRecords {
    <#
      .SYNOPSIS  Parent-thread replay of records produced by worker runspaces. Renders + aggregates them in order.
    #>
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)][object[]]$Records)
    process {
        if (-not $Records) { return }
        foreach ($rec in $Records) {
            if (-not $rec) { continue }
            # Accept both our record objects and raw strings (legacy queues).
            if ($rec -is [string]) {
                Write-CVRecord -Record ([pscustomobject]@{ Kind='Log'; Time=(Get-Date); Message=$rec; Level='Info'; Source=$null; Scope=$null; NoConsole=$false; Exception=$null })
            } else {
                Write-CVRecord -Record $rec
            }
        }
    }
}

function Get-CVRunspaceResult {
    <#
      .SYNOPSIS  Unwrap a runspace's output collection to the single object the worker returned.
      .DESCRIPTION [PowerShell]::EndInvoke() hands back a PSDataCollection, NOT the object the worker returned.
                   Reading a property off that collection goes through member enumeration, which silently yields
                   $null whenever the property holds an EMPTY array - and `$acc += $null` then appends a phantom
                   null element to the accumulator. Every caller must unwrap before touching properties.
      .EXAMPLE   $result = Get-CVRunspaceResult $ps.EndInvoke($handle)
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)]$Output)
    $last = $null
    foreach ($o in $Output) { if ($null -ne $o) { $last = $o } }
    return $last
}

function ConvertTo-CVItemArray {
    <#
      .SYNOPSIS  Normalize any worker-returned collection to a null-free object[] that is safe to `+=`.
      .DESCRIPTION Guards the accumulate step: `$acc += $null` and `$acc += @($null)` both append a phantom
                   element that later surfaces as a bogus inventory count and an Export-Csv null-binding error.
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)]$Value)
    $out = @()
    foreach ($v in $Value) { if ($null -ne $v) { $out += $v } }
    return ,$out
}

#endregion
