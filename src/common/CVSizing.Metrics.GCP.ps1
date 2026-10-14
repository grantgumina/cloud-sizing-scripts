<#
    CVSizing.Metrics.GCP.ps1 - Cloud Monitoring reads for GCP capacity sizing (Cloud Storage and BigQuery).

    Why this exists: bucket sizing ran `gsutil du -s`, which LISTS EVERY OBJECT (1,000 per request) and sums the
    sizes client-side, and BigQuery sizing ran `bq show` once per table - a separate Python process each, with the
    "bulk" INFORMATION_SCHEMA.TABLE_STORAGE shortcut qualified per dataset, which that view does not support, so it
    always failed and fell back. Both scaled with object/table count rather than resource count, which is how large
    estates took 3-5+ hours. Cloud Monitoring already holds both figures per bucket and per dataset: one paged
    query per project replaces all of it.

    Trade-offs, accepted deliberately:
      - Freshness. storage/v2/total_bytes is measured ONCE PER DAY. bigquery storage/stored_bytes is sampled
        every 30 min and can take up to 3h to become visible. Sizing tolerates that; a point-in-time figure is
        not the goal.
      - BigQuery is LOGICAL bytes only. Monitoring has no physical-bytes metric, so TotalPhysicalSizeGB is blank
        (not collected), never 0.
      - Empty buckets are not tracked by the GCS metric at all. Absence is resolved by Resolve-CVGcsBucketSize
        using the bucket's creation time, never silently turned into 0.

    Same Unknown-vs-zero rule as CVSizing.Metrics.Azure.ps1: a value we did not measure is $null, a measured
    zero is 0. Tests: tests/Invoke-CVGcpMetricsTests.ps1 (injectable -Fetch, no gcloud required).
#>

# The GCS metric is daily; 48h survives one missed measurement plus ingestion delay. BigQuery is sampled every
# 30 min with up to 3h visibility lag; 12h is comfortably wide without dragging in long-deleted tables.
$script:CVGcsMetricLookbackHours = 48
$script:CVBqMetricLookbackHours  = 12

function Get-CVGcpAccessToken {
    <# .SYNOPSIS  Bearer token for the active gcloud account, or $null. Same source the AlloyDB/Spanner reads use. #>
    try { $t = (& gcloud auth print-access-token 2>$null | Select-Object -First 1) } catch { return $null }
    if ($t) { return "$t".Trim() }
    return $null
}

function Get-CVGcpRestErrorText {
    <#
      .SYNOPSIS  Turn an Invoke-RestMethod failure into one line: "HTTP 403 PERMISSION_DENIED: <message>".
      .DESCRIPTION Google's error body is JSON ({error:{code,status,message}}). SERVICE_DISABLED surfaces as a 403
                   whose message names the API to enable, which is the single most actionable thing to show.
    #>
    param($ErrorRecord)
    $code = $null
    try { $code = [int]$ErrorRecord.Exception.Response.StatusCode } catch {}
    $status = $null; $msg = $null
    try {
        $body = $ErrorRecord.ErrorDetails.Message | ConvertFrom-Json -ErrorAction Stop
        $status = $body.error.status; $msg = $body.error.message
    } catch {}
    if (-not $msg) { $msg = $ErrorRecord.Exception.Message }
    $prefix = @(@($(if ($code) { "HTTP $code" }), $status) | Where-Object { $_ }) -join ' '
    if ($prefix) { return "${prefix}: $msg" }
    return "$msg"
}

function Invoke-CVGcpRestPaged {
    <#
      .SYNOPSIS  GET a Google REST collection, following nextPageToken, and return every page's response.
      .PARAMETER Fetch  Optional scriptblock override for tests, invoked as & $Fetch $Url and expected to return the
                        parsed response (or throw).
      .OUTPUTS   pscustomobject { Status = Ok|Error; Error; Pages = List[psobject] }
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$AccessToken,
        [scriptblock]$Fetch,
        [int]$MaxPages = 1000
    )
    $result = [pscustomobject]@{ Status = 'Ok'; Error = $null; Pages = [System.Collections.Generic.List[psobject]]::new() }
    if (-not $Fetch -and -not $AccessToken) { $result.Status = 'Error'; $result.Error = 'No gcloud access token (run gcloud auth login)'; return $result }
    $sep = if ($Url.Contains('?')) { '&' } else { '?' }
    $pageToken = $null; $n = 0
    do {
        $n++
        $u = if ($pageToken) { "$Url${sep}pageToken=$([System.Uri]::EscapeDataString($pageToken))" } else { $Url }
        try {
            $resp = if ($Fetch) { & $Fetch $u }
                    else { Invoke-RestMethod -Uri $u -Headers @{ Authorization = "Bearer $AccessToken" } -Method GET -ErrorAction Stop }
        } catch {
            $result.Status = 'Error'; $result.Error = Get-CVGcpRestErrorText $_
            return $result
        }
        if ($null -ne $resp) { $result.Pages.Add($resp) }
        $pageToken = if ($resp -and $resp.PSObject.Properties['nextPageToken']) { $resp.nextPageToken } else { $null }
    } while ($pageToken -and $n -lt $MaxPages)
    return $result
}

function Invoke-CVGcpTimeSeriesQuery {
    <#
      .SYNOPSIS  Latest value of a GAUGE metric per label group, for one project, in one paged query.
      .DESCRIPTION Aligns every series with ALIGN_NEXT_OLDER over a single period equal to the lookback window,
                   which yields the most recent sample in the window, then REDUCE_SUMs across the series that
                   share the -GroupBy labels (e.g. storage classes within a bucket). The filter pins
                   resource.label.project_id: querying a metrics-scope host project otherwise also returns the
                   series of every project it monitors, which would double-count them.
      .OUTPUTS   pscustomobject { Status = Ok|Error; Error; Series = List[psobject] { Labels (hashtable); Value } }
                 Ok with zero Series means "queried successfully, nothing reported" - NOT an error.
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$MetricType,
        [Parameter(Mandatory)][string]$ResourceType,
        [Parameter(Mandatory)][string[]]$GroupBy,
        [Parameter(Mandatory)][int]$LookbackHours,
        [string]$AccessToken,
        [scriptblock]$Fetch,
        [datetime]$NowUtc = [DateTime]::UtcNow
    )
    $filter = 'metric.type="{0}" AND resource.type="{1}" AND resource.label.project_id="{2}"' -f $MetricType, $ResourceType, $ProjectId
    $end    = $NowUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $start  = $NowUtc.AddHours(-$LookbackHours).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $q = [System.Collections.Generic.List[string]]::new()
    $q.Add('filter=' + [System.Uri]::EscapeDataString($filter))
    $q.Add("interval.startTime=$start"); $q.Add("interval.endTime=$end")
    $q.Add("aggregation.alignmentPeriod=$($LookbackHours * 3600)s")
    $q.Add('aggregation.perSeriesAligner=ALIGN_NEXT_OLDER')
    $q.Add('aggregation.crossSeriesReducer=REDUCE_SUM')
    foreach ($g in $GroupBy) { $q.Add('aggregation.groupByFields=' + [System.Uri]::EscapeDataString($g)) }
    $q.Add('pageSize=100000')
    $url = 'https://monitoring.googleapis.com/v3/projects/{0}/timeSeries?{1}' -f $ProjectId, ($q -join '&')

    $paged = Invoke-CVGcpRestPaged -Url $url -AccessToken $AccessToken -Fetch $Fetch
    $out = [pscustomobject]@{ Status = $paged.Status; Error = $paged.Error; Series = [System.Collections.Generic.List[psobject]]::new() }
    if ($paged.Status -ne 'Ok') { return $out }
    foreach ($page in $paged.Pages) {
        foreach ($ts in @($page.timeSeries)) {
            if (-not $ts) { continue }
            $labels = @{}
            foreach ($src in @($ts.resource.labels, $ts.metric.labels)) {
                if ($src) { foreach ($p in $src.PSObject.Properties) { $labels[$p.Name] = "$($p.Value)" } }
            }
            # Points are newest-first; with one alignment period there is normally exactly one.
            $pt = @($ts.points) | Select-Object -First 1
            if (-not $pt -or -not $pt.value) { continue }
            $v = $null
            if ($null -ne $pt.value.int64Value)      { $v = [double]$pt.value.int64Value }
            elseif ($null -ne $pt.value.doubleValue) { $v = [double]$pt.value.doubleValue }
            if ($null -eq $v) { continue }
            $out.Series.Add([pscustomobject]@{ Labels = $labels; Value = $v })
        }
    }
    return $out
}

# ---------------------------------------------------------------------------------------------------------------
# Cloud Storage
# ---------------------------------------------------------------------------------------------------------------

function Get-CVGcsBucketSizeMap {
    <#
      .SYNOPSIS  One Monitoring query for a project -> per-bucket live and noncurrent bytes.
      .DESCRIPTION storage/v2/total_bytes splits each bucket by storage_class and by type (live-object,
                   noncurrent-object, soft-deleted-object, multipart-upload). Live objects are what `gsutil du -s`
                   reported and what is protected; noncurrent versions are carried separately for versioned
                   buckets. Soft-deleted data and in-flight multipart uploads are not protectable and are dropped.
      .OUTPUTS   pscustomobject { Status; Error; Buckets = hashtable name -> { LiveBytes; NoncurrentBytes } }
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectId,
        [string]$AccessToken,
        [scriptblock]$Fetch,
        [datetime]$NowUtc = [DateTime]::UtcNow
    )
    $q = Invoke-CVGcpTimeSeriesQuery -ProjectId $ProjectId -MetricType 'storage.googleapis.com/storage/v2/total_bytes' `
            -ResourceType 'gcs_bucket' -GroupBy @('resource.label.bucket_name', 'metric.label.type') `
            -LookbackHours $script:CVGcsMetricLookbackHours -AccessToken $AccessToken -Fetch $Fetch -NowUtc $NowUtc
    $map = @{}
    foreach ($s in $q.Series) {
        $name = $s.Labels['bucket_name']; if (-not $name) { continue }
        if (-not $map.ContainsKey($name)) { $map[$name] = [pscustomobject]@{ LiveBytes = [int64]0; NoncurrentBytes = [int64]0 } }
        switch ($s.Labels['type']) {
            'live-object'       { $map[$name].LiveBytes       += [int64][math]::Round($s.Value) }
            'noncurrent-object' { $map[$name].NoncurrentBytes += [int64][math]::Round($s.Value) }
        }
    }
    return [pscustomobject]@{ Status = $q.Status; Error = $q.Error; Buckets = $map }
}

function Resolve-CVGcsBucketSize {
    <#
      .SYNOPSIS  Decide one bucket's reported size from the project's Monitoring result.
      .DESCRIPTION The metric does not track empty buckets, so "no series" has two meanings: empty, or created
                   after the last daily measurement. Creation time separates them. Anything we cannot tell apart
                   stays $null (blank = not collected), never 0.
      .OUTPUTS   pscustomobject { Bytes; NoncurrentBytes; Status = Ok|Empty|NotYetMeasured|NoDatapoint|Error; Note }
    #>
    param(
        [Parameter(Mandatory)][string]$BucketName,
        [Parameter(Mandatory)]$SizeMap,
        $CreatedUtc,
        [datetime]$NowUtc = [DateTime]::UtcNow
    )
    if ($SizeMap.Status -ne 'Ok') {
        return [pscustomobject]@{ Bytes = $null; NoncurrentBytes = $null; Status = 'Error'; Note = "Cloud Monitoring query failed: $($SizeMap.Error)" }
    }
    $e = $SizeMap.Buckets[$BucketName]
    if ($e) {
        return [pscustomobject]@{ Bytes = $e.LiveBytes; NoncurrentBytes = $e.NoncurrentBytes; Status = 'Ok'; Note = '' }
    }
    $created = $null
    if ($CreatedUtc) { try { $created = ([datetime]$CreatedUtc).ToUniversalTime() } catch {} }
    if (-not $created) {
        return [pscustomobject]@{ Bytes = $null; NoncurrentBytes = $null; Status = 'NoDatapoint'; Note = 'No Cloud Monitoring datapoint and creation time unknown' }
    }
    if (($NowUtc - $created).TotalHours -lt $script:CVGcsMetricLookbackHours) {
        return [pscustomobject]@{ Bytes = $null; NoncurrentBytes = $null; Status = 'NotYetMeasured'; Note = 'Bucket created within the last 48h; Cloud Monitoring measures size once a day' }
    }
    return [pscustomobject]@{ Bytes = [int64]0; NoncurrentBytes = [int64]0; Status = 'Empty'; Note = 'Not tracked by Cloud Monitoring, which omits buckets with no objects' }
}

# ---------------------------------------------------------------------------------------------------------------
# BigQuery
# ---------------------------------------------------------------------------------------------------------------

function Get-CVBqDatasetList {
    <#
      .SYNOPSIS  Every dataset in a project via the REST API (replaces `bq ls`, removing the bq CLI dependency).
      .OUTPUTS   pscustomobject { Status; Error; Datasets = List[psobject] { DatasetId; Location } }
    #>
    param([Parameter(Mandatory)][string]$ProjectId, [string]$AccessToken, [scriptblock]$Fetch)
    $url = 'https://bigquery.googleapis.com/bigquery/v2/projects/{0}/datasets?all=true&maxResults=1000' -f $ProjectId
    $paged = Invoke-CVGcpRestPaged -Url $url -AccessToken $AccessToken -Fetch $Fetch
    $out = [pscustomobject]@{ Status = $paged.Status; Error = $paged.Error; Datasets = [System.Collections.Generic.List[psobject]]::new() }
    foreach ($page in $paged.Pages) {
        foreach ($d in @($page.datasets)) {
            if ($d -and $d.datasetReference) { $out.Datasets.Add([pscustomobject]@{ DatasetId = $d.datasetReference.datasetId; Location = $d.location }) }
        }
    }
    return $out
}

function Get-CVBqDatasetSizeMap {
    <#
      .SYNOPSIS  Two Monitoring queries for a project -> per-dataset logical bytes, table count, largest table.
      .DESCRIPTION storage/stored_bytes labels only the 100 largest tables in a dataset; the rest arrive as one
                   series with an empty table label. Summing every series per dataset is therefore the dataset
                   total, and the largest LABELLED table is the dataset's largest table.
      .OUTPUTS   pscustomobject { Status; Error; Datasets = hashtable id -> { LogicalBytes; LargestTable;
                 LargestTableBytes }; TableCounts = hashtable id -> count; TableCountStatus }
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectId,
        [string]$AccessToken,
        [scriptblock]$Fetch,
        [datetime]$NowUtc = [DateTime]::UtcNow
    )
    $bytesQ = Invoke-CVGcpTimeSeriesQuery -ProjectId $ProjectId -MetricType 'bigquery.googleapis.com/storage/stored_bytes' `
                -ResourceType 'bigquery_dataset' -GroupBy @('resource.label.dataset_id', 'metric.label.table') `
                -LookbackHours $script:CVBqMetricLookbackHours -AccessToken $AccessToken -Fetch $Fetch -NowUtc $NowUtc
    $countQ = Invoke-CVGcpTimeSeriesQuery -ProjectId $ProjectId -MetricType 'bigquery.googleapis.com/storage/table_count' `
                -ResourceType 'bigquery_dataset' -GroupBy @('resource.label.dataset_id') `
                -LookbackHours $script:CVBqMetricLookbackHours -AccessToken $AccessToken -Fetch $Fetch -NowUtc $NowUtc
    $ds = @{}
    foreach ($s in $bytesQ.Series) {
        $id = $s.Labels['dataset_id']; if (-not $id) { continue }
        if (-not $ds.ContainsKey($id)) { $ds[$id] = [pscustomobject]@{ LogicalBytes = [int64]0; LargestTable = ''; LargestTableBytes = [int64]0 } }
        $b = [int64][math]::Round($s.Value)
        $ds[$id].LogicalBytes += $b
        $t = $s.Labels['table']
        if ($t -and $b -gt $ds[$id].LargestTableBytes) { $ds[$id].LargestTable = $t; $ds[$id].LargestTableBytes = $b }
    }
    $counts = @{}
    foreach ($s in $countQ.Series) { $id = $s.Labels['dataset_id']; if ($id) { $counts[$id] = [int][math]::Round($s.Value) } }
    return [pscustomobject]@{
        Status = $bytesQ.Status; Error = $bytesQ.Error; Datasets = $ds
        TableCounts = $counts; TableCountStatus = $countQ.Status
    }
}

function Resolve-CVBqDatasetSize {
    <#
      .SYNOPSIS  Decide one dataset's reported size from the project's Monitoring result.
      .DESCRIPTION A dataset with no stored_bytes series is either empty or too new to have been sampled. Only a
                   table_count of 0 proves empty; otherwise it stays $null.
      .OUTPUTS   pscustomobject { LogicalBytes; TableCount; LargestTable; LargestTableBytes; Status; Note }
    #>
    param([Parameter(Mandatory)][string]$DatasetId, [Parameter(Mandatory)]$SizeMap)
    $count = if ($SizeMap.TableCounts.ContainsKey($DatasetId)) { $SizeMap.TableCounts[$DatasetId] } else { $null }
    if ($SizeMap.Status -ne 'Ok') {
        return [pscustomobject]@{ LogicalBytes = $null; TableCount = $count; LargestTable = ''; LargestTableBytes = $null; Status = 'Error'; Note = "Cloud Monitoring query failed: $($SizeMap.Error)" }
    }
    $e = $SizeMap.Datasets[$DatasetId]
    if ($e) {
        $lb = if ($e.LargestTable) { $e.LargestTableBytes } else { $null }
        return [pscustomobject]@{ LogicalBytes = $e.LogicalBytes; TableCount = $count; LargestTable = $e.LargestTable; LargestTableBytes = $lb; Status = 'Ok'; Note = '' }
    }
    if ($count -eq 0 -and $null -ne $count) {
        return [pscustomobject]@{ LogicalBytes = [int64]0; TableCount = 0; LargestTable = ''; LargestTableBytes = $null; Status = 'Empty'; Note = 'Dataset has no tables' }
    }
    return [pscustomobject]@{ LogicalBytes = $null; TableCount = $count; LargestTable = ''; LargestTableBytes = $null; Status = 'NoDatapoint'; Note = 'No Cloud Monitoring datapoint (empty dataset, or created within the last few hours)' }
}
