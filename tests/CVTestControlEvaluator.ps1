<#
    CVTestControlEvaluator.ps1 - a TEST-ONLY evaluator for control Test blocks.

    Production never executes a control's Test block. src/common/CVSizing.Resilience.ps1 parses those blocks for
    their `$r.<Field>` references to decide which inventory fields become signal columns, and the backend applies
    the actual pass/fail thresholds. The scoring engine that used to run them (Invoke-CVResilience,
    Get-CVControlScore, Get-CVResilienceSummary, ConvertTo-CVOutcome, ...) was deleted from src/ once every cloud
    moved to the judgement-free signals export.

    The per-cloud suites still assert outcomes - 'Continuous -> Met', 'BackupPolicyStatus Unknown -> Unknown' -
    and those assertions are worth keeping even though production does not run the logic. They are the written
    contract the backend implements, and they are how we catch a Test block that reads a field name the inventory
    never sets. So the evaluator lives here, in the test layer, rather than shipping as unreachable code in src/.

    Deliberately NOT reproduced from the deleted engine:
      - Score / severity weighting (Critical 3, High 2, Medium 1) and the category rollups. Those are the
        backend's to define now, so pinning them here would assert a contract this repo no longer owns.
      - ConvertTo-CVResilienceColumns / Get-CVControlCatalog - both fed CSV columns that no longer exist.
#>

function ConvertTo-CVOutcome {
    <# .SYNOPSIS  Normalize a Test result into an outcome label. $null is Unknown, never a Gap. #>
    param($Value)
    if ($Value -is [string] -and $Value -eq 'NA') { return 'NA' }
    if ($null -eq $Value) { return 'Unknown' }
    return $(if ($Value) { 'Met' } else { 'Gap' })
}

function Invoke-CVResilience {
    <#
      .SYNOPSIS  Run a control set against one resource and report per-control outcomes.
      .OUTPUTS   pscustomobject { Results[]; MetCount; GapCount; UnknownCount }
                 Each Results entry: { Id; Title; Category; Severity; Outcome; Detail }.
      .NOTES     No Score property - see the file header.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Resource,
        [Parameter(Mandatory)][object[]]$Controls
    )
    $results = foreach ($c in $Controls) {
        $outcome = 'Unknown'; $detail = ''
        # A throwing Test is Unknown, not a Gap: the same discipline the collection-status helpers enforce.
        try   { $outcome = ConvertTo-CVOutcome (& $c.Test $Resource) }
        catch { $outcome = 'Unknown'; $detail = $_.Exception.Message }
        [pscustomobject]@{ Id = $c.Id; Title = $c.Title; Category = $c.Category; Severity = $c.Severity; Outcome = $outcome; Detail = $detail }
    }
    [pscustomobject]@{
        Results      = @($results)
        MetCount     = @($results | Where-Object { $_.Outcome -eq 'Met' }).Count
        GapCount     = @($results | Where-Object { $_.Outcome -eq 'Gap' }).Count
        UnknownCount = @($results | Where-Object { $_.Outcome -eq 'Unknown' }).Count
    }
}
