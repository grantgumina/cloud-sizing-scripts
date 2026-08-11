#requires -Version 7.2
<#  Tests the Azure resilience control definitions against synthetic inventory rows. #>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.Azure.ps1')
. (Join-Path $PSScriptRoot 'CVTestControlEvaluator.ps1')

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }
$ctl = Get-CVAzureResilienceControls
function Outcome { param($ev,$id) (@($ev.Results | Where-Object Id -eq $id)[0]).Outcome }

Write-Host "`n[1] Geo-SKU detection"
Assert-CV 'Standard_GRS -> geo'    (Test-CVAzureGeoSku 'Standard_GRS')   $true
Assert-CV 'Standard_RAGRS -> geo'  (Test-CVAzureGeoSku 'Standard_RAGRS') $true
Assert-CV 'Standard_GZRS -> geo'   (Test-CVAzureGeoSku 'Standard_GZRS')  $true
Assert-CV 'Standard_LRS -> not geo' (Test-CVAzureGeoSku 'Standard_LRS')  $false
Assert-CV 'empty sku -> unknown'   ($null -eq (Test-CVAzureGeoSku ''))   $true

Write-Host "`n[2] VM - backup enabled from inventory, cross-region unknown"
$e = Invoke-CVResilience -Resource ([pscustomobject]@{ BackupEnabled=$true }) -Controls $ctl.VM
Assert-CV 'vm-backup Met'          (Outcome $e 'vm-backup') 'Met'
Assert-CV 'vm-xregion Unknown'     (Outcome $e 'vm-xregion') 'Unknown'

Write-Host "`n[3] Azure SQL - PITR/retention from inventory"
$sqlGood = [pscustomobject]@{ PITR_Days=35; LTRWeeklyRetention='P4W'; LTRMonthlyRetention=''; LTRYearlyRetention='' }
$e = Invoke-CVResilience -Resource $sqlGood -Controls $ctl.SQL
Assert-CV 'db-backup Met (SQL PaaS)'  (Outcome $e 'db-backup') 'Met'
Assert-CV 'db-pitr Met'               (Outcome $e 'db-pitr') 'Met'
Assert-CV 'db-retention Met (>=35)'   (Outcome $e 'db-retention') 'Met'
$sqlShort = [pscustomobject]@{ PITR_Days=7; LTRWeeklyRetention=''; LTRMonthlyRetention=''; LTRYearlyRetention='' }
Assert-CV 'db-retention Gap (7d, no LTR)' (Outcome (Invoke-CVResilience -Resource $sqlShort -Controls $ctl.SQL) 'db-retention') 'Gap'
$sqlLtr = [pscustomobject]@{ PITR_Days=7; LTRWeeklyRetention=''; LTRMonthlyRetention='P12M'; LTRYearlyRetention='' }
Assert-CV 'db-retention Met via LTR'  (Outcome (Invoke-CVResilience -Resource $sqlLtr -Controls $ctl.SQL) 'db-retention') 'Met'

Write-Host "`n[4] Storage - geo from SKU, enriched fields"
$st = [pscustomobject]@{ StorageAccountSkuName='Standard_LRS'; BlobVersioning=$true; PublicAccessBlocked=$true; CmkEncrypted=$false; SoftDeleteEnabled=$true }  # ImmutabilityLocked absent
$e = Invoke-CVResilience -Resource $st -Controls $ctl.Storage
Assert-CV 'st-xregion Gap (LRS)'      (Outcome $e 'st-xregion') 'Gap'
Assert-CV 'st-versioning Met'         (Outcome $e 'st-versioning') 'Met'
Assert-CV 'st-public Met'             (Outcome $e 'st-public') 'Met'
Assert-CV 'st-cmek Gap'               (Outcome $e 'st-cmek') 'Gap'
Assert-CV 'st-immutable Unknown'      (Outcome $e 'st-immutable') 'Unknown'

Write-Host "`n[5] FileShare - geo + encrypted"
$fs = [pscustomobject]@{ StorageAccountSkuName='Standard_RAGRS'; EncryptedAtRest=$true }  # HasBackup absent
$e = Invoke-CVResilience -Resource $fs -Controls $ctl.FileShare
Assert-CV 'fs-xregion Met'   (Outcome $e 'fs-xregion') 'Met'
Assert-CV 'fs-encrypted Met' (Outcome $e 'fs-encrypted') 'Met'
Assert-CV 'fs-backup Unknown' (Outcome $e 'fs-backup') 'Unknown'

Write-Host "`n[2b] Enum signals must NOT be read through Get-CVTri"
<#
    THIS IS THE GUARD FOR THE WORST BUG IN THIS AREA. Get-CVTri is [bool]$Value and every non-empty string is
    truthy in PowerShell, so Get-CVTri 'Disabled' is $true. The vault and lock signals are raw Azure enum strings.
    If any of these controls is ever "simplified" back to Get-CVTri, it publishes "Disabled means enabled" as the
    contract the backend implements - and because production never executes Test blocks, nothing else would fail.

    Each assertion below returns 'Met' under Get-CVTri and the correct value under an explicit comparison.
#>
Assert-CV 'Get-CVTri on a string is truthy (the trap)' (Get-CVTri 'Disabled') $true
# Demonstrate the consequence on a control, without touching the real ones: the naive implementation reports a
# vault with immutability DISABLED as fully immutable. This is what these assertions exist to prevent.
$naive = @(New-CVControl -Id 'naive-immutable' -Title 'naive' -Category Immutability -Severity High -Test { param($r) Get-CVTri $r.BackupImmutabilityState })
Assert-CV 'naive Get-CVTri control wrongly says Met for Disabled' `
    (Outcome (Invoke-CVResilience -Resource ([pscustomobject]@{ BackupImmutabilityState='Disabled' }) -Controls $naive) 'naive-immutable') 'Met'
Assert-CV 'the real control says Gap for the same input' `
    (Outcome (Invoke-CVResilience -Resource ([pscustomobject]@{ BackupImmutabilityState='Disabled' }) -Controls $ctl.VM) 'vm-immutable') 'Gap'

$O = { param($set,$id,$row) Outcome (Invoke-CVResilience -Resource $row -Controls $set) $id }
# vm-xregion: Enabled/Disabled
Assert-CV 'vm-xregion Enabled  -> Met'     (& $O $ctl.VM 'vm-xregion' ([pscustomobject]@{ BackupCrossRegionRestore='Enabled'  })) 'Met'
Assert-CV 'vm-xregion Disabled -> Gap'     (& $O $ctl.VM 'vm-xregion' ([pscustomobject]@{ BackupCrossRegionRestore='Disabled' })) 'Gap'
Assert-CV 'vm-xregion blank    -> Unknown' (& $O $ctl.VM 'vm-xregion' ([pscustomobject]@{ BackupCrossRegionRestore=''        })) 'Unknown'
# vm-immutable: only Locked is WORM. Unlocked must be a Gap, which is the subtlest of these.
Assert-CV 'vm-immutable Locked   -> Met'     (& $O $ctl.VM 'vm-immutable' ([pscustomobject]@{ BackupImmutabilityState='Locked'   })) 'Met'
Assert-CV 'vm-immutable Unlocked -> Gap'     (& $O $ctl.VM 'vm-immutable' ([pscustomobject]@{ BackupImmutabilityState='Unlocked' })) 'Gap'
Assert-CV 'vm-immutable Disabled -> Gap'     (& $O $ctl.VM 'vm-immutable' ([pscustomobject]@{ BackupImmutabilityState='Disabled' })) 'Gap'
Assert-CV 'vm-immutable blank    -> Unknown' (& $O $ctl.VM 'vm-immutable' ([pscustomobject]@{ BackupImmutabilityState=$null    })) 'Unknown'
# Vault soft delete / MUA / redundancy
Assert-CV 'vault softdelete AlwaysON -> Met' (& $O $ctl.VM 'vm-vaultsoftdelete' ([pscustomobject]@{ BackupVaultSoftDeleteState='AlwaysON' })) 'Met'
Assert-CV 'vault softdelete Disabled -> Gap' (& $O $ctl.VM 'vm-vaultsoftdelete' ([pscustomobject]@{ BackupVaultSoftDeleteState='Disabled' })) 'Gap'
Assert-CV 'vault MUA Disabled -> Gap'        (& $O $ctl.VM 'vm-vaultmua' ([pscustomobject]@{ BackupVaultMultiUserAuth='Disabled' })) 'Gap'
Assert-CV 'vault redundancy Local -> Gap'    (& $O $ctl.VM 'vm-vaultredundancy' ([pscustomobject]@{ BackupVaultStorageRedundancy='LocallyRedundant' })) 'Gap'
Assert-CV 'vault redundancy Geo   -> Met'    (& $O $ctl.VM 'vm-vaultredundancy' ([pscustomobject]@{ BackupVaultStorageRedundancy='GeoRedundant' })) 'Met'
# Deletion protection: 'None' is a MEASURED gap, blank is Unknown.
Assert-CV 'db-delprot CanNotDelete -> Met'   (& $O $ctl.SQL 'db-delprot' ([pscustomobject]@{ ResourceLockLevel='CanNotDelete' })) 'Met'
Assert-CV 'db-delprot ReadOnly     -> Met'   (& $O $ctl.SQL 'db-delprot' ([pscustomobject]@{ ResourceLockLevel='ReadOnly'     })) 'Met'
Assert-CV 'db-delprot joined levels-> Met'   (& $O $ctl.SQL 'db-delprot' ([pscustomobject]@{ ResourceLockLevel='CanNotDelete;ReadOnly' })) 'Met'
Assert-CV 'db-delprot None -> Gap (measured)' (& $O $ctl.SQL 'db-delprot' ([pscustomobject]@{ ResourceLockLevel='None' })) 'Gap'
Assert-CV 'db-delprot blank -> Unknown'      (& $O $ctl.SQL 'db-delprot' ([pscustomobject]@{ ResourceLockLevel='' })) 'Unknown'
Assert-CV 'cos-delprot None -> Gap'          (& $O $ctl.Cosmos 'cos-delprot' ([pscustomobject]@{ ResourceLockLevel='None' })) 'Gap'
# AKS node-disk CMK uses the same 'None' convention.
Assert-CV 'aks-diskcmek None -> Gap'         (& $O $ctl.AKS 'aks-diskcmek' ([pscustomobject]@{ NodeDiskEncryptionSetId='None' })) 'Gap'
Assert-CV 'aks-diskcmek des id -> Met'       (& $O $ctl.AKS 'aks-diskcmek' ([pscustomobject]@{ NodeDiskEncryptionSetId='/subscriptions/S/../diskEncryptionSets/des1' })) 'Met'
Assert-CV 'aks-diskcmek blank -> Unknown'    (& $O $ctl.AKS 'aks-diskcmek' ([pscustomobject]@{ NodeDiskEncryptionSetId='' })) 'Unknown'
# LTR immutability
Assert-CV 'db-ltrimmutable Enabled -> Met'   (& $O $ctl.SQL 'db-ltrimmutable' ([pscustomobject]@{ LTRTimeBasedImmutability='Enabled' })) 'Met'
Assert-CV 'db-ltrimmutable blank -> Unknown' (& $O $ctl.SQL 'db-ltrimmutable' ([pscustomobject]@{ LTRTimeBasedImmutability='' })) 'Unknown'

Write-Host "`n[2c] Test-CVAzureLockProtects - the three states stay distinct"
Assert-CV 'blank -> null (unread)'        ($null -eq (Test-CVAzureLockProtects '')) $true
Assert-CV 'whitespace -> null'            ($null -eq (Test-CVAzureLockProtects '  ')) $true
Assert-CV "'None' -> false (measured)"    (Test-CVAzureLockProtects 'None') $false
Assert-CV 'CanNotDelete -> true'          (Test-CVAzureLockProtects 'CanNotDelete') $true
Assert-CV 'ReadOnly -> true'              (Test-CVAzureLockProtects 'ReadOnly') $true
Assert-CV 'joined -> true'                (Test-CVAzureLockProtects 'CanNotDelete;ReadOnly') $true

Write-Host "`n[5a] ARM scope matching - locks inherit downward, and prefixes are not enough"
<#
    These are the PRIMARY evidence for the lock signal. The test tenant has 17 real locks but every one of them
    sits on an automation-account variable, so a live run can only exercise the negative path. Every trap below
    is reachable in a customer tenant and each would produce a FABRICATED finding, not merely a missing one.
#>
$subScope = '/subscriptions/S1'
$rgScope  = '/subscriptions/S1/resourceGroups/RG1'
$sqlDb    = '/subscriptions/S1/resourceGroups/RG1/providers/Microsoft.Sql/servers/sql1/databases/db1'

# Scope derivation strips the lock segment. Regex would throw on this real lock name.
$hardName = '/subscriptions/S1/resourceGroups/RG1/providers/Microsoft.Authorization/locks/Start-Stop-VM[pm01-log-analyt-External_AutoStop_Description'
Assert-CV 'lock scope derived from lock id'      (Get-CVAzureLockScope "$rgScope/providers/Microsoft.Authorization/locks/dontdelete") $rgScope
Assert-CV 'lock name with [ does not throw'     (Get-CVAzureLockScope $hardName) $rgScope
Assert-CV 'no lock marker -> null (unparseable)' ($null -eq (Get-CVAzureLockScope $rgScope)) $true
Assert-CV 'empty input -> null'                 ($null -eq (Get-CVAzureLockScope '')) $true

# Inheritance: ancestor scopes cover the resource; the resource covers itself.
Assert-CV 'subscription lock covers a database' (Test-CVArmScopeCovers -Scope $subScope -ResourceId $sqlDb) $true
Assert-CV 'resource-group lock covers it'       (Test-CVArmScopeCovers -Scope $rgScope  -ResourceId $sqlDb) $true
Assert-CV 'server lock covers its database'     (Test-CVArmScopeCovers -Scope '/subscriptions/S1/resourceGroups/RG1/providers/Microsoft.Sql/servers/sql1' -ResourceId $sqlDb) $true
Assert-CV 'self covers self'                    (Test-CVArmScopeCovers -Scope $sqlDb -ResourceId $sqlDb) $true

# The sibling-prefix trap: sql1 must NOT cover sql10's databases.
$sql10Db = '/subscriptions/S1/resourceGroups/RG1/providers/Microsoft.Sql/servers/sql10/databases/db1'
Assert-CV 'sql1 does NOT cover sql10 (segment boundary)' (Test-CVArmScopeCovers -Scope '/subscriptions/S1/resourceGroups/RG1/providers/Microsoft.Sql/servers/sql1' -ResourceId $sql10Db) $false
Assert-CV 'RG1 does NOT cover RG10'             (Test-CVArmScopeCovers -Scope $rgScope -ResourceId '/subscriptions/S1/resourceGroups/RG10/providers/Microsoft.Sql/servers/s/databases/d') $false

# Direction: a lock on a child must not mark the parent.
Assert-CV 'child lock does not cover parent'    (Test-CVArmScopeCovers -Scope $sqlDb -ResourceId '/subscriptions/S1/resourceGroups/RG1/providers/Microsoft.Sql/servers/sql1') $false

# Case: ARM is inconsistent about 'resourceGroups' and names are case-insensitive.
Assert-CV 'lowercase resourcegroups still matches' (Test-CVArmScopeCovers -Scope '/subscriptions/s1/resourcegroups/rg1' -ResourceId $sqlDb) $true
Assert-CV 'trailing slash tolerated'            (Test-CVArmScopeCovers -Scope "$rgScope/" -ResourceId $sqlDb) $true
Assert-CV 'blank scope never matches'           (Test-CVArmScopeCovers -Scope '' -ResourceId $sqlDb) $false

Write-Host "`n[5a2] Resolve-CVAzureResourceLock - measured 'None' vs unread blank"
function New-Lock { param($Scope, $Level) [pscustomobject]@{ ResourceId = "$Scope/providers/Microsoft.Authorization/locks/l$([guid]::Empty.ToString('N').Substring(0,4))"; Properties = [pscustomobject]@{ level = $Level } } }
# $null Locks = we never collected them. Must stay blank, NOT 'None'.
$r = Resolve-CVAzureResourceLock -Locks $null -ResourceId $sqlDb
Assert-CV 'not collected -> Level null' ($null -eq $r.Level) $true
Assert-CV 'not collected -> Count null' ($null -eq $r.Count) $true
# An empty array = we looked, subscription has no locks. That is a MEASURED absence.
$r = Resolve-CVAzureResourceLock -Locks @() -ResourceId $sqlDb
Assert-CV 'looked, none exist -> None' $r.Level 'None'
Assert-CV 'looked, none exist -> Count 0' $r.Count 0
# Locks exist but none cover this resource -> still a measured None.
$r = Resolve-CVAzureResourceLock -Locks @((New-Lock '/subscriptions/S1/resourceGroups/OTHER' 'CanNotDelete')) -ResourceId $sqlDb
Assert-CV 'non-covering lock -> None' $r.Level 'None'
# A covering ancestor lock.
$r = Resolve-CVAzureResourceLock -Locks @((New-Lock $rgScope 'CanNotDelete')) -ResourceId $sqlDb
Assert-CV 'RG lock -> CanNotDelete' $r.Level 'CanNotDelete'
Assert-CV 'RG lock -> scope reported' $r.Scope $rgScope
# Two locks at different scopes both apply; both levels are published rather than one being chosen.
$r = Resolve-CVAzureResourceLock -Locks @((New-Lock $subScope 'ReadOnly'), (New-Lock $rgScope 'CanNotDelete')) -ResourceId $sqlDb
Assert-CV 'two locks -> both levels, sorted' $r.Level 'CanNotDelete;ReadOnly'
Assert-CV 'two locks -> count 2' $r.Count 2
# A resource with no ARM id cannot be judged either way.
$r = Resolve-CVAzureResourceLock -Locks @() -ResourceId ''
Assert-CV 'no resource id -> null, not None' ($null -eq $r.Level) $true

Write-Host "`n[5b] Resolve-CVAzureFlexServerCmk - tri-state over inconsistent module shapes"
# Az.MySql / Az.PostgreSql surface data encryption differently per version, and the versions installed here
# surface it not at all. The resolver must probe, and must return $null (not $false) when nothing is exposed -
# reporting 'platform key' for a server we could not read is the fabricated-gap failure mode.
Assert-CV 'flattened AzureKeyVault -> true'   (Resolve-CVAzureFlexServerCmk -Server ([pscustomobject]@{ DataEncryptionType='AzureKeyVault' })) $true
Assert-CV 'flattened SystemManaged -> false'  (Resolve-CVAzureFlexServerCmk -Server ([pscustomobject]@{ DataEncryptionType='SystemManaged' })) $false
Assert-CV 'nested .Type AzureKeyVault -> true' (Resolve-CVAzureFlexServerCmk -Server ([pscustomobject]@{ DataEncryption=[pscustomobject]@{ Type='AzureKeyVault' } })) $true
Assert-CV 'nested .Type SystemManaged -> false' (Resolve-CVAzureFlexServerCmk -Server ([pscustomobject]@{ DataEncryption=[pscustomobject]@{ Type='SystemManaged' } })) $false
Assert-CV 'flattened key URI alone -> true'   (Resolve-CVAzureFlexServerCmk -Server ([pscustomobject]@{ DataEncryptionPrimaryKeyUri='https://kv.vault.azure.net/keys/k/1' })) $true
Assert-CV 'nested key URI alone -> true'      (Resolve-CVAzureFlexServerCmk -Server ([pscustomobject]@{ DataEncryption=[pscustomobject]@{ PrimaryKeyUri='https://kv.vault.azure.net/keys/k/1' } })) $true
# The cases that must stay Unknown:
Assert-CV 'no encryption property -> null'    ($null -eq (Resolve-CVAzureFlexServerCmk -Server ([pscustomobject]@{ Name='srv1'; StorageGB=128 }))) $true
Assert-CV 'empty type string -> null'         ($null -eq (Resolve-CVAzureFlexServerCmk -Server ([pscustomobject]@{ DataEncryptionType='' })))       $true
Assert-CV 'whitespace type -> null'           ($null -eq (Resolve-CVAzureFlexServerCmk -Server ([pscustomobject]@{ DataEncryptionType='   ' })))    $true
Assert-CV 'null server -> null'               ($null -eq (Resolve-CVAzureFlexServerCmk -Server $null))                                              $true
# And the control built on it agrees.
Assert-CV 'fx-cmek unreadable -> Unknown' (Outcome (Invoke-CVResilience -Resource ([pscustomobject]@{ CmkEncrypted=(Resolve-CVAzureFlexServerCmk -Server ([pscustomobject]@{ Name='srv1' })) }) -Controls $ctl.FlexDB) 'fx-cmek') 'Unknown'
Assert-CV 'fx-cmek CMK -> Met'            (Outcome (Invoke-CVResilience -Resource ([pscustomobject]@{ CmkEncrypted=(Resolve-CVAzureFlexServerCmk -Server ([pscustomobject]@{ DataEncryptionType='AzureKeyVault' })) }) -Controls $ctl.FlexDB) 'fx-cmek') 'Met'

Write-Host "`n[6] No Clean Recovery controls"
# The empty-environment score assertion that used to live here went with the scoring engine: an overall score is
# the backend's to compute, so this repo no longer has a contract to pin.
$cats = ($ctl.Values | ForEach-Object { $_ } | ForEach-Object { $_.Category }) | Sort-Object -Unique
Assert-CV 'no CleanRecovery for Azure' ($cats -contains 'CleanRecovery') $false

Write-Host ("`n{0}  {1} passed, {2} failed  {0}" -f ('=' * 6), $script:Pass, $script:Fail) -ForegroundColor ($script:Fail ? 'Red' : 'Green')
exit ($script:Fail -gt 0 ? 1 : 0)
