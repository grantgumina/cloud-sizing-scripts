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
