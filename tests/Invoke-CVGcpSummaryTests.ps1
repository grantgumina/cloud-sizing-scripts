<#
    Invoke-CVGcpSummaryTests.ps1 - guards gcp_inventory_summary_<date>.csv and gcp_vm_zone_rollup_<date>.csv.

    The GCP rollup replaced ~250 lines of inline code whose VM tiers deduped attached disks on
    (DiskName, SizeGB) with no Project or Zone component. GCP disk names are unique per zone, not per project,
    so two same-named same-sized disks collapsed to one - which made the sum of the per-project VM rows EXCEED
    the overall VM row in the same file. Assertion [2] fails on the old arithmetic; that is the point of it.

    Following the AWS test's philosophy: fixture values are chosen so a wrong formula lands on a visibly
    different figure rather than a plausible one.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Summary.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Summary.GCP.ps1')

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    $a = "$Actual"; $e = "$Expected"
    if ($a -eq $e) { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name`n          expected: '$e'`n          actual:   '$a'" -ForegroundColor Red }
}

# ---- fixture ---------------------------------------------------------------------------------------------
# Two projects. THE KEY CASE: a 100 GB disk named 'data' exists in BOTH projects and in two zones of one of
# them, which is exactly what the retired (DiskName, SizeGB) -Unique dedupe collapsed.
$inventory = @{
    VMs = @(
        [PSCustomObject]@{ Project='proj-a'; Region='us-central1'; Zone='us-central1-a'; VMName='vm1'; VMDiskSizeGB=100; DiskCount=1 }
        [PSCustomObject]@{ Project='proj-a'; Region='us-central1'; Zone='us-central1-b'; VMName='vm2'; VMDiskSizeGB=100; DiskCount=1 }
        [PSCustomObject]@{ Project='proj-a'; Region='europe-west1'; Zone='europe-west1-b'; VMName='vm3'; VMDiskSizeGB=250; DiskCount=2 }
        [PSCustomObject]@{ Project='proj-b'; Region='us-central1'; Zone='us-central1-a'; VMName='vm4'; VMDiskSizeGB=100; DiskCount=1 }
    )
    UnattachedDisks = @(
        [PSCustomObject]@{ Project='proj-a'; Region='us-central1'; Zone='us-central1-a'; DiskName='orphan1'; SizeGB=40 }
    )
    # Buckets group by Location, NOT Region - bucket rows have no Region property at all.
    StorageBuckets = @(
        [PSCustomObject]@{ Project='proj-a'; Location='us';          StorageBucket='b1'; UsedCapacityBytes=2000000000 }
        [PSCustomObject]@{ Project='proj-b'; Location='europe-west1'; StorageBucket='b2'; UsedCapacityBytes=500000000 }
        # A bucket whose size could not be read: $null must be skipped, not counted as 0 in a way that changes anything.
        [PSCustomObject]@{ Project='proj-b'; Location='europe-west1'; StorageBucket='b3'; UsedCapacityBytes=$null }
    )
    # 1024 GiB exactly, so the GiB-vs-decimal distinction is unmistakable in the output.
    FileShares = @(
        [PSCustomObject]@{ Project='proj-a'; Region='us-central1'; InstanceName='fs1'; ShareName='s1'; provisionedGib=1024 }
    )
    CloudSqlInstances = @(
        [PSCustomObject]@{ Project='proj-a'; Region='us-central1'; Name='sql1'; StorageGB=200 }
    )
    SpannerInstances = @(
        [PSCustomObject]@{ Project='proj-b'; Region='us-central1'; Name='sp1'; StorageGB=1024 }
    )
    AlloyDbClusters  = @()
    BigQueryDatasets = @(
        [PSCustomObject]@{ Project='proj-a'; Region='US'; Name='ds1'; TotalPhysicalSizeGB=512 }
    )
    GKEClusters = @(
        [PSCustomObject]@{ Project='proj-a'; Region='us-central1'; ClusterName='c1'; PersistentVolumeCapacityGB=100; PersistentVolumeCount=3 }
    )
    DiskSnapshots = @(
        [PSCustomObject]@{ Project='proj-a'; Region='us-central1'; SnapshotName='s1'; StorageGB=1500 }
        [PSCustomObject]@{ Project='proj-b'; Region='us-central1'; SnapshotName='s2'; StorageGB=500 }
    )
}
$selected = @{}
foreach ($k in 'VM','STORAGE','FILESHARE','DB','GKE','SNAPSHOT','FILESTORE') { $selected[$k] = $true }
$projects = @([PSCustomObject]@{ Name='proj-a' }, [PSCustomObject]@{ Name='proj-b' })

$rows = @(Get-CVGcpInventorySummary -Inventory $inventory -Selected $selected -Projects $projects)
# ALWAYS call as @(Row ...). PowerShell unwraps a single-element array on function return, so a one-row result
# comes back as the PSCustomObject itself and `.Count` then reads the ROW's Count COLUMN rather than the array
# length - which silently reported "4 overall VM rows" because that row's Count happened to be 4.
function Row { param([string]$Proj, [string]$Type, [string]$Region)
    @($rows | Where-Object { $_.Project -eq $Proj -and $_.ResourceType -like "$Type*" -and $_.Region -eq $Region })
}

# ---- [1] the column contract -----------------------------------------------------------------------------
Write-Host "`n[1] Seven columns, Project first - the same shape Azure and AWS publish"
Assert-CV 'column set and order' (@($rows[0].PSObject.Properties.Name) -join ',') 'Project,ResourceType,Region,Count,TotalSizeGB,TotalSizeTB,TotalSizeTiB'
Assert-CV 'no Level column'  ([bool](@($rows[0].PSObject.Properties.Name) -contains 'Level')) $false
Assert-CV 'no Zone column'   ([bool](@($rows[0].PSObject.Properties.Name) -contains 'Zone'))  $false
Assert-CV 'project-level banner present once' (@($rows | Where-Object { $_.Project -eq '[ Project level Summary ]' }).Count) 1

# ---- [2] the dedupe regression -- the assertion that fails on the old code -------------------------------
Write-Host "`n[2] VM disk capacity is NOT deduped by (DiskName, SizeGB)"
$vmOverall = @(Row 'All' 'VM' 'All')
Assert-CV 'one overall VM row' $vmOverall.Count 1
# 100 + 100 + 250 + 100 = 550. The retired dedupe collapsed the three 100 GB 'data' disks to one -> 350.
Assert-CV 'overall VM GB is 550, not 350' $vmOverall[0].TotalSizeGB 550
$vmA = @(Row 'proj-a' 'VM' 'All'); $vmB = @(Row 'proj-b' 'VM' 'All')
Assert-CV 'proj-a VM GB' $vmA[0].TotalSizeGB 450
Assert-CV 'proj-b VM GB' $vmB[0].TotalSizeGB 100
Assert-CV 'per-project VM totals SUM to the overall (old file contradicted itself)' `
    ([double]$vmA[0].TotalSizeGB + [double]$vmB[0].TotalSizeGB) $vmOverall[0].TotalSizeGB
# Same disk name in two zones of one project must both count at the region tier.
$vmACentral = @(Row 'proj-a' 'VM' 'us-central1')
Assert-CV 'proj-a/us-central1 keeps both same-named disks' $vmACentral[0].TotalSizeGB 200
Assert-CV 'and counts both VMs' $vmACentral[0].Count 2
Assert-CV 'VM label carries the disk total' $vmOverall[0].ResourceType 'VM (Disks: 5)'

# ---- [3] units: GiB sources reconcile through one byte count ---------------------------------------------
Write-Host "`n[3] A GiB-denominated source publishes TB and TiB that agree"
$fs = @(Row 'All' 'Filestore Share' 'All')
Assert-CV 'Filestore 1024 GiB -> GB is 1099.51 (binary, not 1024)' $fs[0].TotalSizeGB 1099.51
Assert-CV 'Filestore TiB is exactly 1'  $fs[0].TotalSizeTiB 1
Assert-CV 'Filestore TB is 1.0995'      $fs[0].TotalSizeTB 1.0995
# The GB/1024 shortcut the older code used would have produced TiB = 1024/1024 = 1 too, but TB = 1.024.
Assert-CV 'the GB/1000-of-raw-GiB shortcut would differ' ([bool]($fs[0].TotalSizeTB -ne 1.024)) $true
# Decimal source: 550 GB -> TiB via bytes, not /1024.
Assert-CV 'VM TiB is byte-exact (550e9/2^40)' $vmOverall[0].TotalSizeTiB ([math]::Round(550e9 / 1099511627776, 4))
Assert-CV 'and differs from the 550/1024 shortcut' ([bool]($vmOverall[0].TotalSizeTiB -ne [math]::Round(550 / 1024, 4))) $true

# ---- [4] buckets group by Location ----------------------------------------------------------------------
Write-Host "`n[4] Buckets group by Location, and an unreadable bucket is skipped not zeroed"
$bkOverall = @(Row 'All' 'Storage Bucket' 'All')
Assert-CV 'all three buckets counted' $bkOverall[0].Count 3
Assert-CV 'only the two readable sizes summed (2.5 GB)' $bkOverall[0].TotalSizeGB 2.5
$bkEu = @($rows | Where-Object { $_.Project -eq 'All' -and $_.ResourceType -eq 'Storage Bucket' -and $_.Region -eq 'europe-west1' })
Assert-CV 'a Location value becomes the Region cell' $bkEu.Count 1
Assert-CV 'and carries both eu buckets' $bkEu[0].Count 2
Assert-CV 'a multi-region location groups on its own' (@($rows | Where-Object { $_.ResourceType -eq 'Storage Bucket' -and $_.Region -eq 'us' }).Count -gt 0) 'True'

# ---- [5] the four database services are four rows -------------------------------------------------------
Write-Host "`n[5] Four DB services, four rows, each stating its basis"
$dbOverall = @($rows | Where-Object { $_.Project -eq 'All' -and $_.Region -eq 'All' -and $_.ResourceType -match 'Cloud SQL|Spanner|AlloyDB|BigQuery' })
Assert-CV 'three DB rows (AlloyDB has no rows so is omitted)' $dbOverall.Count 3
Assert-CV 'no fused Database row remains' (@($rows | Where-Object { $_.ResourceType -eq 'Database' }).Count) 0
Assert-CV 'Cloud SQL states provisioned' (@($dbOverall | Where-Object { $_.ResourceType -like 'Cloud SQL*' })[0].ResourceType) 'Cloud SQL Instance (provisioned disk)'
Assert-CV 'Spanner states derived ceiling' (@($dbOverall | Where-Object { $_.ResourceType -like 'Spanner*' })[0].ResourceType) 'Spanner Instance (derived capacity ceiling)'
Assert-CV 'Cloud SQL is decimal GB'  (@($dbOverall | Where-Object { $_.ResourceType -like 'Cloud SQL*' })[0].TotalSizeGB) 200
Assert-CV 'Spanner 1024 is GiB'      (@($dbOverall | Where-Object { $_.ResourceType -like 'Spanner*' })[0].TotalSizeGB) 1099.51
Assert-CV 'AlloyDB emits no row when empty' (@($rows | Where-Object { $_.ResourceType -like 'AlloyDB*' }).Count) 0

# ---- [6] no zero rows, no AllResources -------------------------------------------------------------------
Write-Host "`n[6] Absence is absence - no fabricated zero rows, no AllResources supertotal"
Assert-CV 'no AllResources row' (@($rows | Where-Object { $_.ResourceType -eq 'AllResources' }).Count) 0
Assert-CV 'no Count = N/A anywhere' (@($rows | Where-Object { "$($_.Count)" -eq 'N/A' }).Count) 0
# A project with no Cloud SQL must have no Cloud SQL row, not a zero one.
Assert-CV 'proj-b has no Cloud SQL row' (@(Row 'proj-b' 'Cloud SQL' 'All')).Count 0
$emptySel = @{ SNAPSHOT = $true }
$emptyRows = @(Get-CVGcpInventorySummary -Inventory @{ DiskSnapshots = @() } -Selected $emptySel -Projects $projects)
Assert-CV 'nothing selected-and-present yields only spacers, so the caller can skip the file' `
    (@($emptyRows | Where-Object { "$($_.ResourceType)" -ne '' }).Count) 0

# ---- [7] the new rows the old rollup omitted ------------------------------------------------------------
Write-Host "`n[7] Unattached disks and snapshots reach the rollup at last"
$un = @(Row 'All' 'Unattached Persistent Disk' 'All')
Assert-CV 'unattached disks have a row' $un.Count 1
Assert-CV 'unattached GB' $un[0].TotalSizeGB 40
$sn = @(Row 'All' 'Disk Snapshot' 'All')
Assert-CV 'snapshots have a row (was only ever appended into the data CSV)' $sn.Count 1
Assert-CV 'snapshot GB is the true total, not doubled' $sn[0].TotalSizeGB 2000

# ---- [8] Filestore is not double-counted ---------------------------------------------------------------
Write-Host "`n[8] FilestoreInstances has no descriptor, so shares are not counted twice"
$fsKeys = @($script:CVGcpSummaryTypes | ForEach-Object { $_.Source })
Assert-CV 'FilestoreInstances is deliberately absent from the table' ([bool]($fsKeys -contains 'FilestoreInstances')) $false
Assert-CV 'FileShares is the one that is present' ([bool]($fsKeys -contains 'FileShares')) $true

# ---- [9] descriptor hygiene ----------------------------------------------------------------------------
Write-Host "`n[9] Descriptor table hygiene"
$seqs = @($script:CVGcpSummaryTypes | ForEach-Object { $_.SeqOverall })
Assert-CV 'every descriptor has a SeqOverall' (@($script:CVGcpSummaryTypes | Where-Object { -not $_.SeqOverall }).Count) 0
Assert-CV 'SeqOverall values are unique' $seqs.Count (@($seqs | Sort-Object -Unique).Count)
Assert-CV 'every Source is unique' (@($fsKeys).Count) (@($fsKeys | Sort-Object -Unique).Count)
$badKeys = @($script:CVGcpSummaryTypes | Where-Object { $_.Key -cne $_.Key.ToUpper() })
Assert-CV 'every Key is UPPERCASE (matches $ResourceTypeMap)' $badKeys.Count 0
Assert-CV 'four descriptors share Key=DB' (@($script:CVGcpSummaryTypes | Where-Object { $_.Key -eq 'DB' }).Count) 4
$again = @((Get-CVGcpInventorySummary -Inventory $inventory -Selected $selected -Projects $projects) |
           ForEach-Object { "$($_.Project)|$($_.ResourceType)|$($_.Region)|$($_.Count)|$($_.TotalSizeGB)" })
$first = @($rows | ForEach-Object { "$($_.Project)|$($_.ResourceType)|$($_.Region)|$($_.Count)|$($_.TotalSizeGB)" })
Assert-CV 'a rebuild is identical' ($again -join "`n") ($first -join "`n")

# ---- [10] the zone rollup ------------------------------------------------------------------------------
Write-Host "`n[10] The zone rollup is a pure CSV and reconciles with the summary's VM row"
$zone = @(Get-CVGcpVmZoneRollup -VMs $inventory.VMs)
Assert-CV 'one row per (project, region, zone)' $zone.Count 4
Assert-CV 'zone column set' (@($zone[0].PSObject.Properties.Name) -join ',') 'Project,Region,Zone,VMCount,TotalSizeGB,TotalSizeTB,TotalSizeTiB'
Assert-CV 'zone GB totals equal the overall VM GB (nothing falls out)' `
    (($zone | Measure-Object TotalSizeGB -Sum).Sum) $vmOverall[0].TotalSizeGB
Assert-CV 'zone VM counts equal the overall VM count' (($zone | Measure-Object VMCount -Sum).Sum) $vmOverall[0].Count
$za = @($zone | Where-Object { $_.Project -eq 'proj-a' -and $_.Zone -eq 'us-central1-a' })
Assert-CV 'proj-a/us-central1-a has its own row' $za.Count 1
Assert-CV 'and its own 100 GB (not collapsed with proj-b)' $za[0].TotalSizeGB 100
Assert-CV 'empty VM set yields no rows' (@(Get-CVGcpVmZoneRollup -VMs @()).Count) 0

Write-Host "`n======  $script:Pass passed, $script:Fail failed  ======" -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
