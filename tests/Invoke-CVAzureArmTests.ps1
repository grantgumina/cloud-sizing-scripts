#requires -Version 7.2
<#
    Tests for src/common/CVSizing.Arm.Azure.ps1 - the ARM REST layer that exists so backup signals can report a
    MEASURED zero without lying. No Az modules and no Azure credentials: every HTTP outcome is injected through
    the -Fetch scriptblock.

    The distinction under test, and the reason this file exists at all:
        HTTP 200 + empty value[]  -> we looked, there is none      -> safe to publish $false / 'None'
        HTTP 403 / anything else  -> we could not look             -> must publish blank
    A cmdlet returning an empty collection cannot tell these apart, which is how "0% backup coverage" gets
    asserted about a tenant nobody was allowed to read.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.Azure.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Arm.Azure.ps1')

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }

# A fake ARM. $Responses maps a URI substring -> @{ Code; Body }.
# Keys are matched LONGEST-FIRST. Hashtable enumeration order is not defined, and 'DataProtection/backupVaults'
# is a substring of '.../backupVaults/BV/backupInstances', so unordered matching made the vault-list response
# shadow the instance-list one at random - a bug in this fixture that looked like a bug in the code under test.
function New-Fetch {
    param([hashtable]$Responses, [ref]$Seen)
    return {
        param($uri)
        if ($Seen) { $Seen.Value += $uri }
        foreach ($k in ($Responses.Keys | Sort-Object -Property Length -Descending)) {
            if ($uri -like "*$k*") {
                $r = $Responses[$k]
                if ($r.Throw) { throw $r.Throw }
                return [pscustomobject]@{ StatusCode = $r.Code; Content = $r.Body }
            }
        }
        return [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"NotFound"}}' }
    }.GetNewClosure()
}

Write-Host "`n[1] Invoke-CVAzRestList - the status code IS the tri-state"
$ok = Invoke-CVAzRestList -Path '/subscriptions/S/providers/X/things' -ApiVersion '2024-04-01' `
        -Fetch (New-Fetch @{ 'things' = @{ Code = 200; Body = '{"value":[{"id":"/a"},{"id":"/b"}]}' } })
Assert-CV '200 with items -> Ok'      $ok.Ok $true
Assert-CV '200 with items -> count'   $ok.Items.Count 2

$empty = Invoke-CVAzRestList -Path '/subscriptions/S/providers/X/things' -ApiVersion '2024-04-01' `
        -Fetch (New-Fetch @{ 'things' = @{ Code = 200; Body = '{"value":[]}' } })
Assert-CV '200 with empty value[] -> Ok (measured zero)' $empty.Ok $true
Assert-CV 'and zero items'                              $empty.Items.Count 0

$denied = Invoke-CVAzRestList -Path '/subscriptions/S/providers/X/things' -ApiVersion '2024-04-01' `
        -Fetch (New-Fetch @{ 'things' = @{ Code = 403; Body = '{"error":{"message":"does not have authorization to perform action Microsoft.DataProtection/backupVaults/read"}}' } })
Assert-CV '403 -> NOT Ok'                    $denied.Ok $false
Assert-CV '403 -> zero items, not null'      $denied.Items.Count 0
Assert-CV '403 -> the missing permission is surfaced' ([bool]($denied.Error -match 'backupVaults/read')) $true

$thrown = Invoke-CVAzRestList -Path '/subscriptions/S/providers/X/things' -ApiVersion '2024-04-01' `
        -Fetch (New-Fetch @{ 'things' = @{ Throw = 'socket closed' } })
Assert-CV 'exception -> NOT Ok'  $thrown.Ok $false
Assert-CV 'exception message kept' ([bool]($thrown.Error -match 'socket closed')) $true

# A 200 whose body is not JSON must NOT read as a measured zero.
$garbage = Invoke-CVAzRestList -Path '/subscriptions/S/providers/X/things' -ApiVersion '2024-04-01' `
        -Fetch (New-Fetch @{ 'things' = @{ Code = 200; Body = 'not json at all {' } })
Assert-CV '200 with unparseable body -> NOT Ok' $garbage.Ok $false

# The api-version must be pinned onto the URI, since an ARM default drifting is a silent shape change.
$seen = @()
$null = Invoke-CVAzRestList -Path '/subscriptions/S/providers/X/things' -ApiVersion '2099-01-01' `
        -Fetch (New-Fetch -Responses @{ 'things' = @{ Code = 200; Body = '{"value":[]}' } } -Seen ([ref]$seen))
Assert-CV 'api-version appended' ([bool]($seen[0] -match 'api-version=2099-01-01')) $true
$seen = @()
$null = Invoke-CVAzRestList -Path '/subscriptions/S/things?$filter=x' -ApiVersion '2099-01-01' `
        -Fetch (New-Fetch -Responses @{ 'things' = @{ Code = 200; Body = '{"value":[]}' } } -Seen ([ref]$seen))
Assert-CV 'existing query string uses & not ?' ([bool]($seen[0] -match '\?\$filter=x&api-version=')) $true

Write-Host "`n[2] Get-CVAzureVaultSettingsMap - raw enum strings, keyed by vault id"
$vaultBody = @'
{"value":[{"id":"/subscriptions/S/resourceGroups/RG/providers/Microsoft.RecoveryServices/vaults/V1","name":"V1",
  "properties":{"redundancySettings":{"crossRegionRestore":"Enabled","standardTierStorageRedundancy":"GeoRedundant"},
  "securitySettings":{"immutabilitySettings":{"state":"Unlocked"},
  "softDeleteSettings":{"softDeleteState":"Enabled","softDeleteRetentionPeriodInDays":14},
  "multiUserAuthorization":"Enabled"}}}]}
'@
$vs = Get-CVAzureVaultSettingsMap -SubscriptionId 'S' -Fetch (New-Fetch @{ 'RecoveryServices/vaults' = @{ Code = 200; Body = $vaultBody } })
Assert-CV 'vault settings Ok' $vs.Ok $true
$key = '/subscriptions/s/resourcegroups/rg/providers/microsoft.recoveryservices/vaults/v1'
Assert-CV 'keyed by lowercased vault id' ([bool]$vs.Settings.ContainsKey($key)) $true
$s = $vs.Settings[$key]
Assert-CV 'crossRegionRestore verbatim'  $s.VaultCrossRegionRestore 'Enabled'
# 'Unlocked' must survive as itself: it is NOT WORM, and collapsing it to a boolean would lose that.
Assert-CV 'immutability Unlocked kept as-is' $s.VaultImmutabilityState 'Unlocked'
Assert-CV 'storage redundancy verbatim'  $s.VaultStorageRedundancy 'GeoRedundant'
Assert-CV 'soft delete state verbatim'   $s.VaultSoftDeleteState 'Enabled'
Assert-CV 'soft delete retention days'   $s.VaultSoftDeleteRetentionDays 14
Assert-CV 'multi-user auth verbatim'     $s.VaultMultiUserAuth 'Enabled'

$vsDenied = Get-CVAzureVaultSettingsMap -SubscriptionId 'S' -Fetch (New-Fetch @{ 'RecoveryServices/vaults' = @{ Code = 403; Body = '{}' } })
Assert-CV 'denied vault settings -> not Ok' $vsDenied.Ok $false
Assert-CV 'denied -> empty map, caller must blank the columns' $vsDenied.Settings.Count 0

Write-Host "`n[3] Get-CVAzureDataProtectionInstances - zero vaults is conclusive"
# The case that makes HasBackupPlan = FALSE honest rather than assumed.
$none = Get-CVAzureDataProtectionInstances -SubscriptionId 'S' -Fetch (New-Fetch @{ 'DataProtection/backupVaults' = @{ Code = 200; Body = '{"value":[]}' } })
Assert-CV '200 + zero backup vaults -> Ok' $none.Ok $true
Assert-CV 'vault count 0'                  $none.VaultCount 0
Assert-CV 'no instances'                   $none.Instances.Count 0

# Vaults exist and enumerate: real instances come back with their data-source id.
$dpVaults = '{"value":[{"id":"/subscriptions/S/resourceGroups/RG/providers/Microsoft.DataProtection/backupVaults/BV","name":"BV"}]}'
$dpInst = @'
{"value":[{"id":"/subscriptions/S/.../backupInstances/aks-inst",
  "properties":{"currentProtectionState":"ProtectionConfigured",
  "dataSourceInfo":{"resourceID":"/subscriptions/S/resourceGroups/RG/providers/Microsoft.ContainerService/managedClusters/aks1","datasourceType":"Microsoft.ContainerService/managedClusters"}}}]}
'@
$dp = Get-CVAzureDataProtectionInstances -SubscriptionId 'S' -Fetch (New-Fetch @{
        'DataProtection/backupVaults/BV/backupInstances' = @{ Code = 200; Body = $dpInst }
        'DataProtection/backupVaults'                    = @{ Code = 200; Body = $dpVaults } })
Assert-CV 'instances enumerated'  $dp.Ok $true
Assert-CV 'one instance'          $dp.Instances.Count 1
Assert-CV 'data source id kept'   $dp.Instances[0].DataSourceId '/subscriptions/S/resourceGroups/RG/providers/Microsoft.ContainerService/managedClusters/aks1'
Assert-CV 'vault name kept'       $dp.Instances[0].VaultName 'BV'
Assert-CV 'protection state kept' $dp.Instances[0].ProtectionState 'ProtectionConfigured'

# A vault we cannot read means the subscription's picture is incomplete - NOT "no clusters are backed up".
$partial = Get-CVAzureDataProtectionInstances -SubscriptionId 'S' -Fetch (New-Fetch @{
        'backupVaults/BV/backupInstances' = @{ Code = 403; Body = '{"error":{"message":"denied"}}' }
        'DataProtection/backupVaults'     = @{ Code = 200; Body = $dpVaults } })
Assert-CV 'unreadable vault -> whole subscription not Ok' $partial.Ok $false
Assert-CV 'and the vault is named in the error'           ([bool]($partial.Error -match "vault 'BV'")) $true

$dpDenied = Get-CVAzureDataProtectionInstances -SubscriptionId 'S' -Fetch (New-Fetch @{ 'DataProtection/backupVaults' = @{ Code = 403; Body = '{}' } })
Assert-CV 'denied at the vault list -> not Ok' $dpDenied.Ok $false
Assert-CV 'vault count unknown, not 0'         ($null -eq $dpDenied.VaultCount) $true

Write-Host "`n[4] Joining a backup instance to its cluster reuses the ARM scope predicate"
$clusterId = '/subscriptions/S/resourceGroups/RG/providers/Microsoft.ContainerService/managedClusters/aks1'
Assert-CV 'instance data-source matches the cluster' (Test-CVArmScopeCovers -Scope $dp.Instances[0].DataSourceId -ResourceId $clusterId) $true
# aks1 must not match aks10 - the same segment-boundary trap as resource locks.
Assert-CV 'aks1 does not match aks10' (Test-CVArmScopeCovers -Scope $dp.Instances[0].DataSourceId `
    -ResourceId '/subscriptions/S/resourceGroups/RG/providers/Microsoft.ContainerService/managedClusters/aks10') $false

Write-Host ("`n======  {0} passed, {1} failed  ======`n" -f $script:Pass, $script:Fail) `
           -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
