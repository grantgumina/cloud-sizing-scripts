#requires -Version 7.2
<#
    Tests for Azure backup/snapshot attribution (src/common/CVSizing.Backup.Azure.ps1) and the collection-status
    guard (src/common/CVSizing.Resilience.ps1). No Az modules and no Azure credentials required.

    The cases here are the ones that produced a real false negative in the field: a VM with a backup policy and a
    job completed 10 minutes earlier was reported as unprotected, and the report scored it as a High-severity gap.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.Azure.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Backup.Azure.ps1')
. (Join-Path $PSScriptRoot 'CVTestControlEvaluator.ps1')   # control Tests are not executed in production

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }

# Realistic Azure name shapes. Verified against the documented forms for each workload.
function New-Item2 { param($Sub,$Wl,$Container,$ItemName,$State='Protected',$Status='Healthy',$Policy='DefaultPolicy',$Last,$Vault='vault1',
                          $Xregion,$Immutability,$SoftDelete,$Mua,$Redundancy,$Friendly,$SourceId)
    [pscustomobject]@{ Subscription=$Sub; WorkloadType=$Wl; ContainerName=$Container; ItemName=$ItemName
                       ProtectionState=$State; ProtectionStatus=$Status; PolicyName=$Policy
                       LastBackupStatus='Completed'; LastBackupTime=$Last; VaultName=$Vault
                       # Vault-level settings ride along on the item row - they describe the vault protecting it.
                       VaultCrossRegionRestore=$Xregion; VaultImmutabilityState=$Immutability
                       VaultSoftDeleteState=$SoftDelete; VaultMultiUserAuth=$Mua; VaultStorageRedundancy=$Redundancy
                       # Azure Files: the share name is FriendlyName; .Name/.ItemName is a hashed form.
                       FriendlyName=$Friendly; SourceResourceId=$SourceId } }
function New-Vm { param($Sub,$Rg,$Name) [pscustomobject]@{ Subscription=$Sub; ResourceGroup=$Rg; VMName=$Name } }
function New-Share { param($Sub,$Account,$Name,$Id) [pscustomobject]@{ Subscription=$Sub; StorageAccount=$Account; Name=$Name; ResourceId=$Id } }

Write-Host "`n[1] Name parsing across workload shapes"
$c = ConvertFrom-CVAzureBackupItemName 'iaasvmcontainerv2;RG-A;VM1'
Assert-CV 'AzureVM container -> name'  $c.Name 'VM1'
Assert-CV 'AzureVM container -> rg'    $c.ResourceGroup 'RG-A'
$c = ConvertFrom-CVAzureBackupItemName 'VM;iaasvmcontainerv2;RG-A;VM1'
Assert-CV 'AzureVM item -> name'       $c.Name 'VM1'
Assert-CV 'AzureVM item -> rg'         $c.ResourceGroup 'RG-A'
$c = ConvertFrom-CVAzureBackupItemName 'VMAppContainer;Compute;RG-A;VM1'
Assert-CV 'SQL-in-VM container -> host name' $c.Name 'VM1'
Assert-CV 'SQL-in-VM container -> rg'        $c.ResourceGroup 'RG-A'
$c = ConvertFrom-CVAzureBackupItemName 'StorageContainer;ClusterStorage;RG-B;sa1'
Assert-CV 'Azure Files container -> account' $c.Name 'sa1'
$c = ConvertFrom-CVAzureBackupItemName 'VM1'
Assert-CV 'bare friendly name -> name'    $c.Name 'VM1'
Assert-CV 'bare friendly name -> no rg'   $c.HasResourceGroup $false
$c = ConvertFrom-CVAzureBackupItemName 'iaasvmcontainerv2;RG-A;VM1;'
Assert-CV 'trailing semicolon tolerated'  $c.Name 'VM1'

Write-Host "`n[2] ProtectionState decides protection - ProtectionStatus is health, not enrolment"
Assert-CV 'Protected -> true'                     (Test-CVAzureBackupItemProtected ([pscustomobject]@{ProtectionState='Protected';ProtectionStatus='Healthy'})) $true
Assert-CV 'IRPending (first backup pending) -> true' (Test-CVAzureBackupItemProtected ([pscustomobject]@{ProtectionState='IRPending';ProtectionStatus='Healthy'})) $true
# The old code matched 'Healthy' against ProtectionState+ProtectionStatus concatenated, so this read as protected.
Assert-CV 'ProtectionStopped but Healthy -> false' (Test-CVAzureBackupItemProtected ([pscustomobject]@{ProtectionState='ProtectionStopped';ProtectionStatus='Healthy'})) $false
Assert-CV 'ProtectionError -> false'              (Test-CVAzureBackupItemProtected ([pscustomobject]@{ProtectionState='ProtectionError';ProtectionStatus='Unhealthy'})) $false

Write-Host "`n[3] Same VM name in two resource groups must NOT merge"
Reset-CVCollectionStatus
Set-CVCollectionStatus -Scope 'IT Prod' -Signal BACKUP   -Status Ok
Set-CVCollectionStatus -Scope 'IT Prod' -Signal SNAPSHOT -Status Ok
$items = @( New-Item2 -Sub 'IT Prod' -Wl AzureVM -Container 'iaasvmcontainerv2;RG-A;VM1' -ItemName 'VM;iaasvmcontainerv2;RG-A;VM1' )
$vms   = @( (New-Vm 'IT Prod' 'RG-A' 'VM1'), (New-Vm 'IT Prod' 'RG-B' 'VM1') )
$sum = Resolve-CVAzureBackupAttribution -BackupItems $items -VMs $vms -Status (Get-CVCollectionStatusMap)
Assert-CV 'RG-A VM1 protected'                  $vms[0].BackupEnabled $true
Assert-CV 'RG-B VM1 NOT protected (no inherit)' $vms[1].BackupEnabled $false
Assert-CV 'exactly one protected'               $sum.ProtectedCount 1

Write-Host "`n[4] A SQL-in-VM backup is not VM-level protection"
Reset-CVCollectionStatus
Set-CVCollectionStatus -Scope 'IT Prod' -Signal BACKUP -Status Ok
$items = @( New-Item2 -Sub 'IT Prod' -Wl MSSQL -Container 'VMAppContainer;Compute;RG-A;VM1' -ItemName 'MSSQL;RG-A;VM1;DB1' -Policy 'SqlPolicy' )
$vms   = @( (New-Vm 'IT Prod' 'RG-A' 'VM1') )
$null = Resolve-CVAzureBackupAttribution -BackupItems $items -VMs $vms -Status (Get-CVCollectionStatusMap)
Assert-CV 'MSSQL item does not set BackupEnabled' $vms[0].BackupEnabled $false
Assert-CV 'MSSQL item does not win the policy'    $vms[0].BackupPolicy ''
Assert-CV 'in-guest DB protection still visible'  $vms[0].DbBackupItemCount 1
Assert-CV 'DB workload recorded'                  $vms[0].DbBackupWorkloads 'MSSQL'

Write-Host "`n[5] The field failure: policy exists, lookup failed -> Unknown, not a gap"
Reset-CVCollectionStatus
Set-CVCollectionStatus -Scope 'IT Prod' -Signal BACKUP -Status Failed     # e.g. 403 on the vault, or bad param set
$vms = @( (New-Vm 'IT Prod' 'RG-A' 'Velocity-Azure-AccessNode') )
$sum = Resolve-CVAzureBackupAttribution -BackupItems @() -VMs $vms -Status (Get-CVCollectionStatusMap)
Assert-CV 'BackupEnabled is null (Unknown)'  ($null -eq $vms[0].BackupEnabled) $true
Assert-CV 'BackupCount is null (Unknown)'    ($null -eq $vms[0].BackupCount) $true
Assert-CV 'status recorded on the row'       $vms[0].BackupDataStatus 'Failed'
Assert-CV 'counted as unknown, not gap'      $sum.UnknownBackupCount 1
# ...and the resilience engine must therefore EXCLUDE it rather than score a High-severity gap.
$vmControls = (Get-CVAzureResilienceControls).VM
$ev = Invoke-CVResilience -Resource $vms[0] -Controls $vmControls
Assert-CV 'vm-backup outcome = Unknown'      (($ev.Results | Where-Object Id -eq 'vm-backup').Outcome) 'Unknown'
Assert-CV 'no gaps recorded'                 $ev.GapCount 0

Write-Host "`n[6] -Types without Backup is also Unknown, not 0% coverage"
Reset-CVCollectionStatus
Set-CVCollectionStatus -Scope 'IT Prod' -Signal BACKUP -Status Skipped
$vms = @( (New-Vm 'IT Prod' 'RG-A' 'VM1') )
$null = Resolve-CVAzureBackupAttribution -BackupItems @() -VMs $vms -Status (Get-CVCollectionStatusMap)
Assert-CV 'skipped -> BackupEnabled null'    ($null -eq $vms[0].BackupEnabled) $true
Assert-CV 'skipped -> status on row'         $vms[0].BackupDataStatus 'Skipped'

Write-Host "`n[7] Genuinely unprotected still reports a real gap"
Reset-CVCollectionStatus
Set-CVCollectionStatus -Scope 'IT Prod' -Signal BACKUP -Status Ok         # we DID look
$vms = @( (New-Vm 'IT Prod' 'RG-A' 'VM1') )
$null = Resolve-CVAzureBackupAttribution -BackupItems @() -VMs $vms -Status (Get-CVCollectionStatusMap)
Assert-CV 'looked and found none -> false'   $vms[0].BackupEnabled $false
$ev = Invoke-CVResilience -Resource $vms[0] -Controls $vmControls
Assert-CV 'vm-backup outcome = Gap'          (($ev.Results | Where-Object Id -eq 'vm-backup').Outcome) 'Gap'

Write-Host "`n[8] LastBackupTime is UTC and unambiguous"
Reset-CVCollectionStatus
Set-CVCollectionStatus -Scope 'IT Prod' -Signal BACKUP -Status Ok
$items = @( New-Item2 -Sub 'IT Prod' -Wl AzureVM -Container 'iaasvmcontainerv2;RG-A;VM1' -ItemName 'VM;iaasvmcontainerv2;RG-A;VM1' -Last '2026-08-06T06:18:00Z' )
$vms   = @( (New-Vm 'IT Prod' 'RG-A' 'VM1') )
$null = Resolve-CVAzureBackupAttribution -BackupItems $items -VMs $vms -Status (Get-CVCollectionStatusMap)
Assert-CV 'ISO-8601 UTC with Z' $vms[0].LastBackupTimeUtc '2026-08-06T06:18:00Z'

Write-Host "`n[9] A protected item wins over a stopped one for the same VM"
Reset-CVCollectionStatus
Set-CVCollectionStatus -Scope 'IT Prod' -Signal BACKUP -Status Ok
$items = @(
    New-Item2 -Sub 'IT Prod' -Wl AzureVM -Container 'iaasvmcontainerv2;RG-A;VM1' -ItemName 'VM;a;RG-A;VM1' -State 'ProtectionStopped' -Policy 'OldPolicy'
    New-Item2 -Sub 'IT Prod' -Wl AzureVM -Container 'iaasvmcontainerv2;RG-A;VM1' -ItemName 'VM;b;RG-A;VM1' -State 'Protected'         -Policy 'GoodPolicy'
)
$vms = @( (New-Vm 'IT Prod' 'RG-A' 'VM1') )
$null = Resolve-CVAzureBackupAttribution -BackupItems $items -VMs $vms -Status (Get-CVCollectionStatusMap)
Assert-CV 'protected wins'        $vms[0].BackupEnabled $true
Assert-CV 'protected policy wins' $vms[0].BackupPolicy 'GoodPolicy'

Write-Host "`n[10] Snapshot sizing: max source disk, not sum per snapshot"
Reset-CVCollectionStatus
Set-CVCollectionStatus -Scope 'IT Prod' -Signal SNAPSHOT -Status Ok
$diskId = '/subscriptions/s/resourceGroups/RG-A/providers/Microsoft.Compute/disks/VM1_OsDisk'
$snaps = 1..5 | ForEach-Object { [pscustomobject]@{ SourceDiskId=$diskId; SourceDiskSizeGB=1024; Incremental=$true; TimeCreated=(Get-Date) } }
$vms = @( (New-Vm 'IT Prod' 'RG-A' 'VM1') )
$map = @{ (Get-CVAzureBackupKey -Subscription 'IT Prod' -ResourceGroup 'RG-A' -Name 'VM1') = @($diskId) }
$null = Resolve-CVAzureBackupAttribution -BackupItems @() -VMs $vms -DiskIdMap $map -Snapshots $snaps -Status (Get-CVCollectionStatusMap)
Assert-CV 'all 5 snapshots counted'            $vms[0].SnapshotCount 5
Assert-CV '1TB disk reports ~1TB, not 5TB'     $vms[0].SnapshotSourceDiskTB 1.024
# ARM returns resourceGroups/resourcegroups inconsistently - the join must not care.
$map2 = @{ (Get-CVAzureBackupKey -Subscription 'IT Prod' -ResourceGroup 'RG-A' -Name 'VM1') = @($diskId.ToUpper()) }
$vms2 = @( (New-Vm 'IT Prod' 'RG-A' 'VM1') )
$null = Resolve-CVAzureBackupAttribution -BackupItems @() -VMs $vms2 -DiskIdMap $map2 -Snapshots $snaps -Status (Get-CVCollectionStatusMap)
Assert-CV 'disk-id join is case-insensitive'   $vms2[0].SnapshotCount 5

Write-Host "`n[11] Snapshot lookup failure -> Unknown, not zero snapshots"
Reset-CVCollectionStatus
Set-CVCollectionStatus -Scope 'IT Prod' -Signal SNAPSHOT -Status Failed
$vms = @( (New-Vm 'IT Prod' 'RG-A' 'VM1') )
$null = Resolve-CVAzureBackupAttribution -BackupItems @() -VMs $vms -Status (Get-CVCollectionStatusMap)
Assert-CV 'SnapshotsEnabled null' ($null -eq $vms[0].SnapshotsEnabled) $true
Assert-CV 'SnapshotCount null'    ($null -eq $vms[0].SnapshotCount) $true

Write-Host "`n[12] Collection status semantics"
Reset-CVCollectionStatus
Assert-CV 'unrecorded -> Skipped' (Get-CVCollectionStatus -Scope 'S' -Signal BACKUP) 'Skipped'
Set-CVCollectionStatus -Scope 'S' -Signal BACKUP -Status Ok
Set-CVCollectionStatus -Scope 'S' -Signal BACKUP -Status Failed
Assert-CV 'a later failure does not erase Ok' (Get-CVCollectionStatus -Scope 'S' -Signal BACKUP) 'Ok'
Assert-CV 'Resolve-CVSignal passes through when Ok' (Resolve-CVSignal -Scope 'S' -Signal BACKUP -Value 42) 42
Set-CVCollectionStatus -Scope 'T' -Signal BACKUP -Status Failed
Assert-CV 'Resolve-CVSignal nulls when Failed' ($null -eq (Resolve-CVSignal -Scope 'T' -Signal BACKUP -Value 42)) $true
# Subscription display names are mixed-case; the map must not care.
Reset-CVCollectionStatus
Set-CVCollectionStatus -Scope 'IT Prod' -Signal BACKUP -Status Ok
$m = Get-CVCollectionStatusMap
Assert-CV 'status map lookup is case-insensitive' $m['it prod'].BACKUP 'Ok'

Write-Host "`n[13] Vault settings follow the vault that ACTUALLY protects the VM"
<#
    VaultName used to be assigned first-wins, outside the protected-wins branch. A VM with a stale
    ProtectionStopped item in vault A and a live Protected item in vault B collides on one strict key, so the row
    named vault A while its policy came from vault B. That was cosmetic while VaultName was decorative. It stops
    being cosmetic the moment immutability and cross-region-restore hang off it: the row would assert vault A's
    posture for a VM that vault B protects.
#>
Reset-CVCollectionStatus
Set-CVCollectionStatus -Scope 'IT Prod' -Signal BACKUP -Status Ok
$items = @(
    # Stale item in vaultA, listed FIRST so first-wins would take it. Deliberately opposite settings.
    New-Item2 -Sub 'IT Prod' -Wl AzureVM -Container 'iaasvmcontainerv2;RG-A;VM1' -ItemName 'VM;iaasvmcontainerv2;RG-A;VM1' `
              -State 'ProtectionStopped' -Vault 'vaultA' -Xregion 'Disabled' -Immutability 'Disabled' -Redundancy 'LocallyRedundant'
    # The live one, in vaultB.
    New-Item2 -Sub 'IT Prod' -Wl AzureVM -Container 'iaasvmcontainerv2;RG-A;VM1' -ItemName 'VM;iaasvmcontainerv2;RG-A;VM1' `
              -State 'Protected' -Vault 'vaultB' -Xregion 'Enabled' -Immutability 'Locked' -Redundancy 'GeoRedundant'
)
$vms = @( (New-Vm 'IT Prod' 'RG-A' 'VM1') )
$null = Resolve-CVAzureBackupAttribution -BackupItems $items -VMs $vms -Status (Get-CVCollectionStatusMap)
Assert-CV 'protected item wins the vault'        $vms[0].BackupVaultName 'vaultB'
Assert-CV 'cross-region from the PROTECTING vault' $vms[0].BackupCrossRegionRestore 'Enabled'
Assert-CV 'immutability from the protecting vault' $vms[0].BackupImmutabilityState 'Locked'
Assert-CV 'redundancy from the protecting vault'   $vms[0].BackupVaultStorageRedundancy 'GeoRedundant'
Assert-CV 'and it is still reported protected'     $vms[0].BackupEnabled $true

# Raw enum strings are published verbatim - no collapsing to a boolean here.
Assert-CV 'immutability is a string, not a bool' ($vms[0].BackupImmutabilityState -is [string]) $true

# A VM we looked at but which has no backup item has no vault: inapplicable, so blank.
Reset-CVCollectionStatus
Set-CVCollectionStatus -Scope 'IT Prod' -Signal BACKUP -Status Ok
$vms = @( (New-Vm 'IT Prod' 'RG-A' 'Lonely') )
$null = Resolve-CVAzureBackupAttribution -BackupItems @() -VMs $vms -Status (Get-CVCollectionStatusMap)
Assert-CV 'unprotected VM: measured FALSE backup'  $vms[0].BackupEnabled $false
Assert-CV 'unprotected VM: vault signal blank'     ($null -eq $vms[0].BackupImmutabilityState) $true
Assert-CV 'and status says we DID look'            $vms[0].BackupDataStatus 'Ok'

# Never collected -> both the backup verdict and the vault signals stay blank.
Reset-CVCollectionStatus
$vms = @( (New-Vm 'IT Prod' 'RG-A' 'VM1') )
$null = Resolve-CVAzureBackupAttribution -BackupItems @() -VMs $vms -Status (Get-CVCollectionStatusMap)
Assert-CV 'not collected: BackupEnabled null'      ($null -eq $vms[0].BackupEnabled) $true
Assert-CV 'not collected: vault signal null'       ($null -eq $vms[0].BackupCrossRegionRestore) $true

Write-Host "`n[14] Azure Files backup attributed to the SHARE, not the storage account"
<#
    fs-backup reads $r.HasBackup, which nothing on the Azure side ever set - only the GCP script sets it, for
    Filestore, and the cross-cloud wiring detector hid that. The items were already collected (the backup pass
    queries AzureStorage/AzureFiles) and then folded into the account's DbItemCount and dropped.
#>
$acctId  = '/subscriptions/S1/resourceGroups/RG-B/providers/Microsoft.Storage/storageAccounts/sa1'
$shareId = "$acctId/fileServices/default/shares/share1"
Reset-CVCollectionStatus
Set-CVCollectionStatus -Scope 'IT Prod' -Signal BACKUP -Status Ok
$items = @(
    New-Item2 -Sub 'IT Prod' -Wl AzureFiles -Container 'StorageContainer;ClusterStorage;RG-B;sa1' `
              -ItemName 'AzureFileShare;abc123hash' -Friendly 'share1' -SourceId $acctId -Vault 'vaultFS' -Last '2026-08-11T02:00:00Z'
)
$grouped = Group-CVAzureBackupItems $items
$shares  = @( (New-Share 'IT Prod' 'sa1' 'share1' $shareId), (New-Share 'IT Prod' 'sa1' 'share2' "$acctId/fileServices/default/shares/share2") )
$sum = Resolve-CVAzureFileShareBackup -Grouped $grouped -FileShares $shares -Status (Get-CVCollectionStatusMap)
Assert-CV 'protected share -> HasBackup true'   $shares[0].HasBackup $true
Assert-CV 'protected share -> vault named'      $shares[0].ShareBackupVaultName 'vaultFS'
Assert-CV 'protected share -> UTC ISO-8601'     $shares[0].ShareLastBackupTimeUtc '2026-08-11T02:00:00Z'
Assert-CV 'unbacked share in same account -> FALSE' $shares[1].HasBackup $false
Assert-CV 'summary counts one protected'        $sum.ProtectedCount 1

# The share name alone must not carry across storage accounts.
$otherShare = @( (New-Share 'IT Prod' 'sa2' 'share1' '/subscriptions/S1/resourceGroups/RG-B/providers/Microsoft.Storage/storageAccounts/sa2/fileServices/default/shares/share1') )
$null = Resolve-CVAzureFileShareBackup -Grouped $grouped -FileShares $otherShare -Status (Get-CVCollectionStatusMap)
Assert-CV 'same share name, different account -> FALSE' $otherShare[0].HasBackup $false

# A stopped share backup is enrolment we cannot count on.
$stopped = Group-CVAzureBackupItems @(
    New-Item2 -Sub 'IT Prod' -Wl AzureFiles -Container 'StorageContainer;ClusterStorage;RG-B;sa1' `
              -ItemName 'AzureFileShare;h' -Friendly 'share1' -SourceId $acctId -State 'ProtectionStopped' )
$sh = @( (New-Share 'IT Prod' 'sa1' 'share1' $shareId) )
$null = Resolve-CVAzureFileShareBackup -Grouped $stopped -FileShares $sh -Status (Get-CVCollectionStatusMap)
Assert-CV 'ProtectionStopped share -> FALSE' $sh[0].HasBackup $false

# Not collected -> Unknown, never a fabricated "no backup".
Reset-CVCollectionStatus
$sh = @( (New-Share 'IT Prod' 'sa1' 'share1' $shareId) )
$null = Resolve-CVAzureFileShareBackup -Grouped $grouped -FileShares $sh -Status (Get-CVCollectionStatusMap)
Assert-CV 'backup not collected -> HasBackup null' ($null -eq $sh[0].HasBackup) $true
Assert-CV 'and the status is recorded'             $sh[0].BackupDataStatus 'Skipped'

# An AzureFiles item must still not set any VM's BackupEnabled.
Reset-CVCollectionStatus
Set-CVCollectionStatus -Scope 'IT Prod' -Signal BACKUP -Status Ok
$vms = @( (New-Vm 'IT Prod' 'RG-B' 'sa1') )   # a VM that happens to share the account's name
$null = Resolve-CVAzureBackupAttribution -BackupItems $items -VMs $vms -Status (Get-CVCollectionStatusMap)
Assert-CV 'AzureFiles item does not protect a VM' $vms[0].BackupEnabled $false

Write-Host ("`n======  {0} passed, {1} failed  ======`n" -f $script:Pass, $script:Fail) `
           -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
