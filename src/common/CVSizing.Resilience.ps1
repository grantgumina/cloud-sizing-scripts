<#
    CVSizing.Resilience.ps1 - Cloud-agnostic signal catalog and export.

    THE CONTROL CATALOG IS A FIELD DECLARATION, NOT AN EVALUATOR. This is the single most surprising thing
    about this file, so read it before changing anything here.

    Each cloud declares its controls with New-CVControl, each carrying a Test scriptblock. Nothing executes
    those Test blocks. Get-CVSignalFieldMap regex-extracts the `$r.<Field>` references OUT of the Test source
    text to decide which inventory fields become columns in <cloud>_resilience_signals_*.csv. So a Test block
    is read as data, and its pass/fail logic never runs.

    That is deliberate: the export is judgement-free and the backend owns scoring, weighting and thresholds so
    they can be re-tuned without reissuing reports. Writing the Test as executable code (rather than a plain
    field list) keeps the INTENT of each control - what "good" looks like - recorded next to the field it reads,
    which is the contract the backend implements.

    Consequences worth knowing:
      - Adding a control automatically adds its fields as signal columns. That is the intended way to extend.
      - A Test block can contain a logic bug and no test will catch it, because nothing runs it. Only the
        `$r.<Field>` names it mentions are load-bearing. tests/Invoke-CVControlWiringTests.ps1 checks those
        names against the fields each resource type's row builder actually sets.
      - Category and Severity are metadata for the backend; nothing here consumes them.

    A control's Test is written to return $true = Met, $false = Gap, $null = Unknown, 'NA' = Not Applicable.
    The scoring engine that consumed those values (Invoke-CVResilience, Get-CVControlScore,
    Get-CVResilienceSummary, ConvertTo-CVOutcome, ConvertTo-CVResilienceColumns, Get-CVControlCatalog) was
    removed once all three clouds moved to the signals export; it had no production callers in any of them.
    The eventual destination is a declarative `New-CVSignal -Fields -GoodWhen`, which would drop the pretence
    that these are executable at all.
#>

#region ---------------------------------------------------------------- Model

function New-CVControl {
    <#
      .SYNOPSIS  Declare one resilience control: the fields it reads, and the intent behind them.
      .DESCRIPTION
        $Test is NOT executed - see the file header. It is parsed for its `$r.<Field>` references, which
        become the signal columns for this control's resource type. Write it as real code anyway: it records
        what "good" means for the backend that does the scoring.
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

#region ------------------------------------------------------- Per-resource signal export

<#
    The signals export is deliberately JUDGMENT-FREE: it publishes the values the controls evaluate, not our
    verdicts about them. Scoring, weighting and pass/fail thresholds are owned by the backend so they can be
    re-tuned without reissuing reports, and a verdict baked into the CSV would compete with that and go stale.

    It replaced a gap report that emitted one Gap_<id> column per control holding True/False/blank. That threw
    information away: 'Gap_st-xregion = False' discards the fact that the SKU was Standard_RAGRS, so a consumer
    could not distinguish RA-GRS from GRS from GZRS, nor re-decide what counts as geo-redundant. Note the polarity
    also differs - the old Gap_st-public = False is the new PublicAccessBlocked = True.

    Consequences of dropping verdicts, both intentional:
      - No Status / GapCount / severity rollups. Those are counts of verdicts; the backend derives them.
      - EVERY resource of an assessed type gets a row, not just ones with findings. Without evaluating we cannot
        filter to "has a gap", and comprehensiveness is the point of a normalized export.

    Columns are the RAW field names the controls read. That keeps the export honest (no renaming layer to drift)
    and handles multi-input controls naturally: Azure db-retention reads four fields, which are simply four
    columns rather than one cell with four values crammed into it.
#>

# Identity and materiality. All facts, all safe to publish.
$script:CVSignalIdentityColumns = @(
    'Scope','ResourceGroup','ResourceType','ResourceName','ParentResource','Region','ResourceId','SizeGB','SizeTB'
)

# Collection status, where a cloud script records it. These explain WHY a signal is blank - a fact about the
# collection, not a judgement about the resource - so a blank can be read as "denied"/"skipped" vs "absent".
$script:CVSignalStatusColumns = @('BackupDataStatus','SnapshotDataStatus')

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

function Get-CVControlSignalFields {
    <#
      .SYNOPSIS  The inventory field names a control's Test reads.
      .DESCRIPTION Derived from the Test scriptblock itself, so the export cannot drift from the controls: add a
                   control that reads a new field and the field becomes a column automatically.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Control)
    return @([regex]::Matches($Control.Test.ToString(), '\$r\.([A-Za-z_][A-Za-z0-9_]*)') |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
}

function Get-CVSignalFieldMap {
    <# .SYNOPSIS  ResourceType -> the signal fields that type's controls read. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$ControlSets)
    $map = @{}
    foreach ($type in $ControlSets.Keys) {
        $fields = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($ctl in @($ControlSets[$type])) {
            foreach ($f in (Get-CVControlSignalFields -Control $ctl)) { if (-not $fields.Contains($f)) { $fields[$f] = $true } }
        }
        $map[$type] = @($fields.Keys)
    }
    return $map
}

function Get-CVSignalColumns {
    <#
      .SYNOPSIS  Full ordered column list for the signals CSV: identity, collection status, then signal fields.
      .DESCRIPTION Pass this as -PreferredOrder together with -KeepDeclaredColumns so the header is identical on
                   every run. A signal field that is not currently collected still gets a (blank) column - the
                   consumer needs to see that the field is part of the schema rather than infer it is unsupported.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$ControlSets)
    $cols = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($c in ($script:CVSignalIdentityColumns + $script:CVSignalStatusColumns)) { if (-not $cols.Contains($c)) { $cols[$c] = $true } }
    # Resource types sorted so the column order is stable regardless of hashtable enumeration order.
    $map = Get-CVSignalFieldMap -ControlSets $ControlSets
    foreach ($type in ($map.Keys | Sort-Object)) {
        foreach ($f in $map[$type]) { if (-not $cols.Contains($f)) { $cols[$f] = $true } }
    }
    return @($cols.Keys)
}

function New-CVSignalRow {
    <#
      .SYNOPSIS  One row per resource: identity, size, collection status, and the raw signal values.
      .DESCRIPTION Always returns a row - there is no filtering, because filtering would require a verdict.
                   Signal values are copied VERBATIM from the inventory row: no coercion, no defaulting. A field
                   the resource does not carry is left absent, which the CSV renders blank. $false and blank are
                   therefore distinguishable, which is the whole point.
      .PARAMETER SignalFields  The field names to copy for this resource type (from Get-CVSignalFieldMap).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Resource,
        [Parameter(Mandatory)][string]$ResourceType,
        [string[]]$SignalFields = @(),
        [hashtable]$FieldMap = @{},
        [string[]]$ScopeCandidates = @('Subscription','Project','AwsAccountId','Account')
    )

    $sizeVal = if ($FieldMap.SizeGB) { Get-CVFirstProperty -Resource $Resource -Name @($FieldMap.SizeGB) } else { $null }
    $sizeGB  = if ($null -ne $sizeVal -and "$sizeVal" -match '^\s*-?[\d\.]+\s*$') { [double]$sizeVal } else { $null }

    $row = [ordered]@{
        Scope          = Get-CVFirstProperty -Resource $Resource -Name $ScopeCandidates
        ResourceGroup  = Get-CVFirstProperty -Resource $Resource -Name @('ResourceGroup','ResourceGroupName','VaultResourceGroup')
        ResourceType   = $ResourceType
        ResourceName   = Get-CVFirstProperty -Resource $Resource -Name @($FieldMap.Name)
        ParentResource = if ($FieldMap.Parent) { Get-CVFirstProperty -Resource $Resource -Name @($FieldMap.Parent) } else { $null }
        Region         = Get-CVFirstProperty -Resource $Resource -Name @('Region','Location','VaultRegion')
        ResourceId     = Get-CVFirstProperty -Resource $Resource -Name @('ResourceId','Id','Arn','SelfLink','DiskSelfLink')
        # $null, not 0, when unmeasured: a resource we could not size is not a small resource.
        SizeGB         = $sizeGB
        SizeTB         = if ($null -eq $sizeGB) { $null } else { [math]::Round($sizeGB / 1000, 4) }
    }
    foreach ($s in $script:CVSignalStatusColumns) {
        $p = $Resource.PSObject.Properties[$s]
        if ($p) { $row[$s] = $p.Value }
    }
    foreach ($f in @($SignalFields)) {
        $p = $Resource.PSObject.Properties[$f]
        # Only set the key when the resource actually has the property. Adding it as $null would be identical in
        # the CSV, but this keeps "the row never carried it" visible to callers inspecting the object.
        if ($p) { $row[$f] = $p.Value }
    }
    return [pscustomobject]$row
}

function Sort-CVSignalRows {
    <#
      .SYNOPSIS  Deterministic, judgement-free ordering: scope, then type, then name.
      .DESCRIPTION The gap report sorted by severity weight, which was a priority call. With no verdicts there is
                   nothing to prioritise by, and inventing an order would smuggle judgement back in. Largest-first
                   was tempting but size is not risk.
    #>
    [CmdletBinding()]
    param([object[]]$Rows = @())
    return @($Rows | Sort-Object `
        @{ E = { "$($_.Scope)" } },
        @{ E = { "$($_.ResourceType)" } },
        @{ E = { "$($_.ResourceName)" } })
}

#endregion
