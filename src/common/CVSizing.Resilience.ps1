<#
    CVSizing.Resilience.ps1 - Cloud-agnostic control-evaluation engine for raw protection data.

    Provider-neutral: each cloud script defines its OWN controls (New-CVControl with a cloud-specific Test
    scriptblock), then Get-CVProtectionData reduces those control outcomes to the six RAW protection fields
    that go on the inventory rows and into the sizing JSON. Scoring, gap severity, and any interpretation are
    deliberately NOT emitted here - they are owned by the downstream report generator - so these deliverables
    stay raw and schema-light.

    Design decisions (confirmed):
      - Describes the customer's CURRENT NATIVE cloud posture (as-is), not any backup-vendor target state.
      - "Unknown" (signal not collected / API call failed) and "N/A" surface as $null, never as $false -
        a signal we did not measure is never reported as a negative.

    A control's Test returns: $true = Met, $false = Gap (not met), $null = Unknown, 'NA' = Not Applicable.
    (Get-CVControlScore / CVSeverityWeight remain as internal helpers of Invoke-CVResilience but are never emitted.)
#>

#region ---------------------------------------------------------------- Model + config

$script:CVSeverityWeight = @{ Critical = 3; High = 2; Medium = 1 }
$script:CVResilienceCategories = 'DataExposure','RecoveryReady','Availability','Immutability','CleanRecovery'

function New-CVControl {
    <#
      .SYNOPSIS  Define one resilience control. $Test receives a resource object and returns
                 $true (Met) / $false (Gap) / $null (Unknown) / 'NA' (Not Applicable).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][ValidateSet('DataExposure','RecoveryReady','Availability','Immutability','CleanRecovery')][string]$Category,
        [Parameter(Mandatory)][ValidateSet('Critical','High','Medium')][string]$Severity,
        [Parameter(Mandatory)][scriptblock]$Test
    )
    [pscustomobject]@{ Id = $Id; Title = $Title; Category = $Category; Severity = $Severity; Test = $Test }
}

# Tri-state helper for control Tests: $null field -> Unknown (excluded); otherwise coerce to bool.
function Get-CVTri { param($Value) if ($null -eq $Value) { return $null } return [bool]$Value }

#endregion

#region ---------------------------------------------------------- Collection status (did we actually look?)

<#
    Get-CVTri only converts $null to Unknown, so a posture field left at its $false initializer is scored as a
    GAP - an affirmative "this resource is not protected" finding. That is correct when we queried the API and
    found nothing, and badly wrong when the query never ran or failed.

    Those two cases were indistinguishable: an Azure VM row was created with BackupEnabled = $false before any
    backup data was collected, so a disabled API, a 403, a wrong cmdlet parameter set, or simply omitting
    -Types Backup all produced a confident High-severity "0% backup coverage" report.

    These helpers record, per scope (subscription / project / account) and per signal, whether collection actually
    succeeded. Callers resolve a value through Resolve-CVSignal so anything not collected surfaces as Unknown.
#>

$script:CVCollectionStatus = @{}

function Reset-CVCollectionStatus {
    <# .SYNOPSIS  Clear all recorded collection statuses (call once at run start; used by tests). #>
    [CmdletBinding()] param()
    $script:CVCollectionStatus = @{}
}

function Set-CVCollectionStatus {
    <#
      .SYNOPSIS  Record whether a signal was successfully collected for a scope.
      .PARAMETER Scope   Subscription / project / account identifier.
      .PARAMETER Signal  Logical signal name, e.g. BACKUP, SNAPSHOT, METRICS.
      .PARAMETER Status  Ok = queried successfully. Failed = queried and it errored. Skipped = never attempted.
      .DESCRIPTION Failed and Skipped never downgrade an existing Ok: within one scope a signal may be gathered
                   from several calls, and one later failure should not erase data we did collect.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Signal,
        [Parameter(Mandatory)][ValidateSet('Ok', 'Failed', 'Skipped')][string]$Status
    )
    $k = "$Scope|$Signal".ToLower()
    if ($Status -ne 'Ok' -and $script:CVCollectionStatus[$k] -eq 'Ok') { return }
    $script:CVCollectionStatus[$k] = $Status
}

function Get-CVCollectionStatus {
    <# .SYNOPSIS  Status for a scope+signal. Never recorded means never attempted -> 'Skipped'. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Scope, [Parameter(Mandatory)][string]$Signal)
    $k = "$Scope|$Signal".ToLower()
    if ($script:CVCollectionStatus.ContainsKey($k)) { return $script:CVCollectionStatus[$k] }
    return 'Skipped'
}

function Resolve-CVSignal {
    <#
      .SYNOPSIS  Return $Value only when the signal was actually collected; otherwise $null (Unknown).
      .DESCRIPTION The single guard that stops "we could not look" from being reported as "it is not there".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Signal,
        [Parameter(Position = 0)]$Value
    )
    if ((Get-CVCollectionStatus -Scope $Scope -Signal $Signal) -eq 'Ok') { return $Value }
    return $null
}

function Get-CVCollectionStatusMap {
    <#
      .SYNOPSIS  All recorded statuses as scope -> @{ SIGNAL = status }, for passing to attribution helpers.
    #>
    [CmdletBinding()] param()
    $map = @{}
    foreach ($k in $script:CVCollectionStatus.Keys) {
        $parts  = $k -split '\|', 2
        if ($parts.Count -ne 2) { continue }
        $scope  = $parts[0]
        $signal = $parts[1].ToUpper()
        if (-not $map.ContainsKey($scope)) { $map[$scope] = @{} }
        $map[$scope][$signal] = $script:CVCollectionStatus[$k]
    }
    return $map
}

#endregion

#region ---------------------------------------------------------------- Evaluation

function ConvertTo-CVOutcome {
    # Normalize a Test result into an outcome label.
    param($Value)
    if ($Value -is [string] -and $Value -eq 'NA') { return 'NA' }
    if ($null -eq $Value) { return 'Unknown' }
    if ($Value -is [bool]) { return $(if ($Value) { 'Met' } else { 'Gap' }) }
    return $(if ($Value) { 'Met' } else { 'Gap' })   # truthy fallback
}

function Get-CVControlScore {
    <#
      .SYNOPSIS  Weighted 0-100 score over control results. Only Met/Gap count (Unknown + NA excluded).
                 Returns $null when nothing was actually assessed.
    #>
    [CmdletBinding()]
    param([object[]]$Results = @())   # default/empty-safe: an empty environment scores $null, not an error
    $scored = @($Results | Where-Object { $_.Outcome -in 'Met','Gap' })
    if (-not $scored.Count) { return $null }
    $den = ($scored | ForEach-Object { $script:CVSeverityWeight[$_.Severity] } | Measure-Object -Sum).Sum
    if (-not $den) { return $null }
    $num = ($scored | Where-Object { $_.Outcome -eq 'Met' } | ForEach-Object { $script:CVSeverityWeight[$_.Severity] } | Measure-Object -Sum).Sum
    return [math]::Round(100 * ([double]$num) / $den, 0)
}

function Invoke-CVResilience {
    <#
      .SYNOPSIS  Evaluate a control set against one resource.
      .OUTPUTS   pscustomobject { Score; Results[]; Gaps[]; MetCount; GapCount; UnknownCount }
                 Each Results entry: { Id; Title; Category; Severity; Outcome; Detail }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Resource,
        [Parameter(Mandatory)][object[]]$Controls
    )
    $results = foreach ($c in $Controls) {
        $outcome = 'Unknown'; $detail = ''
        try   { $outcome = ConvertTo-CVOutcome (& $c.Test $Resource) }
        catch { $outcome = 'Unknown'; $detail = $_.Exception.Message }
        [pscustomobject]@{ Id = $c.Id; Title = $c.Title; Category = $c.Category; Severity = $c.Severity; Outcome = $outcome; Detail = $detail }
    }
    $gaps = @($results | Where-Object { $_.Outcome -eq 'Gap' } |
                Sort-Object @{ E = { $script:CVSeverityWeight[$_.Severity] }; Descending = $true }, Id |
                ForEach-Object { "$($_.Severity):$($_.Id)" })
    [pscustomobject]@{
        Score        = Get-CVControlScore -Results $results
        Results      = $results
        Gaps         = $gaps
        MetCount     = @($results | Where-Object { $_.Outcome -eq 'Met' }).Count
        GapCount     = @($results | Where-Object { $_.Outcome -eq 'Gap' }).Count
        UnknownCount = @($results | Where-Object { $_.Outcome -eq 'Unknown' }).Count
    }
}

#endregion

#region ------------------------------------------------------- Protection data (raw)

<#
    Get-CVProtectionData reduces a resource's native protection to a small, consistent set of RAW typed
    fields for the sizing outputs (flat columns on the inventory rows, a nested `protection` object in the
    JSON). It is deliberately raw, not interpreted: all scoring, gap severity, and pass/fail judgment now
    live in the downstream report generator, so these deliverables stay stable and schema-light.

    Up to six fields, drawn from this set:
      backup_enabled, backup_retention_days, backup_immutable, pitr_enabled,
      public_access_blocked, cross_region_backup

    Only the fields that APPLY to the workload type are emitted - a field is present iff the type's control
    catalog defines a control feeding it (so pitr_enabled appears only on DB types, public_access_blocked
    only on object storage / DBs, etc.). Not-applicable fields are omitted entirely, not shown as $null.

    Values are raw: $true / $false / $null (int for retention). For an applicable field, $null means
    "measured nothing" - the API call could not be made or the signal was not collected. A signal we did not
    measure is never reported as $false (the "confident 0% coverage" failure the engine exists to prevent;
    see the collection-status region above). The control Test blocks do the measuring (they encode real
    logic - geo-SKU parsing, public-IP checks); each outcome maps straight through: Met -> $true, Gap ->
    $false, Unknown/NA -> $null.
#>

# The raw field contract, shared by the row columns (flat) and the JSON `protection` object (nested).
$script:CVProtectionFields = @('backup_enabled','backup_retention_days','backup_immutable','pitr_enabled','public_access_blocked','cross_region_backup')

# Per cloud, per signal: which control id(s) feed the value (first present on the row wins). Membership of
# these ids in a resource type's control set ALSO decides applicability - a field is only emitted for a type
# whose catalog defines a control feeding it (so PITR appears only on DB types, public-access only on object
# storage / DBs, etc.). `retentionControls` are the *-retention controls that mark a type as having a retention
# concept; `retentionFields` are the raw properties carrying the day count; `backupFromRetention` types have no
# boolean backup control, so their backup_enabled derives from retention>0. Mirrors CVSizing.Resilience.{AWS,Azure,GCP}.ps1.
$script:CVProtectionMap = @{
    aws = @{
        backup            = @('ec2-backup','rds-backup','efs-backup','ddb-vault')
        immutability      = @('s3-objectlock','ec2-vaultlock','rds-vaultlock','ddb-vaultlock')   # S3 Object Lock / Backup Vault Lock
        pitr              = @('rds-pitr','ddb-pitr')
        public_exposure   = @('s3-public')
        cross_region      = @('s3-xregion')
        retentionControls = @('rds-retention','rs-retention')
        retentionFields   = @('BackupRetentionDays','BackupRetentionPeriod','AutomatedSnapshotRetentionPeriod','AutomatedSnapshotRetentionDays')
        backupFromRetention = @('Redshift')   # automated snapshots only; backup_enabled = retention>0
    }
    azure = @{
        backup            = @('vm-backup','disk-schedule','db-backup','cos-pitr','fs-backup','aks-backup')
        immutability      = @('vm-immutable','st-immutable')
        pitr              = @('db-pitr','cos-pitr')
        public_exposure   = @('st-public')
        cross_region      = @('vm-xregion','st-xregion','db-xregion','fx-xregion','cos-xregion','fs-xregion')
        retentionControls = @('db-retention','fx-retention')
        retentionFields   = @('PITR_Days','BackupRetentionDays')   # Cosmos retention is in hours -> intentionally not mapped
        backupFromRetention = @('FlexDB')
    }
    gcp = @{
        backup            = @('vm-backup','pd-schedule','db-backup','fs-backup','gke-backup')
        immutability      = @('vm-immutable','gcs-lock')
        pitr              = @('db-pitr')
        public_exposure   = @('gcs-public','db-notpublic')
        cross_region      = @('vm-xregion','pd-xregion','gcs-xregion','fs-xregion','db-xregion','gke-xregion')
        retentionControls = @('db-retention')
        retentionFields   = @('RetainedBackups','TxLogRetentionDays')
    }
}

function Get-CVProtectionData {
    <#
      .SYNOPSIS  The six raw protection fields for one resource (see the region header).
      .PARAMETER Resource      The inventory row (carrying the raw signal fields the control Tests read).
      .PARAMETER Cloud         aws | azure | gcp.
      .PARAMETER ResourceType  Engine type key (EC2/RDS/... VM/SQL/FlexDB/... VM/Database/GKE/...).
      .PARAMETER ControlSet    The type's controls; evaluated in-memory to read each signal's outcome.
      .OUTPUTS  [ordered] { backup_enabled; backup_retention_days; backup_immutable; pitr_enabled; public_access_blocked; cross_region_backup }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Resource,
        [Parameter(Mandatory)][ValidateSet('aws','azure','gcp')][string]$Cloud,
        [Parameter(Mandatory)][string]$ResourceType,
        [object[]]$ControlSet
    )

    $map = $script:CVProtectionMap[$Cloud]

    # id -> outcome ('Met'/'Gap'/'Unknown'/'NA'). Prefer any Ctl_* columns already on the row; otherwise
    # evaluate the control set in-memory. The Test blocks are the single source of truth for each signal.
    $outcomes = @{}
    foreach ($p in $Resource.PSObject.Properties) {
        if ($p.Name -like 'Ctl_*') { $outcomes[$p.Name.Substring(4)] = $p.Value }
    }
    if ($outcomes.Count -eq 0 -and $ControlSet) {
        foreach ($r in (Invoke-CVResilience -Resource $Resource -Controls $ControlSet).Results) { $outcomes[$r.Id] = $r.Outcome }
    }

    # Control ids the type's catalog defines - decides APPLICABILITY (a field is emitted only for a type whose
    # catalog feeds it) as well as which outcomes exist.
    $availableIds = if ($ControlSet) { @($ControlSet | ForEach-Object { $_.Id }) } else { @($outcomes.Keys) }
    $applies = { param([string[]]$Ids) foreach ($id in $Ids) { if ($availableIds -contains $id) { return $true } } return $false }

    # First candidate id present decides the value: Met -> $true, Gap -> $false, missing/Unknown/NA -> $null.
    # (public_access_blocked reads the "public access blocked" controls, so Met = blocked = $true.)
    $boolFor = {
        param([string[]]$Ids)
        foreach ($id in $Ids) {
            if ($outcomes.ContainsKey($id)) {
                switch ("$($outcomes[$id])") {
                    'Met' { return $true }
                    'Gap' { return $false }
                    default { return $null }
                }
            }
        }
        return $null
    }

    $fromRetention    = [bool]($map.backupFromRetention -and ($map.backupFromRetention -contains $ResourceType))
    $backupApplies    = (& $applies $map.backup) -or $fromRetention
    $retentionApplies = (& $applies $map.retentionControls) -or $fromRetention

    $retVal  = Get-CVFirstProperty -Resource $Resource -Name $map.retentionFields
    $retDays = if ($null -ne $retVal -and "$retVal" -match '^\s*-?\d+\s*$') { [int]$retVal } else { $null }

    # Emit ONLY the fields that apply to this workload type, in the canonical $script:CVProtectionFields order.
    $out = [ordered]@{}
    if ($backupApplies) {
        $backup = & $boolFor $map.backup
        # Types with no boolean backup control (Azure FlexDB, AWS Redshift): a positive retention IS the evidence.
        if ($null -eq $backup -and $fromRetention -and $null -ne $retDays) { $backup = ($retDays -gt 0) }
        $out['backup_enabled'] = $backup
    }
    if ($retentionApplies)               { $out['backup_retention_days'] = $retDays }
    if (& $applies $map.immutability)    { $out['backup_immutable']      = & $boolFor $map.immutability }
    if (& $applies $map.pitr)            { $out['pitr_enabled']          = & $boolFor $map.pitr }
    if (& $applies $map.public_exposure) { $out['public_access_blocked'] = & $boolFor $map.public_exposure }
    if (& $applies $map.cross_region)    { $out['cross_region_backup']   = & $boolFor $map.cross_region }
    return $out
}

#endregion
#region ------------------------------------------------------------- Property helper

function Get-CVFirstProperty {
    <# .SYNOPSIS  First non-empty value among candidate property names. Collections disagree on field naming. #>
    [CmdletBinding()]
    param($Resource, [string[]]$Name)
    foreach ($n in $Name) {
        if (-not $n) { continue }
        $p = $Resource.PSObject.Properties[$n]
        if ($p -and -not [string]::IsNullOrWhiteSpace("$($p.Value)")) { return $p.Value }
    }
    return $null
}

#endregion
