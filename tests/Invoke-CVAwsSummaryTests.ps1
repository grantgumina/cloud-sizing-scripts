<#
    Invoke-CVAwsSummaryTests.ps1 - guards aws_inventory_summary_<date>.csv.

    The AWS rollup replaced two Excel workbooks whose totals were produced by property-name PROBING: match
    anything ending _SizeGB, fall back to deriving GiB from GB, and so on. That is how S3 came to be reported at
    2x its real size for years - Process-S3Bucket publishes the whole-bucket total as SizeGB and then stamps each
    storage class as <CLASS>_SizeGB, and the regex '(_SizeGB$|^SizeGB$)' summed both.

    So the assertions that matter most here are not "the shape is right" but "the number is right, and it is the
    number for the reason we think". Every fixture value below is chosen so that a wrong formula lands on a
    visibly different figure rather than a plausible one.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Summary.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Summary.AWS.ps1')

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    $a = "$Actual"; $e = "$Expected"
    if ($a -eq $e) { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name`n          expected: '$e'`n          actual:   '$a'" -ForegroundColor Red }
}

# ---- fixture ---------------------------------------------------------------------------------------------
# Two accounts, three regions. S3 buckets carry BOTH the bucket total and the per-storage-class breakdown, which
# is the whole point: the class columns must be ignored.
function New-S3Row {
    param([string]$Acct, [string]$Region, [string]$Name, [double]$TotalGB, [double]$StdGB, [double]$GlacierGB, [long]$Objects)
    # SizeGB is the sum across storage classes, exactly as Process-S3Bucket builds it ($totalBytes += $bytes).
    [PSCustomObject]@{
        AwsAccountId = $Acct; AwsAccountAlias = "alias-$Acct"; Region = $Region; BucketName = $Name
        SizeGB = $TotalGB; SizeGiB = ($TotalGB / 1.073741824); ObjectCount = $Objects
        STANDARD_SizeGB = $StdGB; GLACIER_SizeGB = $GlacierGB
        STANDARD_SizeGiB = ($StdGB / 1.073741824); GLACIER_SizeGiB = ($GlacierGB / 1.073741824)
    }
}

$inventory = @{
    # 100 + 400 = 500 GB total. If the class columns leak in, this becomes 1000.
    S3 = @(
        (New-S3Row -Acct '111111111111' -Region 'us-east-1' -TotalGB 100 -StdGB 60 -GlacierGB 40 -Objects 1200)
        (New-S3Row -Acct '222222222222' -Region 'us-west-2' -TotalGB 400 -StdGB 400 -GlacierGB 0 -Objects 800)
    )
    EC2 = @(
        [PSCustomObject]@{ AwsAccountId = '111111111111'; Region = 'us-east-1'; SizeGB = 1024; VolumeCount = 3 }
        [PSCustomObject]@{ AwsAccountId = '111111111111'; Region = 'eu-west-1'; SizeGB = 512;  VolumeCount = 2 }
        [PSCustomObject]@{ AwsAccountId = '222222222222'; Region = 'us-east-1'; SizeGB = 64;   VolumeCount = 1 }
    )
    # Blank and $null sizes must be skipped, not coerced to 0 in a way that changes the count.
    RDS = @(
        [PSCustomObject]@{ AwsAccountId = '111111111111'; Region = 'us-east-1'; SizeGB = 20 }
        [PSCustomObject]@{ AwsAccountId = '111111111111'; Region = 'us-east-1'; SizeGB = '' }
        [PSCustomObject]@{ AwsAccountId = '111111111111'; Region = 'us-east-1'; SizeGB = $null }
    )
    ElastiCache = @(
        [PSCustomObject]@{ AwsAccountId = '222222222222'; Region = 'us-west-2'; CacheClusterId = 'c1' }
    )
    AWSBackup = @(
        [PSCustomObject]@{ AwsAccountId = '111111111111'; Region = 'us-east-1'; LastBackupSizeGB = 77 }
    )
}
foreach ($k in 'UnattachedVolumes','EFS','FSX','FSX_SVM','DynamoDB','Redshift','EKS','Aurora','DocumentDB') {
    $inventory[$k] = @()
}

$selected = @{}
foreach ($k in $inventory.Keys) { $selected[$k] = $true }
$accounts = @(
    [PSCustomObject]@{ Name = '111111111111' }
    [PSCustomObject]@{ Name = '222222222222' }
)

$rows = @(Get-CVAwsInventorySummary -Inventory $inventory -Selected $selected -Accounts $accounts)

# ---- [1] the S3 double-count is gone --------------------------------------------------------------------
Write-Host "`n[1] S3 totals count SizeGB once, never the per-storage-class columns"
$s3Overall = @($rows | Where-Object { $_.Account -eq 'All' -and $_.Region -eq 'All' -and $_.ResourceType -like 'S3 Buckets*' })
Assert-CV 'exactly one overall S3 row' $s3Overall.Count 1
Assert-CV 'S3 overall GB is 500, not 1000' $s3Overall[0].TotalSizeGB 500
Assert-CV 'S3 overall TB is 0.5'           $s3Overall[0].TotalSizeTB 0.5
# 500 GB decimal = 500e9 bytes = 465.6613 TiB/1000... precisely 500e9 / 2^40 = 0.4547 TiB
Assert-CV 'S3 overall TiB is byte-exact (500e9/2^40), not 500/1024' $s3Overall[0].TotalSizeTiB ([math]::Round(500e9 / 1099511627776, 4))
Assert-CV 'GB/1024 would have given a different TiB' ([math]::Round(500 / 1024, 4) -ne $s3Overall[0].TotalSizeTiB) 'True'

# ---- [2] aggregate counts are folded into the label -----------------------------------------------------
Write-Host "`n[2] Aggregate counts ride in the ResourceType label (the workbook's extra columns)"
Assert-CV 'S3 label carries the object total' $s3Overall[0].ResourceType 'S3 Buckets (Objects: 2000)'
$ec2Overall = @($rows | Where-Object { $_.Account -eq 'All' -and $_.Region -eq 'All' -and $_.ResourceType -like 'EC2 Instances*' })
Assert-CV 'EC2 label carries the volume total' $ec2Overall[0].ResourceType 'EC2 Instances (Volumes: 6)'
Assert-CV 'EC2 overall GB' $ec2Overall[0].TotalSizeGB 1600

# ---- [3] count-only types publish EMPTY size cells, not zeros -------------------------------------------
Write-Host "`n[3] Count-only types leave size cells empty (a 0 would assert 'measured, and it is nothing')"
$ecOverall = @($rows | Where-Object { $_.Account -eq 'All' -and $_.Region -eq 'All' -and $_.ResourceType -eq 'ElastiCache Clusters' })
Assert-CV 'ElastiCache row exists' $ecOverall.Count 1
Assert-CV 'ElastiCache GB is blank'  $ecOverall[0].TotalSizeGB  ''
Assert-CV 'ElastiCache TiB is blank' $ecOverall[0].TotalSizeTiB ''
Assert-CV 'ElastiCache still reports its count' $ecOverall[0].Count 1
$bkOverall = @($rows | Where-Object { $_.Account -eq 'All' -and $_.Region -eq 'All' -and $_.ResourceType -eq 'AWS Backup Protected Resources' })
Assert-CV 'AWS Backup GB is blank (LastBackupSizeGB is not a capacity)' $bkOverall[0].TotalSizeGB ''

# ---- [4] blank and null sizes are skipped, rows are still counted ---------------------------------------
Write-Host "`n[4] Blank / null size values are skipped by the sum but not by the count"
$rdsOverall = @($rows | Where-Object { $_.Account -eq 'All' -and $_.Region -eq 'All' -and $_.ResourceType -eq 'RDS Databases' })
Assert-CV 'RDS counts all three rows' $rdsOverall[0].Count 3
Assert-CV 'RDS sums only the populated one' $rdsOverall[0].TotalSizeGB 20

# ---- [5] the four-tier structure ------------------------------------------------------------------------
Write-Host "`n[5] Four tiers, in Azure's order, with an Account column"
Assert-CV 'scope column is named Account' (@($rows[0].PSObject.Properties.Name) -join ',') 'Account,ResourceType,Region,Count,TotalSizeGB,TotalSizeTB,TotalSizeTiB'
$banner = @($rows | Where-Object { $_.Account -eq '[ Account level Summary ]' })
Assert-CV 'account-level banner is present once' $banner.Count 1
$regional = @($rows | Where-Object { $_.Account -eq 'All' -and $_.Region -ne 'All' -and $_.ResourceType })
Assert-CV 'EC2 has one row per distinct region (us-east-1, eu-west-1)' (@($regional | Where-Object { $_.ResourceType -like 'EC2*' }).Count) 2
# us-east-1 EC2 spans BOTH accounts in pass B: 1024 + 64
$ec2East = @($regional | Where-Object { $_.ResourceType -like 'EC2*' -and $_.Region -eq 'us-east-1' })
Assert-CV 'pass B aggregates a region across accounts' $ec2East[0].TotalSizeGB 1088
Assert-CV 'pass B row count for that region' $ec2East[0].Count 2

# ---- [6] the per-account pass filters on AwsAccountId ---------------------------------------------------
Write-Host "`n[6] Per-account pass splits on AwsAccountId, not on the column name"
$acct1 = @($rows | Where-Object { $_.Account -eq '111111111111' -and $_.ResourceType -like 'EC2*' -and $_.Region -eq 'All' })
Assert-CV 'account 1 EC2 total is its own rows only' $acct1[0].TotalSizeGB 1536
$acct2 = @($rows | Where-Object { $_.Account -eq '222222222222' -and $_.ResourceType -like 'EC2*' -and $_.Region -eq 'All' })
Assert-CV 'account 2 EC2 total is its own rows only' $acct2[0].TotalSizeGB 64
$acct2S3 = @($rows | Where-Object { $_.Account -eq '222222222222' -and $_.ResourceType -like 'S3*' -and $_.Region -eq 'All' })
Assert-CV 'account 2 S3 total is 400 (still not doubled)' $acct2S3[0].TotalSizeGB 400
$acct2Rds = @($rows | Where-Object { $_.Account -eq '222222222222' -and $_.ResourceType -eq 'RDS Databases' })
Assert-CV 'no RDS row for the account that has none' $acct2Rds.Count 0

# ---- [7] a type with no rows is omitted entirely --------------------------------------------------------
Write-Host "`n[7] Empty services produce no rows at all"
Assert-CV 'no FSx rows' (@($rows | Where-Object { $_.ResourceType -like 'FSx*' }).Count) 0
Assert-CV 'no DynamoDB rows' (@($rows | Where-Object { $_.ResourceType -like 'DynamoDB*' }).Count) 0

# ---- [8] ordering is deterministic ---------------------------------------------------------------------
Write-Host "`n[8] Row order is the declaration order, and is stable across rebuilds"
$overallTypes = @($rows | Where-Object { $_.Account -eq 'All' -and $_.Region -eq 'All' -and $_.ResourceType } | ForEach-Object { $_.ResourceType })
$expectedOrder = @('EC2 Instances (Volumes: 6)', 'S3 Buckets (Objects: 2000)', 'RDS Databases',
                   'ElastiCache Clusters', 'AWS Backup Protected Resources')
Assert-CV 'overall pass order follows SeqOverall' ($overallTypes -join ' | ') ($expectedOrder -join ' | ')
$again = @((Get-CVAwsInventorySummary -Inventory $inventory -Selected $selected -Accounts $accounts) |
           ForEach-Object { "$($_.Account)|$($_.ResourceType)|$($_.Region)|$($_.Count)|$($_.TotalSizeGB)" })
$first = @($rows | ForEach-Object { "$($_.Account)|$($_.ResourceType)|$($_.Region)|$($_.Count)|$($_.TotalSizeGB)" })
Assert-CV 'a rebuild is identical' ($again -join "`n") ($first -join "`n")

# ---- [9] the descriptor table cannot silently lose a service -------------------------------------------
Write-Host "`n[9] Every service in the table is distinct and named once"
$keys = @($script:CVAwsSummaryTypes | ForEach-Object { $_.Key })
Assert-CV 'no duplicate Key in the descriptor table' ($keys.Count) (@($keys | Sort-Object -Unique).Count)
Assert-CV 'every descriptor has a SeqOverall' (@($script:CVAwsSummaryTypes | Where-Object { -not $_.SeqOverall }).Count) 0
Assert-CV 'every descriptor groups by Region' (@($script:CVAwsSummaryTypes | Where-Object { $_.Group -ne 'Region' }).Count) 0
$seqs = @($script:CVAwsSummaryTypes | ForEach-Object { $_.SeqOverall })
Assert-CV 'SeqOverall values are unique' ($seqs.Count) (@($seqs | Sort-Object -Unique).Count)

Write-Host "`n======  $script:Pass passed, $script:Fail failed  ======" -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
