#requires -Version 7.2
<#
    Tests for the Azure Monitor metric wrapper (src/common/CVSizing.Metrics.Azure.ps1). No Az modules required -
    Get-CVAzMetricValue takes an injectable -Fetch scriptblock.

    The defect being locked down: the script asked for BlobCapacity/BlobCount/ContainerCount over a ONE HOUR
    window. Those are daily metrics with ingestion lag, so the query usually returned nothing - and the caller
    reported the resulting 0 as a measured empty storage account. Every capacity column read 0.

    The rule: no datapoint -> $null. A datapoint whose value is 0 -> 0. Those must never collapse together.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Metrics.Azure.ps1')

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }

# Shape a Get-AzMetric result: one metric object whose .Data is a time series of aggregation-named properties.
function New-Metric { param([double[]]$Values, [string]$Agg = 'Maximum')
    $data = @(foreach ($v in $Values) { [pscustomobject]@{ $Agg = $v; TimeStamp = (Get-Date) } })
    @([pscustomobject]@{ Id = '/x/providers/Microsoft.Insights/metrics/m'; Data = $data }) }

Write-Host "`n[1] No datapoint is Unknown, not zero"
$empty = Get-CVAzMetricValue -ResourceId '/r' -MetricName 'BlobCapacity' -Fetch { New-Metric -Values @() }
Assert-CV 'value is null'          ($null -eq $empty.Value) $true
Assert-CV 'HasDatapoint false'     $empty.HasDatapoint $false
Assert-CV 'status NoDatapoint'     $empty.Status 'NoDatapoint'
$nothing = Get-CVAzMetricValue -ResourceId '/r' -MetricName 'BlobCapacity' -Fetch { $null }
Assert-CV 'null result -> null'    ($null -eq $nothing.Value) $true
Assert-CV 'null result -> NoDatapoint' $nothing.Status 'NoDatapoint'

Write-Host "`n[2] A measured ZERO is reported as zero, with Ok"
$zero = Get-CVAzMetricValue -ResourceId '/r' -MetricName 'BlobCapacity' -Fetch { New-Metric -Values @(0) }
Assert-CV 'value is 0'             $zero.Value 0
Assert-CV 'HasDatapoint true'      $zero.HasDatapoint $true
Assert-CV 'status Ok'              $zero.Status 'Ok'
# The distinction the old code could not express:
Assert-CV 'zero and no-datapoint are distinguishable' ([bool]($zero.Status -ne $empty.Status)) $true

Write-Host "`n[3] Most recent datapoint in the window wins"
$series = Get-CVAzMetricValue -ResourceId '/r' -MetricName 'BlobCapacity' -Fetch { New-Metric -Values @(10, 20, 33) }
Assert-CV 'last value used'        $series.Value 33

Write-Host "`n[4] A failing query is Error, not a silent zero"
$err = Get-CVAzMetricValue -ResourceId '/r' -MetricName 'BlobCapacity' -Fetch { throw 'AuthorizationFailed' }
Assert-CV 'status Error'           $err.Status 'Error'
Assert-CV 'value null on error'    ($null -eq $err.Value) $true

Write-Host "`n[5] Daily metrics get a window wide enough to contain a datapoint"
foreach ($m in @('BlobCapacity','BlobCount','ContainerCount','UsedCapacity','FileCapacity')) {
    Assert-CV "$m window >= 72h" ([bool]((Get-CVAzMetricWindowHours $m) -ge 72)) $true
}
# Frequently-emitted metrics still get far more than the 1 hour that caused the bug.
foreach ($m in @('storage','allocated_data_storage','VolumeLogicalSize','storage_space_used_mb')) {
    Assert-CV "$m window >= 48h" ([bool]((Get-CVAzMetricWindowHours $m) -ge 48)) $true
}
$res = Get-CVAzMetricValue -ResourceId '/r' -MetricName 'BlobCapacity' -Fetch { New-Metric -Values @(1) }
Assert-CV 'window reported on the result' ([bool]($res.WindowHours -ge 72)) $true

Write-Host "`n[6] The window actually reaches back that far"
$captured = $null
$null = Get-CVAzMetricValue -ResourceId '/r' -MetricName 'BlobCapacity' -Fetch {
    param($rid, $metric, $start, $agg) $script:capturedStart = $start; New-Metric -Values @(5) }
$hoursBack = ([datetime]::UtcNow - $script:capturedStart).TotalHours
Assert-CV 'start time is >= 70h ago' ([bool]($hoursBack -ge 70)) $true

Write-Host "`n[7] Multi-metric reads are independent"
# The old storage code asked for three names in ONE call and matched them back out, so any single failure lost
# all three. Each is queried separately now.
$set = Get-CVAzMetricValueSet -ResourceId '/r' -MetricName @('BlobCapacity','BlobCount','ContainerCount') -Fetch {
    param($rid, $metric, $start, $agg)
    if ($metric -eq 'BlobCount') { throw 'unsupported' }
    New-Metric -Values @(7)
}
Assert-CV 'BlobCapacity ok'        $set['BlobCapacity'].Status 'Ok'
Assert-CV 'BlobCapacity value'     $set['BlobCapacity'].Value 7
Assert-CV 'BlobCount errored alone' $set['BlobCount'].Status 'Error'
Assert-CV 'ContainerCount survives' $set['ContainerCount'].Value 7

Write-Host ("`n======  {0} passed, {1} failed  ======`n" -f $script:Pass, $script:Fail) `
           -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
