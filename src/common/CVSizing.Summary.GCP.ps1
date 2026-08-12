<#
    CVSizing.Summary.GCP.ps1 - the GCP descriptor table for the shared rollup engine in CVSizing.Summary.ps1.

    Replaces ~250 lines of hand-rolled inline rollup that emitted a 9-column schema (Level, ResourceType,
    Project, Region, Zone, Count, TotalSizeGB, TotalSizeTB, TotalSizeTiB) across five tiers. GCP now publishes
    the same 7 columns as Azure and AWS.

    WHY Level AND Zone WENT AWAY

    Level was redundant. Its values were exactly Overall / Project / Region / Zone / a banner string / '', and
    every one of them is already determined by the (Project, Region) pair the engine emits positionally:
    All/All is the overall tier, <proj>/All is a project total, All/<region> is a cumulative region, and
    <proj>/<region> is that project's regional breakdown.

    Zone was NOT redundant, but the tier that carried it was already broken: regional persistent disks are
    stamped Zone = '' by the VM collector, so the zone rows summed to LESS than the region row directly above
    them by exactly the regional-PD capacity. Zone detail now lives in its own pure CSV via
    Get-CVGcpVmZoneRollup below, computed from VM rows so it reconciles with the VM row in the main summary.

    THE DEDUPE THAT HAD TO GO

    Every VM tier used `$attached | Select-Object DiskName,SizeGB -Unique` - no Project and no Zone component.
    GCP disk names are unique per zone, not per project or per organisation. A symmetric two-zone deployment
    with a 100 GB disk named `data` in each zone collapsed to ONE 100 GB entry at the overall, project and
    region tiers while the zone tier kept both, so the same project's section showed us-central1 = 100 GB above
    two zone rows of 100 GB each. Boot disks at conventional names and identical sizes (instance-1, default)
    collapsed across dev/staging/prod, which made the sum of the per-project VM rows EXCEED the overall VM row.

    The fix is not a better dedup key - it is not needing one. VM rows already carry
    VMDiskSizeGB = [int64]$vmDiskGB, the per-VM sum of that VM's own attachments, which is exactly the property
    Azure's VM descriptor sums. Measuring over VMs removes the cross-collection join the engine cannot express
    and makes the summary reconcile with gcp_vm_instance_info_*.csv.

    UNITS

    Disk.sizeGb is treated as DECIMAL GB, which is what the script has always done and what the published GB
    figures already assume. (Google prices Persistent Disk per GiB, so this is a deliberate, signed-off choice
    to keep existing sizing numbers stable rather than an assertion about the API. If it is ever revisited,
    swap the two Format-CVSizeGBDecimal entries below for Format-CVSizeGiB and nothing else changes.)

    Several other GCP figures are binary despite a "GB" name and get Format-CVSizeGiB: Filestore
    provisionedGib, GKE PersistentVolumeCapacityGB (which comes from Convert-QuantityToGiB), AlloyDB monitored
    usage, and BigQuery physical bytes already divided by 1GB. Buckets measure real bytes.

    DELIBERATELY NOT A DESCRIPTOR: FilestoreInstances.

    Get-GcpFileShareInventory and Get-GcpFilestoreInventory are two separate collectors over the SAME
    `gcloud filestore instances list` data, each emitting one row per (instance, share). With the default
    -Types both collections are populated, so giving each a descriptor would report every Filestore share
    twice. FILESHARE is the one that carries provisionedGib, so it wins. This is the same class of trap as the
    AWS S3 double-count documented in CVSizing.Summary.AWS.ps1.
#>

function Get-CVGcpLabelWithTotal {
    <# .SYNOPSIS  "<Base> (<Caption>: <total>)", or just "<Base>" when the total is zero. #>
    param([string]$Base, [string]$Caption, $Rows, [string]$Property)
    $t = Measure-CVLooseSum $Rows $Property
    if ($t -le 0) { return $Base }
    return "$Base ($Caption`: $([long]$t))"
}

# ---- the type table -------------------------------------------------------------------------------------
<#
    ORDER IS THE OUTPUT ORDER for every pass; SeqOverall is stated explicitly so the overall pass cannot drift.
      Key      - the -Types gate ($Selected[$Key]). UPPERCASE, matching $ResourceTypeMap in the GCP script.
      Source   - key into the caller's -Inventory hashtable.
      Group    - property the regional passes group by. Buckets group by Location, not Region: bucket rows
                 carry a GCS location ('us', 'eu', 'us-central1') and have no Region property at all.
      Measure  - scriptblock: rows -> one raw total. Omitted for count-only types.
      Fmt      - raw total -> @{GB;TB;TiB}. Chosen per the unit of the property Measure names.

    Four descriptors share Key='DB' on purpose. The engine supports that (Azure's SQL emits four), and it
    replaces a single fused Database row that added Cloud SQL provisioned disk to a Spanner capacity ceiling to
    AlloyDB monitored usage to BigQuery physical bytes - a number that was not a quantity in any unit. Each row
    now states its own basis in its label so the figure is auditable.
#>
$script:CVGcpSummaryTypes = @(
    @{ Key = 'VM'; Source = 'VMs'; Group = 'Region'; SeqOverall = 1
       Label = { param($r) Get-CVGcpLabelWithTotal -Base 'VM' -Caption 'Disks' -Rows $r -Property 'DiskCount' }
       # VMDiskSizeGB, not a join onto AttachedDisks - see the dedupe note in the header.
       Measure = { param($r) Measure-CVSum $r 'VMDiskSizeGB' }
       Fmt = { param($v) Format-CVSizeGBDecimal $v } }

    # Absent from the old rollup entirely, though they are collected, billable and protectable.
    @{ Key = 'VM'; Source = 'UnattachedDisks'; Group = 'Region'; SeqOverall = 2
       Label = 'Unattached Persistent Disk'
       Measure = { param($r) Measure-CVSum $r 'SizeGB' }
       Fmt = { param($v) Format-CVSizeGBDecimal $v } }

    @{ Key = 'STORAGE'; Source = 'StorageBuckets'; Group = 'Location'; SeqOverall = 3
       Label = 'Storage Bucket'
       Measure = { param($r) Measure-CVSum $r 'UsedCapacityBytes' }
       Fmt = { param($v) Format-CVSizeBytes $v } }

    @{ Key = 'FILESHARE'; Source = 'FileShares'; Group = 'Region'; SeqOverall = 4
       Label = 'Filestore Share'
       Measure = { param($r) Measure-CVLooseSum $r 'provisionedGib' }
       Fmt = { param($v) Format-CVSizeGiB $v } }

    # --- the four database services, formerly one fused row ---
    @{ Key = 'DB'; Source = 'CloudSqlInstances'; Group = 'Region'; SeqOverall = 5
       Label = 'Cloud SQL Instance (provisioned disk)'
       Measure = { param($r) Measure-CVLooseSum $r 'StorageGB' }
       Fmt = { param($v) Format-CVSizeGBDecimal $v } }

    @{ Key = 'DB'; Source = 'SpannerInstances'; Group = 'Region'; SeqOverall = 6
       # Not a measurement: the collector derives a per-node capacity ceiling. Labelled so nobody reads it as used.
       Label = 'Spanner Instance (derived capacity ceiling)'
       Measure = { param($r) Measure-CVLooseSum $r 'StorageGB' }
       Fmt = { param($v) Format-CVSizeGiB $v } }

    @{ Key = 'DB'; Source = 'AlloyDbClusters'; Group = 'Region'; SeqOverall = 7
       Label = 'AlloyDB Cluster (monitored usage)'
       Measure = { param($r) Measure-CVLooseSum $r 'StorageGB' }
       Fmt = { param($v) Format-CVSizeGiB $v } }

    @{ Key = 'DB'; Source = 'BigQueryDatasets'; Group = 'Region'; SeqOverall = 8
       Label = 'BigQuery Dataset (physical)'
       Measure = { param($r) Measure-CVLooseSum $r 'TotalPhysicalSizeGB' }
       Fmt = { param($v) Format-CVSizeGiB $v } }

    @{ Key = 'GKE'; Source = 'GKEClusters'; Group = 'Region'; SeqOverall = 9
       Label = { param($r) Get-CVGcpLabelWithTotal -Base 'GKE Cluster' -Caption 'PVs' -Rows $r -Property 'PersistentVolumeCount' }
       # The field is named ...GB but holds GiB - it comes from Convert-QuantityToGiB over the Kubernetes quantity.
       Measure = { param($r) Measure-CVLooseSum $r 'PersistentVolumeCapacityGB' }
       Fmt = { param($v) Format-CVSizeGiB $v } }

    # Snapshot totals used to be APPENDED into gcp_disk_snapshots_*.csv, which made a consumer's
    # Measure-Object StorageTB -Sum return exactly 2x. This is where the figure belongs.
    @{ Key = 'SNAPSHOT'; Source = 'DiskSnapshots'; Group = 'Region'; SeqOverall = 10
       Label = 'Disk Snapshot'
       Measure = { param($r) Measure-CVLooseSum $r 'StorageGB' }   # storageBytes / 1e9, honest decimal GB
       Fmt = { param($v) Format-CVSizeGBDecimal $v } }
)

# ---- entry points ---------------------------------------------------------------------------------------

function Get-CVGcpInventorySummary {
    <#
      .SYNOPSIS  Build every row of gcp_inventory_summary_<date>.csv.
      .PARAMETER Inventory  hashtable of collection name -> rows, e.g. @{ VMs = ...; StorageBuckets = ... }.
      .PARAMETER Selected   the -Types gate, keyed by the UPPERCASE resource-type names.
      .PARAMETER Projects   the projects actually processed; each needs a .Name holding the project id.
      .OUTPUTS   The summary rows, in file order.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Inventory,
        [Parameter(Mandatory)][hashtable]$Selected,
        $Projects = @()
    )

    Get-CVInventorySummary -Types $script:CVGcpSummaryTypes -Inventory $Inventory -Selected $Selected `
                           -Scopes $Projects -ScopeColumn 'Project' -ScopeProperty 'Project' `
                           -ScopeHeaderLabel '[ Project level Summary ]'
}

function Get-CVGcpVmZoneRollup {
    <#
      .SYNOPSIS  Per-zone VM rollup for gcp_vm_zone_rollup_<date>.csv - a pure CSV, one row per (project, zone).
      .DESCRIPTION Replaces the Zone tier that used to live inside gcp_inventory_summary. That tier grouped
                   ATTACHED DISK rows by Zone, and regional persistent disks are stamped Zone = '' by the
                   collector, so regional capacity fell out of every zone row and the zone rows summed to less
                   than their own region row.

                   This measures VM rows instead. VMDiskSizeGB is the per-VM sum of that VM's attachments,
                   regional ones included, so a regional disk is attributed to the zone of the VM using it and
                   nothing disappears. It also reconciles by construction with the VM row in the main summary,
                   which measures the same property.

                   Zone is whatever the VM row carries. Unattached disks are deliberately out of scope here -
                   they have no zone-owning VM, and they get their own row in the main summary.
      .OUTPUTS   Rows: Project, Region, Zone, VMCount, TotalSizeGB, TotalSizeTB, TotalSizeTiB.
    #>
    [CmdletBinding()]
    param($VMs = @())

    $rows = [System.Collections.Generic.List[psobject]]::new()
    $all  = @($VMs | Where-Object { $_ })
    if (-not $all.Count) { return $rows }

    foreach ($g in ($all | Group-Object Project, Region, Zone | Sort-Object Name)) {
        $first = $g.Group | Select-Object -First 1
        $sz = Format-CVSizeGBDecimal ([double](Measure-CVSum $g.Group 'VMDiskSizeGB'))
        $rows.Add([PSCustomObject]@{
            Project      = "$($first.Project)"
            Region       = "$($first.Region)"
            Zone         = "$($first.Zone)"
            VMCount      = $g.Count
            TotalSizeGB  = $sz.GB
            TotalSizeTB  = $sz.TB
            TotalSizeTiB = $sz.TiB
        })
    }
    return $rows
}
