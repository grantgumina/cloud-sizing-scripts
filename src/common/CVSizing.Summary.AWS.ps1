<#
    CVSizing.Summary.AWS.ps1 - the AWS descriptor table for the shared rollup engine in CVSizing.Summary.ps1.

    Replaces the two Excel workbooks the script used to write (a per-account one and a consolidated one) with
    aws_inventory_summary_<date>.csv, in the same four-tier shape Azure publishes: overall totals, overall
    regional totals, then per-account totals and their regional breakdown. Dropping the workbooks also drops
    the ImportExcel dependency, which was the script's only non-AWS module requirement.

    THREE DELIBERATE DIFFERENCES FROM THE RETIRED WORKBOOKS, all of them visible in customer output:

    1. S3 totals are now HALF what the workbook reported, because the workbook double-counted them.
       Process-S3Bucket accumulates $totalBytes across the seven storage classes and publishes that as SizeGB,
       and THEN stamps each class separately as <CLASS>_SizeGB. Get-S3ServiceTotals summed every property
       matching '(_SizeGB$|^SizeGB$)' - the whole-bucket figure plus its own parts. Every bucket whose
       per-storage-class CloudWatch metrics resolved was reported at exactly 2x its real size. (Buckets that
       fell back to the AllStorageTypes metric left the per-class values at 0 and were reported correctly,
       so the error was proportional to how well the metrics worked - which is why it survived.)
       Each descriptor below names ONE property explicitly; there is no property-name probing left to go wrong.

    2. Sizes are published as GB / TB / TiB, not GiB / GB / TiB / TB. That is Azure's column set, and matching
       it is the point of this file. TiB here is computed from the byte-exact identity GB * 1e9 / 2^40 rather
       than the GB/1024 shortcut, so it is a true binary tebibyte.

    3. The FSx per-filesystem-TYPE breakdown is gone. The Region column has one meaning in this schema and
       Type is not a region. Every FSx row still carries Type in aws_fsx_*.csv, so the breakdown is one pivot
       away, and keeping the column honest is worth more than pre-pivoting it here.

    Counts the workbook published as extra COLUMNS (object count, item count, node count) are folded into the
    resource-type LABEL instead, which is the pattern Azure already uses for AKS persistent volumes. Nothing
    is lost and the column set stays uniform.
#>

function Get-CVAwsLabelWithTotal {
    <#
      .SYNOPSIS  "<Base> (<Caption>: <total>)", or just "<Base>" when the total is zero.
      .DESCRIPTION Keeps aggregate counts inside the label so the CSV can carry them without growing a column
                   that is meaningless for every other resource type.
    #>
    param([string]$Base, [string]$Caption, $Rows, [string]$Property)
    $t = Measure-CVLooseSum $Rows $Property
    if ($t -le 0) { return $Base }
    return "$Base ($Caption`: $([long]$t))"
}

# ---- the type table -------------------------------------------------------------------------------------
<#
    ORDER IS THE OUTPUT ORDER for every pass; SeqOverall is stated explicitly so the overall pass cannot drift
    from it. Fields are the ones CVSizing.Summary.ps1 reads:
      Key      - the -Types gate ($Selected[$Key]); also the ServiceRegistry key.
      Source   - key into the caller's -Inventory hashtable (same service name).
      Group    - property to group the regional passes by. Every AWS row carries Region.
      Label    - static string, or a scriptblock over the row set for labels carrying an aggregate.
      Measure  - scriptblock: rows -> a single raw total, in DECIMAL GIGABYTES. Omitted for count-only types.
      Fmt      - raw total -> @{GB;TB;TiB}.

    Measure names the one true size property per service. They differ only by prefix, but they are spelled out
    rather than derived because a wrong guess here silently changes a customer's sizing number.
#>
$script:CVAwsSummaryTypes = @(
    @{ Key = 'EC2'; Source = 'EC2'; Group = 'Region'; SeqOverall = 1
       Label = { param($r) Get-CVAwsLabelWithTotal -Base 'EC2 Instances' -Caption 'Volumes' -Rows $r -Property 'VolumeCount' }
       Measure = { param($r) Measure-CVLooseSum $r 'SizeGB' }
       Fmt = { param($v) Format-CVSizeGBDecimal $v } }

    @{ Key = 'UnattachedVolumes'; Source = 'UnattachedVolumes'; Group = 'Region'; SeqOverall = 2
       Label = 'Unattached EBS Volumes'
       Measure = { param($r) Measure-CVLooseSum $r 'SizeGB' }
       Fmt = { param($v) Format-CVSizeGBDecimal $v } }

    @{ Key = 'S3'; Source = 'S3'; Group = 'Region'; SeqOverall = 3
       Label = { param($r) Get-CVAwsLabelWithTotal -Base 'S3 Buckets' -Caption 'Objects' -Rows $r -Property 'ObjectCount' }
       # SizeGB only - never the <CLASS>_SizeGB columns, which are this same total broken out (see header note 1).
       Measure = { param($r) Measure-CVLooseSum $r 'SizeGB' }
       Fmt = { param($v) Format-CVSizeGBDecimal $v } }

    @{ Key = 'EFS'; Source = 'EFS'; Group = 'Region'; SeqOverall = 4
       Label = 'EFS File Systems'
       Measure = { param($r) Measure-CVLooseSum $r 'SizeGB' }
       Fmt = { param($v) Format-CVSizeGBDecimal $v } }

    @{ Key = 'FSX'; Source = 'FSX'; Group = 'Region'; SeqOverall = 5
       Label = 'FSx File Systems'
       Measure = { param($r) Measure-CVLooseSum $r 'StorageCapacityGB' }
       Fmt = { param($v) Format-CVSizeGBDecimal $v } }

    @{ Key = 'FSX_SVM'; Source = 'FSX_SVM'; Group = 'Region'; SeqOverall = 6
       Label = { param($r) Get-CVAwsLabelWithTotal -Base 'FSx ONTAP SVMs' -Caption 'Volumes' -Rows $r -Property 'VolumeCount' }
       Measure = { param($r) Measure-CVLooseSum $r 'VolumesSizeGB' }
       Fmt = { param($v) Format-CVSizeGBDecimal $v } }

    @{ Key = 'RDS'; Source = 'RDS'; Group = 'Region'; SeqOverall = 7
       Label = 'RDS Databases'
       Measure = { param($r) Measure-CVLooseSum $r 'SizeGB' }
       Fmt = { param($v) Format-CVSizeGBDecimal $v } }

    @{ Key = 'Aurora'; Source = 'Aurora'; Group = 'Region'; SeqOverall = 8
       Label = { param($r) Get-CVAwsLabelWithTotal -Base 'Aurora Clusters' -Caption 'Instances' -Rows $r -Property 'InstanceCount' }
       Measure = { param($r) Measure-CVLooseSum $r 'SizeGB' }
       Fmt = { param($v) Format-CVSizeGBDecimal $v } }

    @{ Key = 'DocumentDB'; Source = 'DocumentDB'; Group = 'Region'; SeqOverall = 9
       Label = { param($r) Get-CVAwsLabelWithTotal -Base 'DocumentDB Clusters' -Caption 'Instances' -Rows $r -Property 'InstanceCount' }
       Measure = { param($r) Measure-CVLooseSum $r 'SizeGB' }
       Fmt = { param($v) Format-CVSizeGBDecimal $v } }

    @{ Key = 'DynamoDB'; Source = 'DynamoDB'; Group = 'Region'; SeqOverall = 10
       Label = { param($r) Get-CVAwsLabelWithTotal -Base 'DynamoDB Tables' -Caption 'Items' -Rows $r -Property 'ItemCount' }
       Measure = { param($r) Measure-CVLooseSum $r 'TableSizeGB' }
       Fmt = { param($v) Format-CVSizeGBDecimal $v } }

    @{ Key = 'Redshift'; Source = 'Redshift'; Group = 'Region'; SeqOverall = 11
       Label = { param($r) Get-CVAwsLabelWithTotal -Base 'Redshift Clusters' -Caption 'Nodes' -Rows $r -Property 'NodeCount' }
       Measure = { param($r) Measure-CVLooseSum $r 'TotalSizeGB' }
       Fmt = { param($v) Format-CVSizeGBDecimal $v } }

    # Count-only: no Measure, so the engine emits empty size cells rather than a misleading 0.
    # ElastiCache rows carry no capacity figure at all - Process-ElastiCacheCluster collects none, because the
    # data is in-memory and node-type-derived rather than reported by the API.
    @{ Key = 'ElastiCache'; Source = 'ElastiCache'; Group = 'Region'; SeqOverall = 12
       Label = 'ElastiCache Clusters' }

    @{ Key = 'EKS'; Source = 'EKS'; Group = 'Region'; SeqOverall = 13
       Label = { param($r) Get-CVAwsLabelWithTotal -Base 'EKS Clusters' -Caption 'Nodes' -Rows $r -Property 'NodeCount' }
       Measure = { param($r) Measure-CVLooseSum $r 'SizeGB' }
       Fmt = { param($v) Format-CVSizeGBDecimal $v } }

    # Count-only on purpose. The only size on these rows is LastBackupSizeGB - the size of ONE recovery point
    # per resource. Summing it would produce a number that looks like protected capacity but is neither the
    # source capacity (already counted above, per service) nor the vault's stored size (never collected).
    @{ Key = 'AWSBackup'; Source = 'AWSBackup'; Group = 'Region'; SeqOverall = 14
       Label = 'AWS Backup Protected Resources' }
)

# ---- entry point ----------------------------------------------------------------------------------------

function Get-CVAwsInventorySummary {
    <#
      .SYNOPSIS  Build every row of aws_inventory_summary_<date>.csv.
      .PARAMETER Inventory  hashtable of service name -> rows across ALL accounts, e.g. @{ EC2 = ...; S3 = ... }.
      .PARAMETER Selected   the -Types gate, keyed by service name.
      .PARAMETER Accounts   the accounts actually processed; each needs a .Name holding the account ID.
      .OUTPUTS   The summary rows, in file order.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Inventory,
        [Parameter(Mandatory)][hashtable]$Selected,
        $Accounts = @()
    )

    # The column is 'Account' but the row property is 'AwsAccountId' - the two genuinely differ here, which is
    # why the engine takes them separately.
    Get-CVInventorySummary -Types $script:CVAwsSummaryTypes -Inventory $Inventory -Selected $Selected `
                           -Scopes $Accounts -ScopeColumn 'Account' -ScopeProperty 'AwsAccountId' `
                           -ScopeHeaderLabel '[ Account level Summary ]'
}
