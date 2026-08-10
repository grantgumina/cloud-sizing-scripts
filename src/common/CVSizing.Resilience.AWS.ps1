<#
    CVSizing.Resilience.AWS.ps1 - AWS-specific resilience control definitions.

    Consumed by CVAWSCloudSizingScript.ps1 and by the resilience tests. Provider-neutral scoring lives in
    CVSizing.Resilience.ps1; this file only supplies the AWS evaluators (Test blocks over inventory rows).

    Convention: a Test returns $true (Met) / $false (Gap) / $null (Unknown - signal not collected). Every field
    read here is one the AWS script already puts on the row, so no extra API calls are needed. Where a signal was
    not collected the Test must return $null so the control is excluded from the score rather than counted as a
    failure - an unread AWS Backup list is not evidence that a resource is unprotected.

    Clean Recovery controls are intentionally omitted, matching GCP/Azure: threat-scanning recovery points has no
    native AWS signal (it is a Commvault capability), so it is reported as "requires Commvault", not scored.
#>

# Get-CVTri (tri-state helper) lives in the shared engine (CVSizing.Resilience.ps1).

function Get-CVAwsResilienceControls {
    <# .OUTPUTS  hashtable: ResourceType -> [CVControl[]] #>
    [CmdletBinding()] param()

    # EC2. AWSBackupProtected is $false only when the region's protected-resource list was actually read; the
    # script leaves ProtectionStatus = 'Unknown' when it could not be, which is what makes the Unknown branch real.
    $ec2 = @(
        New-CVControl -Id 'ec2-backup'    -Title 'Enrolled in an AWS Backup plan'              -Category RecoveryReady -Severity High     -Test {
            param($r)
            if ($r.ProtectionStatus -eq 'Unknown') { return $null }
            Get-CVTri $r.AWSBackupProtected
        }
        New-CVControl -Id 'ec2-snapshots' -Title 'EBS snapshots exist for attached volumes'    -Category RecoveryReady -Severity High     -Test {
            param($r)
            if ($null -eq $r.EBSSnapshotCount) { return $null }
            [bool]([int]$r.EBSSnapshotCount -gt 0)
        }
        New-CVControl -Id 'ec2-recent'    -Title 'Most recent recovery point < 7 days old'     -Category RecoveryReady -Severity High     -Test {
            param($r)
            if ($null -eq $r.DaysSinceLastBackup) { return $null }
            [bool]([int]$r.DaysSinceLastBackup -le 7)
        }
        New-CVControl -Id 'ec2-encrypted' -Title 'All attached EBS volumes encrypted'          -Category DataExposure  -Severity High     -Test { param($r) Get-CVTri $r.AllVolumesEncrypted }
        New-CVControl -Id 'ec2-vaultlock' -Title 'Backups held in a locked (immutable) vault'  -Category Immutability   -Severity High     -Test { param($r) Get-CVTri $r.BackupVaultLocked }
    )

    # EBS volumes tracked independently of an instance (includes unattached).
    $ebs = @(
        New-CVControl -Id 'ebs-encrypted' -Title 'Volume encrypted at rest'                    -Category DataExposure  -Severity High     -Test { param($r) Get-CVTri $r.Encrypted }
    )

    # RDS / Aurora / DocumentDB share these field names.
    $rds = @(
        New-CVControl -Id 'rds-backup'    -Title 'Automated backups enabled'                   -Category RecoveryReady -Severity Critical -Test { param($r) Get-CVTri $r.AutomatedBackupsEnabled }
        New-CVControl -Id 'rds-retention' -Title 'Backup retention >= 35 days'                 -Category RecoveryReady -Severity High     -Test {
            param($r)
            if ($null -eq $r.BackupRetentionDays) { return $null }
            [bool]([int]$r.BackupRetentionDays -ge 35)
        }
        New-CVControl -Id 'rds-pitr'      -Title 'Point-in-time recovery enabled'              -Category RecoveryReady -Severity High     -Test { param($r) Get-CVTri $r.PITREnabled }
        New-CVControl -Id 'rds-vault'     -Title 'Also covered by an AWS Backup plan'          -Category RecoveryReady -Severity Medium   -Test { param($r) Get-CVTri $r.AWSBackupProtected }
        New-CVControl -Id 'rds-multiaz'   -Title 'Multi-AZ deployment'                         -Category Availability  -Severity High     -Test { param($r) Get-CVTri $r.MultiAZ }
        New-CVControl -Id 'rds-encrypted' -Title 'Storage encrypted at rest'                   -Category DataExposure  -Severity High     -Test { param($r) Get-CVTri $r.StorageEncrypted }
        New-CVControl -Id 'rds-delprot'   -Title 'Deletion protection enabled'                 -Category Immutability  -Severity High     -Test { param($r) Get-CVTri $r.DeletionProtection }
        New-CVControl -Id 'rds-vaultlock' -Title 'Backups held in a locked (immutable) vault'  -Category Immutability  -Severity High     -Test { param($r) Get-CVTri $r.BackupVaultLocked }
    )

    $s3 = @(
        New-CVControl -Id 's3-versioning' -Title 'Object versioning enabled'                   -Category Immutability  -Severity High     -Test {
            param($r)
            if (-not $r.VersioningStatus) { return $null }
            [bool]("$($r.VersioningStatus)" -eq 'Enabled')
        }
        New-CVControl -Id 's3-xregion'    -Title 'Cross-region replication configured'         -Category Availability  -Severity High     -Test { param($r) Get-CVTri $r.ReplicationEnabled }
        New-CVControl -Id 's3-encrypted'  -Title 'Default server-side encryption enabled'      -Category DataExposure  -Severity High     -Test {
            param($r)
            if (-not $r.ServerSideEncryption) { return $null }
            [bool]("$($r.ServerSideEncryption)" -notin @('None','Disabled',''))
        }
        New-CVControl -Id 's3-public'     -Title 'Public access blocked'                       -Category DataExposure  -Severity Critical -Test { param($r) Get-CVTri $r.PublicAccessBlocked }
        New-CVControl -Id 's3-objectlock' -Title 'Object Lock (WORM) enabled'                  -Category Immutability  -Severity High     -Test { param($r) Get-CVTri $r.ObjectLockEnabled }
        New-CVControl -Id 's3-lifecycle'  -Title 'Lifecycle policy configured'                 -Category RecoveryReady -Severity Medium   -Test {
            param($r)
            if ($null -eq $r.LifecycleRuleCount) { return $null }
            [bool]([int]$r.LifecycleRuleCount -gt 0)
        }
    )

    $efs = @(
        New-CVControl -Id 'efs-backup'    -Title 'AWS Backup policy enabled'                   -Category RecoveryReady -Severity Critical -Test {
            param($r)
            if (-not $r.BackupPolicyStatus -or "$($r.BackupPolicyStatus)" -eq 'Unknown') { return $null }
            [bool]("$($r.BackupPolicyStatus)" -eq 'ENABLED')
        }
        New-CVControl -Id 'efs-encrypted' -Title 'Encrypted at rest'                           -Category DataExposure  -Severity Critical -Test { param($r) Get-CVTri $r.Encrypted }
    )

    $dynamodb = @(
        New-CVControl -Id 'ddb-pitr'      -Title 'Point-in-time recovery enabled'              -Category RecoveryReady -Severity Critical -Test { param($r) Get-CVTri $r.PITREnabled }
        New-CVControl -Id 'ddb-vault'     -Title 'Covered by an AWS Backup plan'               -Category RecoveryReady -Severity Medium   -Test { param($r) Get-CVTri $r.AWSBackupProtected }
        New-CVControl -Id 'ddb-vaultlock' -Title 'Backups held in a locked (immutable) vault'  -Category Immutability  -Severity High     -Test { param($r) Get-CVTri $r.BackupVaultLocked }
    )

    $redshift = @(
        New-CVControl -Id 'rs-encrypted'  -Title 'Cluster encrypted at rest'                   -Category DataExposure  -Severity High     -Test { param($r) Get-CVTri $r.Encrypted }
        New-CVControl -Id 'rs-retention'  -Title 'Automated snapshot retention >= 7 days'      -Category RecoveryReady -Severity High     -Test {
            param($r)
            # The Redshift row names this AutomatedSnapshotRetentionDays; this control was written against the
            # raw AWS API property name (…Period), which the row does not carry, so it never evaluated.
            if ($null -eq $r.AutomatedSnapshotRetentionDays) { return $null }
            [bool]([int]$r.AutomatedSnapshotRetentionDays -ge 7)
        }
    )

    return @{ EC2 = $ec2; EBS = $ebs; RDS = $rds; S3 = $s3; EFS = $efs; DynamoDB = $dynamodb; Redshift = $redshift }
}
