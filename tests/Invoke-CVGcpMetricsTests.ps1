#requires -Version 7.2
<#
    Tests for the Cloud Monitoring sizing layer (src/common/CVSizing.Metrics.GCP.ps1). No gcloud required - every
    reader takes an injectable -Fetch scriptblock that receives the request URL and returns the parsed response.

    What is being locked down:
      - Buckets: live bytes are the size; noncurrent versions are carried separately; soft-deleted and multipart
        bytes are not counted. A bucket missing from the metric is 0 only when it is old enough to have been
        measured - otherwise blank. A failed query is blank, never 0.
      - BigQuery: the dataset total includes the unlabelled "everything outside the top 100 tables" series.
      - Every query pins resource.label.project_id, so a metrics-scope host project cannot double-count the
        projects it monitors.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Metrics.GCP.ps1')

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }

# One Monitoring timeSeries entry, shaped like the REST response after aggregation.
function New-TS { param([hashtable]$Resource = @{}, [hashtable]$Metric = @{}, $Int, $Double)
    $v = if ($null -ne $Int) { [pscustomobject]@{ int64Value = "$Int" } } else { [pscustomobject]@{ doubleValue = $Double } }
    [pscustomobject]@{
        resource = [pscustomobject]@{ labels = [pscustomobject]$Resource }
        metric   = [pscustomobject]@{ labels = [pscustomobject]$Metric }
        points   = @([pscustomobject]@{ value = $v })
    } }

$now = [datetime]::Parse('2026-10-14T12:00:00Z').ToUniversalTime()

Write-Host "`n[1] Bucket sizes: live is the size, noncurrent separate, soft-deleted/multipart ignored"
$script:urls = [System.Collections.Generic.List[string]]::new()
$gcsFetch = {
    param($u) $script:urls.Add($u)
    [pscustomobject]@{ timeSeries = @(
        New-TS -Resource @{ bucket_name = 'b1' } -Metric @{ type = 'live-object' }         -Double 1000
        New-TS -Resource @{ bucket_name = 'b1' } -Metric @{ type = 'noncurrent-object' }   -Double 250
        New-TS -Resource @{ bucket_name = 'b1' } -Metric @{ type = 'soft-deleted-object' } -Double 99999
        New-TS -Resource @{ bucket_name = 'b1' } -Metric @{ type = 'multipart-upload' }    -Double 77777
        New-TS -Resource @{ bucket_name = 'b2' } -Metric @{ type = 'live-object' }         -Double 5e9
        New-TS -Resource @{ bucket_name = 'b3' } -Metric @{ type = 'noncurrent-object' }   -Double 42
    ) } }
$map = Get-CVGcsBucketSizeMap -ProjectId 'proj-a' -Fetch $gcsFetch -NowUtc $now
Assert-CV 'query ok'                      $map.Status 'Ok'
Assert-CV 'b1 live bytes'                 $map.Buckets['b1'].LiveBytes 1000
Assert-CV 'b1 noncurrent bytes'           $map.Buckets['b1'].NoncurrentBytes 250
Assert-CV 'b2 large double -> int64'      $map.Buckets['b2'].LiveBytes 5000000000
Assert-CV 'b3 only noncurrent -> live 0'  $map.Buckets['b3'].LiveBytes 0
$u = [System.Uri]::UnescapeDataString($script:urls[0])
Assert-CV 'filter pins project_id'        ($u -match 'resource\.label\.project_id="proj-a"') $true
Assert-CV 'groups by bucket and type'     (($u -match 'groupByFields=resource\.label\.bucket_name') -and ($u -match 'groupByFields=metric\.label\.type')) $true
Assert-CV 'one alignment period = 48h'    ($u -match 'alignmentPeriod=172800s') $true
Assert-CV 'URL targets the project'       ($u -match '/v3/projects/proj-a/timeSeries\?') $true

Write-Host "`n[2] Resolving a bucket: absence is 0 only when the bucket is old enough to have been measured"
$ok = Resolve-CVGcsBucketSize -BucketName 'b1' -SizeMap $map -CreatedUtc '2020-01-01T00:00:00Z' -NowUtc $now
Assert-CV 'present -> Ok'                 $ok.Status 'Ok'
Assert-CV 'present -> live bytes'         $ok.Bytes 1000
$empty = Resolve-CVGcsBucketSize -BucketName 'old-empty' -SizeMap $map -CreatedUtc '2020-01-01T00:00:00Z' -NowUtc $now
Assert-CV 'missing + old -> Empty'        $empty.Status 'Empty'
Assert-CV 'missing + old -> 0'            $empty.Bytes 0
$new = Resolve-CVGcsBucketSize -BucketName 'brand-new' -SizeMap $map -CreatedUtc $now.AddHours(-3) -NowUtc $now
Assert-CV 'missing + new -> NotYetMeasured' $new.Status 'NotYetMeasured'
Assert-CV 'missing + new -> null'         ($null -eq $new.Bytes) $true
$unk = Resolve-CVGcsBucketSize -BucketName 'mystery' -SizeMap $map -CreatedUtc $null -NowUtc $now
Assert-CV 'missing + no created -> null'  ($null -eq $unk.Bytes) $true
Assert-CV 'missing + no created -> NoDatapoint' $unk.Status 'NoDatapoint'

Write-Host "`n[3] A failed query is Error with blank sizes, never a silent zero"
$failMap = Get-CVGcsBucketSizeMap -ProjectId 'proj-x' -Fetch { throw 'Permission denied' } -NowUtc $now
Assert-CV 'status Error'                  $failMap.Status 'Error'
Assert-CV 'error text kept'               ($failMap.Error -match 'Permission denied') $true
$failR = Resolve-CVGcsBucketSize -BucketName 'b1' -SizeMap $failMap -CreatedUtc '2020-01-01' -NowUtc $now
Assert-CV 'resolved Error'                $failR.Status 'Error'
Assert-CV 'resolved null'                 ($null -eq $failR.Bytes) $true
$noTok = Invoke-CVGcpRestPaged -Url 'https://x.example/y'
Assert-CV 'no token and no fetch -> Error' $noTok.Status 'Error'
$emptyResp = Get-CVGcsBucketSizeMap -ProjectId 'proj-e' -Fetch { [pscustomobject]@{ unit = 'By' } } -NowUtc $now
Assert-CV 'empty response is Ok, not Error' $emptyResp.Status 'Ok'
Assert-CV 'empty response has no buckets'  $emptyResp.Buckets.Count 0

Write-Host "`n[4] Pagination is followed"
$script:calls = 0
$pagedFetch = {
    param($u) $script:calls++
    if ($u -notmatch 'pageToken=') { [pscustomobject]@{ timeSeries = @(New-TS -Resource @{ bucket_name = 'p1' } -Metric @{ type = 'live-object' } -Double 1); nextPageToken = 'tok 2' } }
    else { [pscustomobject]@{ timeSeries = @(New-TS -Resource @{ bucket_name = 'p2' } -Metric @{ type = 'live-object' } -Double 2) } } }
$paged = Get-CVGcsBucketSizeMap -ProjectId 'proj-p' -Fetch $pagedFetch -NowUtc $now
Assert-CV 'two pages fetched'             $script:calls 2
Assert-CV 'both pages merged'             $paged.Buckets.Count 2

Write-Host "`n[5] BigQuery: dataset total includes the unlabelled tail; largest labelled table wins"
$bqFetch = {
    param($u)
    if ($u -match 'stored_bytes') {
        [pscustomobject]@{ timeSeries = @(
            New-TS -Resource @{ dataset_id = 'ds1' } -Metric @{ table = 'big' }   -Int 700
            New-TS -Resource @{ dataset_id = 'ds1' } -Metric @{ table = 'small' } -Int 100
            New-TS -Resource @{ dataset_id = 'ds1' } -Metric @{ table = '' }      -Int 5000   # the >100-tables tail
            New-TS -Resource @{ dataset_id = 'ds2' } -Metric @{ table = 't' }     -Int 0
        ) }
    } else {
        [pscustomobject]@{ timeSeries = @(
            New-TS -Resource @{ dataset_id = 'ds1' } -Int 250
            New-TS -Resource @{ dataset_id = 'ds2' } -Int 1
            New-TS -Resource @{ dataset_id = 'ds-empty' } -Int 0
        ) }
    } }
$bq = Get-CVBqDatasetSizeMap -ProjectId 'proj-a' -Fetch $bqFetch -NowUtc $now
$d1 = Resolve-CVBqDatasetSize -DatasetId 'ds1' -SizeMap $bq
Assert-CV 'ds1 total incl. tail'          $d1.LogicalBytes 5800
Assert-CV 'ds1 largest labelled table'    $d1.LargestTable 'big'
Assert-CV 'ds1 largest bytes'             $d1.LargestTableBytes 700
Assert-CV 'ds1 table count'               $d1.TableCount 250
Assert-CV 'ds1 Ok'                        $d1.Status 'Ok'
$d2 = Resolve-CVBqDatasetSize -DatasetId 'ds2' -SizeMap $bq
Assert-CV 'measured zero stays 0'         $d2.LogicalBytes 0
Assert-CV 'measured zero is Ok'           $d2.Status 'Ok'
$de = Resolve-CVBqDatasetSize -DatasetId 'ds-empty' -SizeMap $bq
Assert-CV 'zero tables -> Empty'          $de.Status 'Empty'
Assert-CV 'zero tables -> 0'              $de.LogicalBytes 0
$dn = Resolve-CVBqDatasetSize -DatasetId 'ds-new' -SizeMap $bq
Assert-CV 'no series -> NoDatapoint'      $dn.Status 'NoDatapoint'
Assert-CV 'no series -> null'             ($null -eq $dn.LogicalBytes) $true
$bqFail = Get-CVBqDatasetSizeMap -ProjectId 'proj-x' -Fetch { throw 'boom' } -NowUtc $now
$df = Resolve-CVBqDatasetSize -DatasetId 'ds1' -SizeMap $bqFail
Assert-CV 'failed query -> Error'         $df.Status 'Error'
Assert-CV 'failed query -> null'          ($null -eq $df.LogicalBytes) $true

Write-Host "`n[6] BigQuery dataset listing (REST, replaces bq ls)"
$listFetch = {
    param($u)
    if ($u -notmatch 'pageToken=') { [pscustomobject]@{ datasets = @([pscustomobject]@{ datasetReference = [pscustomobject]@{ datasetId = 'a' }; location = 'US' }); nextPageToken = 'n' } }
    else { [pscustomobject]@{ datasets = @([pscustomobject]@{ datasetReference = [pscustomobject]@{ datasetId = 'b' }; location = 'europe-west2' }) } } }
$list = Get-CVBqDatasetList -ProjectId 'proj-a' -Fetch $listFetch
Assert-CV 'list ok'                       $list.Status 'Ok'
Assert-CV 'both pages listed'             (($list.Datasets | ForEach-Object DatasetId) -join ',') 'a,b'
Assert-CV 'location kept'                 $list.Datasets[1].Location 'europe-west2'
$noDs = Get-CVBqDatasetList -ProjectId 'proj-a' -Fetch { [pscustomobject]@{ kind = 'bigquery#datasetList' } }
Assert-CV 'project with no datasets'      $noDs.Datasets.Count 0

Write-Host ("`n======  {0} passed, {1} failed  ======`n" -f $script:Pass, $script:Fail) `
           -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
