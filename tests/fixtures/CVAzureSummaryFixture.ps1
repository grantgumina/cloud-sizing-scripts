<#
    CVAzureSummaryFixture.ps1 - synthetic Azure inventory used to pin azure_inventory_summary_*.csv.

    Shared by the golden-file capture harness and tests/Invoke-CVAzureSummaryTests.ps1, so both feed the old and
    new summary builders IDENTICAL input. If these two drifted apart the byte-comparison would be meaningless.

    Deliberately exercises the cases where the eleven hand-written rollups differ from one another:
      - two subscriptions, and several regions per resource type
      - a type present in one subscription but absent from the other
      - a type with a $null size property (the rollups differ in how they coalesce that)
      - an elastic pool spanning two databases (Get-CVSqlDbSizeTotal must count the pool once)
      - a pooled database whose SizeBasis is Utilized (must NOT be de-duplicated)
      - Cosmos / MySQL / PostgreSQL, which group on Location where every other type groups on Region
      - AKS with PV/PVC counts, which are interpolated into the ResourceType label
      - one resource type entirely absent from the inventory (NetApp), to cover the .Count -eq 0 guards
#>

$SubA = 'Sub Alpha'
$SubB = 'Sub Beta'

# The subscription objects the per-subscription pass iterates.
$subs = @(
    [pscustomobject]@{ Name = $SubA; Id = '00000000-0000-0000-0000-00000000000a' }
    [pscustomobject]@{ Name = $SubB; Id = '00000000-0000-0000-0000-00000000000b' }
)

# Sizes are deliberately AWKWARD. The passes do not all round to the same precision - Cosmos GB is 2dp in the
# overall pass and 4dp in the regional pass, and VM publishes the RAW sum where others round - so round numbers
# would hide those differences and the golden file would stop being an oracle.
$VMs = @(
    [pscustomobject]@{ Subscription = $SubA; ResourceGroup = 'RG1'; VMName = 'vm-a1'; Region = 'eastus';  VMDiskSizeGB = 128.333 }
    [pscustomobject]@{ Subscription = $SubA; ResourceGroup = 'RG1'; VMName = 'vm-a2'; Region = 'eastus';  VMDiskSizeGB = 512.777 }
    [pscustomobject]@{ Subscription = $SubA; ResourceGroup = 'RG2'; VMName = 'vm-a3'; Region = 'westus2'; VMDiskSizeGB = 64 }
    # $null size: the rollups coalesce this differently from a 0, so it must be represented.
    [pscustomobject]@{ Subscription = $SubB; ResourceGroup = 'RG3'; VMName = 'vm-b1'; Region = 'westus2'; VMDiskSizeGB = $null }
    [pscustomobject]@{ Subscription = $SubB; ResourceGroup = 'RG3'; VMName = 'vm-b2'; Region = 'northeurope'; VMDiskSizeGB = 1024 }
)

$StorageAccounts = @(
    [pscustomobject]@{ Subscription = $SubA; StorageAccount = 'sa1'; Region = 'eastus';  UsedCapacityBytes = 1234567890; BlobCount = 120; UsedCapacityGB = 1.23 }
    [pscustomobject]@{ Subscription = $SubA; StorageAccount = 'sa2'; Region = 'westus2'; UsedCapacityBytes = 250000111;  BlobCount = 8;   UsedCapacityGB = 0.25 }
    [pscustomobject]@{ Subscription = $SubB; StorageAccount = 'sa3'; Region = 'eastus';  UsedCapacityBytes = $null;      BlobCount = $null; UsedCapacityGB = $null }
)

$FileShares = @(
    [pscustomobject]@{ Subscription = $SubA; Name = 'share1'; StorageAccount = 'sa1'; Region = 'eastus';  UsedCapacityBytes = 987654321 }
    [pscustomobject]@{ Subscription = $SubB; Name = 'share2'; StorageAccount = 'sa3'; Region = 'westus2'; UsedCapacityBytes = 100000777 }
)

# Present in SubA only. Populated so its arithmetic is pinned, and absent from SubB so the per-subscription
# zero guards are still exercised (SubB also has no PostgreSQL).
$NetAppVolumes = @(
    [pscustomobject]@{ Subscription = $SubA; Name = 'nav1'; Region = 'eastus';  UsedCapacityBytes = 5555555555 }
    [pscustomobject]@{ Subscription = $SubA; Name = 'nav2'; Region = 'westus2'; UsedCapacityBytes = $null }
)

$SqlInstancesInventory = @(
    [pscustomobject]@{ Subscription = $SubA; ManagedInstanceName = 'mi1'; Region = 'eastus'; StorageUsedGB = 40.5 }
    [pscustomobject]@{ Subscription = $SubB; ManagedInstanceName = 'mi2'; Region = 'westus2'; StorageUsedGB = $null }
)

$SqlDbInventory = @(
    [pscustomobject]@{ Subscription = $SubA; ResourceGroup = 'RG1'; Server = 'sql1'; Database = 'db1'
                       Region = 'eastus'; SizingGB = 12.5; MaxSizeGB = 250; IsPooled = $false; SizeBasis = 'Utilized'; ElasticPoolName = $null }
    # Two databases in ONE pool, provisioned basis: the pool's capacity must be counted once, not twice.
    [pscustomobject]@{ Subscription = $SubA; ResourceGroup = 'RG1'; Server = 'sql1'; Database = 'db2'
                       Region = 'eastus'; SizingGB = 500; MaxSizeGB = 500; IsPooled = $true; SizeBasis = 'ProvisionedMax'; ElasticPoolName = 'pool1' }
    [pscustomobject]@{ Subscription = $SubA; ResourceGroup = 'RG1'; Server = 'sql1'; Database = 'db3'
                       Region = 'eastus'; SizingGB = 500; MaxSizeGB = 500; IsPooled = $true; SizeBasis = 'ProvisionedMax'; ElasticPoolName = 'pool1' }
    # Pooled but measured: genuinely per-database, so this one must NOT be de-duplicated away.
    [pscustomobject]@{ Subscription = $SubB; ResourceGroup = 'RG3'; Server = 'sql2'; Database = 'db4'
                       Region = 'westus2'; SizingGB = 7.25; MaxSizeGB = 500; IsPooled = $true; SizeBasis = 'Utilized'; ElasticPoolName = 'pool2' }
)

# Cosmos groups on LOCATION, not Region, and accumulates raw DataUsage bytes in a foreach. The byte value below
# is chosen so /1e9 has more than four decimals (1.23456789), which is what exposes the 2dp-vs-4dp difference
# between the overall and regional passes. Note DataUsage = '' (empty string), not $null - the guard tests both.
$CosmosDBs = @(
    [pscustomobject]@{ Subscription = $SubA; Name = 'cos1'; Location = 'eastus'; DataUsage = 1234567890; DataUsageGB = 1.23; DatabaseCount = 2; ContainerCount = 5 }
    [pscustomobject]@{ Subscription = $SubB; Name = 'cos2'; Location = 'westus2'; DataUsage = ''; DataUsageGB = $null; DatabaseCount = 1; ContainerCount = 1 }
)

$MySQLServers = @(
    [pscustomobject]@{ Subscription = $SubA; Name = 'my1'; Location = 'eastus'; Region = 'eastus'; StorageUsedGB = 20.6667 }
    [pscustomobject]@{ Subscription = $SubB; Name = 'my2'; Location = 'westus2'; Region = 'westus2'; StorageUsedGB = $null }
)

# SubA only, so the per-subscription pass hits the "type absent from this subscription" path for SubB.
$PostgreSQLServers = @(
    [pscustomobject]@{ Subscription = $SubA; Name = 'pg1'; Location = 'eastus'; Region = 'eastus'; StorageUsedGB = 33.7519 }
)

# PV/PVC counts land inside the ResourceType label, so they must be non-trivial - and the overall pass spells it
# "Total PVs:" while the regional pass spells it "PVs:", a difference the golden must preserve.
$AKSClusters = @(
    [pscustomobject]@{ Subscription = $SubA; ClusterName = 'aks1'; Region = 'eastus'
                       PersistentVolumeCount = 3; PersistentVolumeClaimCount = 2; PersistentVolumeCapacityGB = 300.5001 }
    [pscustomobject]@{ Subscription = $SubB; ClusterName = 'aks2'; Region = 'westus2'
                       PersistentVolumeCount = $null; PersistentVolumeClaimCount = $null; PersistentVolumeCapacityGB = $null }
)

$BackupItems = @(
    [pscustomobject]@{ Subscription = $SubA; VaultName = 'v1'; ItemName = 'VM;iaasvmcontainerv2;RG1;vm-a1'; ProtectionState = 'Protected' }
    [pscustomobject]@{ Subscription = $SubB; VaultName = 'v2'; ItemName = 'VM;iaasvmcontainerv2;RG3;vm-b2'; ProtectionState = 'ProtectionStopped' }
)

$UnmanagedDiskItems = @(
    [pscustomobject]@{ Subscription = $SubA; DiskName = 'disk1'; Region = 'eastus'; DiskSizeGB = 64; AttachedToVM = 'Unattached' }
    [pscustomobject]@{ Subscription = $SubA; DiskName = 'disk2'; Region = 'eastus'; DiskSizeGB = 32; AttachedToVM = 'vm-a1' }
)

$AVSClusters = @(
    [pscustomobject]@{ Subscription = $SubB; PrivateCloudName = 'avs1'; Region = 'northeurope'; TotalHostCount = 6; ClusterCount = 2 }
)

# The canonical -Types map. The overall-totals pass iterates ITS keys (not $Selected's), so without this the
# whole pass emits nothing - which is how the first golden capture came out missing every overall row.
$ResourceTypeMap = @{
    "VM"             = "VMs"
    "STORAGE"        = "StorageAccounts"
    "FILESHARE"      = "FileShares"
    "NETAPP"         = "NetAppVolumes"
    "SQL"            = "SqlInventory"
    "COSMOS"         = "CosmosDBs"
    "AKS"            = "AKSClusters"
    "BACKUP"         = "BackupItems"
    "UNMANAGEDDISKS" = "UnmanagedDisks"
    "AVS"            = "AVSClusters"
}

# Every type selected, so no pass is skipped by the -Types gate.
$Selected = @{}
foreach ($k in $ResourceTypeMap.Keys) { $Selected[$k] = $true }
