<#
    CVSizing.Summary.Azure.ps1 - builds azure_inventory_summary_<date>.csv.

    Replaces 1,034 lines of inline script - 28% of CVAzureCloudSizingScript.ps1 - in which the same rollup was
    hand-written FOUR times for each of eleven resource types: overall totals, regional totals, per-subscription
    totals, and per-subscription regional totals. That duplication was not theoretical: the
    MaxSizeGB-instead-of-utilized bug had to be fixed in four separate places, and the AKS label still differs
    between two of the passes because nobody kept them in step.

    The data access is table-driven ($script:CVAzSummaryTypes below). The ARITHMETIC IS NOT UNIFIED, because it
    genuinely is not uniform in the output this must reproduce:

      - Cosmos gigabytes round to 2dp in the overall pass and 4dp everywhere else.
      - MySQL / PostgreSQL / AKS likewise round to 2dp overall and 4dp per region.
      - VM publishes the RAW float sum, so a total of 1729.11 renders as 1729.1100000000001.
      - Storage / FileShare / NetApp measure bytes; everything else measures gigabytes.
      - Two different blank-spacer row shapes exist, one of which omits Subscription entirely.
      - Backup / Disks / AVS rows carry EMPTY size cells rather than zeros.

    Every one of those is pinned by tests/fixtures/azure_summary_golden.csv, and
    tests/Invoke-CVAzureSummaryTests.ps1 asserts byte equality against it. Change a formula here and that test
    tells you precisely which cell moved. Do not "tidy" a rounding difference away without regenerating the
    golden deliberately - these numbers go into customer sizing spreadsheets.

    One behaviour DID change, and deliberately: the overall pass used to iterate $ResourceTypeMap.Keys, a
    PowerShell Hashtable. .NET randomises string hashing per process, so three consecutive runs produced the
    overall rows in three different orders and no two runs of the tool were diffable. The order is now the
    declaration order below, which is what the pass's own if/elseif chain always intended.
#>

# ---- unit conversions, named once ------------------------------------------------------------------------
# Decimal (SI) gigabytes/terabytes and binary (IEC) tebibytes, matching what the inline code did.
function ConvertTo-CVGB  { param([double]$Bytes) [math]::Round($Bytes / 1000000000, 2) }
function ConvertTo-CVTB  { param([double]$Bytes) [math]::Round($Bytes / 1000000000000, 4) }
function ConvertTo-CVTiB { param([double]$Bytes) [math]::Round($Bytes / 1099511627776, 4) }

function Measure-CVSum {
    <# .SYNOPSIS  Sum a property across rows, coalescing an all-null result to 0 as the inline code did. #>
    param($Rows, [string]$Property)
    $s = ($Rows | Measure-Object -Property $Property -Sum).Sum
    if ($null -eq $s) { return 0 }
    return $s
}

function Measure-CVLooseSum {
    <#
      .SYNOPSIS  Sum a property, skipping $null AND empty string.
      .DESCRIPTION Cosmos/MySQL/PostgreSQL/AKS accumulate in a foreach with an explicit `-ne $null -and -ne ''`
                   guard rather than using Measure-Object. Kept separate because Measure-Object would coerce ''
                   and change the total.
    #>
    param($Rows, [string]$Property)
    $total = 0.0
    foreach ($r in @($Rows)) {
        if (-not $r) { continue }
        $v = $r.$Property
        if ($null -ne $v -and "$v" -ne '') { $total += [double]$v }
    }
    return $total
}

function Get-CVSqlDbSizeTotal {
    <#
      .SYNOPSIS  Total SQL Database size for a summary row, using consumed size and counting each pool once.
      .DESCRIPTION Two defects this replaces:
                     1. The summaries summed MaxSizeGB - the PROVISIONED ceiling - even though the utilized figure
                        was already collected on the same row. For a sizing spreadsheet that is the wrong number.
                     2. Every database in an elastic pool reports the POOL's max size, so summing across databases
                        counted one pool once per database in it and inflated the total by the pool's DB count.
                   SizingGB already prefers Utilized -> Allocated -> ProvisionedMax, so only ProvisionedMax rows
                   need pool de-duplication; utilized figures are genuinely per-database and must all be summed.
    #>
    param($Rows)
    $total = 0.0
    $seenPools = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in @($Rows)) {
        if (-not $r) { continue }
        $v = $r.SizingGB
        if ($null -eq $v) { $v = $r.MaxSizeGB }          # rows from an older shape
        if ($null -eq $v) { continue }
        if ($r.IsPooled -eq $true -and "$($r.SizeBasis)" -eq 'ProvisionedMax') {
            $pk = "$($r.Subscription)|$($r.ResourceGroup)|$($r.ElasticPoolName)"
            if (-not $seenPools.Add($pk)) { continue }   # this pool's capacity is already counted
        }
        $total += [double]$v
    }
    return [math]::Round($total, 3)
}

# ---- size formatters -------------------------------------------------------------------------------------
# Each returns @{ GB; TB; TiB }. Named after what varies, so a descriptor reads as a choice not a formula.

# Raw gigabyte sum, published unrounded (VM). TB/TiB derive from it.
function Format-CVSizeRawGB { param([double]$Gb) @{ GB = $Gb; TB = [math]::Round($Gb / 1000, 4); TiB = [math]::Round($Gb / 1024, 4) } }

# Gigabyte sum rounded to N places; TB/TiB derive from the ROUNDED value for 2dp callers and the raw value for
# 4dp callers - which is exactly how the two passes differed.
function Format-CVSizeGB2 { param([double]$Gb) $g = [math]::Round($Gb, 2); @{ GB = $g; TB = [math]::Round($g / 1000, 4); TiB = [math]::Round($g / 1024, 4) } }
function Format-CVSizeGB4 {
    param([double]$Gb)
    @{ GB  = [math]::Round($Gb, 4)
       TB  = if ($Gb -gt 0) { [math]::Round($Gb / 1000, 4) } else { 0 }
       TiB = if ($Gb -gt 0) { [math]::Round($Gb / 1024, 4) } else { 0 } }
}
# SQL MI / SQL DB round GB to 2dp but derive TB/TiB from the UNROUNDED total.
function Format-CVSizeGB2Raw { param([double]$Gb) @{ GB = [math]::Round($Gb, 2); TB = [math]::Round($Gb / 1000, 4); TiB = [math]::Round($Gb / 1024, 4) } }

# Byte totals (storage, file shares, NetApp).
function Format-CVSizeBytes { param([double]$Bytes) @{ GB = (ConvertTo-CVGB $Bytes); TB = (ConvertTo-CVTB $Bytes); TiB = (ConvertTo-CVTiB $Bytes) } }
# Cosmos measures bytes too, but zero stays a hard 0 and the regional pass wants 4dp gigabytes.
function Format-CVSizeBytes2 { param([double]$Bytes) @{ GB = $(if ($Bytes -gt 0) { [math]::Round($Bytes / 1000000000, 2) } else { 0 })
                                                        TB = $(if ($Bytes -gt 0) { ConvertTo-CVTB  $Bytes } else { 0 })
                                                        TiB = $(if ($Bytes -gt 0) { ConvertTo-CVTiB $Bytes } else { 0 }) } }
function Format-CVSizeBytes4 { param([double]$Bytes) @{ GB = $(if ($Bytes -gt 0) { [math]::Round($Bytes / 1000000000, 4) } else { 0 })
                                                        TB = $(if ($Bytes -gt 0) { ConvertTo-CVTB  $Bytes } else { 0 })
                                                        TiB = $(if ($Bytes -gt 0) { ConvertTo-CVTiB $Bytes } else { 0 }) } }

# ---- the type table -------------------------------------------------------------------------------------
<#
    ORDER IS THE OUTPUT ORDER for every pass. Fields:
      Key        - the -Types gate ($Selected[$Key]); several descriptors may share one key (SQL emits four).
      Source     - name of the inventory collection, resolved from the caller's -Inventory hashtable.
      Group      - property to group by. Cosmos / MySQL / PostgreSQL use Location; everything else uses Region.
      Label      - static string, or a scriptblock over the row set for labels carrying an aggregate.
      LabelOverall - override used only by the overall pass (AKS says "Total PVs:" there and "PVs:" elsewhere).
      Measure    - scriptblock: rows -> a single raw total.
      FmtOverall / Fmt - raw total -> @{GB;TB;TiB}. Two entries because the passes really do differ.
      SubOnly    - emitted only in the per-subscription pass, with empty size cells (Backup / Disks / AVS).
#>
$script:CVAzSummaryTypes = @(
    @{ Key='VM'; Source='VMs'; Group='Region'; Label='VM'; SeqOverall=1
       Measure={ param($r) Measure-CVSum $r 'VMDiskSizeGB' }
       FmtOverall={ param($v) Format-CVSizeRawGB $v }; Fmt={ param($v) Format-CVSizeRawGB $v } }

    @{ Key='STORAGE'; Source='StorageAccounts'; Group='Region'; SeqOverall=2
       Label={ param($r) "Storage Account (Total Blobs: $(Measure-CVSum $r 'BlobCount'))" }
       Measure={ param($r) Measure-CVSum $r 'UsedCapacityBytes' }
       FmtOverall={ param($v) Format-CVSizeBytes $v }; Fmt={ param($v) Format-CVSizeBytes $v } }

    @{ Key='FILESHARE'; Source='FileShares'; Group='Region'; Label='File Share'; SeqOverall=3
       Measure={ param($r) Measure-CVSum $r 'UsedCapacityBytes' }
       FmtOverall={ param($v) Format-CVSizeBytes $v }; Fmt={ param($v) Format-CVSizeBytes $v } }

    @{ Key='NETAPP'; Source='NetAppVolumes'; Group='Region'; Label='NetApp Files Volume'; SeqOverall=4
       Measure={ param($r) Measure-CVSum $r 'UsedCapacityBytes' }
       FmtOverall={ param($v) Format-CVSizeBytes $v }; Fmt={ param($v) Format-CVSizeBytes $v } }

    @{ Key='SQL'; Source='SqlInstancesInventory'; Group='Region'; Label='SQL Managed Instances'; SeqOverall=5
       Measure={ param($r) Measure-CVSum $r 'StorageUsedGB' }
       FmtOverall={ param($v) Format-CVSizeGB2Raw $v }; Fmt={ param($v) Format-CVSizeGB2Raw $v } }

    @{ Key='SQL'; Source='SqlDbInventory'; Group='Region'; Label='SQL Databases'; SeqOverall=6
       # Counts each elastic pool once - see Get-CVSqlDbSizeTotal.
       Measure={ param($r) Get-CVSqlDbSizeTotal -Rows $r }
       FmtOverall={ param($v) Format-CVSizeGB2Raw $v }; Fmt={ param($v) Format-CVSizeGB2Raw $v } }

    # ARRAY ORDER IS THE REGIONAL / PER-SUBSCRIPTION ORDER, and it is NOT the overall pass's order: the inline
    # code emitted MySQL and PostgreSQL from inside its SQL branch (so before Cosmos) in the overall pass, but
    # after Cosmos everywhere else. SeqOverall re-sorts the overall pass to match. Nobody would guess this; the
    # golden file is how it was found.
    @{ Key='COSMOS'; Source='CosmosDBs'; Group='Location'; Label='CosmosDB'; SeqOverall=9
       Measure={ param($r) Measure-CVLooseSum $r 'DataUsage' }
       FmtOverall={ param($v) Format-CVSizeBytes2 $v }; Fmt={ param($v) Format-CVSizeBytes4 $v } }

    @{ Key='SQL'; Source='MySQLServers'; Group='Location'; Label='MySQL Servers'; SeqOverall=7
       Measure={ param($r) Measure-CVLooseSum $r 'StorageUsedGB' }
       FmtOverall={ param($v) Format-CVSizeGB2 $v }; Fmt={ param($v) Format-CVSizeGB4 $v } }

    @{ Key='SQL'; Source='PostgreSQLServers'; Group='Location'; Label='PostgreSQL Servers'; SeqOverall=8
       Measure={ param($r) Measure-CVLooseSum $r 'StorageUsedGB' }
       FmtOverall={ param($v) Format-CVSizeGB2 $v }; Fmt={ param($v) Format-CVSizeGB4 $v } }

    @{ Key='AKS'; Source='AKSClusters'; Group='Region'; SeqOverall=10
       # PV/PVC counts are interpolated INTO the label, and the two passes word it differently.
       LabelOverall={ param($r) "AKS Clusters (Total PVs: $([int](Measure-CVLooseSum $r 'PersistentVolumeCount')), PVCs: $([int](Measure-CVLooseSum $r 'PersistentVolumeClaimCount')))" }
       Label={ param($r) "AKS Clusters (PVs: $([int](Measure-CVLooseSum $r 'PersistentVolumeCount')), PVCs: $([int](Measure-CVLooseSum $r 'PersistentVolumeClaimCount')))" }
       Measure={ param($r) Measure-CVLooseSum $r 'PersistentVolumeCapacityGB' }
       FmtOverall={ param($v) Format-CVSizeGB2 $v }; Fmt={ param($v) Format-CVSizeGB4 $v } }

    # Per-subscription only, and with blank rather than zero sizes - these are counts, not capacity.
    @{ Key='BACKUP'; Source='BackupItems'; SubOnly=$true
       Label={ param($r) "Backup Items (Protected: $(@($r | Where-Object { $_.ProtectionState -eq 'Protected' }).Count))" } }
    @{ Key='UNMANAGEDDISKS'; Source='UnmanagedDiskItems'; SubOnly=$true; Group='Region'
       Label={ param($r) "Disks (Unattached: $(@($r | Where-Object { $_.AttachedToVM -eq 'Unattached' }).Count))" }
       Measure={ param($r) Measure-CVSum $r 'DiskSizeGB' }
       Fmt={ param($v) Format-CVSizeRawGB $v } }
    @{ Key='AVS'; Source='AVSClusters'; SubOnly=$true
       Label={ param($r) "AVS Private Clouds (Total Hosts: $([int](Measure-CVSum $r 'TotalHostCount')))" } }
)

# ---- row builders ---------------------------------------------------------------------------------------

function New-CVAzSummaryRow {
    <# .SYNOPSIS  One summary row. Property ORDER defines the CSV column order. #>
    param([string]$Subscription, [string]$ResourceType, $Region, $Count, $GB, $TB, $TiB)
    [PSCustomObject]@{
        Subscription = $Subscription
        ResourceType = $ResourceType
        Region       = $Region
        Count        = $Count
        TotalSizeGB  = $GB
        TotalSizeTB  = $TB
        TotalSizeTiB = $TiB
    }
}

# The two spacer shapes are NOT interchangeable. The first sets every field to ''; the second omits Subscription
# altogether, so Export-Csv renders it as an unquoted empty. Both appear in the shipped file.
function New-CVAzSummarySpacer { New-CVAzSummaryRow -Subscription '' -ResourceType '' -Region '' -Count '' -GB '' -TB '' -TiB '' }
function New-CVAzSummarySpacerNoSub {
    [PSCustomObject]@{ ResourceType = ''; Region = $null; Count = $null; TotalSizeGB = $null; TotalSizeTB = $null; TotalSizeTiB = $null }
}

function Get-CVAzSummaryLabel {
    param($Descriptor, $Rows, [switch]$Overall)
    $spec = if ($Overall -and $Descriptor.LabelOverall) { $Descriptor.LabelOverall } else { $Descriptor.Label }
    if ($spec -is [scriptblock]) { return [string](& $spec $Rows) }
    return [string]$spec
}

function Get-CVAzSummarySize {
    <# .SYNOPSIS  Measure + format a row set, choosing the pass-specific formatter. #>
    param($Descriptor, $Rows, [switch]$Overall)
    if (-not $Descriptor.Measure) { return @{ GB = ''; TB = ''; TiB = '' } }   # count-only types
    $raw = & $Descriptor.Measure $Rows
    $fmt = if ($Overall -and $Descriptor.FmtOverall) { $Descriptor.FmtOverall } else { $Descriptor.Fmt }
    return (& $fmt ([double]$raw))
}

function Get-CVAzureInventorySummary {
    <#
      .SYNOPSIS  Build every row of azure_inventory_summary_<date>.csv.
      .PARAMETER Inventory  hashtable of collection name -> rows, e.g. @{ VMs = $VMs; StorageAccounts = ... }.
      .PARAMETER Selected   the -Types gate.
      .PARAMETER Subscriptions  the subscription objects actually processed (each with .Name).
      .OUTPUTS   The summary rows, in file order.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Inventory,
        [Parameter(Mandatory)][hashtable]$Selected,
        $Subscriptions = @()
    )

    $rows  = [System.Collections.Generic.List[psobject]]::new()
    $types = $script:CVAzSummaryTypes

    function Get-Rows { param($Name) @($Inventory[$Name] | Where-Object { $_ }) }

    # ---- Pass A: overall totals, one row per type -------------------------------------------------------
    # Sorted by SeqOverall: this pass orders types differently from the others (see the table's note).
    foreach ($d in ($types | Where-Object { $_.SeqOverall } | Sort-Object { $_.SeqOverall })) {
        if ($d.SubOnly) { continue }
        if (-not $Selected[$d.Key]) { continue }
        $all = Get-Rows $d.Source
        if (-not $all.Count) { continue }
        $sz = Get-CVAzSummarySize -Descriptor $d -Rows $all -Overall
        $rows.Add((New-CVAzSummaryRow -Subscription 'All' -ResourceType (Get-CVAzSummaryLabel -Descriptor $d -Rows $all -Overall) `
                                      -Region 'All' -Count $all.Count -GB $sz.GB -TB $sz.TB -TiB $sz.TiB))
    }

    $rows.Add((New-CVAzSummarySpacer))

    # ---- Pass B: regional totals across all subscriptions -----------------------------------------------
    foreach ($d in $types) {
        if ($d.SubOnly) { continue }
        if (-not $Selected[$d.Key]) { continue }
        $all = Get-Rows $d.Source
        if (-not $all.Count) { continue }
        foreach ($g in ($all | Group-Object $d.Group | Sort-Object Name)) {
            $sz = Get-CVAzSummarySize -Descriptor $d -Rows $g.Group
            $rows.Add((New-CVAzSummaryRow -Subscription 'All' -ResourceType (Get-CVAzSummaryLabel -Descriptor $d -Rows $g.Group) `
                                          -Region $g.Name -Count $g.Count -GB $sz.GB -TB $sz.TB -TiB $sz.TiB))
        }
    }

    $rows.Add((New-CVAzSummarySpacerNoSub))
    $rows.Add((New-CVAzSummaryRow -Subscription '[ Subscription level Summary ]' -ResourceType '' -Region '' -Count '' -GB '' -TB '' -TiB ''))

    # ---- Pass C/D: per subscription, a total then its regional breakdown --------------------------------
    foreach ($sub in @($Subscriptions)) {
        $subName = "$($sub.Name)"
        $rows.Add((New-CVAzSummaryRow -Subscription $subName -ResourceType '' -Region '' -Count '' -GB '' -TB '' -TiB ''))

        foreach ($d in $types) {
            if (-not $Selected[$d.Key]) { continue }
            $mine = @((Get-Rows $d.Source) | Where-Object { "$($_.Subscription)" -eq $subName })
            if (-not $mine.Count) { continue }

            $sz = Get-CVAzSummarySize -Descriptor $d -Rows $mine
            $rows.Add((New-CVAzSummaryRow -Subscription $subName -ResourceType (Get-CVAzSummaryLabel -Descriptor $d -Rows $mine) `
                                          -Region 'All' -Count $mine.Count -GB $sz.GB -TB $sz.TB -TiB $sz.TiB))

            # SubOnly types are counts against the subscription; they have no regional breakdown.
            if ($d.SubOnly -or -not $d.Group) { continue }
            foreach ($g in ($mine | Group-Object $d.Group | Sort-Object Name)) {
                $gsz = Get-CVAzSummarySize -Descriptor $d -Rows $g.Group
                $rows.Add((New-CVAzSummaryRow -Subscription $subName -ResourceType (Get-CVAzSummaryLabel -Descriptor $d -Rows $g.Group) `
                                              -Region $g.Name -Count $g.Count -GB $gsz.GB -TB $gsz.TB -TiB $gsz.TiB))
            }
        }
        $rows.Add((New-CVAzSummarySpacer))
    }

    return $rows
}
