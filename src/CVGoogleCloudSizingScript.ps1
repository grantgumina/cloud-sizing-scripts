#requires -Version 7.2
# Windows PowerShell 5.1 is NOT supported: the shared console layer needs $PSStyle (7.2+). A #requires directive
# is evaluated BEFORE the script is parsed, so it fires ahead of any syntax or module error that would mask it.
# Keep the blank line below - without it PowerShell stops treating the next block as comment-based help.

<#
.SYNOPSIS
    GCP Cloud Sizing Script - Fast VM and Storage inventory with correct summaries

.DESCRIPTION
    - Inventories GCP Compute Engine VMs and Cloud Storage Buckets across all or specified projects.
    - Speeds up disk lookups by using a single project-wide disk list.
    - Sizes buckets and BigQuery datasets from Cloud Monitoring (one query per project, no object or table
      enumeration). Bucket sizes are up to a day old; BigQuery sizes up to a few hours old, logical bytes only.
    - Produces summary with VM counts only and disk sizes without double-counting regional disks.
    - Regional disks: Zone is blank, sizes roll up at Region level only.
    - Transcript is closed before zipping so the full log is included in the archive.

.PARAMETER Types
    Optional. Restrict inventory to specific resource types. 
    **Valid values**: [VM, Storage, Fileshare]
    If omitted, all resource types will be inventoried.
    Accepts any of the following forms:
        -Types VM,Storage              (unquoted comma-separated list)
        -Types "VM"                    (single type)
        -Types "VM","Storage"        (standard string array)
        -Types "VM,Storage"            (single quoted comma-separated string, case insensitive)
        
.PARAMETER Projects
        Optional. Target specific GCP projects by name or ID. If omitted, all accessible projects will be processed.
        Accepts any of the following forms:
            -Projects proj1,proj2              (unquoted comma-separated list)
            -Projects "proj1"                  (single project)
            -Projects "proj1","proj2"        (standard string array)
            -Projects "proj1,proj2"          (single quoted comma-separated string)

.OUTPUTS
        Writes to the repository top level (or the current directory when run outside the repo):
            Output/gcp_YYYY-MM-DD_HHMMSS/
                - gcp_inventory_summary_*.csv                 (the rollup - see below)
                - gcp_vm_zone_rollup_*.csv                    (per-zone VM capacity)
                - gcp_vm_instance_info_*.csv                  (VM inventory)
                - gcp_disks_attached_to_vm_instances_*.csv    (attached disks)
                - gcp_disks_unattached_to_vm_instances_*.csv  (unattached disks)
                - gcp_storage_buckets_info_*.csv              (bucket inventory)
                - gcp_filestore_instances_*.csv, gcp_gke_clusters_*.csv, gcp_disk_snapshots_*.csv,
                  gcp_cloudsql_instances_*.csv, gcp_spanner_instances_*.csv, gcp_alloydb_clusters_*.csv,
                  gcp_bigquery_datasets_*.csv, and the GKE PV/PVC pair
                - gcp_resilience_signals_*.csv                (unless -SkipResilienceReport)
                - gcp_sizing_*.json                           (only with -OutputFormat json|both)

            gcp_inventory_summary_*.csv carries Project, ResourceType, Region, Count, TotalSizeGB,
            TotalSizeTB, TotalSizeTiB - the same seven columns Azure and AWS publish - in four tiers:
            overall, overall by region, per project, then per project by region. It no longer has the
            Level or Zone columns; zone detail is in gcp_vm_zone_rollup_*.csv.

            EVERY CSV here is pure CSV: one header row, one row per resource, nothing appended. Four of
            them used to carry a trailing 'Summary:' block, which made a consumer totalling
            gcp_disk_snapshots_*.csv read exactly twice the real figure.
            Output/gcp_YYYY-MM-DD_HHMMSS.zip                  (ZIP archive of the run's output)
            Logs/gcp_YYYY-MM-DD_HHMMSS.log                    (execution log / transcript)
        The per-run Output folder is kept alongside the ZIP; nothing is deleted.

.NOTES
    Requires Google Cloud SDK (gcloud CLI) installed and authenticated.
    Must be run by a user with appropriate GCP permissions.


    SETUP INSTRUCTIONS FOR GOOGLE CLOUD SHELL (Recommended):

    1. Learn about Google Cloud Shell:
        Visit: https://cloud.google.com/shell/docs

    2. Verify GCP permissions:
        Ensure your Google account has "Viewer" or higher role on target projects.

    3. Access Google Cloud Shell:
        - Login to Google Cloud Console with your account
        - Open Google Cloud Shell

    4. Upload this script:
        Use the Cloud Shell file upload feature to upload CVGoogleCloudSizingScript.ps1
        - Enter PowerShell mode, by executing the command:
            pwsh
        - run chmod +x CVGoogleCloudSizingScript.ps1 to allow the script execution permissions

    5. Run the script:
        # For all workload, all Projects
        ./CVGoogleCloudSizingScript.ps1

        # For specific workloads, all Projects
        ./CVGoogleCloudSizingScript.ps1 -Types VM,Storage

        # For all workload, specific Projects
        ./CVGoogleCloudSizingScript.ps1 -Projects my-gcp-project-1,my-gcp-project-2

        # For specific workloads, specific Projects
        ./CVGoogleCloudSizingScript.ps1 -Types VM -Projects my-gcp-project-1,my-gcp-project-2


    SETUP INSTRUCTIONS FOR LOCAL SYSTEM:

    1. Install PowerShell 7:
        Download from: https://github.com/PowerShell/PowerShell/releases

    2. Install Google Cloud SDK:
        Download from: https://cloud.google.com/sdk/docs/install

    3. Authenticate with GCP:
        gcloud auth login

    4. Verify permissions:
        Ensure your account has "Viewer" or higher role on target projects

    5. Run the script:
        # For all workload, all Projects
        ./CVGoogleCloudSizingScript.ps1

        # For specific workloads, all Projects
        ./CVGoogleCloudSizingScript.ps1 -Types VM,Storage

        # For all workload, specific Projects
        ./CVGoogleCloudSizingScript.ps1 -Projects my-gcp-project-1,my-gcp-project-2

        # For specific workloads, specific Projects
        ./CVGoogleCloudSizingScript.ps1 -Types VM -Projects my-gcp-project-1,my-gcp-project-2

    EXAMPLE USAGE
    -------------
        .\CVGoogleCloudSizingScript.ps1
        # Inventories VMs and Storage Buckets in all accessible projects

        .\CVGoogleCloudSizingScript.ps1 -Types VM,Storage
        # Explicitly inventories VMs and Storage Buckets in all projects (same as default)

        .\CVGoogleCloudSizingScript.ps1 -Types VM
        # Only inventories Compute Engine VMs in all projects

        .\CVGoogleCloudSizingScript.ps1 -Projects my-gcp-project-1,my-gcp-project-2
        # Inventories VMs and Storage Buckets in only the specified projects

        .\CVGoogleCloudSizingScript.ps1 -Types Storage -Projects my-gcp-project-1
        # Only inventories Storage Buckets in the specified project

        .\CVGoogleCloudSizingScript.ps1 -SkipDataProtection
        # Cloud Rewind billable-resource sizing only (writes gcp_cloudrewind_<ts>.csv + summary)

        .\CVGoogleCloudSizingScript.ps1 -Labels env=production
        # Scope both passes to resources labelled env=production; Cloud Rewind requires the Cloud Asset API
#>


param(
    [ValidateSet('VM','Storage','Fileshare','DB','GKE','Filestore','Snapshot', IgnoreCase = $true)]
    [string[]]$Types,
    [string[]]$Projects,
    [switch]$LightMode,               # Leaner concurrency model
    [switch]$ForceKubectl,            # Require kubectl to be present (fail if cannot provision)
    [int]$MaxVMThreads                = 10,
    [int]$MaxBucketThreads            = 10,
    [int]$VMProjectTimeoutSec         = 600,   # 10m
    [int]$BucketProjectListTimeoutSec = 300,   # 5m
    [int]$BucketSizingTimeoutSec      = 1200,  # 20m
    [int]$DbProjectTimeoutSec         = 900,   # 15m per project for DB inventory (soft)
    [ValidateSet("csv","json","both")][string]$OutputFormat = "csv",  # Output format: csv (default), json, or both
    [switch]$NonInteractive,   # force plain, non-interactive output (no progress bars / rich UI) - for CI / automation
    [switch]$Quiet,            # minimal console output (still writes the full log file)
    [switch]$SkipResilienceReport, # do not compute or write the cyber resilience posture report
    [string[]]$Labels,             # limit BOTH passes to resources carrying any of these 'key=value' labels
    [switch]$SkipCloudRewind,      # skip the Cloud Rewind billable-resource sizing pass
    [switch]$SkipDataProtection,   # skip the Data Protection inventory + resilience pass (run Cloud Rewind only)
    [string]$OutputDirectory       # write Output/ and Logs/ under this root instead of the repo/script location
)

# Guard: at least one discovery pass must run.
if ($SkipCloudRewind -and $SkipDataProtection) {
    Write-Host 'ERROR: -SkipCloudRewind and -SkipDataProtection cannot both be set - nothing would run.' -ForegroundColor Red
    exit 1
}

# Load the shared console / diagnostics + resilience + Cloud Rewind layers (src/common/).
# Dot-sourcing a MISSING file is non-terminating, so an incomplete copy used to march on through cascading
# CommandNotFoundExceptions and silently skip Assert-CVPreflight. Check first, and name what is missing.
# This block must stay inline - it is the thing that guards dot-sourcing.
$cvCommonDir = Join-Path $PSScriptRoot 'common'
$cvRequired  = @(
    'CVSizing.Console.ps1'          # console / diagnostics / run paths
    'CVSizing.Resilience.ps1'       # provider-neutral scoring engine
    'CVSizing.Resilience.GCP.ps1'   # GCP control definitions
    'CVSizing.Summary.ps1'          # shared four-pass inventory rollup engine (cloud-agnostic)
    'CVSizing.Summary.GCP.ps1'      # GCP descriptor table for it
    'CVSizing.Kubectl.ps1'          # cross-platform kubectl provisioning
    'CVSizing.CloudRewind.ps1'      # provider-neutral Cloud Rewind engine
    'CVSizing.CloudRewind.GCP.ps1'  # GCP billable taxonomy (derived)
    'CVSizing.Metrics.GCP.ps1'      # Cloud Monitoring reads for bucket and BigQuery sizing
)
$cvMissing = @($cvRequired | Where-Object { -not (Test-Path -LiteralPath (Join-Path $cvCommonDir $_) -PathType Leaf) })
if ($cvMissing.Count) {
    Write-Host "FATAL: the shared layer this script depends on was not found." -ForegroundColor Red
    Write-Host "Expected under: $cvCommonDir" -ForegroundColor Red
    $cvMissing | ForEach-Object { Write-Host "  missing: $_" -ForegroundColor Red }
    Write-Host "This script cannot run standalone. Copy the whole src/ directory (the script AND src/common/)," -ForegroundColor Yellow
    Write-Host "or clone the repository, and run it from there." -ForegroundColor Yellow
    exit 1
}
foreach ($cvFile in $cvRequired) { . (Join-Path $cvCommonDir $cvFile) }

# Projects whose Cloud Monitoring read failed (Storage and/or BigQuery), reported with a fix at the end of the run,
# and per-project BigQuery status for gcp_project_status_bigquery_*.csv. Both paths run on this thread.
$script:CVGcpMonitoringFailures = [System.Collections.Generic.List[psobject]]::new()
$script:CVGcpBqProjectStatuses  = [System.Collections.Generic.List[psobject]]::new()

# Normalize -Projects if provided as a single comma-separated string inside quotes
if ($Projects -and $Projects.Count -eq 1 -and $Projects[0] -match ',') {
    $Projects = $Projects[0].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

# Normalize -Types if provided as a single comma-separated string inside quotes
if ($Types -and $Types.Count -eq 1 -and $Types[0] -match ',') {
    $Types = $Types[0].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

# Enforce non-interactive execution for all gcloud commands
$env:CLOUDSDK_CORE_DISABLE_PROMPTS = '1'

# Post-normalization validation for -Types (case-insensitive)
if ($Types) {
    $allowed = @('VM','STORAGE','FILESHARE','DB','GKE','FILESTORE','SNAPSHOT')
    $bad = $Types | Where-Object { $allowed -notcontains ($_.Trim().ToUpper()) }
    if ($bad.Count -gt 0) {
        Write-Error ("Invalid value(s) for -Types: {0}. Valid values: VM, Storage, Fileshare, DB, GKE, Filestore, Snapshot" -f ($bad -join ', '))
        return
    }
}

# Try to remove this and always have more output in logs - $$$$$
$MinimalOutput = $false

# -------------------------
# Setup output + transcript
# -------------------------
$dateStr = (Get-Date).ToString("yyyy-MM-dd_HHmmss")
# Resolve this run's Output/ and Logs/ directories at the repo top level (or CWD when run outside the repo).
$runPaths = Initialize-CVRunPaths -Cloud 'GCP' -TimeStamp $dateStr -StartPath $PSScriptRoot -OutputRoot $OutputDirectory
$outDir = $runPaths.OutputDir
New-Item -Path $outDir -ItemType Directory -Force | Out-Null

$transcriptFile = $runPaths.LogPath   # top-level Logs/<run>.log, kept separate from the CSV output
Start-Transcript -Path $transcriptFile -Append | Out-Null

# Expose primary log file path to child runspaces via environment variable so Write-Log can append directly
$env:GCP_INVENTORY_LOGFILE = $transcriptFile

# Global concurrent queue to collect log lines from child runspaces (VM & Bucket)
if (-not (Get-Variable -Name ChildLogQueue -Scope Global -ErrorAction SilentlyContinue)) {
    $Global:ChildLogQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
}


# --- Preflight (fail fast, plain) then initialize the shared console layer ---
# Console-only mode: Start-Transcript (above) owns the log file; the console layer adds tiered rendering,
# error de-duplication and the end-of-run summary on top.
$peek = Get-CVConsoleCapability -NonInteractive:$NonInteractive -Quiet:$Quiet
$fatalModules = @()
if (-not $peek.IsHeadless) { $fatalModules += 'PwshSpectreConsole' }
# Highly opinionated: require the CLI needed for broad discovery. gsutil and bq are no longer needed: buckets and
# BigQuery are sized from Cloud Monitoring over REST (common/CVSizing.Metrics.GCP.ps1).
# kubectl stays optional only because the script auto-provisions it (Ensure-Kubectl) for GKE when absent.
Assert-CVPreflight -FatalModules $fatalModules -FatalCommands @('gcloud') `
                   -OptionalCommands @{ 'GKE inventory (kubectl)' = 'kubectl' } `
                   -ExitOnFatal | Out-Null

Initialize-CVConsole -Cloud GCP -Title 'GCP Resource Inventory' `
                     -NonInteractive:$NonInteractive -Quiet:$Quiet | Out-Null
if ($Types)    { Write-CVLog "Types: $($Types -join ', ')" -Level Info -Source 'Init' }
if ($Projects) { Write-CVLog "Projects: $($Projects -join ', ')" -Level Info -Source 'Init' }

# Everything below runs inside a top-level handler. Without one, an unhandled terminating error produced no run
# summary, no diagnostics and no Stop-Transcript - the user saw a raw stack trace and no indication of what had
# already been collected. (AWS has had this; Azure and GCP did not.)
try {

function Test-CVGcloudQuotaProject {
    <#
      .SYNOPSIS  Warn early when gcloud's active project is missing or deleted.
      .DESCRIPTION gcloud sends core/project as the quota/billing project on many API calls. When it points at a
                   deleted project every such call fails with USER_PROJECT_DENIED, in a message that names the
                   stale project rather than the one being scanned - which reads like "the API is disabled" in
                   every project at once. Catching it here turns a whole class of confusing failures into one line.
    #>
    [CmdletBinding()] param()
    $cur = (& gcloud config get-value core/project --quiet 2>$null | Out-String).Trim()
    if (-not $cur -or $cur -eq '(unset)') {
        Write-CVLog "gcloud core/project is unset. Some APIs bill quota to it and may fail; run 'gcloud config set project <id>'." `
                    -Level Warning -Source 'Preflight' -Scope @{ Category = 'QuotaProject' }
        return
    }
    $null = & gcloud projects describe $cur --format=json --quiet 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-CVLog ("gcloud core/project '{0}' does not resolve (deleted or inaccessible). It is sent as the quota project, so Cloud Asset / Spanner / other API calls will fail in EVERY scanned project until you run 'gcloud config set project <live-id>'." -f $cur) `
                    -Level Warning -Source 'Preflight' -Scope @{ Category = 'QuotaProject'; Project = $cur }
    } else {
        Write-CVLog "gcloud quota project: $cur" -Level Debug -Source 'Preflight'
    }
}
Test-CVGcloudQuotaProject


# Resource type mapping
$ResourceTypeMap = @{
    "VM"        = "VMs"
    "STORAGE"   = "StorageBuckets"
    "FILESHARE" = "FileShares"
    "DB"        = "Databases"
    "GKE"       = "GKEClusters"
    "FILESTORE" = "FilestoreInstances"
    "SNAPSHOT"  = "DiskSnapshots"
}

# Normalize types
if ($Types) {
    # Already validated; convert to uppercase normalized set
    $Types = $Types | ForEach-Object { $_.Trim().ToUpper() }
    $Selected = @{}
    foreach ($t in $Types) { if ($ResourceTypeMap.ContainsKey($t)) { $Selected[$t] = $true } }
    if ($Selected.Count -eq 0) { Write-Host "No valid -Types specified. Use: VM, Storage"; exit 1 }
} else { $Selected = @{}; $ResourceTypeMap.Keys | ForEach-Object { $Selected[$_] = $true } }

# -SkipDataProtection: run Cloud Rewind only. Clearing $Selected skips the DP inventory dispatch; the resilience
# pass and DP CSV exports are guarded by .Count and by -SkipDataProtection, so they no-op safely.
if ($SkipDataProtection) { $Selected = @{} }

# -------------------------
# Helpers
# -------------------------
function Get-GcpProjects {
    try {
    # Added --quiet to suppress any interactive prompt
    $json = gcloud --quiet projects list --format=json | ConvertFrom-Json
        if (-not $json) { throw "No projects returned by gcloud." }
        return $json.projectId
    } catch {
        Write-CVLog "Failed to list GCP projects. Ensure the gcloud SDK is installed and authenticated." -Level Error -Source 'Auth' -Exception $_
        Write-CVSummary -Title 'GCP Sizing Run Summary (aborted)'
        Stop-Transcript | Out-Null
        exit 1
    }
}

function Get-RegionFromZone {
    param([string]$zone)
    if (-not $zone) { return "Unknown" }
    $z = $zone -replace '.*/',''
    return ($z -replace '-[a-z]$','')
}

function Get-CVWorkerLineLevel {
    <#
      .SYNOPSIS  Pick a log level for a per-project worker line from its own tag.
      .DESCRIPTION Workers tag their lines [X-Project-Warn] / -Skip / -Error / -Debug. Replaying every one of
                   them at Debug meant that in console-only mode (where Start-Transcript owns the file and Debug
                   is never rendered) NONE of them reached the log - so "VMs=0" was indistinguishable from
                   "we could not list VMs in this project". The failures have to survive.
    #>
    [CmdletBinding()]
    param([string]$Line)
    if ($Line -match '-Error\]|JSON parse failed')       { return 'Error' }
    if ($Line -match '-Warn\]|-Skip\]|failed|denied|not enabled|is disabled') { return 'Warning' }
    return 'Debug'
}

function Invoke-CVGcloudJson {
    <#
      .SYNOPSIS  Run a JSON-emitting gcloud command and report success or failure explicitly.
      .DESCRIPTION Callers must be able to tell "the API says there is nothing" (Ok with empty Data) from
                   "we could not look" (Ok = $false). Collapsing the two is what turns a disabled API into a
                   fabricated "unprotected" finding, so this never returns bare $null on failure.
                   ApiDisabled/CommandMissing classify the two failure modes worth acting on.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)

    $raw  = & gcloud @Arguments --format=json --quiet 2>&1
    $code = $LASTEXITCODE
    $text = ($raw | Out-String).Trim()

    if ($code -ne 0) {
        return [pscustomobject]@{
            Ok             = $false
            Data           = $null
            Error          = $text
            # gcloud reports a disabled API as PERMISSION_DENIED/SERVICE_DISABLED - not a real permission problem.
            ApiDisabled    = [bool]($text -match 'SERVICE_DISABLED|has not been used in project|API .*not enabled|is disabled')
            CommandMissing = [bool]($text -match 'Invalid choice')
        }
    }
    $data = $null
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        try { $data = $text | ConvertFrom-Json }
        catch {
            return [pscustomobject]@{ Ok=$false; Data=$null; Error="JSON parse failed: $($_.Exception.Message)"; ApiDisabled=$false; CommandMissing=$false }
        }
    }
    return [pscustomobject]@{ Ok=$true; Data=$data; Error=''; ApiDisabled=$false; CommandMissing=$false }
}

function Invoke-CVGcloudJsonAnyTrack {
    <#
      .SYNOPSIS  As Invoke-CVGcloudJson, but tolerant of a command that only exists on an alternate release track.
      .DESCRIPTION Tries GA first, then the supplied fallback tracks, and only advances when gcloud reports
                   "Invalid choice" (the surface does not exist here) - never when the call failed for a real
                   reason. Returns the result plus the Track that answered, so callers can cache it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string[]]$FallbackTracks = @('beta','alpha'),
        [string]$PreferTrack
    )
    $tracks = if ($PSBoundParameters.ContainsKey('PreferTrack')) { ,$PreferTrack } else { @('') + $FallbackTracks }
    $last = $null
    foreach ($t in $tracks) {
        $argv = if ([string]::IsNullOrEmpty($t)) { $Arguments } else { @($t) + $Arguments }
        $last = Invoke-CVGcloudJson -Arguments $argv
        Add-Member -InputObject $last -NotePropertyName Track -NotePropertyValue $t -Force
        if ($last.Ok -or -not $last.CommandMissing) { return $last }
    }
    return $last
}

function Ensure-Kubectl {
    param([switch]$Force)
    $env:CLOUDSDK_CORE_DISABLE_PROMPTS = '1'
    Write-Host '[Ensure-Kubectl] Ensuring kubectl presence.' -ForegroundColor Cyan

    # Detect platform
    $isWin = $false
    try {
        if ($env:OS -eq 'Windows_NT' -or [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) { $isWin = $true }
    } catch { if ($env:OS -match 'Windows') { $isWin = $true } }

    function Add-PathSegment {
        param([string]$Dir,[switch]$Windows)
        if (-not $Dir) { return }
        if ($Windows) {
            if (-not (($env:PATH -split ';') -contains $Dir)) { $env:PATH = $Dir + ';' + $env:PATH }
        } else {
            if (-not (($env:PATH -split ':') -contains $Dir)) { $env:PATH = $Dir + ':' + $env:PATH }
        }
    }

    function Resolve-KubectlLocal {
        try { return (Get-Command kubectl -ErrorAction SilentlyContinue).Source } catch { return $null }
    }

    $resolved = Resolve-KubectlLocal
    if ($resolved) {
        Write-Host "[Ensure-Kubectl] Found existing kubectl: $resolved" -ForegroundColor Green
        # Don't return yet; still ensure auth plugin & component freshness.
    }

    # Try gcloud components (preferred official source)
    $gcloudCmd = Get-Command gcloud -ErrorAction SilentlyContinue
    if ($gcloudCmd) {
        Write-Host '[Ensure-Kubectl] Checking gcloud components...' -ForegroundColor Cyan
    try { $installedComponents = & gcloud components list --quiet --format="value(id)" 2>$null } catch { $installedComponents=@() }
    if (-not $installedComponents) { $installedComponents=@() } elseif ($installedComponents -is [string]) { $installedComponents=@($installedComponents) }

        # Helper: detect plugin executable presence
        $pluginExe = $null
        try {
            $pluginCmdTest = Get-Command gke-gcloud-auth-plugin -ErrorAction SilentlyContinue
            if ($pluginCmdTest) { $pluginExe = $pluginCmdTest.Source }
        } catch {}
        if (-not $pluginExe) {
            # Probe common locations relative to gcloud root
            $gcloudRoot = Split-Path -Parent (Split-Path -Parent $gcloudCmd.Source)  # .../google-cloud-sdk
            $candidatePaths = @(
                (Join-Path $gcloudRoot 'bin\gke-gcloud-auth-plugin.exe'),
                (Join-Path $gcloudRoot 'bin\gke-gcloud-auth-plugin'),
                (Join-Path (Split-Path -Parent $gcloudCmd.Source) 'gke-gcloud-auth-plugin.exe'),
                (Join-Path (Split-Path -Parent $gcloudCmd.Source) 'gke-gcloud-auth-plugin')
            )
            foreach ($cp in $candidatePaths) { if ($pluginExe) { break }; if (Test-Path $cp) { $pluginExe = $cp } }
        }

    # Always ensure both components each run (idempotent) so stale partial installs get corrected.
    $needInstall = @('kubectl','gke-gcloud-auth-plugin')
        if ($needInstall.Count -gt 0) {
            Write-Host "[Ensure-Kubectl] Installing: $($needInstall -join ', ')" -ForegroundColor Yellow
            # Windows non-interactive workaround: copy bundled python so component install can proceed headless
            if ($isWin) {
                try {
                    Write-Host '[Ensure-Kubectl] (Windows) Preparing bundled Python for non-interactive component install...' -ForegroundColor Cyan
                    $copyOut = & gcloud components copy-bundled-python 2>&1
                    $pythonPath = ($copyOut | Select-Object -Last 1).Trim()
                    if ($pythonPath -and (Test-Path $pythonPath)) {
                        $env:CLOUDSDK_PYTHON = $pythonPath
                        Write-Host "[Ensure-Kubectl] Set CLOUDSDK_PYTHON=$pythonPath" -ForegroundColor DarkGray
                    } else {
                        Write-Warning '[Ensure-Kubectl] Could not resolve copied bundled python path; proceeding anyway.'
                    }
                } catch { Write-Warning "[Ensure-Kubectl] Bundled python copy failed: $($_.Exception.Message)" }
            }
            $componentInstallOutput = @()
            try {
                $componentInstallOutput = & gcloud components install @needInstall -q 2>&1
                $componentInstallOutput | ForEach-Object { Write-Host "[Ensure-Kubectl][gcloud] $_" -ForegroundColor DarkGray }
            } catch {
                Write-Warning "[Ensure-Kubectl] Component install error: $($_.Exception.Message)"
            }
            # Bundled python limitation handling (simpler): if failure, run copy-bundled-python and retry install once
            if ($isWin -and ($componentInstallOutput -match 'Cannot use bundled Python installation')) {
                Write-Warning '[Ensure-Kubectl] Bundled Python restriction detected; copying bundled python and retrying.'
                try {
                    $cpy = & gcloud components copy-bundled-python 2>&1
                    $candidate = ($cpy | Select-Object -Last 1).Trim()
                    if ($candidate -and (Test-Path $candidate)) {
                        $env:CLOUDSDK_PYTHON = $candidate
                        Write-Host "[Ensure-Kubectl] (Retry) Set CLOUDSDK_PYTHON=$candidate" -ForegroundColor DarkGray
                        $componentInstallOutput = & gcloud components install @needInstall -q 2>&1
                        $componentInstallOutput | ForEach-Object { Write-Host "[Ensure-Kubectl][gcloud-rtry] $_" -ForegroundColor DarkGray }
                    } else { Write-Warning '[Ensure-Kubectl] (Retry) Could not determine copied python path.' }
                } catch { Write-Warning "[Ensure-Kubectl] (Retry) copy-bundled-python failed: $($_.Exception.Message)" }
            }
            # Re-evaluate component list after attempted install
            try { $installedComponents = & gcloud components list --quiet --format="value(id)" 2>$null } catch {}
            if ($needInstall | Where-Object { $installedComponents -notmatch $_ }) {
                Write-Warning '[Ensure-Kubectl] One or more requested components did not install successfully.'
            }
        } else { Write-Host '[Ensure-Kubectl] Required components already present.' -ForegroundColor Green }
        # Re-resolve
        $gcloudBin = Split-Path -Parent $gcloudCmd.Source
        foreach ($candidate in @('kubectl','kubectl.exe')) {
            $full = Join-Path $gcloudBin $candidate
            if (Test-Path $full) { $resolved = $full; break }
        }
        if (-not $resolved) { $resolved = Resolve-KubectlLocal }
        # Always add gcloud bin path so plugin executable is on PATH for downloaded kubectl too
        $gcloudBin = Split-Path -Parent $gcloudCmd.Source
        Add-PathSegment -Dir $gcloudBin -Windows:$isWin
    if ($resolved) { Add-PathSegment -Dir (Split-Path -Parent $resolved) -Windows:$isWin; Write-Host "[Ensure-Kubectl] Using kubectl from gcloud dir: $resolved" -ForegroundColor Green }
        # Ensure plugin exists / install retry if missing
        $pluginCmd = Get-Command gke-gcloud-auth-plugin -ErrorAction SilentlyContinue
        if (-not $pluginCmd) {
            Write-Warning '[Ensure-Kubectl] gke-gcloud-auth-plugin not found on PATH; attempting install (retry).'    
            try { & gcloud components install gke-gcloud-auth-plugin -q 2>&1 | ForEach-Object { Write-Host "[Ensure-Kubectl][gcloud] $_" -ForegroundColor DarkGray } } catch { Write-Warning "[Ensure-Kubectl] Plugin install retry error: $($_.Exception.Message)" }
            $pluginCmd = Get-Command gke-gcloud-auth-plugin -ErrorAction SilentlyContinue
        }
    if ($pluginCmd) { Write-Host "[Ensure-Kubectl] Auth plugin: $($pluginCmd.Source)" -ForegroundColor Green } else { Write-Warning '[Ensure-Kubectl] Auth plugin still missing.' }
    $env:USE_GKE_GCLOUD_AUTH_PLUGIN = 'True'
    if ($resolved) { $script:__KubectlResolvedPath=$resolved; return $resolved }
    }

    # Linux apt path (when gcloud not sufficient or absent)
    if (-not $isWin) {
        $apt = Get-Command apt-get -ErrorAction SilentlyContinue
        if ($apt) {
            Write-Host '[Ensure-Kubectl] Attempting apt-get install.' -ForegroundColor Cyan
            $aptCmds = @('sudo apt-get update -y','sudo DEBIAN_FRONTEND=noninteractive apt-get install -y kubectl google-cloud-sdk-gke-gcloud-auth-plugin')
            foreach ($c in $aptCmds) {
                try { & /bin/bash -lc $c 2>&1 | ForEach-Object { Write-Host "[Ensure-Kubectl][apt] $_" -ForegroundColor DarkGray } } catch { Write-Warning "[Ensure-Kubectl] apt step failed: $($_.Exception.Message)"; break }
            }
            $resolved = Resolve-KubectlLocal
            if ($resolved) { Write-Host "[Ensure-Kubectl] Using kubectl from apt: $resolved" -ForegroundColor Green; $script:__KubectlResolvedPath=$resolved; return $resolved }
        }
    }

    # Direct download fallback. Delegated to common/CVSizing.Kubectl.ps1: the previous block pinned $arch='amd64'
    # and hardcoded /tmp/kubectl-bin, so it fetched an amd64 Linux binary onto Apple Silicon and Graviton hosts
    # alike. The shared helper resolves OS and architecture from the runtime, uses the platform temp directory,
    # and verifies the binary actually executes before reporting success.
    Write-Host '[Ensure-Kubectl] Falling back to direct download.' -ForegroundColor Cyan
    $k = Install-CVKubectl
    if ($k.Installed) {
        $resolved = $k.Path
        Write-Host ("[Ensure-Kubectl] kubectl ready -> {0} [{1}, {2}]" -f $k.Path, $k.Platform, $k.Source) -ForegroundColor Green
    } else {
        Write-Warning "[Ensure-Kubectl] Download failed for $($k.Platform): $($k.Error)"
    }

    if ($resolved) {
        # Add gcloud bin path (if available) for plugin resolution in downloaded kubectl scenario
        if ($gcloudCmd) { Add-PathSegment -Dir (Split-Path -Parent $gcloudCmd.Source) -Windows:$isWin }
        $env:USE_GKE_GCLOUD_AUTH_PLUGIN = 'True'
        $pluginCmd = Get-Command gke-gcloud-auth-plugin -ErrorAction SilentlyContinue
        if (-not $pluginCmd -and $gcloudCmd) {
            Write-Warning '[Ensure-Kubectl] Auth plugin not detected after download path; attempting component install.'
            try { & gcloud components install gke-gcloud-auth-plugin -q 2>&1 | ForEach-Object { Write-Host "[Ensure-Kubectl][gcloud] $_" -ForegroundColor DarkGray } } catch { Write-Warning "[Ensure-Kubectl] Plugin install attempt failed: $($_.Exception.Message)" }
            $pluginCmd = Get-Command gke-gcloud-auth-plugin -ErrorAction SilentlyContinue
        }
        if ($pluginCmd) { Write-Host "[Ensure-Kubectl] Auth plugin: $($pluginCmd.Source)" -ForegroundColor Green } else { Write-Warning '[Ensure-Kubectl] Auth plugin unavailable; kubectl GKE auth may fail.' }
        $script:__KubectlResolvedPath = $resolved
        return $resolved
    }

    if ($Force) {
        Write-Error '[Ensure-Kubectl] kubectl could not be provisioned (Force requested).'
        throw 'kubectl not available'
    } else {
        Write-Warning '[Ensure-Kubectl] kubectl not available; continuing without it.'
        return $null
    }
}


# -------------------------
# Lightweight logger 
# -------------------------
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level = 'INFO',
        [string]$Source,            # optional: groups the message in the end-of-run summary
        [hashtable]$Scope           # optional: e.g. @{ Project = $id } - lets repeats across projects de-duplicate
    )
    $ts = (Get-Date).ToString('s')
    $line = "[$ts] [$Level] $Message"
    # Preserve the global queue: CSV reconstruction has read these lines back (BigQuery's per-table CSV did, until
    # BigQuery moved to Cloud Monitoring). Do NOT remove this enqueue without checking for other readers.
    if (-not (Get-Variable -Name ChildLogQueue -Scope Global -ErrorAction SilentlyContinue)) {
        $Global:ChildLogQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    }
    $Global:ChildLogQueue.Enqueue($line) | Out-Null

    if (Get-Command Write-CVLog -ErrorAction SilentlyContinue) {
        # Parent context: route through the shared layer for tiered rendering + warning/error de-duplication.
        # Start-Transcript captures the single console write, so we no longer Add-Content here - that direct
        # append (in addition to the transcript) was the source of the duplicate log lines.
        $cvLevel  = switch ($Level) { 'WARN' { 'Warning' } 'ERROR' { 'Error' } 'DEBUG' { 'Debug' } default { 'Info' } }
        $cvSource = if ($Source) { $Source } else { 'GCP' }
        Write-CVLog -Message $Message -Level $cvLevel -Source $cvSource -Scope $Scope
    }
    else {
        # Worker runspace (shared console layer is not dot-sourced into child runspaces): legacy behavior, unchanged.
        switch ($Level) {
            'ERROR' { Write-Host $line -ForegroundColor Red }
            'WARN'  { Write-Host $line -ForegroundColor Yellow }
            'INFO'  { Write-Host $line -ForegroundColor Gray }
            'DEBUG' { if (-not $MinimalOutput) { Write-Host $line -ForegroundColor DarkGray } }
        }
        if ($env:GCP_INVENTORY_LOGFILE) {
            try { Add-Content -Path $env:GCP_INVENTORY_LOGFILE -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
        }
    }
}



# -------------------------
# VM + Disk Inventory (fast)
# -------------------------
function Get-GcpVMInventory {
    param(
        [string[]]$ProjectIds,
        [switch]$LightMode,
        [int]$MaxThreads = 10,
        [int]$TaskTimeoutSec = 600
    )
    # ScriptBlock executed per project (returns inventory + log lines)
    $vmProjectScriptBlock = {
        param($proj,$minimalFlag)
        $log = New-Object System.Collections.Generic.List[string]
        $startUtc = [DateTime]::UtcNow
        $log.Add("[VM-Project-Start] $proj") | Out-Null

        # Helper to extract region from zone - inner version to avoid cross-runspace issues
        function Get-RegionFromZoneInner {
            param([string]$zone)
            if (-not $zone) { return 'Unknown' }
            $z = $zone -replace '.*/',''
            return ($z -replace '-[a-z]$','')
        }

        # States Initialization to ensure error handling is done correctly
        $apiDisabled = $false
        $permIssue   = $false
        $env:CLOUDSDK_CORE_DISABLE_PROMPTS = '1'

        # Instances List project level - Try block
        try {
            $vmRaw = & gcloud --quiet compute instances list --project $proj --format=json 2>&1
            if ($LASTEXITCODE -ne 0) {
                $msg = ($vmRaw | Out-String).Trim()
                if     ($msg -match '(?i)not enabled|has not been used|is disabled|API .* not enabled') { $apiDisabled = $true }
                elseif ($msg -match '(?i)permission|denied|forbidden|403|PERMISSION_DENIED|insufficientPermissions') { $permIssue  = $true }
                $log.Add("[VM-Project-Warn] $proj instances list failed exit=$LASTEXITCODE msg=$msg") | Out-Null
                $vmList = @()
            } else {
                if ([string]::IsNullOrWhiteSpace(($vmRaw | Out-String))) {
                    $vmList = @()
                } else {
                    try {
                        $vmList = $vmRaw | ConvertFrom-Json
                    } catch {
                        $log.Add("[VM-Project-Error] $proj instances JSON parse failed: $($_.Exception.Message)") | Out-Null
                        # $$$$ check if this empty list causes data falseness or loss later
                        $vmList=@()
                    }
                }
            }
        } 
        
        # Instances List Project level - Exception handling
        catch {
            $log.Add("[VM-Project-Error] $proj instances command threw: $($_.Exception.Message)") | Out-Null
            # $$$$ check if this empty list causes data falseness or loss later
            $vmList=@()
        }

        # Early exit if API disabled or permission issue
        if ($apiDisabled) {
            $log.Add("[VM-Project-Skip] $proj Compute API disabled - skipping VMs & disks") | Out-Null
            return [PSCustomObject]@{ Project=$proj; VMs=@(); AttachedDisks=@(); AllDisks=@(); UnattachedDisks=@(); Logs=$log; DurationSec=[math]::Round(([DateTime]::UtcNow - $startUtc).TotalSeconds,2) }
        }
        if ($permIssue) {
            $log.Add("[VM-Project-Skip] $proj Compute API permission issue - skipping VMs & disks") | Out-Null
            return [PSCustomObject]@{ Project=$proj; VMs=@(); AttachedDisks=@(); AllDisks=@(); UnattachedDisks=@(); Logs=$log; DurationSec=[math]::Round(([DateTime]::UtcNow - $startUtc).TotalSeconds,2) }
        }

        # Disks List project level - Try block
        try {
            $diskRaw = & gcloud --quiet compute disks list --project $proj --format=json 2>&1
            if ($LASTEXITCODE -ne 0) {
                $dmsg = ($diskRaw | Out-String).Trim()
                $log.Add("[VM-Project-Warn] $proj disks list failed exit=$LASTEXITCODE msg=$dmsg") | Out-Null
                $diskListAll = @()
            } else {
                if ([string]::IsNullOrWhiteSpace(($diskRaw | Out-String))) { 
                    $diskListAll=@() 
                }
                else {
                     try { 
                        $diskListAll = $diskRaw | ConvertFrom-Json 
                    } 
                    catch { 
                        $log.Add("[VM-Project-Error] $proj disks JSON parse failed: $($_.Exception.Message)") | Out-Null; $diskListAll=@() 
                    } 
                }
            }
        } 
        # Disks List Project level - Exception handling
        catch {
            $log.Add("[VM-Project-Error] $proj disks command threw: $($_.Exception.Message)") | Out-Null
            # $$$$ check if this empty list causes data falseness or loss later
            $diskListAll=@()
        }

        if (-not $vmList)      { $vmList      = @() }
        if (-not $diskListAll) { $diskListAll = @() }

        # Build disk lookup map. 
        # We now key by (a) selfLink (preferred), and (b) composite "<zoneOrRegion>|<name>". We still keep first-seen entries for composite keys.
        $diskMap = @{}
        foreach ($d in $diskListAll) {
            if (-not $d.name) { continue }
            $selfKey = $null
            
            # Assign Self Link key if available - From disk properties
            if ($d.PSObject.Properties.Name -contains 'selfLink' -and $d.selfLink) {
                $selfKey = $d.selfLink.ToLower() 
            }

            # Fallback to id if selfLink not present - From disk properties
            elseif ($d.PSObject.Properties.Name -contains 'id' -and $d.id) { 
                $selfKey = ("id://" + $d.id) 
            }

            # Fallback - Synthetic key from zone/region + name if no selfLink or id
            else {
                # Fallback synthetic key
                $zr = if ($d.region) { ($d.region -split '/')[-1] } elseif ($d.zone) { ($d.zone -split '/')[-1] } else { '' }
                $selfKey = ("//disk/" + $zr + "/" + $d.name).ToLower()
            }
            
            # Add to map by selfLink/id key (ensures duplicate disks are handled and no data loss)
            $diskMap[$selfKey] = $d
            
            $zr2 = if ($d.region) { 
                ($d.region -split '/')[-1] 
            } elseif ($d.zone) { 
                ($d.zone -split '/')[-1] 
            } else { '' }

            # Add to map by composite key (zone|name or region|name) if not already present (first-seen wins)
            $composite = ($zr2 + '|' + $d.name).ToLower()
            if (-not $diskMap.ContainsKey($composite)) { $diskMap[$composite] = $d }
        }

        # Process VMs and attached disks - Variables to hold results
        $projectVMs       = @()
        $projectAttached  = @()
        $projectAllDisks  = @()
        $projectUnattached= @()
        $vmIndex = 0

        foreach ($vm in $vmList) {
            $vmIndex++
            $zone  = ($vm.zone -replace '.*/','')
            $region = Get-RegionFromZoneInner -zone $vm.zone
            $osType = 'Linux'

            # OS Type detection - from disks - Try block
            try {
                if ($vm.disks) {
                    foreach ($vd in $vm.disks) {
                        if ($vd.licenses) {
                            foreach ($lic in $vd.licenses) { 
                                if ($lic -match 'windows') {
                                    $osType='Windows';
                                    break 
                                } 
                            }
                            if ($osType -eq 'Windows') 
                            { 
                                break 
                            }
                        }
                    }
                }
            } 
            # OS Type detection - fallback - Try block
            catch { 
                $osType='Linux' 
            }

            $vmDiskGB = 0
            if ($vm.disks) {
                if (-not $script:__AllDiskKeys) { $script:__AllDiskKeys = @{} }
                foreach ($disk in $vm.disks) {
                    $diskName = ($disk.source -split '/')[-1]
                    $primaryKey = if ($disk.source) { $disk.source.ToLower() } else { $null }
                    $d = $null
                    $fromMap = $false
                    if ($primaryKey -and $diskMap.ContainsKey($primaryKey)) { 
                        $d = $diskMap[$primaryKey];
                        $fromMap=$true 
                    }
                    else {
                        # Derive composite key from URL for lookup
                        $zrMatch = ''
                        if ($disk.source -match '/zones/([^/]+)/') { 
                            $zrMatch = $Matches[1] 
                        }
                        elseif ($disk.source -match '/regions/([^/]+)/') {
                            $zrMatch = $Matches[1] 
                        }
                        $altKey = ($zrMatch + '|' + $diskName).ToLower()
                        if ($diskMap.ContainsKey($altKey)) {
                            $d = $diskMap[$altKey]; $fromMap=$true 
                        }
                    }
                    # Choose metadata source (disk list object when available, otherwise instance attachment data)
                    $sizeGbVal = 0
                    $regionVal = ''
                    $zoneVal = ''
                    $isRegional = $false
                    $enc = 'No'
                    $cmk = $null          # CMEK is only knowable from the disk-list object, not the attachment
                    $typeVal = ''
                    $selfLinkVal = $null
                    # autoDelete lives on the ATTACHMENT, so it is always readable here even when the disk-list
                    # lookup missed. Polarity is inverted on purpose: the control asks whether the disk SURVIVES
                    # VM deletion, the API reports whether it is auto-DELETED.
                    $survives = if ($null -ne $disk.autoDelete) { -not [bool]$disk.autoDelete } else { $null }
                    if ($d) {
                        $sizeGbVal = [int64]$d.sizeGb
                        if ($d.region) 
                        { 
                            $regionVal = ($d.region -split '/')[-1];
                            $isRegional = $true 
                        } 
                        else { 
                            $zoneVal = ($d.zone -split '/')[-1]; 
                            $regionVal = Get-RegionFromZoneInner -zone $d.zone 
                        }
                        if ($d.diskEncryptionKey -or $d.encryptionKey) {
                            $enc='Yes' 
                        }
                        # CMEK specifically: kmsKeyName is what distinguishes a customer-MANAGED key from a
                        # customer-SUPPLIED one (rawKey/sha256). $enc above is true for both, so pd-cmek cannot
                        # read it. Already in the `compute disks list` payload.
                        $cmk = [bool]$d.diskEncryptionKey.kmsKeyName
                        $typeVal = ($d.type -replace '.*/','')
                        
                        if ($d.PSObject.Properties.Name -contains 'selfLink') {
                            $selfLinkVal = $d.selfLink 
                        }
                    } 
                    else {
                        # Use attachment data only
                        if ($disk.PSObject.Properties.Name -contains 'diskSizeGb' -and $disk.diskSizeGb) {
                            $sizeGbVal = [int64]$disk.diskSizeGb 
                        }
                        if ($disk.source -match '/zones/([^/]+)/') {
                            $zoneVal = $Matches[1]; $regionVal = Get-RegionFromZoneInner -zone $zoneVal 
                        }
                        elseif ($disk.source -match '/regions/([^/]+)/') {
                            $regionVal = $Matches[1]; $isRegional = $true 
                        }
                        if ($disk.PSObject.Properties.Name -contains 'type' -and $disk.type) {
                            $typeVal = ($disk.type -replace '.*/','') 
                        }
                        $selfLinkVal = $disk.source
                    }

                    # Accumulate disk size (regional disks counted once at region level)
                    $vmDiskGB += $sizeGbVal
                    $attachedObj = [PSCustomObject]@{
                        DiskName     = $diskName
                        VMName       = $vm.name
                        Project      = $proj
                        Region       = $regionVal
                        Zone         = if ($isRegional) { '' } else { $zoneVal }
                        IsRegional   = [bool]$isRegional
                        Encrypted    = $enc
                        DiskType     = $typeVal
                        SizeGB       = $sizeGbVal
                        DiskSelfLink = $selfLinkVal
                        DiskKey      = $primaryKey
                        Source       = if ($fromMap) { 'DiskList' } else { 'InstanceAttachment' }
                        CmkEncrypted     = $cmk
                        SurvivesVmDelete = $survives
                    }
                    $projectAttached += $attachedObj
                    # Ensure disk appears once in AllDisks (prefer enriched version if later disk list supplies it)
                    $diskKeyForAll = if ($selfLinkVal) { $selfLinkVal.ToLower() } elseif ($primaryKey) { $primaryKey } else { ($regionVal + '|' + $diskName).ToLower() }
                    if (-not $script:__AllDiskKeys.ContainsKey($diskKeyForAll)) {
                        $script:__AllDiskKeys[$diskKeyForAll] = $true
                        $projectAllDisks += [PSCustomObject]@{
                            DiskName     = $diskName
                            VMName       = $vm.name
                            Project      = $proj
                            Region       = $regionVal
                            Zone         = if ($isRegional) { '' } else { $zoneVal }
                            IsRegional   = [bool]$isRegional
                            Encrypted    = $enc
                            DiskType     = $typeVal
                            SizeGB       = $sizeGbVal
                            DiskSelfLink = $selfLinkVal
                            DiskKey      = $diskKeyForAll
                            CmkEncrypted     = $cmk
                            SurvivesVmDelete = $survives
                        }
                    }
                }
            }
            $diskCountLocal = if ($vm.disks) { $vm.disks.Count } else { 0 }
            $log.Add("[VM] Project=$proj $vmIndex/$($vmList.Count) Name=$($vm.name) Type=$(($vm.machineType -replace '.*/','')) Region=$region Zone=$zone Disks=$diskCountLocal DiskGB=$vmDiskGB") | Out-Null
            $projectVMs += [PSCustomObject]@{
                Project      = $proj
                VMName       = $vm.name
                VMSize       = ($vm.machineType -replace '.*/','')
                OS           = $osType
                Region       = $region
                Zone         = $zone
                VMId         = $vm.id
                SelfLink     = $vm.selfLink          # GCP's stable resource id (ARM id / ARN equivalent)
                DiskCount    = $diskCountLocal
                VMDiskSizeGB = [int64]$vmDiskGB
                # vm-delprot read this and nothing set it on a VM row, so the control could never produce a
                # verdict - while CYBER_RESILIENCE_SIGNALS.md documented it as collected. It was only invisible
                # because DeletionProtection IS set on Cloud SQL rows, which satisfied the cloud-wide check.
                # Already in the `compute instances list` payload: no extra call.
                DeletionProtection = [bool]$vm.deletionProtection
            }
        }

        foreach ($disk in $diskListAll) {
            if (-not $script:__AllDiskKeys) { $script:__AllDiskKeys = @{} }
            $isRegional = ($null -ne $disk.region)
            # `(if ...)` is a COMMAND invocation, not an expression: PowerShell looks for a cmdlet named 'if'.
            # Both of these were written that form, so every disk emitted "The term 'if' is not recognized" and
            # left the target empty. Consequences, in order of severity:
            #   1. $diskKeyForAll fell back to '' + '|' + name, dropping the region/zone component entirely, so
            #      two same-named disks in different zones collided on one key and the SECOND was silently
            #      skipped by the ContainsKey guard below - it never reached the inventory at all.
            #   2. DiskSelfLink was blank on every disk-list row, so New-CVSignalRow could not resolve a
            #      ResourceId (it probes ResourceId/Id/Arn/SelfLink/DiskSelfLink) and the signals CSV carried
            #      unidentifiable disks.
            # The attached-disk path a few lines up already used the correct assignment form, which is why only
            # unattached / disk-list rows were affected.
            $diskSelf  = if ($disk.PSObject.Properties.Name -contains 'selfLink') { $disk.selfLink } else { $null }
            # Hoisted rather than nested: the inner (if ...) had the same defect, and a subexpression inside a
            # string concatenation is exactly where it is least visible.
            $diskScope = if ($disk.region) { ($disk.region -split '/')[-1] }
                         elseif ($disk.zone) { ($disk.zone -split '/')[-1] }
                         else { '' }
            $diskKeyForAll = if ($diskSelf) { $diskSelf.ToLower() } else { ($diskScope + '|' + $disk.name).ToLower() }
            # Skip if already added during VM attachment processing
            if ($script:__AllDiskKeys.ContainsKey($diskKeyForAll)) { continue }
            $script:__AllDiskKeys[$diskKeyForAll] = $true
            $diskObj = [PSCustomObject]@{
                DiskName     = $disk.name
                VMName       = if ($disk.users -and $disk.users.Count -gt 0) { ($disk.users | ForEach-Object { ($_ -split '/')[-1] }) -join ',' } else { $null }
                Project      = $proj
                Region       = if ($disk.region) { ($disk.region -split '/')[-1] } else { (Get-RegionFromZoneInner -zone $disk.zone) }
                Zone         = if ($disk.region) { '' } else { ($disk.zone -split '/')[-1] }
                IsRegional   = [bool]$isRegional
                Encrypted    = if ($disk.diskEncryptionKey -or $disk.encryptionKey) { 'Yes' } else { 'No' }
                DiskType     = ($disk.type -replace '.*/','')
                SizeGB       = [int64]$disk.sizeGb
                DiskSelfLink = $diskSelf
                DiskKey      = $diskKeyForAll
                CmkEncrypted = [bool]$disk.diskEncryptionKey.kmsKeyName
                # autoDelete is a property of an ATTACHMENT, so an unattached disk has none to read. But the
                # branch below establishes by measurement that no VM is using this disk ($disk.users is empty),
                # and a disk with no attachment cannot be auto-deleted with one. That is a real $true, not an
                # assumption. NEVER the string 'NA' here: the control routes through Get-CVTri, which is
                # [bool]$Value, and [bool]'NA' is $true - so 'NA' would silently read as Met.
                SurvivesVmDelete = if (-not $disk.users -or $disk.users.Count -eq 0) { $true } else { $null }
            }
            $projectAllDisks += $diskObj
            if (-not $disk.users -or $disk.users.Count -eq 0) { $projectUnattached += $diskObj }
        }

        $log.Add("[VM-Project-Debug] $proj RawDisksListed=$($diskListAll.Count) AllDisksCaptured=$($projectAllDisks.Count) VMs=$($vmList.Count)") | Out-Null

    # Reconstruction block removed: we now always capture attachment disks during VM iteration.

        $log.Add("[VM-Project-End] $proj VMs=$($projectVMs.Count) Disks=$($projectAllDisks.Count)") | Out-Null
        $durationSec = [math]::Round(([DateTime]::UtcNow - $startUtc).TotalSeconds,2)
        return [PSCustomObject]@{
            Project         = $proj
            VMs             = $projectVMs
            AttachedDisks   = $projectAttached
            AllDisks        = $projectAllDisks
            UnattachedDisks = $projectUnattached
            Logs            = $log
            DurationSec     = $durationSec
            ApiDisabled     = $apiDisabled
            PermissionIssue = $permIssue
        }
    }
    # End - VM Project ScriptBlock

    $effectiveMax = [Math]::Min($MaxThreads, [Math]::Max(1,$ProjectIds.Count))
    $vmStatuses = New-Object System.Collections.Generic.List[psobject]
    if (-not $LightMode) {
        # Existing runspace-pool implementation (default)
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $pool = [RunspaceFactory]::CreateRunspacePool(1,$effectiveMax,$iss,$Host); $pool.Open()
        $runspaces=@()
        foreach ($p in $ProjectIds) {
            $ps = [PowerShell]::Create().AddScript($vmProjectScriptBlock).AddArgument($p).AddArgument($MinimalOutput); $ps.RunspacePool=$pool
            $handle = $ps.BeginInvoke(); $runspaces += [PSCustomObject]@{ PS=$ps; Handle=$handle; Project=$p; Submitted=[DateTime]::UtcNow }
        }
        $allVMs=@(); $allAttached=@(); $allAllDisks=@(); $allUnattached=@(); $completed=0; $total=$ProjectIds.Count
        $durations = New-Object System.Collections.Generic.List[double]; $overallStart=[DateTime]::UtcNow
        Start-CVProgress -Id 'vm-projects' -Activity 'VM Projects'
        while ($runspaces.Count -gt 0) {
            $still=@()
            foreach ($rs in $runspaces) {
                if ($rs.Handle.IsCompleted) {
                    # Unwrap the PSDataCollection first: reading .VMs off it uses member enumeration, which returns
                    # $null for an empty array and makes the accumulate below append a phantom null row.
                    try { $result = Get-CVRunspaceResult $rs.PS.EndInvoke($rs.Handle) } catch { Write-CVLog "VM inventory failed for project" -Level Error -Source 'VM' -Scope @{ Project = $rs.Project } -Exception $_; $result=$null }
                    $completed++
                    if ($result) {
                        $allVMs += ConvertTo-CVItemArray $result.VMs; $allAttached += ConvertTo-CVItemArray $result.AttachedDisks; $allAllDisks += ConvertTo-CVItemArray $result.AllDisks; $allUnattached += ConvertTo-CVItemArray $result.UnattachedDisks
                        $durations.Add($result.DurationSec/60) | Out-Null
                        foreach ($l in $result.Logs) { Write-CVLog $l -Level (Get-CVWorkerLineLevel $l) -Source 'GCP' -Scope @{ Project = $result.Project } }
                        Write-Host ("[Project-Done] {0} VMs={1} Disks={2} ElapsedSec={3}" -f $result.Project,$result.VMs.Count,$result.AllDisks.Count,$result.DurationSec) -ForegroundColor Green
                        Write-Host '--------------------------------------------------' -ForegroundColor DarkGray
                        $statusObj = [PSCustomObject]@{
                            Project=$result.Project
                            Success= -not ($result.ApiDisabled -or $result.PermissionIssue)
                            VMCount=$result.VMs.Count
                            DiskCount=$result.AllDisks.Count
                            ApiDisabled=$result.ApiDisabled
                            PermissionIssue=$result.PermissionIssue
                            Timeout=$false
                        }
                        $vmStatuses.Add($statusObj) | Out-Null
                    }
                } else {
                    $elapsedSec = ([DateTime]::UtcNow - $rs.Submitted).TotalSeconds
                    if ($elapsedSec -ge $TaskTimeoutSec) {
                        try { $rs.PS.Stop() } catch {}
                        try { $rs.PS.Dispose() } catch {}
                        $completed++
                        Write-CVLog "VM inventory timed out for project after $TaskTimeoutSec s" -Level Warning -Source 'VM' -Scope @{ Project = $rs.Project }
                        $vmStatuses.Add([PSCustomObject]@{ Project=$rs.Project; Success=$false; VMCount=0; DiskCount=0; ApiDisabled=$false; PermissionIssue=$false; Timeout=$true }) | Out-Null
                    } else { $still += $rs }
                }
            }
            $runspaces = $still
            $pct = if ($total -gt 0) { [math]::Round(($completed / $total)*100,1) } else { 100 }
            $elapsedMin = [math]::Round(([DateTime]::UtcNow - $overallStart).TotalMinutes,3)
            $avgMin = if ($durations.Count -gt 0) { [math]::Round(($durations | Measure-Object -Average | Select -Expand Average),3) } else { 0 }
            $remaining = $total - $completed; $etaMin = if ($avgMin -gt 0 -and $remaining -gt 0) { [math]::Round($avgMin * $remaining,2) } else { 0 }
            $rate = if ($elapsedMin -gt 0) { [math]::Round($allVMs.Count / ($elapsedMin*60),2) } else { 0 }
            $status = "Projects {0}/{1} ({2}%) | Discovered VMs={3} | Rate={4}/s | ElapsedMin={5} | ETA_Min={6}" -f $completed,$total,$pct,$allVMs.Count,$rate,$elapsedMin,$etaMin
            Update-CVProgress -Id 'vm-projects' -Activity 'VM Projects' -Status $status -PercentComplete $pct
            if ($runspaces.Count -gt 0) { Start-Sleep -Milliseconds 200 }
        }
        Complete-CVProgress -Id 'vm-projects'
        $pool.Close(); $pool.Dispose()
        $script:VmProjectStatuses = $vmStatuses
        return @{ VMs=$allVMs; AttachedDisks=$allAttached; AllDisks=$allAllDisks; UnattachedDisks=$allUnattached; Statuses=$vmStatuses }
    } else {
        # Lightweight on-demand runspace approach (creates only active runspaces; disposes immediately)
        $queue = New-Object System.Collections.Queue
        foreach ($p in $ProjectIds) { $queue.Enqueue($p) }
        $active=@()
        $allVMs=@(); $allAttached=@(); $allAllDisks=@(); $allUnattached=@(); $completed=0; $total=$ProjectIds.Count
        $durations = New-Object System.Collections.Generic.List[double]; $overallStart=[DateTime]::UtcNow
        Start-CVProgress -Id 'vm-projects' -Activity 'VM Projects'
        while ($active.Count -gt 0 -or $queue.Count -gt 0) {
            while ($active.Count -lt $effectiveMax -and $queue.Count -gt 0) {
                $proj = $queue.Dequeue()
                $ps = [PowerShell]::Create().AddScript($vmProjectScriptBlock).AddArgument($proj).AddArgument($MinimalOutput)
                $handle = $ps.BeginInvoke()
                $active += [PSCustomObject]@{ PS=$ps; Handle=$handle; Project=$proj; Started=[DateTime]::UtcNow }
            }
            $remaining=@()
            foreach ($a in $active) {
                if ($a.Handle.IsCompleted) {
                    try { $result = Get-CVRunspaceResult $a.PS.EndInvoke($a.Handle) } catch { Write-CVLog "VM inventory failed for project" -Level Error -Source 'VM' -Scope @{ Project = $a.Project } -Exception $_; $result=$null }
                    $a.PS.Dispose()
                    $completed++
                    if ($result) {
                        $allVMs += ConvertTo-CVItemArray $result.VMs; $allAttached += ConvertTo-CVItemArray $result.AttachedDisks; $allAllDisks += ConvertTo-CVItemArray $result.AllDisks; $allUnattached += ConvertTo-CVItemArray $result.UnattachedDisks
                        $durations.Add($result.DurationSec/60) | Out-Null
                        foreach ($l in $result.Logs) { Write-CVLog $l -Level (Get-CVWorkerLineLevel $l) -Source 'GCP' -Scope @{ Project = $result.Project } }
                        Write-Host ("[Project-Done] {0} VMs={1} Disks={2} ElapsedSec={3}" -f $result.Project,$result.VMs.Count,$result.AllDisks.Count,$result.DurationSec) -ForegroundColor Green
                        Write-Host '--------------------------------------------------' -ForegroundColor DarkGray
                        $vmStatuses.Add([PSCustomObject]@{ Project=$result.Project; Success= -not ($result.ApiDisabled -or $result.PermissionIssue); VMCount=$result.VMs.Count; DiskCount=$result.AllDisks.Count; ApiDisabled=$result.ApiDisabled; PermissionIssue=$result.PermissionIssue; Timeout=$false }) | Out-Null
                    }
                } else {
                    $elapsedSec = ([DateTime]::UtcNow - $a.Started).TotalSeconds
                    if ($elapsedSec -ge $TaskTimeoutSec) {
                        try { $a.PS.Stop() } catch {}
                        try { $a.PS.Dispose() } catch {}
                        $completed++
                        Write-CVLog "VM inventory timed out for project after $TaskTimeoutSec s" -Level Warning -Source 'VM' -Scope @{ Project = $a.Project }
                        $vmStatuses.Add([PSCustomObject]@{ Project=$a.Project; Success=$false; VMCount=0; DiskCount=0; ApiDisabled=$false; PermissionIssue=$false; Timeout=$true }) | Out-Null
                    } else { $remaining += $a }
                }
            }
            $active=$remaining
            $pct = if ($total -gt 0) { [math]::Round(($completed / $total)*100,1) } else { 100 }
            $elapsedMin = [math]::Round(([DateTime]::UtcNow - $overallStart).TotalMinutes,3)
            $avgMin = if ($durations.Count -gt 0) { [math]::Round(($durations | Measure-Object -Average | Select -Expand Average),3) } else { 0 }
            $remainingCount = $total - $completed; $etaMin = if ($avgMin -gt 0 -and $remainingCount -gt 0) { [math]::Round($avgMin * $remainingCount,2) } else { 0 }
            $rate = if ($elapsedMin -gt 0) { [math]::Round($allVMs.Count / ($elapsedMin*60),2) } else { 0 }
            $status = "(Light) Projects {0}/{1} ({2}%) | Discovered VMs={3} | Rate={4}/s | ElapsedMin={5} | ETA_Min={6}" -f $completed,$total,$pct,$allVMs.Count,$rate,$elapsedMin,$etaMin
            Update-CVProgress -Id 'vm-projects' -Activity 'VM Projects' -Status $status -PercentComplete $pct
            if ($active.Count -gt 0 -or $queue.Count -gt 0) { Start-Sleep -Milliseconds 150 }
        }
        Complete-CVProgress -Id 'vm-projects'
        $script:VmProjectStatuses = $vmStatuses
        return @{ VMs=$allVMs; AttachedDisks=$allAttached; AllDisks=$allAllDisks; UnattachedDisks=$allUnattached; Statuses=$vmStatuses }
    }
}

# -------------------------
# Storage Inventory (fast, gcloud-only)
# -------------------------
function Get-GcpStorageInventory {
    param([string[]]$ProjectIds)

    # Phase 1: Concurrent bucket listing per project
    $listingScript = {
        param($project,$minimalFlag)
        $perm=$false; $buckets=@(); $err=$null
        try {
            # Added --quiet to ensure non-interactive bucket listing
            $raw = & gcloud --quiet storage buckets list --project $project --format=json 2>&1
            if ($LASTEXITCODE -ne 0) {
                $txt = ($raw | Out-String)
                if ($txt -match '(?i)permission|denied|forbidden|403') { $perm=$true }
            } else {
                if (-not [string]::IsNullOrWhiteSpace(($raw|Out-String))) { try { $buckets = $raw | ConvertFrom-Json } catch { $err=$_.Exception.Message; $buckets=@() } }
            }
        } catch { $err=$_.Exception.Message }
        $count = if ($perm) { -1 } else { if ($buckets) { $buckets.Count } else { 0 } }
        return [PSCustomObject]@{ Project=$project; Buckets=$buckets; BucketCount=$count; PermissionIssue=$perm; Error=$err }
    }

    $maxProjThreads = [Math]::Min(20,[Math]::Max(1,$ProjectIds.Count))
    Write-Log -Level INFO -Message ("[Buckets-Phase1] Listing {0} projects with maxThreads={1}" -f $ProjectIds.Count,$maxProjThreads)
    $iss1 = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $pool1 = [RunspaceFactory]::CreateRunspacePool(1,$maxProjThreads,$iss1,$Host); $pool1.Open()
    $rsList=@()
    foreach ($p in $ProjectIds) {
        $ps=[PowerShell]::Create().AddScript($listingScript).AddArgument($p).AddArgument($MinimalOutput); $ps.RunspacePool=$pool1
        $rsList += [PSCustomObject]@{ PS=$ps; Handle=$ps.BeginInvoke(); Project=$p }
    }
    $projResults=@(); $completed=0; $total=$rsList.Count; $listStart=[DateTime]::UtcNow
    Start-CVProgress -Id 'bucket-listing' -Activity 'Bucket Listing'
    while ($rsList.Count -gt 0) {
        $next=@()
        foreach ($r in $rsList) {
            if ($r.Handle.IsCompleted) {
                try { $res=$r.PS.EndInvoke($r.Handle) } catch { $res=$null; Write-CVLog "Bucket listing failed for project" -Level Error -Source 'Storage' -Scope @{ Project = $r.Project } -Exception $_ }
                if ($res) { $projResults += ConvertTo-CVItemArray $res }
                $completed++
            } else { $next += $r }
        }
        $rsList=$next
        $pct = if ($total -gt 0) { [math]::Round(($completed/$total)*100,1) } else { 100 }
        $elapsed = [math]::Round(([DateTime]::UtcNow - $listStart).TotalSeconds,1)
        Update-CVProgress -Id 'bucket-listing' -Activity 'Bucket Listing' -Status ("Projects {0}/{1} ({2}%) ElapsedSec={3}" -f $completed,$total,$pct,$elapsed) -PercentComplete $pct
        if ($rsList.Count -gt 0) { Start-Sleep -Milliseconds 150 }
    }
    Complete-CVProgress -Id 'bucket-listing'
    $pool1.Close(); $pool1.Dispose()

    # Build project status list
    $projectStatuses=@()
    foreach ($pr in $projResults) {
        $display = if ($pr.PermissionIssue) { "$($pr.Project)*" } else { $pr.Project }
        $bucketCountCsv = if ($pr.BucketCount -lt 0) { '' } else { $pr.BucketCount }
        $projectStatuses += [PSCustomObject]@{
            Project=$display
            BucketCount=$bucketCountCsv
            PermissionIssue= if ($pr.PermissionIssue){'Y'} else {''}
            Success= if ($pr.PermissionIssue -or $pr.Error) { 'N' } else { 'Y' }
            Error = if ($pr.Error){ $pr.Error } else { '' }
            # Set by Phase 2. NotQueried = no buckets to size (or listing failed).
            SizeStatus = 'NotQueried'
            SizeError  = ''
        }
    }

    # Consolidate all bucket descriptors
    $allBucketDescriptors = @()
    foreach ($pr in $projResults) {
        if ($pr.Buckets) {
            foreach ($b in $pr.Buckets) {
                $allBucketDescriptors += [PSCustomObject]@{ Project=$pr.Project; Name=$b.name; Location=$b.location; StorageClass=$b.storageClass; Raw=$b }
            }
        }
    }
    Write-Log -Level INFO -Message ("[Buckets-Phase1] Total discoverable buckets={0}" -f $allBucketDescriptors.Count)
    if ($allBucketDescriptors.Count -eq 0) {
        $script:StorageProjectStatuses = $projectStatuses
        return @()
    }

    # Phase 2: size every bucket from Cloud Monitoring - ONE query per project, regardless of object count.
    # This replaced `gsutil du -s` per bucket, which lists every object 1,000 at a time; a single bucket with
    # 100M objects held a sizing slot for many hours, and the declared -BucketSizingTimeoutSec was never enforced.
    # Trade-off: storage/v2/total_bytes is measured once a day, so sizes can be up to a day old.
    $byProject = $allBucketDescriptors | Group-Object Project
    Write-Log -Level INFO -Message ("[Buckets-Phase2] Sizing {0} buckets in {1} projects from Cloud Monitoring" -f $allBucketDescriptors.Count,$byProject.Count)
    $sized = [System.Collections.Generic.List[psobject]]::new(); $done=0; $totalProj=$byProject.Count; $sizeStart=[DateTime]::UtcNow
    $sizeStatusByProject = @{}
    Start-CVProgress -Id 'bucket-sizing' -Activity 'Bucket Sizing'
    foreach ($grp in $byProject) {
        $now = [DateTime]::UtcNow
        $sizeMap = Get-CVGcsBucketSizeMap -ProjectId $grp.Name -AccessToken (Get-CVGcpAccessToken) -NowUtc $now
        $sizeStatusByProject[$grp.Name] = $sizeMap
        if ($sizeMap.Status -ne 'Ok') {
            Write-CVLog "Cloud Monitoring bucket size query failed; sizes left blank: $($sizeMap.Error)" -Level Warning -Source 'Storage' -Scope @{ Project = $grp.Name }
            $script:CVGcpMonitoringFailures.Add([pscustomobject]@{ Service = 'Storage'; Project = $grp.Name; Error = $sizeMap.Error })
        }
        foreach ($bd in $grp.Group) {
            $raw = $bd.Raw
            # gcloud storage's standardized JSON is snake_case; the API's raw shape is camelCase. Accept either.
            $created = if ($raw.PSObject.Properties['creation_time']) { $raw.creation_time } elseif ($raw.PSObject.Properties['timeCreated']) { $raw.timeCreated } else { $null }
            $r = Resolve-CVGcsBucketSize -BucketName $bd.Name -SizeMap $sizeMap -CreatedUtc $created -NowUtc $now
            # $null means not measured (see Resolve-CVGcsBucketSize). It must not be cast to [int64], which would
            # make it 0; every size cell stays $null so the CSV shows blank and the rollup's Measure-CVSum skips it.
            $bytes = $r.Bytes
            $known = ($null -ne $bytes)
            # Named, not `return [PSCustomObject]@{...}`: Get-CVBuilderFields in the wiring test extracts signal
            # fields from ASSIGNMENTS to a named builder variable.
            $bucketObj = [PSCustomObject]@{
                StorageBucket       = $bd.Name
                Project             = $bd.Project
                Location            = $bd.Location
                StorageClass        = $(if ($bd.StorageClass) { $bd.StorageClass } elseif ($raw.PSObject.Properties['default_storage_class']) { $raw.default_storage_class } else { $null })
                UsedCapacityBytes   = $bytes
                UsedCapacityMiB     = $(if ($known) { [math]::Round($bytes / 1MB, 3) })
                UsedCapacityGiB     = $(if ($known) { [math]::Round($bytes / 1GB, 4) })
                UsedCapacityTiB     = $(if ($known) { [math]::Round($bytes / 1TB, 6) })
                UsedCapacityMBDec   = $(if ($known) { [math]::Round($bytes / 1e6, 3) })
                UsedCapacityGB      = $(if ($known) { [math]::Round($bytes / 1e9, 4) })
                UsedCapacityTB      = $(if ($known) { [math]::Round($bytes / 1e12, 6) })
                NoncurrentVersionBytes = $r.NoncurrentBytes
                SizeSource          = 'CloudMonitoring:storage/v2/total_bytes'
                SizeStatus          = $r.Status
                SizeNote            = $r.Note
            }
            $sized.Add($bucketObj)
            if (-not $MinimalOutput) { Write-Host ("Bucket={0} Project={1} Location={2} SizeGB={3} ({4})" -f $bucketObj.StorageBucket,$bucketObj.Project,$bucketObj.Location,$(if ($known) { $bucketObj.UsedCapacityGB } else { 'UNKNOWN' }),$r.Status) -ForegroundColor Cyan }
        }
        $done++
        $pct = if ($totalProj -gt 0) { [math]::Round(($done/$totalProj)*100,1) } else { 100 }
        $elapsed = [math]::Round(([DateTime]::UtcNow - $sizeStart).TotalSeconds,1)
        Update-CVProgress -Id 'bucket-sizing' -Activity 'Bucket Sizing' -Status ("Projects {0}/{1} ({2}%) Buckets={3} ElapsedSec={4}" -f $done,$totalProj,$pct,$sized.Count,$elapsed) -PercentComplete $pct
    }
    Complete-CVProgress -Id 'bucket-sizing'

    # Surface the Monitoring outcome in gcp_project_status_storage_*.csv. Status there only reflects LISTING, so a
    # project whose sizes could not be read used to show Success with TotalSizeGB 0.
    foreach ($st in $projectStatuses) {
        $m = $sizeStatusByProject[("$($st.Project)").TrimEnd('*')]
        if ($m) { $st.SizeStatus = $m.Status; $st.SizeError = $(if ($m.Error) { $m.Error } else { '' }) }
    }

    $script:StorageProjectStatuses = $projectStatuses
    return @($sized)
}

# -------------------------
# Filestore (File Share) Inventory
# -------------------------
function Get-GcpFileShareInventory {
    param(
        [string[]]$ProjectIds,
        [switch]$LightMode,
        [int]$MaxThreads = 10,
        [int]$TaskTimeoutSec = 600
    )
    # Defensive: ensure MaxThreads is at least 1 (guard against caller passing null/0)
    if (-not $MaxThreads -or $MaxThreads -lt 1) { $MaxThreads = 1 }
    # Collect all filestore log lines for possible global reconstruction later
    $allLogs = New-Object System.Collections.Generic.List[string]
    # Script per project: list filestore instances
    $fsProjectScript = {
        param($proj,$minimalFlag)
        $log = New-Object System.Collections.Generic.List[string]
        $startUtc=[DateTime]::UtcNow
        $log.Add("[FS-Project-Start] $proj")|Out-Null
        $env:CLOUDSDK_CORE_DISABLE_PROMPTS='1'
        $instances=@()
        try {
            $raw = & gcloud --quiet filestore instances list --project $proj --format=json 2>&1
            if ($LASTEXITCODE -ne 0) {
                $msg=($raw|Out-String).Trim()
                if ($msg -match '(?i)permission|denied|forbidden|403|not enabled|is disabled') {
                    $log.Add("[FS-Project-Skip] $proj Filestore access issue: $msg")|Out-Null
                    $errShare = [PSCustomObject]@{
                        Project=$proj; InstanceName=''; ShareName='(error)'; Tier=''; Region=''; Zone=''; provisionedGb=0; provisionedGib=0; provisionedTb=0; provisionedTib=0; CapacityGB=0; Networks=''; IPAddresses=''; State='ERROR'; CreateTime=''; Labels=''; Protocol=''; Error=$msg
                    }
                    return [PSCustomObject]@{ Project=$proj; Shares=@($errShare); Logs=$log; DurationSec=[math]::Round(([DateTime]::UtcNow - $startUtc).TotalSeconds,2) }
                }
                $log.Add("[FS-Project-Warn] $proj list failed exit=$LASTEXITCODE msg=$msg")|Out-Null
            } else {
                if (-not [string]::IsNullOrWhiteSpace(($raw|Out-String))) { try { $instances = $raw | ConvertFrom-Json } catch { $log.Add("[FS-Project-Error] $proj JSON parse failed: $($_.Exception.Message)")|Out-Null } }
            }
        } catch { $log.Add("[FS-Project-Error] $proj command threw: $($_.Exception.Message)")|Out-Null }
        if (-not $instances) { $instances=@() }
        $shares=@(); $idx=0
        foreach ($inst in $instances) {
            $idx++
            $fullName=$inst.name
            # Extract location (region or zone) from full resource name
            $locationRaw=''
            if ($fullName -match '/locations/([^/]+)/instances/') { $locationRaw=$Matches[1] }
            $region=''; $zone=''
            if ($locationRaw -match '^[a-z0-9-]+-[a-z]$') { $zone=$locationRaw; $region=($locationRaw -replace '-[a-z]$','') } else { $region=$locationRaw }
            $tier=$inst.tier
            $instanceShort = if ($fullName) { ($fullName -split '/')[-1] } else { '' }
            $state = $inst.state
            $createTime = $inst.createTime
            $labels=''
            try { if ($inst.labels) { $labels = ($inst.labels.GetEnumerator() | ForEach-Object { "{0}={1}" -f $_.Key,$_.Value }) -join ';' } } catch {}
            $networksNames = @(); $ipsList=@()
            if ($inst.networks) {
                foreach ($n in $inst.networks) { if ($n.network){ $networksNames += ($n.network -replace '.*/','') }; if ($n.ipAddresses){ $ipsList += $n.ipAddresses } }
            }
            $net = ($networksNames | Sort-Object -Unique) -join ';'
            $ip = ($ipsList | Sort-Object -Unique) -join ';'
            $protocol='NFS'
            if ($inst.fileShares -and $inst.fileShares.Count -gt 0) {
                foreach ($share in $inst.fileShares) {
                    $shareName = $share.name
                    $capGiB = 0; try { if ($share.capacityGb) { $capGiB=[int64]$share.capacityGb } } catch {}
                    # capacityGb from API is GiB; derive decimal GB/TB and binary TiB
                    $provGib = [double]$capGiB
                    $provGb  = [math]::Round(($provGib * 1024 * 1024 * 1024)/1e9,3)
                    $provTib = [math]::Round($provGib/1024,4)
                    $provTb  = [math]::Round($provGb/1000,4)
                    $log.Add("[FS] Project=$proj $idx/$($instances.Count) Instance=$instanceShort Share=$shareName Tier=$tier Region=$region Zone=$zone provisionedGib=$provGib provisionedGb=$provGb")|Out-Null
                    $shares += [PSCustomObject]@{
                        Project=$proj
                        InstanceName=$instanceShort
                        ShareName=$shareName
                        Tier=$tier
                        Region=$region
                        Zone=$zone
                        provisionedGb=$provGb
                        provisionedGib=$provGib
                        provisionedTb=$provTb
                        provisionedTib=$provTib
                        CapacityGB=$capGiB   # legacy field retained
                        Networks=$net
                        IPAddresses=$ip
                        State=$state
                        CreateTime=$createTime
                        Labels=$labels
                        Protocol=$protocol
                        Error=''
                    }
                }
            } else {
                # No shares array; still emit instance row
                $log.Add("[FS] Project=$proj $idx/$($instances.Count) Instance=$instanceShort Tier=$tier Region=$region Zone=$zone provisionedGib=0 provisionedGb=0 (NoShares)")|Out-Null
                $shares += [PSCustomObject]@{
                    Project=$proj
                    InstanceName=$instanceShort
                    ShareName=''
                    Tier=$tier
                    Region=$region
                    Zone=$zone
                    provisionedGb=0
                    provisionedGib=0
                    provisionedTb=0
                    provisionedTib=0
                    CapacityGB=0
                    Networks=$net
                    IPAddresses=$ip
                    State=$state
                    CreateTime=$createTime
                    Labels=$labels
                    Protocol=$protocol
                    Error=''
                }
            }
        }
        $log.Add("[FS-Project-End] $proj ShareRows=$($shares.Count)")|Out-Null
    # Ensure Shares is always an array (even single object)
    $shares = @($shares)
    return [PSCustomObject]@{ Project=$proj; Shares=$shares; Logs=$log; DurationSec=[math]::Round(([DateTime]::UtcNow - $startUtc).TotalSeconds,2) }
    }

    $effectiveMax=[Math]::Min($MaxThreads,[Math]::Max(1,$ProjectIds.Count))
    if (-not $LightMode) {
        $iss=[System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $pool=[RunspaceFactory]::CreateRunspacePool(1,$effectiveMax,$iss,$Host); $pool.Open()
        $runspaces=@(); foreach ($p in $ProjectIds){ $ps=[PowerShell]::Create().AddScript($fsProjectScript).AddArgument($p).AddArgument($MinimalOutput); $ps.RunspacePool=$pool; $runspaces+= [PSCustomObject]@{ PS=$ps; Handle=$ps.BeginInvoke(); Project=$p; Submitted=[DateTime]::UtcNow } }
        $all=@(); $completed=0; $total=$ProjectIds.Count; $overall=[DateTime]::UtcNow
        Start-CVProgress -Id 'fileshare-projects' -Activity 'FileShare Projects'
        while ($runspaces.Count -gt 0) {
            $next=@()
            foreach ($rs in $runspaces) {
                if ($rs.Handle.IsCompleted) {
                    try { $res=Get-CVRunspaceResult $rs.PS.EndInvoke($rs.Handle) } catch { $res=$null; Write-CVLog "Fileshare inventory failed for project" -Level Error -Source 'Fileshare' -Scope @{ Project = $rs.Project } -Exception $_ }
                    $completed++
                    if ($res) {
                        # Force array semantics to avoid single-object collapsing (which breaks .Count checks)
                        $projShares = @($res.Shares)
                        if (-not $projShares -or (@($projShares)).Count -eq 0) {
                            # Fallback: reconstruct from log lines if any successful [FS] entries
                            $recovered=@()
                            foreach ($line in $res.Logs) {
                                if ($line -match '^\[FS\] Project=([^ ]+) .* Instance=([^ ]+) Share=([^ ]+) Tier=([^ ]+) Region=([^ ]+) Zone=([^ ]+) (?:CapacityGB|provisionedGib)=([0-9]+)') {
                                    $gib=[int64]$Matches[7]
                                    $gb=[math]::Round(($gib * 1024 * 1024 * 1024)/1e9,3)
                                    $tib=[math]::Round($gib/1024,4)
                                    $tb=[math]::Round($gb/1000,4)
                                    $recovered += [PSCustomObject]@{
                                        Project=$Matches[1]; InstanceName=$Matches[2]; ShareName=$Matches[3]; Tier=$Matches[4]; Region=$Matches[5]; Zone=$Matches[6]; provisionedGb=$gb; provisionedGib=$gib; provisionedTb=$tb; provisionedTib=$tib; CapacityGB=$gib; Networks=''; IPAddresses=''; State='READY'; CreateTime=''; Labels=''; Protocol='NFS'; Error=''
                                    }
                                }
                            }
                            if ($recovered.Count -gt 0) { Write-Host ("[FS-Recover] Project={0} ReconstructedShares={1}" -f $rs.Project,$recovered.Count) -ForegroundColor Yellow; $projShares=$recovered }
                        }
                        if ($projShares) { $all += $projShares }
                        foreach ($l in $res.Logs){ Write-CVLog $l -Level (Get-CVWorkerLineLevel $l) -Source 'GCP' -Scope @{ Project = $res.Project }; $allLogs.Add($l) | Out-Null }
                        $shareCt = if ($projShares) { (@($projShares)).Count } else { 0 }
                        Write-Host ("[FS-Project-Done] {0} Shares={1} ElapsedSec={2}" -f $res.Project,$shareCt,$res.DurationSec) -ForegroundColor Green
                    }
                } else {
                    $elapsed = ([DateTime]::UtcNow - $rs.Submitted).TotalSeconds
                    if ($elapsed -ge $TaskTimeoutSec) { try { $rs.PS.Stop() } catch {}; try { $rs.PS.Dispose() } catch {}; $completed++; Write-CVLog "Fileshare inventory timed out for project after $TaskTimeoutSec s" -Level Warning -Source 'Fileshare' -Scope @{ Project = $rs.Project } } else { $next += $rs }
                }
            }
            $runspaces=$next
            $pct = if ($total -gt 0){ [math]::Round(($completed/$total)*100,1)} else {100}
            Update-CVProgress -Id 'fileshare-projects' -Activity 'FileShare Projects' -Status ("Projects {0}/{1} ({2}%)" -f $completed,$total,$pct) -PercentComplete $pct
            if ($runspaces.Count -gt 0) { Start-Sleep -Milliseconds 200 }
        }
        Complete-CVProgress -Id 'fileshare-projects'
        $pool.Close(); $pool.Dispose()
    $script:FileShareLogLines = $allLogs
        return $all
    } else {
        $queue=New-Object System.Collections.Queue; foreach ($p in $ProjectIds){ $queue.Enqueue($p) }
        $active=@(); $all=@(); $completed=0; $total=$ProjectIds.Count
        Start-CVProgress -Id 'fileshare-projects' -Activity 'FileShare Projects'
        while ($active.Count -gt 0 -or $queue.Count -gt 0) {
            while ($active.Count -lt $effectiveMax -and $queue.Count -gt 0) {
                $proj=$queue.Dequeue(); $ps=[PowerShell]::Create().AddScript($fsProjectScript).AddArgument($proj).AddArgument($MinimalOutput); $handle=$ps.BeginInvoke(); $active += [PSCustomObject]@{ PS=$ps; Handle=$handle; Project=$proj; Started=[DateTime]::UtcNow }
            }
            $remain=@()
            foreach ($a in $active) {
                if ($a.Handle.IsCompleted) {
                    try { $res=Get-CVRunspaceResult $a.PS.EndInvoke($a.Handle) } catch { $res=$null; Write-CVLog "Fileshare inventory failed for project" -Level Error -Source 'Fileshare' -Scope @{ Project = $a.Project } -Exception $_ }
                    $a.PS.Dispose(); $completed++
                    if ($res) {
                        $projShares = @($res.Shares)
                        if (-not $projShares -or (@($projShares)).Count -eq 0) {
                            $recovered=@()
                            foreach ($line in $res.Logs) {
                                if ($line -match '^\[FS\] Project=([^ ]+) .* Instance=([^ ]+) Share=([^ ]+) Tier=([^ ]+) Region=([^ ]+) Zone=([^ ]+) (?:CapacityGB|provisionedGib)=([0-9]+)') {
                                    $gib=[int64]$Matches[7]
                                    $gb=[math]::Round(($gib * 1024 * 1024 * 1024)/1e9,3)
                                    $tib=[math]::Round($gib/1024,4)
                                    $tb=[math]::Round($gb/1000,4)
                                    $recovered += [PSCustomObject]@{
                                        Project=$Matches[1]; InstanceName=$Matches[2]; ShareName=$Matches[3]; Tier=$Matches[4]; Region=$Matches[5]; Zone=$Matches[6]; provisionedGb=$gb; provisionedGib=$gib; provisionedTb=$tb; provisionedTib=$tib; CapacityGB=$gib; Networks=''; IPAddresses=''; State='READY'; CreateTime=''; Labels=''; Protocol='NFS'; Error=''
                                    }
                                }
                            }
                            if ($recovered.Count -gt 0) { Write-Host ("[FS-Recover] Project={0} ReconstructedShares={1}" -f $a.Project,$recovered.Count) -ForegroundColor Yellow; $projShares=$recovered }
                        }
                        if ($projShares) { $all += $projShares }
                        foreach ($l in $res.Logs){ Write-CVLog $l -Level (Get-CVWorkerLineLevel $l) -Source 'GCP' -Scope @{ Project = $res.Project }; $allLogs.Add($l) | Out-Null }
                        $shareCt = if ($projShares) { (@($projShares)).Count } else { 0 }
                        Write-Host ("[FS-Project-Done] {0} Shares={1} ElapsedSec={2}" -f $res.Project,$shareCt,$res.DurationSec) -ForegroundColor Green
                    }
                } else {
                    $elapsed=([DateTime]::UtcNow - $a.Started).TotalSeconds
                    if ($elapsed -ge $TaskTimeoutSec) { try { $a.PS.Stop() } catch {}; try { $a.PS.Dispose() } catch {}; $completed++; Write-CVLog "Fileshare inventory timed out for project after $TaskTimeoutSec s" -Level Warning -Source 'Fileshare' -Scope @{ Project = $a.Project } } else { $remain += $a }
                }
            }
            $active=$remain
            $pct = if ($total -gt 0){ [math]::Round(($completed/$total)*100,1)} else {100}
            Update-CVProgress -Id 'fileshare-projects' -Activity 'FileShare Projects' -Status ("(Light) Projects {0}/{1} ({2}%)" -f $completed,$total,$pct) -PercentComplete $pct
            if ($active.Count -gt 0 -or $queue.Count -gt 0) { Start-Sleep -Milliseconds 160 }
        }
        Complete-CVProgress -Id 'fileshare-projects'
    $script:FileShareLogLines = $allLogs
        return $all
    }
}

<# =============================
   Modular DB Inventory Helpers
   (Refactor of original monolithic logic; behavior preserved)
   Each helper returns an array of PSCustomObject items OR $null.
   They update status & error refs just like original inline logic.
============================= #>

function Get-AlloyPrimaryClusterStorageBytes {
    param(
        [string]$ProjectId,
        [string]$ClusterId,
        [string]$Region,
        [string]$AccessToken
    )
    $ProjectId = ($ProjectId|ForEach-Object{$_}).Trim(); $ClusterId = ($ClusterId|ForEach-Object{$_}).Trim(); $Region = ($Region|ForEach-Object{$_}).Trim()
    if (-not $ProjectId -or -not $ClusterId -or -not $Region) { return -4 }
    try { if (-not $AccessToken) { $AccessToken = (gcloud auth print-access-token 2>$null).Trim() } } catch { return -1 }
    if (-not $AccessToken) { return -1 }
    $metricType = 'alloydb.googleapis.com/cluster/storage/usage'
    $now=[DateTime]::UtcNow; $endTime=$now.ToString('yyyy-MM-ddTHH:mm:ss.fffZ'); $startTime=$now.AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $filter='metric.type="{0}" AND resource.label.cluster_id="{1}" AND resource.label.location="{2}"' -f $metricType,$ClusterId,$Region
    try { $enc=[System.Uri]::EscapeDataString($filter) } catch { return -3 }
    $url = 'https://monitoring.googleapis.com/v3/projects/{0}/timeSeries?filter={1}&interval.startTime={2}&interval.endTime={3}' -f $ProjectId,$enc,$startTime,$endTime
    try { $resp=Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $AccessToken" } -Method GET -ErrorAction Stop } catch { return -3 }
    if ($resp.timeSeries -and $resp.timeSeries.Count -gt 0) {
        $series=$resp.timeSeries[0]
        $latest=($series.points | Sort-Object { $_.interval.endTime } | Select-Object -Last 1)
        if ($latest -and $latest.value) {
            $v=0; if ($latest.value.int64Value){$v=[double]$latest.value.int64Value} elseif ($latest.value.doubleValue){$v=[double][math]::Round($latest.value.doubleValue,0)}
            return $v
        }
        return -2
    }
    return -2
}

function Invoke-DbAlloyListInternal {
    param(
        [string]$ProjectId,
        [string]$Sub
    )
    $ga = & gcloud alloydb $Sub list --project $ProjectId --quiet --format=json 2>&1
    if ($LASTEXITCODE -eq 0 -and $ga -and -not ($ga -match 'not have this command group')) { return @{Ok=$true;Json=$ga;Msg=''} }
    $beta = & gcloud beta alloydb $Sub list --project $ProjectId --quiet --format=json 2>&1
    if ($LASTEXITCODE -eq 0 -and $beta -and -not ($beta -match 'not have this command group')) { return @{Ok=$true;Json=$beta;Msg=''} }
    return @{Ok=$false;Json='';Msg=($ga|Out-String)+($beta|Out-String)}
}

function Get-GcpCloudSqlInstances {
    param(
        [string]$ProjectId,
        [ref]$Errors,
        [ref]$Status
    )
    Write-Log "[DB] ($ProjectId) Start CloudSQL" -Level DEBUG
    $items=@()
    $rawSql = & gcloud sql instances list --project $ProjectId --quiet --format=json 2>&1
    if ($LASTEXITCODE -eq 0 -and $rawSql) {
        $sqlObjs = $null; try { $sqlObjs = $rawSql | ConvertFrom-Json } catch {}
        $cloudSqlInstCount=0
        foreach ($si in ($sqlObjs | Where-Object { $_ })) {
            $cloudSqlInstCount++
            $tier = $si.settings.tier; if (-not $tier) { $tier='' }
            $state = $si.state
            $region = $si.region
            $zone = if ($si.gceZone) { ($si.gceZone -split '/')[-1] } else { 'Regional' }
            $diskSizeGb = $si.settings.dataDiskSizeGb; if (-not $diskSizeGb) { $diskSizeGb = 0 }
            $engine = $si.databaseVersion
            $privateIPs=@(); $publicIPs=@(); $outgoingIPs=@()
            if ($si.ipAddresses) {
                foreach ($ipa in $si.ipAddresses) {
                    $ipVal = $ipa.ipAddress; if (-not $ipVal) { continue }
                    if ($ipa.type -eq 'PRIMARY') { $publicIPs += $ipVal } elseif ($ipa.type -eq 'OUTGOING') { $outgoingIPs += $ipVal } else { $privateIPs += $ipVal }
                }
            }
            # Resilience posture signals (null-safe; missing paths yield $false/0, scored later).
            $bc = $si.settings.backupConfiguration
            $items += [PSCustomObject]@{Type='CloudSQL';Project=$ProjectId;Name=$si.name;Region=$region;Zone=$zone;Engine=$engine;TierOrCapacity=$tier;State=$state;StorageGB=[double]$diskSizeGb;PrivateIPs=($privateIPs -join ';');PublicIPs=($publicIPs -join ';');OutgoingIPs=($outgoingIPs -join ';');`
                BackupEnabled=[bool]$bc.enabled;`
                PitrEnabled=[bool]($bc.pointInTimeRecoveryEnabled -or $bc.binaryLogEnabled);`
                RetainedBackups=[int]$bc.backupRetentionSettings.retainedBackups;`
                TxLogRetentionDays=[int]$bc.transactionLogRetentionDays;`
                CmkEncrypted=[bool]$si.diskEncryptionConfiguration.kmsKeyName;`
                DeletionProtection=[bool]$si.settings.deletionProtectionEnabled;`
                HasReplica=[bool](@($si.replicaNames).Count -gt 0);`
                AvailabilityType=[string]$si.settings.availabilityType;`
                Extra='';Error=''}
            if ($sqlObjs -and $sqlObjs.Count -gt 0 -and $cloudSqlInstCount -le 200) {
                $pctInst=[int](($cloudSqlInstCount/[double]$sqlObjs.Count)*100); if ($pctInst -gt 100){$pctInst=100}
                Update-CVProgress -Id 'db-cloudsql' -Activity ("CloudSQL $ProjectId") -Status ("Instances ($cloudSqlInstCount/$($sqlObjs.Count)) - $pctInst%") -PercentComplete $pctInst -ParentId 'db-projects'
            }
        }
        Write-Log "[DB] ($ProjectId) End CloudSQL Count=$cloudSqlInstCount" -Level DEBUG
    } else {
        $errText = ($rawSql | Out-String)
        if ($errText -match '(?i)permission|denied|forbidden|403') { $Errors.Value.Add("CloudSQL permission issue for $ProjectId"); $Status.Value.PermissionIssue='Y' }
        elseif ($errText -match '(?i)not enabled|has not been used|api .* enable') { $Errors.Value.Add("CloudSQL API disabled for $ProjectId"); $Status.Value.ApiDisabled='Y' }
        elseif ($errText -and $errText.Trim()) { $Errors.Value.Add("CloudSQL list failed for $ProjectId"); if (-not $Status.Value.Error){ $Status.Value.Error='CloudSQL list failed' } }
    }
    return $items
}

function Get-GcpAlloyDbResources {
    param(
        [string]$ProjectId,
        [ref]$Errors,
        [ref]$Status
    )
    $items=@()
    Write-Log "[DB] ($ProjectId) Start AlloyDB Clusters" -Level DEBUG
    $alloyClustersCall = Invoke-DbAlloyListInternal -ProjectId $ProjectId -Sub 'clusters'
    $alloyComponentMissing = $false
    if (-not $alloyClustersCall.Ok -and $alloyClustersCall.Msg -match 'requires the installation of components') { $alloyComponentMissing = $true }
    if (-not $alloyComponentMissing -and $alloyClustersCall.Ok) {
        $clusters = $null; try { $clusters = $alloyClustersCall.Json | ConvertFrom-Json } catch {}
        $__primaryClusters = @($clusters | Where-Object { $_ -and $_.clusterType -and ($_.clusterType.ToString().ToUpper() -eq 'PRIMARY') })
        $___primTotal = if ($__primaryClusters) { $__primaryClusters.Count } else { 0 }
        $___primProcessed = 0
        foreach ($cl in ($clusters | Where-Object { $_ })) {
            $clusterRegion = $cl.locationId
            if ($cl.name -and $cl.name -match '/locations/([^/]+)/') { $clusterRegion = $Matches[1] }
            $clusterType = if ($cl.clusterType) { $cl.clusterType } elseif ($cl.instanceConfig) { $cl.instanceConfig } else { '' }
            $dbVersion = if ($cl.databaseVersion) { $cl.databaseVersion } else { '' }
            $shortName = if ($cl.name) { ($cl.name -split '/')[-1] } else { '' }
            $engineVal = if ($dbVersion) { "PostgreSQL-$dbVersion" } else { 'PostgreSQL' }
            if ($clusterType -and ($clusterType.ToString().ToUpper() -ne 'PRIMARY')) { continue }
            $___primProcessed++
            if ($___primTotal -gt 0 -and $___primProcessed -le 500) {
                $pctPrim=[int](($___primProcessed/[double]$___primTotal)*100); if ($pctPrim -gt 100) { $pctPrim=100 }
                Update-CVProgress -Id 'db-alloydb' -Activity ("AlloyDB Clusters $ProjectId") -Status ("PrimaryClusters ($___primProcessed/$___primTotal) - $pctPrim%") -PercentComplete $pctPrim -ParentId 'db-projects'
            }
            $clusterStorageBytes = 0; $clusterStorageGB=0; $clusterStorageMB=0; $extraInfo=''
            if ($clusterType -eq 'PRIMARY') {
                if (-not $script:__AlloyAccessToken) { try { $script:__AlloyAccessToken = (gcloud auth print-access-token 2>$null).Trim() } catch { $script:__AlloyAccessToken=$null } }
                Write-Log -Level INFO -Message ("[DB][AlloyDB] ({0}) Cluster={1} Region={2} StartingMonitoringLookup" -f $ProjectId,$shortName,$clusterRegion)
                $bytes = Get-AlloyPrimaryClusterStorageBytes -ProjectId $ProjectId -ClusterId $shortName -Region $clusterRegion -AccessToken $script:__AlloyAccessToken
                $monitorStatus='OK'
                if ($bytes -and $bytes -gt 0) { $clusterStorageBytes=$bytes; $clusterStorageGB=[double][math]::Round($bytes/1GB,0); $clusterStorageMB=[double][math]::Round($bytes/1MB,0); $extraInfo=''; $monitorStatus='OK' }
                elseif ($bytes -eq -2) { $extraInfo='Monitoring=NoData';        $monitorStatus='NoData' }
                elseif ($bytes -eq -3) { $extraInfo='Monitoring=Error';         $monitorStatus='Error' }
                elseif ($bytes -eq -1) { $extraInfo='Monitoring=AuthError';     $monitorStatus='AuthError' }
                elseif ($bytes -eq -4) { $extraInfo='Monitoring=BadParams';     $monitorStatus='BadParams' }
                elseif ($bytes -eq -5) { $extraInfo='Monitoring=URLBuildError'; $monitorStatus='URLBuildError' }
                else { $extraInfo='Monitoring=Unknown';                         $monitorStatus='Unknown' }
                Write-Log -Level INFO -Message ("[DB][AlloyDB] ({0}) Cluster={1} Region={2} MonitoringResult Status={3} StorageBytes={4}" -f $ProjectId,$shortName,$clusterRegion,$monitorStatus,$clusterStorageBytes)
            }
            $items += [PSCustomObject]@{Type='alloydbcluster';Project=$ProjectId;Name=$shortName;Region=$clusterRegion;Zone='N/A';Engine=$engineVal;TierOrCapacity=$clusterType;State=$cl.state;StorageBytes=[int64]$clusterStorageBytes;StorageMB=[double]$clusterStorageMB;StorageGB=[double]$clusterStorageGB;MonitoringStatus=$monitorStatus;PrivateIPs='';PublicIPs='';Extra=$extraInfo;Error=''}
        }
    Write-Log "[DB] ($ProjectId) AlloyDB instance enumeration skipped (primary clusters only)" -Level INFO
    } elseif (-not $alloyComponentMissing -and $alloyClustersCall.Msg -match 'permission|denied|forbidden|403') {
        $Errors.Value.Add("AlloyDB clusters permission issue for $ProjectId")
        if (-not $Status.Value.PermissionIssue) { $Status.Value.PermissionIssue='Y' }
    } elseif ($alloyComponentMissing) {
        # silent skip
    }
    Write-Log "[DB] ($ProjectId) End AlloyDB Clusters" -Level DEBUG
    return $items
}

function Get-SpannerDatabaseStorageBytes {
    <#
        Returns an object with database used bytes plus (optionally) instance used bytes & derived limit.
        Backwards compatibility: if only a numeric value is expected by callers, they can still treat
        .DatabaseUsedBytes (or cast the return to [double] if they adapt). Current script only used the
        numeric return for database size lookups; we extend without breaking existing logic.
        Error Codes (numeric legacy mode):
          -1 Auth error, -2 No data, -3 API/URL build error, -4 Bad params
    #>
    param(
        [string]$ProjectId,
        [string]$InstanceId,
        [string]$DatabaseId,
        [string]$AccessToken,
        [switch]$IncludeInstanceMetrics,
        [int]$InstanceAlignSeconds = 3600,
        [int]$InstanceLookbackHours = 1
    )

    $ProjectId  = ($ProjectId  | ForEach-Object { $_ }).Trim()
    $InstanceId = ($InstanceId | ForEach-Object { $_ }).Trim()
    $DatabaseId = ($DatabaseId | ForEach-Object { $_ }).Trim()
    if (-not $ProjectId -or -not $InstanceId -or -not $DatabaseId) { return -4 }

    try { if (-not $AccessToken) { $AccessToken = (gcloud auth print-access-token 2>$null).Trim() } } catch { return -1 }
    if (-not $AccessToken) { return -1 }

    $now = [DateTime]::UtcNow
    $endTime = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $startTime = $now.AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $metricType = 'spanner.googleapis.com/database/storage/total_bytes'
    $filter = 'metric.type="{0}" AND resource.label.instance_id="{1}" AND resource.label.database_id="{2}"' -f $metricType,$InstanceId,$DatabaseId
    try { $enc = [System.Uri]::EscapeDataString($filter) } catch { return -3 }
    $url = 'https://monitoring.googleapis.com/v3/projects/{0}/timeSeries?filter={1}&interval.startTime={2}&interval.endTime={3}' -f $ProjectId,$enc,$startTime,$endTime
    $dbUsedBytes = -2
    try {
        $resp = Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $AccessToken" } -Method GET -ErrorAction Stop
        if ($resp.timeSeries -and $resp.timeSeries.Count -gt 0) {
            $series = $resp.timeSeries[0]
            $latest = ($series.points | Sort-Object { $_.interval.endTime } | Select-Object -Last 1)
            if ($latest -and $latest.value) {
                if ($latest.value.int64Value) { $dbUsedBytes = [int64]$latest.value.int64Value }
                elseif ($latest.value.doubleValue) { $dbUsedBytes = [int64][math]::Round($latest.value.doubleValue,0) }
            }
        }
    } catch { return -3 }

    $instanceUsedBytes = $null
    $derivedLimitBytes = $null
    $utilPct = $null
    if ($IncludeInstanceMetrics) {
        if ($InstanceAlignSeconds -le 0) { $InstanceAlignSeconds = 300 }
        $instStart = $now.AddHours(-[double]$InstanceLookbackHours)
        $instFilter = 'metric.type="spanner.googleapis.com/instance/storage/used_bytes" AND resource.type="spanner_instance" AND resource.label.instance_id="{0}"' -f $InstanceId
        try { $instEnc = [System.Uri]::EscapeDataString($instFilter) } catch { $instEnc = $null }
        if ($instEnc) {
            $instUrl = "https://monitoring.googleapis.com/v3/projects/$ProjectId/timeSeries?filter=$instEnc&interval.endTime=$endTime&interval.startTime=$($instStart.ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))&view=FULL&aggregation.alignmentPeriod=${InstanceAlignSeconds}s&aggregation.perSeriesAligner=ALIGN_MAX"
            try {
                $instResp = Invoke-RestMethod -Uri $instUrl -Headers @{ Authorization = "Bearer $AccessToken" } -Method GET -ErrorAction Stop
                if ($instResp.timeSeries -and $instResp.timeSeries.Count -gt 0) {
                    $latestSeries = $instResp.timeSeries | ForEach-Object {
                        $p = ($_.points | Sort-Object { $_.interval.endTime } | Select-Object -Last 1)
                        [pscustomobject]@{ Series = $_; LatestPoint = $p }
                    } | Sort-Object { $_.LatestPoint.interval.endTime } | Select-Object -Last 1
                    if ($latestSeries -and $latestSeries.LatestPoint -and $latestSeries.LatestPoint.value) {
                        $val = $latestSeries.LatestPoint.value
                        if ($val.int64Value) { $instanceUsedBytes = [int64]$val.int64Value }
                        elseif ($val.doubleValue) { $instanceUsedBytes = [int64][math]::Round($val.doubleValue,0) }
                    }
                }
            } catch { }
        }
        # Derive limit via processing units or nodeCount
        try {
            $instApi = Invoke-RestMethod -Uri "https://spanner.googleapis.com/v1/projects/$ProjectId/instances/$InstanceId" -Headers @{ Authorization = "Bearer $AccessToken" } -ErrorAction Stop
            $processingUnits = 0
            if ($instApi.processingUnits) { $processingUnits = [int]$instApi.processingUnits }
            elseif ($instApi.nodeCount) { $processingUnits = [int]$instApi.nodeCount * 100 }
            if ($processingUnits -gt 0) {
                $limitPer100PU = [int64]([Math]::Pow(1024,4)) # 1 TiB per 100 PU
                $derivedLimitBytes = [int64]($limitPer100PU * ($processingUnits / 100.0))
            }
            if ($derivedLimitBytes -and $instanceUsedBytes -ne $null -and $derivedLimitBytes -gt 0) {
                $utilPct = [math]::Round(($instanceUsedBytes / $derivedLimitBytes) * 100,4)
            }
        } catch { }
    }

    return [pscustomobject]@{
        DatabaseUsedBytes = $dbUsedBytes
        InstanceUsedBytes = $instanceUsedBytes
        DerivedLimitBytes = $derivedLimitBytes
        UtilizationPercent = $utilPct
    }
}

function Get-GcpSpannerInstances {
    param([string]$ProjectId)
    Write-Log "[DB] ($ProjectId) Start Spanner" -Level DEBUG
    $items=@()
    # Capture both stdout and stderr so we can emit diagnostics on failures
    $rawOutput = $null
    try {
        $rawOutput = & gcloud spanner instances list --project $ProjectId --quiet --format=json 2>&1
    } catch {
        Write-Log "[DB] ($ProjectId) Spanner command threw exception: $($_.Exception.Message)" -Level WARN
    }
    $exit = $LASTEXITCODE
    if ($exit -ne 0) {
        # NOTE: previously this dumped the whole gcloud error blob - `Out-String` yields ONE multi-line string,
        # so `Select-Object -First 1` returned all of it, ~20 lines per project. Classify instead, and put the
        # project in -Scope so repeats across projects collapse into one de-duplicated summary row.
        $errText = ($rawOutput | Out-String).Trim()
        if ($errText -match '(?i)not enabled|has not been used|is disabled|SERVICE_DISABLED') {
            # Benign: the project simply does not use Spanner, so there is nothing to inventory.
            Write-Log "Cloud Spanner API not enabled - skipping Spanner discovery" -Level WARN -Source 'Spanner' -Scope @{ Project = $ProjectId }
        }
        else {
            $firstLine = @($errText -split "`r?`n" | Where-Object { $_.Trim() })[0]
            if ($firstLine -and $firstLine.Length -gt 300) { $firstLine = $firstLine.Substring(0, 300) + '...' }
            Write-Log "Spanner list failed (exit $exit): $firstLine" -Level WARN -Source 'Spanner' -Scope @{ Project = $ProjectId }
        }
    } elseif (-not $rawOutput -or ($rawOutput.Trim() -eq '') -or ($rawOutput.Trim() -eq '[]')) {
        Write-Log "[DB] ($ProjectId) Spanner returned no instances (empty list)." -Level INFO
    } else {
        $spInstances = $null; $convertOk=$true
        try { $spInstances = $rawOutput | ConvertFrom-Json } catch { $convertOk=$false; Write-Log "[DB] ($ProjectId) Spanner JSON parse failure: $($_.Exception.Message)" -Level WARN }
        if ($convertOk -and $spInstances) {
            $count = (@($spInstances)).Count
            Write-Log "[DB] ($ProjectId) Spanner instances retrieved: $count" -Level INFO
            foreach ($spi in ($spInstances | Where-Object { $_ })) {
                $config = $spi.config
                $regionParsed = $config; if ($config -match 'instanceConfigs/(.+)$') { $regionParsed = $Matches[1] }
                $nodes = $spi.nodeCount; $processingUnits=$spi.processingUnits
                $tier = if ($nodes) { "$nodes nodes" } elseif ($processingUnits) { "$processingUnits PU" } else { '' }
                $derivedLimitBytes = $null
                if ($processingUnits) {
                    $derivedLimitBytes = [int64]([Math]::Pow(1024,4) * ($processingUnits / 100.0))
                } elseif ($nodes) {
                    $derivedLimitBytes = [int64]([Math]::Pow(1024,4) * $nodes) # assume 1TiB per node
                }
                $derivedLimitGiB = if ($derivedLimitBytes) { [math]::Round($derivedLimitBytes / 1GB,4) } else { 0 }
                $instMetrics = $null
                try { $instMetrics = Get-SpannerDatabaseStorageBytes -ProjectId $ProjectId -InstanceId $spi.name -DatabaseId 'dummy' -IncludeInstanceMetrics -ErrorAction SilentlyContinue } catch { }
                $usedGiB = 0; $utilPct = $null
                if ($instMetrics -and $instMetrics.InstanceUsedBytes) { $usedGiB = [math]::Round($instMetrics.InstanceUsedBytes / 1GB,4) }
                if ($instMetrics -and $instMetrics.UtilizationPercent -ne $null) { $utilPct = $instMetrics.UtilizationPercent }
                $extra = ''
                if ($usedGiB -gt 0 -or $utilPct -ne $null) {
                    $extra = "InstanceUsedGiB=$usedGiB;DerivedLimitGiB=$derivedLimitGiB;UtilPercent=$utilPct"
                }
                $items += [PSCustomObject]@{Type='SpannerInstance';Project=$ProjectId;Parent='';Name=$spi.name;Region=$regionParsed;Zone='';Engine='Spanner';TierOrCapacity=$tier;State=$spi.state;StorageGB=[double]$derivedLimitGiB;PrivateIPs='';PublicIPs='';Error='';Extra=$extra}
            }
        }
    }
    Write-Log "[DB] ($ProjectId) End Spanner" -Level DEBUG
    return $items
}

function Get-GcpBigQueryDatasets {
    <#
        One row per dataset, sized from Cloud Monitoring: a REST dataset list plus two Monitoring queries per
        project, regardless of table count.

        This replaced `bq ls` per dataset followed by `bq show` per TABLE - a separate Python process each, around
        a second apiece, with projects processed one at a time. Its INFORMATION_SCHEMA.TABLE_STORAGE "bulk" path was
        qualified per dataset, which that view does not support (it requires a region qualifier), so it always failed
        and fell back to per-table calls. Estates with tens of thousands of tables took hours.

        Trade-offs: storage/stored_bytes is LOGICAL bytes, sampled every 30 min and visible up to 3h later.
        Physical bytes are not available from Monitoring, so TotalPhysicalSizeGB and LargestTablePhysicalGB are
        blank (not collected). The per-table CSV is gone: Monitoring labels only the 100 largest tables per dataset.
    #>
    param(
        [string]$ProjectId,
        [ref]$Errors,
        [ref]$Status
    )

    Write-Log "[DB] ($ProjectId) Start BigQuery" -Level DEBUG
    $items = [System.Collections.Generic.List[psobject]]::new()
    $token = Get-CVGcpAccessToken

    $list = Get-CVBqDatasetList -ProjectId $ProjectId -AccessToken $token
    if ($list.Status -ne 'Ok') {
        $Errors.Value.Add("Failed to list BigQuery datasets for ${ProjectId}: $($list.Error)")
        if (-not $Status.Value.Error) { $Status.Value.Error = 'bigquery-list-failed' }
        if ($list.Error -match '403|PERMISSION_DENIED') { $Status.Value.PermissionIssue = 'Y' }
        $script:CVGcpBqProjectStatuses.Add([pscustomobject]@{ Project = $ProjectId; Status = 'Failed'; Error = $list.Error; DatasetCount = $null; TotalLogicalSizeGB = $null; SizeStatus = 'NotQueried'; SizeError = '' })
        return @($items)
    }
    Write-Log ("[DB][BigQuery] ({0}) DatasetCount={1}" -f $ProjectId,$list.Datasets.Count) -Level DEBUG
    if ($list.Datasets.Count -eq 0) {
        $script:CVGcpBqProjectStatuses.Add([pscustomobject]@{ Project = $ProjectId; Status = 'Success'; Error = ''; DatasetCount = 0; TotalLogicalSizeGB = 0; SizeStatus = 'NotQueried'; SizeError = '' })
        Write-Log "[DB] ($ProjectId) End BigQuery" -Level DEBUG; return @($items)
    }

    $sizeMap = Get-CVBqDatasetSizeMap -ProjectId $ProjectId -AccessToken $token
    if ($sizeMap.Status -ne 'Ok') {
        # Datasets are still reported - with blank sizes and a SizeNote - rather than as Error rows, which the
        # exports and the signals CSV drop. Knowing a dataset exists is worth keeping even when it cannot be sized.
        Write-CVLog "Cloud Monitoring BigQuery size query failed; sizes left blank: $($sizeMap.Error)" -Level Warning -Source 'BigQuery' -Scope @{ Project = $ProjectId }
        $script:CVGcpMonitoringFailures.Add([pscustomobject]@{ Service = 'BigQuery'; Project = $ProjectId; Error = $sizeMap.Error })
    }

    foreach ($ds in $list.Datasets) {
        $r = Resolve-CVBqDatasetSize -DatasetId $ds.DatasetId -SizeMap $sizeMap
        $logicalGB = if ($null -ne $r.LogicalBytes) { [math]::Round($r.LogicalBytes / 1GB, 2) } else { $null }
        $largestGB = if ($null -ne $r.LargestTableBytes) { [math]::Round($r.LargestTableBytes / 1GB, 2) } else { $null }
        Write-Log ("[DB][BigQuery] ({0}) Dataset={1} Tables={2} LogicalBytes={3} Status={4}" -f $ProjectId,$ds.DatasetId,$r.TableCount,$r.LogicalBytes,$r.Status) -Level DEBUG
        $items.Add([PSCustomObject]@{
            Type                     = 'BigQueryDataset'
            Project                  = $ProjectId
            Name                     = $ds.DatasetId
            Region                   = $ds.Location
            Engine                   = 'BigQuery'
            StorageGB                = $logicalGB             # Backward compatibility (now LOGICAL size - see above)
            TotalPhysicalSizeGB      = $null                  # Not available from Cloud Monitoring
            TotalLogicalSizeGB       = $logicalGB
            TableCount               = $r.TableCount
            LargestTable             = $r.LargestTable
            LargestTablePhysicalGB   = $null
            LargestTableLogicalGB    = $largestGB
            SizeSource               = 'CloudMonitoring:bigquery/storage/stored_bytes'
            SizeStatus               = $r.Status
            SizeNote                 = $r.Note
            Error                    = ''
        })
    }

    $sizeOk = ($sizeMap.Status -eq 'Ok')
    $script:CVGcpBqProjectStatuses.Add([pscustomobject]@{
        Project = $ProjectId; Status = 'Success'; Error = ''; DatasetCount = $items.Count
        # Blank, not 0, when Monitoring could not be read - see the storage status CSV for the same rule.
        TotalLogicalSizeGB = $(if ($sizeOk) { [math]::Round((($items | Measure-Object TotalLogicalSizeGB -Sum).Sum), 2) } else { $null })
        SizeStatus = $sizeMap.Status; SizeError = $(if ($sizeMap.Error) { $sizeMap.Error } else { '' })
    })

    Write-Log "[DB] ($ProjectId) End BigQuery" -Level DEBUG
    return @($items)
}

function Invoke-GcpDbProjectInventory {
    param(
        [string]$ProjectId,
        [int]$TimeoutSec,
        [int]$ProjectIndex,
        [int]$TotalProjects,
        [ref]$Errors,
        [ref]$Statuses
    )
    $projStart = Get-Date
    $projStatus = [PSCustomObject]@{ Project=$ProjectId; Success=''; PermissionIssue=''; ApiDisabled=''; Timeout=''; Error=''; DurationSec=0 }
    $enabledSvcNames=@()
    try {
        $svcRaw = & gcloud services list --project $ProjectId --enabled --format="value(config.name)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $svcRaw) { $enabledSvcNames = $svcRaw | Where-Object { $_ } }
    } catch {}
    $requiredMap = @{ CloudSQL='sqladmin.googleapis.com'; Spanner='spanner.googleapis.com'; BigQuery='bigquery.googleapis.com'; AlloyDB='alloydb.googleapis.com' }
    $missingSvcs = @(); foreach ($kv in $requiredMap.GetEnumerator()) { if ($enabledSvcNames -and ($enabledSvcNames -notcontains $kv.Value)) { $missingSvcs += $kv.Value } }
    if ($missingSvcs.Count -gt 0) { $projStatus.ApiDisabled='Y'; if (-not $projStatus.Error){ $projStatus.Error = 'MissingServices=' + ($missingSvcs -join ';') } }
    $displayTotal = if ($TotalProjects -gt 0) { $TotalProjects } else { 1 }
    Update-CVProgress -Id 'db-projects' -Activity 'DB Projects' -Status ("Project $ProjectId ($ProjectIndex/$displayTotal)") -PercentComplete ([int](($ProjectIndex-1)/[double]$displayTotal*100))
    $allItems=@()
    $projOk=$true
    try {
        $errRef = $Errors
        $statusRef = [ref]$projStatus
        $allItems += Get-GcpCloudSqlInstances -ProjectId $ProjectId -Errors $errRef -Status $statusRef
        $allItems += Get-GcpAlloyDbResources  -ProjectId $ProjectId -Errors $errRef -Status $statusRef
        $allItems += Get-GcpSpannerInstances  -ProjectId $ProjectId
        $allItems += Get-GcpBigQueryDatasets  -ProjectId $ProjectId -Errors $errRef -Status $statusRef
        if ($projStatus.PermissionIssue -or ($projStatus.Error -and $projStatus.Error -match 'permission')) { $projOk=$false }
        if ($errRef.Value.Count -gt 0) {
            # If last error pertains to this project and is critical, mark not ok
            $lastErr = $errRef.Value | Select-Object -Last 1
            if ($lastErr -match $ProjectId -and ($lastErr -match 'permission issue' -or $lastErr -match 'failed')) { $projOk=$false }
        }
    if ($projStatus.ApiDisabled -eq 'Y') { $projOk=$false }
    } catch {
        $errMsg = "General DB inventory failure for ${ProjectId}: $($_.Exception.Message)"
        $Errors.Value.Add($errMsg)
        if (-not $projStatus.Error) { $projStatus.Error = "General failure: $($_.Exception.Message)" }
        $projOk=$false
    }
    if ($projOk) { $script:DbProjectSuccess.Add($ProjectId); $projStatus.Success='Y' } else { $script:DbProjectFailed.Add($ProjectId); if (-not $projStatus.Error -and $Errors.Value.Count -gt 0) { $projStatus.Error = ($Errors.Value | Select-Object -Last 1) } }
    $projStatus.DurationSec = [math]::Round(((Get-Date)-$projStart).TotalSeconds,2)
    if ($projStatus.DurationSec -ge $TimeoutSec -and -not $projStatus.Success) { $projStatus.Timeout='Y'; if (-not $projStatus.Error) { $projStatus.Error='Timeout' } }
    $Statuses.Value.Add($projStatus) | Out-Null
    return @{ Items=$allItems; Status=$projStatus }
}

function Get-GcpDatabaseInventory {
    param(
        [Parameter(Mandatory)][string[]]$ProjectIds,
        [switch]$LightMode,
        [int] $MaxThreads = 8,
        [int] $ProjectTimeoutSec = 900
    )

    if (-not $ProjectIds -or $ProjectIds.Count -eq 0) {
        return [PSCustomObject]@{
            Data   = @();
            Errors = @('No projects supplied for DB inventory')
        }
    }

    $results = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
    $errors  = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
    $script:DbProjectSuccess = New-Object System.Collections.Concurrent.ConcurrentBag[string]
    $script:DbProjectFailed  = New-Object System.Collections.Concurrent.ConcurrentBag[string]
    # Use thread-safe bag for statuses when running in parallel
    if (-not $script:DbProjectStatuses) { $script:DbProjectStatuses = New-Object System.Collections.Concurrent.ConcurrentBag[object] }
    $projQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new(); foreach ($p in $ProjectIds) { $projQueue.Enqueue($p) }
    $totalProjects = $ProjectIds.Count
    # Thread-safe progress counter (only add type once). Resolve the type by name rather than sweeping every
    # loaded assembly with GetTypes() - that throws ReflectionTypeLoadException for any assembly with an
    # unresolvable member, which is routine when hosted (VS Code PowerShell extension, Az modules) and buried
    # the real output under screens of "does not have an implementation" noise.
    if (-not ('DbProg' -as [type])) {
        Add-Type -TypeDefinition @"
public class DbProg { private static int counter = 0; public static int Increment(){ return System.Threading.Interlocked.Increment(ref counter);} }
"@
    }
    $scriptBlock = {
        param($queue,$res,$errs,$total,$statuses,$timeoutSec)
        $proj = $null; $index=0
        while ($queue.TryDequeue([ref]$proj)) {
            $index++
            try {
                $localErrs = New-Object System.Collections.Generic.List[string]
                $statusListRef = [ref]$statuses
                $inv = Invoke-GcpDbProjectInventory -ProjectId $proj -TimeoutSec $timeoutSec -ProjectIndex $index -TotalProjects $total -Errors ([ref]$localErrs) -Statuses $statusListRef
                foreach ($i in $inv.Items) { $res.Add($i) }
                foreach ($le in $localErrs) { $errs.Add($le) }
                $processed=[DbProg]::Increment(); $pctParent = if ($total -gt 0) { [int](($processed/[double]$total)*100) } else { 100 }
                Update-CVProgress -Id 'db-projects' -Activity 'DB Projects' -Status ("Project $ProjectId ($ProjectIndex/$displayTotal)") -PercentComplete $pctParent
            } catch {
                $errs.Add("General DB inventory failure for ${proj}: $($_.Exception.Message)")
            }
        }
    }
    # Parallel runspaces disabled permanently for DB path due to inconsistent helper propagation.
    $usePool = $false
    $threads = [math]::Min($MaxThreads,[math]::Max(1,$ProjectIds.Count))
    # Always sequential execution
    & $scriptBlock $projQueue $results $errors $totalProjects $script:DbProjectStatuses $ProjectTimeoutSec
    foreach ($e in $errors) {
        $projName = ($ProjectIds | Where-Object { $e -like "*$_*" } | Select-Object -First 1); if (-not $projName) { $projName='' }
        $results.Add([PSCustomObject]@{Type='Error';Project=$projName;Name='';Region='';Zone='';Engine='';TierOrCapacity='';State='';StorageGB=0;Extra='';Error=($e -replace ',',';')})
    }
    return [PSCustomObject]@{ Data=$results.ToArray(); Errors=$errors.ToArray() }
}


function Get-GcpGkeInventory {
    <#
        .SYNOPSIS
            Modular GKE inventory (refactored from monolithic implementation)
        .OUTPUT
            Hashtable: @{ Clusters=[list]; PVs=[list]; PVCs=[list] }
        .NOTES
            Preserves prior output shape for downstream consumers.
    #>
    param(
        [string[]]$ProjectIds,
        [int]$MaxThreads = 4,          # Currently unused (sequential for safety w/ kubectl contexts)
        [int]$TaskTimeoutSec = 600,
        [switch]$LightMode
    )
    if (-not $ProjectIds -or $ProjectIds.Count -eq 0) { return @{ Clusters=@(); PVs=@(); PVCs=@() } }

    $script:gkeVerbose = $true
    if ($gkeVerbose) { Write-Log -Level INFO -Message ("[GKE-INIT] TargetProjects={0}" -f ($ProjectIds -join ',')) }

    # Detect kubectl (already ensured earlier if -Types GKE used)
    $resolvedKubectl = $null
    if (Get-Variable -Name __KubectlResolvedPath -Scope Script -ErrorAction SilentlyContinue) {
        if ($script:__KubectlResolvedPath -and (Test-Path $script:__KubectlResolvedPath)) { $resolvedKubectl = $script:__KubectlResolvedPath }
    }
    if (-not $resolvedKubectl) {
        $kcCmd = Get-Command kubectl -ErrorAction SilentlyContinue
        if ($kcCmd) { $resolvedKubectl = $kcCmd.Source }
    }
    $kubectlPresent = [bool]$resolvedKubectl
    if (-not $kubectlPresent) { Write-Log -Level WARN -Message "[GKE] kubectl not detected; will rely on disk heuristics if PV/PVC API path unavailable." }
    else { Write-Log -Level INFO -Message ("[GKE-ENV] kubectlPresent=True Path={0}" -f $resolvedKubectl) }

    # ----------------- Helper Functions -----------------
    function Get-GkeClustersForProject {
        param([string]$ProjectId)
        $clusters=@(); $apiDisabled=$false; $permIssue=$false
        try {
            $raw = & gcloud --quiet container clusters list --project $ProjectId --format=json 2>$null
            if ($LASTEXITCODE -ne 0) {
                $msg=($raw|Out-String)
                if ($msg -match '(?i)not enabled|has not been used|api .* enable') { $apiDisabled=$true }
                elseif ($msg -match '(?i)permission|denied|forbidden|403') { $permIssue=$true }
            } elseif (-not [string]::IsNullOrWhiteSpace(($raw|Out-String))) {
                try { $clusters = $raw | ConvertFrom-Json } catch {
                    $first= (($raw|Out-String) -split "`n")[0]
                    Write-Log -Level WARN -Message ("[GKE] ({0}) Cluster JSON parse failure FirstLine='{1}'" -f $ProjectId,($first -replace ',',';'))
                }
            }
        } catch { Write-Log -Level WARN -Message ("[GKE] ({0}) Exception listing clusters: {1}" -f $ProjectId,$_.Exception.Message) }
        return [PSCustomObject]@{Clusters=$clusters; ApiDisabled=$apiDisabled; PermIssue=$permIssue}
    }

    function Get-GkeProjectDisks {
        param([string]$ProjectId,[bool]$Skip)
        if ($Skip) { return @() }
        try {
            $diskRaw = & gcloud --quiet compute disks list --project $ProjectId --format=json 2>$null
            if ($LASTEXITCODE -eq 0 -and $diskRaw) { try { return ($diskRaw | ConvertFrom-Json) } catch {} }
        } catch {}
        return @()
    }

    function Convert-QuantityToGiB { param([string]$Val)
        if (-not $Val) { return 0 }
        if ($Val -match '^(?<num>[0-9]+\.?[0-9]*)(?<unit>(Ki|Mi|Gi|Ti|Pi|Ei|K|M|G|T|P|E))?$') {
            $num=[double]$Matches.num; $u=$Matches.unit
            switch ($u) {
                'Ki' { return $num/1024/1024 }
                'Mi' { return $num/1024 }
                'Gi' { return $num }
                'Ti' { return $num*1024 }
                'Pi' { return $num*1024*1024 }
                'Ei' { return $num*1024*1024*1024 }
                'K'  { return $num/1024/1024 }
                'M'  { return $num/1024 }
                'G'  { return $num }
                'T'  { return $num*1024 }
                'P'  { return $num*1024*1024 }
                'E'  { return $num*1024*1024*1024 }
                default { return $num }
            }
        } elseif ($Val -match '^(?<bytes>[0-9]+)$') { return ([double]$Matches.bytes)/1GB }
        return 0
    }

    function Get-GkeNodePoolResources { param($Cluster)
        $nodeCount=0; $vCpu=0; $memGb=0
        if (-not $Cluster.nodePools) { return @{NodeCount=0;vCpu=0;memGb=0} }
        $idx=0
        foreach ($np in $Cluster.nodePools) {
            $idx++
            $nNodes = 0
            if ($np.initialNodeCount) { $nNodes=[int]$np.initialNodeCount }
            elseif ($np.statusMessage -match 'size=([0-9]+)') { $nNodes=[int]$Matches[1] }
            if ($np.autoscaling -and $np.autoscaling.enabled -and $np.autoscaling.autoprovisioningEnabled -ne $true) {
                if ($np.statusMessage -match 'size=([0-9]+)') { $nNodes=[int]$Matches[1] }
            }
            $nodeCount += $nNodes
            $mt = $null; if ($np.config) { $mt=$np.config.machineType }
            if ($mt) {
                switch -regex ($mt) {
                    'e2-micro' { $vCpu += 2*$nNodes; $memGb += 1*$nNodes }
                    'e2-small' { $vCpu += 2*$nNodes; $memGb += 2*$nNodes }
                    'e2-medium'{ $vCpu += 2*$nNodes; $memGb += 4*$nNodes }
                    'e2-standard-(\d+)' { $c=[int]$Matches[1]; $vCpu += $c*$nNodes; $memGb += ($c*4)*$nNodes }
                    'n1-standard-(\d+)' { $c=[int]$Matches[1]; $vCpu += $c*$nNodes; $memGb += ($c*3.75)*$nNodes }
                    'n2-standard-(\d+)' { $c=[int]$Matches[1]; $vCpu += $c*$nNodes; $memGb += ($c*4)*$nNodes }
                }
            }
        }
        return @{NodeCount=$nodeCount;vCpu=$vCpu;memGb=$memGb}
    }

    function Get-GkePvAndPvcInfo {
        param(
            [string]$ProjectId,
            [string]$ClusterName,
            [string]$Region,
            [string]$Zone,
            [bool]$UseKubectl,
            [object[]]$ProjectDisks,
            [string]$KubectlPath
        )
        $pvDetails = New-Object System.Collections.Generic.List[psobject]
        $pvcDetails= New-Object System.Collections.Generic.List[psobject]
        $pvCap=0; $pvCount=0; $source=''
        if (-not $UseKubectl) {
            return @{ PvDetails=$pvDetails; PvcDetails=$pvcDetails; CapacityGiB=0; Count=0; Source=''; }
        }
        $tmpKube = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(),"kubeconfig_${ProjectId}_${ClusterName}_"+[guid]::NewGuid().ToString()+'.tmp')
        try {
            $env:KUBECONFIG=$tmpKube
            Write-Log -Level INFO -Message ("GKE :: Get PVC info started for {0}:{1}" -f $ProjectId,$ClusterName)
            $kubectlCmd = if ($KubectlPath -and (Test-Path $KubectlPath)) { $KubectlPath } else { 'kubectl' }
            if ($Zone) { $connectionOP = & gcloud --quiet container clusters get-credentials $ClusterName --zone $Zone --project $ProjectId 2>$null } else { $connectionOP = & gcloud --quiet container clusters get-credentials $ClusterName --region $Region --project $ProjectId 2>$null }

            Write-Log -Level DEBUG -Message ("[GKE] ({0}) {1} get-credentials output: {2}" -f $ProjectId,$ClusterName,($connectionOP|Out-String).Trim())

            if ($LASTEXITCODE -ne 0) { Write-Log -Level WARN -Message ("[GKE] ({0}) {1} get-credentials failed" -f $ProjectId,$ClusterName); return @{PvDetails=$pvDetails;PvcDetails=$pvcDetails;CapacityGiB=0;Count=0;Source=''} }
            # PV list
            Write-Log -Level INFO -Message ("GKE :: Get PV info started for {0}:{1}" -f $ProjectId,$ClusterName)
            $pvRaw = & $kubectlCmd get pv -o json --request-timeout=25s 2>$null
            Write-Log -Level DEBUG -Message ("[GKE] ({0}) {1} kubectl get pv exitcode={2}" -f $ProjectId,$ClusterName,$LASTEXITCODE)
            Write-Log -Level DEBUG -Message ("[GKE] ({0}) {1} kubectl get pv raw: {2}" -f $ProjectId,$ClusterName,($pvRaw|Out-String).Trim())
            if ($LASTEXITCODE -eq 0 -and $pvRaw) {
                try {
                    $pvObj = $pvRaw | ConvertFrom-Json -ErrorAction Stop
                } catch {
                    # Attempt to sanitize raw output (strip any leading non-JSON noise / trailing text)
                    try {
                        $pvText = ($pvRaw | Out-String).Trim()
                        $startIdx = $pvText.IndexOf('{')
                        if ($startIdx -gt 0) { $pvText = $pvText.Substring($startIdx) }
                        $endIdx = $pvText.LastIndexOf('}')
                        if ($endIdx -gt 0 -and $endIdx -lt ($pvText.Length-1)) { $pvText = $pvText.Substring(0,$endIdx+1) }
                        $pvObj = $pvText | ConvertFrom-Json -ErrorAction Stop
                        Write-Log -Level INFO -Message ("[GKE][PV-JSON-SANITIZE] ({0}) {1} Applied sanitation for kubectl pv output" -f $ProjectId,$ClusterName)
                    } catch {
                        Write-Log -Level WARN -Message ("[GKE] ({0}) {1} PV parse failed after sanitation: {2}" -f $ProjectId,$ClusterName,$_.Exception.Message)
                        $pvObj = $null
                    }
                }
                if ($pvObj -and $pvObj.items) {
                    foreach ($pv in ($pvObj.items | Where-Object { $_ })) {
                        if ($pv.status.phase -and $pv.status.phase -match 'Released|Failed') { continue }
                        $capRaw = if ($pv.spec.capacity.storage) { $pv.spec.capacity.storage } elseif ($pv.status.capacity.storage) { $pv.status.capacity.storage } else { $null }
                        $gi = Convert-QuantityToGiB $capRaw
                        if ($gi -gt 0) {
                            $pvCap += [double]([math]::Round($gi,4)); $pvCount++
                            $backingDisk = ''
                            if ($pv.spec.gcePersistentDisk -and $pv.spec.gcePersistentDisk.pdName) { $backingDisk = $pv.spec.gcePersistentDisk.pdName }
                            # TryParse, not [datetime]. A bare cast on an unparseable creationTimestamp THROWS,
                            # and the enclosing try has only a finally (no catch), so it escaped to the
                            # top-level handler and killed the whole run before any CSV was written. The PVC
                            # loop below was already protected by its own catch; this path was not.
                            $pvCreated = $null
                            $pvParsed  = [datetime]::MinValue
                            if ($pv.metadata.creationTimestamp -and [datetime]::TryParse([string]$pv.metadata.creationTimestamp, [ref]$pvParsed)) { $pvCreated = $pvParsed }
                            $pvDetails.Add([PSCustomObject]@{Project=$ProjectId;ClusterName=$ClusterName;PVName=$pv.metadata.name;Phase=$pv.status.phase;CapacityGiB=[math]::Round($gi,4);StorageClass=$pv.spec.storageClassName;
                                ReclaimPolicy=$pv.spec.persistentVolumeReclaimPolicy;AccessModes=(($pv.spec.accessModes) -join ';');VolumeMode=$pv.spec.volumeMode;ClaimNamespace=$pv.spec.claimRef.namespace;ClaimName=$pv.spec.claimRef.name;
                                Provisioner=$pv.metadata.annotations.'pv.kubernetes.io/provisioned-by';BackingDisk=$backingDisk;CreationTimestamp=$pvCreated;AgeDays=$(if ($pvCreated) { [math]::Round((New-TimeSpan -Start $pvCreated -End (Get-Date)).TotalDays,2) } else { $null }) }) | Out-Null
                        }
                    }
                }
            }
            if ($pvCount -gt 0) { $source='pv' }

            # PVC list (always captured for detail)
            $pvcRaw = & $kubectlCmd get pvc -A -o json --request-timeout=30s 2>$null
            if ($LASTEXITCODE -eq 0 -and $pvcRaw) {
                $pvcCapSum = 0; $pvcCount = 0
                try {
                    $pvcObj = $pvcRaw | ConvertFrom-Json
                    foreach ($pvc in ($pvcObj.items | Where-Object { $_ })) {
                        $reqCap = if ($pvc.spec.resources.requests.storage) { $pvc.spec.resources.requests.storage } else { $null }
                        $actCap = if ($pvc.status.capacity.storage) { $pvc.status.capacity.storage } else { $reqCap }
                        $reqGi = Convert-QuantityToGiB $reqCap
                        $actGi = Convert-QuantityToGiB $actCap
                        if ($actGi -gt 0) { $pvcCapSum += [double]([math]::Round($actGi,4)); $pvcCount++ }
                        # Same TryParse treatment as the PV loop. This path had a catch, so it could not abort the
                        # run - but a single unparseable timestamp still discarded the whole cluster's PVC detail.
                        $pvcCreated = $null
                        $pvcParsed  = [datetime]::MinValue
                        if ($pvc.metadata.creationTimestamp -and [datetime]::TryParse([string]$pvc.metadata.creationTimestamp, [ref]$pvcParsed)) { $pvcCreated = $pvcParsed }
                        $pvcDetails.Add([PSCustomObject]@{Project=$ProjectId;ClusterName=$ClusterName;Namespace=$pvc.metadata.namespace;PVCName=$pvc.metadata.name;Status=$pvc.status.phase;RequestedGiB=[math]::Round($reqGi,4);CapacityGiB=[math]::Round($actGi,4);StorageClass=$pvc.spec.storageClassName;AccessModes=(($pvc.spec.accessModes)-join ';');VolumeMode=$pvc.spec.volumeMode;PVName=$pvc.spec.volumeName;CreationTimestamp=$pvcCreated;AgeDays=$(if ($pvcCreated) { [math]::Round((New-TimeSpan -Start $pvcCreated -End (Get-Date)).TotalDays,2) } else { $null })}) | Out-Null
                    }
                    # If no PV objects were found, fall back to aggregated PVC capacities/count
                    if ($pvCount -eq 0 -and $pvcCount -gt 0) { $pvCap = [math]::Round($pvcCapSum,2); $pvCount = $pvcCount; $source = 'pvc' }
                    else {
                        # Reconcile if PV object count appears incomplete vs distinct PVC PVNames
                        $distinctPvNames = ($pvcDetails | Where-Object { $_.PVName } | Select-Object -ExpandProperty PVName -Unique)
                        if ($pvCount -gt 0 -and $distinctPvNames.Count -gt $pvCount) {
                            $uniqueCap = 0
                            $seen = @{}
                            foreach ($pvcEntry in ($pvcDetails | Where-Object { $_.PVName })) {
                                if (-not $seen.ContainsKey($pvcEntry.PVName)) {
                                    if ($pvcEntry.CapacityGiB -gt 0) { $uniqueCap += [double]$pvcEntry.CapacityGiB }
                                    $seen[$pvcEntry.PVName] = $true
                                }
                            }
                            if ($uniqueCap -gt 0 -and $uniqueCap -gt $pvCap) {
                                Write-Log -Level INFO -Message ("[GKE][PV-RECONCILE] ({0}) {1} Adjusting PVCount {2}->{3} PVCapGB {4}->{5}" -f $ProjectId,$ClusterName,$pvCount,$distinctPvNames.Count,$pvCap,[math]::Round($uniqueCap,2))
                                $pvCap = [math]::Round($uniqueCap,2)
                                $pvCount = $distinctPvNames.Count
                                $source = 'pvc-reconcile'
                            }
                        }
                    }
                } catch { Write-Log -Level WARN -Message ("[GKE] ({0}) {1} PVC parse failed: {2}" -f $ProjectId,$ClusterName,$_.Exception.Message) }
            }
        } catch {
            # This try had ONLY a finally. Anything that threw inside it - the PV timestamp cast above being the
            # proven case - propagated out of the runspace to the top-level handler and abandoned the entire run
            # before a single CSV was written. One cluster's PV detail is not worth the whole deliverable.
            Write-Log -Level WARN -Message ("[GKE] ({0}) {1} PV/PVC collection failed: {2}" -f $ProjectId, $ClusterName, $_.Exception.Message)
        } finally { try { if (Test-Path $tmpKube) { Remove-Item $tmpKube -Force -ErrorAction SilentlyContinue } } catch {} }

        # Heuristic if still zero
        if ($pvCount -eq 0 -and $ProjectDisks -and $ProjectDisks.Count -gt 0) {
            $matched = @()
            foreach ($d in $ProjectDisks) {
                if ($d.name -match "gke-${ClusterName}.*-node-") { continue }
                $hasLabel=$false
                if ($d.labels) {
                    foreach ($ln in $d.labels.PSObject.Properties.Name) { if ($ln -match 'kubernetes-io-created-for-pv-name|kubernetes-io-created-for-pvc-name') { $hasLabel=$true; break } }
                }
                if ($hasLabel -or $d.name -like "gke-${ClusterName}-*") { $matched += $d }
            }
            if ($matched.Count -gt 0) {
                foreach ($m in $matched) { if ($m.sizeGb) { $pvCap += [double]$m.sizeGb } }
                $pvCount = $matched.Count; $source='disk'
                Write-Log -Level INFO -Message ("[GKE][DISK-HEURISTIC] ({0}) Cluster={1} Disks={2} CapGB={3}" -f $ProjectId,$ClusterName,$matched.Count,$pvCap)
            }
        }
        return @{ PvDetails=$pvDetails; PvcDetails=$pvcDetails; CapacityGiB=[math]::Round($pvCap,2); Count=$pvCount; Source=$source }
    }

    $allClusters   = New-Object System.Collections.Generic.List[psobject]
    $allPvDetails  = New-Object System.Collections.Generic.List[psobject]
    $allPvcDetails = New-Object System.Collections.Generic.List[psobject]

    foreach ($proj in $ProjectIds) {
        $projStart=[DateTime]::UtcNow
        Write-Log -Level INFO -Message ("[GKE-PROJECT-START] {0}" -f $proj)
        $clResult = Get-GkeClustersForProject -ProjectId $proj
        $projDisks = Get-GkeProjectDisks -ProjectId $proj -Skip ($clResult.ApiDisabled -or $clResult.PermIssue)
        if ($gkeVerbose) { Write-Log -Level DEBUG -Message ("[GKE-PROJECT] {0} DisksEnumerated={1}" -f $proj,$projDisks.Count) }
        $clusters = $clResult.Clusters
        if (-not $clusters -or $clusters.Count -eq 0) {
            Write-Log -Level INFO -Message ("[GKE-PROJECT] {0} ClusterCount=0 (ApiDisabled={1} PermIssue={2})" -f $proj,$clResult.ApiDisabled,$clResult.PermIssue)
        } else {
            Write-Log -Level INFO -Message ("[GKE-PROJECT] {0} ClusterCount={1}" -f $proj,$clusters.Count)
        }
        foreach ($c in ($clusters | Where-Object { $_ })) {
            $name = $c.name
            $location = if ($c.location) { $c.location } elseif ($c.zone) { ($c.zone -split '/')[-1] } elseif ($c.region) { $c.region } else { '' }
            $region = if ($location -match '^[a-z0-9-]+-[a-z]$') { $location -replace '-[a-z]$','' } else { $location }
            $zone = if ($location -match '^[a-z0-9-]+-[a-z]$') { $location } else { '' }
            $version = $c.currentMasterVersion; if (-not $version) { $version=$c.currentNodeVersion }
            $npRes = Get-GkeNodePoolResources -Cluster $c
            $pvInfo = Get-GkePvAndPvcInfo -ProjectId $proj -ClusterName $name -Region $region -Zone $zone -UseKubectl:$kubectlPresent -ProjectDisks $projDisks -KubectlPath $resolvedKubectl
            if ($pvInfo.PvDetails.Count -gt 0) { foreach ($pv in $pvInfo.PvDetails) { $allPvDetails.Add($pv)|Out-Null } }
            if ($pvInfo.PvcDetails.Count -gt 0) { foreach ($pvc in $pvInfo.PvcDetails) { $allPvcDetails.Add($pvc)|Out-Null } }
            $network = if ($c.network) { ($c.network -split '/')[-1] } else { '' }
            $subnet  = if ($c.subnetwork) { ($c.subnetwork -split '/')[-1] } else { '' }
            $releaseChannel = if ($c.releaseChannel.channel) { $c.releaseChannel.channel } else { '' }
            # $gkeObj, not $obj: the BigQuery-table builder also assigns $obj, so the shared name unioned
            # GKE's field set with LogicalBytes/PhysicalBytes/TableId and weakened GKE's per-type check.
            $gkeObj = [PSCustomObject]@{
                Project       = $proj
                ClusterName   = $name
                Region        = $region
                Zone          = $zone
                Location      = $location
                KubernetesVer = $version
                NodeCount     = $npRes.NodeCount
                EstimatedvCPU = [int]$npRes.vCpu
                EstimatedMemGB= [int][math]::Round($npRes.memGb,0)
                PersistentVolumeCapacityGB = [double]$pvInfo.CapacityGiB
                PersistentVolumeCount      = $pvInfo.Count
                PersistentVolumeSource     = $pvInfo.Source
                ReleaseChannel= $releaseChannel
                Network       = $network
                Subnetwork    = $subnet
                Endpoint      = if ($c.endpoint){$c.endpoint}else{''}
                ApiDisabled   = $clResult.ApiDisabled
                PermissionIssue = $clResult.PermIssue
                # Application-layer secrets encryption (etcd CMEK). Already in the `container clusters list`
                # payload. ENCRYPTED is the only Met state; DECRYPTED, and a databaseEncryption block that is
                # absent entirely, are both a MEASURED $false - we read the cluster object and the feature is
                # not on. Not blank: blank is reserved for "we could not read the cluster at all", which is the
                # ApiDisabled / PermissionIssue path where this whole row does not get built.
                SecretsEncryptionCmk    = ("$($c.databaseEncryption.state)" -eq 'ENCRYPTED')
                # 'None' rather than blank when read-and-absent, matching the aks-diskcmek precedent.
                SecretsEncryptionKeyName = if ($c.databaseEncryption.keyName) { "$($c.databaseEncryption.keyName)" } else { 'None' }
            }
            # Attach detail arrays (for downstream harvesting to remain compatible)
            $null = $gkeObj | Add-Member -NotePropertyName _PvDetails  -NotePropertyValue ($pvInfo.PvDetails.ToArray())  -Force
            $null = $gkeObj | Add-Member -NotePropertyName _PvcDetails -NotePropertyValue ($pvInfo.PvcDetails.ToArray()) -Force
            $allClusters.Add($gkeObj)|Out-Null
            Write-Log -Level INFO -Message ("[GKE] Project={0} Cluster={1} Nodes={2} PVCapGB={3} PVCount={4} Source={5}" -f $proj,$name,$npRes.NodeCount,$pvInfo.CapacityGiB,$pvInfo.Count,$pvInfo.Source)
        }
        $dur=[math]::Round(([DateTime]::UtcNow-$projStart).TotalSeconds,2)
        Write-Log -Level INFO -Message ("[GKE-PROJECT-END] {0} Clusters={1} DurationSec={2}" -f $proj,($allClusters | Where-Object Project -eq $proj).Count,$dur)
    }

    return @{ Clusters=$allClusters; PVs=$allPvDetails; PVCs=$allPvcDetails }
}


# -------------------------
# Execution Flow
# -------------------------
$allProjects = Get-GcpProjects
# Additional normalization & case-insensitive resolution for user-specified projects
if ($Projects) {
    # Trim & dedupe input list
    $Projects = $Projects | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique
    # Build case-insensitive lookup of all accessible projects
    $allLookup = @{}
    foreach ($p in $allProjects) { $allLookup[$p.ToLower()] = $p }
    $resolved=@(); $invalid=@()
    foreach ($p in $Projects) {
        $k = $p.ToLower()
        if ($allLookup.ContainsKey($k)) { $resolved += $allLookup[$k] } else { $invalid += $p }
    }
    if ($invalid.Count -gt 0) {
        Write-Warning ("Ignoring invalid project id(s): {0}" -f ($invalid -join ', '))
    }
    $targetProjects = $resolved | Select-Object -Unique
    if (-not $targetProjects -or $targetProjects.Count -eq 0) {
        Write-Error "No valid projects found from provided -Projects list."
        Stop-Transcript | Out-Null
        exit 1
    }
} else { $targetProjects = $allProjects }
Write-Host "Targeting $($targetProjects.Count) projects." -ForegroundColor Green

$invResults = @{}
if ($Selected.VM)      { $invResults = Get-GcpVMInventory -ProjectIds $targetProjects }
if ($Selected.STORAGE) { $invResults.StorageBuckets = Get-GcpStorageInventory -ProjectIds $targetProjects }
if ($Selected.FILESHARE) {
    # Compute filestore thread cap (10 or project count, whichever is smaller)
    $fsThreads = [Math]::Min(10,[Math]::Max(1,$targetProjects.Count))
    $invResults.FileShares = Get-GcpFileShareInventory -ProjectIds $targetProjects -LightMode:$LightMode -MaxThreads $fsThreads
}
if ($Selected.DB) {
    $dbThreads = [Math]::Min(8,[Math]::Max(1,$targetProjects.Count))
    $dbResult = Get-GcpDatabaseInventory -ProjectIds $targetProjects -LightMode:$LightMode -MaxThreads $dbThreads -ProjectTimeoutSec $DbProjectTimeoutSec
    $invResults.Databases = $dbResult.Data
    $invResults.DatabaseErrors = $dbResult.Errors
}
if ($Selected.GKE) {
    # Ensure kubectl prior to inventory (best-effort)
    $kubectlPath = Ensure-Kubectl
    if (-not $kubectlPath -and $ForceKubectl) {
        Write-Host '[GKE] kubectl missing; retrying provisioning once due to -ForceKubectl.' -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        $kubectlPath = Ensure-Kubectl -Force
    }
    if ($ForceKubectl -and -not $kubectlPath) {
        Write-Error 'kubectl is required (-ForceKubectl specified) but could not be provisioned. Aborting GKE inventory.'
        Stop-Transcript | Out-Null
        exit 2
    }
    $gkeThreads = [Math]::Min(8,[Math]::Max(1,$targetProjects.Count))
    $gkeInv = Get-GcpGkeInventory -ProjectIds $targetProjects -MaxThreads $gkeThreads -LightMode:$LightMode
    $invResults.GKEClusters = $gkeInv.Clusters
    $invResults.GKEPVs      = $gkeInv.PVs
    $invResults.GKEPVCs     = $gkeInv.PVCs
}

# Global Filestore reconstruction (if we somehow ended up with zero successful shares but logs contain entries)
if ($Selected.FILESHARE) {
    $fsShares = $invResults.FileShares
    $fsGood = @()
    if ($fsShares) { $fsGood = $fsShares | Where-Object { -not ($_.Error -and $_.Error.Trim()) -and ($_.ShareName -ne '(error)') -and ($_.State -ne 'ERROR') } }
    if ((-not $fsGood) -or $fsGood.Count -eq 0) {
        if ($script:FileShareLogLines -and $script:FileShareLogLines.Count -gt 0) {
            $recoveredGlobal=@()
            foreach ($line in $script:FileShareLogLines) {
                if ($line -match '^\[FS\] Project=([^ ]+) .* Instance=([^ ]+) Share=([^ ]+) Tier=([^ ]+) Region=([^ ]+) Zone=([^ ]+) (?:CapacityGB|provisionedGib)=([0-9]+)') {
                    $gib=[int64]$Matches[7]
                    $gb=[math]::Round(($gib * 1024 * 1024 * 1024)/1e9,3)
                    $tib=[math]::Round($gib/1024,4)
                    $tb=[math]::Round($gb/1000,4)
                    $recoveredGlobal += [PSCustomObject]@{
                        Project=$Matches[1]; InstanceName=$Matches[2]; ShareName=$Matches[3]; Tier=$Matches[4]; Region=$Matches[5]; Zone=$Matches[6]; provisionedGb=$gb; provisionedGib=$gib; provisionedTb=$tb; provisionedTib=$tib; CapacityGB=$gib; Networks=''; IPAddresses=''; State='READY'; CreateTime=''; Labels=''; Protocol='NFS'; Error=''
                    }
                }
            }
            if ($recoveredGlobal.Count -gt 0) {
                Write-Host ("[FS-Global-Recover] Reconstructed {0} shares from log lines" -f $recoveredGlobal.Count) -ForegroundColor Yellow
                $invResults.FileShares = $recoveredGlobal
            } else {
                Write-Host "[FS-Global-Recover] No reconstructable [FS] log lines found." -ForegroundColor DarkYellow
            }
        } else {
            Write-Host "[FS-Global-Recover] No filestore log lines captured." -ForegroundColor DarkYellow
        }
    }
}

# ---------------------------------------------------------------
# FILESTORE INSTANCES (Cloud Filestore managed NFS)
# ---------------------------------------------------------------
function Get-GcpFilestoreInventory {
    param([string[]]$ProjectIds)
    $results = @()
    foreach ($proj in $ProjectIds) {
        try {
            # A failed lookup is NOT an empty environment. Silently continuing here reported "Found 0 Filestore
            # shares" for projects the script was never able to query.
            $res = Invoke-CVGcloudJson -Arguments @('filestore','instances','list','--project',$proj)
            if (-not $res.Ok) {
                Write-CVLog ("Filestore instance listing failed - counted as unknown, not zero: {0}" -f (($res.Error -split "`r?`n")[0])) `
                            -Level Warning -Source 'Filestore' -Scope @{ Project = $proj; Category = $(if ($res.ApiDisabled) { 'ApiDisabled' } else { 'LookupFailed' }) }
                continue
            }
            $raw = $res.Data
            if (-not $raw) { continue }
            foreach ($inst in $raw) {
                foreach ($fs in $inst.fileShares) {
                    # $fsObj rather than appending the literal straight into $results: $results is also the
                    # snapshot builder's accumulator, and the wiring extractor keys on the variable name, so
                    # sharing it unions Filestore's fields with Snapshot's and loosens both checks.
                    $fsObj = [PSCustomObject]@{
                        Project       = $proj
                        InstanceName  = $inst.name -replace '.*/instances/',''
                        Region        = $inst.location
                        Tier          = $inst.tier
                        State         = $inst.state
                        CapacityGB    = [math]::Round($fs.capacityGb, 2)
                        CapacityTB    = [math]::Round($fs.capacityGb / 1000, 4)
                        ShareName     = $fs.name
                        Protocol      = if ($inst.protocol) { $inst.protocol } else { 'NFS' }
                        Networks      = ($inst.networks | ForEach-Object { $_.network }) -join ';'
                        CreateTime    = $inst.createTime
                    }
                    $results += $fsObj
                }
            }
        } catch { Write-Log "Filestore inventory failed for project ${proj}: $_" -Level WARN }
    }
    return $results
}

# ---------------------------------------------------------------
# DISK SNAPSHOTS (backup coverage proxy)
# ---------------------------------------------------------------
# Projects whose snapshot listing failed. Consumed by the resilience pass so their disks/VMs score snapshot
# coverage as Unknown rather than as a confirmed gap.
$script:SnapshotLookupFailed = @{}

# ...and the POSITIVE marker, which is the one the resilience pass actually reads. $SnapshotLookupFailed answers
# "did an attempt fail?", which is not the same question as "do we know anything?" - it stayed empty in two cases
# that both produced a fabricated measured gap:
#   1. -Types without SNAPSHOT: Get-GcpSnapshotInventory never runs at all, so nothing is ever marked failed and
#      EVERY disk and VM in the run reported XRegionBackup = FALSE - a scored gap for a signal never looked at.
#   2. an exception rather than a non-Ok result: the catch below logged and continued without marking the project.
# Keying off "collected" instead means a project has to be positively proven readable to be scored.
$script:SnapshotCollected = @{}

function Get-GcpSnapshotStatus {
    <#
      .SYNOPSIS  Ok | Failed | Skipped for one project's snapshot listing - why a snapshot signal is blank.
      .DESCRIPTION Every blank in gcp_resilience_signals_*.csv used to be unattributable: "API disabled",
                   "permission denied", "-Types omitted SNAPSHOT" and "not implemented for GCP" were
                   indistinguishable. This is the fact about the COLLECTION, not a judgement about the resource.
                   Only these three values are legal - Set-CVCollectionStatus's ValidateSet defines them.
    #>
    param([string]$Project)
    if ($script:SnapshotCollected[$Project])    { return 'Ok' }
    if ($script:SnapshotLookupFailed[$Project]) { return 'Failed' }
    return 'Skipped'   # never attempted: -Types without SNAPSHOT, or the project was not reached
}

function Get-GcpSnapshotInventory {
    param([string[]]$ProjectIds)
    $results = @()
    foreach ($proj in $ProjectIds) {
        try {
            # Snapshots are the backup-coverage signal for disks and VMs, so a swallowed failure here does not
            # just lose a row - it downgrades every disk in the project to "no snapshots" in the resilience score.
            $res = Invoke-CVGcloudJson -Arguments @('compute','snapshots','list','--project',$proj)
            if (-not $res.Ok) {
                Write-CVLog ("Snapshot listing failed - disks in this project will score snapshot coverage as Unknown: {0}" -f (($res.Error -split "`r?`n")[0])) `
                            -Level Warning -Source 'Snapshot' -Scope @{ Project = $proj; Category = $(if ($res.ApiDisabled) { 'ApiDisabled' } else { 'LookupFailed' }) }
                $script:SnapshotLookupFailed[$proj] = $true
                continue
            }
            # The listing succeeded. Mark it BEFORE the empty-result check: a project with genuinely zero
            # snapshots is a measured zero, and its disks must score a real gap rather than Unknown.
            $script:SnapshotCollected[$proj] = $true
            $raw = $res.Data
            if (-not $raw) { continue }
            foreach ($snap in $raw) {
                $results += [PSCustomObject]@{
                    Project         = $proj
                    SnapshotName    = $snap.name
                    SourceDisk      = ($snap.sourceDisk -replace '.*/disks/','')
                    SourceDiskZone  = if ($snap.sourceDisk -match '/zones/([^/]+)/') { $Matches[1] } else { 'Unknown' }
                    Region          = if ($snap.sourceDisk -match '/zones/([^/]+)/') { $Matches[1] -replace '-[a-z]$','' } else { 'Unknown' }
                    StorageGB       = [math]::Round($snap.storageBytes / 1e9, 2)
                    StorageTB       = [math]::Round($snap.storageBytes / 1e12, 4)
                    DiskSizeGB      = $snap.diskSizeGb
                    Status          = $snap.status
                    CreationTime    = $snap.creationTimestamp
                    StorageLocations = ($snap.storageLocations -join ';')
                    Labels          = if ($snap.labels) { ($snap.labels.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ';' } else { '' }
                }
            }
        } catch {
            # Mark the failure here too. Without this an exception left the project absent from BOTH maps, so it
            # read as "collected, nothing found" and every disk in it scored a gap we never verified.
            $script:SnapshotLookupFailed[$proj] = $true
            Write-Log "Snapshot inventory failed for project ${proj}: $_" -Level WARN
        }
    }
    return $results
}

if ($Selected.FILESTORE) {
    Write-Host "Collecting Cloud Filestore instances..." -ForegroundColor Cyan
    $invResults.FilestoreInstances = Get-GcpFilestoreInventory -ProjectIds $targetProjects
    Write-Host "Found $($invResults.FilestoreInstances.Count) Filestore shares." -ForegroundColor Green
}
if ($Selected.SNAPSHOT) {
    Write-Host "Collecting disk snapshots (backup coverage)..." -ForegroundColor Cyan
    $invResults.DiskSnapshots = Get-GcpSnapshotInventory -ProjectIds $targetProjects
    Write-Host "Found $($invResults.DiskSnapshots.Count) snapshots." -ForegroundColor Green
}

# ============================================================
# CYBER RESILIENCE POSTURE REPORT  (skip with -SkipResilienceReport)
# Scores each resource's CURRENT NATIVE GCP configuration against the Cloud Resilience Control Catalog.
# Runs BEFORE the CSV exports so control columns land on every per-service CSV. Any signal we cannot collect
# (or a failed full-reach call) scores as Unknown and is excluded from the score - it never fails the run.
# ============================================================
if (-not $SkipResilienceReport -and -not $SkipDataProtection) {
  try {
    Write-CVSection 'Cyber Resilience Posture'
    $gcpControls  = Get-CVGcpResilienceControls

    # Snapshot-derived signals (presence + cross-region) per source disk, from data already collected.
    $snapByDisk = @{}
    foreach ($s in @($invResults.DiskSnapshots)) {
        if (-not $s.SourceDisk) { continue }
        $k = "$($s.Project)|$($s.SourceDisk)".ToLower()
        if (-not $snapByDisk.ContainsKey($k)) { $snapByDisk[$k] = @{ Count = 0; XRegion = $false } }
        $snapByDisk[$k].Count++
        $loc = "$($s.StorageLocations)"; $srcR = "$($s.Region)"
        if (($loc -match ',') -or ($loc -match '^(us|eu|asia)$') -or ($srcR -and $loc -and ($loc.ToLower() -notmatch [regex]::Escape($srcR.ToLower())))) {
            $snapByDisk[$k].XRegion = $true
        }
    }
    # Where the snapshot listing itself failed we know nothing about coverage, so leave the signal $null
    # (Unknown -> excluded from the score) instead of $false (a scored gap we never actually verified).
    foreach ($coll in @('AttachedDisks','UnattachedDisks')) {
        foreach ($d in @($invResults.$coll)) {
            if (-not $d) { continue }
            $e = $snapByDisk["$($d.Project)|$($d.DiskName)".ToLower()]
            # Positive marker, not the failure map - see the note at $script:SnapshotCollected.
            $xr = if (-not $script:SnapshotCollected[$d.Project]) { $null } else { [bool]($e -and $e.XRegion) }
            Add-Member -InputObject $d -NotePropertyName XRegionBackup -NotePropertyValue $xr -Force
            Add-Member -InputObject $d -NotePropertyName SnapshotDataStatus -NotePropertyValue (Get-GcpSnapshotStatus $d.Project) -Force
        }
    }
    $vmXRegion = @{}
    foreach ($d in @($invResults.AttachedDisks)) {
        if (-not $d -or -not $d.VMName) { continue }
        foreach ($vn in ([string]$d.VMName -split ',')) {
            $n = $vn.Trim(); if (-not $n) { continue }
            if ($d.XRegionBackup) { $vmXRegion["$($d.Project)|$n".ToLower()] = $true }
        }
    }
    foreach ($v in @($invResults.VMs)) {
        if (-not $v) { continue }
        $xr = if (-not $script:SnapshotCollected[$v.Project]) { $null } else { [bool]$vmXRegion["$($v.Project)|$($v.VMName)".ToLower()] }
        Add-Member -InputObject $v -NotePropertyName XRegionBackup -NotePropertyValue $xr -Force
        Add-Member -InputObject $v -NotePropertyName SnapshotDataStatus -NotePropertyValue (Get-GcpSnapshotStatus $v.Project) -Force
    }

    # Full-reach enrichment (defensive: any failure leaves the field absent -> Unknown).
    foreach ($b in @($invResults.StorageBuckets)) {
        if (-not $b -or -not $b.StorageBucket) { continue }
        try {
            $j = (& gcloud storage buckets describe "gs://$($b.StorageBucket)" --project $b.Project --format=json 2>$null) | ConvertFrom-Json
            if ($j) {
                Add-Member -InputObject $b -NotePropertyName Versioning          -NotePropertyValue ([bool]$j.versioning.enabled) -Force
                Add-Member -InputObject $b -NotePropertyName PublicAccessBlocked -NotePropertyValue ("$($j.iamConfiguration.publicAccessPrevention)" -eq 'enforced') -Force
                Add-Member -InputObject $b -NotePropertyName CmkEncrypted        -NotePropertyValue ([bool]$j.encryption.defaultKmsKeyName) -Force
                Add-Member -InputObject $b -NotePropertyName RetentionLocked     -NotePropertyValue ([bool]$j.retentionPolicy.isLocked) -Force
                Add-Member -InputObject $b -NotePropertyName SoftDeleteEnabled   -NotePropertyValue ([bool]([int]"$($j.softDeletePolicy.retentionDurationSeconds)" -gt 0)) -Force
                Add-Member -InputObject $b -NotePropertyName MultiRegion         -NotePropertyValue ("$($j.locationType)" -in 'multi-region','dual-region') -Force
            }
        } catch {}
    }
    # Filestore backups. A project whose lookup FAILED must stay Unknown ($null) rather than $false - otherwise a
    # disabled Filestore API is scored as "no backups configured", which is a fabricated gap.
    $fsBackups = @{}
    $fsLookupOk = @{}
    foreach ($p in @($targetProjects)) {
        $r = Invoke-CVGcloudJson -Arguments @('filestore','backups','list','--project',$p)
        if ($r.Ok) { $fsLookupOk[$p] = $true; $fsBackups[$p] = @($r.Data) }
        else {
            Write-CVLog ("Filestore backup lookup unavailable ({0}) - HasBackup will read Unknown" -f $(if ($r.ApiDisabled) { 'API disabled' } else { 'lookup failed' })) `
                        -Level Warning -Source 'Filestore' -Scope @{ Project = $p; Category = $(if ($r.ApiDisabled) { 'ApiDisabled' } else { 'LookupFailed' }) }
        }
    }
    # Index the backups we already fetched by the INSTANCE they came from. Every backup carries
    #   sourceInstance = projects/{p}/locations/{loc}/instances/{name}
    #   name           = projects/{p}/locations/{loc}/backups/{name}    <- the BACKUP's own location
    # so per-instance attribution and cross-region comparison both come out of the payload at hand.
    #
    # This replaces a project-scoped test - [bool](@($fsBackups[$f.Project]).Count -gt 0) - which marked EVERY
    # share in a project as protected as soon as ONE backup existed anywhere in it, on a control whose Severity
    # is Critical. That is the mirror image of a fabricated gap and worse in a pre-sales report, because it
    # silently REMOVES a real finding instead of adding a false one.
    $fsByInstance = @{}
    foreach ($p in $fsBackups.Keys) {
        foreach ($bk in @($fsBackups[$p])) {
            if (-not $bk -or -not $bk.sourceInstance) { continue }
            $srcName = ($bk.sourceInstance -split '/')[-1]
            $srcLoc  = $(if ($bk.sourceInstance -match '/locations/([^/]+)/') { $Matches[1] } else { '' })
            $bkLoc   = $(if ("$($bk.name)" -match '/locations/([^/]+)/')      { $Matches[1] } else { '' })
            $k = "$p|$srcName".ToLower()
            if (-not $fsByInstance.ContainsKey($k)) { $fsByInstance[$k] = @{ Count = 0; Locations = @() } }
            $fsByInstance[$k].Count++
            if ($bkLoc) { $fsByInstance[$k].Locations += $bkLoc }
            # Filestore BASIC tiers are ZONAL, so an instance location can be us-central1-a while its backups
            # are regional (us-central1). Comparing those raw would report every zonal instance as cross-region.
            # Strip the zone suffix with the same idiom the snapshot collector uses.
            $srcRegion = $srcLoc -replace '-[a-z]$', ''
            $bkRegion  = $bkLoc  -replace '-[a-z]$', ''
            if ($bkRegion -and $srcRegion -and ($bkRegion -ne $srcRegion)) { $fsByInstance[$k].XRegion = $true }
        }
    }
    foreach ($f in @($invResults.FilestoreInstances)) {
        if (-not $f) { continue }
        Add-Member -InputObject $f -NotePropertyName EncryptedAtRest -NotePropertyValue $true -Force   # GCP encrypts Filestore at rest by default
        if (-not $fsLookupOk.ContainsKey($f.Project)) {
            # The listing failed for this project: everything backup-derived is genuinely unknown. The status
            # column is what makes that blank readable as "denied" rather than "no backups configured".
            Add-Member -InputObject $f -NotePropertyName HasBackup     -NotePropertyValue $null -Force
            Add-Member -InputObject $f -NotePropertyName BackupXRegion -NotePropertyValue $null -Force
            Add-Member -InputObject $f -NotePropertyName FilestoreBackupLocations -NotePropertyValue $null -Force
            Add-Member -InputObject $f -NotePropertyName BackupDataStatus -NotePropertyValue 'Failed' -Force
            continue
        }
        Add-Member -InputObject $f -NotePropertyName BackupDataStatus -NotePropertyValue 'Ok' -Force
        $e = $fsByInstance["$($f.Project)|$($f.InstanceName)".ToLower()]
        Add-Member -InputObject $f -NotePropertyName HasBackup     -NotePropertyValue ([bool]($e -and $e.Count -gt 0)) -Force
        Add-Member -InputObject $f -NotePropertyName BackupXRegion -NotePropertyValue ([bool]($e -and $e.XRegion))     -Force
        # A measured absence is the token 'None', never blank - blank means "not collected".
        $fsLocs = $(if ($e -and $e.Locations.Count) { (($e.Locations | Sort-Object -Unique) -join ';') } else { 'None' })
        Add-Member -InputObject $f -NotePropertyName FilestoreBackupLocations -NotePropertyValue $fsLocs -Force
    }

    # Backup for GKE. `gcloud container backup-restore` is beta-only today: on GA it fails with
    # "Invalid choice: 'backup-restore'", which the previous code swallowed - so HasBackupPlan was always $false
    # and every gke-backup control reported a gap that had never actually been checked. Resolve the release track
    # once (GA first, so this keeps working when the command graduates) and reuse it across projects.
    $gkeBackups   = @{}
    $gkeLookupOk  = @{}
    $gkeCommandMissing = $false
    $gkeBrTrack   = $null
    foreach ($p in @($targetProjects)) {
        $gkeArgs = @('container','backup-restore','backup-plans','list','--project',$p,'--location','-')
        $r = if ($null -ne $gkeBrTrack) { Invoke-CVGcloudJsonAnyTrack -Arguments $gkeArgs -PreferTrack $gkeBrTrack }
             else                       { Invoke-CVGcloudJsonAnyTrack -Arguments $gkeArgs }
        if ($r.Ok) { $gkeBrTrack = $r.Track; $gkeLookupOk[$p] = $true; $gkeBackups[$p] = @($r.Data) }
        else {
            if ($r.CommandMissing) { $gkeCommandMissing = $true }   # drives Skipped-vs-Failed on the row below
            if (-not $r.CommandMissing) { $gkeBrTrack = $r.Track }
            $why = if ($r.CommandMissing) { 'command not available on any release track' }
                   elseif ($r.ApiDisabled) { 'Backup for GKE API disabled' }
                   else { 'lookup failed' }
            Write-CVLog "Backup for GKE lookup unavailable ($why) - HasBackupPlan will read Unknown" `
                        -Level Warning -Source 'GKE' -Scope @{ Project = $p; Category = $(if ($r.ApiDisabled) { 'ApiDisabled' } else { 'LookupFailed' }) }
        }
    }
    # Index plans by the CLUSTER they protect. Each plan carries
    #   cluster = projects/{p}/locations/{loc}/clusters/{name}
    #   name    = projects/{p}/locations/{loc}/backupPlans/{name}   <- the PLAN's own location
    #
    # Same defect as Filestore above and the same severity: HasBackupPlan was project-scoped, so one plan
    # anywhere in a project marked EVERY cluster in it as protected and suppressed gke-backup (Critical) for
    # every unprotected cluster alongside it.
    $gkeByCluster = @{}
    foreach ($p in $gkeBackups.Keys) {
        foreach ($plan in @($gkeBackups[$p])) {
            if (-not $plan -or -not $plan.cluster) { continue }
            # A deactivated plan protects nothing.
            if ("$($plan.state)" -eq 'DEACTIVATED' -or $plan.deactivated -eq $true) { continue }
            $clName  = ($plan.cluster -split '/')[-1]
            $clLoc   = $(if ($plan.cluster -match '/locations/([^/]+)/') { $Matches[1] } else { '' })
            $planLoc = $(if ("$($plan.name)" -match '/locations/([^/]+)/') { $Matches[1] } else { '' })
            $k = "$p|$clName".ToLower()
            if (-not $gkeByCluster.ContainsKey($k)) { $gkeByCluster[$k] = @{ Count = 0; Locations = @() } }
            $gkeByCluster[$k].Count++
            if ($planLoc) { $gkeByCluster[$k].Locations += $planLoc }
            # Plans are regional; a zonal cluster's location is us-central1-a. Normalise both ends.
            $clRegion   = $clLoc   -replace '-[a-z]$', ''
            $planRegion = $planLoc -replace '-[a-z]$', ''
            if ($planRegion -and $clRegion -and ($planRegion -ne $clRegion)) { $gkeByCluster[$k].XRegion = $true }
        }
    }
    foreach ($g in @($invResults.GKEClusters)) {
        if (-not $g) { continue }
        if (-not $gkeLookupOk.ContainsKey($g.Project)) {
            Add-Member -InputObject $g -NotePropertyName HasBackupPlan -NotePropertyValue $null -Force
            Add-Member -InputObject $g -NotePropertyName BackupXRegion -NotePropertyValue $null -Force
            Add-Member -InputObject $g -NotePropertyName GkeBackupPlanLocations -NotePropertyValue $null -Force
            # 'Skipped' when the command exists on no release track (nothing was ever attempted against the
            # API); 'Failed' when it was attempted and denied or errored. The classification is already computed
            # by Invoke-CVGcloudJsonAnyTrack - it was only being logged, never carried onto the row.
            $gkeStatus = $(if ($gkeCommandMissing) { 'Skipped' } else { 'Failed' })
            Add-Member -InputObject $g -NotePropertyName GkeBackupDataStatus -NotePropertyValue $gkeStatus -Force
            continue
        }
        Add-Member -InputObject $g -NotePropertyName GkeBackupDataStatus -NotePropertyValue 'Ok' -Force
        $e = $gkeByCluster["$($g.Project)|$($g.ClusterName)".ToLower()]
        Add-Member -InputObject $g -NotePropertyName HasBackupPlan -NotePropertyValue ([bool]($e -and $e.Count -gt 0)) -Force
        Add-Member -InputObject $g -NotePropertyName BackupXRegion -NotePropertyValue ([bool]($e -and $e.XRegion))     -Force
        $gkeLocs = $(if ($e -and $e.Locations.Count) { (($e.Locations | Sort-Object -Unique) -join ';') } else { 'None' })
        Add-Member -InputObject $g -NotePropertyName GkeBackupPlanLocations -NotePropertyValue $gkeLocs -Force
    }

    # Evaluate each resource type; append Ctl_*/ResilienceScore/ResilienceGaps columns onto the inventory rows.
    $collections = @(
        # Get-GcpDatabaseInventory smuggles collection FAILURES through the data channel as synthetic rows with
        # Type='Error' (reliably one per project when the bq CLI is missing). Unfiltered they became phantom
        # Database resources in the signals CSV with SizeGB=0 and every control Unknown, inflating the exported
        # resource count. The CSV exports already filter them the same way; this is the export that did not.
        @{ Type='Database';  Set=$gcpControls.Database
           Rows=@($invResults.Databases | Where-Object { $_ -and $_.Type -ne 'Error' -and -not ($_.Error -and "$($_.Error)".Trim()) }) }
        @{ Type='VM';        Set=$gcpControls.VM;        Rows=@($invResults.VMs) }
        @{ Type='Disk';      Set=$gcpControls.Disk;      Rows=(@($invResults.AttachedDisks) + @($invResults.UnattachedDisks)) }
        @{ Type='Storage';   Set=$gcpControls.Storage;   Rows=@($invResults.StorageBuckets) }
        @{ Type='Filestore'; Set=$gcpControls.Filestore; Rows=@($invResults.FilestoreInstances) }
        @{ Type='GKE';       Set=$gcpControls.GKE;       Rows=@($invResults.GKEClusters) }
    )
    # Name and size are the only genuinely per-type fields; resource group/region/id are probed by New-CVSignalRow.
    $gcpSignalFields = @{
        # 'Name', not 'InstanceName': every DB builder ($items - CloudSQL, AlloyDB, Spanner, BigQuery) sets
        # Name. InstanceName belongs to Filestore rows, so this mapping left ResourceName blank on every
        # database row in gcp_resilience_signals_*.csv - the backend could not identify the resource at all.
        Database  = @{ Name = 'Name';  SizeGB = 'StorageGB' }
        VM        = @{ Name = 'VMName';        SizeGB = 'VMDiskSizeGB' }
        Disk      = @{ Name = 'DiskName';      SizeGB = 'SizeGB' }
        Storage   = @{ Name = 'StorageBucket'; SizeGB = 'UsedCapacityGB' }
        Filestore = @{ Name = 'ShareName';     SizeGB = 'CapacityGB'; Parent = 'InstanceName' }
        GKE       = @{ Name = 'ClusterName';   SizeGB = 'PersistentVolumeCapacityGB' }
    }
    $gcpSignalMap = Get-CVSignalFieldMap -ControlSets $gcpControls
    $signalRows   = New-Object System.Collections.Generic.List[psobject]
    $resilShownErr = $false
    foreach ($c in $collections) {
        if (-not $c.Set) { continue }
        foreach ($row in $c.Rows) {
            if (-not $row) { continue }
            # Isolate per-row failures so one problematic resource can't sink the whole report.
            try {
                # No evaluation: controls declare WHICH fields are signals; thresholds belong to the backend.
                # Ctl_*/ResilienceScore are no longer written onto the inventory rows either.
                $signalRows.Add((New-CVSignalRow -Resource $row -ResourceType $c.Type `
                                    -SignalFields $gcpSignalMap[$c.Type] -FieldMap $gcpSignalFields[$c.Type]))
            } catch {
                if (-not $resilShownErr) {
                    $resilShownErr = $true
                    Write-Host ("[Resilience] signal export error on a $($c.Type) row: $($_.Exception.GetType().Name): $($_.Exception.Message)") -ForegroundColor DarkYellow
                }
            }
        }
    }

    # No score is printed - a score is a judgement, and the export is deliberately judgement-free.

    # One file: every resource with a gap or an incomplete assessment, ranked. The static control catalog and the
    # per-category rollup are no longer written - neither told you WHICH resources to go look at.
    if ($signalRows.Count) {
        Sort-CVSignalRows -Rows $signalRows |
            Export-CVCsv -Path (Join-Path $outDir ("gcp_resilience_signals_" + $dateStr + ".csv")) `
                         -PreferredOrder (Get-CVSignalColumns -ControlSets $gcpControls) -KeepDeclaredColumns
        Write-CVLog ("Resilience signals: {0} resource(s) exported across {1} resource type(s)." -f `
                     $signalRows.Count, @($signalRows | Select-Object -ExpandProperty ResourceType -Unique).Count) `
                    -Level Info -Source 'Resilience'
        Write-Host "gcp_resilience_signals_$dateStr.csv written to $outDir" -ForegroundColor Cyan
    } else {
        Write-CVLog "No resources of an assessed type were found - no signals CSV written." -Level Info -Source 'Resilience'
    }
  } catch {
    Write-CVLog "Resilience report failed: $($_.Exception.Message)" -Level Warning -Source 'Resilience'
    # Surface the exact location (console-only mode has no structured log file; this reaches the transcript).
    Write-Host ("[Resilience] $($_.Exception.GetType().Name): $($_.Exception.Message) :: " + ($_.ScriptStackTrace -replace "`r?`n", ' <- ')) -ForegroundColor DarkYellow
  }
}

# ============================================================
# CLOUD REWIND SIZING (GCP)  -  skip with -SkipCloudRewind
# Self-contained sweep via Cloud Asset Inventory (gcloud asset search-all-resources) per project, classified
# against the derived billable taxonomy. Emits one row per billable resource + a billable-vs-non-billable summary.
# Honors -Labels (client-side). Independent of the Data Protection inventory. Requires the Cloud Asset API.
# ============================================================
if (-not $SkipCloudRewind) {
  try {
    Write-CVSection 'Cloud Rewind Sizing'
    $crTax           = Get-CVGcpCloudRewindTaxonomy
    $crAssetTypes    = (Get-CVGcpCloudRewindAssetTypes) -join ','
    $crFilterTagKeys = Get-CVFilterTagKeys -FilterTags $Labels
    $crRows          = New-Object System.Collections.Generic.List[psobject]
    $crClassified    = New-Object System.Collections.Generic.List[psobject]

    foreach ($proj in @($targetProjects)) {
        $crRes = Invoke-CVGcloudJson -Arguments @('asset','search-all-resources',"--scope=projects/$proj","--asset-types=$crAssetTypes")
        if (-not $crRes.Ok) {
            # Report what gcloud actually said. Guessing "is the Cloud Asset API enabled?" hid a completely
            # different root cause (a deleted core/project being used as the quota project) across every project.
            $crWhy = if ($crRes.ApiDisabled) { 'Cloud Asset API not enabled' } else { 'asset search failed' }
            $crDetail = ($crRes.Error -split "`r?`n" | Where-Object { $_ -match '\S' } | Select-Object -First 1)
            Write-CVLog "Cloud Rewind: $crWhy in $proj - $crDetail" -Level Warning -Source 'CloudRewind' `
                        -Scope @{ Project = $proj; Category = $(if ($crRes.ApiDisabled) { 'ApiDisabled' } else { 'LookupFailed' }) }
            continue
        }
        $assets = @($crRes.Data)

        foreach ($asset in $assets) {
            $at = $asset.assetType
            $billable = Get-CVCloudRewindBillable -ResourceType $at -Taxonomy $crTax
            if ($null -eq $billable) { continue }

            $labelHash = @{}
            if ($asset.labels) { foreach ($p in $asset.labels.PSObject.Properties) { $labelHash[$p.Name] = $p.Value } }
            if (-not (Test-CVResourceMatch -Tags $labelHash -FilterTags $Labels)) { continue }

            $class = Get-CVGcpCloudRewindClass -AssetType $at
            $crClassified.Add([pscustomobject]@{ Account = $proj; AccountName = $proj; Billable = [bool]$billable; ResourceClass = $class })

            if ($billable) {
                $rname = if ($asset.displayName) { $asset.displayName } else { ("$($asset.name)" -split '/')[-1] }
                $crRows.Add( (New-CVCloudRewindRow -Fields @{
                    CloudProvider    = 'GCP'
                    Account          = $proj
                    AccountName      = $proj
                    TenantOrOrg      = ''
                    Region           = $asset.location
                    ResourceGroup    = ''
                    ResourceName     = $rname
                    ResourceId       = $asset.name
                    ResourceType     = $at
                    ResourceState    = ''
                    BillableReason   = (Get-CVGcpCloudRewindReason -AssetType $at)
                    VpcOrVNet        = ''
                    Subnet           = ''
                    AvailabilityZone = $asset.location
                    HasPublicIp      = ''
                    DiscoveredAt     = $dateStr
                } -Tags $labelHash -FilterTagKeys $crFilterTagKeys) )
            }
        }
    }

    $crCsv = Join-Path $outDir ("gcp_cloudrewind_" + $dateStr + ".csv")
    if ($crRows.Count) {
        $crRows | Export-Csv -Path $crCsv -NoTypeInformation
        Write-Host "gcp_cloudrewind_$dateStr.csv ($($crRows.Count) billable resources) written to $outDir" -ForegroundColor Cyan
    } else {
        Write-CVLog 'Cloud Rewind: no billable resources found for the current scope.' -Level Warning -Source 'CloudRewind'
    }

    $crSummary = Get-CVCloudRewindSummary -Classified $crClassified
    if (@($crSummary).Count) {
        $crSummary | Export-Csv -Path (Join-Path $outDir ("gcp_cloudrewind_summary_" + $dateStr + ".csv")) -NoTypeInformation
        $crTB  = (@($crSummary) | Measure-Object TotalBillableResources -Sum).Sum
        $crTNB = (@($crSummary) | Measure-Object TotalNonBillableResources -Sum).Sum
        Write-CVLog ("Cloud Rewind: {0} billable, {1} non-billable resources across {2} project(s)" -f $crTB, $crTNB, @($crSummary).Count) -Level Success -Source 'CloudRewind'
        Write-Host "gcp_cloudrewind_summary_$dateStr.csv written to $outDir" -ForegroundColor Cyan
    }
  } catch {
    Write-CVLog "Cloud Rewind (GCP) pass failed: $($_.Exception.Message)" -Level Warning -Source 'CloudRewind'
    Write-Host ("[CloudRewind] $($_.Exception.GetType().Name): $($_.Exception.Message) :: " + ($_.ScriptStackTrace -replace "`r?`n", ' <- ')) -ForegroundColor DarkYellow
  }
}

if ($Selected.DB -and $invResults.Databases -and (@($invResults.Databases)).Count) {
    $dbAll      = @($invResults.Databases)
    $dbSuccess  = @($dbAll | Where-Object { -not ($_.Error -and $_.Error.Trim()) -and $_.Type -ne 'Error' })
    $dbErrors   = @($dbAll | Where-Object { ($_.Error -and $_.Error.Trim()) -or $_.Type -eq 'Error' })

    # Cloud SQL
    $cloudSql = $dbSuccess | Where-Object Type -eq 'CloudSQL'
    if ($cloudSql.Count -gt 0) {
        $cloudSqlCsv = Join-Path $outDir ("gcp_cloudsql_instances_" + $dateStr + ".csv")
        $cloudSql | Sort-Object Project,Name | Export-Csv -Path $cloudSqlCsv -NoTypeInformation
        Write-Host "gcp_cloudsql_instances_$dateStr.csv file has been written to $outDir" -ForegroundColor Cyan
    }

    # Spanner
    # Normalize to array so a single instance does not collapse into a lone PSCustomObject (which would make .Count $null)
    $spanner = @($dbSuccess | Where-Object Type -eq 'SpannerInstance')
    if ($spanner.Count -gt 0) {
        $spannerCsv = Join-Path $outDir ("gcp_spanner_instances_" + $dateStr + ".csv")
        $spanner | Sort-Object Project,Name | Export-Csv -Path $spannerCsv -NoTypeInformation
        Write-Host "gcp_spanner_instances_$dateStr.csv file has been written to $outDir" -ForegroundColor Cyan
    }
    else {
        Write-Host '[Spanner] No instances discovered; CSV not generated (expected if API disabled or permission denied).' -ForegroundColor Yellow
    }

    # BigQuery
    # Normalize BigQuery datasets to an array so single-item results don't drop the Count property
    $bigQuery = @($dbSuccess | Where-Object Type -eq 'BigQueryDataset')
    # Always create the dataset CSV if we even attempted DB work (so downstream processes can rely on file existence)
    $bqCsv = Join-Path $outDir ("gcp_bigquery_datasets_" + $dateStr + ".csv")
    if ($bigQuery.Count -gt 0) {
        $bigQuery | Sort-Object Project,Name | Export-Csv -Path $bqCsv -NoTypeInformation
    } else {
        # No datasets discovered - emit a header-only file (downstream relies on it existing).
        'Type,Project,Name,Region,Engine,StorageGB,TotalPhysicalSizeGB,TotalLogicalSizeGB,TableCount,LargestTable,LargestTablePhysicalGB,LargestTableLogicalGB,SizeSource,SizeStatus,SizeNote,Error' | Out-File -FilePath $bqCsv -Encoding utf8
    }
    Write-Host "gcp_bigquery_datasets_$dateStr.csv file has been written to $outDir" -ForegroundColor Cyan
    if ($script:CVGcpBqProjectStatuses.Count -gt 0) {
        $bqStatusCsv = Join-Path $outDir ("gcp_project_status_bigquery_" + $dateStr + ".csv")
        $script:CVGcpBqProjectStatuses | Sort-Object Project | Export-Csv -Path $bqStatusCsv -NoTypeInformation
        Write-Host "gcp_project_status_bigquery_$dateStr.csv file has been written to $outDir" -ForegroundColor Cyan
    }

    # gcp_bigquery_tables_*.csv is no longer produced: per-table sizes came from one `bq show` per table, which is
    # what made BigQuery sizing take hours. Cloud Monitoring labels only the 100 largest tables per dataset; the
    # largest one is carried on the dataset row (LargestTable / LargestTableLogicalGB).

    # AlloyDB Clusters
    $alloyClusters = $dbSuccess | Where-Object Type -eq 'alloydbcluster'
    if ($alloyClusters.Count -gt 0) {
        $alloyCsv = Join-Path $outDir ("gcp_alloydb_clusters_" + $dateStr + ".csv")
        $alloyClusters | Sort-Object Project,Name | Export-Csv -Path $alloyCsv -NoTypeInformation
        Write-Host "gcp_alloydb_clusters_$dateStr.csv file has been written to $outDir" -ForegroundColor Cyan
    }
}

# -------------------------
# Output CSVs
# -------------------------
Update-CVProgress -Id 'output' -Activity "Generating Output Files" -Status "Exporting CSV files..." -PercentComplete 0



# ---------------------------------------------------------------------------
# Protection enrichment: roll disk snapshots up onto each disk row, then aggregate
# those onto the owning VM, so every resource carries its own snapshot coverage.
# Pure join over data already collected this run - no additional API calls.
# ---------------------------------------------------------------------------
$snapByDisk = @{}
foreach ($s in @($invResults.DiskSnapshots)) {
    if (-not $s -or -not $s.SourceDisk) { continue }
    $k = "$($s.Project)|$($s.SourceDisk)".ToLower()
    if (-not $snapByDisk.ContainsKey($k)) { $snapByDisk[$k] = @{ Count = 0; GB = 0.0; Latest = $null } }
    $e = $snapByDisk[$k]
    $e.Count++
    $e.GB += [double]$s.StorageGB
    $parsed = [datetime]::MinValue
    if ($s.CreationTime -and [datetime]::TryParse([string]$s.CreationTime, [ref]$parsed)) {
        if ($null -eq $e.Latest -or $parsed -gt $e.Latest) { $e.Latest = $parsed }
    }
}

# Per-disk coverage
foreach ($coll in @('AttachedDisks','UnattachedDisks')) {
    foreach ($d in @($invResults.$coll)) {
        if (-not $d -or -not $d.DiskName) { continue }
        $e   = $snapByDisk["$($d.Project)|$($d.DiskName)".ToLower()]
        $cnt = 0; $gb = 0.0; $latest = ''
        if ($e) {
            $cnt = $e.Count
            $gb  = [math]::Round($e.GB, 2)
            if ($e.Latest) { $latest = $e.Latest.ToString('yyyy-MM-dd') }
        }
        # TB only - the sizing spreadsheet takes TB, and mixed units invite copy/paste errors.
        Add-Member -InputObject $d -NotePropertyName SnapshotsEnabled   -NotePropertyValue ($cnt -gt 0) -Force
        Add-Member -InputObject $d -NotePropertyName SnapshotCount      -NotePropertyValue $cnt -Force
        Add-Member -InputObject $d -NotePropertyName SnapshotSizeTB     -NotePropertyValue ([math]::Round($gb / 1000, 4)) -Force
        Add-Member -InputObject $d -NotePropertyName LatestSnapshotDate -NotePropertyValue $latest -Force
    }
}

# Aggregate the attached disks' coverage onto each VM
$snapByVm = @{}
foreach ($d in @($invResults.AttachedDisks)) {
    if (-not $d -or -not $d.VMName) { continue }
    # Read the aggregate straight from the lookup so no GB-denominated column has to exist on the disk row.
    $e = $snapByDisk["$($d.Project)|$($d.DiskName)".ToLower()]
    if (-not $e) { continue }
    foreach ($vmn in ([string]$d.VMName -split ',')) {
        $n = $vmn.Trim()
        if (-not $n) { continue }
        $k = "$($d.Project)|$n".ToLower()
        if (-not $snapByVm.ContainsKey($k)) { $snapByVm[$k] = @{ Count = 0; GB = 0.0 } }
        $snapByVm[$k].Count += $e.Count
        $snapByVm[$k].GB    += $e.GB
    }
}
foreach ($v in @($invResults.VMs)) {
    if (-not $v) { continue }
    $a   = $snapByVm["$($v.Project)|$($v.VMName)".ToLower()]
    $cnt = 0; $gb = 0.0
    if ($a) { $cnt = $a.Count; $gb = [math]::Round($a.GB, 2) }
    # TB only - the sizing spreadsheet takes TB, and mixed units invite copy/paste errors.
    Add-Member -InputObject $v -NotePropertyName SnapshotsEnabled -NotePropertyValue ($cnt -gt 0) -Force
    Add-Member -InputObject $v -NotePropertyName SnapshotCount    -NotePropertyValue $cnt -Force
    Add-Member -InputObject $v -NotePropertyName SnapshotSizeTB   -NotePropertyValue ([math]::Round($gb / 1000, 4)) -Force
}

# One CSV per service type, one row per instance, full metadata - matching the Azure layout.
# Summary / diagnostic content is deliberately NOT embedded in these data files; it lives in the
# separate gcp_project_status_* and gcp_inventory_summary_* CSVs.
if ($Selected.VM -and $invResults.VMs -and $invResults.VMs.Count) {
    $vmCsv = Join-Path $outDir ("gcp_vm_instance_info_" + $dateStr + ".csv")
    $invResults.VMs | Export-Csv -Path $vmCsv -NoTypeInformation
    Write-Host "gcp_vm_instance_info_$dateStr.csv file has been written to $outDir" -ForegroundColor Cyan

    if ($invResults.AttachedDisks -and $invResults.AttachedDisks.Count) {
        $attachedCsv = Join-Path $outDir ("gcp_disks_attached_to_vm_instances_" + $dateStr + ".csv")
        $invResults.AttachedDisks | Export-Csv -Path $attachedCsv -NoTypeInformation
        Write-Host "gcp_disks_attached_to_vm_instances_$dateStr.csv file has been written to $outDir" -ForegroundColor Cyan
    }

    if ($invResults.UnattachedDisks -and $invResults.UnattachedDisks.Count) {
        $unattachedCsv = Join-Path $outDir ("gcp_disks_unattached_to_vm_instances_" + $dateStr + ".csv")
        $invResults.UnattachedDisks | Export-Csv -Path $unattachedCsv -NoTypeInformation
        Write-Host "gcp_disks_unattached_to_vm_instances_$dateStr.csv file has been written to $outDir" -ForegroundColor Cyan
    }
}

# Per-project collection status in its own file. This used to be appended inside the VM CSV, which
# left that file holding five different tables and made it impossible to parse as CSV.
if ($script:VmProjectStatuses) {
    $statusCsv = Join-Path $outDir ("gcp_project_status_vm_" + $dateStr + ".csv")
    $script:VmProjectStatuses |
        Select-Object Project,
                      @{ n = 'Status'; e = { if ($_.Success -eq $true -or $_.Success -eq 'True' -or $_.Success -eq 'Y') { 'Success' } else { 'Failed' } } },
                      @{ n = 'Reason'; e = {
                            if ($_.Success -eq $true -or $_.Success -eq 'True' -or $_.Success -eq 'Y') { '' }
                            elseif ($_.Timeout)         { 'Timeout' }
                            elseif ($_.PermissionIssue) { 'PermissionDenied' }
                            elseif ($_.ApiDisabled)     { 'ApiDisabled' }
                            else                        { 'Unknown' } } },
                      VMCount, DiskCount |
        Sort-Object Project |
        Export-Csv -Path $statusCsv -NoTypeInformation
    Write-Host "gcp_project_status_vm_$dateStr.csv file has been written to $outDir" -ForegroundColor Cyan
}

# Always generate Storage Bucket CSV if Storage inventory is selected and data exists
if ($Selected.STORAGE -and $invResults.StorageBuckets -and $invResults.StorageBuckets.Count) {
    $bktCsv = Join-Path $outDir ("gcp_storage_buckets_info_" + $dateStr + ".csv")
    $invResults.StorageBuckets | Export-Csv -Path $bktCsv -NoTypeInformation
    Write-Host "gcp_storage_buckets_info_$dateStr.csv file has been written to $outDir" -ForegroundColor Cyan
}

# Per-project storage collection status in its own single-table CSV (previously appended into the bucket CSV).
if ($script:StorageProjectStatuses) {
    $storageStatusCsv = Join-Path $outDir ("gcp_project_status_storage_" + $dateStr + ".csv")
    $bucketGroups = @($invResults.StorageBuckets) | Group-Object Project
    $script:StorageProjectStatuses |
        Select-Object Project,
                      @{ n = 'Status'; e = { if ($_.Success -eq 'Y') { 'Success' } else { 'Failed' } } },
                      @{ n = 'Reason'; e = {
                            if ($_.Success -eq 'Y')                                  { '' }
                            elseif ($_.Timeout -eq 'Y')                              { 'Timeout' }
                            elseif ($_.PermissionIssue -eq 'Y')                      { 'PermissionDenied' }
                            elseif ($_.Error -and $_.Error -match 'permission|denied'){ 'PermissionDenied' }
                            elseif ($_.Error -and $_.Error -match 'Timeout')          { 'Timeout' }
                            elseif ($_.Error)                                         { 'Error' }
                            else                                                      { 'Unknown' } } },
                      BucketCount,
                      @{ n = 'TotalSizeGB'; e = {
                            # Blank, not 0, when Cloud Monitoring could not be read: 0 would claim the project is empty.
                            if ($_.SizeStatus -eq 'Error') { $null } else {
                            $grp = $bucketGroups | Where-Object Name -eq $_.Project
                            $bytes = if ($grp) { ($grp.Group | Measure-Object UsedCapacityBytes -Sum).Sum } else { 0 }
                            if ($bytes) { [math]::Round($bytes / 1e9, 3) } else { 0 } } } },
                      SizeStatus, SizeError |
        Sort-Object Project |
        Export-Csv -Path $storageStatusCsv -NoTypeInformation
    Write-Host "gcp_project_status_storage_$dateStr.csv file has been written to $outDir" -ForegroundColor Cyan
}

# Always generate Filestore CSV if Filestore inventory is selected and data exists
if ($Selected.FILESHARE -and $invResults.FileShares -and (@($invResults.FileShares)).Count) {
    $fsCsv = Join-Path $outDir ("gcp_filestore_info_" + $dateStr + ".csv")
    $allFs = @($invResults.FileShares)  # normalize enumeration
    $success = @($allFs | Where-Object { -not ($_.Error -and $_.Error.Trim()) -and ($_.ShareName -ne '(error)') -and ($_.State -ne 'ERROR') })
    $fail = @($allFs | Where-Object { ($_.Error -and $_.Error.Trim()) -or ($_.ShareName -eq '(error)') -or ($_.State -eq 'ERROR') })
    $successCount = (@($success)).Count
    if ($successCount -gt 0) {
        $success = $success | Sort-Object Project, InstanceName, ShareName
        $success | Export-Csv -Path $fsCsv -NoTypeInformation
    } else {
    $dummy = [PSCustomObject]@{ Project=''; InstanceName=''; ShareName=''; Tier=''; Region=''; Zone=''; provisionedGb=''; provisionedGib=''; provisionedTb=''; provisionedTib=''; Networks=''; IPAddresses=''; State=''; CreateTime=''; Labels=''; Protocol=''; Error='' }
        @($dummy) | Export-Csv -Path $fsCsv -NoTypeInformation
        (Get-Content $fsCsv | Select-Object -First 1) | Set-Content $fsCsv
    }
    # Failed shares go to their own single-table CSV rather than being appended to the data file.
    if ((@($fail)).Count -gt 0) {
        $fsFailCsv = Join-Path $outDir ("gcp_filestore_failures_" + $dateStr + ".csv")
        $fail |
            Select-Object Project, InstanceName, ShareName, State,
                          @{ n = 'FailureCategory'; e = {
                                # gcloud returns PERMISSION_DENIED for a merely-disabled API. Separating the two
                                # matters: one is "enable this service", the other is "grant this role".
                                $m = "$($_.Error)"
                                if     ($m -match '(?i)SERVICE_DISABLED|has not been used in project|API .*not enabled|is disabled') { 'ApiDisabled' }
                                elseif ($m -match '(?i)PERMISSION_DENIED|permission|forbidden|403')                                  { 'PermissionDenied' }
                                else                                                                                                 { 'Other' } } },
                          @{ n = 'ErrorSnippet'; e = {
                                # The previous pattern cut the message at "Cloud Filestore API has not been used",
                                # which is precisely the actionable part - every row read just "PERMISSION_DENIED: ".
                                $m = ("$($_.Error)" -replace "`r?`n", ' ') -replace '\s{2,}', ' '
                                $m = ($m -split 'Google developers console API activation')[0].Trim()
                                if ($m.Length -gt 400) { $m = $m.Substring(0,397) + '...' }
                                $m } },
                          @{ n = 'ActivationUrl'; e = {
                                if ("$($_.Error)" -match '(https://console\.developers\.google\.com/apis/api/\S+)') { $Matches[1].TrimEnd('.',',') } else { '' } } } |
            Sort-Object Project, InstanceName, ShareName |
            Export-Csv -Path $fsFailCsv -NoTypeInformation
        Write-Host "gcp_filestore_failures_$dateStr.csv file has been written to $outDir" -ForegroundColor Cyan
    }
    Write-Host "Filestore CSV written: $(Split-Path $fsCsv -Leaf) (Good=$successCount Fail=$((@($fail)).Count))" -ForegroundColor Cyan
}

# GKE clusters CSV
if ($Selected.GKE -and $invResults.GKEClusters -and $invResults.GKEClusters.Count) {
    $gkeCsv = Join-Path $outDir ("gcp_gke_clusters_" + $dateStr + ".csv")
    # Order & columns
    # Full metadata - no column subsetting (Azure-style full dump per instance).
    $gkeData = $invResults.GKEClusters
    # -ExcludeProperty: _PvDetails/_PvcDetails are internal arrays used downstream in-memory. Exported, each cell
    # reads "System.Management.Automation.PSObject[]" - a column of type names. Nothing in the repo reads them.
    $gkeData | Select-Object -ExcludeProperty _PvDetails, _PvcDetails | Export-Csv -Path $gkeCsv -NoTypeInformation
    Write-Host "GKE clusters CSV written: $(Split-Path $gkeCsv -Leaf)" -ForegroundColor Cyan

    # PV CSV
    if ($invResults.GKEPVs -and $invResults.GKEPVs.Count) {
        $pvCsv = Join-Path $outDir ("gcp_gke_persistent_volumes_" + $dateStr + ".csv")
        $pvOrdered = $invResults.GKEPVs | Sort-Object Project,ClusterName,ClaimNamespace,PVName
        $pvOrdered | Export-Csv -Path $pvCsv -NoTypeInformation
        Write-Host "GKE PV CSV written: $(Split-Path $pvCsv -Leaf)" -ForegroundColor Cyan
    }
    # PVC CSV
    if ($invResults.GKEPVCs -and $invResults.GKEPVCs.Count) {
        $pvcCsv = Join-Path $outDir ("gcp_gke_persistent_volume_claims_" + $dateStr + ".csv")
        $pvcOrdered = $invResults.GKEPVCs | Sort-Object Project,ClusterName,Namespace,PVCName
        $pvcOrdered | Export-Csv -Path $pvcCsv -NoTypeInformation
        Write-Host "GKE PVC CSV written: $(Split-Path $pvcCsv -Leaf)" -ForegroundColor Cyan
    }
}



# -------------------------
# ---------------------------------------------------------------------------------------------------------
# Inventory rollup + the per-service CSVs that feed it.
#
# The rollup itself used to be ~250 lines of inline code here, emitting a 9-column schema across five tiers
# with the same arithmetic hand-written once per tier. It now lives in common/CVSizing.Summary.GCP.ps1 as a
# descriptor table driving the shared engine in common/CVSizing.Summary.ps1, which Azure and AWS also use.
# Read that file's header for what changed in the OUTPUT and why - Level/Zone, the VM disk dedupe, the fused
# Database row and the AllResources row all went away deliberately.
# ---------------------------------------------------------------------------------------------------------

$vmData = $invResults.VMs
$attached = $invResults.AttachedDisks
$bucketData = $invResults.StorageBuckets
$fileshareData = $invResults.FileShares
if ($fileshareData) { $fileshareData = $fileshareData | Where-Object { -not ($_.Error -and $_.Error.Trim()) } }
$databaseData = $invResults.Databases
if ($databaseData) { $databaseData = $databaseData | Where-Object { -not ($_.Error -and $_.Error.Trim()) -and $_.Type -ne 'Error' } }
$gkeData = $invResults.GKEClusters
$filestoreData = $invResults.FilestoreInstances
$snapshotData = $invResults.DiskSnapshots

# Filestore CSV
if ($Selected.FILESTORE -and $filestoreData -and $filestoreData.Count -gt 0) {
    $fstoreCsv = Join-Path $outDir ("gcp_filestore_instances_" + $dateStr + ".csv")
    $filestoreData | Export-Csv -Path $fstoreCsv -NoTypeInformation
    Write-Host "Filestore CSV written: $(Split-Path $fstoreCsv -Leaf)" -ForegroundColor Cyan
}

# Snapshots CSV
if ($Selected.SNAPSHOT -and $snapshotData -and $snapshotData.Count -gt 0) {
    $snapCsv = Join-Path $outDir ("gcp_disk_snapshots_" + $dateStr + ".csv")
    # Snapshot size reported in TB only (DiskSizeGB below is the SOURCE disk's size, not a snapshot size).
    $snapshotData |
        Select-Object Project,SnapshotName,SourceDisk,SourceDiskZone,Region,StorageTB,DiskSizeGB,Status,CreationTime,StorageLocations,Labels |
        Export-Csv -Path $snapCsv -NoTypeInformation
    # The snapshot total used to be appended here, and it was the only place it was published. It now has a
    # proper Disk Snapshots row in gcp_inventory_summary_*.csv instead. Appending it made `Measure-Object
    # StorageTB -Sum` over this file return exactly 2x the truth, because the total line parsed as a data row.
    Write-Host "Snapshots CSV written: $(Split-Path $snapCsv -Leaf)" -ForegroundColor Cyan
}

# ---- the rollup ------------------------------------------------------------------------------------------
# Databases are passed as FOUR separate collections rather than one, so each service gets its own row with its
# own unit and its own stated basis. $cloudSql / $spanner / $alloyClusters / $bigQuery are computed in the DB
# export block above; they are $null when that block did not run, hence the @() wrappers.
$gcpInventory = @{
    VMs               = @($vmData)
    UnattachedDisks   = @($invResults.UnattachedDisks)
    StorageBuckets    = @($bucketData)
    FileShares        = @($fileshareData)
    CloudSqlInstances = @($cloudSql)
    SpannerInstances  = @($spanner)
    AlloyDbClusters   = @($alloyClusters)
    BigQueryDatasets  = @($bigQuery)
    GKEClusters       = @($gkeData)
    DiskSnapshots     = @($snapshotData)
}
$summaryRows = @(Get-CVGcpInventorySummary -Inventory $gcpInventory -Selected $Selected `
                    -Projects @($targetProjects | ForEach-Object { [PSCustomObject]@{ Name = $_ } }))

# Guarded, unlike before. The old export was unconditional, so -Types Snapshot, -Types Filestore or
# -SkipDataProtection (which clears $Selected entirely) each shipped a gcp_inventory_summary CSV containing a
# header and twelve all-blank spacer rows, and then announced "Inventory summary exported".
if (-not $summaryRows.Count) {
    Write-CVLog 'No inventory rows for the selected types; skipping the inventory summary CSV.' -Level Warning -Source 'Summary'
} else {
    $summaryCsv = Join-Path $outDir ("gcp_inventory_summary_" + $dateStr + ".csv")
    $summaryRows | Export-Csv -Path $summaryCsv -NoTypeInformation
    Write-Host "Inventory summary exported: $(Split-Path $summaryCsv -Leaf)" -ForegroundColor Green
}

# Per-zone VM detail, as its own pure CSV. This used to be a Zone tier inside the summary above, grouping
# ATTACHED DISK rows - but regional persistent disks carry Zone = '', so their capacity fell out of every zone
# row and the zone rows summed to less than the region row above them. Measuring VM rows fixes that and makes
# this file reconcile with the summary's VM row, which measures the same property.
if ($Selected.VM) {
    $zoneRows = @(Get-CVGcpVmZoneRollup -VMs $vmData)
    if ($zoneRows.Count) {
        $zoneCsv = Join-Path $outDir ("gcp_vm_zone_rollup_" + $dateStr + ".csv")
        $zoneRows | Export-Csv -Path $zoneCsv -NoTypeInformation
        Write-Host "VM zone rollup exported: $(Split-Path $zoneCsv -Leaf)" -ForegroundColor Green
    }
}


# ============================================================
# JSON EXPORT (when OutputFormat is json or both)
# ============================================================
if ($OutputFormat -eq "json" -or $OutputFormat -eq "both") {
    Update-CVProgress -Id 'output' -Activity "Generating Output Files" -Status "Writing JSON output..." -PercentComplete 72

    $jsonSummary = @{}
    $allWorkloads = @{}

    # $AllVMs / $AllBuckets were never assigned anywhere in this script, so gcp_sizing_*.json silently shipped
    # with no VMs and no buckets - the two largest workloads - and nobody saw an error because a $null guard
    # reads as "none discovered". The property names were wrong too: VM rows carry VMDiskSizeGB and bucket rows
    # carry UsedCapacityGB, so even with the variables bound both totals would have been 0.
    $jsonVMs     = @($invResults.VMs)
    $jsonBuckets = @($invResults.StorageBuckets)
    if ($jsonVMs.Count -gt 0) {
        $allWorkloads["gcp_vms"]         = $jsonVMs
        $jsonSummary["VM"]               = @{ count = $jsonVMs.Count; total_storage_gb = [double](($jsonVMs | Measure-Object -Property VMDiskSizeGB -Sum -ErrorAction SilentlyContinue).Sum); notes = "" }
    }
    if ($jsonBuckets.Count -gt 0) {
        $allWorkloads["gcp_storage"]     = $jsonBuckets
        $jsonSummary["Storage"]          = @{ count = $jsonBuckets.Count; total_storage_gb = [double](($jsonBuckets | Measure-Object -Property UsedCapacityGB -Sum -ErrorAction SilentlyContinue).Sum); notes = "" }
    }
    if ($filestoreData -and $filestoreData.Count -gt 0) {
        $allWorkloads["gcp_filestore"]   = @($filestoreData)
        $jsonSummary["Filestore"]        = @{ count = $filestoreData.Count; total_storage_gb = [double](($filestoreData | Measure-Object -Property CapacityGB -Sum -ErrorAction SilentlyContinue).Sum); notes = "" }
    }
    if ($snapshotData -and $snapshotData.Count -gt 0) {
        $allWorkloads["gcp_snapshots"]   = @($snapshotData)
        $jsonSummary["Snapshot"]         = @{ count = $snapshotData.Count; total_storage_gb = [double](($snapshotData | Measure-Object -Property StorageGB -Sum -ErrorAction SilentlyContinue).Sum); notes = "" }
    }

    $jsonDoc = @{
        metadata = @{
            cloud          = "gcp"
            projects       = @($targetProjects)   # $activeProjects was never assigned - this shipped as []
            generated_at   = (Get-Date -Format "o")
            script_version = "2.0"
        }
        summary   = $jsonSummary
        workloads = $allWorkloads
    }

    $jsonPath = Join-Path $outDir ("gcp_sizing_" + $dateStr + ".json")
    $jsonDoc | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8
    Write-Host "gcp_sizing_$dateStr.json written to $outDir" -ForegroundColor Cyan
}

# -------------------------
# Finalize log, then ZIP
# -------------------------
Update-CVProgress -Id 'output' -Activity "Generating Output Files" -Status "Finalizing log..." -PercentComplete 75
# Projects with no bucket/BigQuery sizes, grouped by cause, each with the command or role that fixes it. Printed
# before the summary so it lands in the transcript. Without it, gcp_inventory_summary silently under-reported.
$monLines = @(Format-CVGcpMonitoringFailureReport -Failures $script:CVGcpMonitoringFailures)
if ($monLines.Count) {
    Write-CVLog $monLines[0] -Level Warning -Source 'Monitoring'
    $monLines | Select-Object -Skip 1 | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
}

# Aggregated diagnostics summary (warning/error counts + which projects/services were skipped and why).
Write-CVSummary -Title 'GCP Sizing Run Summary'
Stop-Transcript | Out-Null   # end transcript (separate from detail log)


Update-CVProgress -Id 'output' -Activity "Generating Output Files" -Status "Creating ZIP archive..." -PercentComplete 90
$zipFile = $runPaths.ZipPath
Add-Type -AssemblyName System.IO.Compression.FileSystem

# The transcript lives in Logs/, outside $outDir, so zipping $outDir alone silently shipped an archive with no
# log in it - while the closing message promised one. Copy it in first; the log is the whole point when a
# customer sends this back to explain a failed run.
try {
    if ($transcriptFile -and (Test-Path -LiteralPath $transcriptFile)) {
        Copy-Item -LiteralPath $transcriptFile -Destination (Join-Path $outDir (Split-Path $transcriptFile -Leaf)) -Force -ErrorAction Stop
    }
} catch {
    Write-Warning "Could not stage the run log into the output folder: $($_.Exception.Message)"
}

# The closing messages below are GATED on this. They used to run unconditionally after a catch that only
# emitted a Write-Warning, so a full disk or a file locked by a stalled child produced two confident
# contradictions - "Results in <path>.zip" and "All output files ... are compressed into the ZIP archive" -
# a few lines under a warning saying the opposite. A customer reads the green text, sends nothing, and the run
# summary reports no error at all. Nothing is lost either way, because the loose files are kept.
$zipOk = $false
try {
    $onDisk = @(Get-ChildItem -LiteralPath $outDir -File -Recurse -ErrorAction Stop)
    if (-not $onDisk.Count) {
        Write-CVLog "Output directory is empty; no archive created: $outDir" -Level Error -Source 'Archive'
    } else {
        if (Test-Path -LiteralPath $zipFile) { Remove-Item -LiteralPath $zipFile -Force }
        [IO.Compression.ZipFile]::CreateFromDirectory($outDir, $zipFile)
        # Verify rather than assume: CreateFromDirectory can throw AFTER creating a partial file.
        if (Test-Path -LiteralPath $zipFile) {
            $zipOk = $true
            Write-Host ("ZIP archive created: {0} ({1} file(s), {2:N0} bytes)" -f $zipFile, $onDisk.Count, (Get-Item -LiteralPath $zipFile).Length) -ForegroundColor Green
        } else {
            Write-CVLog "Archive creation reported success but the file is not there: $zipFile" -Level Error -Source 'Archive'
        }
    }
} catch {
    # Write-CVLog, not Write-Warning: a warning never reaches Add-CVDiagnostic, so the run summary counted zero
    # errors for a run that produced no deliverable.
    Write-CVLog "Failed to create ZIP archive" -Level Error -Source 'Archive' -Exception $_
}

# The per-run output folder is kept under Output/ (loose CSVs/JSON) alongside the ZIP - nothing is deleted.

Complete-CVProgress -Id 'output'
if ($zipOk) {
    Write-Host "`nInventory complete. Results in $zipFile`n" -ForegroundColor Green
    if ($OutputFormat -eq "json" -or $OutputFormat -eq "both") {
        Write-Host "JSON sizing report (gcp_sizing_$dateStr.json) is included in the ZIP for Sales AI Hub upload." -ForegroundColor Cyan
    }
    Write-Host "All output files (including the log) are compressed into the ZIP archive." -ForegroundColor Cyan
} else {
    Write-Host "`nInventory finished, but NO ZIP ARCHIVE was produced." -ForegroundColor Red
    Write-Host "The individual output files are intact in: $outDir" -ForegroundColor Yellow
    Write-Host "Send that folder to your Commvault representative, or re-run once the cause above is resolved." -ForegroundColor Yellow
}

}
catch {
    # Test-CVConsoleReady exists precisely for this: only use the console layer if it actually initialized.
    if ((Get-Command Test-CVConsoleReady -ErrorAction SilentlyContinue) -and (Test-CVConsoleReady)) {
        Write-CVLog "Critical error in main execution" -Level Error -Source 'Main' -Exception $_
        Write-CVSummary -Title 'GCP Sizing Run Summary (aborted)'
    } else {
        Write-Host "Critical error in main execution: $_" -ForegroundColor Red
    }
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}
