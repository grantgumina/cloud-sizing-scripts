<#
    CVSizing.Resilience.Azure.ps1 - Azure-specific resilience control definitions.

    Same framework as GCP (shared engine in CVSizing.Resilience.ps1); Azure-tailored Test blocks over the enriched
    inventory rows. A Test returns $true (Met) / $false (Gap) / $null (Unknown - signal not collected).

    Many signals come straight from the inventory we already keep: VMs carry BackupEnabled; SQL DBs carry PITR_Days
    and long-term-retention; storage accounts and file shares carry the SKU (which encodes GRS geo-redundancy).
    Others (blob public-access / CMK / versioning / immutability / soft-delete, vault cross-region + immutability,
    Cosmos/AKS backup) are filled in by the Azure resilience pass via defensive Az cmdlet calls; where a field is
    absent the control is Unknown and excluded from the score.

    Clean Recovery (threat-scanned recovery points) is omitted - no native Azure signal (a Commvault capability).
#>

# Get-CVTri lives in the shared engine.

# Azure Storage/File SKU encodes geo-redundancy: *GRS / *RAGRS / *GZRS / *RAGZRS replicate cross-region; LRS/ZRS don't.
function Test-CVAzureGeoSku { param([string]$Sku) if ([string]::IsNullOrWhiteSpace($Sku)) { return $null } return [bool]($Sku -match 'GRS|GZRS') }

# Backup/redundancy fields report a word rather than a SKU: Local | Zone | Geo | GeoZone. Blank/absent must stay
# $null (Unknown) - "we did not read it" is not "it is local-only".
function Test-CVAzureGeoRedundancy { param([string]$Value) if ([string]::IsNullOrWhiteSpace($Value)) { return $null } return [bool]($Value -match 'Geo') }

#region ------------------------------------------------------------------ ARM path / scope utilities

# The suffix every resource-lock ARM id carries after the scope it applies to.
$script:CVLockMarker = '/providers/Microsoft.Authorization/locks/'

function Get-CVAzureLockScope {
    <#
      .SYNOPSIS  The ARM scope a lock applies to: its own ResourceId minus the trailing lock segment.
      .DESCRIPTION
        Index-based, deliberately NOT regex. Real lock names contain regex metacharacters - this one is live in a
        test tenant:
            Start-Stop-VM[pm01-log-analyt-External_AutoStop_Description
        Interpolating that into a -replace pattern throws "parsing ... Unterminated [] set", which would take out
        the whole lock pass for the subscription.
      .OUTPUTS  The scope string, or $null when the marker is absent - which the caller must treat as
                UNPARSEABLE (we cannot claim a complete picture), never as "no scope".
    #>
    [CmdletBinding()]
    param([string]$LockResourceId)
    if ([string]::IsNullOrWhiteSpace($LockResourceId)) { return $null }
    $i = $LockResourceId.LastIndexOf($script:CVLockMarker, [StringComparison]::OrdinalIgnoreCase)
    if ($i -lt 1) { return $null }
    return $LockResourceId.Substring(0, $i).TrimEnd('/')
}

function Test-CVArmScopeCovers {
    <#
      .SYNOPSIS  Does $Scope contain $ResourceId - as itself or as an ancestor?
      .DESCRIPTION
        Azure resource locks inherit DOWNWARD: a lock at subscription or resource-group scope protects everything
        beneath it. So the scope must be an ancestor-or-self of the resource. Three things a naive StartsWith
        gets wrong, all of them reachable:

          1. Segment boundary. '.../servers/sql1' is a raw prefix of '.../servers/sql10/databases/db', so without
             requiring the '/' every database of sql10 would inherit sql1's lock - a fabricated finding.
          2. Case. ARM returns 'resourceGroups' and 'resourcegroups' interchangeably (the same inconsistency
             Group-CVAzureSnapshotsByDisk already lowercases for), and resource names are case-insensitive.
          3. Direction. A lock defined on a CHILD yields a scope LONGER than the parent's id, so the parent is
             correctly not matched. Note Azure's real delete behaviour does cascade - deleting a server whose
             database is locked fails - which is why the export publishes the matched scope too and lets the
             backend decide, rather than collapsing it here.

        Also used to join backup instances and Azure Files backup items to the resource they protect.
    #>
    [CmdletBinding()]
    param([string]$Scope, [string]$ResourceId)
    if ([string]::IsNullOrWhiteSpace($Scope) -or [string]::IsNullOrWhiteSpace($ResourceId)) { return $false }
    $s = $Scope.TrimEnd('/')
    $r = $ResourceId.TrimEnd('/')
    if ($s.Equals($r, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $r.StartsWith($s + '/', [StringComparison]::OrdinalIgnoreCase)
}

function Test-CVAzureLockProtects {
    <#
      .SYNOPSIS  Tri-state read of a ResourceLockLevel value.
      .DESCRIPTION
        Both CanNotDelete and ReadOnly block deletion, so either counts. The value may be ';'-joined when locks
        at several scopes apply at once.

        The three cases must stay distinct, and this is why 'None' exists as a token rather than an empty string:
            ''             -> we did not read locks           -> $null (Unknown)
            'None'         -> we read them, nothing applies   -> $false (a measured gap)
            'CanNotDelete' -> protected                       -> $true
        Do NOT route this through Get-CVTri: [bool]'None' is $true.

        Caveat worth knowing: 'None' does not mean deletable. Deny assignments (Blueprints, managed applications)
        and Azure Policy DenyAction also block deletion and are not locks.
    #>
    [CmdletBinding()]
    param([string]$Level)
    if ([string]::IsNullOrWhiteSpace($Level)) { return $null }
    if ($Level -eq 'None') { return $false }
    return [bool]($Level -match 'CanNotDelete|ReadOnly')
}

function Resolve-CVAzureResourceLock {
    <#
      .SYNOPSIS  Which locks cover a resource, as raw values for the signals export.
      .PARAMETER Locks  The subscription's locks. $null means NOT COLLECTED; an empty array means we looked and
                        the subscription has none. That distinction is the whole point: it separates a blank
                        column from a measured 'None'.
      .OUTPUTS  pscustomobject { Level; Scope; Count }
                Level: ';'-joined distinct lock levels (CanNotDelete / ReadOnly), 'None' when measured-absent,
                       or $null when not collected. Multiple locks genuinely apply at once - a subscription
                       ReadOnly plus a resource-group CanNotDelete - and choosing between them is a judgement
                       this export exists to avoid.
    #>
    [CmdletBinding()]
    param($Locks, [string]$ResourceId)

    if ($null -eq $Locks)                             { return [pscustomobject]@{ Level = $null; Scope = $null; Count = $null } }
    if ([string]::IsNullOrWhiteSpace($ResourceId))    { return [pscustomobject]@{ Level = $null; Scope = $null; Count = $null } }

    $levels = [System.Collections.Generic.List[string]]::new()
    $scopes = [System.Collections.Generic.List[string]]::new()
    foreach ($l in @($Locks)) {
        if (-not $l) { continue }
        $scope = Get-CVAzureLockScope ([string]$l.ResourceId)
        if (-not $scope) { continue }   # unparseable; the caller degrades the whole subscription to Unknown
        if (-not (Test-CVArmScopeCovers -Scope $scope -ResourceId $ResourceId)) { continue }
        $lvl = "$($l.Properties.level)"
        if ([string]::IsNullOrWhiteSpace($lvl)) { $lvl = "$($l.Level)" }   # shape varies by Az.Resources version
        if (-not [string]::IsNullOrWhiteSpace($lvl) -and -not $levels.Contains($lvl)) { $levels.Add($lvl) }
        $scopes.Add($scope)
    }

    if (-not $scopes.Count) { return [pscustomobject]@{ Level = 'None'; Scope = ''; Count = 0 } }
    return [pscustomobject]@{
        Level = (@($levels) | Sort-Object) -join ';'
        Scope = (@($scopes) | Sort-Object -Unique) -join ';'
        Count = $scopes.Count
    }
}

#endregion

function Resolve-CVAzureFlexServerCmk {
    <#
      .SYNOPSIS  Tri-state CMK verdict for a MySQL/PostgreSQL Flexible Server object.
      .DESCRIPTION
        Az.MySql / Az.PostgreSql expose data encryption differently across versions - flattened
        (DataEncryptionType) on some, nested (DataEncryption.Type) on others, and NOT AT ALL on others: the
        versions installed here surface no encryption property on the server model whatsoever.

        So this probes rather than assumes, and returns $null when no candidate property exists. That matters:
        a server whose module build cannot report encryption is Unknown, not "platform-key encrypted". Reporting
        $false there would be exactly the fabricated-gap failure this codebase keeps having to undo.
      .OUTPUTS  $true (CMK) | $false (service/system-managed) | $null (module does not expose it)
    #>
    [CmdletBinding()]
    param($Server)
    if (-not $Server) { return $null }

    # A key URI is only ever present for CMK, so finding one is conclusive.
    $uri = Get-CVFirstProperty -Resource $Server -Name @('DataEncryptionPrimaryKeyUri','DataEncryptionPrimaryKeyURI')
    if (-not $uri -and $Server.PSObject.Properties['DataEncryption']) {
        $uri = Get-CVFirstProperty -Resource $Server.DataEncryption -Name @('PrimaryKeyUri','PrimaryKeyURI','PrimaryUserAssignedIdentityId')
    }
    if ($uri) { return $true }

    $type = Get-CVFirstProperty -Resource $Server -Name @('DataEncryptionType')
    if (-not $type -and $Server.PSObject.Properties['DataEncryption']) {
        $type = Get-CVFirstProperty -Resource $Server.DataEncryption -Name @('Type')
    }
    if ([string]::IsNullOrWhiteSpace("$type")) { return $null }   # property absent -> Unknown, never a gap
    return [bool]("$type" -match 'KeyVault|Customer')
}

function Get-CVAzureResilienceControls {
    <# .OUTPUTS  hashtable: ResourceType -> [CVControl[]] #>
    [CmdletBinding()] param()

    <#
        NEVER Get-CVTri ON AN ENUM SIGNAL. Get-CVTri is [bool]$Value, and in PowerShell every non-empty string is
        truthy - so Get-CVTri 'Disabled' is $true, as is 'Unlocked' and 'None'. These vault signals are raw Azure
        enum strings, so passing them through Get-CVTri would publish "immutability Disabled means immutable" as
        the specification the backend implements. Production never executes these Test blocks, so no test would
        catch it; tests/Invoke-CVResilienceAzureTests.ps1 asserts the outcomes explicitly for exactly that reason.
    #>
    $vm = @(
        New-CVControl -Id 'vm-backup'    -Title 'Enrolled in a managed backup plan (Recovery Services vault)' -Category RecoveryReady -Severity High -Test { param($r) Get-CVTri $r.BackupEnabled }
        New-CVControl -Id 'vm-xregion'   -Title 'Backup vault cross-region restore enabled' -Category Availability -Severity High -Test {
            param($r)
            # 'Enabled' | 'Disabled'. Blank means we never established the protecting vault - Unknown, not a gap.
            if ([string]::IsNullOrWhiteSpace("$($r.BackupCrossRegionRestore)")) { return $null }
            [bool]("$($r.BackupCrossRegionRestore)" -eq 'Enabled')
        }
        New-CVControl -Id 'vm-immutable' -Title 'Backup vault immutability LOCKED' -Category Immutability -Severity High -Test {
            param($r)
            # 'Disabled' | 'Unlocked' | 'Locked'. Only Locked is WORM: an Unlocked policy can simply be removed,
            # which is the same standard st-immutable applies to storage via ImmutabilityLocked.
            if ([string]::IsNullOrWhiteSpace("$($r.BackupImmutabilityState)")) { return $null }
            [bool]("$($r.BackupImmutabilityState)" -eq 'Locked')
        }
        New-CVControl -Id 'vm-vaultsoftdelete' -Title 'Backup vault soft delete enabled' -Category Immutability -Severity High -Test {
            param($r)
            # 'Enabled' | 'Disabled' | 'AlwaysON'. AlwaysON cannot be turned off, so it is the strongest state.
            if ([string]::IsNullOrWhiteSpace("$($r.BackupVaultSoftDeleteState)")) { return $null }
            [bool]("$($r.BackupVaultSoftDeleteState)" -match '^(Enabled|AlwaysON)$')
        }
        New-CVControl -Id 'vm-vaultmua' -Title 'Backup vault Multi-User Authorization enabled' -Category Immutability -Severity High -Test {
            param($r)
            # Requires a Resource Guard to approve destructive vault operations - the control that stops an
            # attacker with vault permissions from shortening retention and then deleting backups.
            if ([string]::IsNullOrWhiteSpace("$($r.BackupVaultMultiUserAuth)")) { return $null }
            [bool]("$($r.BackupVaultMultiUserAuth)" -match '^(Enabled|True)$')
        }
        New-CVControl -Id 'vm-vaultredundancy' -Title 'Backup vault storage is geo-redundant' -Category Availability -Severity High -Test {
            param($r)
            # 'GeoRedundant' | 'ZoneRedundant' | 'LocallyRedundant' - a word, not a SKU, so reuse the word test.
            Test-CVAzureGeoRedundancy "$($r.BackupVaultStorageRedundancy)"
        }
    )

    $disk = @(
        New-CVControl -Id 'disk-cmek'     -Title 'Encrypted with a customer-managed key'          -Category DataExposure   -Severity High -Test { param($r) Get-CVTri $r.CmkEncrypted }
    )

    $storage = @(
        New-CVControl -Id 'st-versioning' -Title 'Blob versioning enabled'                 -Category Immutability -Severity High -Test { param($r) Get-CVTri $r.BlobVersioning }
        New-CVControl -Id 'st-xregion'    -Title 'Geo-redundant storage (GRS/RA-GRS)'       -Category Availability -Severity High -Test { param($r) Test-CVAzureGeoSku $r.StorageAccountSkuName }
        New-CVControl -Id 'st-cmek'       -Title 'Encrypted with a customer-managed key'    -Category DataExposure -Severity High -Test { param($r) Get-CVTri $r.CmkEncrypted }
        New-CVControl -Id 'st-immutable'  -Title 'Immutable storage policy (locked)'        -Category Immutability -Severity High -Test { param($r) Get-CVTri $r.ImmutabilityLocked }
        New-CVControl -Id 'st-public'     -Title 'Public blob access disabled'              -Category DataExposure -Severity High -Test { param($r) Get-CVTri $r.PublicAccessBlocked }
        New-CVControl -Id 'st-softdelete' -Title 'Blob soft delete enabled'                -Category Immutability -Severity High -Test { param($r) Get-CVTri $r.SoftDeleteEnabled }
    )

    # Azure SQL Database (PaaS). Automated backups are inherent; retention/PITR come from the inventory row.
    $sql = @(
        New-CVControl -Id 'db-backup'    -Title 'Automated backups enabled' -Category RecoveryReady -Severity High -Test { param($r) if ($null -eq $r.PITR_Days) { $null } else { $true } }
        New-CVControl -Id 'db-retention' -Title 'Backup retention >= 35 days' -Category RecoveryReady -Severity High -Test {
            param($r)
            $ltrCombined = ("$($r.LTRWeeklyRetention)$($r.LTRMonthlyRetention)$($r.LTRYearlyRetention)")
            $ltrSet = ($ltrCombined -and $ltrCombined -notmatch '^(|PT0S|P0.*)$')
            $pitrKnown = -not [string]::IsNullOrWhiteSpace("$($r.PITR_Days)")
            $pitrLong  = ($pitrKnown -and [int]$r.PITR_Days -ge 35)

            # Long enough PITR alone settles it, whatever LTR says.
            if ($pitrLong -or $ltrSet) { return $true }
            # Otherwise we need to have actually READ the LTR policy before concluding "too short". The read is
            # -ErrorAction SilentlyContinue, so an RBAC denial yields empty retention fields indistinguishable
            # from "no LTR configured" - and this control then reported a gap about data it never saw. The
            # inventory now records LtrDataStatus so that case becomes Unknown instead.
            if ("$($r.LtrDataStatus)" -and "$($r.LtrDataStatus)" -ne 'Ok') { return $null }
            if (-not $pitrKnown) { return $null }
            return $false
        }
        New-CVControl -Id 'db-pitr'    -Title 'Point-in-time recovery enabled'      -Category RecoveryReady -Severity High -Test { param($r) if ($null -eq $r.PITR_Days) { $null } else { [bool]([int]$r.PITR_Days -gt 0) } }
        New-CVControl -Id 'db-xregion' -Title 'Geo-redundant backup storage'        -Category Availability   -Severity High -Test {
            param($r)
            # BackupStorageRedundancy (Local|Zone|Geo|GeoZone) is collected on the SQL DB row. This previously read
            # a GeoRedundant field that nothing ever set, so the control never evaluated. Retitled because it
            # measures backup storage redundancy, not the presence of a geo-replica.
            Test-CVAzureGeoRedundancy "$($r.BackupStorageRedundancy)"
        }
        New-CVControl -Id 'db-cmek'    -Title 'TDE with a customer-managed key'      -Category DataExposure   -Severity High -Test { param($r) Get-CVTri $r.CmkEncrypted }
        New-CVControl -Id 'db-delprot' -Title 'Deletion protection (resource lock)'  -Category Immutability    -Severity High -Test { param($r) Test-CVAzureLockProtects "$($r.ResourceLockLevel)" }
        New-CVControl -Id 'db-ltrimmutable' -Title 'Long-term retention backups immutable' -Category Immutability -Severity High -Test {
            param($r)
            # LTR time-based immutability, from the same policy object the retention fields come from.
            if ([string]::IsNullOrWhiteSpace("$($r.LTRTimeBasedImmutability)")) { return $null }
            [bool]("$($r.LTRTimeBasedImmutability)" -match '^(Enabled|True|Locked)$')
        }
    )

    # MySQL / PostgreSQL Flexible Server.
    $flexdb = @(
        New-CVControl -Id 'fx-retention' -Title 'Backup retention >= 35 days'        -Category RecoveryReady -Severity High -Test { param($r) if ($null -eq $r.BackupRetentionDays) { $null } else { [bool]([int]$r.BackupRetentionDays -ge 35) } }
        New-CVControl -Id 'fx-xregion'   -Title 'Geo-redundant backup'               -Category Availability   -Severity High -Test {
            param($r)
            # GeoRedundantBackup is now collected on the MySQL/PostgreSQL rows ('Enabled' | 'Disabled'). This read
            # a GeoRedundant field that nothing set.
            if ([string]::IsNullOrWhiteSpace("$($r.GeoRedundantBackup)")) { return $null }
            [bool]("$($r.GeoRedundantBackup)" -match '^(Enabled|True)$')
        }
        New-CVControl -Id 'fx-cmek'      -Title 'Encrypted with a customer-managed key' -Category DataExposure -Severity High -Test { param($r) Get-CVTri $r.CmkEncrypted }
    )

    # Cosmos DB (NoSQL / document).
    $cosmos = @(
        New-CVControl -Id 'cos-pitr'    -Title 'Continuous backup / PITR enabled'       -Category RecoveryReady -Severity Critical -Test {
            param($r)
            # Reads BackupPolicyBackupType ('Periodic' | 'Continuous'), which is what the inventory collects.
            # It previously read a ContinuousBackup field that nothing ever set, so this never evaluated.
            if ([string]::IsNullOrWhiteSpace("$($r.BackupPolicyBackupType)")) { return $null }
            [bool]("$($r.BackupPolicyBackupType)" -match 'Continuous')
        }
        New-CVControl -Id 'cos-xregion' -Title 'Geo-redundant backup storage'           -Category Availability   -Severity High     -Test {
            param($r)
            # Retitled from 'Geo-redundant / multi-region': BackupPolicyBackupStorageRedundancy is what we collect,
            # and it describes BACKUP storage, not the account's read-region topology. Continuous-backup accounts
            # legitimately report nothing here, which stays Unknown rather than a gap.
            Test-CVAzureGeoRedundancy "$($r.BackupPolicyBackupStorageRedundancy)"
        }
        New-CVControl -Id 'cos-cmek'    -Title 'Encrypted with a customer-managed key'  -Category DataExposure   -Severity Critical -Test { param($r) Get-CVTri $r.CmkEncrypted }
        New-CVControl -Id 'cos-delprot' -Title 'Deletion protection (resource lock)'    -Category Immutability   -Severity High     -Test { param($r) Test-CVAzureLockProtects "$($r.ResourceLockLevel)" }
    )

    $fileshare = @(
        New-CVControl -Id 'fs-backup'    -Title 'Enrolled in a backup plan (share snapshots)' -Category RecoveryReady -Severity Critical -Test { param($r) Get-CVTri $r.HasBackup }
        New-CVControl -Id 'fs-xregion'   -Title 'Geo-redundant storage (GRS/RA-GRS)'          -Category Availability   -Severity High     -Test { param($r) Test-CVAzureGeoSku $r.StorageAccountSkuName }
        New-CVControl -Id 'fs-encrypted' -Title 'Encrypted at rest'                           -Category DataExposure   -Severity Critical -Test { param($r) Get-CVTri $r.EncryptedAtRest }
    )

    $aks = @(
        New-CVControl -Id 'aks-backup'    -Title 'Cluster enrolled in Backup for AKS (DataProtection backup vault)' -Category RecoveryReady -Severity Critical -Test { param($r) Get-CVTri $r.HasBackupPlan }
        # Retitled: AKS ALWAYS encrypts etcd with a platform-managed key, so $false here means "no customer-managed
        # key", not "secrets are unencrypted". The old title oversold the gap.
        New-CVControl -Id 'aks-secretenc' -Title 'etcd secrets encrypted with a customer-managed key (KMS)' -Category DataExposure -Severity High -Test { param($r) Get-CVTri $r.SecretsEncryptionCmk }
        New-CVControl -Id 'aks-diskcmek'  -Title 'Node disks encrypted with a customer-managed key' -Category DataExposure -Severity High -Test {
            param($r)
            # A disk-encryption-set id, or the token 'None' when the cluster uses platform keys. Blank = unread.
            if ([string]::IsNullOrWhiteSpace("$($r.NodeDiskEncryptionSetId)")) { return $null }
            [bool]("$($r.NodeDiskEncryptionSetId)" -ne 'None')
        }
    )

    return @{ VM=$vm; Disk=$disk; Storage=$storage; SQL=$sql; FlexDB=$flexdb; Cosmos=$cosmos; FileShare=$fileshare; AKS=$aks }
}
