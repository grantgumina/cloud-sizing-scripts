<#
    CVSizing.Backup.Azure.ps1 - Attribution of Azure Backup items and managed-disk snapshots onto VM rows.

    Extracted from CVAzureCloudSizingScript.ps1 so it can be unit-tested with zero Azure access: every function
    here is pure, taking already-collected rows and returning/annotating objects. Tests live in
    tests/Invoke-CVAzureBackupTests.ps1.

    The rules this file exists to enforce:

      1. A protected VM must not be confused with a DIFFERENT VM of the same name in another resource group.
         Azure item/container names carry the resource group; the previous inline code parsed it out and threw it
         away, so `VM1` in RG-A and `VM1` in RG-B merged and an unprotected VM inherited its namesake's backup.

      2. A DATABASE backup running inside a VM is not VM-level protection. An MSSQL item's container is
         `VMAppContainer;Compute;<rg>;<vmName>`, so an unfiltered join set the HOST VM's BackupEnabled from a
         SQL-workload item - and could win the policy slot with the SQL policy.

      3. "Protection is configured" is ProtectionState, not health. ProtectionStatus is orthogonal: a machine whose
         protection has been STOPPED still reports Healthy, and the old test matched 'Healthy' against the
         concatenation of both fields, so stopped items read as protected.

      4. A signal we could not collect is $null (Unknown), never $false. See Set-CVCollectionStatus in
         CVSizing.Resilience.ps1 - $false is a scored Gap, so defaulting to it asserts "not backed up" about
         resources that were never successfully queried.
#>

# Azure reports protection as configured for these ProtectionStates. 'IRPending' = first (initial replication)
# backup has not completed yet, which is still enrolled. Anything else - ProtectionStopped, ProtectionError,
# ProtectionPaused, Invalid - is not protection we can count on.
$script:CVAzureProtectedStates = @('Protected', 'IRPending')

function ConvertFrom-CVAzureBackupItemName {
    <#
      .SYNOPSIS  Split an Azure Backup item/container name into its resource group and resource name.
      .DESCRIPTION Azure delimits these with ';' and always ends them `...;<resourceGroup>;<resourceName>`:
                     iaasvmcontainerv2;RG-A;VM1                (AzureVM container)
                     VM;iaasvmcontainerv2;RG-A;VM1             (AzureVM item)
                     VMAppContainer;Compute;RG-A;VM1           (SQL-in-VM container)
                     StorageContainer;ClusterStorage;RG-B;sa1  (Azure Files container)
                   Taking the last two segments is therefore shape-agnostic across workloads. A single-segment
                   value is a bare friendly name, which yields no resource group.
      .OUTPUTS   pscustomobject { Name; ResourceGroup; HasResourceGroup; Segments }
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Name)

    $segments = @(([string]$Name) -split ';' | ForEach-Object { $_.Trim() })
    # A trailing ';' yields an empty final segment - drop empties from the tail so [-1] is the real name.
    while ($segments.Count -gt 0 -and [string]::IsNullOrWhiteSpace($segments[-1])) {
        $segments = @($segments[0..($segments.Count - 2)])
    }
    if ($segments.Count -eq 0) {
        return [pscustomobject]@{ Name = $null; ResourceGroup = $null; HasResourceGroup = $false; Segments = @() }
    }
    $leaf = $segments[-1]
    $rg   = if ($segments.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($segments[-2])) { $segments[-2] } else { $null }
    return [pscustomobject]@{
        Name             = $leaf
        ResourceGroup    = $rg
        HasResourceGroup = [bool]$rg
        Segments         = $segments
    }
}

function Test-CVAzureBackupItemProtected {
    <# .SYNOPSIS  Is protection actually configured for this item? ProtectionState only - health is separate. #>
    [CmdletBinding()]
    param([Parameter(Position = 0)]$Item)
    if (-not $Item) { return $false }
    return [bool]("$($Item.ProtectionState)" -in $script:CVAzureProtectedStates)
}

function Get-CVAzureBackupKey {
    <# .SYNOPSIS  Join key for a protected resource. Strict = subscription|resourceGroup|name. #>
    [CmdletBinding()]
    param([string]$Subscription, [string]$ResourceGroup, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
    if ([string]::IsNullOrWhiteSpace($ResourceGroup)) { return "$Subscription||$Name".ToLower() }
    return "$Subscription|$ResourceGroup|$Name".ToLower()
}

function Group-CVAzureBackupItems {
    <#
      .SYNOPSIS  Fold raw backup items into per-resource aggregates, split by VM-level vs in-guest DB workloads.
      .OUTPUTS   hashtable: strict-or-loose key -> aggregate. Loose keys (no resource group) are kept separately
                 under a `Loose` map so callers can detect and report ambiguity rather than silently guessing.
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)]$BackupItems)

    $strict = @{}   # sub|rg|name  -> aggregate
    $loose  = @{}   # sub||name    -> aggregate (item name carried no resource group)

    foreach ($b in @($BackupItems)) {
        if (-not $b) { continue }

        # The CONTAINER identifies the protected machine/account; the item can be a child (a single database).
        $source = if ($b.ContainerName) { $b.ContainerName } else { $b.ItemName }
        $parsed = ConvertFrom-CVAzureBackupItemName $source
        if (-not $parsed.Name) { continue }

        $isVmLevel = ("$($b.WorkloadType)" -eq 'AzureVM')
        $key = Get-CVAzureBackupKey -Subscription $b.Subscription -ResourceGroup $parsed.ResourceGroup -Name $parsed.Name
        if (-not $key) { continue }
        $bucket = if ($parsed.HasResourceGroup) { $strict } else { $loose }

        if (-not $bucket.ContainsKey($key)) {
            $bucket[$key] = [pscustomobject]@{
                Subscription     = $b.Subscription
                ResourceGroup    = $parsed.ResourceGroup
                Name             = $parsed.Name
                VmItemCount      = 0
                VmProtected      = $false
                VmPolicy         = ''
                VmProtectionState  = ''
                VmProtectionStatus = ''
                VmLastBackupStatus = ''
                LatestBackupUtc  = $null
                VaultName        = ''
                DbItemCount      = 0
                DbWorkloads      = @()
            }
        }
        $agg = $bucket[$key]

        if ($isVmLevel) {
            $agg.VmItemCount++
            if (-not $agg.VaultName -and $b.VaultName) { $agg.VaultName = [string]$b.VaultName }
            if (Test-CVAzureBackupItemProtected $b) {
                $agg.VmProtected = $true
                # Prefer a protected item's policy/state over a stopped one's, rather than first-wins.
                $agg.VmPolicy           = [string]$b.PolicyName
                $agg.VmProtectionState  = [string]$b.ProtectionState
                $agg.VmProtectionStatus = [string]$b.ProtectionStatus
                $agg.VmLastBackupStatus = [string]$b.LastBackupStatus
            } elseif (-not $agg.VmProtected) {
                if (-not $agg.VmPolicy)           { $agg.VmPolicy           = [string]$b.PolicyName }
                if (-not $agg.VmProtectionState)  { $agg.VmProtectionState  = [string]$b.ProtectionState }
                if (-not $agg.VmProtectionStatus) { $agg.VmProtectionStatus = [string]$b.ProtectionStatus }
                if (-not $agg.VmLastBackupStatus) { $agg.VmLastBackupStatus = [string]$b.LastBackupStatus }
            }
            $t = [datetime]::MinValue
            if ($b.LastBackupTime -and [datetime]::TryParse([string]$b.LastBackupTime, [ref]$t)) {
                if ($null -eq $agg.LatestBackupUtc -or $t -gt $agg.LatestBackupUtc) { $agg.LatestBackupUtc = $t }
            }
        } else {
            # In-guest / PaaS workload sharing the container (SQL in VM, SAP HANA, Azure Files). Recorded so the
            # protection is visible, but it must NOT set VM-level BackupEnabled.
            $agg.DbItemCount++
            $wl = "$($b.WorkloadType)"
            if ($wl -and $agg.DbWorkloads -notcontains $wl) { $agg.DbWorkloads = @($agg.DbWorkloads) + $wl }
        }
    }

    return @{ Strict = $strict; Loose = $loose }
}

function Group-CVAzureSnapshotsByDisk {
    <#
      .SYNOPSIS  Aggregate managed-disk snapshots per source disk ARM ID.
      .DESCRIPTION Size is reported as the MAXIMUM source-disk size seen, not the sum. Azure exposes no
                   consumed-bytes property for incremental snapshots, so summing the source disk size once per
                   snapshot reported a 1 TB disk with five incrementals as 5 TB. One full copy is the honest
                   upper bound. ARM returns 'resourceGroups' and 'resourcegroups' inconsistently, so keys are
                   lowercased.
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)]$Snapshots)

    $byDisk = @{}
    foreach ($s in @($Snapshots)) {
        if (-not $s -or -not $s.SourceDiskId) { continue }
        $k = ([string]$s.SourceDiskId).ToLower()
        if (-not $byDisk.ContainsKey($k)) {
            $byDisk[$k] = [pscustomobject]@{ Count = 0; MaxSourceDiskGB = 0.0; Incremental = $null; LatestUtc = $null }
        }
        $e = $byDisk[$k]
        $e.Count++
        $gb = 0.0
        if ($null -ne $s.SourceDiskSizeGB) { $gb = [double]$s.SourceDiskSizeGB }
        elseif ($null -ne $s.DiskSizeGB)   { $gb = [double]$s.DiskSizeGB }   # older row shape
        if ($gb -gt $e.MaxSourceDiskGB) { $e.MaxSourceDiskGB = $gb }
        if ($null -ne $s.Incremental) { $e.Incremental = [bool]$s.Incremental }
        $t = [datetime]::MinValue
        if ($s.TimeCreated -and [datetime]::TryParse([string]$s.TimeCreated, [ref]$t)) {
            if ($null -eq $e.LatestUtc -or $t -gt $e.LatestUtc) { $e.LatestUtc = $t }
        }
    }
    return $byDisk
}

function Resolve-CVAzureBackupAttribution {
    <#
      .SYNOPSIS  Annotate VM rows with backup and snapshot coverage, honouring collection status.
      .DESCRIPTION Mutates each VM row in place (Add-Member -Force) and returns a summary. A subscription whose
                   BACKUP or SNAPSHOT collection did not complete leaves the corresponding fields $null (Unknown),
                   so the resilience engine excludes them instead of scoring a Gap we never verified.
      .PARAMETER Status  hashtable: subscription -> @{ BACKUP = 'Ok'|'Failed'|'Skipped'; SNAPSHOT = ... }.
                         A missing entry is treated as 'Skipped' (not collected).
      .OUTPUTS   pscustomobject { VmCount; ProtectedCount; UnknownBackupCount; AmbiguousCount; SnapshotVmCount }
    #>
    [CmdletBinding()]
    param(
        $BackupItems,
        $VMs,
        [hashtable]$DiskIdMap = @{},
        $Snapshots,
        [hashtable]$Status = @{}
    )

    $grouped  = Group-CVAzureBackupItems $BackupItems
    $snapByDisk = Group-CVAzureSnapshotsByDisk $Snapshots

    # Loose (no-resource-group) aggregates can only be matched by name. Count how many distinct VMs each such
    # name matches so a genuine ambiguity is reported rather than silently applied to all of them.
    $vmsByLooseKey = @{}
    foreach ($v in @($VMs)) {
        if (-not $v) { continue }
        $lk = Get-CVAzureBackupKey -Subscription $v.Subscription -ResourceGroup $null -Name $v.VMName
        if (-not $lk) { continue }
        if (-not $vmsByLooseKey.ContainsKey($lk)) { $vmsByLooseKey[$lk] = 0 }
        $vmsByLooseKey[$lk]++
    }

    $vmCount = 0; $protectedCount = 0; $unknownBackup = 0; $ambiguous = 0; $snapshotVms = 0

    foreach ($v in @($VMs)) {
        if (-not $v) { continue }
        $vmCount++
        $sub = "$($v.Subscription)"
        $backupStatus   = if ($Status.ContainsKey($sub) -and $Status[$sub].BACKUP)   { $Status[$sub].BACKUP }   else { 'Skipped' }
        $snapshotStatus = if ($Status.ContainsKey($sub) -and $Status[$sub].SNAPSHOT) { $Status[$sub].SNAPSHOT } else { 'Skipped' }

        # ---- Backup coverage -------------------------------------------------------------------------------
        if ($backupStatus -ne 'Ok') {
            # Never successfully queried -> Unknown, NOT "unprotected".
            $unknownBackup++
            Add-Member -InputObject $v -NotePropertyName BackupEnabled       -NotePropertyValue $null -Force
            Add-Member -InputObject $v -NotePropertyName BackupCount         -NotePropertyValue $null -Force
            Add-Member -InputObject $v -NotePropertyName BackupPolicy        -NotePropertyValue ''    -Force
            Add-Member -InputObject $v -NotePropertyName BackupProtectionState  -NotePropertyValue '' -Force
            Add-Member -InputObject $v -NotePropertyName BackupProtectionStatus -NotePropertyValue '' -Force
            Add-Member -InputObject $v -NotePropertyName LastBackupStatus    -NotePropertyValue ''    -Force
            Add-Member -InputObject $v -NotePropertyName LastBackupTimeUtc   -NotePropertyValue ''    -Force
            Add-Member -InputObject $v -NotePropertyName BackupVaultName     -NotePropertyValue ''    -Force
            Add-Member -InputObject $v -NotePropertyName DbBackupItemCount   -NotePropertyValue $null -Force
            Add-Member -InputObject $v -NotePropertyName DbBackupWorkloads   -NotePropertyValue ''    -Force
            Add-Member -InputObject $v -NotePropertyName BackupDataStatus    -NotePropertyValue $backupStatus -Force
            Add-Member -InputObject $v -NotePropertyName AmbiguousNameMatch  -NotePropertyValue $false -Force
        } else {
            $strictKey = Get-CVAzureBackupKey -Subscription $v.Subscription -ResourceGroup $v.ResourceGroup -Name $v.VMName
            $looseKey  = Get-CVAzureBackupKey -Subscription $v.Subscription -ResourceGroup $null            -Name $v.VMName
            $agg = $null; $isAmbiguous = $false
            if ($strictKey -and $grouped.Strict.ContainsKey($strictKey)) {
                $agg = $grouped.Strict[$strictKey]
            } elseif ($looseKey -and $grouped.Loose.ContainsKey($looseKey)) {
                # Only usable when exactly one VM in the subscription bears this name.
                $agg = $grouped.Loose[$looseKey]
                if (($vmsByLooseKey[$looseKey] | ForEach-Object { $_ }) -gt 1) { $isAmbiguous = $true; $ambiguous++ }
            }

            $protected = if ($agg) { [bool]$agg.VmProtected } else { $false }
            if ($protected) { $protectedCount++ }

            Add-Member -InputObject $v -NotePropertyName BackupEnabled       -NotePropertyValue $protected -Force
            Add-Member -InputObject $v -NotePropertyName BackupCount         -NotePropertyValue ([int]$(if ($agg) { $agg.VmItemCount } else { 0 })) -Force
            Add-Member -InputObject $v -NotePropertyName BackupPolicy        -NotePropertyValue ([string]$(if ($agg) { $agg.VmPolicy } else { '' })) -Force
            Add-Member -InputObject $v -NotePropertyName BackupProtectionState  -NotePropertyValue ([string]$(if ($agg) { $agg.VmProtectionState } else { '' })) -Force
            Add-Member -InputObject $v -NotePropertyName BackupProtectionStatus -NotePropertyValue ([string]$(if ($agg) { $agg.VmProtectionStatus } else { '' })) -Force
            Add-Member -InputObject $v -NotePropertyName LastBackupStatus    -NotePropertyValue ([string]$(if ($agg) { $agg.VmLastBackupStatus } else { '' })) -Force
            Add-Member -InputObject $v -NotePropertyName BackupVaultName     -NotePropertyValue ([string]$(if ($agg) { $agg.VaultName } else { '' })) -Force
            Add-Member -InputObject $v -NotePropertyName DbBackupItemCount   -NotePropertyValue ([int]$(if ($agg) { $agg.DbItemCount } else { 0 })) -Force
            Add-Member -InputObject $v -NotePropertyName DbBackupWorkloads   -NotePropertyValue ($(if ($agg) { @($agg.DbWorkloads) -join ';' } else { '' })) -Force
            Add-Member -InputObject $v -NotePropertyName BackupDataStatus    -NotePropertyValue 'Ok' -Force
            Add-Member -InputObject $v -NotePropertyName AmbiguousNameMatch  -NotePropertyValue $isAmbiguous -Force

            # UTC, ISO-8601. The source is UTC and the old 'yyyy-MM-dd HH:mm' form carried no zone, so a
            # 10-minute-old backup read as an unexplained offset.
            $lastUtc = if ($agg -and $agg.LatestBackupUtc) { $agg.LatestBackupUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { '' }
            Add-Member -InputObject $v -NotePropertyName LastBackupTimeUtc -NotePropertyValue $lastUtc -Force
        }

        # ---- Snapshot coverage -----------------------------------------------------------------------------
        if ($snapshotStatus -ne 'Ok') {
            Add-Member -InputObject $v -NotePropertyName SnapshotsEnabled     -NotePropertyValue $null -Force
            Add-Member -InputObject $v -NotePropertyName SnapshotCount        -NotePropertyValue $null -Force
            Add-Member -InputObject $v -NotePropertyName SnapshotSourceDiskTB -NotePropertyValue $null -Force
            Add-Member -InputObject $v -NotePropertyName SnapshotDataStatus   -NotePropertyValue $snapshotStatus -Force
        } else {
            $vmKey = Get-CVAzureBackupKey -Subscription $v.Subscription -ResourceGroup $v.ResourceGroup -Name $v.VMName
            $count = 0; $maxGb = 0.0
            foreach ($id in @($DiskIdMap[$vmKey])) {
                if (-not $id) { continue }
                $e = $snapByDisk[([string]$id).ToLower()]
                if ($e) { $count += $e.Count; $maxGb += $e.MaxSourceDiskGB }
            }
            if ($count -gt 0) { $snapshotVms++ }
            Add-Member -InputObject $v -NotePropertyName SnapshotsEnabled     -NotePropertyValue ($count -gt 0) -Force
            Add-Member -InputObject $v -NotePropertyName SnapshotCount        -NotePropertyValue $count -Force
            Add-Member -InputObject $v -NotePropertyName SnapshotSourceDiskTB -NotePropertyValue ([math]::Round($maxGb / 1000, 4)) -Force
            Add-Member -InputObject $v -NotePropertyName SnapshotDataStatus   -NotePropertyValue 'Ok' -Force
        }
    }

    # Deprecated aliases so a spreadsheet built against the previous column names keeps working for one release.
    # SnapshotSizeTB carried a materially different (inflated) number, so it is aliased to the corrected value
    # rather than preserved - a column that silently kept overstating capacity would be worse than a rename.
    foreach ($v in @($VMs)) {
        if (-not $v) { continue }
        Add-Member -InputObject $v -NotePropertyName SnapshotSizeTB -NotePropertyValue $v.SnapshotSourceDiskTB -Force
        Add-Member -InputObject $v -NotePropertyName LastBackupTime -NotePropertyValue $v.LastBackupTimeUtc    -Force
    }

    return [pscustomobject]@{
        VmCount            = $vmCount
        ProtectedCount     = $protectedCount
        UnknownBackupCount = $unknownBackup
        AmbiguousCount     = $ambiguous
        SnapshotVmCount    = $snapshotVms
    }
}
