#requires -Version 7.2
<#
    Byte-equality test for the azure_inventory_summary CSV builder.

    src/common/CVSizing.Summary.Azure.ps1 replaced 1,034 lines of inline script in which the same rollup was
    hand-written four times per resource type. These numbers go into customer sizing spreadsheets, so the
    refactor is pinned to tests/fixtures/azure_summary_golden.csv - captured from the ORIGINAL inline code,
    against the same synthetic inventory, before any of it was touched.

    If this fails, the diff below names the exact row and cell that moved. Do not regenerate the golden to make
    it pass unless you intend the output change and can say what it is.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Summary.Azure.ps1')

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }

. (Join-Path $PSScriptRoot 'fixtures' 'CVAzureSummaryFixture.ps1')

$inventory = @{
    VMs                   = $VMs
    StorageAccounts       = $StorageAccounts
    FileShares            = $FileShares
    NetAppVolumes         = $NetAppVolumes
    SqlInstancesInventory = $SqlInstancesInventory
    SqlDbInventory        = $SqlDbInventory
    MySQLServers          = $MySQLServers
    PostgreSQLServers     = $PostgreSQLServers
    CosmosDBs             = $CosmosDBs
    AKSClusters           = $AKSClusters
    BackupItems           = $BackupItems
    UnmanagedDiskItems    = $UnmanagedDiskItems
    AVSClusters           = $AVSClusters
}

$rows = Get-CVAzureInventorySummary -Inventory $inventory -Selected $Selected -Subscriptions $subs

Write-Host "`n[1] Output is byte-identical to the pre-refactor golden file"
$goldenPath = Join-Path $PSScriptRoot 'fixtures' 'azure_summary_golden.csv'
Assert-CV 'golden fixture exists' (Test-Path -LiteralPath $goldenPath) $true

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("cv-summary-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".csv")
try {
    $rows | Export-Csv -Path $tmp -NoTypeInformation
    $actual   = Get-Content -Raw $tmp
    $expected = Get-Content -Raw $goldenPath
    Assert-CV 'byte-identical to golden' ($actual -eq $expected) $true

    if ($actual -ne $expected) {
        # Name the exact rows that differ - a bare "not equal" on an 82-row file is not actionable.
        $a = @(Get-Content $tmp); $e = @(Get-Content $goldenPath)
        Assert-CV 'row count matches' $a.Count $e.Count
        $shown = 0
        for ($i = 0; $i -lt [Math]::Max($a.Count, $e.Count); $i++) {
            $al = if ($i -lt $a.Count) { $a[$i] } else { '<missing>' }
            $el = if ($i -lt $e.Count) { $e[$i] } else { '<missing>' }
            if ($al -ne $el -and $shown -lt 12) {
                $shown++
                Write-Host "        line $($i + 1):" -ForegroundColor DarkYellow
                Write-Host "          expected: $el" -ForegroundColor DarkYellow
                Write-Host "          actual  : $al" -ForegroundColor DarkYellow
            }
        }
    }
} finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }

Write-Host "`n[2] The quirks the golden exists to protect"
$byKey = { param($sub, $type, $region) @($rows | Where-Object { $_.Subscription -eq $sub -and $_.ResourceType -like $type -and "$($_.Region)" -eq $region })[0] }

# Cosmos rounds gigabytes to 2dp in the overall pass and 4dp per region. Same underlying bytes.
Assert-CV 'Cosmos overall GB is 2dp'  (& $byKey 'All' 'CosmosDB' 'All').TotalSizeGB    1.23
Assert-CV 'Cosmos regional GB is 4dp' (& $byKey 'All' 'CosmosDB' 'eastus').TotalSizeGB 1.2346

# AKS words its label differently between passes, and rounds differently too.
Assert-CV 'AKS overall label says "Total PVs"' ([bool]((& $byKey 'All' 'AKS Clusters*' 'All').ResourceType -match 'Total PVs')) $true
Assert-CV 'AKS regional label says just "PVs"' ([bool]((& $byKey 'All' 'AKS Clusters*' 'eastus').ResourceType -match '\(PVs:')) $true
Assert-CV 'AKS overall GB is 2dp'  (& $byKey 'All' 'AKS Clusters*' 'All').TotalSizeGB    300.5
Assert-CV 'AKS regional GB is 4dp' (& $byKey 'All' 'AKS Clusters*' 'eastus').TotalSizeGB 300.5001

# VM publishes the raw float sum, so the float artefact is part of the shipped output.
Assert-CV 'VM overall GB is the raw sum' (& $byKey 'All' 'VM' 'All').TotalSizeGB 1729.1100000000001

# An elastic pool must be counted once, not once per database in it.
# SubA: db1 utilized 12.5 + pool1 provisioned 500 counted ONCE = 512.5, not 1012.5.
Assert-CV 'elastic pool counted once' (& $byKey 'Sub Alpha' 'SQL Databases' 'All').TotalSizeGB 512.5
# ...but a POOLED database measured by utilization is per-database and must still be summed.
Assert-CV 'pooled-but-utilized still counted' (& $byKey 'Sub Beta' 'SQL Databases' 'All').TotalSizeGB 7.25

# Count-only types carry EMPTY size cells, not zeros - they measure items, not capacity.
$bk = & $byKey 'Sub Alpha' 'Backup Items*' 'All'
Assert-CV 'backup row size is empty, not 0' "$($bk.TotalSizeGB)" ''
Assert-CV 'backup row still reports a count' $bk.Count 1

# Cosmos / MySQL / PostgreSQL group on Location; every other type groups on Region. Mixing them up would put
# rows under the wrong heading or drop them entirely.
Assert-CV 'Cosmos grouped by Location' ([bool](& $byKey 'All' 'CosmosDB' 'westus2')) $true

# A type absent from a subscription emits nothing for it rather than a zero row.
Assert-CV 'no PostgreSQL row for the subscription without one' (@($rows | Where-Object { $_.Subscription -eq 'Sub Beta' -and $_.ResourceType -eq 'PostgreSQL Servers' }).Count) 0

Write-Host "`n[3] Overall-pass row order is deterministic (it used to be Hashtable key order)"
# $ResourceTypeMap is a Hashtable and .NET randomises string hashing per process, so consecutive runs of the
# tool emitted these rows in different orders and no two runs were diffable. Order is now declaration order.
$overall = @($rows | Where-Object { $_.Subscription -eq 'All' -and "$($_.Region)" -eq 'All' } | ForEach-Object { $_.ResourceType })
$expectedOrder = @('VM', 'Storage Account*', 'File Share', 'NetApp Files Volume', 'SQL Managed Instances',
                   'SQL Databases', 'MySQL Servers', 'PostgreSQL Servers', 'CosmosDB', 'AKS Clusters*')
Assert-CV 'overall row count' $overall.Count $expectedOrder.Count
for ($i = 0; $i -lt [Math]::Min($overall.Count, $expectedOrder.Count); $i++) {
    Assert-CV "overall[$i] is $($expectedOrder[$i])" ([bool]($overall[$i] -like $expectedOrder[$i])) $true
}

# And prove it is stable: building twice in one process must give the same order (the real proof is the
# byte-comparison above, which is run by a fresh process every time the suite runs).
$again = @((Get-CVAzureInventorySummary -Inventory $inventory -Selected $Selected -Subscriptions $subs) |
            Where-Object { $_.Subscription -eq 'All' -and "$($_.Region)" -eq 'All' } | ForEach-Object { $_.ResourceType })
Assert-CV 'rebuild produces the same order' (($again -join '|') -eq ($overall -join '|')) $true

Write-Host ("`n======  {0} passed, {1} failed  ======`n" -f $script:Pass, $script:Fail) `
           -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
