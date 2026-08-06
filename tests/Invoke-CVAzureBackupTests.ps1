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

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }

# Realistic Azure name shapes. Verified against the documented forms for each workload.
function New-Item2 { param($Sub,$Wl,$Container,$ItemName,$State='Protected',$Status='Healthy',$Policy='DefaultPolicy',$Last,$Vault='vault1')
    [pscustomobject]@{ Subscription=$Sub; WorkloadType=$Wl; ContainerName=$Container; ItemName=$ItemName
                       ProtectionState=$State; ProtectionStatus=$Status; PolicyName=$Policy
                       LastBackupStatus='Completed'; LastBackupTime=$Last; VaultName=$Vault } }
function New-Vm { param($Sub,$Rg,$Name) [pscustomobject]@{ Subscription=$Sub; ResourceGroup=$Rg; VMName=$Name } }

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
Assert-CV 'no gaps recorded'                 (@($ev.Gaps).Count) 0

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

Write-Host ("`n======  {0} passed, {1} failed  ======`n" -f $script:Pass, $script:Fail) `
           -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
