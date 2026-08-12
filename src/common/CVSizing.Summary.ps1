<#
    CVSizing.Summary.ps1 - the cloud-agnostic inventory-summary engine.

    Extracted from CVSizing.Summary.Azure.ps1 so AWS (and later GCP) can emit the same four-tier rollup
    instead of an Excel workbook. Everything here is shape and control flow; every number is decided by the
    per-cloud descriptor table that gets passed in (-Types), so this file cannot change a total.

    The four passes, in file order:
      A  overall totals              - one row per resource type, scope 'All', region 'All'
      B  overall regional totals     - one row per type per region, scope 'All'
      C  per-scope totals            - one row per type within one subscription / account, region 'All'
      D  per-scope regional totals   - the same broken out by region

    "Scope" is the tenancy axis: a subscription in Azure, an account in AWS, a project in GCP. It is named
    twice on purpose - -ScopeColumn is the CSV HEADER, -ScopeProperty is the INVENTORY ROW PROPERTY filtered
    on - because those genuinely differ (AWS publishes a column called Account but filters on AwsAccountId).

    Azure's output is pinned byte-for-byte by tests/fixtures/azure_summary_golden.csv, so this extraction is
    verifiable: if a formatter or an ordering rule moved during the move, that test names the exact cell.
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

# Decimal-gigabyte input, converted honestly. Used by AWS, whose size columns are all decimal GB.
# The Format-CVSizeGB* family above derives TiB as GB/1024, which silently treats a decimal gigabyte as a
# binary one and overstates TiB by 7.4%. Azure's output is frozen against a golden file so that stays as it is;
# nothing new should copy it. GB * 1e9 / 2^40 is the byte-exact identity.
function Format-CVSizeGBDecimal {
    param([double]$Gb)
    @{ GB  = [math]::Round($Gb, 2)
       TB  = [math]::Round($Gb / 1000, 4)
       TiB = [math]::Round(($Gb * 1000000000) / 1099511627776, 4) }
}

# Byte totals (storage, file shares, NetApp).
function Format-CVSizeBytes { param([double]$Bytes) @{ GB = (ConvertTo-CVGB $Bytes); TB = (ConvertTo-CVTB $Bytes); TiB = (ConvertTo-CVTiB $Bytes) } }
# Cosmos measures bytes too, but zero stays a hard 0 and the regional pass wants 4dp gigabytes.
function Format-CVSizeBytes2 { param([double]$Bytes) @{ GB = $(if ($Bytes -gt 0) { [math]::Round($Bytes / 1000000000, 2) } else { 0 })
                                                        TB = $(if ($Bytes -gt 0) { ConvertTo-CVTB  $Bytes } else { 0 })
                                                        TiB = $(if ($Bytes -gt 0) { ConvertTo-CVTiB $Bytes } else { 0 }) } }
function Format-CVSizeBytes4 { param([double]$Bytes) @{ GB = $(if ($Bytes -gt 0) { [math]::Round($Bytes / 1000000000, 4) } else { 0 })
                                                        TB = $(if ($Bytes -gt 0) { ConvertTo-CVTB  $Bytes } else { 0 })
                                                        TiB = $(if ($Bytes -gt 0) { ConvertTo-CVTiB $Bytes } else { 0 }) } }

# ---- row builders ---------------------------------------------------------------------------------------

function New-CVSummaryRow {
    <#
      .SYNOPSIS  One summary row. Property ORDER defines the CSV column order.
      .DESCRIPTION The scope column is named at runtime, so an OrderedDictionary is required - casting a plain
                   hashtable would let .NET's key order decide the customer's column layout.
    #>
    param([string]$ScopeColumn, [string]$Scope, [string]$ResourceType, $Region, $Count, $GB, $TB, $TiB)
    $o = [ordered]@{}
    $o[$ScopeColumn]   = $Scope
    $o['ResourceType'] = $ResourceType
    $o['Region']       = $Region
    $o['Count']        = $Count
    $o['TotalSizeGB']  = $GB
    $o['TotalSizeTB']  = $TB
    $o['TotalSizeTiB'] = $TiB
    [PSCustomObject]$o
}

# The two spacer shapes are NOT interchangeable. The first sets every field to ''; the second omits the scope
# column altogether, so Export-Csv renders it as an unquoted empty. Both appear in the shipped file.
function New-CVSummarySpacer {
    param([string]$ScopeColumn)
    New-CVSummaryRow -ScopeColumn $ScopeColumn -Scope '' -ResourceType '' -Region '' -Count '' -GB '' -TB '' -TiB ''
}
function New-CVSummarySpacerNoScope {
    [PSCustomObject]@{ ResourceType = ''; Region = $null; Count = $null; TotalSizeGB = $null; TotalSizeTB = $null; TotalSizeTiB = $null }
}

function Get-CVSummaryLabel {
    param($Descriptor, $Rows, [switch]$Overall)
    $spec = if ($Overall -and $Descriptor.LabelOverall) { $Descriptor.LabelOverall } else { $Descriptor.Label }
    if ($spec -is [scriptblock]) { return [string](& $spec $Rows) }
    return [string]$spec
}

function Get-CVSummarySize {
    <# .SYNOPSIS  Measure + format a row set, choosing the pass-specific formatter. #>
    param($Descriptor, $Rows, [switch]$Overall)
    if (-not $Descriptor.Measure) { return @{ GB = ''; TB = ''; TiB = '' } }   # count-only types
    $raw = & $Descriptor.Measure $Rows
    $fmt = if ($Overall -and $Descriptor.FmtOverall) { $Descriptor.FmtOverall } else { $Descriptor.Fmt }
    return (& $fmt ([double]$raw))
}

function Get-CVInventorySummary {
    <#
      .SYNOPSIS  Build every row of <cloud>_inventory_summary_<date>.csv from a descriptor table.
      .PARAMETER Types        the per-cloud descriptor table; DECLARATION ORDER IS OUTPUT ORDER.
      .PARAMETER Inventory    hashtable of collection name -> rows, e.g. @{ VMs = $VMs; StorageAccounts = ... }.
      .PARAMETER Selected     the -Types gate, keyed by each descriptor's Key.
      .PARAMETER Scopes       the subscriptions / accounts actually processed; each needs a .Name.
      .PARAMETER ScopeColumn  CSV header for the tenancy column ('Subscription', 'Account').
      .PARAMETER ScopeProperty  inventory-row property matched against each scope's .Name. Defaults to
                                ScopeColumn, which is right for Azure and wrong for AWS - hence the parameter.
      .PARAMETER ScopeHeaderLabel  the banner row that introduces the per-scope section.
      .OUTPUTS   The summary rows, in file order.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Types,
        [Parameter(Mandatory)][hashtable]$Inventory,
        [Parameter(Mandatory)][hashtable]$Selected,
        $Scopes = @(),
        [string]$ScopeColumn = 'Subscription',
        [string]$ScopeProperty,
        [string]$ScopeHeaderLabel = '[ Subscription level Summary ]'
    )

    if ([string]::IsNullOrWhiteSpace($ScopeProperty)) { $ScopeProperty = $ScopeColumn }

    $rows = [System.Collections.Generic.List[psobject]]::new()

    function Get-Rows { param($Name) @($Inventory[$Name] | Where-Object { $_ }) }

    # ---- Pass A: overall totals, one row per type -------------------------------------------------------
    # Sorted by SeqOverall: this pass orders types differently from the others (see the table's note).
    foreach ($d in ($Types | Where-Object { $_.SeqOverall } | Sort-Object { $_.SeqOverall })) {
        if ($d.SubOnly) { continue }
        if (-not $Selected[$d.Key]) { continue }
        $all = Get-Rows $d.Source
        if (-not $all.Count) { continue }
        $sz = Get-CVSummarySize -Descriptor $d -Rows $all -Overall
        $rows.Add((New-CVSummaryRow -ScopeColumn $ScopeColumn -Scope 'All' -ResourceType (Get-CVSummaryLabel -Descriptor $d -Rows $all -Overall) `
                                    -Region 'All' -Count $all.Count -GB $sz.GB -TB $sz.TB -TiB $sz.TiB))
    }

    $rows.Add((New-CVSummarySpacer -ScopeColumn $ScopeColumn))

    # ---- Pass B: regional totals across all scopes ------------------------------------------------------
    foreach ($d in $Types) {
        if ($d.SubOnly) { continue }
        if (-not $Selected[$d.Key]) { continue }
        $all = Get-Rows $d.Source
        if (-not $all.Count) { continue }
        foreach ($g in ($all | Group-Object $d.Group | Sort-Object Name)) {
            $sz = Get-CVSummarySize -Descriptor $d -Rows $g.Group
            $rows.Add((New-CVSummaryRow -ScopeColumn $ScopeColumn -Scope 'All' -ResourceType (Get-CVSummaryLabel -Descriptor $d -Rows $g.Group) `
                                        -Region $g.Name -Count $g.Count -GB $sz.GB -TB $sz.TB -TiB $sz.TiB))
        }
    }

    $rows.Add((New-CVSummarySpacerNoScope))
    $rows.Add((New-CVSummaryRow -ScopeColumn $ScopeColumn -Scope $ScopeHeaderLabel -ResourceType '' -Region '' -Count '' -GB '' -TB '' -TiB ''))

    # ---- Pass C/D: per scope, a total then its regional breakdown ----------------------------------------
    foreach ($sc in @($Scopes)) {
        $scName = "$($sc.Name)"
        $rows.Add((New-CVSummaryRow -ScopeColumn $ScopeColumn -Scope $scName -ResourceType '' -Region '' -Count '' -GB '' -TB '' -TiB ''))

        foreach ($d in $Types) {
            if (-not $Selected[$d.Key]) { continue }
            $mine = @((Get-Rows $d.Source) | Where-Object { "$($_.$ScopeProperty)" -eq $scName })
            if (-not $mine.Count) { continue }

            $sz = Get-CVSummarySize -Descriptor $d -Rows $mine
            $rows.Add((New-CVSummaryRow -ScopeColumn $ScopeColumn -Scope $scName -ResourceType (Get-CVSummaryLabel -Descriptor $d -Rows $mine) `
                                        -Region 'All' -Count $mine.Count -GB $sz.GB -TB $sz.TB -TiB $sz.TiB))

            # SubOnly types are counts against the scope; they have no regional breakdown.
            if ($d.SubOnly -or -not $d.Group) { continue }
            foreach ($g in ($mine | Group-Object $d.Group | Sort-Object Name)) {
                $gsz = Get-CVSummarySize -Descriptor $d -Rows $g.Group
                $rows.Add((New-CVSummaryRow -ScopeColumn $ScopeColumn -Scope $scName -ResourceType (Get-CVSummaryLabel -Descriptor $d -Rows $g.Group) `
                                            -Region $g.Name -Count $g.Count -GB $gsz.GB -TB $gsz.TB -TiB $gsz.TiB))
            }
        }
        $rows.Add((New-CVSummarySpacer -ScopeColumn $ScopeColumn))
    }

    return $rows
}
