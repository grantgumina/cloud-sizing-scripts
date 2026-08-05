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

function Get-CVAzureResilienceControls {
    <# .OUTPUTS  hashtable: ResourceType -> [CVControl[]] #>
    [CmdletBinding()] param()

    $vm = @(
        New-CVControl -Id 'vm-backup'    -Title 'Enrolled in a managed backup plan (Recovery Services vault)' -Category RecoveryReady -Severity High -Test { param($r) Get-CVTri $r.BackupEnabled }
        New-CVControl -Id 'vm-xregion'   -Title 'Backups copied to a secondary region'                        -Category Availability   -Severity High -Test { param($r) Get-CVTri $r.BackupCrossRegion }
        New-CVControl -Id 'vm-immutable' -Title 'Backup vault configured with immutability'                   -Category Immutability   -Severity High -Test { param($r) Get-CVTri $r.BackupImmutable }
    )

    $disk = @(
        New-CVControl -Id 'disk-schedule' -Title 'Automated snapshot/backup schedule configured' -Category RecoveryReady -Severity High -Test { param($r) Get-CVTri $r.HasBackupSchedule }
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
            $ltr = ("$($r.LTRWeeklyRetention)$($r.LTRMonthlyRetention)$($r.LTRYearlyRetention)")
            $ltrSet = ($ltr -and $ltr -notmatch '^(|PT0S|P0.*)$')
            if ($null -eq $r.PITR_Days -and -not $ltrSet) { return $null }
            [bool](([int]$r.PITR_Days -ge 35) -or $ltrSet)
        }
        New-CVControl -Id 'db-pitr'    -Title 'Point-in-time recovery enabled'      -Category RecoveryReady -Severity High -Test { param($r) if ($null -eq $r.PITR_Days) { $null } else { [bool]([int]$r.PITR_Days -gt 0) } }
        New-CVControl -Id 'db-xregion' -Title 'Geo-redundant backup / geo-replica'  -Category Availability   -Severity High -Test { param($r) Get-CVTri $r.GeoRedundant }
        New-CVControl -Id 'db-cmek'    -Title 'TDE with a customer-managed key'      -Category DataExposure   -Severity High -Test { param($r) Get-CVTri $r.CmkEncrypted }
        New-CVControl -Id 'db-delprot' -Title 'Deletion protection (resource lock)'  -Category Immutability    -Severity High -Test { param($r) Get-CVTri $r.DeletionProtected }
    )

    # MySQL / PostgreSQL Flexible Server.
    $flexdb = @(
        New-CVControl -Id 'fx-retention' -Title 'Backup retention >= 35 days'        -Category RecoveryReady -Severity High -Test { param($r) if ($null -eq $r.BackupRetentionDays) { $null } else { [bool]([int]$r.BackupRetentionDays -ge 35) } }
        New-CVControl -Id 'fx-xregion'   -Title 'Geo-redundant backup'               -Category Availability   -Severity High -Test { param($r) Get-CVTri $r.GeoRedundant }
        New-CVControl -Id 'fx-cmek'      -Title 'Encrypted with a customer-managed key' -Category DataExposure -Severity High -Test { param($r) Get-CVTri $r.CmkEncrypted }
    )

    # Cosmos DB (NoSQL / document).
    $cosmos = @(
        New-CVControl -Id 'cos-pitr'    -Title 'Continuous backup / PITR enabled'       -Category RecoveryReady -Severity Critical -Test { param($r) Get-CVTri $r.ContinuousBackup }
        New-CVControl -Id 'cos-xregion' -Title 'Geo-redundant / multi-region'           -Category Availability   -Severity High     -Test { param($r) Get-CVTri $r.GeoRedundant }
        New-CVControl -Id 'cos-cmek'    -Title 'Encrypted with a customer-managed key'  -Category DataExposure   -Severity Critical -Test { param($r) Get-CVTri $r.CmkEncrypted }
        New-CVControl -Id 'cos-delprot' -Title 'Deletion protection (resource lock)'    -Category Immutability   -Severity High     -Test { param($r) Get-CVTri $r.DeletionProtected }
    )

    $fileshare = @(
        New-CVControl -Id 'fs-backup'    -Title 'Enrolled in a backup plan (share snapshots)' -Category RecoveryReady -Severity Critical -Test { param($r) Get-CVTri $r.HasBackup }
        New-CVControl -Id 'fs-xregion'   -Title 'Geo-redundant storage (GRS/RA-GRS)'          -Category Availability   -Severity High     -Test { param($r) Test-CVAzureGeoSku $r.StorageAccountSkuName }
        New-CVControl -Id 'fs-encrypted' -Title 'Encrypted at rest'                           -Category DataExposure   -Severity Critical -Test { param($r) Get-CVTri $r.EncryptedAtRest }
    )

    $aks = @(
        New-CVControl -Id 'aks-backup'    -Title 'Persistent volumes enrolled in a backup plan' -Category RecoveryReady -Severity Critical -Test { param($r) Get-CVTri $r.HasBackupPlan }
        New-CVControl -Id 'aks-secretenc' -Title 'Secrets encrypted at rest (etcd/CMK)'         -Category DataExposure   -Severity High     -Test { param($r) Get-CVTri $r.SecretsEncryptionCmk }
    )

    return @{ VM=$vm; Disk=$disk; Storage=$storage; SQL=$sql; FlexDB=$flexdb; Cosmos=$cosmos; FileShare=$fileshare; AKS=$aks }
}
