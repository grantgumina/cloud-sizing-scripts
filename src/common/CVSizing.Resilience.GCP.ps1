<#
    CVSizing.Resilience.GCP.ps1 - GCP-specific resilience control definitions.

    Consumed by CVGoogleCloudSizingScript.ps1 and by the resilience tests. Provider-neutral scoring lives in
    CVSizing.Resilience.ps1; this file only supplies the GCP evaluators (Test blocks over enriched inventory rows).

    Convention: a Test returns $true (Met) / $false (Gap) / $null (Unknown - signal not collected). The GCP script
    enriches each row with the boolean/int posture fields these Tests read; where a field is absent, the Test
    returns $null and the control is excluded from the score (never counted as a failure).

    Clean Recovery controls are intentionally omitted for GCP: threat-scanning recovery points has no native GCP
    signal (it is a Commvault capability), so it is reported as "requires Commvault", not scored.
#>

# Get-CVTri (tri-state helper) lives in the shared engine (CVSizing.Resilience.ps1).

function Get-CVGcpResilienceControls {
    <# .OUTPUTS  hashtable: ResourceType -> [CVControl[]] #>
    [CmdletBinding()] param()

    $vm = @(
        New-CVControl -Id 'vm-backup'   -Title 'Enrolled in an automated snapshot/backup schedule' -Category RecoveryReady -Severity High   -Test { param($r) Get-CVTri $r.HasSnapshotSchedule }
        New-CVControl -Id 'vm-xregion'  -Title 'Backups copied to a secondary region'               -Category Availability   -Severity High   -Test { param($r) Get-CVTri $r.XRegionBackup }
        New-CVControl -Id 'vm-immutable' -Title 'Recovery points protected by immutability'          -Category Immutability   -Severity High   -Test { param($r) Get-CVTri $r.BackupImmutable }
        New-CVControl -Id 'vm-delprot'  -Title 'Instance deletion protection enabled'                -Category Immutability   -Severity High   -Test { param($r) Get-CVTri $r.DeletionProtection }
    )

    $disk = @(
        New-CVControl -Id 'pd-schedule' -Title 'Automated snapshot schedule configured'  -Category RecoveryReady -Severity High -Test { param($r) Get-CVTri $r.HasSnapshotSchedule }
        New-CVControl -Id 'pd-xregion'  -Title 'Snapshots copied to a secondary region'  -Category Availability   -Severity High -Test { param($r) Get-CVTri $r.XRegionBackup }
        New-CVControl -Id 'pd-cmek'     -Title 'Encrypted with a customer-managed key'    -Category DataExposure   -Severity High -Test { param($r) Get-CVTri $r.CmkEncrypted }
        New-CVControl -Id 'pd-nodelete' -Title 'Data disk survives VM deletion'           -Category Immutability   -Severity High -Test { param($r) Get-CVTri $r.SurvivesVmDelete }
    )

    $storage = @(
        New-CVControl -Id 'gcs-versioning' -Title 'Object versioning enabled'              -Category Immutability -Severity High -Test { param($r) Get-CVTri $r.Versioning }
        New-CVControl -Id 'gcs-xregion'    -Title 'Multi/dual-region redundancy'           -Category Availability -Severity High -Test { param($r) Get-CVTri $r.MultiRegion }
        New-CVControl -Id 'gcs-cmek'       -Title 'Encrypted with a customer-managed key'  -Category DataExposure -Severity High -Test { param($r) Get-CVTri $r.CmkEncrypted }
        New-CVControl -Id 'gcs-lock'       -Title 'Immutable (Bucket Lock retention)'      -Category Immutability -Severity High -Test { param($r) Get-CVTri $r.RetentionLocked }
        New-CVControl -Id 'gcs-public'     -Title 'Public access blocked'                  -Category DataExposure -Severity High -Test { param($r) Get-CVTri $r.PublicAccessBlocked }
        New-CVControl -Id 'gcs-softdelete' -Title 'Soft delete enabled'                    -Category Immutability -Severity High -Test { param($r) Get-CVTri $r.SoftDeleteEnabled }
    )

    $filestore = @(
        New-CVControl -Id 'fs-backup'   -Title 'Enrolled in a backup plan'      -Category RecoveryReady -Severity Critical -Test { param($r) Get-CVTri $r.HasBackup }
        New-CVControl -Id 'fs-xregion'  -Title 'Backups copied to a secondary region' -Category Availability -Severity High  -Test { param($r) Get-CVTri $r.BackupXRegion }
        New-CVControl -Id 'fs-encrypted' -Title 'Encrypted at rest'             -Category DataExposure  -Severity Critical -Test { param($r) Get-CVTri $r.EncryptedAtRest }
    )

    # Cloud SQL / AlloyDB (AlloyDB/Spanner rows lack most fields -> those controls score Unknown, excluded).
    $database = @(
        New-CVControl -Id 'db-backup'    -Title 'Automated backups enabled'          -Category RecoveryReady -Severity High -Test { param($r) Get-CVTri $r.BackupEnabled }
        New-CVControl -Id 'db-retention' -Title 'Backup retention >= 35 days'         -Category RecoveryReady -Severity High -Test {
            param($r)
            if ($null -eq $r.RetainedBackups -and $null -eq $r.TxLogRetentionDays) { return $null }
            [bool](([int]$r.RetainedBackups -ge 35) -or ([int]$r.TxLogRetentionDays -ge 35))
        }
        New-CVControl -Id 'db-pitr'      -Title 'Point-in-time recovery enabled'     -Category RecoveryReady -Severity High -Test { param($r) Get-CVTri $r.PitrEnabled }
        New-CVControl -Id 'db-xregion'   -Title 'Cross-region replica for DR'        -Category Availability   -Severity High -Test { param($r) Get-CVTri $r.HasReplica }
        New-CVControl -Id 'db-cmek'      -Title 'Encrypted with a customer-managed key' -Category DataExposure -Severity High -Test { param($r) Get-CVTri $r.CmkEncrypted }
        New-CVControl -Id 'db-delprot'   -Title 'Deletion protection enabled'        -Category Immutability   -Severity High -Test { param($r) Get-CVTri $r.DeletionProtection }
        New-CVControl -Id 'db-notpublic' -Title 'Not publicly exposed'               -Category DataExposure   -Severity High -Test {
            param($r)
            if ($null -eq $r.PublicIPs) { return $null }
            [string]::IsNullOrWhiteSpace([string]$r.PublicIPs)
        }
    )

    $gke = @(
        New-CVControl -Id 'gke-backup'    -Title 'Persistent volumes enrolled in a backup plan' -Category RecoveryReady -Severity Critical -Test { param($r) Get-CVTri $r.HasBackupPlan }
        New-CVControl -Id 'gke-xregion'   -Title 'Backups stored in a secondary region'         -Category Availability   -Severity High     -Test { param($r) Get-CVTri $r.BackupXRegion }
        New-CVControl -Id 'gke-secretenc' -Title 'Secrets encrypted at rest (CMEK)'              -Category DataExposure   -Severity High     -Test { param($r) Get-CVTri $r.SecretsEncryptionCmk }
    )

    return @{ VM = $vm; Disk = $disk; Storage = $storage; Filestore = $filestore; Database = $database; GKE = $gke }
}
