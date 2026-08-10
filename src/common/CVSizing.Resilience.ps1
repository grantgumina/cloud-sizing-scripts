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

#region ------------------------------------------------------- Protection posture (JSON headline)

<#
    Get-CVProtectionPosture summarizes a resource's native protection into a small, consistent set of
    status LABELS for the sizing JSON that feeds the cloud posture report. Terminology is the point:
    every workload type and every cloud uses the SAME vocabulary, taken from CYBER_RESILIENCE_REPORT.md.

    It is a headline view of controls that already ran - it reuses the Ctl_<id> outcomes the resilience
    pass wrote onto the row (Met/Gap/Unknown/NA). No new signals are collected here. When those columns
    are absent (the resilience report was skipped) it re-evaluates in-memory from the supplied control
    set, so the single source of truth stays the New-CVControl Test blocks.

    The tri-state maps straight to labels: Met -> positive, Gap -> negative, Unknown/NA/absent ->
    'NotAssessed'. 'NotAssessed' deliberately covers both "does not apply" and "could not evaluate" -
    a signal we did not measure is never reported as a negative (the "confident 0% coverage" failure the
    engine exists to prevent; see the collection-status region above).
#>

# signal -> the positive (Met) and negative (Gap) word. public_exposure is phrased so the control's
# "public access blocked" == Met reads as NotPublic; a Gap (not blocked) reads as Public.
$script:CVPostureLabels = @{
    backup          = @{ Met = 'Protected'; Gap = 'Unprotected'  }
    immutability    = @{ Met = 'Immutable'; Gap = 'NotImmutable' }
    pitr            = @{ Met = 'Enabled';   Gap = 'NotEnabled'   }
    public_exposure = @{ Met = 'NotPublic'; Gap = 'Public'       }
    cross_region    = @{ Met = 'Protected'; Gap = 'NotProtected' }
}

# Per cloud: which control id(s) feed each headline signal (first present on the row wins), which raw
# fields carry the retention day count, and which engine types derive backup from retention (no boolean
# backup control exists for them). Mirrors the catalogs in CVSizing.Resilience.{AWS,Azure,GCP}.ps1.
$script:CVProtectionMap = @{
    aws = @{
        backup          = @('ec2-backup','rds-backup','efs-backup','ddb-vault')
        immutability    = @('s3-objectlock','ec2-vaultlock','rds-vaultlock','ddb-vaultlock')   # S3 Object Lock / Backup Vault Lock
        pitr            = @('rds-pitr','ddb-pitr')
        public_exposure = @('s3-public')
        cross_region    = @('s3-xregion')
        retention       = @('BackupRetentionDays','BackupRetentionPeriod','AutomatedSnapshotRetentionPeriod','AutomatedSnapshotRetentionDays')
    }
    azure = @{
        backup          = @('vm-backup','disk-schedule','db-backup','cos-pitr','fs-backup','aks-backup')
        immutability    = @('vm-immutable','st-immutable')
        pitr            = @('db-pitr','cos-pitr')
        public_exposure = @('st-public')
        cross_region    = @('vm-xregion','st-xregion','db-xregion','fx-xregion','cos-xregion','fs-xregion')
        retention       = @('PITR_Days','BackupRetentionDays')   # Cosmos retention is in hours -> intentionally not mapped
        backupFromRetention = @('FlexDB')
    }
    gcp = @{
        backup          = @('vm-backup','pd-schedule','db-backup','fs-backup','gke-backup')
        immutability    = @('vm-immutable','gcs-lock')
        pitr            = @('db-pitr')
        public_exposure = @('gcs-public','db-notpublic')
        cross_region    = @('vm-xregion','pd-xregion','gcs-xregion','fs-xregion','db-xregion','gke-xregion')
        retention       = @('RetainedBackups','TxLogRetentionDays')
    }
}

function Get-CVProtectionPosture {
    <#
      .SYNOPSIS  Headline protection labels for one resource, for the sizing JSON.
      .PARAMETER Resource      The inventory row (already carrying Ctl_<id> columns after the resilience pass).
      .PARAMETER Cloud         aws | azure | gcp.
      .PARAMETER ResourceType  Engine type key (EC2/RDS/... VM/SQL/FlexDB/... VM/Database/GKE/...).
      .PARAMETER ControlSet    The type's controls; used to re-evaluate when Ctl_<id> columns are absent.
      .OUTPUTS  [ordered] { backup; retention_days; immutability; pitr; public_exposure; cross_region; overall }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Resource,
        [Parameter(Mandatory)][ValidateSet('aws','azure','gcp')][string]$Cloud,
        [Parameter(Mandatory)][string]$ResourceType,
        [object[]]$ControlSet
    )

    $map = $script:CVProtectionMap[$Cloud]

    # id -> outcome ('Met'/'Gap'/'Unknown'/'NA'). Prefer the Ctl_* columns already on the row; fall back
    # to an in-memory evaluation so posture is still correct when -SkipResilienceReport skipped the CSV pass.
    $outcomes = @{}
    foreach ($p in $Resource.PSObject.Properties) {
        if ($p.Name -like 'Ctl_*') { $outcomes[$p.Name.Substring(4)] = $p.Value }
    }
    if ($outcomes.Count -eq 0 -and $ControlSet) {
        foreach ($r in (Invoke-CVResilience -Resource $Resource -Controls $ControlSet).Results) { $outcomes[$r.Id] = $r.Outcome }
    }

    # First candidate id present on the row decides the label; missing/Unknown/NA -> NotAssessed.
    $labelFor = {
        param([string]$Signal, [string[]]$Ids)
        foreach ($id in $Ids) {
            if ($outcomes.ContainsKey($id)) {
                switch ("$($outcomes[$id])") {
                    'Met' { return $script:CVPostureLabels[$Signal].Met }
                    'Gap' { return $script:CVPostureLabels[$Signal].Gap }
                    default { return 'NotAssessed' }
                }
            }
        }
        return 'NotAssessed'
    }

    $backup = & $labelFor 'backup'          $map.backup
    $immut  = & $labelFor 'immutability'    $map.immutability
    $pitr   = & $labelFor 'pitr'            $map.pitr
    $public = & $labelFor 'public_exposure' $map.public_exposure
    $xreg   = & $labelFor 'cross_region'    $map.cross_region

    $retVal  = Get-CVFirstProperty -Resource $Resource -Name $map.retention
    $retDays = if ($null -ne $retVal -and "$retVal" -match '^\s*-?\d+\s*$') { [int]$retVal } else { $null }

    # Types with no boolean backup control (Azure FlexDB): a positive retention IS the backup evidence.
    if ($backup -eq 'NotAssessed' -and $map.backupFromRetention -and ($map.backupFromRetention -contains $ResourceType) -and $null -ne $retDays) {
        $backup = if ($retDays -gt 0) { 'Protected' } else { 'Unprotected' }
    }

    $signals   = @($backup, $immut, $pitr, $public, $xreg)
    $negatives = @('Unprotected','NotImmutable','NotEnabled','Public','NotProtected')
    $overall =
        if (@($signals | Where-Object { $_ -ne 'NotAssessed' }).Count -eq 0) { 'NotAssessed' }
        elseif ($backup -eq 'Unprotected') { 'Unprotected' }
        elseif ($backup -eq 'Protected' -and @($signals | Where-Object { $negatives -contains $_ }).Count -eq 0) { 'Protected' }
        else { 'PartiallyProtected' }

    return [ordered]@{
        backup          = $backup
        retention_days  = $retDays
        immutability    = $immut
        pitr            = $pitr
        public_exposure = $public
        cross_region    = $xreg
        overall         = $overall
    }
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

#region ------------------------------------------------------------- Per-resource gap report

<#
    The gap report answers "WHICH resources are exposed, how badly, and how much data is at risk" - one row per
    resource. It replaces two files that could not answer that:
      - the control catalog, which was a static legend identical on every run
      - the gaps rollup, which was one row PER CONTROL with a count, so it told you the estate's worst control
        but never which machines to go look at.

    Resources whose signals could not be collected are included with Status = 'NotAssessed' and GapCount 0. They
    are a finding in their own right - "we could not check 40 VMs" is something a reader of this file alone must
    be able to see - and keeping them out of the gap counts preserves the Unknown-is-not-a-Gap rule.
#>

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

function New-CVGapRow {
    <#
      .SYNOPSIS  Build one gap-report row for a resource from its evaluation.
      .PARAMETER FieldMap  Per-type field names that genuinely differ: @{ Name; Parent; SizeGB }.
                           Identity fields (resource group, region, id, scope) are probed from candidate lists
                           because their variation is mechanical rather than meaningful.
      .OUTPUTS   pscustomobject row, or $null when the resource is fully Met (nothing to report).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Resource,
        [Parameter(Mandatory)][string]$ResourceType,
        [Parameter(Mandatory)]$Evaluation,
        [hashtable]$FieldMap = @{},
        [string[]]$ScopeCandidates = @('Subscription','Project','AwsAccountId','Account')
    )

    $gaps = @($Evaluation.Results | Where-Object { $_.Outcome -eq 'Gap' })
    $unknownCount = [int]$Evaluation.UnknownCount
    # Fully compliant and fully assessed -> not a finding, no row.
    if (-not $gaps.Count -and -not $unknownCount) { return $null }

    $status = if ($gaps.Count) { 'Gap' } elseif ($Evaluation.MetCount -eq 0) { 'NotAssessed' } else { 'PartiallyAssessed' }

    $sizeVal = if ($FieldMap.SizeGB) { Get-CVFirstProperty -Resource $Resource -Name @($FieldMap.SizeGB) } else { $null }
    $sizeGB  = if ($null -ne $sizeVal -and "$sizeVal" -match '^\s*-?[\d\.]+\s*$') { [double]$sizeVal } else { $null }

    # Severity counts only. No weight and no score are emitted: scoring is decided (and re-tuned) on the backend,
    # and publishing our numbers here would put two competing answers in circulation - ours going stale the moment
    # the backend's model changed. Everything needed to recompute them is in the row: the per-control Gap_<id>
    # results plus the severity counts below. Sort-CVGapRows derives an ordering weight from these at write time.
    $bySeverity = @{ Critical = 0; High = 0; Medium = 0 }
    foreach ($g in $gaps) {
        if ($bySeverity.ContainsKey($g.Severity)) { $bySeverity[$g.Severity]++ }
    }
    $worst = if ($bySeverity.Critical) { 'Critical' } elseif ($bySeverity.High) { 'High' } elseif ($bySeverity.Medium) { 'Medium' } else { '' }

    # One column per control: Gap_<id>. THREE states, not two - $true = gap found, $false = checked and clean,
    # $null (blank in the CSV) = not assessed, or the control does not apply to this resource type.
    # Unknown must NOT collapse to $false: that would assert "no gap here" about a control we never evaluated,
    # which is the exact failure this whole subsystem was corrected to avoid. Blank and FALSE filter separately.
    $gapCols = [ordered]@{}
    foreach ($res in $Evaluation.Results) {
        $gapCols["Gap_$($res.Id)"] = switch ($res.Outcome) {
            'Gap' { $true }
            'Met' { $false }
            default { $null }      # Unknown / NA
        }
    }

    $row = [pscustomobject]@{
        # --- identity -------------------------------------------------------------------------------------
        Scope             = Get-CVFirstProperty -Resource $Resource -Name $ScopeCandidates
        ResourceGroup     = Get-CVFirstProperty -Resource $Resource -Name @('ResourceGroup','ResourceGroupName','VaultResourceGroup')
        ResourceType      = $ResourceType
        ResourceName      = Get-CVFirstProperty -Resource $Resource -Name @($FieldMap.Name)
        ParentResource    = if ($FieldMap.Parent) { Get-CVFirstProperty -Resource $Resource -Name @($FieldMap.Parent) } else { $null }
        Region            = Get-CVFirstProperty -Resource $Resource -Name @('Region','Location','VaultRegion')
        # ARM id / ARN / self-link depending on cloud. Blank when the row genuinely has none - never fabricated.
        ResourceId        = Get-CVFirstProperty -Resource $Resource -Name @('ResourceId','Id','Arn','SelfLink','DiskSelfLink')
        # --- materiality ----------------------------------------------------------------------------------
        # $null, not 0, when unmeasured: a resource we could not size is not a small resource.
        SizeGB            = $sizeGB
        SizeTB            = if ($null -eq $sizeGB) { $null } else { [math]::Round($sizeGB / 1000, 4) }
        # --- findings -------------------------------------------------------------------------------------
        # Observations only. No RiskWeight and no ResilienceScore: those are scoring decisions, and scoring is
        # owned by the backend so it can be adjusted without reissuing reports. The counts below are raw facts
        # about what failed, which the backend combines with its own severity model.
        Status            = $status
        WorstSeverity     = $worst
        GapCount          = $gaps.Count
        CriticalGaps      = $bySeverity.Critical
        HighGaps          = $bySeverity.High
        MediumGaps        = $bySeverity.Medium
        # --- what is wrong --------------------------------------------------------------------------------
        # GapIds is gone - the Gap_<id> columns below ARE the ids. GapTitles stays because the column headers
        # are terse control ids and this is the sentence you can paste into a report.
        GapCategories     = (@($gaps | Select-Object -ExpandProperty Category -Unique | Sort-Object) -join '; ')
        GapTitles         = (@($gaps | Select-Object -ExpandProperty Title) -join '; ')
        # --- confidence -----------------------------------------------------------------------------------
        # How much of the check actually ran on this resource. Without these, GapCount reads as a complete audit:
        # "1 gap of 3 controls checked" and "1 gap, 2 controls we could not evaluate" are very different claims.
        # AssessedControls   = non-blank Gap_* cells (a real verdict, gap or clean)
        # UnassessedControls = blank Gap_* cells (no verdict: missing permission, disabled API, or -Types omission)
        AssessedControls   = [int]$Evaluation.MetCount + $gaps.Count
        UnassessedControls = $unknownCount
        AssessmentComplete = ($unknownCount -eq 0)
    }

    foreach ($k in $gapCols.Keys) { Add-Member -InputObject $row -NotePropertyName $k -NotePropertyValue $gapCols[$k] -Force }
    return $row
}

# Column order for the gap CSV. Export-CVCsv appends anything not listed, so adding a field to New-CVGapRow
# cannot silently drop it - it just lands at the end until it is named here.
$script:CVGapReportColumns = @(
    'Scope','ResourceGroup','ResourceType','ResourceName','ParentResource','Region','ResourceId',
    'SizeGB','SizeTB',
    'Status','WorstSeverity','GapCount','CriticalGaps','HighGaps','MediumGaps',
    'GapCategories','GapTitles',
    'AssessedControls','UnassessedControls','AssessmentComplete'
)

function Get-CVGapReportColumns {
    <#
      .SYNOPSIS  Gap-report column order: the fixed columns, then one Gap_<id> column per control.
      .PARAMETER ControlSets  The cloud's ResourceType -> controls hashtable. Supplying it fixes the ORDER of the
                              Gap_* columns to catalog order (resource type, then declaration order) instead of
                              letting them appear in whatever order the first rows happened to introduce.
                              Note the column SET still follows the estate: Export-CVCsv omits preferred columns
                              that no row carries, so a run with no storage accounts has no Gap_st-* columns. That
                              keeps the file narrow, but means two runs over different scopes are not necessarily
                              column-for-column comparable.
    #>
    [CmdletBinding()]
    param([hashtable]$ControlSets)

    if (-not $ControlSets) { return $script:CVGapReportColumns }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $gapCols = foreach ($type in @($ControlSets.Keys | Sort-Object)) {
        foreach ($c in @($ControlSets[$type])) {
            $name = "Gap_$($c.Id)"
            if ($seen.Add($name)) { $name }     # a control shared by two resource types gets one column
        }
    }
    return @($script:CVGapReportColumns) + @($gapCols)
}

function Sort-CVGapRows {
    <#
      .SYNOPSIS  Priority order: real gaps first, then severity weight, then data at risk.
      .DESCRIPTION The weight is derived here from the severity COUNT columns rather than stored on the row.
                   A CSV has to be in some order and severity-first is the useful one, but the ordering is a
                   presentation choice - it is deliberately not published as a column, because scoring and
                   weighting belong to the backend and a stale number in the file would compete with it.
    #>
    [CmdletBinding()]
    param([object[]]$Rows = @())
    $weightOf = {
        param($r)
        ($script:CVSeverityWeight.Critical * [int]$r.CriticalGaps) +
        ($script:CVSeverityWeight.High     * [int]$r.HighGaps)     +
        ($script:CVSeverityWeight.Medium   * [int]$r.MediumGaps)
    }
    return @($Rows | Sort-Object `
        @{ E = { if ($_.Status -eq 'Gap') { 0 } else { 1 } } },
        @{ E = { & $weightOf $_ }; Descending = $true },
        @{ E = { if ($null -eq $_.SizeGB) { -1 } else { [double]$_.SizeGB } }; Descending = $true },
        @{ E = { "$($_.ResourceType)" } },
        @{ E = { "$($_.ResourceName)" } })
}

#endregion
