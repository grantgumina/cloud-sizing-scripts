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

    # Progress renders only in the interactive tiers; size its erase region to this terminal.
    if ($cap.Tier -ne 'Plain-Headless') { Set-CVProgressWidth }

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
      .SYNOPSIS  The repo top-level directory (nearest ancestor containing a .git), else the script's own location.
      .DESCRIPTION Outside a checkout this used to return (Get-Location).Path, DISCARDING the $StartPath the caller
                   passed in. Every non-repo copy - a zip sent to a customer, the k8s image (which COPYs src/ with
                   no .git) - therefore wrote Output/ and Logs/ wherever the user happened to be cd'd, and running
                   from an unwritable directory failed outright. Falling back to $StartPath (the calling script's
                   $PSScriptRoot) makes the location deterministic; -OutputRoot on Initialize-CVRunPaths overrides
                   it entirely.
    #>
    [CmdletBinding()]
    param([string]$StartPath)
    $dir = if ($StartPath) { $StartPath } else { (Get-Location).Path }
    $probe = $dir
    while ($probe) {
        if (Test-Path -LiteralPath (Join-Path $probe '.git')) { return $probe }
        $parent = Split-Path $probe -Parent
        if (-not $parent -or $parent -eq $probe) { break }
        $probe = $parent
    }
    # No repo above us: use where the script actually lives, not where the shell happens to be.
    return $dir
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
        [string]$StartPath,          # pass the calling script's $PSScriptRoot
        [string]$OutputRoot          # explicit override (-OutputDirectory); wins over repo/script detection
    )
    $root      = if ($OutputRoot) { $OutputRoot } else { Get-CVBaseRoot -StartPath $StartPath }
    $runName   = ('{0}_{1}' -f $Cloud.ToLower(), $TimeStamp)
    $outputTop = Join-Path $root 'Output'
    $outputDir = Join-Path $outputTop $runName
    $logsDir   = Join-Path $root 'Logs'
    # An unwritable root used to surface as an unhandled New-Item throw on line 1 of the run, with no indication
    # of which path was at fault or that -OutputDirectory exists.
    try {
        New-Item -ItemType Directory -Force -Path $outputDir -ErrorAction Stop | Out-Null
        New-Item -ItemType Directory -Force -Path $logsDir   -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "FATAL: cannot create the output directories under '$root': $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Pass -OutputDirectory <path> to write somewhere else." -ForegroundColor Yellow
        throw
    }
    return [pscustomobject]@{
        Root      = $root
        RunName   = $runName
        OutputDir = $outputDir
        LogsDir   = $logsDir
        LogPath   = Join-Path $logsDir  ("$runName.log")
        ZipPath   = Join-Path $outputTop ("$runName.zip")   # sibling of OutputDir (avoids zipping the zip into itself)
    }
}

function Export-CVCsv {
    <#
      .SYNOPSIS  Export-Csv that cannot silently drop columns.
      .DESCRIPTION Export-Csv derives its header from the FIRST object only, so any property that appears later in
                   the collection is discarded without warning. Our rows are legitimately heterogeneous - Tag_*
                   columns are flattened per resource, and error paths emit a short object - so this bit hard:

                     first row FEWER props : "Name","Type"                        <- Tag_env, StorageGB LOST
                     union projection      : "Name","Type","Tag_env","StorageGB"

                   The most common victim was Tag_*: one untagged first VM erased every tag column in the file,
                   which reads as "the tool doesn't collect tags".

                   Builds the union of property names in first-seen order and projects every row through it.
      .PARAMETER PreferredOrder  Names to place first when present, so existing consumers keep their column order
                                 and newly added fields append rather than shifting positions.
      .PARAMETER Append  Passed through to Export-Csv. Note the union is computed from THIS call's rows only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][AllowEmptyCollection()]$InputObject,
        [Parameter(Mandatory)][string]$Path,
        [string[]]$PreferredOrder,
        [switch]$Append,
        [switch]$NoHeaderOnEmpty,
        # Emit every name in -PreferredOrder even when no row carries it, so the header is identical between runs
        # and scopes. Machine consumers want a fixed schema; a human reading a gap list wants a narrow file, which
        # is why absent columns are dropped by default.
        [switch]$KeepDeclaredColumns
    )
    begin { $rows = [System.Collections.Generic.List[psobject]]::new() }
    process {
        foreach ($o in @($InputObject)) { if ($null -ne $o) { $rows.Add($o) } }
    }
    end {
        if ($rows.Count -eq 0) {
            if (-not $NoHeaderOnEmpty -and $PreferredOrder -and $PreferredOrder.Count) {
                # Header-only file so downstream consumers still see the expected schema.
                ($PreferredOrder | ForEach-Object { '"' + ($_ -replace '"', '""') + '"' }) -join ',' |
                    Set-Content -Path $Path -Encoding UTF8
            }
            return
        }

        # OrdinalIgnoreCase is REQUIRED, not a nicety. OrderedDictionary defaults to a case-SENSITIVE comparer,
        # so 'Tag_Demoroom' and 'Tag_demoroom' were admitted as two separate columns - but Select-Object resolves
        # properties case-INSENSITIVELY and rejects the second with "the property ... already exists", spraying one
        # error per row per collision. Cloud tag keys preserve case, so any estate tagging some resources 'owner'
        # and others 'Owner' hit this. First-seen casing wins; the other row's value is still picked up because
        # property lookup ignores case, which is why the CSV was correct despite the noise.
        $keys = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($p in @($PreferredOrder)) {
            if ($p -and -not $keys.Contains($p)) { $keys[$p] = $true }
        }
        foreach ($r in $rows) {
            foreach ($n in $r.PSObject.Properties.Name) {
                if (-not $keys.Contains($n)) { $keys[$n] = $true }
            }
        }
        if ($KeepDeclaredColumns) {
            $ordered = @($keys.Keys)
        } else {
            # Drop preferred names that no row actually has, so we do not invent empty columns.
            $present = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($r in $rows) { foreach ($n in $r.PSObject.Properties.Name) { [void]$present.Add($n) } }
            $ordered = @($keys.Keys | Where-Object { $present.Contains($_) })
        }

        $rows | Select-Object -Property $ordered | Export-Csv -Path $Path -NoTypeInformation -Append:$Append
    }
}

function Export-CVSizingJson {
    <#
      .SYNOPSIS  Single shared writer for the <cloud>_sizing_<ts>.json the posture report consumes.
      .DESCRIPTION Replaces the per-script inline JSON blocks (which had drifted and, on GCP/Azure, read
                   undefined variables). Blends a normalized `protection` label object onto every resource
                   (Get-CVProtectionPosture), builds the `summary`, and emits a normalized `protection_summary`
                   rollup counted by the same vocabulary. Includes whatever workloads the caller passes - no
                   per-type allow-list - so coverage follows the estate.
      .PARAMETER Workloads  Ordered map workloadKey -> @{ Items=[object[]]; Type='<summary bucket>';
                            PostureType='<control-set key>'; SizeField='<GB prop>' }.
                            `Type` names the summary / protection_summary bucket (a display name, e.g. 'Aurora');
                            keys sharing a Type accumulate. `PostureType` (defaults to Type) is the resilience
                            control-set key used for posture - so Aurora/DocumentDB can bucket separately yet share
                            the RDS controls, and MySQL/PostgreSQL share FlexDB.
      .PARAMETER Controls   The cloud's ResourceType -> controls hashtable, for posture fallback when the
                            resilience pass did not run (no Ctl_* columns on the row).
      .OUTPUTS  The path written.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('aws','azure','gcp')][string]$Cloud,
        [Parameter(Mandatory)][string]$OutputDir,
        [Parameter(Mandatory)][string]$TimeStamp,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Metadata,
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary]$Workloads,
        [hashtable]$Controls,
        [string]$SchemaVersion = '3.0'
    )

    $summary      = [ordered]@{}
    $protSummary  = [ordered]@{}
    $workloadsOut = [ordered]@{}

    foreach ($key in @($Workloads.Keys)) {
        $entry     = $Workloads[$key]
        $items     = @($entry.Items | Where-Object { $null -ne $_ })
        $type      = if ($entry.Type) { $entry.Type } else { $key }
        $postType  = if ($entry.PostureType) { $entry.PostureType } else { $type }
        $sizeField = $entry.SizeField
        $ctrlSet   = if ($Controls -and $postType -and $Controls.ContainsKey($postType)) { $Controls[$postType] } else { $null }

        # Size total for this collection (skip non-numeric / missing values).
        $sumGb = 0.0
        if ($sizeField) {
            foreach ($it in $items) {
                $v = $it.$sizeField
                if ($null -ne $v -and "$v" -match '^\s*-?[\d\.]+\s*$') { $sumGb += [double]$v }
            }
        }

        # Attach the normalized protection label object to each resource; keep the postures for the rollup.
        $postures = foreach ($it in $items) {
            $p = Get-CVProtectionPosture -Resource $it -Cloud $Cloud -ResourceType $postType -ControlSet $ctrlSet
            Add-Member -InputObject $it -NotePropertyName protection -NotePropertyValue $p -Force
            $p
        }
        $workloadsOut[$key] = $items

        # summary - accumulate by engine type so shared-type keys (FlexDB) sum rather than overwrite.
        if (-not $summary.Contains($type)) { $summary[$type] = [ordered]@{ count = 0; total_storage_gb = 0.0; notes = '' } }
        $summary[$type].count            += $items.Count
        $summary[$type].total_storage_gb += $sumGb

        # protection_summary - counted by the per-resource label vocabulary.
        if (-not $protSummary.Contains($type)) {
            $protSummary[$type] = [ordered]@{ total = 0; protected = 0; unprotected = 0; not_assessed = 0
                                              immutable = 0; publicly_exposed = 0; pitr_enabled = 0; cross_region = 0 }
        }
        $ps = $protSummary[$type]
        foreach ($p in @($postures)) {
            $ps.total++
            switch ($p.backup) { 'Protected' { $ps.protected++ } 'Unprotected' { $ps.unprotected++ } default { $ps.not_assessed++ } }
            if ($p.immutability    -eq 'Immutable') { $ps.immutable++ }
            if ($p.public_exposure -eq 'Public')    { $ps.publicly_exposed++ }
            if ($p.pitr            -eq 'Enabled')   { $ps.pitr_enabled++ }
            if ($p.cross_region    -eq 'Protected') { $ps.cross_region++ }
        }
    }

    foreach ($t in @($summary.Keys)) { $summary[$t].total_storage_gb = [math]::Round([double]$summary[$t].total_storage_gb, 4) }

    # Overall coverage over resources whose backup was actually assessed (NotAssessed excluded, never a failure).
    $ovTotal = 0; $ovProt = 0; $ovUnprot = 0; $ovNA = 0
    foreach ($t in @($protSummary.Keys)) {
        $ovTotal += $protSummary[$t].total; $ovProt += $protSummary[$t].protected
        $ovUnprot += $protSummary[$t].unprotected; $ovNA += $protSummary[$t].not_assessed
    }
    $protSummary['_overall'] = [ordered]@{
        total        = $ovTotal
        protected    = $ovProt
        unprotected  = $ovUnprot
        not_assessed = $ovNA
        coverage_pct = if (($ovProt + $ovUnprot) -gt 0) { [math]::Round(100 * [double]$ovProt / ($ovProt + $ovUnprot), 1) } else { $null }
    }

    $meta = [ordered]@{}
    foreach ($k in $Metadata.Keys) { $meta[$k] = $Metadata[$k] }
    $meta['cloud']          = $Cloud
    $meta['generated_at']   = (Get-Date -Format 'o')
    $meta['schema_version'] = $SchemaVersion

    $doc = [ordered]@{
        metadata           = $meta
        summary            = $summary
        protection_summary = $protSummary
        workloads          = $workloadsOut
    }

    if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
    $jsonPath = Join-Path $OutputDir ("{0}_sizing_{1}.json" -f $Cloud, $TimeStamp)
    $doc | ConvertTo-Json -Depth 12 | Set-Content -Path $jsonPath -Encoding UTF8
    return $jsonPath
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
    #    Flatten embedded newlines for the console only - the file already has the full text (step 2). Worker
    #    runspaces hand us raw CLI stderr (gcloud hard-wraps its PERMISSION_DENIED text), and a multi-line
    #    Write-Host paints several full-width rows. The native progress pane then repaints over those rows but
    #    only erases $PSStyle.Progress.MaxWidth columns, so the tail of each wrapped row survives and freezes
    #    into scrollback as ragged right-hand fragments. See Set-CVProgressWidth for the other half of the fix.
    if ($msg -match "`r|`n") { $msg = ($msg -replace "\s*\r?\n\s*", ' ').Trim() }

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

function Set-CVProgressWidth {
    <#
      .SYNOPSIS  Match the native progress pane's erase width to the real terminal width.
      .DESCRIPTION $PSStyle.Progress.MaxWidth defaults to 120. The Minimal view blanks its reserved rows out to
                   that column ONLY, so on a wider terminal anything already painted past column 120 - the tail
                   of a wrapped CLI error, a severed ANSI reset - survives the repaint and scrolls into history
                   as garbage tacked onto unrelated lines. Widening the pane makes the erase cover the whole row.
                   Deliberately a process-wide $PSStyle mutation: the AWS/GCP scripts call Write-Progress
                   directly in their runspace-polling loops, bypassing the wrappers below.
    #>
    [CmdletBinding()] param()
    if (-not $PSStyle) { return }
    try {
        $w = $Host.UI.RawUI.WindowSize.Width
        if ($w -ge 18) { $PSStyle.Progress.MaxWidth = $w }   # <18 throws (PS validation range)
    } catch {
        # No raw UI (redirected host, some remoting sessions) - leave the default in place.
    }
}

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
    Set-CVProgressWidth   # re-check per bar, so a mid-run terminal resize is picked up
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

function Get-CVAzAccountsFloor {
    <#
      .SYNOPSIS  Highest Az.Accounts version demanded by the given Az.<Service> modules.
      .DESCRIPTION Contrary to a long-standing assumption in this file, Az.<Service> modules do NOT pin an exact
                   Az.Accounts version - every one of them ships `RequiredModules = @()`. What they declare is a
                   MINIMUM, listed in the manifest's ModuleList and enforced by their own .psm1 at import time:

                       $module = Get-Module Az.Accounts
                       if ($module -ne $null -and $module.Version -lt [System.Version]"5.5.1") { Write-Error ... }
                       elseif ($module -eq $null) { Import-Module Az.Accounts -MinimumVersion 5.5.1 -Scope Global }

                   So the constraint for a run is the MAX of the minimums across the modules it will import.
                   Read from the manifests rather than hard-coded, so a module upgrade cannot leave this stale.
      .OUTPUTS   @{ Version = [version] (or $null when nothing declares one); By = 'Az.Network' }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Name)

    $floor = $null
    $by    = $null
    foreach ($m in @($Name | Where-Object { $_ -like 'Az.*' -and $_ -ne 'Az.Accounts' })) {
        $mod = Get-Module -ListAvailable -Name $m -ErrorAction SilentlyContinue |
                    Sort-Object Version -Descending | Select-Object -First 1
        if (-not $mod -or -not $mod.Path) { continue }
        # A manifest we cannot read yields NO constraint rather than a guessed one - inventing a floor here
        # would block runs on a machine that is actually fine.
        try { $data = Import-PowerShellDataFile -Path $mod.Path -ErrorAction Stop } catch { continue }
        foreach ($r in @($data.ModuleList | Where-Object { $_.ModuleName -eq 'Az.Accounts' })) {
            $v = $null
            if ([version]::TryParse("$($r.ModuleVersion)", [ref]$v) -and ($null -eq $floor -or $v -gt $floor)) {
                $floor = $v
                $by    = $m
            }
        }
    }
    return @{ Version = $floor; By = $by }
}

function Test-CVAzModuleConflict {
    <#
      .SYNOPSIS  Detect the Az.Accounts states that end in "Assembly with same name is already loaded".
      .DESCRIPTION Az.Accounts lists its own DLLs (Microsoft.Azure.PowerShell.AssemblyLoading.dll and friends) in
                   the manifest's RequiredAssemblies, which PowerShell loads BEFORE the .psm1 runs - and an
                   assembly can never be unloaded from a session. Load two different Az.Accounts copies into one
                   session (two versions, or one version reachable from two scopes) and the second throws
                   FileLoadException: "Assembly with same name is already loaded". No retry recovers it; the
                   session is spent.

                   The sizing scripts' real defence is ORDERING - they import Az.Accounts first, so every
                   Az.<Service> afterwards takes the "already loaded and new enough" branch and never resolves a
                   second copy for itself. This function is the net under that: it catches the two states the
                   ordering cannot save, and warns about the setup that makes them likely.
      .OUTPUTS   @{ Fatal = @('...'); Warning = @('...') }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Name)

    $fatal = [System.Collections.Generic.List[string]]::new()
    $warn  = [System.Collections.Generic.List[string]]::new()

    $azNames = @($Name | Where-Object { $_ -like 'Az.*' })
    if (-not $azNames.Count) { return @{ Fatal = @(); Warning = @() } }      # AWS/GCP runs: nothing to check

    $installed = @(Get-Module -ListAvailable -Name Az.Accounts -ErrorAction SilentlyContinue |
                        Sort-Object Version -Descending)
    if (-not $installed.Count) { return @{ Fatal = @(); Warning = @() } }    # not installed at all -> reported as a missing module

    $floor  = Get-CVAzAccountsFloor -Name $azNames
    $loaded = @(Get-Module -Name Az.Accounts -ErrorAction SilentlyContinue | Sort-Object Version -Descending)[0]

    if ($loaded -and $floor.Version -and $loaded.Version -lt $floor.Version) {
        # Poisoned session: too-old Az.Accounts is ALREADY loaded, so its assemblies are already pinned here.
        # This is the case that produced an unreadable wall of loader errors instead of one clear sentence.
        $fatal.Add(("Az.Accounts $($loaded.Version) is already loaded in this session, but $($floor.By) requires " +
                    "$($floor.Version) or newer. PowerShell cannot unload assemblies, so this session cannot be repaired."))
    }
    elseif ($floor.Version -and $installed[0].Version -lt $floor.Version) {
        # Nothing installed is new enough - ordering is irrelevant, the import fails either way.
        $fatal.Add(("Az.Accounts $($installed[0].Version) is the newest version installed, but $($floor.By) requires " +
                    "$($floor.Version) or newer. Run: Update-Module Az.Accounts -Scope CurrentUser"))
    }

    # Advisory, deliberately NOT fatal: side-by-side copies are harmless as long as Az.Accounts is imported
    # first, which these scripts do. It only bites when something else (a profile, an editor extension, an
    # earlier partial run) loaded an older copy first. Blocking here would fail machines that work today.
    $copies = @($installed | ForEach-Object { "$($_.Version) at $($_.ModuleBase)" } | Select-Object -Unique)
    if ($copies.Count -gt 1) {
        $warn.Add(("Multiple Az.Accounts copies are visible on PSModulePath ($($copies -join '; ')). Loading two of " +
                   "them in one session fails with 'Assembly with same name is already loaded'. Keep exactly one: " +
                   "Uninstall-Module Az.Accounts -AllVersions, then reinstall into a single scope."))
    }

    return @{ Fatal = @($fatal); Warning = @($warn) }
}

function Write-CVPreflightFailure {
    <#
      .SYNOPSIS  Render a fatal preflight block. PLAIN output on purpose - the missing piece may be Spectre itself.
      .OUTPUTS   $false (or exits 1 when -ExitOnFatal), so callers can `return (Write-CVPreflightFailure ...)`.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string[]]$Instructions = @(),
        [switch]$ExitOnFatal
    )
    Write-Host ""
    Write-Host "  PREFLIGHT FAILED  " -ForegroundColor Red
    Write-Host $Message -ForegroundColor Red
    Write-Host ""
    foreach ($line in $Instructions) {
        if ($line.StartsWith('    ')) { Write-Host $line -ForegroundColor Cyan }
        else { Write-Host "  $line" -ForegroundColor Yellow }
    }
    Write-Host ""
    if (Test-CVConsoleReady) {
        Write-CVFileLine -Time (Get-Date) -Level 'Fatal' -Source 'Preflight' -Message ("$Message`n" + ($Instructions -join "`n"))
    }
    if ($ExitOnFatal) { exit 1 }
    return $false
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

    # Az.Accounts version / duplication conflicts. Checked only once the modules are known to be present - a
    # genuinely missing module is the more fundamental problem and is reported below with install instructions.
    # No-op for AWS and GCP runs, which pass no Az.* modules.
    if ($FatalModules -and -not $missingModules.Count) {
        $azConflict = Test-CVAzModuleConflict -Name $FatalModules
        foreach ($w in $azConflict.Warning) {
            if (Test-CVConsoleReady) { Write-CVLog -Message $w -Level Warning -Source 'Preflight' }
            else { Write-Host "[Preflight] $w" -ForegroundColor Yellow }
        }
        if ($azConflict.Fatal.Count) {
            $azInst = [System.Collections.Generic.List[string]]::new()
            foreach ($f in $azConflict.Fatal) { $azInst.Add($f) }
            $azInst.Add("Keep exactly ONE Az.Accounts installed, in one scope:")
            $azInst.Add("    Uninstall-Module Az.Accounts -AllVersions -Force")
            $azInst.Add("    Install-Module Az.Accounts -Scope CurrentUser -Force")
            $azInst.Add("(Uninstall-Module only removes what PowerShellGet installed - a copy under Program Files must be deleted by hand.)")
            $azInst.Add("Then re-run from a NEW session, since this one already has the old assemblies loaded:")
            $azInst.Add("    pwsh -NoProfile")
            $azInst.Add("(-NoProfile matters: a profile that imports Az or Microsoft.Graph loads conflicting assemblies before the script starts.)")
            return (Write-CVPreflightFailure -Message "Az.Accounts version conflict - the run would fail at Import-Module." `
                                             -Instructions $azInst -ExitOnFatal:$ExitOnFatal)
        }
    }

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
        #
        # The hint MUST be provider-aware. AWS.Tools.* and Az.* manifests declare EXACT RequiredModules versions,
        # so a plain `Install-Module <one module> -Force` drops a new module beside a stale AWS.Tools.Common or
        # Az.Accounts and the import then fails on the version mismatch - which neither -Force, -AllowClobber, nor
        # a fresh session can repair, because the old version directory is still on disk. That is precisely the
        # "hard-coded module versions that won't update" trap users have hit. Point them at the remedy that works.
        $instructions = [System.Collections.Generic.List[string]]::new()
        if ($missingModules.Count) {
            $awsMods   = @($missingModules | Where-Object { $_ -like 'AWS.Tools.*' })
            $azMods    = @($missingModules | Where-Object { $_ -like 'Az.*' })
            $graphMods = @($missingModules | Where-Object { $_ -like 'Microsoft.Graph.*' })
            $otherMods = @($missingModules | Where-Object { $_ -notlike 'AWS.Tools.*' -and $_ -notlike 'Az.*' -and $_ -notlike 'Microsoft.Graph.*' })

            if ($awsMods.Count) {
                $instructions.Add("AWS modules - install them TOGETHER with -CleanUp so side-by-side versions cannot conflict:")
                $instructions.Add("    Install-Module AWS.Tools.Installer -Scope CurrentUser -Force")
                $instructions.Add("    Install-AWSToolsModule $($awsMods -join ',') -Scope CurrentUser -CleanUp -Force")
                $instructions.Add("(A plain Install-Module of a single AWS.Tools.* module leaves an older AWS.Tools.Common in place; the exact-version requirement then fails at import and -Force will not fix it.)")
            }
            if ($azMods.Count) {
                $instructions.Add("Azure modules - install all of them in one call, then align Az.Accounts:")
                $instructions.Add("    Install-Module $($azMods -join ',') -Scope CurrentUser -Force -AllowClobber")
                $instructions.Add("    Update-Module Az.Accounts")
                $instructions.Add("(Each Az.<Service> requires a MINIMUM Az.Accounts version, checked as it imports - not an exact pin. Keep exactly one Az.Accounts installed, in one scope: two copies loaded in the same session fail with 'Assembly with same name is already loaded', and PowerShell cannot unload the first.)")
            }
            if ($graphMods.Count) {
                $instructions.Add("Microsoft Graph modules - one call, so they share a matching Authentication version:")
                $instructions.Add("    Install-Module $($graphMods -join ',') -Scope CurrentUser -Force")
            }
            if ($otherMods.Count) {
                $instructions.Add("To install the remaining PowerShell module(s), run:")
                $instructions.Add("    Install-Module $($otherMods -join ',') -Scope CurrentUser -Force")
            }
        }
        if ($missingCommands.Count) {
            $instructions.Add("To install the missing command-line tool(s):")
            foreach ($c in $missingCommands) { $instructions.Add("    $c  ->  $(Get-CVCommandInstallHint $c)") }
        }
        $instructions.Add("Then re-run this script.")

        # Diagnostics for the "I installed it and it still says missing" case: almost always a wrong scope, a
        # Windows PowerShell 5.1 install, or a sudo/other-user install - none of which were visible before.
        if ($missingModules.Count) {
            $instructions.Add("If you believe these are already installed, check WHERE PowerShell is looking:")
            $instructions.Add("    pwsh $($PSVersionTable.PSVersion) / $($PSVersionTable.PSEdition)")
            foreach ($mp in @($env:PSModulePath -split [IO.Path]::PathSeparator | Where-Object { $_ })) {
                $instructions.Add("    PSModulePath: $mp")
            }
            foreach ($mm in $missingModules) {
                $found = @(Get-Module -ListAvailable -Name $mm -ErrorAction SilentlyContinue |
                            Select-Object -First 3 | ForEach-Object { "$($_.Version) at $($_.ModuleBase)" })
                if ($found.Count) { $instructions.Add("    $mm found but not usable: $($found -join '; ')") }
            }
        }

        return (Write-CVPreflightFailure -Message $fmsg -Instructions $instructions -ExitOnFatal:$ExitOnFatal)
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
            # NB: this Get-Command is not free of side effects - command discovery AUTO-IMPORTS Az.Accounts to
            # resolve the name. That is harmless (it loads the newest copy, which is the same one the script
            # would import moments later, and getting Az.Accounts in first is exactly the ordering we want),
            # but it does mean Az.Accounts is usually already loaded before the script's explicit Import-Module.
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
