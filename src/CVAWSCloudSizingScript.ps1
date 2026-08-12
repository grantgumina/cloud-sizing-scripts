#requires -Version 7.2
# Windows PowerShell 5.1 is NOT supported: the shared console layer needs $PSStyle (7.2+), and this script uses
# the null-coalescing operator (??), which 5.1 cannot even parse. A #requires directive is evaluated BEFORE the
# script is parsed, so it fires ahead of the parse error that would otherwise be all a 5.1 user saw.
# Keep the blank line below - without it PowerShell stops treating the next block as comment-based help.

<#
.SYNOPSIS
    AWS Cloud Sizing Script – Comprehensive inventory and sizing analysis for compute, storage, and databases.

.DESCRIPTION
    Inventories AWS Services across one or multiple accounts and regions:
      - EC2 instances (with attached/unattached EBS volumes)
      - S3 buckets and storage metrics
      - Elastic File System (EFS)
      - FSx file systems (ONTAP/SVX, Windows, Lustre, etc.)
      - RDS database instances
      - DynamoDB tables
      - DocumentDB clusters
      - Redshift clusters
      - EKS Clusters and PVCs associated with the cluster

    The inventory includes provisioned size details for applicable services and used size for S3 along with other configuration and metadata information.

    Supports multiple authentication methods including:
      - Access/Secret Key authentication (via Creds.txt or ProfileLocation)
      - Default AWS CLI profile (IAM role assumed automatically in CloudShell/EC2)
      - Cross-account role assumption

    Generates one CSV per service covering every account in the run, plus a four-tier inventory rollup
    (overall, overall by region, per account, per account by region) - the same output shape the Azure and GCP
    scripts produce. There are no Excel workbooks and no ImportExcel dependency.

    Includes hierarchical progress tracking and detailed logging.
    Outputs timestamped CSVs and zips the whole run directory.

.PARAMETER DefaultProfile
    Use the default AWS CLI profile (IAM role) for authentication.
    Typically used when running inside AWS CloudShell or an EC2 instance.

.PARAMETER UserSpecifiedProfileNames
    Comma-separated list of AWS CLI profile names defined inside a credentials file (Creds.txt).

.PARAMETER AllLocalProfiles
    Use all profiles defined inside a credentials file.

.PARAMETER ProfileLocation
    Path to a shared credentials file (e.g., ./Creds.txt).
    Required for access/secret key authentication outside AWS (e.g., Laptop/Desktop).

.PARAMETER CrossAccountRoleName
    Name of the IAM role to assume for cross-account access.
    Must be executed from AWS environments (EC2/CloudShell) or with valid base IAM role.

.PARAMETER UserSpecifiedAccounts
    Comma-separated list of AWS account IDs to use with the specified cross-account role.

.PARAMETER UserSpecifiedAccountsFile
    Path to a file containing AWS account IDs (one per line) to use with the specified cross-account role.

.PARAMETER Regions
    Comma-separated list of AWS regions to query.

.PARAMETER ExternalId
    External ID required for cross-account role assumption (Optional).

.OUTPUTS
    Writes to the repository top level (or the current directory when run outside the repo):

    Output/aws_YYYY-MM-DD_HHMMSS/
        - aws_inventory_summary_YYYY-MM-DD_HHMMSS.csv
            – The rollup: overall totals, overall by region, then per account and per account by region.
              Columns: Account, ResourceType, Region, Count, TotalSizeGB, TotalSizeTB, TotalSizeTiB.
        - aws_<service>_info_YYYY-MM-DD_HHMMSS.csv
            – One file per service, one row per resource, EVERY account in the run. AwsAccountId and
              AwsAccountAlias identify the owner, so the files no longer carry an account name segment.
              Services: ec2_instance, ec2_unattached_volume, s3, efs, fsx, fsx_ontap_svms, rds, dynamodb,
              redshift, eks, documentdb, aurora, elasticache, backup_protected_resources.
        - aws_resilience_signals_YYYY-MM-DD_HHMMSS.csv   (unless -SkipResilienceReport)
            – Raw cyber-resilience signal values; the backend applies the thresholds. See
              CYBER_RESILIENCE_SIGNALS.md for the blank-means-not-collected rule.
        - aws_sizing_YYYY-MM-DD_HHMMSS.json        (only with -OutputFormat json|both)
    Output/aws_YYYY-MM-DD_HHMMSS.zip
        – The whole output directory, zipped. The loose files are kept: the ZIP is a copy, not a move.
    Logs/aws_YYYY-MM-DD_HHMMSS.log
        – Complete execution log

    Cloud Rewind sizing (default; -SkipCloudRewind to skip) additionally writes to Output/aws_.../:
        - aws_cloudrewind_<account>_YYYY-MM-DD_HHMMSS.csv          (one row per billable resource)
        - aws_cloudrewind_summary_<account>_YYYY-MM-DD_HHMMSS.csv  (billable vs non-billable totals)
    Use -SkipDataProtection for Cloud Rewind only; -Tags Key=Value scopes the Cloud Rewind pass.
#>


[CmdletBinding(DefaultParameterSetName = 'DefaultProfile')]
param (
    [Parameter(ParameterSetName='AllLocalProfiles',Mandatory=$true)]
    [ValidateNotNullOrEmpty()][switch]$AllLocalProfiles,

    [Parameter(ParameterSetName='CrossAccountRole',Mandatory=$true)]
    [ValidateNotNullOrEmpty()][string]$CrossAccountRoleName,

    [Parameter(ParameterSetName='CrossAccountRole')]
    [string]$CrossAccountRoleSessionName = "CVAWS-Cost-Sizing",

    [string]$ExternalId,

    [Parameter(ParameterSetName='DefaultProfile')][switch]$DefaultProfile,

    [Parameter(ParameterSetName='UserSpecifiedProfiles',Mandatory=$true)]
    [ValidateNotNullOrEmpty()][string]$UserSpecifiedProfileNames,

    [Parameter(ParameterSetName='CrossAccountRole')]
    [ValidateNotNullOrEmpty()][string]$UserSpecifiedAccounts,

    [Parameter(ParameterSetName='CrossAccountRole')]
    [ValidateNotNullOrEmpty()][string]$UserSpecifiedAccountsFile,

    [ValidateSet("GovCloud","")][string]$Partition,
    [string]$ProfileLocation,
    [string]$Regions,
    [string]$RegionToQuery,
    [switch]$SkipBucketTags,
    [switch]$DebugBucketTags,
    [ValidateSet("csv","json","both")][string]$OutputFormat = "csv",  # Output format: csv (default), json, or both
    [switch]$NonInteractive,   # force plain, non-interactive output (no progress bars / rich UI) - for CI / automation
    [switch]$Quiet,            # minimal console output (still writes the full log file)
    [switch]$SkipResilienceReport, # do not compute or write the cyber resilience posture report
    [string[]]$ResourceGroups,     # (reserved) AWS resource-group filtering is a follow-up; -Tags is applied today
    [string[]]$Tags,               # limit the Cloud Rewind pass to resources carrying any of these 'Key=Value' tags
    [switch]$SkipCloudRewind,      # skip the Cloud Rewind billable-resource sizing pass
    [switch]$SkipDataProtection,   # skip the Data Protection inventory pass (run Cloud Rewind only)
    [string]$OutputDirectory       # write Output/ and Logs/ under this root instead of the repo/script location
)

# Guard: at least one discovery pass must run.
if ($SkipCloudRewind -and $SkipDataProtection) {
    Write-Host 'ERROR: -SkipCloudRewind and -SkipDataProtection cannot both be set - nothing would run.' -ForegroundColor Red
    exit 1
}

# Load the shared console / diagnostics + resilience + Cloud Rewind layers (src/common/).
# Dot-sourcing a MISSING file is non-terminating, so an incomplete copy used to march on through cascading
# CommandNotFoundExceptions and silently skip Assert-CVPreflight. Check first, and name what is missing.
# This block must stay inline - it is the thing that guards dot-sourcing.
$cvCommonDir = Join-Path $PSScriptRoot 'common'
$cvRequired  = @(
    'CVSizing.Console.ps1'          # console / diagnostics / run paths
    'CVSizing.Resilience.ps1'       # provider-neutral scoring engine
    'CVSizing.Resilience.AWS.ps1'   # AWS control definitions
    'CVSizing.Summary.ps1'          # shared four-pass inventory rollup engine (cloud-agnostic)
    'CVSizing.Summary.AWS.ps1'      # AWS descriptor table for it
    'CVSizing.Kubectl.ps1'          # cross-platform kubectl provisioning
    'CVSizing.CloudRewind.ps1'      # provider-neutral Cloud Rewind engine
    'CVSizing.CloudRewind.AWS.ps1'  # AWS billable taxonomy (derived)
)
$cvMissing = @($cvRequired | Where-Object { -not (Test-Path -LiteralPath (Join-Path $cvCommonDir $_) -PathType Leaf) })
if ($cvMissing.Count) {
    Write-Host "FATAL: the shared layer this script depends on was not found." -ForegroundColor Red
    Write-Host "Expected under: $cvCommonDir" -ForegroundColor Red
    $cvMissing | ForEach-Object { Write-Host "  missing: $_" -ForegroundColor Red }
    Write-Host "This script cannot run standalone. Copy the whole src/ directory (the script AND src/common/)," -ForegroundColor Yellow
    Write-Host "or clone the repository, and run it from there." -ForegroundColor Yellow
    exit 1
}
foreach ($cvFile in $cvRequired) { . (Join-Path $cvCommonDir $cvFile) }


[System.Threading.Thread]::CurrentThread.CurrentCulture = 'en-US'
[System.Threading.Thread]::CurrentThread.CurrentUICulture = 'en-US'

Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:startTime = Get-Date
$script:currentActivity = ""
$script:moduleImportError = $false
$script:KubectlInstalled = $false

# Service configuration registry
$script:ServiceRegistry = @{
    EC2 = @{
        DisplayName = "Instances"
        GetCommand = "Get-EC2Instance"
        PropertyPath = "Instances"
        SizeProperty = "SizeGiB"
        IdProperty = "InstanceId"
        StorageType = "EBS"
        ProcessorFunction = "Process-EC2Instance"
        RequiresTagProcessing = $true
    }
    S3 = @{
        DisplayName = "Buckets"
        GetCommand = "Get-S3Bucket"
        PropertyPath = $null
        SizeProperty = "Custom"
        IdProperty = "BucketName"
        StorageType = "Object"
        ProcessorFunction = "Process-S3Bucket"
        RequiresTagProcessing = $true
        SpecialHandling = $true
    }
    EFS = @{
        DisplayName = "File Systems"
        GetCommand = "Get-EFSFileSystem"
        PropertyPath = $null
        SizeProperty = "SizeGiB"
        IdProperty = "FileSystemId"
        StorageType = "NFS"
        ProcessorFunction = "Process-EFSFileSystem"
        RequiresTagProcessing = $true
    }
    FSX = @{
        DisplayName = "File Systems"
        GetCommand = "Get-FSXFileSystem"
        PropertyPath = $null
        SizeProperty = "StorageCapacityGiB"
        IdProperty = "FileSystemId"
        StorageType = "Managed"
        ProcessorFunction = "Process-FSXFileSystem"
        RequiresTagProcessing = $true
        HasTypeBreakdown = $true
    }
    FSX_SVM = @{
        DisplayName = "ONTAP SVMs"
        GetCommand = "Get-FSXStorageVirtualMachine"
        PropertyPath = $null
        SizeProperty = "Custom"
        IdProperty = "StorageVirtualMachineId"
        StorageType = "Metadata"
        ProcessorFunction = "Process-FSXStorageVirtualMachine"
        RequiresTagProcessing = $true
        SpecialHandling = $true
    }
EKS = @{
    DisplayName = "Kubernetes"
    GetCommand = "Get-AllEKSClusters"
    CandidateGetCommands = @("Get-AllEKSClusters","Get-EKSClusterList")
    PropertyPath = $null
    SizeProperty = "Custom"
    IdProperty = "Name"
    StorageType = "Block"
    ProcessorFunction = "Process-EKSCluster"
    RequiresTagProcessing = $false
    SpecialHandling = $true
}

    UnattachedVolumes = @{
        DisplayName = "Volumes"
        GetCommand = "Get-EC2Volume"
        PropertyPath = $null
        SizeProperty = "SizeGiB"
        IdProperty = "VolumeId"
        StorageType = "EBS"
        ProcessorFunction = "Process-UnattachedVolume"
        RequiresTagProcessing = $true
        Filter = @{Name='status';Values='available'}
    }
    RDS = @{
        DisplayName = "Databases"
        GetCommand = "Get-RDSDBInstance"
        CandidateGetCommands = @("Get-RDSDBInstance","Get-RDSInstance","Get-RDSDBInstances","Get-RDSDBInstanceList")
        PropertyPath = "DBInstances"
        SizeProperty = "AllocatedStorageGB"
        IdProperty = "DBInstanceIdentifier"
        StorageType = "Block"
        ProcessorFunction = "Process-RDSInstance"
        RequiresTagProcessing = $true
    }
    DynamoDB = @{
        DisplayName = "Tables"
        GetCommand = "Get-DDBTableList"
        CandidateGetCommands = @("Get-DDBTableList","Get-DDBTable","Get-DDBTables","Get-DDBTableNames")
        PropertyPath = "TableNames"
        SizeProperty = "TableSizeBytes"
        IdProperty = "TableName"
        StorageType = "NoSQL"
        ProcessorFunction = "Process-DynamoDBTable"
        RequiresTagProcessing = $true
    }
    Redshift = @{
        DisplayName = "Clusters"
        GetCommand = "Get-RSCluster"
        PropertyPath = "Clusters"
        SizeProperty = "Custom"
        IdProperty = "ClusterIdentifier"
        StorageType = "Columnar"
        ProcessorFunction = "Process-RedshiftCluster"
        RequiresTagProcessing = $true
        SpecialHandling = $true
    }
    DocumentDB = @{
        DisplayName = "Clusters"
        GetCommand = "Get-DOCDBCluster"
        CandidateGetCommands = @("Get-DOCDBCluster","Get-DOCCluster","Get-DocumentDBCluster")
        PropertyPath = $null
        SizeProperty = "Custom"
        IdProperty = "DBClusterIdentifier"
        StorageType = "Document"
        ProcessorFunction = "Process-DocumentDBCluster"
        RequiresTagProcessing = $true
        SpecialHandling = $true
    }
    Aurora = @{
        DisplayName = "Clusters"
        GetCommand = "Get-RDSDBCluster"
        CandidateGetCommands = @("Get-RDSDBCluster","Get-RDSCluster")
        PropertyPath = "DBClusters"
        SizeProperty = "Custom"
        IdProperty = "DBClusterIdentifier"
        StorageType = "Block"
        ProcessorFunction = "Process-AuroraCluster"
        RequiresTagProcessing = $true
        SpecialHandling = $true
    }
    ElastiCache = @{
        DisplayName = "Clusters"
        GetCommand = "Get-ECCacheCluster"
        CandidateGetCommands = @("Get-ECCacheCluster","Get-ElastiCacheCacheCluster")
        PropertyPath = "CacheClusters"
        SizeProperty = "Custom"
        IdProperty = "CacheClusterId"
        StorageType = "InMemory"
        ProcessorFunction = "Process-ElastiCacheCluster"
        RequiresTagProcessing = $false
        SpecialHandling = $true
    }
    AWSBackup = @{
        DisplayName = "Protected Resources"
        GetCommand = "Get-BAKProtectedResourceList"
        CandidateGetCommands = @("Get-BAKProtectedResourceList","Get-BKPProtectedResourceList")
        PropertyPath = "Results"
        SizeProperty = "Custom"
        IdProperty = "ResourceArn"
        StorageType = "Backup"
        ProcessorFunction = "Process-AWSBackupResource"
        RequiresTagProcessing = $false
        SpecialHandling = $true
    }
}

$script:Config = @{
    DefaultQueryRegion = if ($RegionToQuery) { $RegionToQuery } else { "us-east-1" }
    DefaultGovCloudQueryRegion = "us-gov-west-1"
    Partition = if ($Partition) { $Partition } else { "Standard" }
    ProfileLocation = if ($ProfileLocation) { @{ProfileLocation = $ProfileLocation} } else { @{} }
    OutputPath = $null   # set from Initialize-CVRunPaths below; a CWD default silently misplaces output
    SkipBucketTags = $SkipBucketTags.IsPresent
    DebugBucketTags = $DebugBucketTags.IsPresent
}

$date = Get-Date
$date_string = $date.ToString("yyyy-MM-dd_HHmmss")

# Resolve this run's Output/ and Logs/ directories at the repo top level (or CWD when run outside the repo).
$script:RunPaths = Initialize-CVRunPaths -Cloud 'AWS' -TimeStamp $date_string -StartPath $PSScriptRoot -OutputRoot $OutputDirectory
$script:Config.OutputPath = $script:RunPaths.OutputDir
# Distinct from the -OutputDirectory PARAMETER above (which is the requested ROOT): this is the resolved
# per-run output directory consumed by the JSON export path.
$script:ResolvedOutputDir = $script:RunPaths.OutputDir
$script:LogPath           = $script:RunPaths.LogPath
$script:LogFile           = Split-Path $script:RunPaths.LogPath -Leaf

$utcEndTime = $date.ToUniversalTime()
$utcStartTime = $utcEndTime.AddDays(-7)

$script:ServiceDataByAccount = @{}
$script:AccountsProcessed = @()
$script:AllOutputFiles = [System.Collections.ArrayList]::new()

$baseOutputEc2Instance = "aws_ec2_instance_info"
$baseOutputEc2UnattachedVolume = "aws_ec2_unattached_volume_info"
$baseOutputS3 = "aws_s3_info"
$baseOutputEFS = "aws_efs_info"
$baseOutputFSx = "aws_fsx_info"
$baseOutputFSxSVM = "aws_fsx_ontap_svms_info"
$baseOutputRDS = "aws_rds_info"
$baseOutputDynamoDB = "aws_dynamodb_info"
$baseOutputRedshift = "aws_redshift_info"
$baseOutputEKS = "aws_eks_info"
$baseOutputDocumentDB = "aws_documentdb_info"
$baseOutputAurora = "aws_aurora_info"
$baseOutputElastiCache = "aws_elasticache_info"
$baseOutputAWSBackup = "aws_backup_protected_resources_info"
$archiveFile = $script:RunPaths.ZipPath

function Show-ScriptProgress {
    param(
        [string]$Activity,
        [string]$Status = "",
        [int]$PercentComplete = 0
    )
    # Shim over the shared console layer - throttling and tier handling (progress suppressed when headless) live there.
    $script:currentActivity = $Activity
    Update-CVProgress -Id 'aws' -Activity "AWS Cost Sizing Analysis" -Status "$Activity - $Status" -PercentComplete $PercentComplete
}

function Get-SafeCWMetricStatistic {
    param(
        [string]$Namespace,
        [string]$MetricName,
        [object]$Dimensions,
        [int]$Period = 300,
        [string[]]$Statistics = "Average",
        [datetime]$StartTime,
        [datetime]$EndTime,
        [object]$Credential,
        [string]$Region
    )

    if (-not $EndTime)   { $EndTime = if ($script:utcEndTime) { [datetime]$script:utcEndTime } else { (Get-Date).ToUniversalTime() } }
    if (-not $StartTime) { $StartTime = if ($script:utcStartTime) { [datetime]$script:utcStartTime } else { $EndTime.AddDays(-7) } }

    if ($Dimensions -and -not ($Dimensions -is [System.Collections.IEnumerable] -and -not ($Dimensions -is [string]))) {
        $Dimensions = @($Dimensions)
    }

    $cmdParams = (Get-Command Get-CWMetricStatistic).Parameters.Keys
    $hasUtcParams = $cmdParams -contains 'UtcEndTime'

    # Build parameters based on environment(AWS CloudShell vs Local PowerShell)
    $cwParams = @{
        Namespace      = $Namespace
        MetricName     = $MetricName
        Period         = $Period
        ErrorAction    = 'SilentlyContinue'
        WarningAction  = 'SilentlyContinue'
    }

    if ($hasUtcParams) {
        # CloudShell - use ONLY Utc parameters
        $cwParams['UtcStartTime'] = $StartTime.ToUniversalTime()
        $cwParams['UtcEndTime'] = $EndTime.ToUniversalTime()
    } else {
        # Local PowerShell - use ONLY regular parameters  
        $cwParams['StartTime'] = $StartTime
        $cwParams['EndTime'] = $EndTime
    }

    if ($Dimensions) { $cwParams['Dimension'] = $Dimensions }
    if ($Statistics) { $cwParams['Statistic'] = $Statistics }
    if ($Credential) { $cwParams['Credential'] = $Credential }
    if ($Region) { $cwParams['Region'] = $Region }

    try {
    return Get-CWMetricStatistic @cwParams
    } catch {
        Write-ScriptOutput "CloudWatch query failed - Namespace: $Namespace, Metric: $MetricName - $($_.Exception.Message)" -Level Warning
        return $null
    }
}

function Write-ScriptOutput {
    param(
        [string]$Message,
        [ValidateSet("Info", "Warning", "Error", "Success")]
        [string]$Level = "Info"
    )
    # Shim over the shared console layer: rendering, structured file logging, and warning/error
    # aggregation/de-duplication all happen in Write-CVLog. Existing call sites are unchanged.
    if (Get-Command Write-CVLog -ErrorAction SilentlyContinue) {
        Write-CVLog -Message $Message -Level $Level
    }
    else {
        # Fallback only if the console layer failed to load.
        Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $Message"
    }
}

function Convert-BytesToSizes {
    param([double]$Bytes)

    if ($Bytes -eq 0) {
        return @{
            SizeGiB = 0; SizeTiB = 0; SizeGB = 0; SizeTB = 0
        }
    }

    return @{
        SizeGiB = $Bytes / 1GB
        SizeTiB = $Bytes / 1TB
        SizeGB = $Bytes / 1000000000
        SizeTB = $Bytes / 1000000000000
    }
}

function Add-TagProperties {
    param([object]$Object, [array]$Tags)

    if ($Tags) {
        foreach ($tag in $Tags) {
            $tagName = "Tag_$($tag.Key -replace '[^a-zA-Z0-9_]', '_')"
            Add-Member -InputObject $Object -NotePropertyName $tagName -NotePropertyValue $tag.Value -Force
        }
    }
}

function Initialize-ServiceCollections {
    param([string]$AccountId)

    if (-not $script:ServiceDataByAccount.ContainsKey($AccountId)) {
        $script:ServiceDataByAccount[$AccountId] = @{}

        foreach ($serviceName in $script:ServiceRegistry.Keys) {
            $script:ServiceDataByAccount[$AccountId][$serviceName] = [System.Collections.ArrayList]@()
        }
    }
}

function Invoke-ServiceInventory {
    param(
        [string]$ServiceName,
        [object]$Credential,
        [string]$Region,
        [object]$AccountInfo,
        [string]$AccountAlias
    )

    $serviceConfig = $script:ServiceRegistry[$ServiceName]
    if (-not $serviceConfig) {
        Write-ScriptOutput "Unknown service: $ServiceName" -Level Warning
        return
    }

    try {
        Write-ScriptOutput "$ServiceName inventory started for region $Region" -Level Info

        if (-not (Get-Command $serviceConfig.GetCommand -ErrorAction SilentlyContinue)) {
            Write-ScriptOutput "Command $($serviceConfig.GetCommand) not available. Install the appropriate AWS Tools module for $ServiceName." -Level Warning
            return
        }

        $getParams = @{
            Credential = $Credential
            Region = $Region
            ErrorAction = 'Stop'
        }

        if ($ServiceName -eq "S3") { $getParams.BucketRegion = $Region }
        if ($ServiceName -eq "UnattachedVolumes" -and $serviceConfig.Filter) {
            $getParams.Filter = $serviceConfig.Filter
        }

        $resolvedCommand = $null
        if ($serviceConfig.CandidateGetCommands) {
            foreach ($cand in $serviceConfig.CandidateGetCommands) {
                if (Get-Command -Name $cand -ErrorAction SilentlyContinue) { $resolvedCommand = $cand; break }
            }
        }
        if (-not $resolvedCommand -and $serviceConfig.GetCommand) {
            if (Get-Command -Name $serviceConfig.GetCommand -ErrorAction SilentlyContinue) { $resolvedCommand = $serviceConfig.GetCommand }
        }

        if (-not $resolvedCommand) {
            Write-ScriptOutput "Command $($serviceConfig.GetCommand) not available. Install the appropriate AWS Tools module for $ServiceName." -Level Warning
            return
        }

        Write-ScriptOutput "Using command $resolvedCommand for service $ServiceName" -Level Info
        $serviceItems = & $resolvedCommand @getParams

        if ($serviceConfig.PropertyPath -and $serviceItems) {
            $prop = $serviceConfig.PropertyPath
            try {
                if ($serviceItems -and $serviceItems.PSObject -and ($serviceItems.PSObject.Properties.Name -contains $prop)) {
                    $extracted = $serviceItems.($prop)
                    if ($extracted -is [System.Collections.IEnumerable] -and -not ($extracted -is [string])) { $serviceItems = $extracted } else { $serviceItems = @($extracted) }
                }
                elseif ($serviceItems -is [System.Collections.IEnumerable] -and -not ($serviceItems -is [string]) -and $serviceItems.Count -gt 0 -and ($serviceItems[0].PSObject -and ($serviceItems[0].PSObject.Properties.Name -contains $prop))) {
                    $serviceItems = $serviceItems | ForEach-Object { $_.($prop) } | Where-Object { $_ -ne $null }
                }
            } catch {
            }
        }

        if ($serviceItems -ne $null -and -not ($serviceItems -is [System.Collections.IEnumerable] -and -not ($serviceItems -is [string]))) {
            $serviceItems = @($serviceItems)
        }

        if (-not $serviceItems) {
            Write-ScriptOutput "No $ServiceName found in region $Region" -Level Info
            return
        }

        $serviceList = $script:ServiceDataByAccount[$AccountInfo.Account][$ServiceName]
        $count = 1

        foreach ($item in $serviceItems) {
            $itemId = $item.($serviceConfig.IdProperty)
            Show-ScriptProgress -Activity "$ServiceName $itemId" -Status "$count / $($serviceItems.Count)" -PercentComplete (($count / $serviceItems.Count) * 100)

            $processedItem = & $serviceConfig.ProcessorFunction -Item $item -Credential $Credential -Region $Region -AccountInfo $AccountInfo -AccountAlias $AccountAlias

            if ($processedItem) {
                if ($processedItem -is [Array]) {
                    foreach ($singleItem in $processedItem) {
                        if ($singleItem) {
                            [void]$serviceList.Add($singleItem)
                        }
                    }
                } else {
                    [void]$serviceList.Add($processedItem)
                }
            }
            $count++
        }

        Write-ScriptOutput "$ServiceName done" -Level Success
    }
    catch {
        # Aggregated: the first failure per (service+message) renders; per-region repeats collapse into the summary.
        Write-CVLog "Failed to get $ServiceName for region $Region" -Level Error -Source $ServiceName -Scope @{ Region = $Region } -Exception $_
    }
}

# ============================================================
# CYBER RESILIENCE POSTURE (AWS)  -  skip with -SkipResilienceReport
# Scores each resource's CURRENT NATIVE AWS configuration against the Cloud Resilience Control Catalog.
# Runs per account BEFORE that account's CSVs are written, so Ctl_*/ResilienceScore columns land on every
# per-service CSV - matching the GCP and Azure passes. Any signal we could not collect scores as Unknown and
# is excluded from the score; it never fails the run.
# ============================================================
$script:ResilienceSignalRows = New-Object System.Collections.Generic.List[psobject]

# Name and size are the only genuinely per-type fields; resource group/region/id are probed by New-CVSignalRow.
$script:AwsSignalFields = @{
    EC2      = @{ Name = 'InstanceId';           SizeGB = 'SizeGB' }
    EBS      = @{ Name = 'VolumeId';             SizeGB = 'SizeGB' }
    RDS      = @{ Name = 'DBInstanceIdentifier'; SizeGB = 'SizeGB' }
    S3       = @{ Name = 'BucketName';           SizeGB = 'SizeGB' }
    EFS      = @{ Name = 'FileSystemId';         SizeGB = 'SizeGB' }
    DynamoDB = @{ Name = 'TableName';            SizeGB = 'SizeGB' }
    Redshift = @{ Name = 'ClusterIdentifier';    SizeGB = 'SizeGB' }
}
$script:ResilienceErrShown = $false

# Inventory service name -> control set in Get-CVAwsResilienceControls. Services absent here simply are not scored.
$script:AwsResilienceMap = @{
    EC2               = 'EC2'
    UnattachedVolumes = 'EBS'
    RDS               = 'RDS'
    Aurora            = 'RDS'
    DocumentDB        = 'RDS'
    S3                = 'S3'
    EFS               = 'EFS'
    DynamoDB          = 'DynamoDB'
    Redshift          = 'Redshift'
}

function Invoke-AWSResiliencePass {
    <#
      .SYNOPSIS  Emit one signal row per inventory row, for every resource type that has a control set.
      .DESCRIPTION
        NOTHING is scored here and no verdict is written. The control sets are consulted only for WHICH inventory
        fields are signals (via Get-CVSignalFieldMap, which parses the Test blocks); thresholds and weighting
        belong to the backend. The Ctl_*/ResilienceScore/ResilienceGaps columns this used to append no longer
        exist - see the CVSizing.Resilience.ps1 header.
    #>
    param([Parameter(Mandatory)][string]$AccountId)

    if ($SkipResilienceReport) { return }
    try {
        $controls = Get-CVAwsResilienceControls
        foreach ($serviceName in @($script:AwsResilienceMap.Keys)) {
            $setName = $script:AwsResilienceMap[$serviceName]
            $set     = $controls[$setName]
            if (-not $set) { continue }

            $rows = @($script:ServiceDataByAccount[$AccountId][$serviceName])
            if (-not $rows.Count) { continue }

            foreach ($row in $rows) {
                if (-not $row) { continue }
                # Isolate per-row failures so one problematic resource cannot sink the whole report.
                try {
                    # No evaluation: controls declare WHICH fields are signals; thresholds belong to the backend.
                    if (-not $script:AwsSignalMap) { $script:AwsSignalMap = Get-CVSignalFieldMap -ControlSets (Get-CVAwsResilienceControls) }
                    $script:ResilienceSignalRows.Add((New-CVSignalRow -Resource $row -ResourceType $setName `
                        -SignalFields $script:AwsSignalMap[$setName] -FieldMap $script:AwsSignalFields[$setName]))
                } catch {
                    if (-not $script:ResilienceErrShown) {
                        $script:ResilienceErrShown = $true
                        Write-CVLog "Signal export failed on a $setName row" -Level Warning -Source 'Resilience' -Exception $_
                    }
                }
            }
        }
    } catch {
        Write-CVLog "Resilience pass failed for account ${AccountId}: $($_.Exception.Message)" -Level Warning -Source 'Resilience'
    }
}

function Write-AWSResilienceReport {
    <# .SYNOPSIS  Write the run-wide resilience posture summary and the per-resource gap report. #>
    param([Parameter(Mandatory)][string]$OutputPath, [Parameter(Mandatory)][string]$DateString)

    if ($SkipResilienceReport) { return }
    try {
        Write-CVSection 'Cyber Resilience Posture'
        # No score is printed - the export is judgement-free; scoring is the backend's. Two lines here used to
        # print one anyway, off a $summary variable that was never assigned: the run emitted "Overall native
        # resilience score: /100  (0 controls assessed, 0 not assessed)" on every AWS run, directly contradicting
        # the comment above it, and the per-category loop iterated nothing.
        # One file: every resource with a gap or an incomplete assessment, ranked. The static control catalog and
        # the per-category rollup are no longer written - neither named the resources to go look at.
        if ($script:ResilienceSignalRows.Count) {
            $signalsPath = Join-Path $OutputPath ("aws_resilience_signals_" + $DateString + ".csv")
            Sort-CVSignalRows -Rows $script:ResilienceSignalRows |
                Export-CVCsv -Path $signalsPath `
                             -PreferredOrder (Get-CVSignalColumns -ControlSets (Get-CVAwsResilienceControls)) -KeepDeclaredColumns
            # REGISTER IT FOR THE ARCHIVE. The ZIP is built from $script:AllOutputFiles, not from the output
            # directory, so a file that writes itself without registering is silently left out - and the ZIP is
            # the artifact handed to the Commvault representative. Verified against a live run: the signals CSV
            # was on disk and absent from the archive, so on AWS this whole export was invisible in the
            # deliverable. Every other writer does this; this one did not.
            $script:AllOutputFiles.Add($signalsPath) | Out-Null
            Write-CVLog ("Resilience signals: {0} resource(s) exported across {1} resource type(s)." -f `
                         $script:ResilienceSignalRows.Count, @($script:ResilienceSignalRows | Select-Object -ExpandProperty ResourceType -Unique).Count) `
                        -Level Info -Source 'Resilience'
            Write-ScriptOutput "aws_resilience_signals_$DateString.csv written to $OutputPath" -Level Success
        } else {
            Write-CVLog "No resources of an assessed type were found - no signals CSV written." -Level Info -Source 'Resilience'
        }
    } catch {
        Write-CVLog "Resilience report failed: $($_.Exception.Message)" -Level Warning -Source 'Resilience'
    }
}

# ── AWS Backup lookup helpers ──────────────────────────────────────────────
# AWS Tools for PowerShell has carried more than one name for these cmdlets across module versions, and a
# hard-coded wrong name fails as CommandNotFound - which a bare catch turns into "this resource has no backups".
# Resolving from a candidate list keeps the check honest across versions and degrades to Unknown, never to a
# fabricated "Unprotected".
$script:AWSBackupProtectedCache = @{}
$script:AWSBackupCmdWarned      = $false
$script:AWSRecoveryPointCmd     = $null

function Resolve-CVAwsCommand {
    param([Parameter(Mandatory)][string[]]$Candidates)
    foreach ($c in $Candidates) {
        if (Get-Command -Name $c -ErrorAction SilentlyContinue) { return $c }
    }
    return $null
}

function Test-CVAwsNotConfiguredError {
    <#
      .SYNOPSIS  Does this S3 exception mean "the feature is not configured" rather than "the call failed"?
      .DESCRIPTION
        S3 signals absence by THROWING, not by returning an empty object. Verified live against a real bucket:
        get-object-lock-configuration returns ObjectLockConfigurationNotFoundError when Object Lock was never
        enabled. The same pattern applies to replication, lifecycle and default encryption.

        That makes a blanket `catch { $null }` wrong in the opposite direction from a blanket `catch { $false }`:
        one invents a gap, the other hides a real one behind Unknown. Only these specific error codes are a
        measured absence; anything else - AccessDenied, throttling, a network fault - is genuinely unknown.
      .OUTPUTS  $true when the error means "not configured".
    #>
    param($ErrorRecord)

    # The AWS error CODE is the reliable signal, but it can sit on the exception, on an InnerException, or be
    # absent entirely depending on how the cmdlet wrapped the fault - so gather every place it might be and
    # match once. Verified live: two buckets with no public-access block raise
    # NoSuchPublicAccessBlockConfiguration, and an ErrorCode-only check missed it, leaving the four columns blank
    # when the honest answer is FALSE - i.e. hiding a genuinely unprotected bucket behind "not collected".
    $parts = [System.Collections.Generic.List[string]]::new()
    $ex = $ErrorRecord.Exception
    $depth = 0
    while ($ex -and $depth -lt 4) {
        foreach ($prop in 'ErrorCode', 'Message') {
            try { $v = $ex.$prop; if ($v) { $parts.Add("$v") } } catch { }
        }
        $ex = $ex.InnerException; $depth++
    }
    try { if ($ErrorRecord.FullyQualifiedErrorId) { $parts.Add("$($ErrorRecord.FullyQualifiedErrorId)") } } catch { }
    $hay = ($parts -join ' | ')

    # Error-code tokens, plus the prose forms AWS uses when no code survives the wrapping.
    return [bool]($hay -match '(?i)(ReplicationConfigurationNotFound|NoSuchLifecycleConfiguration|NoSuchLifecycleConfig|ServerSideEncryptionConfigurationNotFound|ObjectLockConfigurationNotFound|NoSuchPublicAccessBlockConfiguration|NoSuchReplicationConfiguration|NoSuchConfiguration|not\s*found|does not exist)')
}

function Get-AWSBackupProtectedResource {
    <#
      .SYNOPSIS  Region-scoped list of resources covered by AWS Backup, as full objects.
      .DESCRIPTION
        Caches the ProtectedResource objects rather than just their ARNs, because two of their other fields
        matter: .ResourceType ('EC2' | 'RDS' | 'DynamoDB' | 'EFS' | 'S3' ...) lets a caller match by type instead
        of guessing from the ARN text, and .LastBackupTime gives a real recovery-point age for every service -
        not just EC2, which was inferring it from EBS snapshots alone.
        Verified live: ResourceType='RDS', ResourceArn='arn:aws:rds:us-east-1:...:db:database-1',
        LastBackupTime=2021-07-31.
      .OUTPUTS   ProtectedResource[] (possibly empty) when the lookup SUCCEEDED; $null when it could not be
                 performed. That distinction is the whole point - see Resolve-AWSBackupProtection.
    #>
    param($Credential, [string]$Region)

    if ($script:AWSBackupProtectedCache.ContainsKey($Region)) {
        $cached = $script:AWSBackupProtectedCache[$Region]
        if ($null -eq $cached) { return $null }
        return ,$cached
    }

    $cmdName = Resolve-CVAwsCommand -Candidates @('Get-BAKProtectedResourceList','Get-BKPProtectedResourceList','Get-BAKProtectedResource')
    if (-not $cmdName) {
        if (-not $script:AWSBackupCmdWarned) {
            $script:AWSBackupCmdWarned = $true
            Write-ScriptOutput "AWS Backup protected-resource cmdlet not found (install AWS.Tools.Backup) - AWSBackupProtected will read Unknown." -Level Warning
        }
        $script:AWSBackupProtectedCache[$Region] = $null
        return $null
    }
    try {
        $items = @(& $cmdName -Credential $Credential -Region $Region -ErrorAction Stop | Where-Object { $_ -and $_.ResourceArn })
        $script:AWSBackupProtectedCache[$Region] = $items
        Write-ScriptOutput "AWS Backup: $($items.Count) protected resource(s) in $Region (via $cmdName)." -Level Info
        return ,$items
    } catch {
        Write-ScriptOutput "AWS Backup protected-resource lookup failed in ${Region}: $($_.Exception.Message)" -Level Warning
        $script:AWSBackupProtectedCache[$Region] = $null
        return $null
    }
}

$script:AWSVaultLockCache = @{}

function Get-AWSBackupVaultLock {
    <#
      .SYNOPSIS  Region-scoped AWS Backup Vault Lock posture - the immutability signal AWS had none of.
      .DESCRIPTION
        Vault Lock is the AWS analogue of an Azure Recovery Services vault's locked immutability policy: once
        locked in compliance mode, recovery points cannot be deleted or their retention shortened, even by an
        administrator. Nothing in this script collected it, so AWS reported no immutability signal for backups at
        all while Azure reported one for every VM.

        Verified live: Get-BAKBackupVaultList then Get-BAKBackupVault returns .Locked (a real boolean), .LockDate,
        .MinRetentionDays, .MaxRetentionDays and .NumberOfRecoveryPoints. On the test account the 'Default' vault
        reported Locked=false with 1 recovery point.

        Aggregated per region because a resource's recovery points can span vaults: AnyLocked answers "is any
        vault protecting this region immutable", which is the honest summary without pretending to know which
        vault holds a given resource's points.
      .OUTPUTS  pscustomobject { Status; VaultCount; LockedCount; AnyLocked; MinRetentionDays; VaultNames }
                Status is Ok | Failed; every value is $null when Failed.
    #>
    param($Credential, [string]$Region)

    if ($script:AWSVaultLockCache.ContainsKey($Region)) { return $script:AWSVaultLockCache[$Region] }

    $unknown = [pscustomobject]@{ Status = 'Failed'; VaultCount = $null; LockedCount = $null
                                 AnyLocked = $null; MinRetentionDays = $null; VaultNames = '' }
    $listCmd = Resolve-CVAwsCommand -Candidates @('Get-BAKBackupVaultList','Get-BKPBackupVaultList')
    $descCmd = Resolve-CVAwsCommand -Candidates @('Get-BAKBackupVault','Get-BKPBackupVault')
    if (-not $listCmd -or -not $descCmd) {
        $script:AWSVaultLockCache[$Region] = $unknown
        return $unknown
    }

    try {
        $vaults = @(& $listCmd -Credential $Credential -Region $Region -ErrorAction Stop)
    } catch {
        Write-ScriptOutput "AWS Backup vault listing failed in ${Region}: $($_.Exception.Message)" -Level Warning
        $script:AWSVaultLockCache[$Region] = $unknown
        return $unknown
    }

    # 200 with zero vaults is conclusive: no vault, so nothing is locked.
    if (-not $vaults.Count) {
        $res = [pscustomobject]@{ Status = 'Ok'; VaultCount = 0; LockedCount = 0
                                  AnyLocked = $false; MinRetentionDays = $null; VaultNames = '' }
        $script:AWSVaultLockCache[$Region] = $res
        return $res
    }

    $locked = 0; $minRet = $null; $names = @(); $anyFailed = $false
    foreach ($v in $vaults) {
        $names += "$($v.BackupVaultName)"
        try {
            $d = & $descCmd -BackupVaultName $v.BackupVaultName -Credential $Credential -Region $Region -ErrorAction Stop
            if ($d.Locked) {
                $locked++
                if ($null -ne $d.MinRetentionDays -and ($null -eq $minRet -or [int]$d.MinRetentionDays -lt $minRet)) { $minRet = [int]$d.MinRetentionDays }
            }
        } catch { $anyFailed = $true }
    }
    # One unreadable vault means we cannot claim "nothing is locked" for the region.
    if ($anyFailed -and $locked -eq 0) {
        $script:AWSVaultLockCache[$Region] = $unknown
        return $unknown
    }

    $res = [pscustomobject]@{
        Status = 'Ok'; VaultCount = $vaults.Count; LockedCount = $locked
        AnyLocked = [bool]($locked -gt 0); MinRetentionDays = $minRet; VaultNames = ($names -join ';')
    }
    $script:AWSVaultLockCache[$Region] = $res
    return $res
}

function Resolve-AWSBackupProtection {
    <#
      .SYNOPSIS  Tri-state AWS Backup coverage for one resource, plus its last backup time.
      .DESCRIPTION
        Matches on ResourceType AND an exact ARN, replacing a substring test
        (`$_ -like "*$InstanceId*"`) that could match the wrong resource: identifiers chosen by the user - RDS
        instances, DynamoDB tables - collide readily, so 'db1' matched 'db10'. An ARN suffix match on
        "/$Identifier" or ":$Identifier" is exact at the segment boundary, the same reasoning as the Azure
        resource-lock scope predicate.
      .PARAMETER ResourceArn  Preferred: the resource's own ARN, matched exactly.
      .PARAMETER Identifier   Fallback for resources whose row carries no ARN (EC2 instances). Matched against
                              the final ARN segment only.
      .OUTPUTS  pscustomobject { Protected; LastBackupTime; Status }
                Protected is $null when the protected-resource list could not be read - NEVER $false, because
                "we could not look" is not evidence the resource is unprotected. Status is Ok | Failed.
    #>
    param($Credential, [string]$Region, [string]$ResourceArn, [string]$Identifier, [string]$ResourceType)

    $all = Get-AWSBackupProtectedResource -Credential $Credential -Region $Region
    if ($null -eq $all) {
        return [pscustomobject]@{ Protected = $null; LastBackupTime = $null; Status = 'Failed' }
    }

    $candidates = @($all)
    if ($ResourceType) { $candidates = @($candidates | Where-Object { "$($_.ResourceType)" -eq $ResourceType }) }

    $match = $null
    if ($ResourceArn) {
        $match = @($candidates | Where-Object { "$($_.ResourceArn)".Equals($ResourceArn, [StringComparison]::OrdinalIgnoreCase) })[0]
    }
    if (-not $match -and $Identifier) {
        # Segment-boundary match: an ARN ends '.../i-0abc' or ':table/name', so require the delimiter.
        $match = @($candidates | Where-Object {
            $a = "$($_.ResourceArn)"
            $a.EndsWith("/$Identifier", [StringComparison]::OrdinalIgnoreCase) -or
            $a.EndsWith(":$Identifier", [StringComparison]::OrdinalIgnoreCase)
        })[0]
    }

    return [pscustomobject]@{
        Protected      = [bool]$match
        LastBackupTime = $(if ($match) { $match.LastBackupTime } else { $null })
        Status         = 'Ok'
    }
}

function Get-AWSBackupRecoveryPoint {
    <#
      .SYNOPSIS  Most recent AWS Backup recovery point for one resource ARN, or $null when unknown/none.
    #>
    param([string]$ResourceArn, $Credential, [string]$Region)
    if (-not $ResourceArn) { return $null }
    if (-not $script:AWSRecoveryPointCmd) {
        $script:AWSRecoveryPointCmd = Resolve-CVAwsCommand -Candidates @(
            'Get-BAKRecoveryPointsByResourceList','Get-BAKRecoveryPointsByResource','Get-BKPRecoveryPointsByResource')
        if (-not $script:AWSRecoveryPointCmd) { return $null }
    }
    try {
        $rps = & $script:AWSRecoveryPointCmd -ResourceArn $ResourceArn -MaxResult 1 -Credential $Credential -Region $Region -ErrorAction Stop
        if ($rps -and @($rps).Count -gt 0) { return @($rps)[0] }
        return $null
    } catch { return $null }
}

function Process-EC2Instance {
    param($Item, $Credential, $Region, $AccountInfo, $AccountAlias)

    $ebsVolumes = @()
    $totalEbsBytes = 0

    foreach ($blockDevice in $Item.BlockDeviceMappings) {
        if ($blockDevice.Ebs) {
            try {
                $volume = Get-EC2Volume -VolumeId $blockDevice.Ebs.VolumeId -Credential $Credential -Region $Region -ErrorAction Stop
                $ebsVolumes += $volume
                $totalEbsBytes += $volume.Size * 1GB
            }
            catch {
                Write-ScriptOutput "Failed to get volume $($blockDevice.Ebs.VolumeId): $($_.Exception.Message)" -Level Warning
            }
        }
    }

    $instanceTags = @()
    try {
        $tagFilter = @{
            Name = "resource-id"
            Values = @($Item.InstanceId)
        }
        $tagResponse = Get-EC2Tag -Filter $tagFilter -Credential $Credential -Region $Region -ErrorAction Stop
        $instanceTags = $tagResponse

        if ($instanceTags -and $instanceTags.Count -gt 0) {
            Write-ScriptOutput "Retrieved $($instanceTags.Count) tags for instance $($Item.InstanceId)" -Level Info
        }
    }
    catch {
        try {
            $instanceDetail = Get-EC2Instance -InstanceId $Item.InstanceId -Credential $Credential -Region $Region -ErrorAction Stop
            if ($instanceDetail -and $instanceDetail.Instances -and $instanceDetail.Instances[0].Tags) {
                $instanceTags = $instanceDetail.Instances[0].Tags
                Write-ScriptOutput "Retrieved tags via instance detail for $($Item.InstanceId)" -Level Info
            }
        }
        catch {
            Write-ScriptOutput "Failed to get tags for instance $($Item.InstanceId): $($_.Exception.Message)" -Level Warning
        }
    }

    $sizes = Convert-BytesToSizes -Bytes $totalEbsBytes

    # ── Backup coverage: check AWS Backup and native EBS snapshots ─────────
    # $null, NOT $false. This used to initialise to $false, so a region whose protected-resource list could not
    # be read exported AWSBackupProtected = FALSE - an affirmative "not backed up" about data we never saw. The
    # ec2-backup control happened to compensate via ProtectionStatus, but the SIGNAL COLUMN itself was wrong, and
    # the column is what the backend consumes.
    $awsBackupProtected = $null
    $awsBackupLastTime  = $null
    $latestSnapshotDate = $null
    $snapshotCount = 0
    $snapshotSizeGiB = 0

    # The protected-resource list is per REGION, not per instance - fetched once and cached. Matched by
    # ResourceType + exact ARN segment rather than a substring of the instance id.
    $ec2Backup = Resolve-AWSBackupProtection -Credential $Credential -Region $Region `
                    -Identifier $Item.InstanceId -ResourceType 'EC2'
    $awsBackupProtected = $ec2Backup.Protected
    $awsBackupLastTime  = $ec2Backup.LastBackupTime


    # EBS snapshots belong to VOLUMES, not instances: 'source-instance-id' is not a valid DescribeSnapshots
    # filter, so the old call was rejected by the API and the bare catch reported every instance as having
    # zero snapshots. Filter on the volume IDs already collected above.
    $volumeIds = @($ebsVolumes | ForEach-Object { $_.VolumeId } | Where-Object { $_ })
    if ($volumeIds.Count -gt 0) {
        try {
            # DescribeSnapshots caps filter values, so chunk defensively for instances with many volumes.
            $snaps = @()
            for ($i = 0; $i -lt $volumeIds.Count; $i += 200) {
                $chunk = $volumeIds[$i..([Math]::Min($i + 199, $volumeIds.Count - 1))]
                $snapFilter = @(@{ Name = 'volume-id'; Values = @($chunk) })
                $snaps += @(Get-EC2Snapshot -Filter $snapFilter -OwnerId 'self' -Credential $Credential -Region $Region -ErrorAction Stop)
            }
            if ($snaps.Count -gt 0) {
                $snapshotCount = $snaps.Count
                # EBS snapshot VolumeSize is the source volume size in GiB (AWS bills only changed blocks,
                # but provisioned size is the consistent figure available without extra API calls).
                $snapshotSizeGiB = [double](($snaps | Measure-Object -Property VolumeSize -Sum).Sum)
                $latestSnap = $snaps | Sort-Object StartTime -Descending | Select-Object -First 1
                $latestSnapshotDate = if ($latestSnap) { $latestSnap.StartTime } else { $null }
            }
        } catch {
            Write-ScriptOutput "Snapshot lookup failed for $($Item.InstanceId) in ${Region}: $($_.Exception.Message)" -Level Warning
        }
    }

    # ── Encryption: check all attached EBS volumes ─────────────────────────
    $allEncrypted = if ($ebsVolumes.Count -gt 0) { ($ebsVolumes | Where-Object { -not $_.Encrypted }).Count -eq 0 } else { $null }
    $encryptedVolumeCount = ($ebsVolumes | Where-Object { $_.Encrypted }).Count

    # ── Platform / OS ──────────────────────────────────────────────────────
    $platform = if ($Item.Platform) { $Item.Platform.Value ?? $Item.Platform } else { 'linux' }

    # ── IAM instance profile ───────────────────────────────────────────────
    $iamProfile = if ($Item.IamInstanceProfile) { $Item.IamInstanceProfile.Arn } else { $null }

    # ── Protection status inference ────────────────────────────────────────
    # 'Unprotected' is a claim, so only make it when both signals were actually collected. When the AWS Backup
    # list could not be read and no snapshots were found, the honest answer is Unknown.
    $protectionStatus = if ($awsBackupProtected)                        { 'Protected' }
                        elseif ($snapshotCount -gt 0)                   { 'Snapshot-Only' }
                        elseif ($ec2Backup.Status -ne 'Ok')             { 'Unknown' }
                        else                                            { 'Unprotected' }

    $ec2Obj = [PSCustomObject]@{
        AwsAccountId          = $AccountInfo.Account
        AwsAccountAlias       = $AccountAlias
        Region                = $Region
        InstanceId            = $Item.InstanceId
        InstanceType          = if ($Item.InstanceType -and $Item.InstanceType.PSObject.Properties.Name -contains 'Value') { $Item.InstanceType.Value } else { [string]$Item.InstanceType }
        Platform              = $platform
        State                 = if ($Item.State -and $Item.State.Name) { if ($Item.State.Name.PSObject.Properties.Name -contains 'Value') { $Item.State.Name.Value } else { [string]$Item.State.Name } } else { 'unknown' }
        LaunchTime            = $Item.LaunchTime
        IamInstanceProfile    = $iamProfile
        LaunchDays            = if ($Item.LaunchTime) { [math]::Round((New-TimeSpan -Start $Item.LaunchTime -End (Get-Date)).TotalDays, 0) } else { $null }
        VolumeCount           = $ebsVolumes.Count
        SizeGiB               = $sizes.SizeGiB
        SizeTiB               = $sizes.SizeTiB
        SizeGB                = $sizes.SizeGB
        SizeTB                = $sizes.SizeTB
        VolumeDetails         = ($ebsVolumes | ForEach-Object { "$($_.VolumeId):$($_.Size)GB:$($_.VolumeType)" }) -join ";"
        AllVolumesEncrypted   = $allEncrypted
        EncryptedVolumeCount  = $encryptedVolumeCount
        # EC2 does not return an ARN, so build the canonical one rather than leave the row unjoinable.
        ResourceId            = "arn:aws:ec2:${Region}:$($AccountInfo.Account):instance/$($Item.InstanceId)"
        AWSBackupProtected    = $awsBackupProtected
        # AWS Backup Vault Lock - region-scoped immutability. Locked vaults cannot have recovery points
        # deleted or retention shortened, even by an admin: the AWS analogue of Azure vault immutability.
        BackupVaultAnyLocked    = $vaultLock.AnyLocked
        # Why a blank neighbouring cell is blank. DaysSinceLastBackup blank could mean 'no recovery point
        # exists' OR 'the AWS Backup list could not be read' - these two columns say which.
        BackupDataStatus        = $ec2Backup.Status
        VaultLockDataStatus     = $vaultLock.Status
        BackupVaultLockedCount  = $vaultLock.LockedCount
        BackupVaultMinRetentionDays = $vaultLock.MinRetentionDays
        EBSSnapshotCount      = $snapshotCount
        # Reported in TB only (decimal) - the sizing spreadsheet takes TB, and mixed units invite copy/paste errors.
        EBSSnapshotSizeTB     = [math]::Round(($snapshotSizeGiB * 1GB) / 1000000000000, 4)
        LatestSnapshotDate    = $latestSnapshotDate
        # Most recent recovery point from EITHER source. It used to consider EBS snapshots only, so an instance
        # backed up solely by AWS Backup reported no recovery point at all and ec2-recent read Unknown.
        DaysSinceLastBackup   = $(
            $newest = @($latestSnapshotDate, $awsBackupLastTime) | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1
            if ($newest) { [math]::Round((New-TimeSpan -Start $newest -End (Get-Date)).TotalDays, 0) } else { $null }
        )
        AwsBackupLastBackupUtc = $(if ($awsBackupLastTime) { ([datetime]$awsBackupLastTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { '' })
        ProtectionStatus      = $protectionStatus
    }

    Add-TagProperties -Object $ec2Obj -Tags $instanceTags

    return $ec2Obj
}

function Process-S3Bucket {
    param($Item, $Credential, $Region, $AccountInfo, $AccountAlias)

    try {
        $bucketName = if ($Item.BucketName) { $Item.BucketName } elseif ($Item.Name) { $Item.Name } else { $null }
        if (-not $bucketName) { return $null }

        try {
            $bucketLocation = Get-S3BucketLocation -BucketName $bucketName -Credential $Credential -ErrorAction Stop
            $actualRegion = if ($bucketLocation.Value -eq "" -or -not $bucketLocation.Value) { "us-east-1" } else { $bucketLocation.Value }
        }
        catch {
            Write-ScriptOutput "Warning: could not determine region for bucket $bucketName, using passed region '$Region' : $_" -Level Warning
            $actualRegion = if ($Region) { $Region } else { "us-east-1" }
        }

        $storageClasses = @("STANDARD", "STANDARD_IA", "ONEZONE_IA", "REDUCED_REDUNDANCY", "GLACIER", "DEEP_ARCHIVE", "INTELLIGENT_TIERING")
        $classBytes = @{}
        $totalBytes = 0.0

        foreach ($storageClass in $storageClasses) {
            try {
                $bytes = Get-S3BucketSizeByStorageClass -BucketName $bucketName -StorageClass $storageClass -Credential $Credential -Region $actualRegion
                $bytes = if ($bytes) { [double]$bytes } else { 0.0 }
            } catch {
                Write-ScriptOutput "Warning: failed to get metric for storage class $storageClass on bucket ${bucketName}: $_" -Level Warning
                $bytes = 0.0
            }
            $classBytes[$storageClass] = $bytes
            $totalBytes += $bytes

            if ($script:Config.DebugBucketTags) {
                $classSizes = Convert-BytesToSizes -Bytes $bytes
                Write-ScriptOutput ("S3 metric: Bucket='{0}' StorageClass={1} Bytes={2} GiB(binary)={3:N4} GB(decimal)={4:N4}" -f $bucketName, $storageClass, $bytes, $classSizes.SizeGiB, $classSizes.SizeGB) -Level Info
            }
        }

        $objectCount = 0
        try {
            $objectMetric = Get-SafeCWMetricStatistic -Namespace 'AWS/S3' -MetricName 'NumberOfObjects' -Dimensions @(@{Name='BucketName';Value=$bucketName}, @{Name='StorageType';Value='AllStorageTypes'}) -Period 86400 -Statistics 'Average' -StartTime $script:utcStartTime -EndTime $script:utcEndTime -Credential $Credential -Region $actualRegion
            
            if ($objectMetric -and $objectMetric.Datapoints) {
                $objectCount = [math]::Round(($objectMetric.Datapoints | Sort-Object Timestamp -Descending | Select-Object -First 1).Average, 0)
                Write-ScriptOutput "S3 object count via CloudWatch for ${bucketName}: $objectCount objects" -Level Info
            }
        } catch {
            Write-ScriptOutput "Warning: failed to get object count for bucket ${bucketName}: $_" -Level Warning
        }

        if ($totalBytes -eq 0) {    try {
                $val = Get-S3BucketSize -BucketName $bucketName -Credential $Credential -Region $actualRegion
                if ($val -and $val -gt 0) {
                    $totalBytes = [double]$val
                    if ($script:Config.DebugBucketTags) {
                        $sizes = Convert-BytesToSizes -Bytes $totalBytes
                        Write-ScriptOutput ("S3 metric fallback (AllStorageTypes): Bucket='{0}' Bytes={1} GiB(binary)={2:N4} GB(decimal)={3:N4}" -f $bucketName, $totalBytes, $sizes.SizeGiB, $sizes.SizeGB) -Level Info
                    }
                }
            } catch {
            }
        }
        if ($totalBytes -eq 0) {
            try {
                $accurate = Get-S3BucketSizeAccurate -BucketName $bucketName -Credential $Credential -Region $actualRegion
                if ($accurate -and $accurate -gt 0) {
                    $totalBytes = [double]$accurate
                    if ($script:Config.DebugBucketTags) {
                        $sizes = Convert-BytesToSizes -Bytes $totalBytes
                        Write-ScriptOutput ("S3 enumeration: Bucket='{0}' Bytes={1} GiB(binary)={2:N4} GB(decimal)={3:N4}" -f $bucketName, $totalBytes, $sizes.SizeGiB, $sizes.SizeGB) -Level Info
                    }
                } else {
                    Write-ScriptOutput "S3 enumeration for bucket '$bucketName'" -Level Info
                }
            } catch {

            }
        }

        $bucketTags = @()
        if (-not $script:Config.SkipBucketTags) {
            try {
                $taggingResponse = Get-S3BucketTagging -BucketName $bucketName -Credential $Credential -Region $actualRegion -ErrorAction Stop
                $bucketTags = if ($taggingResponse.TagSet) { $taggingResponse.TagSet } elseif ($taggingResponse -is [array]) { $taggingResponse } else { $taggingResponse }
                if ($script:Config.DebugBucketTags) {
                    Write-ScriptOutput "Retrieved $($bucketTags.Count) tags for bucket $bucketName (region $actualRegion)" -Level Info
                }
            } catch {
                if ($script:Config.DebugBucketTags) {
                    Write-ScriptOutput "No tags for bucket $bucketName (region $actualRegion): $_" -Level Info
                }
                $bucketTags = @()
            }
        }

        $sizes = Convert-BytesToSizes -Bytes $totalBytes

        # ── Per-bucket posture reads ──────────────────────────────────────
        # Six independent calls, each able to fail on its own. $s3PostureFailed counts the ones that failed for a
        # reason OTHER than "the feature is not configured", so a row can say Partial rather than leaving the
        # reader to guess which blank cells were unread. Observed live: 2 of 7 buckets failed the public-access
        # read while every other read on those buckets succeeded.
        $s3PostureReads  = 6
        $s3PostureFailed = 0

        # ── Versioning ────────────────────────────────────────────────────
        $versioningStatus = 'Unknown'
        try {
            $vConfig = Get-S3BucketVersioning -BucketName $bucketName -Credential $Credential -Region $actualRegion -ErrorAction Stop
            $versioningStatus = if ($vConfig -and $vConfig.Status) { $vConfig.Status.Value ?? $vConfig.Status } else { 'Disabled' }
        } catch { $versioningStatus = 'Unknown'; $s3PostureFailed++ }

        # ── Public access block ───────────────────────────────────────────
        # All FOUR booleans are published raw. Collapsing them into one PublicAccessBlocked was a judgement about
        # what "blocked" means, and it hid WHICH protection was missing. Verified live: a real bucket returns all
        # four nested under .PublicAccessBlockConfiguration.
        $pabAcls = $null; $pabPolicy = $null; $pabIgnore = $null; $pabRestrict = $null
        $publicAccessBlocked = $null
        try {
            $pabResp = Get-S3PublicAccessBlock -BucketName $bucketName -Credential $Credential -Region $actualRegion -ErrorAction Stop
            $pab = if ($pabResp -and $pabResp.PSObject.Properties['PublicAccessBlockConfiguration']) { $pabResp.PublicAccessBlockConfiguration } else { $pabResp }
            if ($pab) {
                $pabAcls     = $(if ($null -ne $pab.BlockPublicAcls)       { [bool]$pab.BlockPublicAcls })
                $pabPolicy   = $(if ($null -ne $pab.BlockPublicPolicy)     { [bool]$pab.BlockPublicPolicy })
                $pabIgnore   = $(if ($null -ne $pab.IgnorePublicAcls)      { [bool]$pab.IgnorePublicAcls })
                $pabRestrict = $(if ($null -ne $pab.RestrictPublicBuckets) { [bool]$pab.RestrictPublicBuckets })
                $publicAccessBlocked = ($pabAcls -and $pabPolicy -and $pabIgnore -and $pabRestrict)
            }
        } catch {
            # No block configuration at all is a MEASURED "nothing is blocked", not an unknown.
            if (Test-CVAwsNotConfiguredError $_) {
                $pabAcls = $false; $pabPolicy = $false; $pabIgnore = $false; $pabRestrict = $false
                $publicAccessBlocked = $false
            } else { $s3PostureFailed++ }
        }

        # ── Replication ───────────────────────────────────────────────────
        # $null, not $false: this used to report "no cross-region replication" whenever the call failed for ANY
        # reason, including AccessDenied. S3 throws ReplicationConfigurationNotFoundError when there genuinely is
        # none, so only that error is a measured absence.
        $replicationEnabled = $null
        try {
            $replConfig = Get-S3BucketReplication -BucketName $bucketName -Credential $Credential -Region $actualRegion -ErrorAction Stop
            $replicationEnabled = [bool]($replConfig -and $replConfig.Rules -and @($replConfig.Rules).Count -gt 0)
        } catch { if (Test-CVAwsNotConfiguredError $_) { $replicationEnabled = $false } else { $s3PostureFailed++ } }

        # ── Lifecycle rules ───────────────────────────────────────────────
        $lifecycleRuleCount = $null
        try {
            $lcRules = Get-S3LifecycleConfiguration -BucketName $bucketName -Credential $Credential -Region $actualRegion -ErrorAction Stop
            $lifecycleRuleCount = if ($lcRules -and $lcRules.Rules) { @($lcRules.Rules).Count } else { 0 }
        } catch { if (Test-CVAwsNotConfiguredError $_) { $lifecycleRuleCount = 0 } else { $s3PostureFailed++ } }

        # ── Encryption ────────────────────────────────────────────────────
        # 'Unknown', NOT 'None', when the read fails. s3-encrypted treats 'None' as a Gap, so the old catch
        # reported a bucket as unencrypted because the API call did not succeed - the worst of the three S3
        # fabrications, since encryption is a Critical-adjacent finding.
        $serverSideEncryption = 'Unknown'
        try {
            $encConfig = Get-S3BucketEncryption -BucketName $bucketName -Credential $Credential -Region $actualRegion -ErrorAction Stop
            if ($encConfig -and $encConfig.ServerSideEncryptionRules -and @($encConfig.ServerSideEncryptionRules).Count -gt 0) {
                # ServerSideEncryptionAlgorithm, NOT SSEAlgorithm. The latter is the REST/JSON field name; the
                # .NET SDK object calls it ServerSideEncryptionAlgorithm, so reading .SSEAlgorithm returned $null
                # and this column was blank on EVERY bucket in every run - meaning s3-encrypted could only ever
                # be Unknown. Confirmed on a live account whose buckets are all AES256.
                $sseDefault = $encConfig.ServerSideEncryptionRules[0].ServerSideEncryptionByDefault
                $sse = if ($sseDefault) { $sseDefault.ServerSideEncryptionAlgorithm } else { $null }
                $serverSideEncryption = if ($sse -and $sse.PSObject.Properties.Name -contains 'Value') { $sse.Value }
                                        elseif ($sse) { [string]$sse }
                                        else { 'None' }
            } else { $serverSideEncryption = 'None' }
        } catch { if (Test-CVAwsNotConfiguredError $_) { $serverSideEncryption = 'None' } else { $s3PostureFailed++ } }

        # ── Object Lock (WORM) ────────────────────────────────────────────
        # S3's immutability control, and the AWS analogue of Azure storage's locked immutability policy. Not
        # collected before, so AWS had no immutability signal for object storage at all. Verified live: absent
        # configuration throws ObjectLockConfigurationNotFoundError, which is a measured 'None'.
        $objectLockEnabled = 'Unknown'
        $objectLockMode    = ''
        $objectLockDays    = $null
        try {
            $olResp = Get-S3ObjectLockConfiguration -BucketName $bucketName -Credential $Credential -Region $actualRegion -ErrorAction Stop
            $ol = if ($olResp -and $olResp.PSObject.Properties['ObjectLockConfiguration']) { $olResp.ObjectLockConfiguration } else { $olResp }
            if ($ol -and "$($ol.ObjectLockEnabled)") {
                $objectLockEnabled = "$($ol.ObjectLockEnabled)"
                if ($ol.Rule -and $ol.Rule.DefaultRetention) {
                    $objectLockMode = "$($ol.Rule.DefaultRetention.Mode)"
                    $objectLockDays = $(if ($ol.Rule.DefaultRetention.Days) { [int]$ol.Rule.DefaultRetention.Days }
                                        elseif ($ol.Rule.DefaultRetention.Years) { [int]$ol.Rule.DefaultRetention.Years * 365 })
                }
            } else { $objectLockEnabled = 'None' }
        } catch { if (Test-CVAwsNotConfiguredError $_) { $objectLockEnabled = 'None' } else { $s3PostureFailed++ } }

        # ── MFA delete ────────────────────────────────────────────────────
        # Comes from the versioning response already fetched above - no extra call.
        # A successfully read versioning config that omits EnableMfaDelete means MFA delete is OFF - measured,
        # not unknown. Blank is reserved for the case where the versioning read itself failed.
        $mfaDelete = $(if ($null -ne $vConfig -and $null -ne $vConfig.EnableMfaDelete) { [bool]$vConfig.EnableMfaDelete }
                       elseif ($null -ne $vConfig) { $false })

        # ── Protection status inference ───────────────────────────────────
        $s3ProtectionStatus = if ($replicationEnabled -and $versioningStatus -eq 'Enabled') { 'Protected' }
                              elseif ($versioningStatus -eq 'Enabled') { 'Versioned' }
                              elseif ($lifecycleRuleCount -gt 0) { 'Lifecycle-Only' }
                              else { 'Unprotected' }

        $s3Obj = [PSCustomObject]@{
            AwsAccountId          = "$($AccountInfo.Account)"
            AwsAccountAlias       = $AccountAlias
            Region                = $actualRegion
            BucketName            = $bucketName
            ObjectCount           = $objectCount
            CreationDate          = if ($Item.CreationDate) { $Item.CreationDate } else { $null }
            VersioningStatus      = $versioningStatus
            MfaDeleteEnabled      = $mfaDelete
            # All four public-access booleans, published raw. PublicAccessBlocked is kept as the AND of them for
            # continuity, but the four are what tell you WHICH protection is missing.
            PublicAccessBlocked   = $publicAccessBlocked
            BlockPublicAcls       = $pabAcls
            BlockPublicPolicy     = $pabPolicy
            IgnorePublicAcls      = $pabIgnore
            RestrictPublicBuckets = $pabRestrict
            ReplicationEnabled    = $replicationEnabled
            LifecycleRuleCount    = $lifecycleRuleCount
            ServerSideEncryption  = $serverSideEncryption
            # Object Lock: S3's WORM control. 'Enabled' | 'None' | 'Unknown'.
            ObjectLockEnabled     = $objectLockEnabled
            ObjectLockMode        = $objectLockMode
            ObjectLockRetentionDays = $objectLockDays
            # Ok = all six posture reads succeeded; Partial = some failed for a reason other than "not
            # configured"; Failed = none succeeded. Tells the reader which blank cells above were unread.
            S3PostureDataStatus   = $(if ($s3PostureFailed -eq 0) { 'Ok' }
                                      elseif ($s3PostureFailed -ge $s3PostureReads) { 'Failed' }
                                      else { 'Partial' })
            ProtectionStatus      = $s3ProtectionStatus
            SizeGiB               = $sizes.SizeGiB
            SizeTiB               = $sizes.SizeTiB
            SizeGB                = $sizes.SizeGB
            SizeTB                = $sizes.SizeTB
        }

        foreach ($storageClass in $storageClasses) {
            $classSizeBytes = if ($classBytes.ContainsKey($storageClass)) { $classBytes[$storageClass] } else { 0.0 }
            $classSizes = Convert-BytesToSizes -Bytes $classSizeBytes

            Add-Member -InputObject $s3Obj -NotePropertyName "${storageClass}_SizeGiB" -NotePropertyValue $classSizes.SizeGiB -Force
            Add-Member -InputObject $s3Obj -NotePropertyName "${storageClass}_SizeGB" -NotePropertyValue $classSizes.SizeGB -Force
            Add-Member -InputObject $s3Obj -NotePropertyName "${storageClass}_SizeTiB" -NotePropertyValue $classSizes.SizeTiB -Force
            Add-Member -InputObject $s3Obj -NotePropertyName "${storageClass}_SizeTB" -NotePropertyValue $classSizes.SizeTB -Force
        }

        Add-TagProperties -Object $s3Obj -Tags $bucketTags

        return $s3Obj
    }
    catch {
        Write-ScriptOutput "Failed to process S3 bucket $($Item.BucketName) : $_" -Level Warning
        return $null
    }
}

function Process-EFSFileSystem {
    param($Item, $Credential, $Region, $AccountInfo, $AccountAlias)

    $efsSizeBytes = Get-EFSFileSystemSize -EFS $Item -Credential $Credential -Region $Region

    $efsTags = @()
    try {
        if (Get-Command "Get-EFSResourceTag" -ErrorAction SilentlyContinue) {
            $efsTags = Get-EFSResourceTag -ResourceId $Item.FileSystemArn -Credential $Credential -Region $Region -ErrorAction Stop
        } else {
            $efsTags = Get-EFSTag -FileSystemId $Item.FileSystemId -Credential $Credential -Region $Region -ErrorAction Stop -WarningAction SilentlyContinue
        }
    }
    catch {
        Write-ScriptOutput "Failed to get tags for EFS $($Item.FileSystemId)" -Level Warning
    }

    $sizes = Convert-BytesToSizes -Bytes $efsSizeBytes

    # ── EFS backup policy ─────────────────────────────────────────────
    $backupPolicyStatus = 'Unknown'
    try {
        $bp = Get-EFSBackupPolicy -FileSystemId $Item.FileSystemId -Credential $Credential -Region $Region -ErrorAction Stop
        $backupPolicyStatus = if ($bp -and $bp.BackupPolicy -and $bp.BackupPolicy.Status) {
            $bp.BackupPolicy.Status.Value ?? $bp.BackupPolicy.Status
        } else { 'DISABLED' }
    } catch { $backupPolicyStatus = 'Unknown' }

    $efsEncrypted = if ($Item.Encrypted -ne $null) { [bool]$Item.Encrypted } else { $null }
    $throughputMode = if ($Item.ThroughputMode) { $Item.ThroughputMode.Value ?? $Item.ThroughputMode } else { $null }

    # ── AWS Backup coverage + cross-region replication ─────────────────────
    $efsBackup = Resolve-AWSBackupProtection -Credential $Credential -Region $Region `
                    -ResourceArn $Item.FileSystemArn -Identifier $Item.FileSystemId -ResourceType 'EFS'
    # EFS replication to another region is its cross-region redundancy signal. Absence throws, which is a
    # measured 'None' rather than an unknown.
    $efsReplication = 'Unknown'
    try {
        $rc = Get-EFSReplicationConfiguration -FileSystemId $Item.FileSystemId -Credential $Credential -Region $Region -ErrorAction Stop
        $efsReplication = $(if (@($rc).Count) { 'Configured' } else { 'None' })
    } catch { if (Test-CVAwsNotConfiguredError $_) { $efsReplication = 'None' } }

    $efsProtectionStatus = if ($backupPolicyStatus -eq 'ENABLED' -or $efsBackup.Protected) { 'Protected' }
                           elseif ($backupPolicyStatus -eq 'Unknown' -or $efsBackup.Status -ne 'Ok') { 'Unknown' }
                           else { 'Unprotected' }

    $efsObj = [PSCustomObject]@{
        AwsAccountId       = $AccountInfo.Account
        AwsAccountAlias    = $AccountAlias
        Region             = $Region
        FileSystemId       = $Item.FileSystemId
        CreationTime       = $Item.CreationTime
        PerformanceMode    = if ($Item.PerformanceMode -and $Item.PerformanceMode.PSObject.Properties.Name -contains 'Value') { $Item.PerformanceMode.Value } else { [string]$Item.PerformanceMode }
        ThroughputMode     = $throughputMode
        State              = if ($Item.LifeCycleState -and $Item.LifeCycleState.PSObject.Properties.Name -contains 'Value') { $Item.LifeCycleState.Value } else { [string]$Item.LifeCycleState }
        Encrypted          = $efsEncrypted
        BackupPolicyStatus = $backupPolicyStatus
        AWSBackupProtected = $efsBackup.Protected
        # AWS Backup Vault Lock - region-scoped immutability. Locked vaults cannot have recovery points
        # deleted or retention shortened, even by an admin: the AWS analogue of Azure vault immutability.
        BackupVaultAnyLocked    = $vaultLock.AnyLocked
        # Why a blank neighbouring cell is blank. DaysSinceLastBackup blank could mean 'no recovery point
        # exists' OR 'the AWS Backup list could not be read' - these two columns say which.
        BackupDataStatus        = $efsBackup.Status
        VaultLockDataStatus     = $vaultLock.Status
        BackupVaultLockedCount  = $vaultLock.LockedCount
        BackupVaultMinRetentionDays = $vaultLock.MinRetentionDays
        AwsBackupLastBackupUtc = $(if ($efsBackup.LastBackupTime) { ([datetime]$efsBackup.LastBackupTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { '' })
        ReplicationStatus  = $efsReplication
        ProtectionStatus   = $efsProtectionStatus
        SizeGiB            = $sizes.SizeGiB
        SizeTiB            = $sizes.SizeTiB
        SizeGB             = $sizes.SizeGB
        SizeTB             = $sizes.SizeTB
    }

    Add-TagProperties -Object $efsObj -Tags $efsTags

    return $efsObj
}

function Process-FSXFileSystem {
    param($Item, $Credential, $Region, $AccountInfo, $AccountAlias)

    $fsxTags = @()
    try {
        if ($Item.ResourceARN -and $Item.ResourceARN.Trim() -ne "") {
            if (Get-Command "Get-FSXResourceTag" -ErrorAction SilentlyContinue) {
                $fsxTags = Get-FSXResourceTag -ResourceArn $Item.ResourceARN -Credential $Credential -Region $Region -ErrorAction Stop
                Write-ScriptOutput "Retrieved $($fsxTags.Count) tags for FSx $($Item.FileSystemId) via ResourceTag API" -Level Info
            } else {
                Write-ScriptOutput "Get-FSXResourceTag command not available for FSx $($Item.FileSystemId)" -Level Warning
            }
        } else {
            Write-ScriptOutput "No ResourceARN available for FSx $($Item.FileSystemId), skipping tag retrieval" -Level Warning
        }
    }
    catch {
        Write-ScriptOutput "Failed to get tags for FSx $($Item.FileSystemId): $($_.Exception.Message)" -Level Warning
        try {
            if ($Item.Tags -and $Item.Tags.Count -gt 0) {
                $fsxTags = $Item.Tags
                Write-ScriptOutput "Retrieved $($fsxTags.Count) tags for FSx $($Item.FileSystemId) from item properties" -Level Info
            }
        }
        catch {
            Write-ScriptOutput "Alternative tag retrieval also failed for FSx $($Item.FileSystemId)" -Level Warning
        }
    }

    $capacityBytes = $Item.StorageCapacity * 1GB
    $sizes = Convert-BytesToSizes -Bytes $capacityBytes

    $fsxObj = [PSCustomObject]@{
        AwsAccountId = "$($AccountInfo.Account)"
        AwsAccountAlias = $AccountAlias
        Region = $Region
        FileSystemId = $Item.FileSystemId
        Type = $Item.FileSystemType
        State = $Item.Lifecycle
        CreationTime = $Item.CreationTime
        StorageCapacity = $Item.StorageCapacity
        StorageCapacityGiB = $sizes.SizeGiB
        StorageCapacityTiB = $sizes.SizeTiB
        StorageCapacityGB = $sizes.SizeGB
        StorageCapacityTB = $sizes.SizeTB
    }

    Add-TagProperties -Object $fsxObj -Tags $fsxTags

    return $fsxObj
}

function Process-FSXStorageVirtualMachine {
    param($Item, $Credential, $Region, $AccountInfo, $AccountAlias)
    try {
        $svmId = $null
        $svmName = $null
        $svmState = $null
        $svmUUID = $null
        $fileSystemId = $null
        $endpointIps = $null

        if ($Item -is [string]) {
            $svmName = $Item
        } else {
            $svmId   = $Item.StorageVirtualMachineId ?? $Item.SvmId
            $svmName = $Item.Name ?? $Item.StorageVirtualMachineName
            $svmState = $Item.Lifecycle ?? $Item.OperationalState
            $svmUUID = $Item.UUID ?? $Item.StorageVirtualMachineArn
            $fileSystemId = $Item.FileSystemId

            try {
                if ($Item.ManagementEndpoint -and $Item.ManagementEndpoint.IpAddresses) {
                    $endpointIps = ($Item.ManagementEndpoint.IpAddresses -join ";")
                } elseif ($Item.Endpoints -and $Item.Endpoints.Nfs) {
                    $endpointIps = ($Item.Endpoints.Nfs -join ";")
                }
            } catch {}
        }

        $svmTags = @()
        try {
            if ($Item.ResourceARN -and (Get-Command Get-FSXResourceTag -ErrorAction SilentlyContinue)) {
                $svmTags = Get-FSXResourceTag -ResourceArn $Item.ResourceARN -Credential $Credential -Region $Region -ErrorAction SilentlyContinue
            } elseif ($Item.Tags) {
                $svmTags = $Item.Tags
            }
        } catch {}

        $volumes = @()
        try {
            $allVolumes = Get-FSXVolume -Region $Region -Credential $Credential -ErrorAction Stop
            if ($allVolumes) {
                $volumes = $allVolumes | Where-Object {
                    $_.OntapConfiguration -and $_.OntapConfiguration.StorageVirtualMachineId -eq $svmId
                }
            }
            Write-ScriptOutput ("DEBUG: Found {0} volume(s) for SVM {1}" -f ($volumes.Count), $svmId) -Level Info
        } catch {
            Write-ScriptOutput ("DEBUG: Get-FSXVolume failed: {0}" -f $_.Exception.Message) -Level Warning
        }

        function Get-VolumeSizeBytes {
            param($v)
            if (-not $v) { return 0 }
            if ($v.OntapConfiguration) {
                if ($v.OntapConfiguration.SizeInBytes) { return [double]$v.OntapConfiguration.SizeInBytes }
                if ($v.OntapConfiguration.SizeInMegabytes) { return [double]$v.OntapConfiguration.SizeInMegabytes * 1024 * 1024 }
            }
            if ($v.SizeInBytes) { return [double]$v.SizeInBytes }
            if ($v.SizeInMegabytes) { return [double]$v.SizeInMegabytes * 1024 * 1024 }
            if ($v.SizeGiB) { return [double]$v.SizeGiB * 1024 * 1024 * 1024 }
            return 0
        }

        $totalBytes = ($volumes | ForEach-Object { Get-VolumeSizeBytes $_ } | Measure-Object -Sum).Sum

        $volumeCount = $volumes.Count
        $volumeDetails = $volumes | ForEach-Object {
            $bytes = Get-VolumeSizeBytes $_
            $sizeGiB = [math]::Round($bytes / 1GB, 2)
            "$($_.VolumeId):${sizeGiB}GiB"
        }

        $sizes = Convert-BytesToSizes -Bytes $totalBytes

        $obj = [PSCustomObject]@{
            AwsAccountId          = "$($AccountInfo.Account)"
            AwsAccountAlias       = $AccountAlias
            Region                = $Region
            FileSystemId          = $fileSystemId
            StorageVirtualMachineId = $svmId
            Name                  = $svmName
            OperationalState      = $svmState
            UUID                  = $svmUUID
            VolumeCount           = $volumeCount
            VolumesSizeGiB        = $sizes.SizeGiB
            VolumesSizeTiB        = $sizes.SizeTiB
            VolumesSizeGB         = $sizes.SizeGB
            VolumesSizeTB         = $sizes.SizeTB
            VolumeDetails         = ($volumeDetails -join ";")
        }

        Add-TagProperties -Object $obj -Tags $svmTags
        return $obj
    } catch {
        Write-ScriptOutput "Failed to process FSx ONTAP SVM item: $_" -Level Warning
        return $null
    }
}

function Ensure-Kubectl {
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        Write-ScriptOutput "kubectl not found. Attempting to install for PVC/node enumeration." -Level Warning

        # Delegated to common/CVSizing.Kubectl.ps1. Previously this auto-installed on Windows only (into a
        # hardcoded C:\kubectl) and the non-Windows branch just said "install manually" - so -Types EKS on
        # macOS/Linux silently produced no persistent-volume data, unlike the Azure and GCP scripts which both
        # auto-provision.
        $k = Install-CVKubectl
        if ($k.Installed) {
            $script:KubectlInstalled = ($k.Source -eq 'Downloaded')   # only clean up what WE installed
            $script:KubectlDir       = $k.Dir
            Write-ScriptOutput "kubectl ready at $($k.Path) [$($k.Platform), $($k.Source)]" -Level Success
        } else {
            Write-ScriptOutput "Could not provision kubectl for $($k.Platform): $($k.Error)" -Level Warning
            Write-ScriptOutput "Install kubectl from https://kubernetes.io/docs/tasks/tools/ and add it to PATH; EKS persistent-volume data will be skipped." -Level Warning
        }
    } else {
        Write-ScriptOutput "kubectl is already available." -Level Info
    }
}

function Convert-K8sSizeToBytes {
     param([string]$Size)
     if (-not $Size) { return 0 }
     $s = $Size.Trim()
     if ($s -match '^(?<num>[\d\.]+)(?<unit>Ei|Pi|Ti|Gi|Mi|Ki|E|P|T|G|M|K|i)?$') {
         $num = [double]$matches['num']
         $unit = $matches['unit']
         switch ($unit) {
             'Ei' { return $num * [math]::Pow(1024,6) }
             'Pi' { return $num * [math]::Pow(1024,5) }
             'Ti' { return $num * [math]::Pow(1024,4) }
             'Gi' { return $num * [math]::Pow(1024,3) }
             'Mi' { return $num * [math]::Pow(1024,2) }
             'Ki' { return $num * 1024 }
             'E'  { return $num * 1e18 }
             'P'  { return $num * 1e15 }
             'T'  { return $num * 1e12 }
             'G'  { return $num * 1e9 }
             'M'  { return $num * 1e6 }
             'K'  { return $num * 1e3 }
             default { return $num }
         }
     } else {
         # try to parse numeric-only
         try { return [double]$s } catch { return 0 }
     }
 }

function Get-AllEKSClusters {
    param(
        $Credential,
        [string]$Region,
        $AccountInfo,
        $AccountAlias
    )

    try {
        if (-not (Get-Command Get-EKSClusterList -ErrorAction SilentlyContinue)) {
            Write-ScriptOutput "EKS: Get-EKSClusterList command not available. Skipping EKS in region $Region." -Level Warning
            return
        }

        # Include Credential when listing clusters so cross-account/profile contexts are correct
        $clusterNames = Get-EKSClusterList -Credential $Credential -Region $Region -ErrorAction Stop

        if (-not $clusterNames -or $clusterNames.Count -eq 0) {
            Write-ScriptOutput "EKS: No clusters found in region $Region" -Level Info
            return
        }

        foreach ($clusterName in $clusterNames) {
            try {
                $result = Process-EKSCluster -Item $clusterName -Credential $Credential -Region $Region -AccountInfo $AccountInfo -AccountAlias $AccountAlias
                if ($result) { $result }
            } catch {
                Write-ScriptOutput "EKS: Failed processing cluster $clusterName in $Region : $_" -Level Warning
            }
        }
    } catch {
        Write-ScriptOutput "EKS: Error fetching clusters for $Region : $_" -Level Warning
    }
}

function Process-EKSCluster {
    param(
        $Item,
        $Credential,
        [string]$Region,
        $AccountInfo,
        [string]$AccountAlias,
        [string]$RoleArn
    )

    $clusterName = if ($Item -is [string]) { $Item }
                   elseif ($Item.Name) { $Item.Name }
                   elseif ($Item.name) { $Item.name }
                   elseif ($Item.ClusterName) { $Item.ClusterName }
                   else { $null }

    if (-not $clusterName) {
        $itemType = if ($Item) { $Item.GetType().FullName } else { 'Null' }
        Write-ScriptOutput "EKS: Cluster name not found in item (type=${itemType}), skipping" -Level Warning
        return $null
    }

    $kubernetesVersion = "Unknown"
    try {
        $clusterInfo = Get-EKSCluster -Name $clusterName -Credential $Credential -Region $Region -ErrorAction Stop
        $kubernetesVersion = $clusterInfo.Version ?? "Unknown"
    } catch {
        Write-ScriptOutput "EKS: Failed to get cluster details for ${clusterName}: $_" -Level Warning
    }

    $tmpKube = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "kubeconfig_${clusterName}_${([guid]::NewGuid())}.yaml")

    Ensure-Kubectl

    $oldEnv = @{
        AWS_ACCESS_KEY_ID     = $env:AWS_ACCESS_KEY_ID
        AWS_SECRET_ACCESS_KEY = $env:AWS_SECRET_ACCESS_KEY
        AWS_SESSION_TOKEN     = $env:AWS_SESSION_TOKEN
    }

    try {
        $accessKey = $null; $secretKey = $null; $sessionToken = $null

        if ($Credential) {
            if ($Credential.PSObject.Methods.Name -contains 'GetCredentials') {
                try {
                    $credsObj = $Credential.GetCredentials()
                    if ($credsObj) {
                        $accessKey    = $credsObj.AccessKey   ?? $accessKey
                        $secretKey    = $credsObj.SecretKey   ?? $secretKey
                        $sessionToken = $credsObj.Token       ?? $credsObj.SessionToken ?? $sessionToken
                    }
                } catch {}
            }

            $accessKey    = $accessKey    ?? $Credential.AccessKey ?? $Credential.AccessKeyId
            $secretKey    = $secretKey    ?? $Credential.SecretKey ?? $Credential.SecretAccessKey
            $sessionToken = $sessionToken ?? $Credential.SessionToken ?? $Credential.Token
        }

        if (-not $accessKey -and $AccountInfo -and $AccountInfo.AccessKey) {
            $accessKey    = $AccountInfo.AccessKey
            $secretKey    = $AccountInfo.SecretKey
            $sessionToken = $AccountInfo.SessionToken
        }

        if ($accessKey -and $secretKey) {
            $env:AWS_ACCESS_KEY_ID     = $accessKey
            $env:AWS_SECRET_ACCESS_KEY = $secretKey
            if ($sessionToken) { $env:AWS_SESSION_TOKEN = $sessionToken } else { Remove-Item Env:AWS_SESSION_TOKEN -ErrorAction SilentlyContinue }
            Write-ScriptOutput "EKS: Exported AWS env vars for cluster '${clusterName}' (region ${Region})" -Level Info
        }

        $awsArgs = @('eks','update-kubeconfig','--name',$clusterName,'--region',$Region,'--kubeconfig',$tmpKube)
        if ($RoleArn) { $awsArgs += @('--role-arn',$RoleArn) }
        $updateResult = & aws @awsArgs 2>&1
         if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tmpKube)) {
             Write-ScriptOutput "EKS: Failed to update kubeconfig for ${clusterName} in ${Region}: ${updateResult}" -Level Warning
             return [PSCustomObject]@{
                 AwsAccountId    = "$($AccountInfo.Account)"
                 AwsAccountAlias = $AccountInfo.AccountAlias
                 Region          = $Region
                 ClusterName     = $clusterName
                 KubernetesVersion = $kubernetesVersion
                 Count           = 1
                 PVCCount        = 0
                 SizeGiB         = 0
                 SizeTiB         = 0
                 SizeGB          = 0
                 SizeTB          = 0
                 PVCDetails      = ""
                 NodeCount       = 0
                 NodeDetails     = ""
             }
         }

        $pvcCount = 0; $sizeBytes = 0; $pvcDetails = @()

        if (Get-Command kubectl -ErrorAction SilentlyContinue) {
            $env:KUBECONFIG = $tmpKube
            $pvcRaw = & kubectl get pvc --all-namespaces -o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name,VOLUME:.spec.volumeName,CAPACITY:.spec.resources.requests.storage,STATUS:.status.phase" 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-ScriptOutput "EKS: kubectl get pvc failed for ${clusterName}, skipping PVCs: ${pvcRaw}" -Level Warning
            } elseif ($pvcRaw) {
                $lines = $pvcRaw -split "`n" | Where-Object { $_ -and $_ -notmatch '^NAMESPACE' }  # Skip header
                foreach ($line in $lines) {
                    if ($line -match '^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)$') {
                        $namespace = $matches[1]
                        $name = $matches[2]
                        $capacity = $matches[4]
                        $status = $matches[5]
                        if ($capacity -and $capacity -ne '<none>') {
                            $bytes = Convert-K8sSizeToBytes -Size $capacity
                            if ($bytes -gt 0) {
                                $sizeBytes += $bytes
                                $pvcCount++
                                $pvcDetails += ("${namespace}/${name}:${capacity}:${status}")
                            }
                        }
                    }
                }
            }
        } else {
            Write-ScriptOutput "kubectl not available; skipping PVC enumeration for ${clusterName}" -Level Info
        }

        $nodeCount = 0
        $nodeDetails = @()
        if (Get-Command kubectl -ErrorAction SilentlyContinue) {
            $env:KUBECONFIG = $tmpKube
            # Get node names and provider IDs
            $nodeRaw = & kubectl get nodes -o custom-columns="NAME:.metadata.name,PROVIDER_ID:.spec.providerID" 2>&1
            if ($LASTEXITCODE -eq 0 -and $nodeRaw) {
                $nodeLines = $nodeRaw | Where-Object { $_ -and $_.Trim() -ne "" -and -not $_.StartsWith("NAME") }
                $nodeCount = $nodeLines.Count
                foreach ($line in $nodeLines) {
                    $parts = $line -split '\s+', 2
                    if ($parts.Count -ge 2) {
                        $nodeName = $parts[0].Trim()
                        $providerId = $parts[1].Trim()
                        $instanceType = '<none>'
                        if ($providerId -and $providerId -match 'aws://.*/(.*)') {
                            $instanceId = $matches[1]
                            try {
                                $ec2Instance = Get-EC2Instance -InstanceId $instanceId -Credential $Credential -Region $Region -ErrorAction Stop
                                if ($ec2Instance -and $ec2Instance.Instances) {
                                    $instanceType = $ec2Instance.Instances[0].InstanceType.Value
                                }
                            } catch {
                                Write-ScriptOutput "EKS: Failed to get instance type for node ${nodeName} (ID: ${instanceId}): $_" -Level Warning
                            }
                        }
                        $nodeDetails += "${nodeName}:${instanceType}"
                    }
                }
            } else {
                Write-ScriptOutput "EKS: kubectl get nodes failed for ${clusterName}, skipping nodes: ${nodeRaw}" -Level Warning
            }
        } else {
            Write-ScriptOutput "kubectl not available; skipping node enumeration for ${clusterName}" -Level Info
        }

        $sizeGiB = [math]::Round($sizeBytes / 1GB, 4)
        $sizeTiB = [math]::Round($sizeGiB / 1024, 6)
        $sizeGB  = [math]::Round($sizeGiB * 1.073741824, 4)
        $sizeTB  = [math]::Round($sizeGB / 1024, 6)

        return [PSCustomObject]@{
            AwsAccountId    = "$($AccountInfo.Account)"
            AwsAccountAlias = $AccountInfo.AccountAlias
            Region          = $Region
            ClusterName     = $clusterName
            KubernetesVersion = $kubernetesVersion
            PVCCount        = $pvcCount
            NodeCount       = $nodeCount
            SizeGiB         = $sizeGiB
            SizeTiB         = $sizeTiB
            SizeGB          = $sizeGB
            SizeTB          = $sizeTB
            PVCDetails      = ($pvcDetails -join ";")
            NodeDetails     = ($nodeDetails -join ";")
        }

    } catch {
        Write-ScriptOutput "EKS: Exception processing cluster ${clusterName}: $_" -Level Warning
        return $null
    } finally {
        try { if (Test-Path $tmpKube) { Remove-Item $tmpKube -Force -ErrorAction SilentlyContinue } } catch {}
        Remove-Item Env:KUBECONFIG -ErrorAction SilentlyContinue
        foreach ($k in $oldEnv.Keys) {
            if ($null -ne $oldEnv[$k]) { ${env:$k} = $oldEnv[$k] } else { Remove-Item Env:$k -ErrorAction SilentlyContinue }
        }
    }
}

function Process-UnattachedVolume {
    param($Item, $Credential, $Region, $AccountInfo, $AccountAlias)

    $volumeTags = @()
    try {
        $tagFilter = @{
            Name = "resource-id"
            Values = @($Item.VolumeId)
        }
        $tagResponse = Get-EC2Tag -Filter $tagFilter -Credential $Credential -Region $Region -ErrorAction Stop
        $volumeTags = $tagResponse

        if ($volumeTags -and $volumeTags.Count -gt 0) {
            Write-ScriptOutput "Retrieved $($volumeTags.Count) tags for volume $($Item.VolumeId)" -Level Info
        }
    }
    catch {
        try {
            $volumeDetail = Get-EC2Volume -VolumeId $Item.VolumeId -Credential $Credential -Region $Region -ErrorAction Stop
            if ($volumeDetail -and $volumeDetail.Tags) {
                $volumeTags = $volumeDetail.Tags
                Write-ScriptOutput "Retrieved tags via volume detail for $($Item.VolumeId)" -Level Info
            }
        }
        catch {
            Write-ScriptOutput "Failed to get tags for volume $($Item.VolumeId): $($_.Exception.Message)" -Level Warning
        }
    }

    $volumeBytes = $Item.Size * 1GB
    $sizes = Convert-BytesToSizes -Bytes $volumeBytes

    $volEncrypted = if ($Item.Encrypted -ne $null) { [bool]$Item.Encrypted } else { $null }

    $volumeObj = [PSCustomObject]@{
        AwsAccountId    = $AccountInfo.Account
        AwsAccountAlias = $AccountAlias
        Region          = $Region
        VolumeId        = $Item.VolumeId
        VolumeType      = if ($Item.VolumeType -and $Item.VolumeType.PSObject.Properties.Name -contains 'Value') { $Item.VolumeType.Value } else { [string]$Item.VolumeType }
        Size            = $Item.Size
        State           = if ($Item.State -and $Item.State.PSObject.Properties.Name -contains 'Value') { $Item.State.Value } else { [string]$Item.State }
        Encrypted       = $volEncrypted
        CreateTime      = $Item.CreateTime
        DaysSinceCreation = if ($Item.CreateTime) { [math]::Round((New-TimeSpan -Start $Item.CreateTime -End (Get-Date)).TotalDays, 0) } else { $null }
        SizeGiB         = $sizes.SizeGiB
        SizeTiB         = $sizes.SizeTiB
        SizeGB          = $sizes.SizeGB
        SizeTB          = $sizes.SizeTB
    }

    Add-TagProperties -Object $volumeObj -Tags $volumeTags

    return $volumeObj
}

function Process-RDSInstance {
    param($Item, $Credential, $Region, $AccountInfo, $AccountAlias)
    try {
        if ($Item.Engine -and ($Item.Engine -match '^(?i:docdb)')) {
            Write-ScriptOutput "Skipping DocumentDB resource (engine='$($Item.Engine)') $($Item.DBInstanceIdentifier)" -Level Info
            return $null
        }

        $sizeGB = 0
        if ($Item.AllocatedStorage) {
            $sizeGB = [double]$Item.AllocatedStorage
        }

        if ($Item.Engine -match '^(?i:aurora)') {
            $sizeGB = 0
        }

        $sizes = Convert-BytesToSizes -Bytes ($sizeGB * 1GB)

        try {
            $clusterId = if ($Item.DBClusterIdentifier) { $Item.DBClusterIdentifier } else { $null }
            if (-not $clusterId -and $Item.DBInstanceIdentifier) {
                $desc = Get-RDSDBInstance -DBInstanceIdentifier $Item.DBInstanceIdentifier -Credential $Credential -Region $Region -ErrorAction SilentlyContinue
                if ($desc -and $desc.DBInstance -and $desc.DBInstance.DBClusterIdentifier) { $clusterId = $desc.DBInstance.DBClusterIdentifier }
            }
            if ($clusterId) {
                $cwParams = @{
                    Namespace  = 'AWS/RDS'
                    MetricName = 'VolumeBytesUsed'
                    Dimension  = @{ Name = 'DBClusterIdentifier'; Value = $clusterId }
                    StartTime  = $utcStartTime
                    EndTime    = $utcEndTime
                    Period     = 86400
                    Statistic  = 'Maximum'
                    Credential = $Credential
                    Region     = $Region
                }
                $metric = Get-SafeCWMetricStatistic -Namespace 'AWS/RDS' -MetricName 'VolumeBytesUsed' -Dimensions @(@{ Name = 'DBClusterIdentifier'; Value = $clusterId }) -Period 86400 -Statistics 'Maximum' -StartTime $utcStartTime -EndTime $utcEndTime -Credential $Credential -Region $Region

                if ($metric -and $metric.Datapoints) {
                    $mv = ($metric.Datapoints | Sort-Object Timestamp -Descending | Select-Object -First 1).Maximum
                    if ($mv -and $mv -gt 0) {
                        $sizes = Convert-BytesToSizes -Bytes ([double]$mv)
                        Write-ScriptOutput "Aurora cluster storage-used via CloudWatch for ${clusterId}: $([math]::Round($mv/1GB,2)) GB" -Level Info
                    }
                }
                if ($sizes.SizeGiB -eq 0) {
                    $cinfo = Get-RDSDBCluster -DBClusterIdentifier $clusterId -Credential $Credential -Region $Region -ErrorAction SilentlyContinue
                    if ($cinfo) {
                        if ($cinfo.StorageUsage) {
                            $sizes = Convert-BytesToSizes -Bytes ($cinfo.StorageUsage * 1GB)
                            Write-ScriptOutput "Aurora cluster used storage via DescribeDBCluster for ${clusterId}: $($cinfo.StorageUsage) GB" -Level Info
                        } elseif ($cinfo.AllocatedStorage) {
                            $sizes = Convert-BytesToSizes -Bytes ($cinfo.AllocatedStorage * 1GB)
                            Write-ScriptOutput "Aurora cluster allocated storage via DescribeDBCluster for ${clusterId}: $($cinfo.AllocatedStorage) GB" -Level Info
                        }
                    }
                }
            }
        } catch {}

        # ── Backup & protection fields ────────────────────────────────────
        # $null, not $false/0, when the API did not report the field. DescribeDBInstances virtually always
        # returns these, so the coalesce is a safety net - but a safety net that invents 'no Multi-AZ',
        # 'not encrypted' and 'no deletion protection' is worse than a blank cell, because each becomes an
        # affirmative Gap in the report.
        $backupRetentionDays = if ($null -ne $Item.BackupRetentionPeriod) { [int]$Item.BackupRetentionPeriod } else { $null }
        $automatedBackupsEnabled = $(if ($null -eq $backupRetentionDays) { $null } else { $backupRetentionDays -gt 0 })
        $multiAZ = if ($null -ne $Item.MultiAZ) { [bool]$Item.MultiAZ } else { $null }
        $storageEncrypted = if ($null -ne $Item.StorageEncrypted) { [bool]$Item.StorageEncrypted } else { $null }
        $deletionProtection = if ($null -ne $Item.DeletionProtection) { [bool]$Item.DeletionProtection } else { $null }
        $dbStatus = if ($Item.DBInstanceStatus) { $Item.DBInstanceStatus } else { 'unknown' }

        # ── AWS Backup coverage ───────────────────────────────────────────
        # Was [bool](Get-AWSBackupRecoveryPoint ...), which collapsed the tri-state at the boundary: that helper
        # returns $null both for "no recovery point" AND for "the call failed / the cmdlet is missing", and
        # [bool]$null is $false - so an unreadable AWS Backup API reported the database as not covered.
        # The region-scoped protected-resource list is also ONE call per region instead of one per instance, and
        # it carries LastBackupTime.
        $rdsBackup = Resolve-AWSBackupProtection -Credential $Credential -Region $Region `
                        -ResourceArn $Item.DBInstanceArn -ResourceType 'RDS'
        $awsBackupProtected = $rdsBackup.Protected
        $awsBackupLastTime  = $rdsBackup.LastBackupTime

        $protectionStatus = if ($awsBackupProtected) { 'Protected' }
                            elseif ($automatedBackupsEnabled) { 'Automated-Backup' }
                            elseif ($null -eq $automatedBackupsEnabled -or $rdsBackup.Status -ne 'Ok') { 'Unknown' }
                            else { 'Unprotected' }

        # ── PITR: RDS supports point-in-time recovery when automated backups are enabled.
        # LatestRestorableTime shows exactly how far back you can restore.
        $pitrEnabled = $automatedBackupsEnabled  # RDS PITR is active when BackupRetentionPeriod > 0 ($null if unread)
        $latestRestorableTime = if ($Item.LatestRestorableTime) { $Item.LatestRestorableTime.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }

        $rdsObj = [PSCustomObject]@{
            AwsAccountId            = "$($AccountInfo.Account)"
            AwsAccountAlias         = $AccountAlias
            Region                  = $Region
            DBInstanceIdentifier    = $Item.DBInstanceIdentifier
            Engine                  = $Item.Engine
            EngineVersion           = $Item.EngineVersion
            DBInstanceClass         = $Item.DBInstanceClass
            DBInstanceStatus        = $dbStatus
            MultiAZ                 = $multiAZ
            StorageEncrypted        = $storageEncrypted
            DeletionProtection      = $deletionProtection
            BackupRetentionDays     = $backupRetentionDays
            AutomatedBackupsEnabled = $automatedBackupsEnabled
            PITREnabled             = $pitrEnabled
            LatestRestorableTime    = $latestRestorableTime
            AWSBackupProtected      = $awsBackupProtected
            # AWS Backup Vault Lock - region-scoped immutability. Locked vaults cannot have recovery points
            # deleted or retention shortened, even by an admin: the AWS analogue of Azure vault immutability.
            BackupVaultAnyLocked    = $vaultLock.AnyLocked
            # Why a blank neighbouring cell is blank. DaysSinceLastBackup blank could mean 'no recovery point
            # exists' OR 'the AWS Backup list could not be read' - these two columns say which.
            BackupDataStatus        = $rdsBackup.Status
            VaultLockDataStatus     = $vaultLock.Status
            BackupVaultLockedCount  = $vaultLock.LockedCount
            BackupVaultMinRetentionDays = $vaultLock.MinRetentionDays
            AwsBackupLastBackupUtc  = $(if ($awsBackupLastTime) { ([datetime]$awsBackupLastTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { '' })
            ProtectionStatus        = $protectionStatus
            SizeGiB                 = $sizes.SizeGiB
            SizeTiB                 = $sizes.SizeTiB
            SizeGB                  = $sizes.SizeGB
            SizeTB                  = $sizes.SizeTB
        }

        try {
            if (Get-Command Get-RDSTag -ErrorAction SilentlyContinue) {
                $tags = Get-RDSTag -ResourceName $Item.DBInstanceArn -Credential $Credential -Region $Region -ErrorAction Stop
                Add-TagProperties -Object $rdsObj -Tags $tags
            }
        } catch { }

        return $rdsObj
    } catch {
        Write-ScriptOutput "Failed to process RDS instance $($Item.DBInstanceIdentifier): $_" -Level Warning
        return $null
    }
}

function Process-DocumentDBCluster {
    param($Item, $Credential, $Region, $AccountInfo, $AccountAlias)
    try {
        $clusterId = $Item.DBClusterIdentifier
        $engine = if ($Item.Engine) { $Item.Engine } else { "docdb" }

        # Guard: skip Aurora clusters that may surface via fallback API calls
        if ($engine -match '^aurora') {
            Write-ScriptOutput "Skipping Aurora cluster '$clusterId' in DocumentDB processor (engine='$engine')" -Level Info
            return $null
        }

        $engineVersion = if ($Item.EngineVersion) { $Item.EngineVersion } else { "Unknown" }
        $clusterStatus = if ($Item.Status) { $Item.Status } else { "Unknown" }
        
        $instances = @()
        try {
            if (Get-Command Get-DOCDBInstance -ErrorAction SilentlyContinue) {
                $allInstances = Get-DOCDBInstance -Credential $Credential -Region $Region -ErrorAction SilentlyContinue
                $instances = $allInstances | Where-Object { $_.DBClusterIdentifier -eq $clusterId }
            }
        } catch {
            Write-ScriptOutput "Failed to get instances for DocumentDB cluster $clusterId : $_" -Level Warning
        }

        $totalBytes = 0
        try {
            $metric = Get-SafeCWMetricStatistic -Namespace 'AWS/DocDB' -MetricName 'VolumeBytesUsed' -Dimensions @(@{ Name = 'DBClusterIdentifier'; Value = $clusterId }) -Period 86400 -Statistics 'Maximum' -Credential $Credential -Region $Region

            if ($metric -and $metric.Datapoints -and $metric.Datapoints.Count -gt 0) {
                $mv = ($metric.Datapoints | Sort-Object Timestamp -Descending | Select-Object -First 1).Maximum
                if ($mv -and $mv -gt 0) {
                    $totalBytes = [double]$mv
                    Write-ScriptOutput "DocumentDB cluster storage via CloudWatch for ${clusterId}: $([math]::Round($mv/1GB,2)) GB" -Level Info
                }
            }
        } catch {
            Write-ScriptOutput "CloudWatch metrics failed for DocumentDB cluster $clusterId : $($_.Exception.Message)" -Level Warning
        }

        
        if ($totalBytes -eq 0) {
            try {
                if ($Item.StorageUsed) {
                    $totalBytes = [double]$Item.StorageUsed
                } elseif ($Item.AllocatedStorage) {
                    $totalBytes = [double]$Item.AllocatedStorage * 1GB
                } else {
                    if ($clusterStatus -eq "available" -and $instances.Count -gt 0) {
                        $totalBytes = 1GB
                        Write-ScriptOutput "DocumentDB cluster $clusterId - using default 1GB (no metrics available)" -Level Warning
                    }
                }
            } catch {
                Write-ScriptOutput "Failed to get storage from cluster properties for $clusterId" -Level Warning
            }
        }

        $sizes = Convert-BytesToSizes -Bytes $totalBytes
        $instanceCount = $instances.Count
        $instanceTypes = $instances | ForEach-Object { $_.DBInstanceClass } | Sort-Object -Unique
        $availabilityZones = $instances | ForEach-Object { $_.AvailabilityZone } | Where-Object { $_ } | Sort-Object -Unique

        # ── PITR: DocumentDB supports PITR when BackupRetentionPeriod > 0.
        # EarliestRestorableTime / LatestRestorableTime show the actual restore window.
        $docdbBackupDays = if ($Item.BackupRetentionPeriod) { [int]$Item.BackupRetentionPeriod } else { 0 }
        $docdbPitrEnabled = $docdbBackupDays -gt 0
        $docdbLatestRestore = if ($Item.LatestRestorableTime) { $Item.LatestRestorableTime.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }
        $docdbEarliestRestore = if ($Item.EarliestRestorableTime) { $Item.EarliestRestorableTime.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }

        $docdbClusterObj = [PSCustomObject]@{
            AwsAccountId          = "$($AccountInfo.Account)"
            AwsAccountAlias       = $AccountAlias
            Region                = $Region
            DBClusterIdentifier   = $clusterId
            Engine                = $engine
            EngineVersion         = $engineVersion
            ClusterStatus         = $clusterStatus
            InstanceCount         = $instanceCount
            InstanceTypes         = ($instanceTypes -join ";")
            AvailabilityZones     = ($availabilityZones -join ";")
            SizeGiB               = $sizes.SizeGiB
            SizeTiB               = $sizes.SizeTiB
            SizeGB                = $sizes.SizeGB
            SizeTB                = $sizes.SizeTB
            ClusterCreateTime     = if ($Item.ClusterCreateTime) { $Item.ClusterCreateTime } else { $null }
            BackupRetentionPeriod = $docdbBackupDays
            PITREnabled           = $docdbPitrEnabled
            LatestRestorableTime  = $docdbLatestRestore
            EarliestRestorableTime = $docdbEarliestRestore
            PreferredBackupWindow = if ($Item.PreferredBackupWindow) { $Item.PreferredBackupWindow } else { $null }
            PreferredMaintenanceWindow = if ($Item.PreferredMaintenanceWindow) { $Item.PreferredMaintenanceWindow } else { $null }
        }

        try {
            if ($Item.DBClusterArn -and (Get-Command Get-RDSTag -ErrorAction SilentlyContinue)) {
                $tags = Get-RDSTag -ResourceName $Item.DBClusterArn -Credential $Credential -Region $Region -ErrorAction Stop
                Add-TagProperties -Object $docdbClusterObj -Tags $tags
            }
        } catch {
            Write-ScriptOutput "Failed to get tags for DocumentDB cluster $clusterId : $_" -Level Warning
        }

        return $docdbClusterObj
    } catch {
        Write-ScriptOutput "Failed to process DocumentDB cluster $($Item.DBClusterIdentifier): $($_.Exception.Message)" -Level Warning
        return $null
    }
}

function Process-AuroraCluster {
    param($Item, $Credential, $Region, $AccountInfo, $AccountAlias)
    try {
        $clusterId = $Item.DBClusterIdentifier
        # Only Aurora engines — skip plain RDS clusters surfaced by Get-RDSDBCluster
        if ($Item.Engine -notmatch '^aurora') { return $null }

        $totalBytes = 0
        try {
            $metric = Get-SafeCWMetricStatistic -Namespace 'AWS/RDS' -MetricName 'VolumeBytesUsed' `
                -Dimensions @(@{Name='DBClusterIdentifier';Value=$clusterId}) `
                -Period 86400 -Statistics 'Maximum' -Credential $Credential -Region $Region
            if ($metric -and $metric.Datapoints -and $metric.Datapoints.Count -gt 0) {
                $mv = ($metric.Datapoints | Sort-Object Timestamp -Descending | Select-Object -First 1).Maximum
                if ($mv -gt 0) { $totalBytes = [double]$mv }
            }
        } catch { Write-ScriptOutput "CloudWatch metrics failed for Aurora cluster ${clusterId}: $_" -Level Warning }

        $sizes = Convert-BytesToSizes -Bytes $totalBytes
        # ── PITR: Aurora PITR is active when BackupRetentionPeriod > 0.
        # EarliestRestorableTime / LatestRestorableTime show the actual restore window.
        $aurPitrEnabled = ($Item.BackupRetentionPeriod -ne $null) -and ([int]$Item.BackupRetentionPeriod -gt 0)
        $aurLatestRestore = if ($Item.LatestRestorableTime) { $Item.LatestRestorableTime.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }
        $aurEarliestRestore = if ($Item.EarliestRestorableTime) { $Item.EarliestRestorableTime.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }

        $auroraObj = [PSCustomObject]@{
            AwsAccountId          = "$($AccountInfo.Account)"
            AwsAccountAlias       = $AccountAlias
            Region                = $Region
            DBClusterIdentifier   = $clusterId
            Engine                = $Item.Engine
            EngineVersion         = $Item.EngineVersion
            EngineMode            = $Item.EngineMode       # provisioned / serverless / parallelquery
            ClusterStatus         = $Item.Status
            MultiAZ               = $Item.MultiAZ
            DatabaseName          = $Item.DatabaseName
            ReaderEndpoint        = $Item.ReaderEndpoint
            Endpoint              = $Item.Endpoint
            InstanceCount         = ($Item.DBClusterMembers | Measure-Object).Count
            BackupRetentionDays   = $Item.BackupRetentionPeriod
            PITREnabled           = $aurPitrEnabled
            LatestRestorableTime  = $aurLatestRestore
            EarliestRestorableTime = $aurEarliestRestore
            SizeGiB               = $sizes.SizeGiB
            SizeTiB               = $sizes.SizeTiB
            SizeGB                = $sizes.SizeGB
            SizeTB                = $sizes.SizeTB
        }
        try {
            if ($Item.DBClusterArn -and (Get-Command Get-RDSTag -ErrorAction SilentlyContinue)) {
                $tags = Get-RDSTag -ResourceName $Item.DBClusterArn -Credential $Credential -Region $Region -ErrorAction SilentlyContinue
                Add-TagProperties -Object $auroraObj -Tags $tags
            }
        } catch {}
        return $auroraObj
    } catch {
        Write-ScriptOutput "Failed to process Aurora cluster $($Item.DBClusterIdentifier): $_" -Level Warning
        return $null
    }
}

function Process-ElastiCacheCluster {
    param($Item, $Credential, $Region, $AccountInfo, $AccountAlias)
    try {
        # Node count and type for size estimation
        $nodeType  = $Item.CacheNodeType
        $nodeCount = if ($Item.NumCacheNodes) { $Item.NumCacheNodes } else { 1 }

        # Map instance family to approximate RAM GB for sizing context
        $approxRamGB = 0
        if ($nodeType -match '\.(\w+)$') {
            $size = $Matches[1]
            $approxRamGB = switch ($size) {
                'micro'    { 0.555 }; 'small'   { 1.55 };  'medium'  { 3.09 }
                'large'    { 6.38 };  'xlarge'  { 14.28 }; '2xlarge' { 28.56 }
                '4xlarge'  { 58.2 };  '8xlarge' { 118.8 }; '12xlarge'{ 193.6 }
                '16xlarge' { 209 };   default   { 0 }
            }
        }
        $totalRamGB = [math]::Round($approxRamGB * $nodeCount, 2)

        $ecObj = [PSCustomObject]@{
            AwsAccountId       = "$($AccountInfo.Account)"
            AwsAccountAlias    = $AccountAlias
            Region             = $Region
            CacheClusterId     = $Item.CacheClusterId
            Engine             = $Item.Engine
            EngineVersion      = $Item.EngineVersion
            CacheNodeType      = $nodeType
            NumCacheNodes      = $nodeCount
            ClusterStatus      = $Item.CacheClusterStatus
            ApproxTotalRAMGB   = $totalRamGB   # sizing proxy for backup capacity
            PreferredAZ        = $Item.PreferredAvailabilityZone
            ReplicationGroupId = $Item.ReplicationGroupId
            SnapshotRetentionDays = $Item.SnapshotRetentionLimit
        }
        return $ecObj
    } catch {
        Write-ScriptOutput "Failed to process ElastiCache cluster $($Item.CacheClusterId): $_" -Level Warning
        return $null
    }
}

function Process-AWSBackupResource {
    param($Item, $Credential, $Region, $AccountInfo, $AccountAlias)
    try {
        # Get the most recent recovery point for this resource to show last backup time
        $lastBackupTime = $null
        $backupStatus   = 'Unknown'
        try {
            $rp = Get-AWSBackupRecoveryPoint -ResourceArn $Item.ResourceArn -Credential $Credential -Region $Region
            if ($rp) {
                $lastBackupTime = $rp.CreationDate
                $backupStatus   = $rp.Status
            }
        } catch {}

        return [PSCustomObject]@{
            AwsAccountId      = "$($AccountInfo.Account)"
            AwsAccountAlias   = $AccountAlias
            Region            = $Region
            ResourceArn       = $Item.ResourceArn
            ResourceType      = $Item.ResourceType
            LastBackupTime    = $lastBackupTime
            LastBackupStatus  = $backupStatus
            LastBackupSizeGB  = if ($rps -and $rps[0].BackupSizeInBytes) { [math]::Round($rps[0].BackupSizeInBytes/1GB,4) } else { 0 }
        }
    } catch {
        Write-ScriptOutput "Failed to process AWS Backup resource $($Item.ResourceArn): $_" -Level Warning
        return $null
    }
}

function Process-DynamoDBTable {
    param($Item, $Credential, $Region, $AccountInfo, $AccountAlias)
    try {
        $tableName = if ($Item -is [string]) { $Item } elseif ($Item.TableName) { $Item.TableName } else { $Item }

        $tbl = $null
        try { $tbl = Get-DDBTable -TableName $tableName -Credential $Credential -Region $Region -ErrorAction Stop } catch { $tbl = $null }

        $tableArn = $null
        $tableId = $null
        $tableStatus = $null
        $tableSizeBytes = 0
        $itemCount = $null

        if ($tbl) {
            if ($tbl -and $tbl.Table) {
                $src = $tbl.Table
            } else {
                $src = $tbl
            }

            if ($src.TableArn)   { $tableArn = $src.TableArn }
            if ($src.TableId)    { $tableId = $src.TableId }
            if ($src.TableStatus) { $tableStatus = $src.TableStatus }
            if ($src.TableSizeBytes -ne $null) { $tableSizeBytes = [double]$src.TableSizeBytes }
            if ($src.ItemCount -ne $null) { $itemCount = [long]$src.ItemCount }

            if ($tableStatus -and $tableStatus.PSObject.Properties.Name -contains 'Value') {
                $tableStatus = $tableStatus.Value
            }
        }

        if (-not $tableArn -and $Item.TableArn) { $tableArn = $Item.TableArn }
        if (-not $tableId  -and $Item.TableId)  { $tableId = $Item.TableId }
        if (-not $tableStatus -and $Item.TableStatus) { $tableStatus = $Item.TableStatus }
        if (($tableSizeBytes -eq 0) -and $Item.TableSizeBytes -ne $null) {
            $tableSizeBytes = [double]$Item.TableSizeBytes
        }
        if (-not $itemCount -and $Item.ItemCount -ne $null) { $itemCount = [long]$Item.ItemCount }

        $sizes = Convert-BytesToSizes -Bytes $tableSizeBytes

        # ── PITR (point-in-time recovery) ────────────────────────────────
        # $null until proven otherwise: a failed Get-DDBContinuousBackup must not read as "PITR disabled".
        $pitrEnabled = $null
        $pitrRecoveryDays = $null
        try {
            $cbs = Get-DDBContinuousBackup -TableName $tableName -Credential $Credential -Region $Region -ErrorAction Stop
            $pitrStatus = if ($cbs -and $cbs.ContinuousBackupsDescription) {
                $cbs.ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus
            } elseif ($cbs) {
                $cbs.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus
            } else { $null }
            $pitrEnabled = ($null -ne $pitrStatus) -and ($pitrStatus.ToString() -eq 'ENABLED')
            # RecoveryPeriodInDays sits on the same description - how far back PITR can restore, not just whether
            # it is on. Newer API versions only; absent on older ones, which stays $null rather than 0.
            $pitrDesc = if ($cbs -and $cbs.ContinuousBackupsDescription) { $cbs.ContinuousBackupsDescription.PointInTimeRecoveryDescription }
                        elseif ($cbs) { $cbs.PointInTimeRecoveryDescription } else { $null }
            if ($pitrDesc -and $pitrDesc.PSObject.Properties['RecoveryPeriodInDays']) { $pitrRecoveryDays = $pitrDesc.RecoveryPeriodInDays }
        } catch {
            $pitrEnabled = $null
            Write-ScriptOutput "DynamoDB continuous-backup lookup failed for ${tableName}: $($_.Exception.Message)" -Level Warning
        }

        # ── AWS Backup coverage ───────────────────────────────────────────
        # ddb-vault reads AWSBackupProtected, which DynamoDB never set at ALL - the field was absent from the row,
        # so the control was permanently Unknown on every table in every account. Found by the per-resource-type
        # wiring guard; the cross-cloud field search had reported it as wired because EC2 and RDS set it.
        $ddbBackup = Resolve-AWSBackupProtection -Credential $Credential -Region $Region `
                        -ResourceArn $tableArn -Identifier $tableName -ResourceType 'DynamoDB'

        $ddbProtectionStatus = if ($pitrEnabled -or $ddbBackup.Protected) { 'Protected' }
                               elseif ($null -eq $pitrEnabled -or $ddbBackup.Status -ne 'Ok') { 'Unknown' }
                               else { 'Unprotected' }

        $ddbObj = [PSCustomObject]@{
            AwsAccountId     = "$($AccountInfo.Account)"
            AwsAccountAlias  = $AccountAlias
            Region           = $Region
            TableName        = $tableName
            TableId          = $tableId
            TableArn         = $tableArn
            TableSizeBytes   = $tableSizeBytes
            TableStatus      = $tableStatus
            ItemCount        = $itemCount
            PITREnabled      = $pitrEnabled
            # ddb-vault reads this. It was never set on a DynamoDB row, so the control could only ever be Unknown.
            AWSBackupProtected = $ddbBackup.Protected
            # AWS Backup Vault Lock - region-scoped immutability. Locked vaults cannot have recovery points
            # deleted or retention shortened, even by an admin: the AWS analogue of Azure vault immutability.
            BackupVaultAnyLocked    = $vaultLock.AnyLocked
            # Why a blank neighbouring cell is blank. DaysSinceLastBackup blank could mean 'no recovery point
            # exists' OR 'the AWS Backup list could not be read' - these two columns say which.
            BackupDataStatus        = $ddbBackup.Status
            VaultLockDataStatus     = $vaultLock.Status
            BackupVaultLockedCount  = $vaultLock.LockedCount
            BackupVaultMinRetentionDays = $vaultLock.MinRetentionDays
            AwsBackupLastBackupUtc = $(if ($ddbBackup.LastBackupTime) { ([datetime]$ddbBackup.LastBackupTime).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { '' })
            # PITR window length, not just on/off - from PointInTimeRecoveryDescription.RecoveryPeriodInDays.
            PITRRecoveryPeriodDays = $pitrRecoveryDays
            # Deletion protection and encryption at rest. Both come free from the DescribeTable response that was
            # already fetched, and DynamoDB previously had NO encryption signal at all.
            DeletionProtection = $(if ($null -ne $Item.DeletionProtectionEnabled) { [bool]$Item.DeletionProtectionEnabled } else { $null })
            SSEType            = $(if ($Item.SSEDescription) { "$($Item.SSEDescription.SSEType)" } else { 'None' })
            SSEStatus          = $(if ($Item.SSEDescription) { "$($Item.SSEDescription.Status)" } else { 'None' })
            # Global tables: a replica in another region is DynamoDB's cross-region redundancy.
            ReplicaRegionCount = $(if ($null -ne $Item.Replicas) { @($Item.Replicas).Count } else { $null })
            ProtectionStatus = $ddbProtectionStatus
            TableSizeGiB     = $sizes.SizeGiB
            TableSizeTiB     = $sizes.SizeTiB
            TableSizeGB      = $sizes.SizeGB
            TableSizeTB      = $sizes.SizeTB
        }

        try {
            if (Get-Command Get-DDBTableTag -ErrorAction SilentlyContinue) {
                $tags = Get-DDBTableTag -TableName $tableName -Credential $Credential -Region $Region -ErrorAction Stop
                Add-TagProperties -Object $ddbObj -Tags $tags
            }
        } catch { }

        return $ddbObj
    } catch {
        Write-ScriptOutput "Failed to process DynamoDB table $($Item): $_" -Level Warning
        return $null
    }
}

function Process-RedshiftCluster {
    param($Item, $Credential, $Region, $AccountInfo, $AccountAlias)
    try {
        $clusterId = $Item.ClusterIdentifier
        $nodeCount = if ($Item.NumberOfNodes) { [int]$Item.NumberOfNodes } else { 0 }
        $nodeType = if ($Item.NodeType) { $Item.NodeType } else { $null }

        $totalBytes = 0
        if ($Item -and $Item.PSObject -and $Item.PSObject.Properties.Name) {
            if ($Item.PSObject.Properties.Name -contains 'TotalStorageInBytes') { $totalBytes = [double]$Item.TotalStorageInBytes }
            elseif ($Item.PSObject.Properties.Name -contains 'TotalStorageInMegaBytes') { $totalBytes = [double]$Item.TotalStorageInMegaBytes * 1MB }
            elseif ($Item.PSObject.Properties.Name -contains 'TotalStorageInMegabytes') { $totalBytes = [double]$Item.TotalStorageInMegabytes * 1MB }
            elseif ($Item.PSObject.Properties.Name -contains 'TotalStorageCapacityInMegaBytes') { $totalBytes = [double]$Item.TotalStorageCapacityInMegaBytes * 1MB }
            elseif ($Item.PSObject.Properties.Name -contains 'TotalStorageCapacityInMegabytes') { $totalBytes = [double]$Item.TotalStorageCapacityInMegabytes * 1MB }
            elseif ($Item.PSObject.Properties.Name -contains 'TotalStorageCapacityInBytes') { $totalBytes = [double]$Item.TotalStorageCapacityInBytes }
            elseif ($Item.PSObject.Properties.Name -contains 'TotalStorage') {
                $v = $Item.TotalStorage
                if ($v -ne $null) { $totalBytes = [double]$v }
            }
            elseif ($Item.PSObject.Properties.Name -contains 'Storage') { $totalBytes = [double]$Item.Storage }
        }

        if ($totalBytes -eq 0 -and $Item.Cluster -and $Item.Cluster.PSObject.Properties.Name) {
            if ($Item.Cluster.PSObject.Properties.Name -contains 'TotalStorageInBytes') { $totalBytes = [double]$Item.Cluster.TotalStorageInBytes }
            elseif ($Item.Cluster.PSObject.Properties.Name -contains 'TotalStorageInMegaBytes') { $totalBytes = [double]$Item.Cluster.TotalStorageInMegaBytes * 1MB }
            elseif ($Item.Cluster.PSObject.Properties.Name -contains 'TotalStorageInMegabytes') { $totalBytes = [double]$Item.Cluster.TotalStorageInMegabytes * 1MB }
            elseif ($Item.Cluster.PSObject.Properties.Name -contains 'TotalStorageCapacityInMegaBytes') { $totalBytes = [double]$Item.Cluster.TotalStorageCapacityInMegaBytes * 1MB }
            elseif ($Item.Cluster.PSObject.Properties.Name -contains 'TotalStorageCapacityInMegabytes') { $totalBytes = [double]$Item.Cluster.TotalStorageCapacityInMegabytes * 1MB }
            elseif ($Item.Cluster.PSObject.Properties.Name -contains 'TotalStorageCapacityInBytes') { $totalBytes = [double]$Item.Cluster.TotalStorageCapacityInBytes }
            elseif ($Item.Cluster.PSObject.Properties.Name -contains 'TotalStorage') { $totalBytes = [double]$Item.Cluster.TotalStorage }
        }

        if ($totalBytes -eq 0 -and $clusterId) {
            try {
                $desc = Get-RSCluster -ClusterIdentifier $clusterId -Credential $Credential -Region $Region -ErrorAction Stop
                Write-ScriptOutput "DEBUG: DescribeClusters returned properties: $(($desc.PSObject.Properties.Name) -join ', ')" -Level Info
                if ($desc -and $desc.PSObject.Properties.Name -contains 'Cluster') { $src = $desc.Cluster }
                elseif ($desc -and $desc.PSObject.Properties.Name -contains 'Clusters') { $src = if ($desc.Clusters.Count -gt 0) { $desc.Clusters[0] } else { $null } }
                else { $src = $desc }

                if ($src) {
                    if ($src.PSObject.Properties.Name -contains 'TotalStorageInBytes') { $totalBytes = [double]$src.TotalStorageInBytes }
                    elseif ($src.PSObject.Properties.Name -contains 'TotalStorageInMegaBytes') { $totalBytes = [double]$src.TotalStorageInMegaBytes * 1MB }
                    elseif ($src.PSObject.Properties.Name -contains 'TotalStorageInMegabytes') { $totalBytes = [double]$src.TotalStorageInMegabytes * 1MB }
                    elseif ($src.PSObject.Properties.Name -contains 'TotalStorageCapacityInMegaBytes') { $totalBytes = [double]$src.TotalStorageCapacityInMegaBytes * 1MB }
                    elseif ($src.PSObject.Properties.Name -contains 'TotalStorageCapacityInMegabytes') { $totalBytes = [double]$src.TotalStorageCapacityInMegabytes * 1MB }
                    elseif ($src.PSObject.Properties.Name -contains 'TotalStorageCapacityInBytes') { $totalBytes = [double]$src.TotalStorageCapacityInBytes }
                    elseif ($src.PSObject.Properties.Name -contains 'TotalStorage') {
                        $v = $src.TotalStorage
                        if ($v -ne $null) { $totalBytes = [double]$v }
                    }
                    elseif ($src.PSObject.Properties.Name -contains 'Storage') { $totalBytes = [double]$src.Storage }
                }
            } catch {
                Write-ScriptOutput "DescribeClusters fallback for $clusterId did not return a storage field" -Level Info
            }
        }

        $totalSizes = Convert-BytesToSizes -Bytes $totalBytes

        # ── Backup & security fields ──────────────────────────────────────
        $rsEncrypted = if ($Item.Encrypted -ne $null) { [bool]$Item.Encrypted } else { $false }
        $rsAutomatedSnapshotRetention = if ($Item.AutomatedSnapshotRetentionPeriod -ne $null) { [int]$Item.AutomatedSnapshotRetentionPeriod } else { 0 }
        $rsClusterStatus = if ($Item.ClusterStatus) { $Item.ClusterStatus } else { 'unknown' }
        $rsPubliclyAccessible = if ($Item.PubliclyAccessible -ne $null) { [bool]$Item.PubliclyAccessible } else { $false }

        $rsProtectionStatus = if ($rsAutomatedSnapshotRetention -gt 0) { 'Automated-Backup' } else { 'Unprotected' }

        $rsObj = [PSCustomObject]@{
            AwsAccountId                    = "$($AccountInfo.Account)"
            AwsAccountAlias                 = $AccountAlias
            Region                          = $Region
            ClusterIdentifier               = $clusterId
            ClusterStatus                   = $rsClusterStatus
            NodeType                        = $nodeType
            NodeCount                       = $nodeCount
            Encrypted                       = $rsEncrypted
            PubliclyAccessible              = $rsPubliclyAccessible
            AutomatedSnapshotRetentionDays  = $rsAutomatedSnapshotRetention
            # Both come free from the DescribeClusters response already fetched.
            ManualSnapshotRetentionDays     = $(if ($null -ne $Item.ManualSnapshotRetentionPeriod) { [int]$Item.ManualSnapshotRetentionPeriod } else { $null })
            MultiAZ                         = $(if ($null -ne $Item.MultiAZ) { "$($Item.MultiAZ)" } else { $null })
            ProtectionStatus                = $rsProtectionStatus
            TotalSizeGiB                    = $totalSizes.SizeGiB
            TotalSizeTiB                    = $totalSizes.SizeTiB
            TotalSizeGB                     = $totalSizes.SizeGB
            TotalSizeTB                     = $totalSizes.SizeTB
        }

        try {
            if (Get-Command Get-RSClusterTag -ErrorAction SilentlyContinue) {
                $tags = Get-RSClusterTag -ClusterIdentifier $clusterId -Credential $Credential -Region $Region -ErrorAction Stop
                Add-TagProperties -Object $rsObj -Tags $tags
            }
        } catch { }

        return $rsObj
    } catch {
        Write-ScriptOutput "Failed to process Redshift cluster $($Item.ClusterIdentifier): $_" -Level Warning
        return $null
    }
}



function Export-ServiceCSVFiles {
    <#
      .SYNOPSIS  Write one CSV per service, covering EVERY account in the run.
      .DESCRIPTION Was called once per account and produced <service>_<accountAlias>_<date>.csv, so a
                   three-account run left ~21 files that a human had to concatenate before they could pivot.
                   Azure emits one CSV per resource type for the whole run with a Subscription column; this is
                   the AWS equivalent, keyed by the AwsAccountId / AwsAccountAlias that Process-* already stamps
                   on every row. Filenames therefore lose the account segment.

                   Called ONCE, after every account has been collected and scored - not inside the account loop.
    #>
    try {
        # Service -> base filename. Registry order is not meaningful here; the map is authoritative.
        $serviceFiles = [ordered]@{
            EC2               = $baseOutputEc2Instance
            UnattachedVolumes = $baseOutputEc2UnattachedVolume
            S3                = $baseOutputS3
            EFS               = $baseOutputEFS
            FSX               = $baseOutputFSx
            FSX_SVM           = $baseOutputFSxSVM
            RDS               = $baseOutputRDS
            DynamoDB          = $baseOutputDynamoDB
            Redshift          = $baseOutputRedshift
            EKS               = $baseOutputEKS
            DocumentDB        = $baseOutputDocumentDB
            Aurora            = $baseOutputAurora
            ElastiCache       = $baseOutputElastiCache
            AWSBackup         = $baseOutputAWSBackup
        }

        foreach ($serviceName in $serviceFiles.Keys) {
            $baseName = $serviceFiles[$serviceName]
            if ([string]::IsNullOrWhiteSpace($baseName)) {
                Write-ScriptOutput "Skipping export for $serviceName because its base file name is empty" -Level Warning
                continue
            }

            # Concatenate every account's rows for this service, preserving account processing order.
            $rows = [System.Collections.Generic.List[psobject]]::new()
            foreach ($account in $script:AccountsProcessed) {
                $perAccount = $script:ServiceDataByAccount["$($account.Account)"]
                if (-not $perAccount) { continue }
                foreach ($row in @($perAccount[$serviceName])) { if ($row) { $rows.Add($row) } }
            }
            if (-not $rows.Count) { continue }

            # Export-Csv takes its header from the FIRST object and silently drops properties later objects add.
            # Accounts are scored independently, so a control that only resolved in account 2 would otherwise
            # vanish from the file entirely. Union the property names and project every row onto that union, so a
            # column missing from one account reads as blank - which is this repo's "not collected" - rather than
            # disappearing for everyone.
            $columns = [System.Collections.Generic.List[string]]::new()
            $seen    = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($row in $rows) {
                foreach ($name in $row.PSObject.Properties.Name) {
                    if ($seen.Add($name)) { $columns.Add($name) }
                }
            }

            $outputFile = "${baseName}_$date_string.csv"
            $csvPath    = Join-Path $script:Config.OutputPath $outputFile
            $rows | Select-Object -Property $columns | Export-Csv -Path $csvPath -NoTypeInformation

            $accountCount = @($rows | Group-Object AwsAccountId).Count
            Write-ScriptOutput "$outputFile written to $($script:Config.OutputPath) ($($rows.Count) rows across $accountCount account(s))" -Level Info
            $script:AllOutputFiles.Add($csvPath) | Out-Null
        }
    }
    catch {
        Write-ScriptOutput "Error exporting service CSV files: $_" -Level Error
    }
}

function Get-S3BucketSize {
    param([string]$BucketName, [object]$Credential, [string]$Region)

    try {
        $metricRegion = if ($script:Config.Partition -eq 'GovCloud') { $script:Config.DefaultGovCloudQueryRegion } else { 'us-east-1' }

        $commonParams = @{
            Namespace  = 'AWS/S3'
            MetricName = 'BucketSizeBytes'
            Period     = 86400
            Statistic  = 'Average'
            Credential = $Credential
        }

        function QueryMetric {
            param($QueryRegion, $StorageType)
            $dims = @(@{Name='BucketName';Value=$BucketName}, @{Name='StorageType';Value=$StorageType})
            $m = Get-SafeCWMetricStatistic -Namespace $commonParams.Namespace -MetricName $commonParams.MetricName -Dimensions $dims -Period $commonParams.Period -Statistics $commonParams.Statistic -StartTime $script:utcStartTime -EndTime $script:utcEndTime -Credential $Credential -Region $QueryRegion
            if ($m -and $m.Datapoints) {
                $dp = $m.Datapoints | Sort-Object Timestamp -Descending | Select-Object -First 1
                return $dp.Average
            }
            return $null
        }

        $val = QueryMetric -QueryRegion $metricRegion -StorageType 'AllStorageTypes'
        if ($val -and $val -gt 0) { return [double]$val }

        if ($Region -and ($Region -ne $metricRegion)) {
            $val = QueryMetric -QueryRegion $Region -StorageType 'AllStorageTypes'
            if ($val -and $val -gt 0) { return [double]$val }
        }

        $storageTypes = @(
            'StandardStorage','StandardIAStorage','OneZoneIAStorage',
            'ReducedRedundancyStorage','GlacierStorage','DeepArchiveStorage','IntelligentTieringStorage'
        )

        $totalBytes = 0
        foreach ($st in $storageTypes) {
            $v = QueryMetric -QueryRegion $metricRegion -StorageType $st
            if ($v) { $totalBytes += [double]$v }
        }

        if ($totalBytes -eq 0 -and $Region -and ($Region -ne $metricRegion)) {
            foreach ($st in $storageTypes) {
                $v = QueryMetric -QueryRegion $Region -StorageType $st
                if ($v) { $totalBytes += [double]$v }
            }
        }

        return $totalBytes
    }
    catch {
        return 0
    }
}
function Get-S3BucketSizeByStorageClass {
    param([string]$BucketName, [string]$StorageClass, [object]$Credential, [string]$Region)

    try {
        $map = @{
            'STANDARD'             = 'StandardStorage'
            'STANDARD_IA'          = 'StandardIAStorage'
            'ONEZONE_IA'           = 'OneZoneIAStorage'
            'REDUCED_REDUNDANCY'   = 'ReducedRedundancyStorage'
            'GLACIER'              = 'GlacierStorage'
            'DEEP_ARCHIVE'         = 'DeepArchiveStorage'
            'INTELLIGENT_TIERING'  = 'IntelligentTieringStorage'
        }

        $key = $StorageClass.ToUpper()
        $storageType = if ($map.ContainsKey($key)) { $map[$key] } else { $StorageClass }

        $metricRegion = if ($script:Config.Partition -eq 'GovCloud') { $script:Config.DefaultGovCloudQueryRegion } else { 'us-east-1' }

        $metric = Get-SafeCWMetricStatistic -Namespace 'AWS/S3' -MetricName 'BucketSizeBytes' -Dimensions @(@{Name='BucketName';Value=$BucketName}, @{Name='StorageType';Value=$storageType}) -Period 86400 -Statistics 'Average' -StartTime $script:utcStartTime -EndTime $script:utcEndTime -Credential $Credential -Region $metricRegion
        if ($metric -and $metric.Datapoints) {
            return ($metric.Datapoints | Sort-Object Timestamp -Descending | Select-Object -First 1).Average
        }

        if ($Region -and $Region -ne $metricRegion) {
            $metric = Get-SafeCWMetricStatistic -Namespace 'AWS/S3' -MetricName 'BucketSizeBytes' -Dimensions @(@{Name='BucketName';Value=$BucketName}, @{Name='StorageType';Value=$storageType}) -Period 86400 -Statistics 'Average' -StartTime $script:utcStartTime -EndTime $script:utcEndTime -Credential $Credential -Region $Region
            if ($metric -and $metric.Datapoints) {
                return ($metric.Datapoints | Sort-Object Timestamp -Descending | Select-Object -First 1).Average
            }
        }

        return 0
    }
    catch {
        return 0
    }
}

function Get-S3BucketSizeAccurate {
    param(
        [string]$BucketName,
        [object]$Credential,
        [string]$Region,
        [int]$MaxSeconds = 120,
        [int]$MaxObjects = 100000
    )

    try {
        if (-not $BucketName) { return 0 }

        $regionName = if ($Region) { $Region } else { 'us-east-1' }

        try {
            if (-not ([System.Type]::GetType("Amazon.S3.AmazonS3Client, AWSSDK.S3"))) {
                # Get-Module -ListAvailable returns one entry PER INSTALLED VERSION in no guaranteed order, and
                # this used to be unfiltered by name - so the first AWSSDK.S3.dll found anywhere on PSModulePath
                # won for the whole process, frequently an older side-by-side copy left behind by an upgrade.
                # LoadFrom cannot be undone in-process, which is exactly the "module version that will not update
                # no matter how many new sessions or -Force installs" symptom. Filter by name, newest first.
                $mods = Get-Module -ListAvailable -Name 'AWS.Tools.*' -ErrorAction SilentlyContinue |
                            Where-Object { $_.ModuleBase } | Sort-Object Version -Descending
                foreach ($m in $mods) {
                    try {
                        $candidate = Get-ChildItem -Path $m.ModuleBase -Filter "AWSSDK.S3.dll" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($candidate) { [Reflection.Assembly]::LoadFrom($candidate.FullName) | Out-Null; break }
                    } catch { }
                }
            }
        } catch { }

        $regionEndpoint = [Amazon.RegionEndpoint]::GetBySystemName($regionName)

        if ($Credential -and ($Credential -is [Amazon.Runtime.AWSCredentials])) {
            $s3Client = [Amazon.S3.AmazonS3Client]::new($Credential, $regionEndpoint)
        } else {
            $s3Client = [Amazon.S3.AmazonS3Client]::new($regionEndpoint)
        }

        $totalBytes = 0
        $request = [Amazon.S3.Model.ListObjectsV2Request]::new()
        $request.BucketName = $BucketName
        $request.MaxKeys = 1000

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $objectCount = 0
        $page = 0

        do {
            $page++
            $response = $s3Client.ListObjectsV2Async($request).GetAwaiter().GetResult()

            if ($response -and $response.S3Objects) {
                foreach ($obj in $response.S3Objects) {
                    if ($obj.Size -ne $null) {
                        $totalBytes += [double]$obj.Size
                        $objectCount++
                    }

                    if (($objectCount % 1000) -eq 0) {
                        Write-Progress -Activity "Enumerating S3 bucket objects" -Status "Bucket: $BucketName — Objects: $objectCount — Elapsed: $([math]::Round($sw.Elapsed.TotalSeconds,1))s" -PercentComplete 0
                        if ($sw.Elapsed.TotalSeconds -gt $MaxSeconds) {
                            return 0
                        }
                        if ($objectCount -ge $MaxObjects) {
                            return 0
                        }
                    }
                }
            }

            $request.ContinuationToken = $response.NextContinuationToken
            $isTruncated = $response.IsTruncated

            if ($sw.Elapsed.TotalSeconds -gt $MaxSeconds) {
                return 0
            }
        } while ($isTruncated)

        Write-Progress -Activity "Enumerating S3 bucket objects" -Completed
        return $totalBytes
    }
    catch {
        return 0
    }
}

function Get-EFSFileSystemSize {
    param([object]$EFS, [object]$Credential, [string]$Region)

    try {
        if ($EFS.SizeInBytes -and $EFS.SizeInBytes.Value -gt 0) {
            Write-ScriptOutput "Found direct size information (FileSystemSize object) for EFS $($EFS.FileSystemId): $([math]::Round($EFS.SizeInBytes.Value / 1GB, 2)) GB" -Level Info
            return $EFS.SizeInBytes.Value
        }

        $metric = Get-SafeCWMetricStatistic -Namespace 'AWS/EFS' -MetricName 'StorageBytes' -Dimensions @{ Name='FileSystemId'; Value=$EFS.FileSystemId } -Period 86400 -Statistics 'Average' -StartTime $script:utcStartTime -EndTime $script:utcEndTime -Credential $Credential -Region $Region

        if ($metric -and $metric.Datapoints) {
            return ($metric.Datapoints | Sort-Object Timestamp -Descending | Select-Object -First 1).Average
        }
        return 0
    }
    catch {
        return 0
    }
}

# ============================================================
# CLOUD REWIND SIZING (AWS)  -  skip with -SkipCloudRewind
# Self-contained per-account sweep via the Resource Groups Tagging API (Get-RGTResource, one call per region).
# Each resource ARN is classified against the derived billable taxonomy; emits one row per billable resource plus
# a billable-vs-non-billable summary. Honors -Tags (client-side). Independent of the Data Protection inventory.
# ============================================================
function Invoke-AWSCloudRewindSweep {
    param([object]$Credential, [object[]]$Regions, [hashtable]$AccountInfo)
    try {
        Write-CVSection 'Cloud Rewind Sizing'
        # Filter out empties before counting: @($null).Count is 1, so a bare @($ResourceGroups).Count would fire
        # this warning on every run even when -ResourceGroups was never passed.
        if (@($ResourceGroups | Where-Object { $_ -and "$_".Trim() }).Count) {
            Write-CVLog 'Cloud Rewind (AWS): -ResourceGroups filtering is a follow-up for AWS; applying -Tags only.' -Level Warning -Source 'CloudRewind'
        }
        $crTax           = Get-CVAwsCloudRewindTaxonomy
        $crFilterTagKeys = Get-CVFilterTagKeys -FilterTags $Tags
        $crRows          = New-Object System.Collections.Generic.List[psobject]
        $crClassified    = New-Object System.Collections.Generic.List[psobject]
        $accountSuffix   = if ($AccountInfo.AccountAlias -and $AccountInfo.AccountAlias -ne 'Unknown') { $AccountInfo.AccountAlias } else { $AccountInfo.Account }

        foreach ($region in @($Regions)) {
            $region = Format-RegionName -Region $region
            $resources = @()
            try { $resources = @(Get-RGTResource -Credential $Credential -Region $region -ErrorAction Stop) }
            catch { Write-CVLog "Cloud Rewind: Get-RGTResource failed in $region : $($_.Exception.Message)" -Level Warning -Source 'CloudRewind'; continue }

            foreach ($res in $resources) {
                $arn = $res.ResourceARN
                $billable = Get-CVAwsCloudRewindBillable -Arn $arn -Taxonomy $crTax
                if ($null -eq $billable) { continue }

                $tagHash = @{}
                foreach ($t in @($res.Tags)) { if ($t.Key) { $tagHash[$t.Key] = $t.Value } }
                if (-not (Test-CVResourceMatch -Tags $tagHash -FilterTags $Tags)) { continue }

                $token = Get-CVAwsArnType -Arn $arn
                $class = Get-CVAwsCloudRewindClass -Token $token
                $crClassified.Add([pscustomobject]@{ Account = $AccountInfo.Account; AccountName = $accountSuffix; Billable = [bool]$billable; ResourceClass = $class })

                if ($billable) {
                    $name = ("$arn" -split '[:/]')[-1]
                    $crRows.Add( (New-CVCloudRewindRow -Fields @{
                        CloudProvider    = 'AWS'
                        Account          = $AccountInfo.Account
                        AccountName      = $accountSuffix
                        TenantOrOrg      = ''
                        Region           = $region
                        ResourceGroup    = ''
                        ResourceName     = $name
                        ResourceId       = $arn
                        ResourceType     = $token
                        ResourceState    = ''
                        BillableReason   = (Get-CVAwsCloudRewindReason -Token $token)
                        VpcOrVNet        = ''
                        Subnet           = ''
                        AvailabilityZone = $region
                        HasPublicIp      = ''
                        DiscoveredAt     = $date_string
                    } -Tags $tagHash -FilterTagKeys $crFilterTagKeys) )
                }
            }
        }

        $crFile = "aws_cloudrewind_${accountSuffix}_$date_string.csv"
        $crPath = Join-Path $script:Config.OutputPath $crFile
        if ($crRows.Count) {
            $crRows | Export-Csv -Path $crPath -NoTypeInformation
            $script:AllOutputFiles.Add($crPath) | Out-Null
            Write-ScriptOutput "$crFile ($($crRows.Count) billable resources) written to $($script:Config.OutputPath)" -Level Info
        } else {
            Write-CVLog "Cloud Rewind: no billable resources found for account $($AccountInfo.Account)." -Level Warning -Source 'CloudRewind'
        }

        $crSummary = Get-CVCloudRewindSummary -Classified $crClassified
        if (@($crSummary).Count) {
            $crSumFile = "aws_cloudrewind_summary_${accountSuffix}_$date_string.csv"
            $crSumPath = Join-Path $script:Config.OutputPath $crSumFile
            $crSummary | Export-Csv -Path $crSumPath -NoTypeInformation
            $script:AllOutputFiles.Add($crSumPath) | Out-Null
            $tb  = (@($crSummary) | Measure-Object TotalBillableResources -Sum).Sum
            $tnb = (@($crSummary) | Measure-Object TotalNonBillableResources -Sum).Sum
            Write-ScriptOutput "Cloud Rewind: $tb billable, $tnb non-billable resources for account $($AccountInfo.Account)" -Level Success
        }
    }
    catch {
        Write-CVLog "Cloud Rewind (AWS) pass failed: $($_.Exception.Message)" -Level Warning -Source 'CloudRewind'
    }
}

function Invoke-AWSDataCollection {
    param([object]$Credential)

    try {
        $queryRegion = if ($script:Config.Partition -eq "GovCloud") {
            $script:Config.DefaultGovCloudQueryRegion
        } else {
            $script:Config.DefaultQueryRegion
        }

        # Cheap local check first: when no credential source exists at all, every AWS call below would spend
        # ~30s in the SDK provider chain before failing with the same answer.
        if (-not (Test-AWSCredentialPreflight -Credential $Credential)) { return }

        # Identity BEFORE regions. Both need credentials, but this one reports the provider-chain detail, so
        # resolving it first means a credential failure is explained once instead of surfacing as a confusing
        # "failed to list EC2 regions" and then being explained.
        $accountInfo = Get-AWSAccountInfo -Credential $Credential -QueryRegion $queryRegion

        if (-not $accountInfo) {
            # The detailed error was already recorded by Get-AWSAccountInfo; just note the skip (no duplicate Error).
            Write-CVLog "Skipping account - identity could not be determined" -Level Debug -Source 'Auth'
            return
        }

        $awsRegions = Get-ProcessingRegions -Credential $Credential -QueryRegion $queryRegion
        if (-not $awsRegions -or @($awsRegions).Count -eq 0) {
            Write-CVLog "No regions to process for account $($accountInfo.Account) - skipping. Pass -Regions to set them explicitly." -Level Error -Source 'Region'
            return
        }

        Write-ScriptOutput "Processing AWS Account: $($accountInfo.Account) ($($accountInfo.AccountAlias))" -Level Success

        Initialize-ServiceCollections -AccountId $accountInfo.Account
        $script:AccountsProcessed += $accountInfo

        if (-not $SkipDataProtection) {
            $awsRegionCounter = 1
            foreach ($awsRegion in $awsRegions) {
                $awsRegion = Format-RegionName -Region $awsRegion
                Show-ScriptProgress -Activity "Region $awsRegion" -Status "Region $awsRegionCounter of $($awsRegions.Count)" -PercentComplete (($awsRegionCounter / $awsRegions.Count) * 100)

                Set-RegionPartition -Region $awsRegion

                foreach ($serviceName in $script:ServiceRegistry.Keys) {
                    Invoke-ServiceInventory -ServiceName $serviceName -Credential $Credential -Region $awsRegion -AccountInfo $accountInfo -AccountAlias $accountInfo.AccountAlias
                }

                $awsRegionCounter++
            }

            Write-ScriptOutput "Region processing completed for account $($accountInfo.Account)" -Level Success

            # Score native resilience posture BEFORE the CSVs are written so the Ctl_* columns land on them.
            Invoke-AWSResiliencePass -AccountId $accountInfo.Account

            # CSVs are NOT written here. Both the per-service files and the rollup span every account, so they
            # are written once at the end of the run - see Export-ServiceCSVFiles / Export-InventorySummaryCSV.
        }

        # Cloud Rewind billable-resource sizing (independent of the Data Protection inventory above).
        if (-not $SkipCloudRewind) {
            Invoke-AWSCloudRewindSweep -Credential $Credential -Regions $awsRegions -AccountInfo $accountInfo
        }
    }
    catch {
        Write-ScriptOutput "Error in AWS data collection: $_" -Level Error
    }
}

function Get-AWSCredentialSource {
    <#
      .SYNOPSIS  Local, instant check for credential sources the AWS SDK's default chain could resolve.
      .DESCRIPTION Deliberately mirrors only the sources that are visible WITHOUT a network call. Used to fail
                   fast: if nothing here is present and instance metadata is unreachable, no AWS call can
                   possibly succeed, and waiting ~30s per API call to rediscover that helps nobody.
      .OUTPUTS   String[] describing each source found (empty when none).
    #>
    [CmdletBinding()] param()
    $sources = @()
    if ($env:AWS_ACCESS_KEY_ID -and $env:AWS_SECRET_ACCESS_KEY)  { $sources += 'AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY' }
    if ($env:AWS_PROFILE)                                        { $sources += "AWS_PROFILE=$($env:AWS_PROFILE)" }
    if ($env:AWS_WEB_IDENTITY_TOKEN_FILE)                        { $sources += 'AWS_WEB_IDENTITY_TOKEN_FILE' }
    if ($env:AWS_CONTAINER_CREDENTIALS_RELATIVE_URI -or
        $env:AWS_CONTAINER_CREDENTIALS_FULL_URI)                 { $sources += 'container credential provider' }

    $sharedDir =
        if ($script:Config.ProfileLocation -and $script:Config.ProfileLocation.ProfileLocation) {
            Split-Path -Parent $script:Config.ProfileLocation.ProfileLocation
        } elseif ($env:HOME)        { Join-Path $env:HOME '.aws' }
        elseif ($env:USERPROFILE)   { Join-Path $env:USERPROFILE '.aws' }
        else                        { $null }

    if ($sharedDir) {
        foreach ($f in @('credentials','config')) {
            $p = Join-Path $sharedDir $f
            if (Test-Path -LiteralPath $p -PathType Leaf) { $sources += $p }
        }
    }
    return $sources
}

function Test-AWSInstanceMetadata {
    <# .SYNOPSIS  Is the EC2 instance metadata service reachable? Short timeout - it is the last-resort provider. #>
    [CmdletBinding()] param([int]$TimeoutSec = 2)
    if ($env:AWS_EC2_METADATA_DISABLED -eq 'true') { return $false }
    try {
        $null = Invoke-WebRequest -Uri 'http://169.254.169.254/latest/api/token' -Method Put `
                    -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '60' } `
                    -TimeoutSec $TimeoutSec -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Test-AWSCredentialPreflight {
    <#
      .SYNOPSIS  Fail fast, with remediation, when no AWS credential source exists at all.
      .DESCRIPTION Only applies to the default credential chain ($Credential = $null). When the caller already
                   resolved a credential object we have nothing to add. Returns $true to continue.
    #>
    [CmdletBinding()] param([object]$Credential)

    if ($null -ne $Credential) { return $true }

    $sources = @(Get-AWSCredentialSource)
    if ($sources.Count) {
        Write-CVLog "AWS credential source(s): $($sources -join '; ')" -Level Debug -Source 'Preflight'
        return $true
    }
    if (Test-AWSInstanceMetadata) {
        Write-CVLog "AWS credentials will come from EC2 instance metadata." -Level Debug -Source 'Preflight'
        return $true
    }

    Write-CVLog ("No AWS credentials found. Checked: AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY, AWS_PROFILE, " +
                 "AWS_WEB_IDENTITY_TOKEN_FILE, container credential provider, the shared credentials/config " +
                 "files, and EC2 instance metadata (unreachable). Run 'aws configure' (or 'aws configure sso'), " +
                 "export the access-key variables, or pass -ProfileLocation / -CrossAccountRoleName.") `
                -Level Error -Source 'Preflight'
    return $false
}

function Get-ProcessingRegions {
    param([object]$Credential, [string]$QueryRegion)

    if ($Regions -and $Regions.Trim() -ne '') {
        return $Regions.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    } else {
        try {
            $profileLocationParams = $script:Config.ProfileLocation
            return Get-EC2Region @profileLocationParams -Region $QueryRegion -Credential $Credential -ErrorAction Stop | Select-Object -ExpandProperty RegionName
        } catch {
            # Carry the exception: without it this reads as a bare "EC2 query failed" and hides the real cause
            # (most often credential resolution, since this is the first AWS call the script makes).
            Write-CVLog "Failed to list EC2 regions (query region $QueryRegion)" -Level Error -Source 'Region' -Exception $_
            return @()
        }
    }
}

function Get-AWSAccountInfo {
    param([object]$Credential, [string]$QueryRegion)

    Write-ScriptOutput "Getting AWS account information..." -Level Info
    try {
        $awsAccountInfo = Get-STSCallerIdentity -Credential $Credential -Region $QueryRegion -ErrorAction Stop
        $awsAccountAlias = try {
            Get-IAMAccountAlias -Credential $Credential -Region $QueryRegion -ErrorAction Stop
        } catch {
            "Unknown"
        }

        return @{
            Account = $awsAccountInfo.Account
            AccountAlias = $awsAccountAlias
        }
    } catch {
        Write-CVLog "Failed to get AWS account information" -Level Error -Source 'Auth' -Exception $_
        return $null
    }
}

function Format-RegionName {
    param([string]$Region)
    return $Region.Trim().ToLower()
}

function Set-RegionPartition {
    param([string]$Region)
    if ($Region -like "us-gov-*") {
        $script:Config.Partition = "GovCloud"
        if (-not $ProfileLocation) {
            $script:Config.ProfileLocation = @{ ProfileLocation = "SAMLRoleProfile" }
        }
    } else {
        $script:Config.Partition = "Standard"
        if (-not $ProfileLocation) {
            $script:Config.ProfileLocation = @{}
        }
    }
}

function Invoke-AuthenticationScenarios {
    $authFunctions = @{
        AllLocalProfiles = {
            try {
                $profileLocationParams = $script:Config.ProfileLocation
                Write-ScriptOutput "Using profile location parameters: $($profileLocationParams | ConvertTo-Json -Compress)" -Level Info

                if ($profileLocationParams.Count -gt 0) {
                    $profileFile = $profileLocationParams.ProfileLocation
                    if (Test-Path $profileFile) {
                        Write-ScriptOutput "Reading profiles from custom location: $profileFile" -Level Info
                        $content = Get-Content $profileFile -Raw
                        $profiles = [regex]::Matches($content, '\[([^\]]+)\]') | ForEach-Object { $_.Groups[1].Value }
                        Write-ScriptOutput "Found profiles in custom file: $($profiles -join ', ')" -Level Info
                        $allProfiles = $profiles
                    } else {
                        Write-ScriptOutput "Custom profile file not found: $profileFile" -Level Error
                        return
                    }
                } else {
                    $allProfiles = Get-AWSCredential -ListProfiles
                }

                Write-ScriptOutput "Found $($allProfiles.Count) profiles to process" -Level Info

                $allProfiles | ForEach-Object {
                    Write-ScriptOutput "Processing profile: $_" -Level Info
                    try {
                        $cred = $null
                        try {
                            if ($profileLocationParams.Count -gt 0) {
                                $cred = Get-AWSCredential -ProfileName $_ @profileLocationParams -ErrorAction Stop
                                Write-ScriptOutput "Successfully loaded credentials from custom location for profile '$_'" -Level Success
                            } else {
                                $cred = Get-AWSCredential -ProfileName $_ -ErrorAction Stop
                                Write-ScriptOutput "Successfully loaded credentials from default location for profile '$_'" -Level Success
                            }
                        }
                        catch {
                            Write-ScriptOutput "Failed to load credentials for profile '$_': $($_.Exception.Message)" -Level Error

                            if ($profileLocationParams.Count -gt 0) {
                                Write-ScriptOutput "Skipping profile '$_' as custom ProfileLocation was specified but failed" -Level Warning
                                return
                            }

                            try {
                                Write-ScriptOutput "Attempting alternative credential loading for profile '$_'..." -Level Info
                                $cred = Get-AWSCredential -ProfileName $_ -ErrorAction Stop
                                Write-ScriptOutput "Successfully loaded credentials via alternative method for profile '$_'" -Level Success
                            }
                            catch {
                                Write-ScriptOutput "All credential loading methods failed for profile '$_': $($_.Exception.Message)" -Level Error
                                return
                            }
                        }

                        if ($cred) {
                            Write-ScriptOutput "Credential object obtained for profile '$_', proceeding with data collection" -Level Success
                            Invoke-AWSDataCollection -Credential $cred
                        } else {
                            Write-ScriptOutput "No credentials object returned for profile: $_" -Level Warning
                        }
                    } catch {
                        Write-ScriptOutput "Error processing profile $_`: $($_.Exception.Message)" -Level Error
                    }
                }
            }
            catch {
                Write-ScriptOutput "Error in AllLocalProfiles processing: $($_.Exception.Message)" -Level Error
            }
        }
        UserSpecifiedProfiles = {
            $UserSpecifiedProfileNames.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object {
                Write-ScriptOutput "Processing profile: $_" -Level Info
                try {
                    $profileLocationParams = $script:Config.ProfileLocation
                    Write-ScriptOutput "Using profile location parameters: $($profileLocationParams | ConvertTo-Json -Compress)" -Level Info

                    $cred = $null
                    try {
                        if ($profileLocationParams.Count -gt 0) {
                            $cred = Get-AWSCredential -ProfileName $_ @profileLocationParams -ErrorAction Stop
                            Write-ScriptOutput "Successfully loaded credentials from custom location for profile '$_'" -Level Success
                        } else {
                            $cred = Get-AWSCredential -ProfileName $_ -ErrorAction Stop
                            Write-ScriptOutput "Successfully loaded credentials from default location for profile '$_'" -Level Success
                        }
                    }
                    catch {
                        Write-ScriptOutput "Failed to load credentials for profile '$_': $($_.Exception.Message)" -Level Error

                        if ($profileLocationParams.Count -gt 0) {
                            Write-ScriptOutput "Skipping profile '$_' as custom ProfileLocation was specified but failed" -Level Warning
                            return
                        }

                        try {
                            Write-ScriptOutput "Attempting alternative credential loading for profile '$_'..." -Level Info
                            $cred = Get-AWSCredential -ProfileName $_ -ErrorAction Stop
                            Write-ScriptOutput "Successfully loaded credentials via alternative method for profile '$_'" -Level Success
                        }
                        catch {
                            Write-ScriptOutput "All credential loading methods failed for profile '$_': $($_.Exception.Message)" -Level Error
                            return
                        }
                    }

                    if ($cred) {
                        Write-ScriptOutput "Credential object obtained for profile '$_', proceeding with data collection" -Level Success
                        Invoke-AWSDataCollection -Credential $cred
                    } else {
                        Write-ScriptOutput "No credentials object returned for profile: $_" -Level Warning
                    }
                } catch {
                    Write-ScriptOutput "Error processing profile $_`: $($_.Exception.Message)" -Level Error
                }
            }
        }
        CrossAccountRole = {
            function Assume-RoleOrFail {
                param($AccountId)

                Write-ScriptOutput "Processing cross-account role for account: $AccountId" -Level Info
                try {
                    Write-ScriptOutput "DEBUG: AccountId being used for role ARN: '$AccountId'" -Level Info

                    $AccountId = if ($AccountId) { $AccountId.Trim() } else { $AccountId }
                    $roleName = if ($CrossAccountRoleName) { ($CrossAccountRoleName -replace '^(?:role/|/)+','').Trim() } else { $null }

                    if (-not $AccountId -or -not $roleName -or -not ($AccountId -match '^\d{12}$')) {
                        Write-ScriptOutput "ERROR: AccountId or RoleName is missing or invalid for role assumption! AccountId='$AccountId' RoleName='$roleName'" -Level Error
                        return
                    }

                    $roleArn = "arn:aws:iam::${AccountId}:role/${roleName}"
                    Write-ScriptOutput "DEBUG: Built role ARN: $roleArn" -Level Info

                    $sessionName = if ($CrossAccountRoleSessionName) { $CrossAccountRoleSessionName } else { "CVAWS-Cost-Sizing" }
                    $stsParams = @{
                        RoleArn = $roleArn
                        RoleSessionName = $sessionName
                        ErrorAction = 'Stop'
                    }
                    if ($ExternalId) { $stsParams.ExternalId = $ExternalId }

                    $profileLocationParams = $script:Config.ProfileLocation
                    if ($profileLocationParams -and $profileLocationParams.Count -gt 0) {
                        foreach ($k in $profileLocationParams.Keys) { $stsParams[$k] = $profileLocationParams[$k] }
                    }

                    Write-ScriptOutput "Attempting STS AssumeRole for $AccountId" -Level Info
                    $assumeResult = Use-STSRole @stsParams
                    if (-not $assumeResult) {
                        throw "Failed to assume role $roleArn for account $AccountId."
                    }

                    if ($assumeResult -is [Amazon.Runtime.AWSCredentials]) {
                        Write-ScriptOutput "DEBUG: Use-STSRole returned AWSCredentials for account $AccountId" -Level Info
                        Invoke-AWSDataCollection -Credential $assumeResult
                        return
                    }

                    $creds = $null
                    if ($assumeResult -and $assumeResult.Credentials) { $creds = $assumeResult.Credentials }

                    if (-not $creds) {
                        throw "AssumeRole did not return usable credentials."
                    }

                    $basicType = [System.Type]::GetType("Amazon.Runtime.BasicSessionAWSCredentials, AWSSDK.Core")
                    if (-not $basicType) {
                        try {
                            # Newest AWS.Tools.* first - see the AWSSDK.S3 note above. An unfiltered, unordered
                            # scan pinned whichever stale side-by-side version happened to be enumerated first.
                            $mods = Get-Module -ListAvailable -Name 'AWS.Tools.*' -ErrorAction SilentlyContinue |
                                        Where-Object { $_.ModuleBase } | Sort-Object Version -Descending
                            $dllPath = $null
                            foreach ($m in $mods) {
                                try {
                                    $candidate = Get-ChildItem -Path $m.ModuleBase -Filter "AWSSDK.Core.dll" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                                    if ($candidate) { $dllPath = $candidate.FullName; break }
                                } catch { continue }
                            }
                            if ($dllPath) {
                                [Reflection.Assembly]::LoadFrom($dllPath) | Out-Null
                                Write-ScriptOutput "DEBUG: Loaded AWSSDK.Core from $dllPath" -Level Info
                            }
                        } catch {
                            Write-ScriptOutput "DEBUG: Could not auto-load AWSSDK.Core: $($_.Exception.Message)" -Level Warning
                        }
                        $basicType = [System.Type]::GetType("Amazon.Runtime.BasicSessionAWSCredentials, AWSSDK.Core")
                    }

                    if ($basicType) {
                        try {
                            $sessionCred = New-Object Amazon.Runtime.BasicSessionAWSCredentials(
                                $creds.AccessKeyId,
                                $creds.SecretAccessKey,
                                $creds.SessionToken
                            )
                            Write-ScriptOutput "DEBUG: Converted AssumeRoleResponse to BasicSessionAWSCredentials for account $AccountId" -Level Info
                            Invoke-AWSDataCollection -Credential $sessionCred
                            return
                        }
                        catch {
                            Write-ScriptOutput "DEBUG: Failed to construct BasicSessionAWSCredentials: $($_.Exception.Message)" -Level Warning
                        }
                    }

                    Write-ScriptOutput "DEBUG: Falling back to environment-variable based credentials for account $AccountId" -Level Info

                    $oldAWSAccessKey = $env:AWS_ACCESS_KEY_ID
                    $oldAWSSecretKey = $env:AWS_SECRET_ACCESS_KEY
                    $oldAWSSessionToken = $env:AWS_SESSION_TOKEN

                    try {
                        $env:AWS_ACCESS_KEY_ID = $creds.AccessKeyId
                        $env:AWS_SECRET_ACCESS_KEY = $creds.SecretAccessKey
                        $env:AWS_SESSION_TOKEN = $creds.SessionToken

                        Invoke-AWSDataCollection -Credential $null
                    }
                    finally {
                        if ($null -ne $oldAWSAccessKey) { $env:AWS_ACCESS_KEY_ID = $oldAWSAccessKey } else { Remove-Item Env:AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue }
                        if ($null -ne $oldAWSSecretKey) { $env:AWS_SECRET_ACCESS_KEY = $oldAWSSecretKey } else { Remove-Item Env:AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue }
                        if ($null -ne $oldAWSSessionToken) { $env:AWS_SESSION_TOKEN = $oldAWSSessionToken } else { Remove-Item Env:AWS_SESSION_TOKEN -ErrorAction SilentlyContinue }
                    }
                }
                catch {
                    Write-ScriptOutput "Failed to assume cross-account role for account ${AccountId}: $($_.Exception.Message)" -Level Error
                }
            }

            Write-ScriptOutput "DEBUG: UserSpecifiedAccounts='$UserSpecifiedAccounts'" -Level Info

            if ($UserSpecifiedAccounts) {
                $UserSpecifiedAccounts.Split(',') | ForEach-Object {
                    $accountId = $_.Trim()
                    if ($accountId -and $accountId -match '^\d{12}$') {
                        Assume-RoleOrFail $accountId
                    } else {
                        Write-ScriptOutput "Skipping invalid or empty account id: '$accountId'" -Level Warning
                    }
                }
            } elseif ($UserSpecifiedAccountsFile -and (Test-Path $UserSpecifiedAccountsFile)) {
                $accounts = Get-Content $UserSpecifiedAccountsFile | Where-Object { $_.Trim() -and -not $_.StartsWith('#') }
                $accounts | ForEach-Object {
                    $accountId = $_.Trim()
                    if ($accountId -and $accountId -match '^\d{12}$') {
                        Assume-RoleOrFail $accountId
                    } else {
                        Write-ScriptOutput "Skipping invalid or empty account id from file: '$accountId'" -Level Warning
                    }
                }
            } else {
                Write-ScriptOutput "Cross-account role processing requires UserSpecifiedAccounts or UserSpecifiedAccountsFile" -Level Error
            }
        }
        Default = {
            Invoke-AWSDataCollection -Credential $null
        }
    }

    $scenario = if ($AllLocalProfiles) { 'AllLocalProfiles' }
                elseif ($UserSpecifiedProfileNames) { 'UserSpecifiedProfiles' }
                elseif ($CrossAccountRoleName) { 'CrossAccountRole' }
                else { 'Default' }

    Write-ScriptOutput "Executing authentication scenario: $scenario" -Level Info
    & $authFunctions[$scenario]
}

function Export-InventorySummaryCSV {
    <#
      .SYNOPSIS  Write aws_inventory_summary_<date>.csv - the cross-account inventory rollup.
      .DESCRIPTION Replaces the two Excel workbooks this script used to emit (a per-account
                   <AccountId>_summary_<date>.xlsx and a consolidated one). The rollup shape, the arithmetic
                   and the column set now come from the same engine Azure uses - see
                   common/CVSizing.Summary.ps1 for the four passes and common/CVSizing.Summary.AWS.ps1 for the
                   AWS descriptor table, which also documents the S3 double-count the workbook had.
    #>
    try {
        $summaryFile = Join-Path $script:Config.OutputPath "aws_inventory_summary_$date_string.csv"

        # Flatten the per-account collections into one list per service. The engine's per-account pass re-splits
        # them on AwsAccountId, which Process-* stamps on every row, so nothing has to be threaded through here.
        $inventory = @{}
        $selected  = @{}
        foreach ($serviceName in $script:ServiceRegistry.Keys) {
            $svcRows = [System.Collections.Generic.List[psobject]]::new()
            foreach ($accountId in $script:ServiceDataByAccount.Keys) {
                foreach ($row in @($script:ServiceDataByAccount[$accountId][$serviceName])) {
                    if ($row) { $svcRows.Add($row) }
                }
            }
            $inventory[$serviceName] = $svcRows
            $selected[$serviceName]  = $true    # AWS has no -Types gate; every registered service is in scope.
        }

        # Scope objects need a .Name holding the value AwsAccountId is matched against.
        $accounts = @($script:AccountsProcessed | ForEach-Object { [PSCustomObject]@{ Name = "$($_.Account)" } })

        $summaryRows = @(Get-CVAwsInventorySummary -Inventory $inventory -Selected $selected -Accounts $accounts)
        if (-not $summaryRows.Count) {
            Write-ScriptOutput "No inventory collected; skipping the inventory summary CSV." -Level Warning
            return $false
        }

        $summaryRows | Export-Csv -Path $summaryFile -NoTypeInformation
        Write-ScriptOutput "Inventory summary: $summaryFile" -Level Success
        return $true
    }
    catch {
        Write-ScriptOutput "Error creating inventory summary CSV: $_" -Level Error
        return $false
    }
}

function New-OutputArchive {
    <#
      .SYNOPSIS  Zip the whole run directory, matching what Azure and GCP do.
      .DESCRIPTION Was a curated add-one-file-at-a-time loop over $script:AllOutputFiles. That is a whitelist,
                   and a whitelist you have to remember to update is a whitelist that goes stale: it is why
                   aws_resilience_signals_*.csv shipped for several revisions without ever reaching the ZIP the
                   customer was handed. CreateFromDirectory cannot omit a file, so the failure mode is gone by
                   construction rather than by a cross-check that warns after the fact.

                   ZipPath is a SIBLING of OutputDir (see Initialize-CVRunPaths), so this never zips the archive
                   into itself. The loose files are deliberately left in place - the ZIP is a copy, not a move.
    #>
    try {
        Write-ScriptOutput "Creating output archive..." -Level Info

        $runDir = if ($script:Config.OutputPath) { $script:Config.OutputPath } else { $script:RunPaths.OutputDir }
        if (-not $runDir -or -not (Test-Path -LiteralPath $runDir)) {
            Write-ScriptOutput "Output directory not found; nothing to archive: $runDir" -Level Warning
            return
        }

        $onDisk = @(Get-ChildItem -LiteralPath $runDir -File -Recurse)
        if (-not $onDisk.Count) {
            Write-ScriptOutput "Output directory is empty; no archive created." -Level Warning
            return
        }

        if (Test-Path -LiteralPath $archiveFile) { Remove-Item -LiteralPath $archiveFile -Force }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($runDir, $archiveFile)

        if (-not (Test-Path -LiteralPath $archiveFile)) {
            Write-ScriptOutput "Archive creation failed: file not found after compression" -Level Error
            return
        }

        $archiveSize = (Get-Item -LiteralPath $archiveFile).Length
        Write-ScriptOutput ("Archive created: {0} ({1} file(s), {2:N0} bytes)" -f $archiveFile, $onDisk.Count, $archiveSize) -Level Success

        # Anything registered for output that never made it to disk is still worth reporting - the archive is
        # complete with respect to the DIRECTORY, which says nothing about a write that failed earlier.
        $names   = @($onDisk | ForEach-Object { $_.Name })
        $missing = @($script:AllOutputFiles | ForEach-Object { Split-Path $_ -Leaf } | Where-Object { $_ -notin $names })
        if ($missing.Count) {
            Write-ScriptOutput ("{0} expected output file(s) were never written: {1}" -f $missing.Count, ($missing -join ', ')) -Level Warning
        }
    }
    catch {
        Write-ScriptOutput "Error creating output archive: $_" -Level Error
        Write-ScriptOutput "Stack trace: $($_.ScriptStackTrace)" -Level Error
    }
}


try {
    # --- Preflight (fail fast, plain output) then initialize the shared console layer ---
    # Highly opinionated: EVERY AWS.Tools module the script can use is required, so discovery is always broad -
    # a partial inventory is worse than a clear "install these first" message. PwshSpectreConsole powers the
    # interactive UI and is required unless running headless (container/CI), where output is plain by design.
    $peek = Get-CVConsoleCapability -NonInteractive:$NonInteractive -Quiet:$Quiet
    $fatalModules = @(
        'AWS.Tools.Common', 'AWS.Tools.EC2', 'AWS.Tools.S3', 'AWS.Tools.SecurityToken',
        'AWS.Tools.IdentityManagement', 'AWS.Tools.CloudWatch', 'AWS.Tools.RDS', 'AWS.Tools.DynamoDBv2',
        'AWS.Tools.Redshift', 'AWS.Tools.FSx', 'AWS.Tools.ElasticFileSystem', 'AWS.Tools.EKS', 'AWS.Tools.DocDB',
        'AWS.Tools.ElastiCache', 'AWS.Tools.Backup'
    )
    if (-not $peek.IsHeadless) { $fatalModules += 'PwshSpectreConsole' }
    if (-not $SkipCloudRewind) { $fatalModules += 'AWS.Tools.ResourceGroupsTaggingAPI' }   # Cloud Rewind resource sweep
    Assert-CVPreflight -FatalModules $fatalModules -ExitOnFatal | Out-Null

    Initialize-CVConsole -Cloud AWS -LogPath $script:LogPath -Title 'AWS Cost Sizing Analysis' `
                         -NonInteractive:$NonInteractive -Quiet:$Quiet | Out-Null
    Write-CVLog "Log file: $script:LogFile" -Level Info -Source 'Init'
    Write-CVLog "Supported services: $($script:ServiceRegistry.Keys -join ', ')" -Level Info -Source 'Init'

    if ($ProfileLocation) {
        Write-ScriptOutput "ProfileLocation parameter provided: $ProfileLocation" -Level Info
        if (Test-Path $ProfileLocation) {
            Write-ScriptOutput "ProfileLocation file exists and is accessible" -Level Success
        } else {
            Write-ScriptOutput "ProfileLocation file does not exist or is not accessible: $ProfileLocation" -Level Warning
        }
    } else {
        Write-ScriptOutput "No ProfileLocation parameter provided, using default AWS credentials" -Level Info
    }

    if ($UserSpecifiedProfileNames) {
        Write-ScriptOutput "UserSpecifiedProfileNames: $UserSpecifiedProfileNames" -Level Info
        $profileList = $UserSpecifiedProfileNames.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        Write-ScriptOutput "Parsed profiles: $($profileList -join ', ')" -Level Info
    }

    Invoke-AuthenticationScenarios

    Write-ScriptOutput "=== Processing Summary ===" -Level Success
    Write-ScriptOutput "Accounts processed: $($script:AccountsProcessed.Count)" -Level Info

    # DP cross-account summary + per-service counts - only meaningful when the Data Protection pass ran.
    if (-not $SkipDataProtection) {
        if ($script:AccountsProcessed.Count -gt 0) {
            # Order matters only for the log: per-service detail first, then the rollup that summarises it.
            Export-ServiceCSVFiles
            Export-InventorySummaryCSV | Out-Null
        }

        foreach ($account in $script:AccountsProcessed) {
            Write-ScriptOutput "Account: $($account.Account) ($($account.AccountAlias))" -Level Info
            foreach ($serviceName in $script:ServiceRegistry.Keys) {
                $count = $script:ServiceDataByAccount[$account.Account][$serviceName].Count
                Write-ScriptOutput "  $serviceName`: $count items" -Level Info
            }
        }
    }

    # Run-wide resilience posture report (per-account scoring already ran before each account's CSV export).
    Write-AWSResilienceReport -OutputPath $script:Config.OutputPath -DateString $date_string

    # ============================================================
    # JSON EXPORT (when OutputFormat is json or both)
    # ============================================================
    if ($OutputFormat -eq "json" -or $OutputFormat -eq "both") {
        Write-ScriptOutput "Writing JSON sizing output..." -Level Info
        $jsonSummary = @{}
        $allWorkloads = @{}

        # Map each service to the GB property on its workload objects
        $serviceSizeField = @{
            EC2              = "SizeGB"
            S3               = "SizeGB"
            EFS              = "SizeGB"
            FSX              = "SizeGB"
            FSX_SVM          = $null
            EKS              = $null
            UnattachedVolumes = "SizeGB"
            RDS              = "SizeGB"
            DynamoDB         = "TableSizeGB"
            Redshift         = "TotalSizeGB"
            DocumentDB       = "SizeGB"
            Aurora           = "SizeGB"
            ElastiCache      = $null
            AWSBackup        = "LastBackupSizeGB"
        }

        foreach ($account in $script:AccountsProcessed) {
            foreach ($serviceName in $script:ServiceRegistry.Keys) {
                $items = @($script:ServiceDataByAccount[$account.Account][$serviceName])
                if ($items.Count -gt 0) {
                    $key = "aws_" + $serviceName.ToLower()
                    if (-not $allWorkloads.ContainsKey($key)) { $allWorkloads[$key] = @() }
                    $allWorkloads[$key] += $items
                }
                if (-not $jsonSummary.ContainsKey($serviceName)) {
                    $jsonSummary[$serviceName] = @{ count = 0; total_storage_gb = 0.0; notes = "" }
                }
                $jsonSummary[$serviceName].count += $items.Count

                # Accumulate storage from each workload item
                $sizeField = $serviceSizeField[$serviceName]
                if ($sizeField -and $items.Count -gt 0) {
                    foreach ($item in $items) {
                        $val = $item.$sizeField
                        if ($null -ne $val) {
                            $jsonSummary[$serviceName].total_storage_gb += [double]$val
                        }
                    }
                }
            }
        }

        # Round all totals to 4 decimal places
        foreach ($key in @($jsonSummary.Keys)) {
            $jsonSummary[$key].total_storage_gb = [math]::Round($jsonSummary[$key].total_storage_gb, 4)
        }

        # ── Protection summary (cross-service) ────────────────────────────
        function Get-ProtectionCounts {
            param([array]$Items)
            if (-not $Items -or $Items.Count -eq 0) {
                return @{ protected = 0; unprotected = 0; partial = 0; unknown = 0; total = 0; assessed = 0; coverage_pct = $null }
            }
            $protected   = ($Items | Where-Object { $_.ProtectionStatus -eq 'Protected' }).Count
            $automated   = ($Items | Where-Object { $_.ProtectionStatus -in @('Automated-Backup','Snapshot-Only','Versioned') }).Count
            $unprotected = ($Items | Where-Object { $_.ProtectionStatus -eq 'Unprotected' }).Count
            # Resources we could not assess are reported separately and excluded from the coverage denominator -
            # rolling them into "unprotected" would overstate exposure using data we never collected.
            $unknown     = ($Items | Where-Object { $_.ProtectionStatus -eq 'Unknown' -or -not $_.ProtectionStatus }).Count
            $total       = $Items.Count
            $assessed     = $protected + $automated + $unprotected
            $coveredCount = $protected + $automated
            return @{
                protected       = $protected
                partial         = $automated
                unprotected     = $unprotected
                unknown         = $unknown
                total           = $total
                assessed        = $assessed
                coverage_pct    = if ($assessed -gt 0) { [math]::Round(($coveredCount / $assessed) * 100, 1) } else { $null }
            }
        }

        $protectionSummary = @{}

        # EC2
        $ec2Items = @($allWorkloads['aws_ec2'] | Where-Object { $_ -ne $null })
        $protectionSummary['EC2'] = Get-ProtectionCounts -Items $ec2Items
        $protectionSummary['EC2']['encrypted_volumes_pct'] = if ($ec2Items.Count -gt 0) {
            $encTotal = ($ec2Items | Where-Object { $_.AllVolumesEncrypted -eq $true }).Count
            [math]::Round(($encTotal / $ec2Items.Count) * 100, 1)
        } else { 0.0 }

        # RDS
        $rdsItems = @($allWorkloads['aws_rds'] | Where-Object { $_ -ne $null })
        $protectionSummary['RDS'] = Get-ProtectionCounts -Items $rdsItems
        $protectionSummary['RDS']['multi_az_pct'] = if ($rdsItems.Count -gt 0) {
            [math]::Round((($rdsItems | Where-Object { $_.MultiAZ -eq $true }).Count / $rdsItems.Count) * 100, 1)
        } else { 0.0 }
        $protectionSummary['RDS']['encrypted_pct'] = if ($rdsItems.Count -gt 0) {
            [math]::Round((($rdsItems | Where-Object { $_.StorageEncrypted -eq $true }).Count / $rdsItems.Count) * 100, 1)
        } else { 0.0 }

        # S3
        $s3Items = @($allWorkloads['aws_s3'] | Where-Object { $_ -ne $null })
        $protectionSummary['S3'] = Get-ProtectionCounts -Items $s3Items
        $protectionSummary['S3']['versioned_pct'] = if ($s3Items.Count -gt 0) {
            [math]::Round((($s3Items | Where-Object { $_.VersioningStatus -eq 'Enabled' }).Count / $s3Items.Count) * 100, 1)
        } else { 0.0 }
        $protectionSummary['S3']['public_access_exposed_count'] = ($s3Items | Where-Object { $_.PublicAccessBlocked -eq $false }).Count

        # EFS
        $efsItems = @($allWorkloads['aws_efs'] | Where-Object { $_ -ne $null })
        $protectionSummary['EFS'] = Get-ProtectionCounts -Items $efsItems
        $protectionSummary['EFS']['encrypted_pct'] = if ($efsItems.Count -gt 0) {
            [math]::Round((($efsItems | Where-Object { $_.Encrypted -eq $true }).Count / $efsItems.Count) * 100, 1)
        } else { 0.0 }

        # DynamoDB
        $ddbItems = @($allWorkloads['aws_dynamodb'] | Where-Object { $_ -ne $null })
        $protectionSummary['DynamoDB'] = Get-ProtectionCounts -Items $ddbItems
        $protectionSummary['DynamoDB']['pitr_enabled_count'] = ($ddbItems | Where-Object { $_.PITREnabled -eq $true }).Count

        # Redshift
        $rsItems = @($allWorkloads['aws_redshift'] | Where-Object { $_ -ne $null })
        $protectionSummary['Redshift'] = Get-ProtectionCounts -Items $rsItems
        $protectionSummary['Redshift']['encrypted_pct'] = if ($rsItems.Count -gt 0) {
            [math]::Round((($rsItems | Where-Object { $_.Encrypted -eq $true }).Count / $rsItems.Count) * 100, 1)
        } else { 0.0 }

        # Unattached Volumes
        $uvItems = @($allWorkloads['aws_unattachedvolumes'] | Where-Object { $_ -ne $null })
        $uvEncryptedCount = ($uvItems | Where-Object { $_.Encrypted -eq $true }).Count
        $protectionSummary['UnattachedVolumes'] = @{
            total               = $uvItems.Count
            encrypted_count     = $uvEncryptedCount
            unencrypted_count   = $uvItems.Count - $uvEncryptedCount
        }

        # Aurora
        $auroraItems = @($allWorkloads['aws_aurora'] | Where-Object { $_ -ne $null })
        $protectionSummary['Aurora'] = @{
            total          = $auroraItems.Count
            multi_az_count = ($auroraItems | Where-Object { $_.MultiAZ -eq $true }).Count
            protected      = ($auroraItems | Where-Object { [int]$_.BackupRetentionDays -gt 0 }).Count
            unprotected    = ($auroraItems | Where-Object { [int]$_.BackupRetentionDays -eq 0 }).Count
        }

        # Cross-service totals
        $allProtectable = @('EC2','RDS','S3','EFS','DynamoDB','Redshift')
        $totalProtected   = ($allProtectable | ForEach-Object { $protectionSummary[$_].protected ?? 0 } | Measure-Object -Sum).Sum
        $totalPartial     = ($allProtectable | ForEach-Object { $protectionSummary[$_].partial ?? 0 } | Measure-Object -Sum).Sum
        $totalUnprotected = ($allProtectable | ForEach-Object { $protectionSummary[$_].unprotected ?? 0 } | Measure-Object -Sum).Sum
        $totalWorkloads   = $totalProtected + $totalPartial + $totalUnprotected
        $protectionSummary['_overall'] = @{
            total_workloads      = $totalWorkloads
            fully_protected      = $totalProtected
            partially_protected  = $totalPartial
            unprotected          = $totalUnprotected
            overall_coverage_pct = if ($totalWorkloads -gt 0) {
                [math]::Round((($totalProtected + $totalPartial) / $totalWorkloads) * 100, 1)
            } else { 0.0 }
        }

        $jsonDoc = @{
            metadata = @{
                cloud          = "aws"
                accounts       = @($script:AccountsProcessed | ForEach-Object { $_.Account })
                generated_at   = (Get-Date -Format "o")
                script_version = "2.2"
            }
            summary            = $jsonSummary
            protection_summary = $protectionSummary
            workloads          = $allWorkloads
        }

        $jsonTimestamp = (Get-Date -Format "yyyy-MM-dd_HHmmss")
        # Never fall back to $PSScriptRoot - that wrote the JSON report into the script's own source directory.
        $jsonOutDir = if ($script:ResolvedOutputDir) { $script:ResolvedOutputDir } else { $script:RunPaths.OutputDir }
        if (-not (Test-Path $jsonOutDir)) { New-Item -ItemType Directory -Path $jsonOutDir -Force | Out-Null }
        $jsonPath = Join-Path $jsonOutDir ("aws_sizing_" + $jsonTimestamp + ".json")
        $jsonDoc | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8
        Write-ScriptOutput "JSON sizing report written: $jsonPath" -Level Success
    }

    # Unconditional. This was gated on -SelectiveZipping (a switch that defaulted to $true, so it could only
    # ever be turned off) AND on having produced more than one output file - so a single-service run wrote its
    # CSV and then silently shipped no archive at all. New-OutputArchive now zips the run directory and handles
    # the empty case itself, so there is nothing left for a caller to select.
    New-OutputArchive

    if ($script:KubectlInstalled -and $script:KubectlDir) {
        try {
            # Platform separator: ';' is Windows-only, and kubectl is now auto-provisioned on macOS/Linux too.
            $pathSep  = [IO.Path]::PathSeparator
            $env:Path = ($env:Path -split $pathSep | Where-Object { $_ -ne $script:KubectlDir }) -join $pathSep
            if (Test-Path $script:KubectlDir) {
                Remove-Item $script:KubectlDir -Recurse -Force
                Write-ScriptOutput "kubectl uninstalled successfully from $script:KubectlDir." -Level Info
            }
        } catch {
            Write-ScriptOutput "Failed to uninstall kubectl: $_" -Level Warning
        }
    }

    # Aggregated diagnostics summary (warning/error counts + which services/regions were skipped and why).
    Write-CVSummary -Title 'AWS Sizing Run Summary'

    $executionTime = (Get-Date) - $script:startTime
    Write-ScriptOutput "Total execution time: $($executionTime.ToString('hh\:mm\:ss'))" -Level Success
    Write-ScriptOutput "Log file created: $script:LogFile" -Level Info
    Write-ScriptOutput "=== AWS Cost Sizing Analysis Completed ===" -Level Success
}
catch {
    if (Get-Command Write-CVLog -ErrorAction SilentlyContinue) {
        Write-CVLog "Critical error in main execution" -Level Error -Source 'Main' -Exception $_
        Write-CVSummary -Title 'AWS Sizing Run Summary (aborted)'
    } else {
        Write-Host "Critical error in main execution: $_" -ForegroundColor Red
    }
    exit 1
}


