<#
    CVSizing.Metrics.Azure.ps1 - One wrapper for every Azure Monitor metric read in the Azure sizing script.

    Why this exists: the script asked for BlobCapacity / BlobCount / ContainerCount over a ONE HOUR window. Those
    are DAILY metrics, emitted once per day with up to ~24h of ingestion lag, so the query routinely returned no
    datapoints at all - and the caller then reported the resulting 0 as though it had measured an empty account.
    Every storage capacity column read 0. The same one-hour window was copy-pasted to 13 call sites across SQL,
    MySQL, PostgreSQL, Cosmos and NetApp.

    Two rules:
      - "No datapoint" is NOT zero. It returns $null with Status = 'NoDatapoint', matching the Unknown-vs-Gap
        discipline in CVSizing.Resilience.ps1: a value we did not measure must never masquerade as a measurement.
      - A datapoint whose value genuinely IS 0 returns 0 with Status = 'Ok'. Callers must be able to tell those
        apart, which is the whole point.

    Kept separate from CVSizing.Console.ps1 because that file is dot-sourced by the AWS and M365 scripts too and
    must stay cloud-agnostic. Tests: tests/Invoke-CVAzureMetricsTests.ps1 (injectable -Fetch, no Az required).
#>

# Metrics that Azure emits about once per day. These need a wide window or they come back empty.
$script:CVAzDailyMetrics = @(
    'BlobCapacity', 'BlobCount', 'ContainerCount',
    'FileCapacity', 'FileCount', 'FileShareCount',
    'TableCapacity', 'TableCount', 'QueueCapacity', 'QueueMessageCount',
    'UsedCapacity'
)

function Get-CVAzMetricWindowHours {
    <# .SYNOPSIS  How far back to look for a given metric name. Daily metrics need >= 72h to survive lag. #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$MetricName, [int]$DefaultHours = 48)
    if ($MetricName -and ($script:CVAzDailyMetrics -contains $MetricName)) { return 72 }
    return $DefaultHours
}

function Get-CVAzMetricValue {
    <#
      .SYNOPSIS  Read one Azure Monitor metric and report whether it was actually measured.
      .DESCRIPTION Returns the LAST non-null datapoint in the window (metrics are emitted over time; the most
                   recent reading is the current state). Never converts absence into 0.
      .PARAMETER Fetch  Optional scriptblock override for tests, invoked as & $Fetch $ResourceId $MetricName
                        $StartTime $AggregationType and expected to return Get-AzMetric-shaped objects.
      .OUTPUTS   pscustomobject { Value; HasDatapoint; Status; MetricName; WindowHours }
                 Status: Ok | NoDatapoint | Error | Unsupported
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string]$MetricName,
        [ValidateSet('Maximum', 'Average', 'Total', 'Minimum', 'Count')][string]$AggregationType = 'Maximum',
        [int]$WindowHours,
        [scriptblock]$Fetch
    )

    if (-not $WindowHours) { $WindowHours = Get-CVAzMetricWindowHours $MetricName }
    $start = (Get-Date).ToUniversalTime().AddHours(-$WindowHours)

    $result = [pscustomobject]@{
        Value        = $null
        HasDatapoint = $false
        Status       = 'NoDatapoint'
        MetricName   = $MetricName
        WindowHours  = $WindowHours
    }

    try {
        $raw = if ($Fetch) {
            & $Fetch $ResourceId $MetricName $start $AggregationType
        } else {
            Get-AzMetric -ResourceId $ResourceId -MetricName $MetricName -AggregationType $AggregationType `
                         -StartTime $start -WarningAction SilentlyContinue -ErrorAction Stop
        }
    } catch {
        $result.Status = 'Error'
        return $result
    }

    if (-not $raw) { return $result }

    # Get-AzMetric returns one object per metric name; Data is the time series.
    $series = @($raw | Where-Object { $_ } | ForEach-Object { $_.Data } | Where-Object { $_ })
    if (-not $series.Count) { return $result }

    $values = @(
        foreach ($d in $series) {
            $v = $d.PSObject.Properties[$AggregationType]
            if ($v -and $null -ne $v.Value) { [double]$v.Value }
        }
    )
    if (-not $values.Count) { return $result }

    $result.Value        = $values[-1]   # most recent reading in the window
    $result.HasDatapoint = $true
    $result.Status       = 'Ok'
    return $result
}

function Get-CVAzMetricValueSet {
    <#
      .SYNOPSIS  Read several metrics for one resource, returning a name -> result map.
      .DESCRIPTION Queries each metric independently so one unsupported name cannot blank the others - the
                   previous code requested three names in a single call and matched them back out of one result
                   set, so any single failure lost all three.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string[]]$MetricName,
        [ValidateSet('Maximum', 'Average', 'Total', 'Minimum', 'Count')][string]$AggregationType = 'Maximum',
        [int]$WindowHours,
        [scriptblock]$Fetch
    )
    $out = @{}
    foreach ($m in $MetricName) {
        $splat = @{ ResourceId = $ResourceId; MetricName = $m; AggregationType = $AggregationType }
        if ($WindowHours) { $splat.WindowHours = $WindowHours }
        if ($Fetch)       { $splat.Fetch       = $Fetch }
        $out[$m] = Get-CVAzMetricValue @splat
    }
    return $out
}
