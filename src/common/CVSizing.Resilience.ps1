<#
    CVSizing.Resilience.ps1 - Cloud-agnostic resilience scoring engine.

    Implements the scoring framework from the Cloud Resilience Control Catalog. It is provider-neutral:
    each cloud script defines its OWN controls (New-CVControl with a cloud-specific Test scriptblock),
    then calls Invoke-CVResilience per resource and Get-CVResilienceSummary at the end. The catalog's five
    categories and Critical/High/Medium severities live here; the per-provider evaluation logic does not.

    Design decisions (confirmed):
      - Scores the customer's CURRENT NATIVE cloud posture (as-is), not any backup-vendor target state.
      - "Unknown" (signal not collected / API call failed) and "N/A" are EXCLUDED from the score, not counted
        as failures - the score reflects only what was actually evaluated. They are still reported separately.
      - Severity weights: Critical 3, High 2, Medium 1.

    A control's Test returns: $true = Met, $false = Gap (not met), $null = Unknown, 'NA' = Not Applicable.
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

# Flatten one resource's evaluation into columns to append to its inventory row (one column per control + rollups).
function ConvertTo-CVResilienceColumns {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Evaluation, [string]$Prefix = 'Ctl_')
    $cols = [ordered]@{}
    foreach ($r in $Evaluation.Results) { $cols["$Prefix$($r.Id)"] = $r.Outcome }
    $cols['ResilienceScore'] = $Evaluation.Score
    $cols['ResilienceGaps']  = ($Evaluation.Gaps -join '; ')
    return $cols
}

#endregion

#region ---------------------------------------------------------------- Aggregation / summary

function Get-CVResilienceSummary {
    <#
      .SYNOPSIS  Roll flattened per-control results (across all resources) into category posture, an overall
                 score, and a ranked list of the most common gaps - the report's headline numbers.
      .PARAMETER Results  Every per-control result object (from the .Results of each Invoke-CVResilience),
                          ideally each tagged with a ResourceType note property.
    #>
    [CmdletBinding()]
    param([object[]]$Results = @())   # empty-safe: no assessed controls -> OverallScore $null, empty tables

    $scored = @($Results | Where-Object { $_.Outcome -in 'Met','Gap' })

    $byCategory = foreach ($cat in $script:CVResilienceCategories) {
        $c = @($scored | Where-Object { $_.Category -eq $cat })
        if (-not $c.Count) { continue }
        $met = @($c | Where-Object { $_.Outcome -eq 'Met' }).Count
        [pscustomobject]@{
            Category      = $cat
            ControlsMet   = $met
            ControlsTotal = $c.Count
            PercentMet    = [math]::Round(100 * $met / $c.Count, 0)
        }
    }

    $topGaps = $scored | Where-Object { $_.Outcome -eq 'Gap' } |
        Group-Object Id | ForEach-Object {
            $first = $_.Group[0]
            [pscustomobject]@{
                Id       = $_.Name
                Title    = $first.Title
                Category = $first.Category
                Severity = $first.Severity
                Count    = $_.Count
                Weight   = $script:CVSeverityWeight[$first.Severity] * $_.Count
            }
        } | Sort-Object Weight -Descending

    [pscustomobject]@{
        OverallScore = Get-CVControlScore -Results $scored
        ByCategory   = @($byCategory)
        TopGaps      = @($topGaps)
        Assessed     = $scored.Count
        Excluded     = @($Results | Where-Object { $_.Outcome -in 'Unknown','NA' }).Count
    }
}

# Metadata rows (for a legend/catalog CSV so readers can see what each Ctl_* column means).
function Get-CVControlCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Controls, [string]$ResourceType)
    foreach ($c in $Controls) {
        [pscustomobject]@{ ResourceType = $ResourceType; Id = $c.Id; Title = $c.Title; Category = $c.Category; Severity = $c.Severity }
    }
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
