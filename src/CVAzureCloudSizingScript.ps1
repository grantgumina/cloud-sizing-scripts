#requires -Version 7.2
# Windows PowerShell 5.1 is NOT supported: the shared console layer needs $PSStyle (7.2+), and Az.Accounts 5.x
# no longer ships the lib\netfx assemblies its Desktop-edition preload path still asks for - importing it under
# 5.1 yields a wall of Add-Type "cannot find path ...\lib\netfx\*.dll" errors, then an assembly-load conflict.
# A #requires directive is evaluated BEFORE the script is parsed, so it fires ahead of any syntax or module
# error that would otherwise mask the real cause.
# Keep the blank line below - without it PowerShell stops treating the next block as comment-based help.

<#  
.SYNOPSIS  
    Azure Cloud Sizing Script - Comprehensive inventory and sizing analysis
.DESCRIPTION  
    Inventories Azure Virtual Machines, Storage Accounts, File Shares, NetApp File Volumes, SQL Databases/Managed Instances, MySQL Servers, PostgreSQL Servers, CosmosDB Accounts, and Azure Kubernetes Service (AKS) clusters across all or specified subscriptions.
    Calculates disk sizes for VMs, storage capacity utilization for Storage Accounts, capacity metrics for File Shares, usage metrics for NetApp File Volumes, database storage metrics for SQL, MySQL, PostgreSQL, and CosmosDB resources, and persistent volume information for AKS clusters.
    Generates detailed CSV reports with comprehensive sizing information in multiple units (GB, TB, TiB).
    Includes hierarchical progress tracking and comprehensive logging.
    Outputs timestamped CSV files and creates a ZIP archive of all results.

.PARAMETER Types
    Optional. Restrict inventory to specific resource types.
    Valid values: VM, Storage, FileShare, NetApp, SQL, Cosmos, AKS
    If not specified, all supported resource types will be inventoried.
    Note: MySQL and PostgreSQL servers are included as part of SQL inventory.
    
.PARAMETER Subscriptions
    Optional. Target specific subscriptions by name or ID.
    If not specified, all accessible subscriptions will be processed.
    
.EXAMPLE  
    .\CVAzureCloudSizingScript.ps1  
    # Inventories all resources in all accessible subscriptions  
.EXAMPLE  
    .\CVAzureCloudSizingScript.ps1 -Types VM,Storage,AKS  
    # Inventories VMs, Storage Accounts, and AKS clusters in all subscriptions
.EXAMPLE  
    .\CVAzureCloudSizingScript.ps1 -Types AKS
    # Only inventories Azure Kubernetes Service clusters in all subscriptions
.EXAMPLE  
    .\CVAzureCloudSizingScript.ps1 -Subscriptions "Production","Development"  
    # Inventories all resources in only the Production and Development subscriptions

.EXAMPLE  
    .\CVAzureCloudSizingScript.ps1 -Subscriptions "Dev Test","Production Environment"
    # Inventories all resources in subscriptions with spaces in names (always use quotes for names with spaces)

    # IMPORTANT: If you pass a subscription name that contains spaces WITHOUT quotes, PowerShell will treat the words as separate arguments
    # and the script will not match the subscription. Example of the problem and fixes:
    #   WRONG (will fail / be parsed incorrectly):
    #     .\CVAzureCloudSizingScript.ps1 -Subscriptions Dev Test
    #   CORRECT (use double quotes):
    #     .\CVAzureCloudSizingScript.ps1 -Subscriptions "Dev Test"
    #   ALTERNATIVE (use single quotes):
    #     .\CVAzureCloudSizingScript.ps1 -Subscriptions 'Dev Test'
    # You can also pass multiple quoted names separated by commas:
    #     .\CVAzureCloudSizingScript.ps1 -Subscriptions "Dev Test","Production Environment"

.EXAMPLE  
    .\CVAzureCloudSizingScript.ps1 -Subscriptions Production,Development
    # Inventories all resources in the subscriptions Production and Development (no spaces in names)

.EXAMPLE  
    .\CVAzureCloudSizingScript.ps1 -Types NetApp
    # Only inventories NetApp File volumes in all subscriptions
.EXAMPLE  
    .\CVAzureCloudSizingScript.ps1 -Types VM,Storage,NetApp -Subscriptions Production  
    # Inventories VMs, Storage Accounts, and NetApp File Volumes in only the Production subscription

.EXAMPLE  
    .\CVAzureCloudSizingScript.ps1 -Types Cosmos -Subscriptions "Development","Staging"  
    # Only inventories CosmosDB accounts in the Development and Staging subscriptions

.EXAMPLE  
    .\CVAzureCloudSizingScript.ps1 -Subscriptions xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    # Inventories all resources in the subscription with the specified Subscription ID

.OUTPUTS
    Creates timestamped output directory with the following files:
    - azure_vm_info_YYYY-MM-DD_HHMMSS.csv - VM inventory with disk sizing
    - azure_storage_accounts_info_YYYY-MM-DD_HHMMSS.csv - Storage Account inventory with capacity metrics
    - azure_file_shares_info_YYYY-MM-DD_HHMMSS.csv - File Share inventory with capacity metrics
    - azure_netapp_volumes_info_YYYY-MM-DD_HHMMSS.csv - NetApp Files volume inventory with capacity metrics
    - azure_sql_managed_instances_YYYY-MM-DD_HHMMSS.csv - SQL Managed Instances inventory
    - azure_sql_databases_inventory_YYYY-MM-DD_HHMMSS.csv - SQL Databases inventory  
    - azure_mysql_servers_YYYY-MM-DD_HHMMSS.csv - MySQL Servers inventory (included with SQL inventory)
    - azure_postgresql_servers_YYYY-MM-DD_HHMMSS.csv - PostgreSQL Servers inventory (included with SQL inventory)
    - azure_cosmosdb_accounts_YYYY-MM-DD_HHMMSS.csv - CosmosDB Accounts inventory with storage metrics
    - azure_aks_clusters_YYYY-MM-DD_HHMMSS.csv - AKS Clusters inventory with node and storage information
    - azure_aks_persistent_volumes_YYYY-MM-DD_HHMMSS.csv - AKS Persistent Volumes inventory
    - azure_aks_persistent_volume_claims_YYYY-MM-DD_HHMMSS.csv - AKS Persistent Volume Claims inventory
    - azure_inventory_summary_YYYY-MM-DD_HHMMSS.csv - Comprehensive summary with regional breakdowns
    - azure_sizing_script_output_YYYY-MM-DD_HHMMSS.log - Complete execution log
    - azure_sizing_YYYY-MM-DD_HHMMSS.zip - ZIP archive containing all output files
    
.NOTES
    Required Azure PowerShell modules (installed automatically based on selected resource types):
    - Az.Accounts (always required for authentication)
    - Az.Compute (for VM sizing)
    - Az.Storage (for Storage Accounts and File Shares)
    - Az.Monitor (for performance metrics)
    - Az.Resources (for resource group and subscription information)
    - Az.NetAppFiles (for NetApp Volumes)
    - Az.CosmosDB (for CosmosDB accounts)
    - Az.Sql (for Azure SQL databases and servers)
    - Az.MySql (for MySQL servers)
    - Az.PostgreSql (for PostgreSQL servers)
    - Az.Aks (for AKS clusters)
    
    Script must be run by a user with appropriate Azure permissions to read VMs, Storage Accounts, File Shares, NetApp Volumes, SQL resources, CosmosDB accounts, MySQL servers, PostgreSQL servers, and AKS clusters
    VM disk sizing includes both OS disks and data disks with error handling for inaccessible disks
    Storage Account, File Share, NetApp Files, CosmosDB, MySQL, and PostgreSQL metrics are retrieved from Azure Monitor for the last 1 hour
    
    AKS (Azure Kubernetes Service) REQUIREMENTS:
    
    KUBECTL REQUIREMENT:
    - kubectl command-line tool is REQUIRED for AKS persistent volume analysis
    - The script will automatically attempt to install kubectl if not found using:
      1. Azure CLI (az aks install-cli) - preferred method in Azure Cloud Shell
      2. Direct download from official Kubernetes releases if Azure CLI unavailable
    - kubectl installation is validated at script startup when AKS resource type is selected
    - If kubectl cannot be installed, AKS functionality will be limited to basic cluster information only
    
    AZURE PERMISSIONS REQUIRED FOR AKS:
    - Azure RBAC should be enabled on target AKS clusters (recommended configuration)
    - Azure Kubernetes Service Cluster User role on target AKS clusters
    - Azure Kubernetes Service RBAC Reader role on target AKS clusters  
    - Reader role on the subscription/resource group containing AKS clusters
    - Network Contributor role may be required for some AKS network configurations
    
    KUBERNETES RBAC REQUIREMENTS:
    - AKS clusters should have Azure RBAC integration enabled (recommended)
    - With Azure RBAC enabled, the Azure roles above provide the necessary Kubernetes permissions
    - Required Kubernetes permissions: read access to persistentvolumes, persistentvolumeclaims, storageclasses, and nodes
    - Since the script uses Azure credentials (az aks get-credentials), Azure RBAC roles determine access permissions
    
    NOTE: If insufficient permissions, kubectl commands will fail and AKS storage data collection will be incomplete.
    
    AKS CONNECTIVITY REQUIREMENTS:
    - Script must be able to connect to AKS cluster API servers
    - AKS clusters must be accessible from the execution environment
    - For private clusters, script must run from within the same virtual network or with proper connectivity
    - kubectl context will be automatically configured using 'az aks get-credentials' for each cluster
    
    AZURE CLOUD SHELL ADVANTAGES FOR AKS:
    - kubectl is pre-installed and maintained
    - Automatic Azure authentication integration
    - No firewall/connectivity issues with AKS clusters
    - Seamless integration with Azure CLI for cluster access
    
    AKS DATA COLLECTED:
    - Basic cluster information (name, location, version, node pools)
    - Persistent Volume (PV) inventory with storage class, capacity, and status
    - Persistent Volume Claim (PVC) inventory with requested storage and binding status
    - Storage class information and provisioner details
    - Regional and subscription-level AKS storage summaries
    
    NOTE: All Azure Monitor metrics collected use Maximum aggregation over a 1-hour time period to capture current resource utilization values efficiently.
    
    IMPORTANT: If Azure Monitor metrics are reported inaccurately or are not available for certain resources, there may be discrepancies between the reported values in this script and actual resource utilization.
    This can occur due to Azure Monitor data delays, resource configuration issues, or temporary service interruptions.
    
    SETUP INSTRUCTIONS FOR AZURE CLOUD SHELL (Recommended):

    1. Learn about Azure Cloud Shell:
       Visit: https://docs.microsoft.com/en-us/azure/cloud-shell/overview

    2. Verify Azure permissions:
       Ensure your Azure AD account has "Reader" role on target subscriptions
       Additional "Reader and Data Access" role may be needed for storage metrics
       For AKS: "Azure Kubernetes Service Cluster User" role required on AKS clusters

    3. Access Azure Cloud Shell:
       - Login to Azure Portal with verified account
       - Open Azure Cloud Shell (PowerShell mode)

    4. Upload this script:
       Use the Cloud Shell file upload feature to upload CVAzureCloudSizingScript.ps1

    5. Run the script:
       ./CVAzureCloudSizingScript.ps1
       ./CVAzureCloudSizingScript.ps1 -Types VM,Storage
       ./CVAzureCloudSizingScript.ps1 -Types AKS  # AKS-only inventory
       ./CVAzureCloudSizingScript.ps1 -Subscriptions "Production","Development"
       ./CVAzureCloudSizingScript.ps1 -Subscriptions Production,Development -Types VM,Storage

    SETUP INSTRUCTIONS FOR LOCAL SYSTEM:

    1. Install PowerShell 7:
       Download from: https://github.com/PowerShell/PowerShell/releases

    2. Install required Azure PowerShell modules:
       Install-Module Az.Accounts,Az.Compute,Az.Storage,Az.Monitor,Az.Resources,Az.NetAppFiles,Az.CosmosDB,Az.Sql,Az.MySql,Az.PostgreSql,Az.Aks -Force

    3. For AKS functionality - Install kubectl:
       Windows: choco install kubernetes-cli  OR  winget install Kubernetes.kubectl
       macOS: brew install kubectl
       Linux: curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
              chmod +x kubectl && sudo mv kubectl /usr/local/bin/
       Note: Script will attempt automatic installation if kubectl is not found

    4. Verify Azure permissions:
       Ensure your Azure AD account has "Reader" role on target subscriptions
       For AKS: "Azure Kubernetes Service Cluster User" role required on AKS clusters

    5. Connect to Azure:
       Connect-AzAccount

    6. Run the script:
       .\CVAzureCloudSizingScript.ps1
       .\CVAzureCloudSizingScript.ps1 -Types VM
       .\CVAzureCloudSizingScript.ps1 -Types AKS  # AKS-only inventory
       .\CVAzureCloudSizingScript.ps1 -Subscriptions "MySubscription"
       .\CVAzureCloudSizingScript.ps1 -SkipDataProtection          # Cloud Rewind billable-resource sizing only
       .\CVAzureCloudSizingScript.ps1 -ResourceGroups rg1 -Tags Environment=Production   # scope both passes

    Cloud Rewind sizing runs by default alongside Data Protection and writes azure_cloudrewind_<ts>.csv
    (one row per billable resource) + azure_cloudrewind_summary_<ts>.csv. Use -SkipCloudRewind to skip it.
    Cloud Rewind discovery uses Azure Resource Graph by default (fast, one query); -CloudRewindDiscovery Arm
    forces the Get-AzResource path (exact parity with the standalone sizer). Graph auto-falls-back to Arm if
    Az.ResourceGraph is unavailable.
#>  
  
param(  
    [string[]]$Types, # Choices: VM, Storage, FileShare, NetApp, SQL, Cosmos, AKS, Backup, UnmanagedDisks, AVS
    [string[]]$Subscriptions, # Subscription names or IDs to target (if not specified, all subscriptions will be processed)
    [string]$EnvTagName  = "Environment",   # Tag key used to identify environment (e.g. "Environment", "Env")
    [string[]]$EnvTagValues,                 # Filter to these tag values only (e.g. "Production","Prod"). If omitted, all resources are included.
    [ValidateSet("csv","json","both")][string]$OutputFormat = "csv",  # Output format: csv (default), json, or both
    [switch]$NonInteractive,   # force plain, non-interactive output (no progress bars / rich UI) - for CI / automation
    [switch]$Quiet,            # minimal console output (still writes the full log file)
    [switch]$SkipResilienceReport, # do not compute or write the cyber resilience posture report
    [string[]]$ResourceGroups,     # limit BOTH passes to these resource groups (union with -Tags). Omitted = all.
    [string[]]$Tags,               # limit BOTH passes to resources carrying any of these 'Key=Value' tags. Omitted = all.
    [switch]$SkipCloudRewind,      # skip the Cloud Rewind billable-resource sizing pass
    [ValidateSet('Graph','Arm')][string]$CloudRewindDiscovery = 'Graph', # CR discovery backend; Graph (Resource Graph) auto-falls-back to Arm (Get-AzResource)
    [switch]$SkipDataProtection,   # skip the Data Protection inventory + resilience pass (run Cloud Rewind only)
    [string]$OutputDirectory       # write Output/ and Logs/ under this root instead of the repo/script location
)

# Guard: at least one discovery pass must run.
if ($SkipCloudRewind -and $SkipDataProtection) {
    Write-Host 'ERROR: -SkipCloudRewind and -SkipDataProtection cannot both be set - nothing would run.' -ForegroundColor Red
    exit 1
}

# Load the shared console / diagnostics + resilience + Cloud Rewind layers (src/common/).
# Dot-sourcing a MISSING file is non-terminating, so an incomplete copy used to march on through ~10 cascading
# CommandNotFoundExceptions, silently skip Assert-CVPreflight, and die mid-inventory with no output. Check first
# and say exactly what is missing. This block must stay inline - it is the thing that guards dot-sourcing.
$cvCommonDir = Join-Path $PSScriptRoot 'common'
$cvRequired  = @(
    'CVSizing.Console.ps1'            # console / diagnostics / run paths
    'CVSizing.Resilience.ps1'         # provider-neutral scoring engine
    'CVSizing.Resilience.Azure.ps1'   # Azure control definitions
    'CVSizing.Backup.Azure.ps1'       # Azure backup attribution
    'CVSizing.Metrics.Azure.ps1'      # Azure Monitor metric wrapper
    'CVSizing.Kubectl.ps1'            # cross-platform kubectl provisioning (Install-CVKubectl, used by AKS)
    'CVSizing.CloudRewind.ps1'        # provider-neutral Cloud Rewind engine
    'CVSizing.CloudRewind.Azure.ps1'  # Azure billable taxonomy + inclusion rules
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

# AKS Helper Functions
function Test-KubectlAvailable {
    try {
        $null = Get-Command kubectl -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Install-Kubectl {
    Write-Host "kubectl not found, attempting to install..." -ForegroundColor Yellow
    
    # Check if we're in Azure Cloud Shell (preferred method)
    if ($env:ACC_CLOUD -eq 'Azure' -or $env:AZUREPS_HOST_ENVIRONMENT -like '*CloudShell*') {
        Write-Host "Detected Azure Cloud Shell environment" -ForegroundColor Cyan
        
        # In Azure Cloud Shell, kubectl should already be available, but if not, use az CLI
        try {
            Write-Host "Installing kubectl via Azure CLI..." -ForegroundColor Cyan
            $result = az aks install-cli --only-show-errors 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "kubectl installed successfully via Azure CLI" -ForegroundColor Green
                return $true
            }
        } catch {
            Write-Verbose "Azure CLI kubectl installation failed: $($_.Exception.Message)"
        }
    }
    
    # Fallback to direct download. Delegated to common/CVSizing.Kubectl.ps1, which resolves BOTH the OS and the
    # architecture at runtime. The previous code here always fetched bin/linux/amd64/kubectl into a hardcoded
    # /tmp/kubectl for every non-Windows host, so on macOS it wrote a Linux ELF binary, chmod +x succeeded, and
    # every later kubectl call failed with an exec-format error. It was also wrong on any arm64 host.
    Write-Host "Installing kubectl via direct download..." -ForegroundColor Cyan
    $k = Install-CVKubectl
    if ($k.Installed) {
        Write-Host "kubectl ready at $($k.Path) [$($k.Platform), $($k.Source)]" -ForegroundColor Green
        return $true
    }
    Write-Warning "Failed to install kubectl for $($k.Platform): $($k.Error)"
    Write-Host "In Azure Cloud Shell, kubectl should be pre-installed. Try running: az aks install-cli" -ForegroundColor Yellow
    return $false
}

function Convert-KubernetesQuantity {
    param([string]$Quantity)
    
    if (-not $Quantity) { return 0 }
    
    # Handle different Kubernetes quantity formats
    if ($Quantity -match '^(\d+\.?\d*)([KMGTPE]i?)?$') {
        $value = [double]$Matches[1]
        $unit = $Matches[2]
        
        switch ($unit) {
            'Ki' { return $value * 1024 }
            'Mi' { return $value * 1024 * 1024 }
            'Gi' { return $value * 1024 * 1024 * 1024 }
            'Ti' { return $value * 1024 * 1024 * 1024 * 1024 }
            'Pi' { return $value * 1024 * 1024 * 1024 * 1024 * 1024 }
            'Ei' { return $value * 1024 * 1024 * 1024 * 1024 * 1024 * 1024 }
            'K' { return $value * 1000 }
            'M' { return $value * 1000 * 1000 }
            'G' { return $value * 1000 * 1000 * 1000 }
            'T' { return $value * 1000 * 1000 * 1000 * 1000 }
            'P' { return $value * 1000 * 1000 * 1000 * 1000 * 1000 }
            'E' { return $value * 1000 * 1000 * 1000 * 1000 * 1000 * 1000 }
            default { return $value }
        }
    } elseif ($Quantity -match '^(\d+)$') {
        return [double]$Matches[1]
    }
    
    return 0
}

function Get-AKSPersistentVolumeInfo {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ClusterName,
        [Parameter(Mandatory=$true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory=$true)]
        [string]$SubscriptionId
    )
    
    $pvInfo = @{
        PersistentVolumes = @()
        PersistentVolumeClaims = @()
        TotalCapacityGB = 0
        TotalVolumeCount = 0
        TotalPVCCount = 0
        AccessError = $null
    }
    
    try {
        # Get AKS cluster credentials using PowerShell cmdlet
        Write-Verbose "Getting credentials for AKS cluster $ClusterName"
        Import-AzAksCredential -ResourceGroupName $ResourceGroupName -Name $ClusterName -SubscriptionId $SubscriptionId -Force -ErrorAction Stop
        
        # Test kubectl access with a simple command first
        Write-Verbose "Testing kubectl access for cluster $ClusterName"
        $testResult = kubectl get nodes --request-timeout=10s 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            $errorMessage = "Failed to access AKS cluster $ClusterName with kubectl. This requires proper Azure Kubernetes Service permissions (Cluster User Role or higher). Error: $testResult"
            Write-Warning $errorMessage
            $pvInfo.AccessError = $errorMessage
            return $pvInfo
        }
        
        # Get Persistent Volumes
        Write-Verbose "Getting Persistent Volumes for cluster $ClusterName"
        $pvJson = kubectl get pv -o json --request-timeout=30s 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            $errorMessage = "Failed to get persistent volumes from cluster $ClusterName. Error: $pvJson"
            Write-Warning $errorMessage
            $pvInfo.AccessError = $errorMessage
            return $pvInfo
        }
        
        if ($pvJson) {
            try {
                $pvData = $pvJson | ConvertFrom-Json
                
                foreach ($pv in $pvData.items) {
                    if (-not $pv.metadata.name) { continue }
                    
                    $capacityBytes = 0
                    if ($pv.spec.capacity.storage) {
                        $capacityBytes = Convert-KubernetesQuantity -Quantity $pv.spec.capacity.storage
                    }
                    
                    $capacityGB = [math]::Round($capacityBytes / 1GB, 4)
                    $pvInfo.TotalCapacityGB += $capacityGB
                    $pvInfo.TotalVolumeCount++
                    
                    $AKSVolume = [PSCustomObject]@{
                        ClusterName = $ClusterName
                        ResourceGroup = $ResourceGroupName
                        Subscription = (Get-AzContext).Subscription.Name
                        PVName = $pv.metadata.name
                        StorageClass = $pv.spec.storageClassName
                        CapacityBytes = [int64]$capacityBytes
                        CapacityGB = $capacityGB
                        AccessModes = ($pv.spec.accessModes -join ', ')
                        ReclaimPolicy = $pv.spec.persistentVolumeReclaimPolicy
                        Status = $pv.status.phase
                        VolumeMode = $pv.spec.volumeMode
                        ClaimNamespace = $pv.spec.claimRef.namespace
                        ClaimName = $pv.spec.claimRef.name
                        CreationTimestamp = $pv.metadata.creationTimestamp
                    }
                    
                    $pvInfo.PersistentVolumes += $AKSVolume
                }
                
                Write-Verbose "Found $($pvData.items.Count) Persistent Volumes in cluster $ClusterName"
            } catch {
                $errorMessage = "Failed to parse PV JSON for cluster $ClusterName`: $($_.Exception.Message)"
                Write-Warning $errorMessage
                $pvInfo.AccessError = $errorMessage
                return $pvInfo
            }
        }
        
        # Get Persistent Volume Claims
        Write-Verbose "Getting Persistent Volume Claims for cluster $ClusterName"
        $pvcJson = kubectl get pvc -A -o json --request-timeout=30s 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            $errorMessage = "Failed to get persistent volume claims from cluster $ClusterName. Error: $pvcJson"
            Write-Warning $errorMessage
            $pvInfo.AccessError = $errorMessage
            return $pvInfo
        }
        
        if ($pvcJson) {
            try {
                $pvcData = $pvcJson | ConvertFrom-Json
                
                foreach ($pvc in $pvcData.items) {
                    if (-not $pvc.metadata.name) { continue }
                    
                    $requestedBytes = 0
                    $capacityBytes = 0
                    
                    if ($pvc.spec.resources.requests.storage) {
                        $requestedBytes = Convert-KubernetesQuantity -Quantity $pvc.spec.resources.requests.storage
                    }
                    
                    if ($pvc.status.capacity.storage) {
                        $capacityBytes = Convert-KubernetesQuantity -Quantity $pvc.status.capacity.storage
                    }
                    
                    $requestedGB = [math]::Round($requestedBytes / 1GB, 4)
                    $capacityGB = [math]::Round($capacityBytes / 1GB, 4)
                    
                    $AKSPVC = [PSCustomObject]@{
                        ClusterName = $ClusterName
                        ResourceGroup = $ResourceGroupName
                        Subscription = (Get-AzContext).Subscription.Name
                        Namespace = $pvc.metadata.namespace
                        PVCName = $pvc.metadata.name
                        StorageClass = $pvc.spec.storageClassName
                        RequestedBytes = [int64]$requestedBytes
                        RequestedGB = $requestedGB
                        CapacityBytes = [int64]$capacityBytes
                        CapacityGB = $capacityGB
                        AccessModes = ($pvc.spec.accessModes -join ', ')
                        Status = $pvc.status.phase
                        VolumeMode = $pvc.spec.volumeMode
                        VolumeName = $pvc.spec.volumeName
                        CreationTimestamp = $pvc.metadata.creationTimestamp
                    }
                    
                    $pvInfo.PersistentVolumeClaims += $AKSPVC
                    $pvInfo.TotalPVCCount++
                }
                
                Write-Verbose "Found $($pvcData.items.Count) Persistent Volume Claims in cluster $ClusterName"
            } catch {
                $errorMessage = "Failed to parse PVC JSON for cluster $ClusterName`: $($_.Exception.Message)"
                Write-Warning $errorMessage
                $pvInfo.AccessError = $errorMessage
                return $pvInfo
            }
        }
        
    } catch {
        $errorMessage = "Error accessing AKS cluster $ClusterName. This requires proper Azure Kubernetes Service permissions: $($_.Exception.Message)"
        Write-Warning $errorMessage
        $pvInfo.AccessError = $errorMessage
    }
    
    return $pvInfo
}  

# Set culture to en-US for consistent date and time formatting
$CurrentCulture = [System.Globalization.CultureInfo]::CurrentCulture
[System.Threading.Thread]::CurrentThread.CurrentCulture = 'en-US'
[System.Threading.Thread]::CurrentThread.CurrentUICulture = 'en-US'
  
# Resource type mapping  
$ResourceTypeMap = @{  
    "VM"             = "VMs"  
    "STORAGE"        = "StorageAccounts"
    "FILESHARE"      = "FileShares"
    "NETAPP"         = "NetAppVolumes"
    "SQL"            = "SqlInventory"
    "COSMOS"         = "CosmosDBs"
    "AKS"            = "AKSClusters"
    "BACKUP"         = "BackupItems"
    "UNMANAGEDDISKS" = "UnmanagedDisks"
    "AVS"            = "AVSClusters"
}

# Back-compat: the canonical key was misspelled "UNMANAGEDISKS" (one D), so the documented `-Types UnmanagedDisks`
# was rejected and the error message named the very spelling that failed - only the typo worked. Both are accepted
# now and normalized to the canonical key below.
$TypeAliases = @{
    "UNMANAGEDISKS"   = "UNMANAGEDDISKS"
    "UNMANAGEDDISK"   = "UNMANAGEDDISKS"
    "DISKS"           = "UNMANAGEDDISKS"
    "RECOVERYSERVICES" = "BACKUP"
    "FILESHARES"      = "FILESHARE"
    "VMS"             = "VM"
}

# Environment tag filter helper — returns $true if resource should be included
function Test-EnvTagMatch {
    param([hashtable]$Tags)
    if (-not $EnvTagValues -or $EnvTagValues.Count -eq 0) { return $true }
    if (-not $Tags) { return $false }
    $tagVal = $Tags[$EnvTagName]
    if (-not $tagVal) { return $false }
    return ($EnvTagValues | Where-Object { $_ -ieq $tagVal }).Count -gt 0
}
  
# Normalize types
if ($Types) {
    # Split on commas as well as taking the array as given. `pwsh -File script.ps1 -Types VM,SQL` hands the whole
    # list over as ONE string (unlike `-Command` or a direct call from a session, which bind an array), so every
    # type came through as the single unmatched value "VM,SQL" - and the error then listed VM and SQL among the
    # valid types it had just rejected. Splitting here makes all three invocation styles behave the same.
    $Types = $Types | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ }
    $Selected = @{}
    $invalidTypes = @()
    foreach ($t in $Types) {
        $key = if ($TypeAliases.ContainsKey($t)) { $TypeAliases[$t] } else { $t }
        if ($ResourceTypeMap.ContainsKey($key)) {
            $Selected[$key] = $true
        } else {
            $invalidTypes += $t
        }
    }
    # The valid-values text is generated from the map so it can never again advertise a spelling the code rejects.
    $validTypeList = ($ResourceTypeMap.Keys | Sort-Object) -join ', '
    if ($invalidTypes.Count -gt 0) {
        Write-Host "Invalid type(s) specified: $($invalidTypes -join ', '). Valid types are: $validTypeList" -ForegroundColor Red
    }
    if ($Selected.Count -eq 0) {
        Write-Host "No valid -Types specified. Use: $validTypeList" -ForegroundColor Red
        exit 1
    }
} else {  
    $Selected = @{}  
    $ResourceTypeMap.Keys | ForEach-Object { $Selected[$_] = $true }  
}

# -SkipDataProtection: run Cloud Rewind only. Clearing $Selected skips every DP per-service block (all guarded
# by $Selected.<type>) and their CSVs, while the subscription loop still runs for the Cloud Rewind sweep.
if ($SkipDataProtection) { $Selected = @{} }

# Fold the legacy -EnvTagName/-EnvTagValues filter into the unified -Tags filter (Key=Value), so both passes
# share one filter surface.
if ($EnvTagValues -and $EnvTagValues.Count) {
    $Tags = @($Tags) + @($EnvTagValues | ForEach-Object { "$EnvTagName=$_" })
}

# Early kubectl availability check if AKS is selected
if ($Selected.AKS) {
    Write-Host "AKS resource type selected - checking kubectl availability..." -ForegroundColor Cyan
    
    if (-not (Test-KubectlAvailable)) {
        Write-Host "kubectl not found, attempting installation..." -ForegroundColor Yellow
        if (-not (Install-Kubectl)) {
            Write-Warning "kubectl is not available and could not be installed."
            Write-Warning "AKS persistent volume information will be limited to basic cluster details only."
            Write-Host "To get full AKS storage information, please ensure kubectl is available." -ForegroundColor Yellow
        } else {
            Write-Host "kubectl is now available for AKS operations" -ForegroundColor Green
        }
    } else {
        Write-Host "kubectl is available for AKS operations" -ForegroundColor Green
    }
}  
  
# Output Directory and Logging
$dateStr = Get-Date -Format "yyyy-MM-dd_HHmmss"  
# Resolve this run's Output/ and Logs/ directories at the repo top level (or CWD when run outside the repo).
$runPaths = Initialize-CVRunPaths -Cloud 'Azure' -TimeStamp $dateStr -StartPath $PSScriptRoot -OutputRoot $OutputDirectory
$outdir = $runPaths.OutputDir  
New-Item -ItemType Directory -Force -Path $outdir | Out-Null

# Create comprehensive log file that captures everything
$logFile = $runPaths.LogPath   # top-level Logs/<run>.log, kept separate from the CSV output

# Start transcript to capture everything to the log file. The shared console layer then runs in console-only mode
# on top: the transcript owns the file, while the layer adds tiered rendering, error de-duplication and the run
# summary. Native Az breaking-change warnings (the historical log noise) are suppressed at the source below.
Start-Transcript -Path $logFile -Append

# --- Preflight (fail fast, plain) then initialize the shared console layer ---
$peek = Get-CVConsoleCapability -NonInteractive:$NonInteractive -Quiet:$Quiet
# Highly opinionated: require EVERY Az module the script can use, so discovery is always broad. A partial
# inventory (e.g. silently skipping SQL/Backup/AVS) is worse than a clear "install these first" message.
$fatalModules = @(
    'Az.Accounts','Az.Compute','Az.Storage','Az.Monitor','Az.Resources','Az.NetAppFiles','Az.CosmosDB',
    'Az.Sql','Az.MySql','Az.PostgreSql','Az.Aks','Az.RecoveryServices','Az.VMware'
)
if (-not $peek.IsHeadless) { $fatalModules += 'PwshSpectreConsole' }
if (-not $SkipCloudRewind) { $fatalModules += 'Az.Network' }   # Cloud Rewind ARM-fallback attach checks (public IP / NIC)
# Resource Graph is the default Cloud Rewind discovery backend but SOFT: if Az.ResourceGraph is absent we warn
# and fall back to the Get-AzResource (ARM) path rather than aborting the run.
$optionalModules = @{}
if (-not $SkipCloudRewind -and $CloudRewindDiscovery -eq 'Graph') { $optionalModules['Cloud Rewind Resource Graph discovery'] = 'Az.ResourceGraph' }
Assert-CVPreflight -FatalModules $fatalModules -OptionalModules $optionalModules -ExitOnFatal | Out-Null

# Initialize-CVConsole also calls Set-CVNativeNoiseSuppression -Provider Azure, which sets the
# SuppressAzurePowerShellBreakingChangeWarnings env var before the Az modules load below.
Initialize-CVConsole -Cloud Azure -Title 'Azure Resource Inventory' `
                     -NonInteractive:$NonInteractive -Quiet:$Quiet | Out-Null
if ($Types)         { Write-CVLog "Types: $($Types -join ', ')" -Level Info -Source 'Init' }
if ($Subscriptions) { Write-CVLog "Subscriptions: $($Subscriptions -join ', ')" -Level Info -Source 'Init' }

# Everything below runs inside a top-level handler. Without one, an unhandled terminating error produced no run
# summary, no diagnostics and no Stop-Transcript - the user saw a raw stack trace and no indication of what had
# already been collected. (AWS has had this; Azure and GCP did not.)
try {

# Helper function to determine if a storage account supports Azure Files
function Get-AzureFileSAs {
    param (
        [Parameter(Mandatory=$true)]
        [PSObject]$StorageAccount
    )

    return ($StorageAccount.Kind -in @('StorageV2', 'Storage') -and 
              $StorageAccount.Sku.Name -notin @('Premium_LRS', 'Premium_ZRS')) -or
              ($StorageAccount.Kind -eq 'FileStorage' -and 
              $StorageAccount.Sku.Name -in @('Premium_LRS', 'Premium_ZRS'))
}

if ($BlobLimit -gt 0) { Write-Host "  BlobLimit: $BlobLimit" -ForegroundColor Green }  
  
# Define module requirements for each resource type
$ResourceTypeModules = @{
    VM             = @('Az.Accounts', 'Az.Compute')
    STORAGE        = @('Az.Accounts', 'Az.Storage', 'Az.Monitor')
    FILESHARE      = @('Az.Accounts', 'Az.Storage')
    NETAPP         = @('Az.Accounts', 'Az.NetAppFiles', 'Az.Monitor', 'Az.Resources')
    SQL            = @('Az.Accounts', 'Az.Sql', 'Az.MySql', 'Az.PostgreSql', 'Az.Monitor')
    COSMOS         = @('Az.Accounts', 'Az.CosmosDB', 'Az.Monitor')
    AKS            = @('Az.Accounts', 'Az.Aks', 'Az.Resources')
    BACKUP         = @('Az.Accounts', 'Az.RecoveryServices')
    UNMANAGEDDISKS = @('Az.Accounts', 'Az.Compute')
    AVS            = @('Az.Accounts', 'Az.VMware')
}

# Every required Az module was verified present by the preflight above (the script is opinionated: all-or-nothing).
# Import Az.Accounts (needed immediately for subscription discovery) then the modules the selected -Types need.
#
# This ORDER is load-bearing, not stylistic. Each Az.<Service>.psm1 imports Az.Accounts for itself only when none
# is loaded yet ("elseif ($module -eq $null) { Import-Module Az.Accounts -MinimumVersion x.y.z -Scope Global }").
# On a machine with Az.Accounts installed in more than one scope, letting several service modules each resolve it
# independently can pull in two different copies - and because Az.Accounts declares its DLLs in RequiredAssemblies,
# the second load dies with "Assembly with same name is already loaded", unrecoverably, mid-run. Loading it once
# here first means every module below takes the already-loaded branch. Assert-CVPreflight backstops the cases this
# ordering cannot fix (see Test-CVAzModuleConflict).
Import-Module Az.Accounts -ErrorAction Stop
foreach ($svc in @($Selected.Keys)) {
    foreach ($m in ($ResourceTypeModules[$svc] | Select-Object -Unique)) {
        if (-not (Get-Module -Name $m)) { Import-Module $m -ErrorAction Stop }
    }
}

# Cloud Rewind sweep needs Az.Resources (Get-AzResource) + Az.Compute/Az.Network (attach checks), independent of -Types.
if (-not $SkipCloudRewind) {
    foreach ($m in @('Az.Resources','Az.Compute','Az.Network')) {
        if (-not (Get-Module -Name $m)) { Import-Module $m -ErrorAction Stop }
    }
}
  
# Subscription discovery  
$allSubs = Get-AzSubscription  
if ($allSubs -isnot [array]) { $allSubs = @($allSubs) }  

# Filter subscriptions if specified
if ($Subscriptions) {
    Write-Host "Filtering subscriptions based on provided list..." -ForegroundColor Yellow
    $subs = @()
    $notFoundSubs = @()
    
    foreach ($subFilter in $Subscriptions) {
        # Trim whitespace from the filter
        $cleanSubFilter = $subFilter.Trim()
        
        # Try exact match first (case-insensitive for names)
        $matchedSubs = $allSubs | Where-Object { 
            $_.Name.Trim() -eq $cleanSubFilter -or 
            $_.Id -eq $cleanSubFilter -or 
            $_.SubscriptionId -eq $cleanSubFilter 
        }
        
        # If no exact match, try case-insensitive name match
        if (-not $matchedSubs) {
            $matchedSubs = $allSubs | Where-Object { 
                $_.Name.Trim() -ieq $cleanSubFilter
            }
        }
        
        if ($matchedSubs) {
            $subs += $matchedSubs
            Write-Host "Found subscription: '$($matchedSubs.Name)' (ID: $($matchedSubs.Id))" -ForegroundColor Green
        } else {
            $notFoundSubs += $cleanSubFilter
            Write-Warning "Subscription '$cleanSubFilter' not found or not accessible"
        }
    }
    
    # Show available subscriptions if some weren't found
    if ($notFoundSubs.Count -gt 0) {
        Write-Host "`nAvailable subscriptions:" -ForegroundColor Yellow
        $allSubs | ForEach-Object { Write-Host "  - '$($_.Name)' (ID: $($_.Id))" -ForegroundColor Cyan }
    }
    
    if ($subs.Count -eq 0) {
        Write-Error "No valid subscriptions found from the provided list. Exiting."
        exit 1
    }
} else {
    Write-Host "No subscription filter specified, targeting all accessible subscriptions..." -ForegroundColor Yellow
    $subs = $allSubs
}

Write-Host "Targeting $($subs.Count) subscriptions: $($subs.Name -join ', ')" -ForegroundColor Green  

# Global output arrays for all resources
$VMs = @()  
$StorageAccounts = @()  
$FileShares = @()  
$NetAppVolumes = @()  
# Renamed SQL collections to reduce similarity with original source
$SqlInstancesInventory = @()
$SqlDbInventory = @()
$SqlMIDbInventory = @()
$CosmosDBs = @()
$MySQLServers = @()
$PostgreSQLServers = @()
$AKSClusters = @()
$AKSPersistentVolumes = @()
$AKSPersistentVolumeClaims = @()
$BackupItems = @()
$AzSnapshots = @()   # managed-disk snapshots (attributed to VMs after the subscription loop)
$VMDiskIdMap = @{}   # "<subscription>|<vmName>" -> that VM's managed-disk resource IDs
$UnmanagedDiskItems = @()
$AVSClusters = @()

# Process each subscription sequentially
$subIdx = 0
# -SkipDataProtection: skip the entire Data Protection pipeline (subscription loop + protection enrichment +
# coverage) so only the Cloud Rewind pass below runs. DP arrays stay empty; downstream DP CSV/summary/JSON
# exports are guarded by $Selected/.Count and no-op. (Cloud Rewind has its own subscription loop.)
if (-not $SkipDataProtection) {
$savedEAP = $ErrorActionPreference   # restored in the finally below so the per-iteration "Stop" cannot leak out
try {
foreach ($sub in $subs) {
    $subIdx++
    Write-Progress -Id 1 -Activity "Processing Azure Subscriptions" -Status "Subscription $subIdx of $($subs.Count): $($sub.Name)" -PercentComplete (($subIdx / $subs.Count) * 100)

    $ErrorActionPreference = "Stop"
    # Unguarded under "Stop", one inaccessible subscription aborted the ENTIRE loop - skipping every remaining
    # subscription and, because the abort escaped past the export section, producing no CSVs, no JSON, no ZIP and
    # no Stop-Transcript. Mark this subscription's signals uncollected and move to the next one.
    try {
        Set-AzContext -SubscriptionId $sub.Id -ErrorAction Stop | Out-Null
    } catch {
        foreach ($sig in @('BACKUP','SNAPSHOT')) { Set-CVCollectionStatus -Scope $sub.Name -Signal $sig -Status Failed }
        Write-CVLog "Could not select subscription - skipping it: $($_.Exception.Message)" -Level Error -Source 'Auth' -Scope @{ Subscription = $sub.Name; Category = 'ContextFailed' }
        continue
    }

    # VMs  
    # ---------------------------------------------------------------
    # ENVIRONMENT TAG FILTER: log filter status once per subscription
    # ---------------------------------------------------------------
    if ($EnvTagValues -and $EnvTagValues.Count -gt 0) {
        Write-Host "  [EnvFilter] Filtering to resources where tag '$EnvTagName' in ($($EnvTagValues -join ', '))" -ForegroundColor DarkCyan
    }

    if ($Selected.VM) {  
        try {
            Write-Host "Processing Virtual Machines in subscription $($sub.Name)" -ForegroundColor Green
            # -Status is required for PowerState. Without it the list call returns PSVirtualMachine, which carries
            # no run-state at all, so the PowerState column was empty on every row this script has ever written.
            # -Status returns PSVirtualMachineListStatus, verified to be a strict SUPERSET of PSVirtualMachine
            # (StorageProfile/HardwareProfile/Tags all still present, so disk sizing is unaffected), and it is
            # still ONE ARM list call - statusOnly=true, not a per-VM instance-view fetch.
            $vmList = Get-AzVM -Status
            if ($vmList) {
                $vmCount = 0
                foreach ($vm in $vmList) {  
                    $vmCount++
                    $vmPercentComplete = [math]::Round(($vmCount / $vmList.Count) * 100, 1)
                    Write-Progress -Id 2 -ParentId 1 -Activity "Processing Virtual Machines" -Status "Processing VM $vmCount of $($vmList.Count) - $vmPercentComplete% complete" -PercentComplete $vmPercentComplete
                    
                    # Calculate disk information
                $diskCount = 0
                $totalDiskSizeGB = 0         
                # OS Disk - get actual disk object for size
                if ($vm.StorageProfile.OsDisk) {
                    $diskCount++
                    try {
                        if ($vm.StorageProfile.OsDisk.DiskSizeGB) {
                        
                            $totalDiskSizeGB += $vm.StorageProfile.OsDisk.DiskSizeGB
                        } elseif($vm.StorageProfile.OsDisk.ManagedDisk) {
                            # Managed disk - get the disk resource
                            $osDiskName = $vm.StorageProfile.OsDisk.Name
                            $osDisk = Get-AzDisk -ResourceGroupName $vm.ResourceGroupName -DiskName $osDiskName -ErrorAction SilentlyContinue
                            if ($osDisk -and $osDisk.DiskSizeGB) {
                                $totalDiskSizeGB += $osDisk.DiskSizeGB
                            }
                        } else {
                            Write-CVLog "Could not get data disk size for OS disk" -Level Warning -Source 'VM' -Scope @{ Subscription = $sub.Name; VM = $vm.Name }

                        }
                    } catch {
                        Write-CVLog "Could not get OS disk size for VM: $($_.Exception.Message)" -Level Warning -Source 'VM' -Scope @{ Subscription = $sub.Name; VM = $vm.Name }
                    }
                }
                
                # Data Disks - get actual disk objects for sizes
                if ($vm.StorageProfile.DataDisks) {
                    $diskCount += $vm.StorageProfile.DataDisks.Count
                    foreach ($dataDisk in $vm.StorageProfile.DataDisks) {
                        try {
                            if ($dataDisk.DiskSizeGB) {
                              
                                $totalDiskSizeGB += $dataDisk.DiskSizeGB
                            } elseif ($dataDisk.ManagedDisk) {
                                # Managed disk and VM is Powered Off - get the disk resource
                                $diskName = $dataDisk.Name
                                $disk = Get-AzDisk -ResourceGroupName $vm.ResourceGroupName -DiskName $diskName -ErrorAction SilentlyContinue
                                if ($disk -and $disk.DiskSizeGB) {
                                    $totalDiskSizeGB += $disk.DiskSizeGB
                                }
                            } 
                        } catch {
                            Write-CVLog "Could not get data disk size: $($_.Exception.Message)" -Level Warning -Source 'VM' -Scope @{ Subscription = $sub.Name; VM = $vm.Name; Disk = $dataDisk.Name }
                        }
                    }
                }
                
                # Apply environment tag filter
                if (-not (Test-EnvTagMatch -Tags $vm.Tags)) { continue }

                # Flatten tags into Tag_Key columns
                $vmObj = [ordered]@{
                    Subscription   = $sub.Name  
                    ResourceGroup  = $vm.ResourceGroupName  
                    VMName         = $vm.Name  
                    ResourceId     = $vm.Id                 # ARM id - the stable key for joins / portal lookup
                    VMSize         = $vm.HardwareProfile.VmSize  
                    OS             = $vm.StorageProfile.OsDisk.OsType  
                    Region         = $vm.Location
                    # The list form (-Status) exposes PowerState directly as a string ("VM running"); the
                    # single-VM/instance-view shape exposes it only under Statuses. Handle both rather than
                    # assuming, and leave it blank - never a guess - if neither is populated.
                    PowerState     = $(
                        if ($vm.PSObject.Properties['PowerState'] -and $vm.PowerState) { $vm.PowerState }
                        elseif ($vm.PSObject.Properties['Statuses']) {
                            $vm.Statuses | Where-Object Code -like 'PowerState/*' | Select-Object -First 1 -ExpandProperty DisplayStatus
                        }
                    )
                    DiskCount      = $diskCount
                    VMDiskSizeGB   = $totalDiskSizeGB
                    # Protection coverage - $null, NOT $false. These are placeholders until the enrichment pass
                    # runs, and $false is a scored Gap: initializing to it meant any failure to collect backup
                    # data was reported as an affirmative "this VM is not protected".
                    BackupEnabled    = $null
                    BackupCount      = $null
                    LastBackupTimeUtc = ''
                    BackupPolicy     = ''
                    SnapshotsEnabled = $null
                    SnapshotCount    = $null
                    SnapshotSourceDiskTB = $null   # TB only - the sizing spreadsheet takes TB; mixed units invite copy/paste errors
                }
                # Remember this VM's managed-disk IDs so snapshots can be attributed back to it. Keyed WITH the
                # resource group: two VMs may share a name across resource groups, and the previous key omitted
                # it, so the second VM overwrote the first and the first lost all its snapshots.
                $vmDiskIds = @()
                if ($vm.StorageProfile.OsDisk.ManagedDisk.Id) { $vmDiskIds += $vm.StorageProfile.OsDisk.ManagedDisk.Id }
                foreach ($dd in $vm.StorageProfile.DataDisks) {
                    if ($dd.ManagedDisk.Id) { $vmDiskIds += $dd.ManagedDisk.Id }
                }
                $vmDiskKey = Get-CVAzureBackupKey -Subscription $sub.Name -ResourceGroup $vm.ResourceGroupName -Name $vm.Name
                if ($VMDiskIdMap.ContainsKey($vmDiskKey)) { $VMDiskIdMap[$vmDiskKey] = @($VMDiskIdMap[$vmDiskKey]) + $vmDiskIds }
                else                                      { $VMDiskIdMap[$vmDiskKey] = $vmDiskIds }
                if ($vm.Tags) { $vm.Tags.GetEnumerator() | ForEach-Object { $vmObj["Tag_$($_.Key)"] = $_.Value } }
                $VMs += [PSCustomObject]$vmObj
            }
            }
            Write-Progress -Id 2 -Activity "Processing Virtual Machines" -Completed
        } catch {
            Write-CVLog "Error getting VMs: $($_.Exception.Message)" -Level Warning -Source 'VM' -Scope @{ Subscription = $sub.Name }
        }  
    }  
    # Managed-disk snapshots: listed once per subscription, attributed to VMs after the loop.
    if (-not $Selected.VM) {
        Set-CVCollectionStatus -Scope $sub.Name -Signal SNAPSHOT -Status Skipped
    } else {
        try {
            foreach ($snap in @(Get-AzSnapshot -ErrorAction Stop)) {
                if (-not $snap) { continue }
                $AzSnapshots += [PSCustomObject]@{
                    Subscription     = $sub.Name
                    SnapshotName     = $snap.Name
                    ResourceGroup    = $snap.ResourceGroupName
                    Region           = $snap.Location
                    SourceDiskId     = $snap.CreationData.SourceResourceId
                    # The PROVISIONED size of the source disk, not the snapshot's own consumed bytes - Azure
                    # exposes no consumed-bytes property for incremental snapshots. Named accordingly so the
                    # column cannot be mistaken for billable snapshot capacity.
                    SourceDiskSizeGB = [double]$snap.DiskSizeGB
                    Incremental      = [bool]$snap.Incremental
                    TimeCreated      = $snap.TimeCreated
                }
            }
            Set-CVCollectionStatus -Scope $sub.Name -Signal SNAPSHOT -Status Ok
        } catch {
            # A failed listing is not "no snapshots" - leave it Unknown so no disk is scored as uncovered.
            Set-CVCollectionStatus -Scope $sub.Name -Signal SNAPSHOT -Status Failed
            Write-CVLog "Could not list managed-disk snapshots - snapshot coverage will report Unknown, not zero: $($_.Exception.Message)" -Level Warning -Source 'Snapshot' -Scope @{ Subscription = $sub.Name }
        }
    }

    # Storage Accounts - Get all storage accounts once if either STORAGE or FILESHARE is selected
    if ($Selected.STORAGE -or $Selected.FILESHARE) {  
        try {
            $accounts = Get-AzStorageAccount  
            if ($accounts) {
                
                # Process Storage Account metrics if selected
                if ($Selected.STORAGE) {
                    Write-Host "Processing Storage Accounts in subscription $($sub.Name)" -ForegroundColor Green
                    $saCount = 0
                    foreach ($sa in $accounts) {  
                        $saCount++
                        $saPercentComplete = [math]::Round(($saCount / $accounts.Count) * 100, 1)
                        Write-Progress -Id 3 -ParentId 1 -Activity "Processing Storage Account Metrics" -Status "Processing Storage Account $saCount of $($accounts.Count) - $saPercentComplete% complete" -PercentComplete $saPercentComplete
                        try {
                        # Storage capacity metrics. BlobCapacity/BlobCount/ContainerCount are DAILY metrics with
                        # ingestion lag, and this used to request a ONE HOUR window - so the query usually returned
                        # no datapoints and the resulting 0 was reported as a measured empty account. Every
                        # capacity column read 0. Get-CVAzMetricValue widens the window and, critically,
                        # distinguishes "no datapoint" ($null) from a measured zero.
                        $resourceId = $sa.Id
                        $blobRes = Get-CVAzMetricValueSet -ResourceId "$resourceId/blobServices/default" `
                                        -MetricName @('BlobCapacity','ContainerCount','BlobCount')
                        $acctRes = Get-CVAzMetricValueSet -ResourceId $resourceId `
                                        -MetricName @('UsedCapacity')

                        $blobCapacity   = $blobRes['BlobCapacity'].Value
                        $containerCount = $blobRes['ContainerCount'].Value
                        $blobCount      = $blobRes['BlobCount'].Value
                        # Account-level UsedCapacity spans blob+file+table+queue. The old code assigned the BLOB
                        # figure to both UsedCapacity* and UsedBlobCapacity*, so ten columns carried two numbers.
                        $usedCapacity   = $acctRes['UsedCapacity'].Value
                        if ($null -eq $usedCapacity) { $usedCapacity = $blobCapacity }   # fall back, still may be $null

                        foreach ($m in @('BlobCapacity','ContainerCount','BlobCount')) {
                            if ($blobRes[$m].Status -eq 'Error') {
                                Write-CVLog "Storage metric $m unavailable: reported as Unknown, not zero." -Level Warning -Source 'Storage' `
                                            -Scope @{ Subscription = $sub.Name; StorageAccount = $sa.StorageAccountName; Category = 'MetricError' }
                            }
                        }

                        # Null-safe scaling: $null in must stay $null out, so an unmeasured account never
                        # contributes a fabricated 0 to the sizing totals.
                        $scale = { param($bytes, $divisor, $round) if ($null -eq $bytes) { $null } else { [math]::Round(($bytes / $divisor), $round) } }

                        $azSAObj = [ordered] @{}
                        $azSAObj.Add("StorageAccount",$sa.StorageAccountName)
                        $azSAObj.Add("ResourceId",$sa.Id)
                        $azSAObj.Add("StorageAccountType",$sa.Kind)
                        $azSAObj.Add("HNSEnabled(ADLSGen2)",$sa.EnableHierarchicalNamespace)
                        $azSAObj.Add("StorageAccountSkuName",$sa.Sku.Name)
                        $azSAObj.Add("StorageAccountSkuTier",$sa.Sku.Tier)
                        $azSAObj.Add("StorageAccountAccessTier",$sa.AccessTier)
                        $azSAObj.Add("Subscription",$sub.Name)
                        $azSAObj.Add("Region",$sa.PrimaryLocation)
                        $azSAObj.Add("SecondaryRegion",$sa.SecondaryLocation)
                        $azSAObj.Add("ResourceGroup",$sa.ResourceGroupName)
                        $azSAObj.Add("CreationTime",$sa.CreationTime)
                        $azSAObj.Add("MinimumTlsVersion",$sa.MinimumTlsVersion)
                        $azSAObj.Add("AllowSharedKeyAccess",$sa.AllowSharedKeyAccess)
                        $azSAObj.Add("ImmutableStorageWithVersioning",$sa.ImmutableStorageWithVersioning.Enabled)
                        $azSAObj.Add("UsedCapacityBytes",$usedCapacity)
                        $azSAObj.Add("UsedCapacityGiB",(& $scale $usedCapacity 1073741824 0))
                        $azSAObj.Add("UsedCapacityTiB",(& $scale $usedCapacity 1099511627776 4))
                        $azSAObj.Add("UsedCapacityGB",(& $scale $usedCapacity 1000000000 3))
                        $azSAObj.Add("UsedCapacityTB",(& $scale $usedCapacity 1000000000000 4))
                        $azSAObj.Add("UsedBlobCapacityBytes",$blobCapacity)
                        $azSAObj.Add("UsedBlobCapacityGiB",(& $scale $blobCapacity 1073741824 0))
                        $azSAObj.Add("UsedBlobCapacityTiB",(& $scale $blobCapacity 1099511627776 4))
                        $azSAObj.Add("UsedBlobCapacityGB",(& $scale $blobCapacity 1000000000 3))
                        $azSAObj.Add("UsedBlobCapacityTB",(& $scale $blobCapacity 1000000000000 4))
                        $azSAObj.Add("BlobContainerCount",$containerCount)
                        $azSAObj.Add("BlobCount",$blobCount)
                        $azSAObj.Add("CapacityMetricStatus",$blobRes['BlobCapacity'].Status)

                        # ── Resilience posture signals ──────────────────────────────────────────────────────
                        # Collected HERE, inside the subscription loop, because Set-AzContext currently points at
                        # this account's subscription. The previous code did this in a post-loop pass with no
                        # -SubscriptionId, so every lookup ran against whichever subscription the loop happened to
                        # finish on: in a multi-subscription run only the LAST subscription's accounts were
                        # enriched, and the rest silently reported versioning/CMK/public-access/soft-delete as
                        # Unknown. $sa already carries the account-level properties, so this is also one fewer
                        # API call per account than the re-fetch it replaces.
                        $azSAObj.Add("PublicAccessBlocked", $(if ($null -eq $sa.AllowBlobPublicAccess) { $null } else { $sa.AllowBlobPublicAccess -eq $false }))
                        $azSAObj.Add("CmkEncrypted",        $(if (-not $sa.Encryption) { $null } else { "$($sa.Encryption.KeySource)" -eq 'Microsoft.Keyvault' }))

                        # st-immutable used to read a field nothing ever set, so it was permanently Unknown on
                        # every account. "Locked" is the meaningful state: an unlocked policy can be removed, so
                        # it is not WORM protection. When the state is not reported, fall back to Enabled.
                        $immLocked = $null
                        if ($null -ne $sa.ImmutableStorageWithVersioning) {
                            $imm = $sa.ImmutableStorageWithVersioning
                            if ($imm.Enabled -ne $true) { $immLocked = $false }
                            elseif ($imm.ImmutabilityPolicy -and -not [string]::IsNullOrWhiteSpace("$($imm.ImmutabilityPolicy.State)")) {
                                $immLocked = ("$($imm.ImmutabilityPolicy.State)" -eq 'Locked')
                            } else { $immLocked = $true }
                        }
                        $azSAObj.Add("ImmutabilityLocked", $immLocked)

                        # Blob service properties need their own call - they are not on the account object.
                        try {
                            $bsp = Get-AzStorageBlobServiceProperty -ResourceGroupName $sa.ResourceGroupName -StorageAccountName $sa.StorageAccountName -ErrorAction Stop
                            $azSAObj.Add("BlobVersioning",    [bool]$bsp.IsVersioningEnabled)
                            $azSAObj.Add("SoftDeleteEnabled", [bool]$bsp.DeleteRetentionPolicy.Enabled)
                        } catch {
                            # Was a bare catch{}. Leaving the fields absent is correct (they score Unknown, not a
                            # fabricated gap) but the reason has to be visible or the Unknown is unactionable.
                            Write-CVLog "Blob service properties unavailable - versioning/soft-delete will report Unknown: $($_.Exception.Message)" `
                                        -Level Warning -Source 'Storage' `
                                        -Scope @{ Subscription = $sub.Name; StorageAccount = $sa.StorageAccountName; Category = 'BlobPropsUnavailable' }
                        }

                        # Storage was the only collection with no tag flattening, so -Tags/reporting by tag never
                        # worked for it. Matches the VM and disk idiom.
                        if ($sa.Tags) { $sa.Tags.GetEnumerator() | ForEach-Object { $azSAObj["Tag_$($_.Key)"] = $_.Value } }
                        $StorageAccounts += New-Object -TypeName PSObject -Property $azSAObj
                    } catch {
                        Write-CVLog "Error getting storage metrics: $($_.Exception.Message)" -Level Warning -Source 'Storage' -Scope @{ Subscription = $sub.Name; StorageAccount = $sa.StorageAccountName }
                    }
                    }
                    Write-Progress -Id 3 -Activity "Processing Storage Account Metrics" -Completed
                }
                
                # Process File Shares if selected (separate progress tracking)
                if ($Selected.FILESHARE) {
                    Write-Host "Processing File Shares in subscription $($sub.Name)" -ForegroundColor Green
                    $fileShareCount = 0
                    foreach ($sa in $accounts) {  
                        $fileShareCount++
                        $fsPercentComplete = [math]::Round(($fileShareCount / $accounts.Count) * 100, 1)
                        Write-Progress -Id 4 -ParentId 1 -Activity "Processing File Shares" -Status "Processing Storage Account $fileShareCount of $($accounts.Count) for File Shares - $fsPercentComplete% complete" -PercentComplete $fsPercentComplete
                        try {
                            # Check if this storage account supports Azure Files
                            if (Get-AzureFileSAs -StorageAccount $sa) {
                                $storageAccountFileShares = Get-AzRmStorageShare -StorageAccount $sa
                                $currentFileShareDetails = foreach ($fileShare in $storageAccountFileShares) {
                                    $storageAccountName = $fileShare.StorageAccountName
                                    $resourceGroupName = $fileShare.ResourceGroupName
                                    $shareName = $fileShare.Name
                                    Get-AzRmStorageShare -ResourceGroupName $resourceGroupName -StorageAccountName $storageAccountName -Name $shareName -GetShareUsage
                                }
                                
                                # Process each detailed file share from this storage account
                                foreach ($fileShareInfo in $currentFileShareDetails) {
                                    $fileShareObj = [ordered] @{}
                                    $fileShareObj.Add("Name", $fileShareInfo.Name)
                                    $fileShareObj.Add("ResourceId", $fileShareInfo.Id)
                                    $fileShareObj.Add("StorageAccount", $sa.StorageAccountName)
                                    $fileShareObj.Add("StorageAccountType", $sa.Kind)
                                    $fileShareObj.Add("StorageAccountSkuName", $sa.Sku.Name)
                                    $fileShareObj.Add("StorageAccountAccessTier", $sa.AccessTier)
                                    # Determine file share-specific tier if available. If not present, set to 'Unknown' (do NOT fall back to storage account tier).
                                    $shareTier = $null
                                    if ($fileShareInfo -and $fileShareInfo.PSObject.Properties.Name -contains 'AccessTier') {
                                        $shareTier = $fileShareInfo.AccessTier
                                    } elseif ($fileShareInfo -and $fileShareInfo.Properties -and $fileShareInfo.Properties.AccessTier) {
                                        $shareTier = $fileShareInfo.Properties.AccessTier
                                    }
                                    if (-not $shareTier) { $shareTier = 'Unknown' }
                                    $fileShareObj.Add("ShareTier", $shareTier)
                                    $fileShareObj.Add("Subscription", $sub.Name)
                                    $fileShareObj.Add("Region", $sa.PrimaryLocation)
                                    
                                    if ($fileShareInfo.EnabledProtocols) {
                                        $fileShareObj.Add("ProtocolType", ($fileShareInfo.EnabledProtocols -join ", "))
                                    } elseif ($sa.Kind -eq 'StorageV2') {
                                        # StorageV2 accounts primarily support SMB protocol
                                        $fileShareObj.Add("ProtocolType", "SMB")
                                    } else {
                                        $fileShareObj.Add("ProtocolType", "")
                                    }
                                    $fileShareObj.Add("QuotaGiB", $fileShareInfo.QuotaGiB)
                                    $fileShareObj.Add("QuotaTiB", [math]::round(($fileShareInfo.QuotaGiB / 1024), 3))
                                    $fileShareObj.Add("UsedCapacityBytes", $fileShareInfo.ShareUsageBytes)
                                    $fileShareObj.Add("UsedCapacityGiB", [math]::round(($fileShareInfo.ShareUsageBytes / 1073741824), 0))
                                    $fileShareObj.Add("UsedCapacityTiB", [math]::round(($fileShareInfo.ShareUsageBytes / 1073741824 / 1024), 4))
                                    $fileShareObj.Add("UsedCapacityGB", [math]::round(($fileShareInfo.ShareUsageBytes / 1000000000), 3))
                                    $fileShareObj.Add("UsedCapacityTB", [math]::round(($fileShareInfo.ShareUsageBytes / 1000000000000), 4))

                                    $FileShares += New-Object -TypeName PSObject -Property $fileShareObj
                                }
                            } else {
                                Write-Verbose "Skipping File Share query for $($sa.StorageAccountName) because it does not support Azure Files."
                            }
                        } catch {
                            Write-CVLog "Error getting Azure File Storage information: $($_.Exception.Message)" -Level Warning -Source 'FileShare' -Scope @{ Subscription = $sub.Name; StorageAccount = $sa.StorageAccountName }
                        }
                    }
                    Write-Progress -Id 4 -Activity "Processing File Shares" -Completed
                }
            }
            Write-Progress -Id 3 -Activity "Processing Storage Accounts" -Completed
        } catch {
            Write-CVLog "Error getting storage accounts: $($_.Exception.Message)" -Level Warning -Source 'Storage' -Scope @{ Subscription = $sub.Name }
        }  
    }
    
    # NetApp Files
    if ($Selected.NETAPP) {
        try {
            Write-Host "Processing NetApp Volumes in subscription $($sub.Name)" -ForegroundColor Green
            # Time window for metric lookup
            $startTime = (Get-Date).AddHours(-1)
            $endTime = Get-Date
            $timeGrain = New-TimeSpan -Hours 1
            # Get all NetApp Files accounts in this subscription
            try {
                # First get all resource groups, then get NetApp accounts from each.
                # NOTE: must NOT be named $resourceGroups - PowerShell variable names are case-insensitive, so
                # that would overwrite the script's -ResourceGroups parameter and silently scope the whole run.
                $subRgList = Get-AzResourceGroup
                $anfAccounts = @()

                foreach ($rg in $subRgList) {
                    try {
                        $rgNetAppAccounts = Get-AzNetAppFilesAccount -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue
                        if ($rgNetAppAccounts) {
                            $anfAccounts += $rgNetAppAccounts
                        }
                    } catch {
                        # Continue silently if no NetApp accounts in this resource group
                    }
                }
            } catch {
                Write-CVLog "Failed to get NetApp Files accounts: $($_.Exception.Message)" -Level Warning -Source 'NetApp' -Scope @{ Subscription = $sub.Name }
                $anfAccounts = $null
            }
            if ($anfAccounts) {
                $anfCount = 0
                $totalAnfAccounts = ($anfAccounts | Measure-Object).Count
                
                foreach ($account in $anfAccounts) {
                    $anfCount++
                    $anfPercentComplete = [math]::Round(($anfCount / $totalAnfAccounts) * 100, 1)
                    Write-Progress -Id 6 -ParentId 1 -Activity "Processing NetApp Volumes" -Status "Processing NetApp Account $anfCount of $totalAnfAccounts - $anfPercentComplete% complete" -PercentComplete $anfPercentComplete
        
                    try {
                        try {
                            $pools = Get-AzNetAppFilesPool -ResourceGroupName $account.ResourceGroupName -AccountName $account.Name
                        } catch {
                            Write-CVLog "Failed to get NetApp capacity pools: $($_.Exception.Message)" -Level Warning -Source 'NetApp' -Scope @{ Subscription = $sub.Name; Account = $account.Name }
                            continue
                        }
                        
                        foreach ($pool in $pools) {
                            try {
                                # Extract just the pool name part (after the last '/' if present)
                                $poolName = if ($pool.Name -like '*/*') {
                                    ($pool.Name -split '/')[-1]
                                } else {
                                    $pool.Name
                                }
                                
                                $volumes = Get-AzNetAppFilesVolume -ResourceGroupName $account.ResourceGroupName -AccountName $account.Name -PoolName $poolName
                            } catch {
                                Write-CVLog "Failed to get NetApp volumes for capacity pool: $($_.Exception.Message)" -Level Warning -Source 'NetApp' -Scope @{ Subscription = $sub.Name; Account = $account.Name; Pool = $pool.Name }
                                continue
                            }
                            
                            foreach ($vol in $volumes) {
                                # Extract just the volume name part (after the last '/' if present)
                                $volumeName = if ($vol.Name -like '*/*') {
                                    ($vol.Name -split '/')[-1]
                                } else {
                                    $vol.Name
                                }
                                
                                try {
                                    # Get usage metric (LogicalSize)
                                    $usedBytes = 0
                                    try {
                                        # 48h window, not 1h: a quiet volume can easily have no datapoint in the
                                        # last hour, and the 0 that produced was reported as measured usage.
                                        $metric = Get-AzMetric -ResourceId $vol.Id -StartTime (Get-Date).ToUniversalTime().AddHours(-(Get-CVAzMetricWindowHours 'VolumeLogicalSize')) -MetricName "VolumeLogicalSize" -AggregationType Average -WarningAction SilentlyContinue
                                        
                                        if ($metric.Data -and $metric.Data.Count -gt 0) {
                                            $usedBytes = $metric.Data[-1].Average
                                            if (-not $usedBytes) { $usedBytes = 0 }
                                        } else {
                                            Write-CVLog "No usage metric data available for NetApp volume" -Level Debug -Source 'NetApp' -Scope @{ Subscription = $sub.Name; Volume = $volumeName }
                                        }
                                    } catch {
                                        Write-CVLog "Could not get usage metrics for NetApp volume: $($_.Exception.Message)" -Level Warning -Source 'NetApp' -Scope @{ Subscription = $sub.Name; Volume = $volumeName }
                                    }
                                    
                                    $netAppObj = [ordered] @{}
                                    $netAppObj.Add("VolumeName", $volumeName)
                                    $netAppObj.Add("VolumeFullPath", $vol.Name)
                                    $netAppObj.Add("ResourceGroup", $account.ResourceGroupName)
                                    $netAppObj.Add("Subscription", $sub.Name)
                                    $netAppObj.Add("Region", $vol.Location)
                                    $netAppObj.Add("NetAppAccount", $account.Name)
                                    $netAppObj.Add("CapacityPool", $pool.Name)
                                    $netAppObj.Add("ProtocolType", ($vol.ProtocolTypes -join ", "))
                                    $netAppObj.Add("FilePath", $vol.CreationToken)
                                    $netAppObj.Add("ProvisionedGiB", [math]::Round($vol.UsageThreshold / 1GB, 2))
                                    $netAppObj.Add("ProvisionedTiB", [math]::Round($vol.UsageThreshold / 1TB, 4))
                                    $netAppObj.Add("ProvisionedGB", [math]::Round($vol.UsageThreshold / 1000000000, 2))
                                    $netAppObj.Add("ProvisionedTB", [math]::Round($vol.UsageThreshold / 1000000000000, 4))
                                    $netAppObj.Add("UsedCapacityBytes", $usedBytes)
                                    $netAppObj.Add("UsedCapacityGiB", [math]::Round($usedBytes / 1GB, 2))
                                    $netAppObj.Add("UsedCapacityTiB", [math]::Round($usedBytes / 1TB, 4))
                                    $netAppObj.Add("UsedCapacityGB", [math]::Round($usedBytes / 1000000000, 2))
                                    $netAppObj.Add("UsedCapacityTB", [math]::Round($usedBytes / 1000000000000, 4))
                                    $netAppObj.Add("ServiceLevel", $pool.ServiceLevel)
                                    $netAppObj.Add("PoolSizeGiB", [math]::Round($pool.Size / 1GB, 2))
                                    $netAppObj.Add("PoolSizeTiB", [math]::Round($pool.Size / 1TB, 4))
                                    
                                    $NetAppVolumes += New-Object -TypeName PSObject -Property $netAppObj
                                } catch {
                                    Write-CVLog "Error processing NetApp volume: $($_.Exception.Message)" -Level Warning -Source 'NetApp' -Scope @{ Subscription = $sub.Name; Volume = $volumeName }
                                }
                            }
                        }
                    } catch {
                        Write-CVLog "Error getting NetApp pools/volumes: $($_.Exception.Message)" -Level Warning -Source 'NetApp' -Scope @{ Subscription = $sub.Name; Account = $account.Name }
                    }
                }
                Write-Progress -Id 6 -Activity "Processing NetApp Volumes" -Completed
            } else {
                Write-Host "No NetApp Files accounts found in subscription $($sub.Name)" -ForegroundColor Yellow
            }
        } catch {
            Write-CVLog "Error during NetApp Files processing: $($_.Exception.Message)" -Level Warning -Source 'NetApp' -Scope @{ Subscription = $sub.Name }
        }
    }
    
    # SQL Managed Instances
    if ($Selected.SQL) {
        try {
            Write-Host "Processing SQL Managed Instances in subscription $($sub.Name)" -ForegroundColor Green
            $sqlMIList = Get-AzSqlInstance

            if ($sqlMIList) {
                $sqlMICount = 0
                foreach ($sqlMI in $sqlMIList) {
                    $sqlMICount++
                    $sqlMIPercentComplete = [math]::Round(($sqlMICount / $sqlMIList.Count) * 100, 1)
                    Write-Progress -Id 7 -ParentId 1 -Activity "Processing SQL Managed Instances" -Status "Processing SQL MI $sqlMICount of $($sqlMIList.Count) - $sqlMIPercentComplete% complete" -PercentComplete $sqlMIPercentComplete
                    
                    try {
                        # Get storage metrics for SQL MI. $null - not 0 - is the "we did not measure it" value:
                        # 0 has to keep meaning "measured, and it was zero", same discipline as the backup signals.
                        $storageUsedGB = $null
                        $storageAllocatedGB = $null
                        $storageUsedMB = $null
                        # Binary TiB values computed from MB (1024-based) for clarity
                        $storageUsedTiBBinary = $null
                        $storageAllocatedTiBBinary = $null

                        try {
                            # 48h window: a 1h window returned no datapoints often enough that used-storage
                            # reported 0 for instances that were simply idle.
                            #
                            # BOTH metric names must be requested. The switch below has always had a
                            # reserved_storage_mb case, but the request asked for storage_space_used_mb only -
                            # so that case was unreachable and StorageAllocatedGB was 0 on every row.
                            $storageMetrics = Get-AzMetric -ResourceId $sqlMI.Id -StartTime (Get-Date).ToUniversalTime().AddHours(-(Get-CVAzMetricWindowHours 'storage_space_used_mb')) -MetricNames @("storage_space_used_mb", "reserved_storage_mb") -AggregationType Maximum -WarningAction SilentlyContinue

                            if ($storageMetrics) {
                                foreach ($metric in $storageMetrics) {
                                    if ($metric.Data -and $metric.Data.Count -gt 0) {
                                        $latestValue = $metric.Data[-1].Maximum
                                        if ($null -eq $latestValue) { continue }   # no datapoint: leave the column blank
                                        switch ($metric.Name.Value) {
                                            "storage_space_used_mb" {
                                                $valueMiB = [double]$latestValue
                                                $storageUsedMB = $valueMiB
                                                $valueBytes = $valueMiB * 1048576.0    # 1 MiB = 1,048,576 bytes (IEC)
                                                # Decimal GB (SI): 1 GB = 1,000,000,000 bytes
                                                $storageUsedGB = [math]::Round($valueBytes / 1000000000.0, 2)
                                                # Binary TiB (IEC): 1 TiB = 1024^4 bytes
                                                $storageUsedTiBBinary = [math]::Round($valueBytes / 1099511627776.0, 4)
                                            }
                                            "reserved_storage_mb" {
                                                $valueMiB = [double]$latestValue
                                                $valueBytes = $valueMiB * 1048576.0
                                                $storageAllocatedGB = [math]::Round($valueBytes / 1000000000.0, 2)
                                                $storageAllocatedTiBBinary = [math]::Round($valueBytes / 1099511627776.0, 4)
                                            }
                                        }
                                    }
                                }
                                Write-Verbose "Retrieved storage metrics for SQL MI $($sqlMI.ManagedInstanceName) - Used: $storageUsedGB GB, Allocated: $storageAllocatedGB GB"
                            }
                        } catch {
                            Write-CVLog "Could not get storage metrics for SQL Managed Instance: $($_.Exception.Message)" -Level Warning -Source 'SQL' -Scope @{ Subscription = $sub.Name; Instance = $sqlMI.ManagedInstanceName }
                        }
                        
                        $sqlMIObj = [ordered] @{}
                        $sqlMIObj.Add("Subscription", $sub.Name)
                        $sqlMIObj.Add("ResourceGroup", $sqlMI.ResourceGroupName)
                        $sqlMIObj.Add("ManagedInstanceName", $sqlMI.ManagedInstanceName)
                        $sqlMIObj.Add("Region", $sqlMI.Location)
                        $sqlMIObj.Add("vCores", $sqlMI.VCores)
                        $sqlMIObj.Add("StorageSizeGB", $sqlMI.StorageSizeInGB)
                        # StorageUsedGB is decimal (SI). StorageUsedTiB is binary (IEC) computed directly from MB.
                        $sqlMIObj.Add("StorageUsedMB", $storageUsedMB)
                        $sqlMIObj.Add("StorageUsedGB", $storageUsedGB)
                        $sqlMIObj.Add("StorageUsedTiB", $storageUsedTiBBinary)
                        # $null / 1000 is 0 in PowerShell, so these derived columns need the same guard as their
                        # source - otherwise TB reads 0 while GB is blank, which is the ambiguity we just removed.
                        $sqlMIObj.Add("StorageUsedTB", $(if ($null -ne $storageUsedGB) { [math]::Round($storageUsedGB / 1000, 4) }))
                        $sqlMIObj.Add("StorageAllocatedGB", $storageAllocatedGB)
                        $sqlMIObj.Add("StorageAllocatedTiB", $storageAllocatedTiBBinary)
                        $sqlMIObj.Add("StorageAllocatedTB", $(if ($null -ne $storageAllocatedGB) { [math]::Round($storageAllocatedGB / 1000, 4) }))
                        $sqlMIObj.Add("LicenseType", $sqlMI.LicenseType)
                        $sqlMIObj.Add("State", $sqlMI.State)
                        $sqlMIObj.Add("SubnetId", $sqlMI.SubnetId)
                        
                        $SqlInstancesInventory += New-Object -TypeName PSObject -Property $sqlMIObj
                        Write-Verbose "Successfully processed SQL Managed Instance: $($sqlMI.ManagedInstanceName)"
                        
                        # Get databases for this SQL Managed Instance (not added to summary)
                        try {
                            Write-Verbose "Collecting databases for SQL MI: $($sqlMI.ManagedInstanceName)"
                            $miDatabases = Get-AzSqlInstanceDatabase -InstanceName $sqlMI.ManagedInstanceName -ResourceGroupName $sqlMI.ResourceGroupName -ErrorAction SilentlyContinue
                            
                            if ($miDatabases) {
                                foreach ($miDb in $miDatabases) {
                                    # Skip system databases
                                    if ($miDb.Name -in @('master', 'msdb', 'tempdb', 'model')) { continue }
                                    
                                    # Get retention policies for this database
                                    $ltrPolicyJson = $null
                                    $strPolicyJson = $null
                                    
                                    try {
                                        # Get Long-Term Retention policy
                                        $ltrPolicy = Get-AzSqlInstanceDatabaseBackupLongTermRetentionPolicy -InstanceName $sqlMI.ManagedInstanceName -DatabaseName $miDb.Name -ResourceGroupName $sqlMI.ResourceGroupName -ErrorAction SilentlyContinue
                                        if ($ltrPolicy) {
                                            $ltrPolicyJson = $ltrPolicy | ConvertTo-Json -Compress
                                        }
                                    } catch {
                                        Write-CVLog "Could not get LTR policy for database: $($_.Exception.Message)" -Level Warning -Source 'SQL' -Scope @{ Subscription = $sub.Name; Database = $miDb.Name }
                                    }
                                    
                                    try {
                                        # Get Short-Term Retention policy
                                        $strPolicy = Get-AzSqlInstanceDatabaseBackupShortTermRetentionPolicy -InstanceName $sqlMI.ManagedInstanceName -DatabaseName $miDb.Name -ResourceGroupName $sqlMI.ResourceGroupName -ErrorAction SilentlyContinue
                                        if ($strPolicy) {
                                            $strPolicyJson = $strPolicy | ConvertTo-Json -Compress
                                        }
                                    } catch {
                                        Write-CVLog "Could not get STR policy for database: $($_.Exception.Message)" -Level Warning -Source 'SQL' -Scope @{ Subscription = $sub.Name; Database = $miDb.Name }
                                    }
                                    
                                    $miDbObj = [ordered]@{
                                        "Subscription" = $sub.Name
                                        "ResourceGroup" = $sqlMI.ResourceGroupName
                                        "ManagedInstanceName" = $sqlMI.ManagedInstanceName
                                        "DatabaseName" = $miDb.Name
                                        "Status" = $miDb.Status
                                        "CreationDate" = $miDb.CreationDate
                                        "Collation" = $miDb.Collation
                                        "Region" = $sqlMI.Location
                                        "LongTermRetentionPolicyJson" = $ltrPolicyJson
                                        "ShortTermRetentionPolicyJson" = $strPolicyJson
                                    }
                                    
                                    $SqlMIDbInventory += New-Object -TypeName PSObject -Property $miDbObj
                                }
                                Write-Verbose "Collected $($miDatabases.Count) databases for SQL MI: $($sqlMI.ManagedInstanceName)"
                            }
                        } catch {
                            Write-CVLog "Could not get databases for SQL Managed Instance: $($_.Exception.Message)" -Level Warning -Source 'SQL' -Scope @{ Subscription = $sub.Name; Instance = $sqlMI.ManagedInstanceName }
                        }
                    } catch {
                        Write-CVLog "Error processing SQL Managed Instance: $($_.Exception.Message)" -Level Warning -Source 'SQL' -Scope @{ Subscription = $sub.Name; Instance = $sqlMI.ManagedInstanceName }
                    }
                }
                Write-Progress -Id 7 -Activity "Processing SQL Managed Instances" -Completed
            } else {
                Write-Host "No SQL Managed Instances found in subscription $($sub.Name)" -ForegroundColor Yellow
            }
        } catch {
            Write-CVLog "Error during SQL Managed Instances processing: $($_.Exception.Message)" -Level Warning -Source 'SQL' -Scope @{ Subscription = $sub.Name }
        }
    }

    # SQL Logical Servers & Databases
    if ($Selected.SQL) {
        try {
            Write-Host "Processing Azure SQL Servers and Databases in subscription $($sub.Name)" -ForegroundColor Green
            try {
                $sqlServers = Get-AzSqlServer -ErrorAction Stop
            } catch {
                Write-CVLog "Unable to list SQL servers: $($_.Exception.Message)" -Level Warning -Source 'SQL' -Scope @{ Subscription = $sub.Name }
                $sqlServers = $null
            }

            if ($sqlServers) {
                $sqlServerIdx = 0
                foreach ($sqlServer in $sqlServers) {
                    $sqlServerIdx++
                    Write-Progress -Id 8 -ParentId 1 -Activity "Processing SQL Servers" -Status "Server $sqlServerIdx of $($sqlServers.Count) - $($sqlServer.ServerName)" -PercentComplete ([math]::Round(($sqlServerIdx / $sqlServers.Count) * 100,1))
                    try {
                        $sqlDBs = Get-AzSqlDatabase -ServerName $sqlServer.ServerName -ResourceGroupName $sqlServer.ResourceGroupName -ErrorAction Stop
                    } catch {
                        Write-CVLog "Could not enumerate databases for SQL server: $($_.Exception.Message)" -Level Warning -Source 'SQL' -Scope @{ Subscription = $sub.Name; Server = $sqlServer.ServerName }
                        continue
                    }

                    # db-cmek reads CmkEncrypted, which nothing populated - so the TDE control was blank on every
                    # SQL row. The TDE protector is a SERVER-level setting (Type: AzureKeyVault | ServiceManaged),
                    # so it is fetched once here and applied to each of that server's databases below, rather than
                    # once per database. A failure leaves it $null (Unknown), never $false.
                    $sqlTdeCmk = $null
                    try {
                        $tde = Get-AzSqlServerTransparentDataEncryptionProtector -ResourceGroupName $sqlServer.ResourceGroupName -ServerName $sqlServer.ServerName -ErrorAction Stop
                        if ($tde -and -not [string]::IsNullOrWhiteSpace("$($tde.Type)")) {
                            $sqlTdeCmk = [bool]("$($tde.Type)" -match 'KeyVault')
                        }
                    } catch {
                        Write-CVLog "Could not read TDE protector: $($_.Exception.Message)" -Level Warning -Source 'SQL' -Scope @{ Subscription = $sub.Name; Server = $sqlServer.ServerName }
                    }

                    foreach ($sqlDB in $sqlDBs) {
                        # Skip system DBs
                        if ($sqlDB.SkuName -eq 'System') { continue }

                        $sqlObj = [ordered]@{}
                        $sqlObj.Add("Subscription", $sub.Name)
                        $sqlObj.Add("ResourceGroup", $sqlServer.ResourceGroupName)
                        $sqlObj.Add("Server", $sqlServer.ServerName)
                        $sqlObj.Add("Database", $sqlDB.DatabaseName)
                        $sqlObj.Add("ResourceId", $sqlDB.ResourceId)
                        $sqlObj.Add("Edition", $sqlDB.Edition)
                        $sqlObj.Add("InstanceType", $sqlDB.SkuName)
                        $sqlObj.Add("MaxSizeGiB", [math]::Round(($sqlDB.MaxSizeBytes / 1073741824), 0))
                        $sqlObj.Add("MaxSizeGB", [math]::Round(($sqlDB.MaxSizeBytes / 1000000000), 3))
                        # Elastic pools: a pooled database reports the POOL's max size, so summing MaxSizeGB across
                        # databases counted the same pool once per database. ElasticPoolName lets the summaries
                        # exclude pooled DBs from size totals instead of multiplying them.
                        $sqlObj.Add("ElasticPoolName", $sqlDB.ElasticPoolName)
                        $sqlObj.Add("IsPooled", [bool]$sqlDB.ElasticPoolName)
                        $sqlObj.Add("ZoneRedundant", $sqlDB.ZoneRedundant)
                        $sqlObj.Add("BackupStorageRedundancy", $sqlDB.CurrentBackupStorageRedundancy)
                        $sqlObj.Add("SkuCapacity", $sqlDB.Capacity)
                        $sqlObj.Add("Region", $sqlDB.Location)
                        $sqlObj.Add("DatabaseId", $sqlDB.DatabaseId)
                        $sqlObj.Add("Status", $sqlDB.Status)
                        $sqlObj.Add("CmkEncrypted", $sqlTdeCmk)   # server-level TDE protector, resolved above

                        # Get allocated and used storage metrics (Maximum over last 24h)
                        $allocatedVal = $null
                        $usedVal = $null
                        try {
                            # Single call for both metrics reduces API calls and keeps timing/aggregation identical.
                            # 48h window - the comment below used to claim 24h while the code asked for 1h.
                            $metrics = Get-AzMetric -ResourceId $sqlDB.ResourceId -MetricNames @("allocated_data_storage","storage") -AggregationType Maximum -StartTime (Get-Date).ToUniversalTime().AddHours(-(Get-CVAzMetricWindowHours 'storage')) -WarningAction SilentlyContinue

                            # Map returned metrics back to the named variables for compatibility with existing logic
                            $allocatedMetric = $null
                            $usedMetric = $null
                            if ($metrics) {
                                $allocatedMetric = $metrics | Where-Object { $_.Name.Value -eq "allocated_data_storage" } | Select-Object -First 1
                                $usedMetric = $metrics | Where-Object { $_.Name.Value -eq "storage" } | Select-Object -First 1
                            }

                            if ($allocatedMetric -and $allocatedMetric.Data -and $allocatedMetric.Data.Count -gt 0) {
                                # pick the last non-null Maximum datapoint
                                $allocatedVal = ($allocatedMetric.Data | ForEach-Object { $_.Maximum } | Where-Object { $_ -ne $null } | Select-Object -Last 1)
                            }
                            if ($usedMetric -and $usedMetric.Data -and $usedMetric.Data.Count -gt 0) {
                                $usedVal = ($usedMetric.Data | ForEach-Object { $_.Maximum } | Where-Object { $_ -ne $null } | Select-Object -Last 1)
                            }
                        } catch {
                            # leave as $null if metrics fail
                            $allocatedVal = $null
                            $usedVal = $null
                        }

                        # Normalize numeric values to doubles for calculations
                        $allocatedBytes = if ($allocatedVal -ne $null) { [double]$allocatedVal } else { $null }
                        $usedBytes = if ($usedVal -ne $null) { [double]$usedVal } else { $null }

                        $sqlObj.Add("Allocated_Bytes", $allocatedBytes)
                        $sqlObj.Add("Utilized_Bytes", $usedBytes)
                        if ($allocatedBytes) { $sqlObj.Add("Allocated_GB", [math]::Round($allocatedBytes / 1000000000, 3)) } else { $sqlObj.Add("Allocated_GB", $null) }
                        if ($usedBytes) { $sqlObj.Add("Utilized_GB", [math]::Round($usedBytes / 1000000000, 3)) } else { $sqlObj.Add("Utilized_GB", $null) }

                        # Compute percent used. Prefer allocated metric; if missing, fall back to MaxSizeBytes from the DB resource
                        $percentUsed = $null
                        if ($usedBytes -ne $null -and $allocatedBytes -ne $null -and $allocatedBytes -gt 0) {
                            $percentUsed = [math]::Round((($usedBytes / $allocatedBytes) * 100), 2)
                        } elseif ($usedBytes -ne $null -and $sqlDB.MaxSizeBytes -ne $null -and $sqlDB.MaxSizeBytes -gt 0) {
                            $percentUsed = [math]::Round((($usedBytes / [double]$sqlDB.MaxSizeBytes) * 100), 2)
                        }
                        $sqlObj.Add("PercentUsed", $percentUsed)

                        # SizingGB is what the summaries total. Prefer what the database ACTUALLY uses; fall back
                        # to allocated, then provisioned max. SizeBasis states which was used so the spreadsheet
                        # never silently mixes "consumed" with "provisioned ceiling" - the summaries used to sum
                        # MaxSizeGB even though Utilized_GB was collected right here.
                        $sizingGB = $null; $sizeBasis = 'None'
                        if ($null -ne $usedBytes)                       { $sizingGB = [math]::Round($usedBytes / 1000000000, 3);      $sizeBasis = 'Utilized' }
                        elseif ($null -ne $allocatedBytes)              { $sizingGB = [math]::Round($allocatedBytes / 1000000000, 3); $sizeBasis = 'Allocated' }
                        elseif ($null -ne $sqlDB.MaxSizeBytes)          { $sizingGB = [math]::Round($sqlDB.MaxSizeBytes / 1000000000, 3); $sizeBasis = 'ProvisionedMax' }
                        $sqlObj.Add("SizingGB", $sizingGB)
                        $sqlObj.Add("SizeBasis", $sizeBasis)

                        # STR / LTR policies (best-effort; master & some instance types may not support)
                        try {
                            $ltr = Get-AzSqlDatabaseBackupLongTermRetentionPolicy -ServerName $sqlDB.ServerName -DatabaseName $sqlDB.DatabaseName -ResourceGroupName $sqlDB.ResourceGroupName -ErrorAction SilentlyContinue
                        } catch { $ltr = $null }
                        try {
                            $str = Get-AzSqlDatabaseBackupShortTermRetentionPolicy -ServerName $sqlDB.ServerName -DatabaseName $sqlDB.DatabaseName -ResourceGroupName $sqlDB.ResourceGroupName -ErrorAction SilentlyContinue
                        } catch { $str = $null }
                        $sqlObj.Add("LTRWeeklyRetention", ($ltr.WeeklyRetention -as [string]))
                        $sqlObj.Add("LTRMonthlyRetention", ($ltr.MonthlyRetention -as [string]))
                        $sqlObj.Add("PITR_Days", ($str.RetentionDays -as [string]))

                        $SqlDbInventory += New-Object -TypeName PSObject -Property $sqlObj
                    }
                }
                Write-Progress -Id 8 -Activity "Processing SQL Servers" -Completed
            }
        } catch {
            Write-CVLog "Error processing SQL servers/databases: $($_.Exception.Message)" -Level Warning -Source 'SQL' -Scope @{ Subscription = $sub.Name }
        }

        # MySQL Servers (part of SQL inventory)
        try {
            Write-Host "Processing MySQL servers in subscription $($sub.Name)" -ForegroundColor Green
            
            $allMySQLServers = @()
            
            try {
                # Get all MySQL flexible servers at subscription level
                Write-Progress -Id 10 -ParentId 1 -Activity "Discovering MySQL Servers" -Status "Getting MySQL Flexible Servers..." -PercentComplete 25
                # -Force on the Add-Member calls below is load-bearing. Observed live: "Cannot add a member with
                # the name ResourceGroupName because a member with that name already exists" - some Az.MySql /
                # Az.PostgreSql builds already surface that property on the server object. Add-Member throws
                # rather than warns, and -ErrorAction on the GET does not cover it, so the exception escaped to
                # the outer catch and ABANDONED MySQL collection for the whole subscription. The run then
                # reported "Total MySQL Servers found: 0" as though the tenant had none.
                $mysqlFlexibleServers = Get-AzMySqlFlexibleServer -ErrorAction SilentlyContinue
                if ($mysqlFlexibleServers) {
                    $allMySQLServers += $mysqlFlexibleServers | ForEach-Object {
                        $_ | Add-Member -NotePropertyName "ServerType" -NotePropertyValue "Flexible" -Force -PassThru |
                             Add-Member -NotePropertyName "ResourceGroupName" -NotePropertyValue ($_.Id -split '/')[4] -Force -PassThru
                    }
                }
                
                # Get all MySQL single servers at subscription level. Azure MySQL Single Server is retired and the
                # Get-AzMySqlServer cmdlet was removed in Az.MySql v2+, so only call it if it still exists.
                Write-Progress -Id 10 -ParentId 1 -Activity "Discovering MySQL Servers" -Status "Getting MySQL Single Servers..." -PercentComplete 50
                $mysqlSingleServers = if (Get-Command Get-AzMySqlServer -ErrorAction SilentlyContinue) { Get-AzMySqlServer -ErrorAction SilentlyContinue } else { $null }
                if ($mysqlSingleServers) {
                    $allMySQLServers += $mysqlSingleServers | ForEach-Object {
                        $_ | Add-Member -NotePropertyName "ServerType" -NotePropertyValue "Single" -Force -PassThru |
                             Add-Member -NotePropertyName "ResourceGroupName" -NotePropertyValue ($_.Id -split '/')[4] -Force -PassThru
                    }
                }
            } catch {
                Write-CVLog "Unable to collect MySQL information: $($_.Exception.Message)" -Level Warning -Source 'SQL' -Scope @{ Subscription = $sub.Name }
            }
            
            Write-Progress -Id 10 -Activity "Discovering MySQL Servers" -Status "Discovery Complete" -PercentComplete 100
            Start-Sleep -Milliseconds 100  # Brief pause to ensure progress bar displays properly
            Write-Progress -Id 10 -Activity "Discovering MySQL Servers" -Completed
            
            if ($allMySQLServers -and $allMySQLServers.Count -gt 0) {
                $mysqlCount = 0
                foreach ($mysqlServer in $allMySQLServers) {
                        $mysqlCount++
                        $mysqlPercentComplete = [math]::Round(($mysqlCount / $allMySQLServers.Count) * 100, 1)
                        Write-Progress -Id 11 -ParentId 1 -Activity "Processing MySQL Servers" -Status "Processing MySQL $mysqlCount of $($allMySQLServers.Count) - $mysqlPercentComplete% complete" -PercentComplete $mysqlPercentComplete
                        
                        try {
                            # Build MySQL object
                            $mysqlObj = [ordered]@{
                                "Id" = $mysqlServer.Id
                                "Subscription" = $sub.Name
                                "ResourceGroupName" = $mysqlServer.ResourceGroupName
                                "Name" = $mysqlServer.Name
                                "ServerType" = $mysqlServer.ServerType
                                "Location" = $mysqlServer.Location
                                "Region" = $mysqlServer.Location
                                "Version" = $mysqlServer.Version
                                "FullyQualifiedDomainName" = $mysqlServer.FullyQualifiedDomainName
                                "BackupRetentionDays" = $mysqlServer.BackupRetentionDays
                                # Needed by the fx-xregion control, which previously read a field nothing set.
                                # Property naming varies by Az module version, same as BackupRetentionDay(s) below.
                                "GeoRedundantBackup" = $(
                                    if ($mysqlServer.BackupGeoRedundantBackup)      { $mysqlServer.BackupGeoRedundantBackup }
                                    elseif ($mysqlServer.Backup.GeoRedundantBackup) { $mysqlServer.Backup.GeoRedundantBackup }
                                    elseif ($mysqlServer.GeoRedundantBackup)        { $mysqlServer.GeoRedundantBackup }
                                    else { $null })
                                "StorageSku" = $mysqlServer.StorageSku
                                "SkuName" = $mysqlServer.SkuName
                            }
                            
                            # Get storage size based on server type (different properties for different types)
                            if ($mysqlServer.ServerType -eq "Flexible") {
                                # Flexible servers typically have StorageInMb or StorageGB properties
                                if ($mysqlServer.StorageSizeGB) {
                                    $storageGB = $mysqlServer.StorageSizeGB
                                    $storageMB = [math]::Round($storageGB * 1024, 2)
                                    $mysqlObj.Add("StorageMB", $storageMB)
                                    $mysqlObj.Add("StorageGB", $storageGB)
                                } elseif ($mysqlServer.StorageInMb) {
                                    $storageMB = $mysqlServer.StorageInMb
                                    $storageGB = [math]::Round($storageMB / 1024, 2)
                                    $mysqlObj.Add("StorageMB", $storageMB)
                                    $mysqlObj.Add("StorageGB", $storageGB)
                                } else {
                                    $mysqlObj.Add("StorageMB", $null)
                                    $mysqlObj.Add("StorageGB", $null)
                                }
                            } elseif ($mysqlServer.ServerType -eq "Single") {
                                # Single servers have StorageProfile.StorageMb structure
                                if ($mysqlServer.StorageProfile -and $mysqlServer.StorageProfile.StorageMb) {
                                    $storageMB = $mysqlServer.StorageProfile.StorageMb
                                    $storageGB = [math]::Round($storageMB / 1024, 2)
                                    $mysqlObj.Add("StorageMB", $storageMB)
                                    $mysqlObj.Add("StorageGB", $storageGB)
                                } elseif ($mysqlServer.StorageSizeGB) {
                                    # Fallback to direct StorageGB if StorageProfile is not available
                                    $storageGB = $mysqlServer.StorageSizeGB
                                    $storageMB = [math]::Round($storageGB * 1024, 2)
                                    $mysqlObj.Add("StorageMB", $storageMB)
                                    $mysqlObj.Add("StorageGB", $storageGB)
                                } else {
                                    $mysqlObj.Add("StorageMB", $null)
                                    $mysqlObj.Add("StorageGB", $null)
                                }
                            } else {
                                # Unknown server type - try common properties
                                if ($mysqlServer.StorageGB) {
                                    $storageGB = $mysqlServer.StorageGB
                                    $storageMB = [math]::Round($storageGB * 1024, 2)
                                    $mysqlObj.Add("StorageMB", $storageMB)
                                    $mysqlObj.Add("StorageGB", $storageGB)
                                } else {
                                    $mysqlObj.Add("StorageMB", $null)
                                    $mysqlObj.Add("StorageGB", $null)
                                }
                            }
                            
                            # Get metrics for storage usage
                            $id = $mysqlServer.Id
                            
                            # Storage Used
                            try {
                                $storageUsedMetric = (Get-CVAzMetricValue -ResourceId $id -MetricName storage_used -AggregationType Maximum).Value
                                if ($storageUsedMetric) {
                                    $storageUsedMB = [math]::Round($storageUsedMetric / (1024 * 1024), 2)  # Convert bytes to MB
                                    $storageUsedGB = [math]::Round($storageUsedMetric / (1024 * 1024 * 1024), 4)  # Convert bytes to GB
                                } else {
                                    $storageUsedMB = $null
                                    $storageUsedGB = $null
                                }
                                $mysqlObj.Add("StorageUsedBytes", $storageUsedMetric)
                                $mysqlObj.Add("StorageUsedMB", $storageUsedMB)
                                $mysqlObj.Add("StorageUsedGB", $storageUsedGB)
                            } catch {
                                $mysqlObj.Add("StorageUsedBytes", $null)
                                $mysqlObj.Add("StorageUsedMB", $null)
                                $mysqlObj.Add("StorageUsedGB", $null)
                            }
                            
                            # Storage Percent
                            try {
                                $storagePercentMetric = (Get-CVAzMetricValue -ResourceId $id -MetricName storage_percent -AggregationType Maximum).Value
                                $mysqlObj.Add("StoragePercent", $storagePercentMetric)
                            } catch {
                                $mysqlObj.Add("StoragePercent", $null)
                            }


                            # fx-cmek reads this. Probed, not assumed - see Resolve-CVAzureFlexServerCmk for why
                            # $null (not $false) is correct when the module build exposes no encryption property.
                            $mysqlObj.Add("CmkEncrypted", (Resolve-CVAzureFlexServerCmk -Server $mysqlServer))

                            $MySQLServers += New-Object -TypeName PSObject -Property $mysqlObj
                            Write-Verbose "Added MySQL server $($mysqlServer.Name)"
                        } catch {
                            Write-CVLog "Error processing MySQL server: $($_.Exception.Message)" -Level Warning -Source 'SQL' -Scope @{ Subscription = $sub.Name; Server = $mysqlServer.Name }
                            
                            # Create minimal object on error
                            $mysqlObj = [ordered]@{
                                "Id" = $mysqlServer.Id
                                "Name" = $mysqlServer.Name
                                "ServerType" = $mysqlServer.ServerType
                                "Error" = $_.Exception.Message
                            }
                            $MySQLServers += New-Object -TypeName PSObject -Property $mysqlObj
                    }
                }
                Write-Progress -Id 11 -ParentId 1 -Activity "Processing MySQL Servers" -Completed
            } else {
                Write-Host "No MySQL servers found in subscription $($sub.Name)" -ForegroundColor Yellow
            }
            
        } catch {
            Write-CVLog "Error processing MySQL servers: $($_.Exception.Message)" -Level Warning -Source 'SQL' -Scope @{ Subscription = $sub.Name }
        }

        # PostgreSQL Servers (part of SQL inventory)
        try {
            Write-Host "Processing PostgreSQL servers in subscription $($sub.Name)" -ForegroundColor Green
            
            $allPostgreSQLServers = @()
            
            try {
                # Get all PostgreSQL flexible servers at subscription level
                Write-Progress -Id 12 -ParentId 1 -Activity "Discovering PostgreSQL Servers" -Status "Getting PostgreSQL Flexible Servers..." -PercentComplete 25
                $postgresFlexibleServers = Get-AzPostgreSqlFlexibleServer -ErrorAction SilentlyContinue
                if ($postgresFlexibleServers) {
                    $allPostgreSQLServers += $postgresFlexibleServers | ForEach-Object {
                        $_ | Add-Member -NotePropertyName "ServerType" -NotePropertyValue "Flexible" -Force -PassThru |
                             Add-Member -NotePropertyName "ResourceGroupName" -NotePropertyValue ($_.Id -split '/')[4] -Force -PassThru
                    }
                }
                
                # Get all PostgreSQL single servers at subscription level. Azure PostgreSQL Single Server is retired
                # and Get-AzPostgreSqlServer was removed in Az.PostgreSql v2+, so only call it if it still exists.
                Write-Progress -Id 12 -ParentId 1 -Activity "Discovering PostgreSQL Servers" -Status "Getting PostgreSQL Single Servers..." -PercentComplete 50
                $postgresSingleServers = if (Get-Command Get-AzPostgreSqlServer -ErrorAction SilentlyContinue) { Get-AzPostgreSqlServer -ErrorAction SilentlyContinue } else { $null }
                if ($postgresSingleServers) {
                    $allPostgreSQLServers += $postgresSingleServers | ForEach-Object {
                        $_ | Add-Member -NotePropertyName "ServerType" -NotePropertyValue "Single" -Force -PassThru |
                             Add-Member -NotePropertyName "ResourceGroupName" -NotePropertyValue ($_.Id -split '/')[4] -Force -PassThru
                    }
                }
            } catch {
                Write-CVLog "Unable to collect PostgreSQL information: $($_.Exception.Message)" -Level Warning -Source 'SQL' -Scope @{ Subscription = $sub.Name }
            }
            
            Write-Progress -Id 12 -Activity "Discovering PostgreSQL Servers" -Status "Discovery Complete" -PercentComplete 100
            Start-Sleep -Milliseconds 100  # Brief pause to ensure progress bar displays properly
            Write-Progress -Id 12 -Activity "Discovering PostgreSQL Servers" -Completed
            
            if ($allPostgreSQLServers -and $allPostgreSQLServers.Count -gt 0) {
                $postgresCount = 0
                foreach ($postgresServer in $allPostgreSQLServers) {
                        $postgresCount++
                        $postgresPercentComplete = [math]::Round(($postgresCount / $allPostgreSQLServers.Count) * 100, 1)
                        Write-Progress -Id 13 -ParentId 1 -Activity "Processing PostgreSQL Servers" -Status "Processing PostgreSQL $postgresCount of $($allPostgreSQLServers.Count) - $postgresPercentComplete% complete" -PercentComplete $postgresPercentComplete
                        
                        try {
                            # Build PostgreSQL object
                            $postgresObj = [ordered]@{
                                "Subscription" = $sub.Name
                                "ResourceGroupName" = $postgresServer.ResourceGroupName
                                "Name" = $postgresServer.Name
                                "Id" = $postgresServer.Id
                                "ServerType" = $postgresServer.ServerType
                                "Location" = $postgresServer.Location
                                "Region" = $postgresServer.Location
                                "Version" = $postgresServer.Version
                                "FullyQualifiedDomainName" = $postgresServer.FullyQualifiedDomainName
                                "BackupRetentionDays" = if ($postgresServer.BackupRetentionDays) { $postgresServer.BackupRetentionDays } elseif ($postgresServer.BackupRetentionDay) { $postgresServer.BackupRetentionDay } elseif ($postgresServer.StorageProfileBackupRetentionDay) { $postgresServer.StorageProfileBackupRetentionDay } else { $null }
                                "SkuName" = $postgresServer.SkuName
                                # Needed by the fx-xregion control - see the MySQL block above.
                                "GeoRedundantBackup" = $(
                                    if ($postgresServer.BackupGeoRedundantBackup)      { $postgresServer.BackupGeoRedundantBackup }
                                    elseif ($postgresServer.Backup.GeoRedundantBackup) { $postgresServer.Backup.GeoRedundantBackup }
                                    elseif ($postgresServer.GeoRedundantBackup)        { $postgresServer.GeoRedundantBackup }
                                    else { $null })
                            }
                            
                            # Get storage size based on server type (different properties for different types)
                            if ($postgresServer.ServerType -eq "Flexible") {
                                # Flexible servers have different storage properties
                                if ($postgresServer.StorageSizeGB) {
                                    $storageGB = $postgresServer.StorageSizeGB
                                    $storageMB = $storageGB * 1024
                                    $postgresObj.Add("StorageMB", $storageMB)
                                    $postgresObj.Add("StorageGB", $storageGB)
                                } elseif ($postgresServer.StorageInMb) {
                                    $storageMB = $postgresServer.StorageInMb
                                    $storageGB = [math]::Round($storageMB / 1024, 2)
                                    $postgresObj.Add("StorageMB", $storageMB)
                                    $postgresObj.Add("StorageGB", $storageGB)
                                } else {
                                    $postgresObj.Add("StorageMB", $null)
                                    $postgresObj.Add("StorageGB", $null)
                                }
                            } elseif ($postgresServer.ServerType -eq "Single") {
                                # Single servers typically have StorageInMb property
                                if ($postgresServer.StorageInMb) {
                                    $storageMB = $postgresServer.StorageInMb
                                    $storageGB = [math]::Round($storageMB / 1024, 2)
                                    $postgresObj.Add("StorageMB", $storageMB)
                                    $postgresObj.Add("StorageGB", $storageGB)
                                } else {
                                    $postgresObj.Add("StorageMB", $null)
                                    $postgresObj.Add("StorageGB", $null)
                                }
                            } else {
                                $postgresObj.Add("StorageMB", $null)
                                $postgresObj.Add("StorageGB", $null)
                            }
                            
                            # Get metrics for storage usage
                            $id = $postgresServer.Id
                            
                            # Storage Used
                            try {
                                $storageUsedMetric = (Get-CVAzMetricValue -ResourceId $id -MetricName storage_used -AggregationType Maximum).Value
                                $storageUsedGB = if ($storageUsedMetric -ne $null) { [math]::Round($storageUsedMetric / 1000000000, 4) } else { $null }
                                $postgresObj.Add("StorageUsedGB", $storageUsedGB)
                            } catch {
                                $postgresObj.Add("StorageUsedGB", $null)
                            }
                            
                            # Storage Percent
                            try {
                                $storagePercentMetric = (Get-CVAzMetricValue -ResourceId $id -MetricName storage_percent -AggregationType Maximum).Value
                                $postgresObj.Add("StoragePercent", $storagePercentMetric)
                            } catch {
                                $postgresObj.Add("StoragePercent", $null)
                            }

                            # fx-cmek reads this - same probe as MySQL above.
                            $postgresObj.Add("CmkEncrypted", (Resolve-CVAzureFlexServerCmk -Server $postgresServer))

                            $PostgreSQLServers += New-Object -TypeName PSObject -Property $postgresObj
                            Write-Verbose "Added PostgreSQL server $($postgresServer.Name)"
                        } catch {
                            Write-CVLog "Error processing PostgreSQL server: $($_.Exception.Message)" -Level Warning -Source 'SQL' -Scope @{ Subscription = $sub.Name; Server = $postgresServer.Name }
                            
                            # Create minimal object on error
                            $postgresObj = [ordered]@{
                                "Id" = $postgresServer.Id
                                "Name" = $postgresServer.Name
                                "ServerType" = $postgresServer.ServerType
                                "Error" = $_.Exception.Message
                            }
                            $PostgreSQLServers += New-Object -TypeName PSObject -Property $postgresObj
                    }
                }
                Write-Progress -Id 13 -ParentId 1 -Activity "Processing PostgreSQL Servers" -Completed
            } else {
                Write-Host "No PostgreSQL servers found in subscription $($sub.Name)" -ForegroundColor Yellow
            }
        } catch {
            Write-CVLog "Error processing PostgreSQL servers: $($_.Exception.Message)" -Level Warning -Source 'SQL' -Scope @{ Subscription = $sub.Name }
        }
    }
    
    # CosmosDB Accounts
    if ($Selected.COSMOS) {
        try {
            Write-Host "Processing CosmosDB accounts in subscription $($sub.Name)" -ForegroundColor Green
            
            # Get all resource groups in the subscription.
            # NOTE: must NOT be named $resourceGroups - see the NetApp block above; that name aliases the
            # script's -ResourceGroups parameter and would silently scope the whole run to these objects.
            $subRgList = Get-AzResourceGroup -ErrorAction SilentlyContinue
            if (-not $subRgList) {
                Write-Host "No resource groups found in subscription $($sub.Name)" -ForegroundColor Yellow
                continue
            }

            $allCosmosAccounts = @()
            $rgCount = 0

            # Iterate through each resource group to find CosmosDB accounts
            foreach ($rg in $subRgList) {
                $rgCount++
                Write-Progress -Id 8 -ParentId 1 -Activity "Scanning Resource Groups for CosmosDB" -Status "Resource Group $rgCount of $($subRgList.Count): $($rg.ResourceGroupName)" -PercentComplete ([math]::Round(($rgCount / $subRgList.Count) * 100, 1))
                
                try {
                    $cosmosAccountsInRG = Get-AzCosmosDBAccount -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue
                    if ($cosmosAccountsInRG) {
                        $allCosmosAccounts += $cosmosAccountsInRG | Add-Member -NotePropertyName "ResourceGroupName" -NotePropertyValue $rg.ResourceGroupName -Force -PassThru
                    }
                } catch {
                    Write-Error "Unable to collect CosmosDB information for Resource Group $($rg.ResourceGroupName) in subscription: $($sub.Name)"
                    Write-Error "Error: $_"
                    Continue
                }
            }
            
            Write-Progress -Id 8 -Activity "Scanning Resource Groups for CosmosDB" -Completed
            
            if ($allCosmosAccounts -and $allCosmosAccounts.Count -gt 0) {
                $cosmosCount = 0
                foreach ($cosmosAccount in $allCosmosAccounts) {
                    $cosmosCount++
                    $cosmosPercentComplete = [math]::Round(($cosmosCount / $allCosmosAccounts.Count) * 100, 1)
                    Write-Progress -Id 9 -ParentId 1 -Activity "Processing CosmosDB Accounts" -Status "Processing CosmosDB $cosmosCount of $($allCosmosAccounts.Count) - $cosmosPercentComplete% complete" -PercentComplete $cosmosPercentComplete
                    
                    try {
                        # Build CosmosDB object following the reference file pattern
                        $cosmosObj = [ordered]@{
                            "Subscription" = $sub.Name
                            "ResourceGroupName" = $cosmosAccount.ResourceGroupName
                            "Name" = $cosmosAccount.Name
                            "Location" = $cosmosAccount.Location
                            "Id" = $cosmosAccount.Id
                            "Kind" = $cosmosAccount.Kind
                            "InstanceId" = $cosmosAccount.InstanceId
                            "BackupPolicyBackupIntervalInMinutes" = $cosmosAccount.BackupPolicy.BackupIntervalInMinutes
                            "BackupPolicyBackupRetentionIntervalInHours" = $cosmosAccount.BackupPolicy.BackupRetentionIntervalInHours
                            "BackupPolicyBackupType" = $cosmosAccount.BackupPolicy.BackupType
                            "BackupPolicyBackupStorageRedundancy" = $cosmosAccount.BackupPolicy.BackupStorageRedundancy
                            "MinimalTlsVersion" = $cosmosAccount.MinimalTlsVersion
                            # cos-cmek reads this. Cosmos signals CMK by carrying a key-vault key URI; a
                            # service-managed account leaves it empty. The property is always present on the
                            # account model, so empty here genuinely means "not CMK" rather than "not collected".
                            "CmkEncrypted" = [bool]$cosmosAccount.KeyVaultKeyUri
                            "KeyVaultKeyUri" = $cosmosAccount.KeyVaultKeyUri
                        }

                        # Get metrics following the reference file pattern
                        $id = $cosmosAccount.Id
                        
                        # Document Count
                        try {
                            $documentCountMetric = (Get-CVAzMetricValue -ResourceId $id -MetricName DocumentCount -AggregationType Maximum).Value
                            $cosmosObj.Add("DocumentCount", $documentCountMetric)
                        } catch {
                            $cosmosObj.Add("DocumentCount", $null)
                        }
                        
                        # Data Usage
                        try {
                            $dataUsageMetric = (Get-CVAzMetricValue -ResourceId $id -MetricName DataUsage -AggregationType Maximum).Value
                            $cosmosObj.Add("DataUsage", $dataUsageMetric)
                            # Convert DataUsage from bytes to GB
                            $dataUsageGB = if ($dataUsageMetric -ne $null -and $dataUsageMetric -ne '') { [math]::Round($dataUsageMetric / 1000000000, 4) } else { $null }
                            $cosmosObj.Add("DataUsageGB", $dataUsageGB)
                        } catch {
                            $cosmosObj.Add("DataUsage", $null)
                            $cosmosObj.Add("DataUsageGB", $null)
                        }
                        
                        # Physical Partition Size Info
                        try {
                            $partitionSizeMetric = (Get-CVAzMetricValue -ResourceId $id -MetricName PhysicalPartitionSizeInfo -AggregationType Maximum).Value
                            $cosmosObj.Add("PhysicalPartitionSizeInfo", $partitionSizeMetric)
                        } catch {
                            $cosmosObj.Add("PhysicalPartitionSizeInfo", $null)
                        }
                        
                        # Physical Partition Count
                        try {
                            $partitionCountMetric = (Get-CVAzMetricValue -ResourceId $id -MetricName PhysicalPartitionCount -AggregationType Maximum).Value
                            $cosmosObj.Add("PhysicalPartitionCount", $partitionCountMetric)
                        } catch {
                            $cosmosObj.Add("PhysicalPartitionCount", $null)
                        }
                        
                        # Index Usage
                        try {
                            $indexUsageMetric = (Get-CVAzMetricValue -ResourceId $id -MetricName IndexUsage -AggregationType Maximum).Value
                            $cosmosObj.Add("IndexUsage", $indexUsageMetric)
                        } catch {
                            $cosmosObj.Add("IndexUsage", $null)
                        }
                        
                        $CosmosDBs += New-Object -TypeName PSObject -Property $cosmosObj
                        Write-Verbose "Added CosmosDB account $($cosmosAccount.Name)"
                    } catch {
                        Write-CVLog "Error processing CosmosDB account: $($_.Exception.Message)" -Level Warning -Source 'Cosmos' -Scope @{ Subscription = $sub.Name; Account = $cosmosAccount.Name }
                        
                        # Create minimal object on error
                        $cosmosObj = [ordered]@{
                            "Subscription" = $sub.Name
                            "ResourceGroupName" = $cosmosAccount.ResourceGroupName
                            "Name" = $cosmosAccount.Name
                            "Location" = $cosmosAccount.Location
                            "Id" = $cosmosAccount.Id
                            "Kind" = $cosmosAccount.Kind
                            "Error" = $_.Exception.Message
                        }
                        $CosmosDBs += New-Object -TypeName PSObject -Property $cosmosObj
                    }
                }
                Write-Progress -Id 9 -ParentId 1 -Activity "Processing CosmosDB Accounts" -Completed
            } else {
                Write-Host "No CosmosDB accounts found in subscription $($sub.Name)" -ForegroundColor Yellow
            }
        } catch {
            Write-CVLog "Error processing CosmosDB accounts: $($_.Exception.Message)" -Level Warning -Source 'Cosmos' -Scope @{ Subscription = $sub.Name }
        }
    }

    # AKS Clusters
    if ($Selected.AKS) {
        try {
            $AKSClustersFromAzure = Get-AzAksCluster
            
            if ($AKSClustersFromAzure) {
                $aksCount = 0
                foreach ($cluster in $AKSClustersFromAzure) {
                    $aksCount++
                    $aksPercentComplete = [math]::Round(($aksCount / $AKSClustersFromAzure.Count) * 100, 1)
                    Write-Progress -Id 9 -ParentId 1 -Activity "Processing AKS Clusters" -Status "Processing cluster $aksCount of $($AKSClustersFromAzure.Count) - $aksPercentComplete% complete" -PercentComplete $aksPercentComplete
                    
                    try {
                        # Get resource group name - handle different possible property names
                        $resourceGroupName = $null
                        if ($cluster.ResourceGroupName) {
                            $resourceGroupName = $cluster.ResourceGroupName
                        } elseif ($cluster.ResourceGroup) {
                            $resourceGroupName = $cluster.ResourceGroup
                        } elseif ($cluster.Id) {
                            # Extract from resource ID: /subscriptions/{sub-id}/resourceGroups/{rg-name}/...
                            $resourceGroupName = ($cluster.Id -split '/')[4]
                        }
                        
                        if (-not $resourceGroupName) {
                            Write-CVLog "Could not determine resource group for AKS cluster; skipping PV info" -Level Warning -Source 'AKS' -Scope @{ Subscription = $sub.Name; Cluster = $cluster.Name }
                            $pvInfo = @{
                                PersistentVolumes = @()
                                PersistentVolumeClaims = @()
                                TotalCapacityGB = 0
                                TotalVolumeCount = 0
                                AccessError = "Could not determine resource group"
                            }
                        } else {
                            # Get persistent volume information
                            $pvInfo = Get-AKSPersistentVolumeInfo -ClusterName $cluster.Name -ResourceGroupName $resourceGroupName -SubscriptionId $sub.Id
                        }
                        
                        # Add PVs and PVCs to global arrays only if access was successful
                        if (-not $pvInfo.AccessError) {
                            $AKSPersistentVolumes += $pvInfo.PersistentVolumes
                            $AKSPersistentVolumeClaims += $pvInfo.PersistentVolumeClaims
                            Write-Host "  Collected $($pvInfo.TotalVolumeCount) PVs and $($pvInfo.TotalPVCCount) PVCs from cluster $($cluster.Name)" -ForegroundColor Green
                        } else {
                            Write-CVLog "Skipping PV/PVC collection due to access error: $($pvInfo.AccessError)" -Level Warning -Source 'AKS' -Scope @{ Subscription = $sub.Name; Cluster = $cluster.Name }
                        }
                        
                        $AKSCluster = [PSCustomObject]@{
                            ClusterName = $cluster.Name
                            ResourceId = $cluster.Id
                            Region = $cluster.Location
                            Subscription = $sub.Name
                            ResourceGroup = $resourceGroupName
                            PersistentVolumeCount = if ($pvInfo.AccessError) { $null } else { $pvInfo.TotalVolumeCount }
                            PersistentVolumeClaimCount = if ($pvInfo.AccessError) { $null } else { $pvInfo.TotalPVCCount }
                            PersistentVolumeCapacityGB = if ($pvInfo.AccessError) { $null } else { [math]::Round($pvInfo.TotalCapacityGB, 2) }
                            PersistentVolumeAccessError = $pvInfo.AccessError
                        }
                        
                        $AKSClusters += $AKSCluster
                        Write-Verbose "Added AKS cluster $($cluster.Name) with $($pvInfo.TotalVolumeCount) persistent volumes"
                        
                    } catch {
                        Write-CVLog "Error processing AKS cluster: $($_.Exception.Message)" -Level Warning -Source 'AKS' -Scope @{ Subscription = $sub.Name; Cluster = $cluster.Name }
                        
                        # Get resource group name for error object
                        $resourceGroupName = $null
                        if ($cluster.ResourceGroupName) {
                            $resourceGroupName = $cluster.ResourceGroupName
                        } elseif ($cluster.ResourceGroup) {
                            $resourceGroupName = $cluster.ResourceGroup
                        } elseif ($cluster.Id) {
                            $resourceGroupName = ($cluster.Id -split '/')[4]
                        }
                        
                        # Create minimal object on error
                        $AKSCluster = [PSCustomObject]@{
                            ResourceId = $cluster.Id
                            Subscription = $sub.Name
                            ResourceGroup = $resourceGroupName
                            ClusterName = $cluster.Name
                            Location = $cluster.Location
                            Error = $_.Exception.Message
                        }
                        $AKSClusters += $AKSCluster
                    }
                }
                Write-Progress -Id 9 -ParentId 1 -Activity "Processing AKS Clusters" -Completed
            } else {
                Write-Host "No AKS clusters found in subscription $($sub.Name)" -ForegroundColor Yellow
            }
        } catch {
            Write-CVLog "Error processing AKS clusters: $($_.Exception.Message)" -Level Warning -Source 'AKS' -Scope @{ Subscription = $sub.Name }
        }
    }

    # ---------------------------------------------------------------
    # BACKUP COVERAGE (Azure Backup / Recovery Services Vaults)
    # ---------------------------------------------------------------
    if (-not $Selected.BACKUP) {
        # Not requested. Recorded so VM rows report backup coverage as Unknown rather than a scored gap.
        Set-CVCollectionStatus -Scope $sub.Name -Signal BACKUP -Status Skipped
    } else {
        # Get-AzRecoveryServicesBackupItem has three parameter sets, and the DEFAULT (GetItemsForContainer)
        # requires -Container. Passing only -WorkloadType therefore bound to that default with a mandatory
        # parameter missing: non-interactively it threw, interactively it PROMPTED and hung. The vault-wide set
        # needs BOTH -BackupManagementType and -WorkloadType, so these pairs are mandatory, not optional extras.
        # Verified against Az.RecoveryServices 7.13.0 ValidateSets:
        #   WorkloadType         : AzureVM, AzureFiles, MSSQL, FileFolder, SAPHanaDatabase, AzureSQLDatabase
        #   BackupManagementType : AzureVM, MAB, AzureStorage, AzureWorkload, AzureSQL
        # 'AzureStorage' used to be passed as a WorkloadType, which is not valid - it is a BackupManagementType,
        # and the matching workload is AzureFiles. Azure Files backups were never collected at all.
        $backupWorkloads = @(
            @{ Mgmt = 'AzureVM';       Workload = 'AzureVM' }
            @{ Mgmt = 'AzureStorage';  Workload = 'AzureFiles' }
            @{ Mgmt = 'AzureWorkload'; Workload = 'MSSQL' }
            @{ Mgmt = 'AzureWorkload'; Workload = 'SAPHanaDatabase' }
            @{ Mgmt = 'MAB';           Workload = 'FileFolder' }
            @{ Mgmt = 'AzureSQL';      Workload = 'AzureSQLDatabase' }
        )
        try {
            Write-Host "Processing Azure Backup coverage in subscription $($sub.Name)" -ForegroundColor Green

            # Vault discovery. A subscription-scope list needs read at subscription scope; under resource-group
            # scoped RBAC it returns 403, which used to be swallowed by -ErrorAction SilentlyContinue and then
            # reported as the confident "No Recovery Services vaults found". Distinguish the two, and fall back
            # to per-resource-group enumeration so a scoped caller still gets their data.
            $vaults = @()
            $vaultListOk = $false
            try {
                $vaults = @(Get-AzRecoveryServicesVault -ErrorAction Stop)
                $vaultListOk = $true
            } catch {
                Write-CVLog "Subscription-scope vault listing failed; retrying per resource group. Grant Microsoft.RecoveryServices/vaults/read at subscription scope to avoid this: $($_.Exception.Message)" `
                            -Level Warning -Source 'Backup' -Scope @{ Subscription = $sub.Name; Category = 'VaultListScope' }
                foreach ($rg in @(Get-AzResourceGroup -ErrorAction SilentlyContinue)) {
                    try {
                        $vaults += @(Get-AzRecoveryServicesVault -ResourceGroupName $rg.ResourceGroupName -ErrorAction Stop)
                        $vaultListOk = $true    # at least one RG answered
                    } catch { }
                }
            }

            if (-not $vaultListOk) {
                # We never got an authoritative answer, so we cannot claim there are no vaults.
                Set-CVCollectionStatus -Scope $sub.Name -Signal BACKUP -Status Failed
                Write-CVLog "Could not enumerate Recovery Services vaults - backup coverage will report Unknown, not zero. Check Microsoft.RecoveryServices/vaults/read." `
                            -Level Warning -Source 'Backup' -Scope @{ Subscription = $sub.Name; Category = 'VaultListDenied' }
            } elseif (-not $vaults.Count) {
                # Enumeration genuinely succeeded and there are none. This IS a measured zero.
                Set-CVCollectionStatus -Scope $sub.Name -Signal BACKUP -Status Ok
                Write-Host "No Recovery Services vaults found in subscription $($sub.Name)" -ForegroundColor Yellow
            } else {
                $anyVaultQueried = $false
                foreach ($vault in $vaults) {
                    $vaultOk = $true
                    foreach ($pair in $backupWorkloads) {
                        try {
                            # -VaultId instead of the deprecated ambient Set-AzRecoveryServicesVaultContext, which
                            # is process-wide state that fights the per-subscription Set-AzContext above.
                            $items = @(Get-AzRecoveryServicesBackupItem -VaultId $vault.ID `
                                        -BackupManagementType $pair.Mgmt -WorkloadType $pair.Workload -ErrorAction Stop)
                            foreach ($item in $items) {
                                $BackupItems += [PSCustomObject]@{
                                    Subscription         = $sub.Name
                                    VaultName            = $vault.Name
                                    VaultResourceGroup   = $vault.ResourceGroupName
                                    VaultRegion          = $vault.Location
                                    BackupManagementType = $pair.Mgmt
                                    WorkloadType         = $pair.Workload
                                    ItemName             = $item.Name
                                    ContainerName        = $item.ContainerName
                                    ProtectionStatus     = $item.ProtectionStatus
                                    ProtectionState      = $item.ProtectionState
                                    LastBackupStatus     = $item.LastBackupStatus
                                    LastBackupTime       = $item.LastBackupTime
                                    PolicyName           = $item.ProtectionPolicyName
                                    DiskSizeGB           = if ($item.DiskSizeGB) { $item.DiskSizeGB } else { 'N/A' }
                                }
                            }
                        } catch {
                            # Was Write-Verbose with $VerbosePreference never set, i.e. invisible everywhere -
                            # which is how a total collection failure produced a clean-looking run. Write-CVLog
                            # routes through Add-CVDiagnostic, so N vaults x M workloads dedupe to one summary line.
                            $vaultOk = $false
                            Write-CVLog "Backup item query failed ($($pair.Mgmt)/$($pair.Workload)): $($_.Exception.Message)" `
                                        -Level Warning -Source 'Backup' `
                                        -Scope @{ Subscription = $sub.Name; Vault = $vault.Name; Workload = $pair.Workload }
                        }
                    }
                    if ($vaultOk) { $anyVaultQueried = $true }
                }
                Set-CVCollectionStatus -Scope $sub.Name -Signal BACKUP -Status $(if ($anyVaultQueried) { 'Ok' } else { 'Failed' })
            }
        } catch {
            Set-CVCollectionStatus -Scope $sub.Name -Signal BACKUP -Status Failed
            Write-CVLog "Error processing Azure Backup: $($_.Exception.Message)" -Level Warning -Source 'Backup' -Scope @{ Subscription = $sub.Name }
        }
    }

    # ---------------------------------------------------------------
    # UNMANAGED DISKS (Orphaned / unattached managed disks)
    # ---------------------------------------------------------------
    if ($Selected.UNMANAGEDDISKS) {
        try {
            Write-Host "Processing Unmanaged/Unattached Disks in subscription $($sub.Name)" -ForegroundColor Green
            $allDisks = Get-AzDisk -ErrorAction SilentlyContinue
            if ($allDisks) {
                foreach ($disk in $allDisks) {
                    if (-not (Test-EnvTagMatch -Tags $disk.Tags)) { continue }
                    $diskObj = [ordered]@{
                        Subscription    = $sub.Name
                        ResourceGroup   = $disk.ResourceGroupName
                        DiskName        = $disk.Name
                        ResourceId      = $disk.Id
                        Region          = $disk.Location
                        DiskSizeGB      = $disk.DiskSizeGB
                        DiskSizeTB      = [math]::Round($disk.DiskSizeGB / 1000, 4)
                        DiskState       = $disk.DiskState      # Unattached / Attached / Reserved
                        DiskSku         = $disk.Sku.Name
                        OsType          = $disk.OsType
                        # disk-cmek reads this. Encryption.Type is one of EncryptionAtRestWithPlatformKey /
                        # WithCustomerKey / WithPlatformAndCustomerKeys - the last two both involve a CMK. Absent
                        # Encryption block stays $null (Unknown); it is not evidence of platform-key encryption.
                        CmkEncrypted    = $(if (-not $disk.Encryption) { $null } else { [bool]("$($disk.Encryption.Type)" -match 'CustomerKey') })
                        DiskEncryptionSetId = $disk.Encryption.DiskEncryptionSetId
                        AttachedToVM    = if ($disk.ManagedBy) { ($disk.ManagedBy -split '/')[-1] } else { 'Unattached' }
                        CreationTime    = $disk.TimeCreated
                    }
                    if ($disk.Tags) { $disk.Tags.GetEnumerator() | ForEach-Object { $diskObj["Tag_$($_.Key)"] = $_.Value } }
                    $UnmanagedDiskItems += [PSCustomObject]$diskObj
                }
            }
        } catch {
            Write-CVLog "Error processing unmanaged disks: $($_.Exception.Message)" -Level Warning -Source 'UnmanagedDisks' -Scope @{ Subscription = $sub.Name }
        }
    }

    # ---------------------------------------------------------------
    # AZURE VMWARE SOLUTION (AVS)
    # ---------------------------------------------------------------
    if ($Selected.AVS) {
        try {
            Write-Host "Processing Azure VMware Solution in subscription $($sub.Name)" -ForegroundColor Green
            $avsClouds = Get-AzVMwarePrivateCloud -ErrorAction SilentlyContinue
            if ($avsClouds) {
                foreach ($cloud in $avsClouds) {
                    try {
                        $clusters = Get-AzVMwareCluster -PrivateCloudName $cloud.Name -ResourceGroupName $cloud.ResourceGroupName -ErrorAction SilentlyContinue
                        $totalHosts = ($clusters | Measure-Object -Property ClusterSize -Sum).Sum
                        $AVSClusters += [PSCustomObject]@{
                            Subscription        = $sub.Name
                            ResourceGroup       = $cloud.ResourceGroupName
                            PrivateCloudName    = $cloud.Name
                            Region              = $cloud.Location
                            Status              = $cloud.ProvisioningState
                            ManagementClusterSize = $cloud.ManagementClusterSize
                            ClusterCount        = if ($clusters) { $clusters.Count } else { 0 }
                            TotalHostCount      = $totalHosts
                            SkuName             = $cloud.SkuName
                            CircuitPrimarySubnet = $cloud.CircuitPrimarySubnet
                            NsxtVersion         = $cloud.NsxtVersion
                            VcenterVersion      = $cloud.VcenterVersion
                        }
                    } catch { Write-CVLog "Error processing AVS cloud: $($_.Exception.Message)" -Level Warning -Source 'AVS' -Scope @{ Subscription = $sub.Name; Cloud = $cloud.Name } }
                }
            } else {
                Write-Host "No Azure VMware Solution private clouds found in subscription $($sub.Name)" -ForegroundColor Yellow
            }
        } catch {
            Write-CVLog "Error processing AVS: $($_.Exception.Message)" -Level Warning -Source 'AVS' -Scope @{ Subscription = $sub.Name }
        }
    }
}
}
finally {
    # In a finally so an unhandled throw inside the loop cannot leave "Stop" in force for the export section -
    # which is what turned one bad subscription into a run with zero output files.
    $ErrorActionPreference = $savedEAP
}

# Complete subscription progress
Write-Progress -Id 1 -Activity "Processing Azure Subscriptions" -Completed
Write-CVSection "Subscription Processing Complete"

# ---------------------------------------------------------------------------
# Run-wide resource-group filter (-ResourceGroups): scope the Data Protection inventory to the requested groups,
# matching the Cloud Rewind pass ("entire run" filter). Applied via the ResourceGroup property every inventory
# row carries; rows without a resolvable ResourceGroup are kept (conservative). -Tags is honored fully by the
# Cloud Rewind pass; DP-side per-service tag capture is a follow-up.
# ---------------------------------------------------------------------------
# NOTE: build $rgFilter FIRST and guard on it. Guarding on @($ResourceGroups).Count is wrong: when the caller
# omits -ResourceGroups the parameter is $null, and @($null) is a ONE-element array containing $null, so .Count
# is 1 and the guard passes on every run. $rgFilter would then be empty, $keepRg would match nothing, and every
# inventory row carrying a ResourceGroup got silently discarded - only row types that never set that property
# (File Shares, PostgreSQL) survived, via the IsNullOrWhiteSpace escape hatch below.
$rgFilter = @($ResourceGroups | Where-Object { $_ -and "$_".Trim() })
if (-not $SkipDataProtection -and $rgFilter.Count) {
    $keepRg = {
        param($obj)
        if (-not $obj) { return $false }
        # Collections do not agree on the property name: most use ResourceGroup, but MySQL/PostgreSQL/Cosmos use
        # ResourceGroupName and BackupItems only carry VaultResourceGroup. Probing only ResourceGroup meant the
        # filter silently did not apply to any of those - they all fell through the escape hatch below.
        $rg = $null
        foreach ($prop in @('ResourceGroup','ResourceGroupName','VaultResourceGroup')) {
            $p = $obj.PSObject.Properties[$prop]
            if ($p -and -not [string]::IsNullOrWhiteSpace("$($p.Value)")) { $rg = $p.Value; break }
        }
        if ([string]::IsNullOrWhiteSpace("$rg")) { return $true }   # unknown resource group -> keep
        return [bool](@($rgFilter | Where-Object { $_.Trim() -ieq "$rg".Trim() }).Count)
    }
    foreach ($arrName in @('VMs','StorageAccounts','FileShares','NetAppVolumes','SqlInstancesInventory','SqlDbInventory','SqlMIDbInventory','MySQLServers','PostgreSQLServers','CosmosDBs','AKSClusters','UnmanagedDiskItems','AVSClusters','BackupItems')) {
        $cur = Get-Variable -Name $arrName -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $cur) { Set-Variable -Name $arrName -Value @(@($cur) | Where-Object { & $keepRg $_ }) }
    }
    Write-CVLog "Data Protection scoped to resource group(s): $($rgFilter -join ', ')" -Level Info -Source 'Filter'
}

# ---------------------------------------------------------------------------
# Protection enrichment: attribute Recovery Services backup items and managed-disk
# snapshots back onto each VM row, so every resource carries its own coverage.
# ---------------------------------------------------------------------------
# Attribution lives in common/CVSizing.Backup.Azure.ps1 so it is unit-testable without Azure
# (tests/Invoke-CVAzureBackupTests.ps1). It keys on subscription|resourceGroup|name so same-named VMs in
# different resource groups cannot inherit each other's backup, filters in-guest DB workloads out of VM-level
# protection, judges protection on ProtectionState alone, and leaves every field $null for any subscription
# whose collection did not actually succeed.
$protectionSummary = Resolve-CVAzureBackupAttribution -BackupItems $BackupItems -VMs $VMs `
                        -DiskIdMap $VMDiskIdMap -Snapshots $AzSnapshots -Status (Get-CVCollectionStatusMap)

$protectedVmCount = @($VMs | Where-Object { $_.BackupEnabled -eq $true -or $_.SnapshotsEnabled -eq $true }).Count
Write-CVLog ("Protection coverage: {0}/{1} VMs have a backup item or snapshot" -f $protectedVmCount, $protectionSummary.VmCount) -Level Info -Source 'Protection'
if ($protectionSummary.UnknownBackupCount -gt 0) {
    # Say this out loud. Silently reporting these as unprotected is the defect this replaced.
    Write-CVLog ("{0} VM(s) have UNKNOWN backup coverage - their subscription's Recovery Services data could not be collected, so they are excluded from scoring rather than counted as unprotected." -f $protectionSummary.UnknownBackupCount) `
                -Level Warning -Source 'Protection' -Scope @{ Category = 'CoverageUnknown' }
}
if ($protectionSummary.AmbiguousCount -gt 0) {
    Write-CVLog ("{0} VM(s) matched a backup item only by name (no resource group in the item name) while sharing that name with another VM - see AmbiguousNameMatch." -f $protectionSummary.AmbiguousCount) `
                -Level Warning -Source 'Protection' -Scope @{ Category = 'AmbiguousMatch' }
}
if ($Selected.VM) { Write-Host "Total VMs found: $($VMs.Count)" -ForegroundColor Cyan }
if ($Selected.STORAGE) { Write-Host "Total Storage Accounts found: $($StorageAccounts.Count)" -ForegroundColor Cyan }
if ($Selected.FILESHARE) { Write-Host "Total File Shares found: $($FileShares.Count)" -ForegroundColor Cyan }
if ($Selected.NETAPP) { Write-Host "Total NetApp Volumes found: $($NetAppVolumes.Count)" -ForegroundColor Cyan }
if ($Selected.SQL) { Write-Host "Total SQL Managed Instances found: $($SqlInstancesInventory.Count)" -ForegroundColor Cyan }
if ($Selected.SQL) { Write-Host "Total MySQL Servers found: $($MySQLServers.Count)" -ForegroundColor Cyan }
if ($Selected.SQL) { Write-Host "Total PostgreSQL Servers found: $($PostgreSQLServers.Count)" -ForegroundColor Cyan }
if ($Selected.SQL) { Write-Host "Total Azure SQL Servers found: $(($SqlDbInventory | Select-Object -ExpandProperty Server | Sort-Object -Unique | Measure-Object).Count)" -ForegroundColor Cyan }
if ($Selected.COSMOS) { Write-Host "Total CosmosDB Accounts found: $($CosmosDBs.Count)" -ForegroundColor Cyan }
if ($Selected.AKS) { Write-Host "Total AKS Clusters found: $($AKSClusters.Count)" -ForegroundColor Cyan }
if ($Selected.AKS) { Write-Host "Total AKS Persistent Volumes found: $($AKSPersistentVolumes.Count)" -ForegroundColor Cyan }
if ($Selected.AKS) { Write-Host "Total AKS Persistent Volume Claims found: $($AKSPersistentVolumeClaims.Count)" -ForegroundColor Cyan }
}   # end of the Data Protection pipeline (-SkipDataProtection wrap)

# ============================================================
# CYBER RESILIENCE POSTURE REPORT  (skip with -SkipResilienceReport)
# Scores each resource's CURRENT NATIVE Azure configuration against the Cloud Resilience Control Catalog.
# Runs before the CSV exports so Ctl_* columns land on every per-service CSV. Unknown signals are excluded
# from the score (never failing), and per-row failures are isolated. Empty environment -> "nothing to assess".
# ============================================================
if (-not $SkipResilienceReport -and -not $SkipDataProtection) {
  try {
    Write-CVSection 'Cyber Resilience Posture'
    $azControls   = Get-CVAzureResilienceControls

    # Storage posture signals are collected inside the subscription loop now (see the storage block above), where
    # the Az context already points at the right subscription. The post-loop pass that used to live here re-fetched
    # each account with no -SubscriptionId, so it only ever worked for the last subscription processed.

    # Azure Files is SSE-encrypted at rest by default.
    foreach ($fsh in @($FileShares)) { if ($fsh) { Add-Member -InputObject $fsh -NotePropertyName EncryptedAtRest -NotePropertyValue $true -Force } }

    # Evaluate each resource type; append Ctl_*/ResilienceScore/ResilienceGaps onto the inventory rows.
    $collections = @(
        @{ Type='VM';        Set=$azControls.VM;        Rows=@($VMs) }
        @{ Type='Disk';      Set=$azControls.Disk;      Rows=@($UnmanagedDiskItems) }
        @{ Type='Storage';   Set=$azControls.Storage;   Rows=@($StorageAccounts) }
        @{ Type='SQL';       Set=$azControls.SQL;       Rows=@($SqlDbInventory) }
        @{ Type='FlexDB';    Set=$azControls.FlexDB;    Rows=(@($MySQLServers) + @($PostgreSQLServers)) }
        @{ Type='Cosmos';    Set=$azControls.Cosmos;    Rows=@($CosmosDBs) }
        @{ Type='FileShare'; Set=$azControls.FileShare; Rows=@($FileShares) }
        @{ Type='AKS';       Set=$azControls.AKS;       Rows=@($AKSClusters) }
    )
    # Name and size are the only fields that differ meaningfully per type; resource group, region and resource id
    # are probed from candidate lists inside New-CVSignalRow.
    $azSignalFields = @{
        VM        = @{ Name = 'VMName';         SizeGB = 'VMDiskSizeGB' }
        Disk      = @{ Name = 'DiskName';       SizeGB = 'DiskSizeGB' }
        Storage   = @{ Name = 'StorageAccount'; SizeGB = 'UsedCapacityGB' }
        SQL       = @{ Name = 'Database';       SizeGB = 'SizingGB';   Parent = 'Server' }
        FlexDB    = @{ Name = 'Name';           SizeGB = 'StorageGB' }
        Cosmos    = @{ Name = 'Name';           SizeGB = 'DataUsageGB' }
        FileShare = @{ Name = 'Name';           SizeGB = 'UsedCapacityGB'; Parent = 'StorageAccount' }
        AKS       = @{ Name = 'ClusterName';    SizeGB = 'PersistentVolumeCapacityGB' }
    }
    # Signal fields per resource type, derived from the control definitions so the export cannot drift.
    $azSignalMap = Get-CVSignalFieldMap -ControlSets $azControls
    $signalRows  = New-Object System.Collections.Generic.List[psobject]
    $resilShownErr = $false
    foreach ($c in $collections) {
        if (-not $c.Set) { continue }
        foreach ($row in $c.Rows) {
            if (-not $row) { continue }
            try {
                # No evaluation. The controls are consulted only for WHICH fields are signals (via
                # Get-CVSignalFieldMap); their pass/fail thresholds are the backend's to apply. Nothing is written
                # back onto the inventory row either - Ctl_*/ResilienceScore/ResilienceGaps used to be added here,
                # which put our verdicts on the per-service CSVs and contradicted the judgement-free export.
                $signalRows.Add((New-CVSignalRow -Resource $row -ResourceType $c.Type `
                                    -SignalFields $azSignalMap[$c.Type] -FieldMap $azSignalFields[$c.Type]))
            } catch {
                if (-not $resilShownErr) {
                    $resilShownErr = $true
                    Write-Host ("[Resilience] signal export error on a $($c.Type) row: $($_.Exception.GetType().Name): $($_.Exception.Message)") -ForegroundColor DarkYellow
                }
            }
        }
    }

    # No score is printed. A score is a judgement, and an on-screen "0/100" invites an SE to quote it - which was
    # exactly the trap where a storage account with 1 of 6 controls assessable scored 100. What is reported below
    # is countable fact: how many resources were exported and how completely they were measured.
    if ($signalRows.Count) {
        # Judgement-free export: the VALUES the controls evaluate, not our verdicts about them. -KeepDeclaredColumns
        # fixes the header across runs and scopes so a machine consumer sees one stable schema.
        Sort-CVSignalRows -Rows $signalRows |
            Export-CVCsv -Path (Join-Path $outdir ("azure_resilience_signals_$dateStr.csv")) `
                         -PreferredOrder (Get-CVSignalColumns -ControlSets $azControls) -KeepDeclaredColumns
        Write-CVLog ("Resilience signals: {0} resource(s) exported across {1} resource type(s)." -f `
                     $signalRows.Count, @($signalRows | Select-Object -ExpandProperty ResourceType -Unique).Count) `
                    -Level Info -Source 'Resilience'
        Write-Host "azure_resilience_signals_$dateStr.csv written to $outdir" -ForegroundColor Cyan
    } else {
        Write-CVLog "No resources of an assessed type were found - no signals CSV written." -Level Info -Source 'Resilience'
    }
  } catch {
    Write-CVLog "Resilience report failed: $($_.Exception.Message)" -Level Warning -Source 'Resilience'
    Write-Host ("[Resilience] $($_.Exception.GetType().Name): $($_.Exception.Message) :: " + ($_.ScriptStackTrace -replace "`r?`n", ' <- ')) -ForegroundColor DarkYellow
  }
}

# ============================================================
# CLOUD REWIND SIZING  (skip with -SkipCloudRewind)
# Discovers via Azure Resource Graph (default) or Get-AzResource (fallback / -CloudRewindDiscovery Arm), already
# attach/exclusion-filtered, then classifies against the Cloud Rewind billable taxonomy (article 89349). One row
# per BILLABLE resource + a billable-vs-non-billable summary. Honors the run-wide -ResourceGroups/-Tags filter.
# ============================================================
if (-not $SkipCloudRewind) {
  try {
    Write-CVSection 'Cloud Rewind Sizing'
    $crTax           = Get-CVAzureCloudRewindTaxonomy
    $crFilterTagKeys = Get-CVFilterTagKeys -FilterTags $Tags
    $crRows          = New-Object System.Collections.Generic.List[psobject]
    $crClassified    = New-Object System.Collections.Generic.List[psobject]
    # Discovery returns resources already attach/exclusion-filtered (KQL for Graph, Test-CVAzureCloudRewindInclude
    # for Arm), so the classify loop below must NOT re-apply the inclusion test.
    $crItems = @(Invoke-CVAzureCloudRewindDiscovery -Backend $CloudRewindDiscovery -Subs $subs)

    foreach ($it in $crItems) {
        if (-not (Test-CVResourceMatch -ResourceGroup $it.ResourceGroup -Tags $it.Tags -FilterResourceGroups $ResourceGroups -FilterTags $Tags)) { continue }
        $billable = Get-CVCloudRewindBillable -ResourceType $it.Type -Taxonomy $crTax
        if ($null -eq $billable) { continue }   # defensive: discovery already returns in-taxonomy resources only

        $class = Get-CVAzureCloudRewindClass -ResourceType $it.Type
        $crClassified.Add([pscustomobject]@{ Account = $it.SubscriptionId; AccountName = $it.SubscriptionName; Billable = [bool]$billable; ResourceClass = $class })

        if ($billable) {
            $crRows.Add( (New-CVCloudRewindRow -Fields @{
                CloudProvider    = 'Azure'
                Account          = $it.SubscriptionId
                AccountName      = $it.SubscriptionName
                TenantOrOrg      = $it.TenantId
                Region           = $it.Location
                ResourceGroup    = $it.ResourceGroup
                ResourceName     = $it.Name
                ResourceId       = $it.Id
                ResourceType     = $it.Type
                ResourceState    = ''
                BillableReason   = (Get-CVAzureCloudRewindReason -ResourceType $it.Type)
                VpcOrVNet        = ''      # topology enrichment: fast-follow
                Subnet           = ''
                AvailabilityZone = ''
                HasPublicIp      = ''
                DiscoveredAt     = $dateStr
            } -Tags $it.Tags -FilterTagKeys $crFilterTagKeys) )
        }
    }

    $crCsv = Join-Path $outdir ("azure_cloudrewind_$dateStr.csv")
    if ($crRows.Count) {
        $crRows | Export-CVCsv -Path $crCsv
        Write-Host "azure_cloudrewind_$dateStr.csv ($($crRows.Count) billable resources) written to $outdir" -ForegroundColor Cyan
    } else {
        Write-CVLog 'Cloud Rewind: no billable resources found for the current scope.' -Level Warning -Source 'CloudRewind'
    }

    $crSummary = Get-CVCloudRewindSummary -Classified $crClassified
    if (@($crSummary).Count) {
        $crSummary | Export-CVCsv -Path (Join-Path $outdir ("azure_cloudrewind_summary_$dateStr.csv"))
        $crTB  = (@($crSummary) | Measure-Object TotalBillableResources -Sum).Sum
        $crTNB = (@($crSummary) | Measure-Object TotalNonBillableResources -Sum).Sum
        Write-CVLog ("Cloud Rewind: {0} billable, {1} non-billable resources across {2} subscription(s)" -f $crTB, $crTNB, @($crSummary).Count) -Level Success -Source 'CloudRewind'
        Write-Host "azure_cloudrewind_summary_$dateStr.csv written to $outdir" -ForegroundColor Cyan
    }
  } catch {
    Write-CVLog "Cloud Rewind pass failed: $($_.Exception.Message)" -Level Warning -Source 'CloudRewind'
    Write-Host ("[CloudRewind] $($_.Exception.GetType().Name): $($_.Exception.Message) :: " + ($_.ScriptStackTrace -replace "`r?`n", ' <- ')) -ForegroundColor DarkYellow
  }
}

# Write all resources to CSV files
Write-Progress -Id 5 -Activity "Generating Output Files" -Status "Writing CSV files..." -PercentComplete 0

if ($Selected.VM -and $VMs.Count) { 
    Write-Progress -Id 5 -Activity "Generating Output Files" -Status "Writing VMs CSV..." -PercentComplete 25
    $VMs | Export-CVCsv -Path (Join-Path $outdir "azure_vm_info_$dateStr.csv")
    Write-Host "azure_vm_info_$dateStr.csv file has been written to $outdir" -ForegroundColor Cyan
}
if ($Selected.STORAGE -and $StorageAccounts.Count) { 
    Write-Progress -Id 5 -Activity "Generating Output Files" -Status "Writing Storage Accounts CSV..." -PercentComplete 50
    $StorageAccounts | Export-CVCsv -Path (Join-Path $outdir "azure_storage_accounts_info_$dateStr.csv")
    Write-Host "azure_storage_accounts_info_$dateStr.csv file has been written to $outdir" -ForegroundColor Cyan
}
if ($Selected.FILESHARE -and $FileShares.Count) { 
    Write-Progress -Id 5 -Activity "Generating Output Files" -Status "Writing File Shares CSV..." -PercentComplete 60
    $FileShares | Export-CVCsv -Path (Join-Path $outdir "azure_file_shares_info_$dateStr.csv")
    Write-Host "azure_file_shares_info_$dateStr.csv file has been written to $outdir" -ForegroundColor Cyan
}
if ($Selected.NETAPP -and $NetAppVolumes.Count) { 
    Write-Progress -Id 5 -Activity "Generating Output Files" -Status "Writing NetApp Files CSV..." -PercentComplete 70
    $NetAppVolumes | Export-CVCsv -Path (Join-Path $outdir "azure_netapp_volumes_info_$dateStr.csv")
    Write-Host "azure_netapp_volumes_info_$dateStr.csv file has been written to $outdir" -ForegroundColor Cyan
}
if ($Selected.SQL -and $SqlInstancesInventory.Count) { 
    Write-Progress -Id 5 -Activity "Generating Output Files" -Status "Writing SQL Instances CSV..." -PercentComplete 75
    $SqlInstancesInventory | Export-CVCsv -Path (Join-Path $outdir "azure_sql_managed_instances_$dateStr.csv")
    Write-Host "azure_sql_managed_instances_$dateStr.csv file has been written to $outdir" -ForegroundColor Cyan
}
if ($Selected.SQL -and $SqlDbInventory.Count) {
    Write-Progress -Id 5 -Activity "Generating Output Files" -Status "Writing SQL Databases CSV..." -PercentComplete 80
    $SqlDbInventory | Export-CVCsv -Path (Join-Path $outdir "azure_sql_databases_inventory_$dateStr.csv")
    Write-Host "azure_sql_databases_inventory_$dateStr.csv file has been written to $outdir" -ForegroundColor Cyan
}
if ($Selected.SQL -and $SqlMIDbInventory.Count) {
    Write-Progress -Id 5 -Activity "Generating Output Files" -Status "Writing SQL MI Databases CSV..." -PercentComplete 82
    $SqlMIDbInventory | Export-CVCsv -Path (Join-Path $outdir "azure_sql_mi_databases_$dateStr.csv")
    Write-Host "azure_sql_mi_databases_$dateStr.csv file has been written to $outdir" -ForegroundColor Cyan
}
if ($Selected.COSMOS -and $CosmosDBs.Count) {
    Write-Progress -Id 5 -Activity "Generating Output Files" -Status "Writing CosmosDB CSV..." -PercentComplete 85
    $CosmosDBs | Export-CVCsv -Path (Join-Path $outdir "azure_cosmosdb_accounts_$dateStr.csv")
    Write-Host "azure_cosmosdb_accounts_$dateStr.csv file has been written to $outdir" -ForegroundColor Cyan
}
if ($Selected.SQL -and $MySQLServers.Count) {
    Write-Progress -Id 5 -Activity "Generating Output Files" -Status "Writing MySQL CSV..." -PercentComplete 90
    $MySQLServers | Export-CVCsv -Path (Join-Path $outdir "azure_mysql_servers_$dateStr.csv")
    Write-Host "azure_mysql_servers_$dateStr.csv file has been written to $outdir" -ForegroundColor Cyan
}
if ($Selected.SQL -and $PostgreSQLServers.Count) {
    Write-Progress -Id 5 -Activity "Generating Output Files" -Status "Writing PostgreSQL CSV..." -PercentComplete 92
    $PostgreSQLServers | Export-CVCsv -Path (Join-Path $outdir "azure_postgresql_servers_$dateStr.csv")
    Write-Host "azure_postgresql_servers_$dateStr.csv file has been written to $outdir" -ForegroundColor Cyan
}
if ($Selected.AKS -and $AKSClusters.Count) {
    Write-Progress -Id 5 -Activity "Generating Output Files" -Status "Writing AKS Clusters CSV..." -PercentComplete 94
    $AKSClusters | Export-CVCsv -Path (Join-Path $outdir "azure_aks_clusters_$dateStr.csv")
    Write-Host "azure_aks_clusters_$dateStr.csv file has been written to $outdir" -ForegroundColor Cyan
}
if ($Selected.AKS -and $AKSPersistentVolumes.Count) {
    Write-Progress -Id 5 -Activity "Generating Output Files" -Status "Writing AKS Persistent Volumes CSV..." -PercentComplete 96
    $AKSPersistentVolumes | Export-CVCsv -Path (Join-Path $outdir "azure_aks_persistent_volumes_$dateStr.csv")
    Write-Host "azure_aks_persistent_volumes_$dateStr.csv file has been written to $outdir" -ForegroundColor Cyan
}
if ($Selected.AKS -and $AKSPersistentVolumeClaims.Count) {
    Write-Progress -Id 5 -Activity "Generating Output Files" -Status "Writing AKS Persistent Volume Claims CSV..." -PercentComplete 98
    $AKSPersistentVolumeClaims | Export-CVCsv -Path (Join-Path $outdir "azure_aks_persistent_volume_claims_$dateStr.csv")
    Write-Host "azure_aks_persistent_volume_claims_$dateStr.csv file has been written to $outdir" -ForegroundColor Cyan
}
if ($Selected.BACKUP -and $BackupItems.Count) {
    $BackupItems | Export-CVCsv -Path (Join-Path $outdir "azure_backup_items_$dateStr.csv")
    Write-Host "azure_backup_items_$dateStr.csv file has been written to $outdir" -ForegroundColor Cyan
}
# Managed-disk snapshots. These drive the SnapshotCount/SnapshotSourceDiskTB columns on every VM row but were
# never exported, so there was no way to audit those numbers or see which snapshots the tool actually found.
if ($AzSnapshots.Count) {
    $AzSnapshots | Export-CVCsv -Path (Join-Path $outdir "azure_snapshots_$dateStr.csv") `
        -PreferredOrder @('Subscription','ResourceGroup','SnapshotName','Region','Incremental','SourceDiskSizeGB','TimeCreated','SourceDiskId')
    Write-Host "azure_snapshots_$dateStr.csv file has been written to $outdir" -ForegroundColor Cyan
}
if ($Selected.UNMANAGEDDISKS -and $UnmanagedDiskItems.Count) {
    $UnmanagedDiskItems | Export-CVCsv -Path (Join-Path $outdir "azure_disks_inventory_$dateStr.csv")
    Write-Host "azure_disks_inventory_$dateStr.csv file has been written to $outdir" -ForegroundColor Cyan
}
if ($Selected.AVS -and $AVSClusters.Count) {
    $AVSClusters | Export-CVCsv -Path (Join-Path $outdir "azure_avs_clusters_$dateStr.csv")
    Write-Host "azure_avs_clusters_$dateStr.csv file has been written to $outdir" -ForegroundColor Cyan
}

function Get-CVSqlDbSizeTotal {
    <#
      .SYNOPSIS  Total SQL Database size for a summary row, using consumed size and counting each pool once.
      .DESCRIPTION Two defects this replaces:
                     1. The summaries summed MaxSizeGB - the PROVISIONED ceiling - even though the utilized figure
                        was already collected on the same row. For a sizing spreadsheet that is the wrong number.
                     2. Every database in an elastic pool reports the POOL's max size, so summing across databases
                        counted one pool once per database in it and inflated the total by the pool's DB count.
                   SizingGB already prefers Utilized -> Allocated -> ProvisionedMax, so only ProvisionedMax rows
                   need pool de-duplication; utilized figures are genuinely per-database and must all be summed.
    #>
    param($Rows)
    $total = 0.0
    $seenPools = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($r in @($Rows)) {
        if (-not $r) { continue }
        $v = $r.SizingGB
        if ($null -eq $v) { $v = $r.MaxSizeGB }          # rows from an older shape
        if ($null -eq $v) { continue }
        if ($r.IsPooled -eq $true -and "$($r.SizeBasis)" -eq 'ProvisionedMax') {
            $pk = "$($r.Subscription)|$($r.ResourceGroup)|$($r.ElasticPoolName)"
            if (-not $seenPools.Add($pk)) { continue }   # this pool's capacity is already counted
        }
        $total += [double]$v
    }
    return [math]::Round($total, 3)
}

# Create comprehensive summary CSV
$summaryRows = @()

# Add overall resource type counts first
foreach ($k in $ResourceTypeMap.Keys) { 
    if ($Selected[$k]) {  
        # Calculate total disk size for VMs or storage capacity for Storage Accounts
        $Subscription = "All"
        $ResourceType = ""
        $totalSize = 0
        $totalSizeTB = 0
        $totalSizeTiB = 0
        $count = 0
        
        if ($k -eq "VM" -and $VMs.Count -gt 0) {
            $ResourceType = "VM"
            $count = $VMs.Count
            $totalSize = ($VMs | Measure-Object -Property VMDiskSizeGB -Sum).Sum
            if ($totalSize -eq $null) { $totalSize = 0 }
            $totalSizeTB = [math]::Round($totalSize / 1000, 4)
            $totalSizeTiB = [math]::Round($totalSize / 1024, 4)
        } elseif ($k -eq "STORAGE" -and $StorageAccounts.Count -gt 0) {
            $totalBlobCount = ($StorageAccounts | Measure-Object -Property BlobCount -Sum).Sum
            if ($totalBlobCount -eq $null) { $totalBlobCount = 0 }
            $ResourceType = "Storage Account (Total Blobs: $totalBlobCount)"
            $count = $StorageAccounts.Count
            $totalCapacityBytes = ($StorageAccounts | Measure-Object -Property UsedCapacityBytes -Sum).Sum
            if ($totalCapacityBytes -eq $null) { $totalCapacityBytes = 0 }
            $totalSize = [math]::round(($totalCapacityBytes / 1000000000), 2)  # Convert bytes to GB
            $totalSizeTB = [math]::Round($totalCapacityBytes / 1000000000000, 4)  # Convert bytes to TB
            $totalSizeTiB = [math]::Round($totalCapacityBytes / 1099511627776, 4)  # Convert bytes to TiB
        } elseif ($k -eq "FILESHARE" -and $FileShares.Count -gt 0) {
            $ResourceType = "File Share"
            $count = $FileShares.Count
            $totalCapacityBytes = ($FileShares | Measure-Object -Property UsedCapacityBytes -Sum).Sum
            if ($totalCapacityBytes -eq $null) { $totalCapacityBytes = 0 }
            $totalSize = [math]::round(($totalCapacityBytes / 1000000000), 2)  # Convert bytes to GB
            $totalSizeTB = [math]::Round($totalCapacityBytes / 1000000000000, 4)  # Convert bytes to TB
            $totalSizeTiB = [math]::Round($totalCapacityBytes / 1099511627776, 4)  # Convert bytes to TiB
        } elseif ($k -eq "NETAPP" -and $NetAppVolumes.Count -gt 0) {
            $ResourceType = "NetApp Files Volume"
            $count = $NetAppVolumes.Count
            $totalCapacityBytes = ($NetAppVolumes | Measure-Object -Property UsedCapacityBytes -Sum).Sum
            if ($totalCapacityBytes -eq $null) { $totalCapacityBytes = 0 }
            $totalSize = [math]::round(($totalCapacityBytes / 1000000000), 2)  # Convert bytes to GB
            $totalSizeTB = [math]::Round($totalCapacityBytes / 1000000000000, 4)  # Convert bytes to TB
            $totalSizeTiB = [math]::Round($totalCapacityBytes / 1099511627776, 4)  # Convert bytes to TiB
        } elseif ($k -eq "SQL") {
            # Handle SQL Managed Instances and SQL Databases separately
            
            # Add SQL Managed Instances if any exist
            if ($SqlInstancesInventory.Count -gt 0) {
                $ResourceType = "SQL Managed Instances"
                $count = $SqlInstancesInventory.Count
                $totalStorageUsed = ($SqlInstancesInventory | Measure-Object -Property StorageUsedGB -Sum).Sum
                if ($totalStorageUsed -eq $null) { $totalStorageUsed = 0 }
                $totalSize = [math]::Round($totalStorageUsed, 2)
                $totalSizeTB = [math]::Round($totalSize / 1000, 4)
                $totalSizeTiB = [math]::Round($totalSize / 1024, 4)
                
                # Add SQL Managed Instances summary row
                $summaryRows += [PSCustomObject]@{ 
                    Subscription = "All"
                    ResourceType = $ResourceType
                    Region = "All"
                    Count = $count
                    TotalSizeGB = $totalSize
                    TotalSizeTB = $totalSizeTB
                    TotalSizeTiB = $totalSizeTiB
                }
            }
            
            # Add SQL Databases if any exist
            if ($SqlDbInventory.Count -gt 0) {
                $ResourceType = "SQL Databases"
                $count = $SqlDbInventory.Count
                $totalDbMaxSize = Get-CVSqlDbSizeTotal -Rows $SqlDbInventory
                if ($totalDbMaxSize -eq $null) { $totalDbMaxSize = 0 }
                $totalSize = [math]::Round($totalDbMaxSize, 2)
                $totalSizeTB = [math]::Round($totalSize / 1000, 4)
                $totalSizeTiB = [math]::Round($totalSize / 1024, 4)
                
                # Add SQL Databases summary row
                $summaryRows += [PSCustomObject]@{ 
                    Subscription = "All"
                    ResourceType = $ResourceType
                    Region = "All"
                    Count = $count
                    TotalSizeGB = $totalSize
                    TotalSizeTB = $totalSizeTB
                    TotalSizeTiB = $totalSizeTiB
                }
            }
            
            # Add MySQL Servers if any exist
            if ($MySQLServers.Count -gt 0) {
                $ResourceType = "MySQL Servers"
                $count = $MySQLServers.Count
                # Calculate total storage from StorageGB field
                $totalStorageGB = 0
                foreach ($mysql in $MySQLServers) {
                    if ($mysql.StorageUsedGB -ne $null -and $mysql.StorageUsedGB -ne '') {
                        $totalStorageGB += [double]$mysql.StorageUsedGB
                    }
                }
                $totalSize = [math]::Round($totalStorageGB, 2)
                $totalSizeTB = [math]::Round($totalSize / 1000, 4)
                $totalSizeTiB = [math]::Round($totalSize / 1024, 4)
                
                # Add MySQL Servers summary row
                $summaryRows += [PSCustomObject]@{ 
                    Subscription = "All"
                    ResourceType = $ResourceType
                    Region = "All"
                    Count = $count
                    TotalSizeGB = $totalSize
                    TotalSizeTB = $totalSizeTB
                    TotalSizeTiB = $totalSizeTiB
                }
            }
            
            # Add PostgreSQL Servers if any exist
            if ($PostgreSQLServers.Count -gt 0) {
                $ResourceType = "PostgreSQL Servers"
                $count = $PostgreSQLServers.Count
                # Calculate total storage from StorageGB field
                $totalStorageGB = 0
                foreach ($postgres in $PostgreSQLServers) {
                    if ($postgres.StorageUsedGB -ne $null -and $postgres.StorageUsedGB -ne '') {
                        $totalStorageGB += [double]$postgres.StorageUsedGB
                    }
                }
                $totalSize = [math]::Round($totalStorageGB, 2)
                $totalSizeTB = [math]::Round($totalSize / 1000, 4)
                $totalSizeTiB = [math]::Round($totalSize / 1024, 4)
                
                # Add PostgreSQL Servers summary row
                $summaryRows += [PSCustomObject]@{ 
                    Subscription = "All"
                    ResourceType = $ResourceType
                    Region = "All"
                    Count = $count
                    TotalSizeGB = $totalSize
                    TotalSizeTB = $totalSizeTB
                    TotalSizeTiB = $totalSizeTiB
                }
            }
            
            # Set count to 0 to prevent the normal summary row addition at the end
            $count = 0
        } elseif ($k -eq "COSMOS" -and $CosmosDBs.Count -gt 0) {
            $totalDatabases = ($CosmosDBs | Measure-Object -Property DatabaseCount -Sum).Sum
            if ($totalDatabases -eq $null) { $totalDatabases = 0 }
            $totalContainers = ($CosmosDBs | Measure-Object -Property ContainerCount -Sum).Sum
            if ($totalContainers -eq $null) { $totalContainers = 0 }
            $ResourceType = "CosmosDB"
            $count = $CosmosDBs.Count
            # Calculate total from DataUsage field (in bytes)
            $totalDataUsage = 0
            foreach ($cosmos in $CosmosDBs) {
                if ($cosmos.DataUsage -ne $null -and $cosmos.DataUsage -ne '') {
                    $totalDataUsage += [double]$cosmos.DataUsage
                }
            }
            $totalCapacityGB = if ($totalDataUsage -gt 0) { [math]::Round($totalDataUsage / 1000000000, 2) } else { 0 }
            $totalSize = $totalCapacityGB
            $totalSizeTB = if ($totalDataUsage -gt 0) { [math]::Round($totalDataUsage / 1000000000000, 4) } else { 0 }
            $totalSizeTiB = if ($totalDataUsage -gt 0) { [math]::Round($totalDataUsage / 1099511627776, 4) } else { 0 }
        } elseif ($k -eq "AKS" -and $AKSClusters.Count -gt 0) {
            $ResourceType = "AKS Clusters"
            $count = $AKSClusters.Count
            # Calculate total persistent volume storage
            $totalPVStorageGB = 0
            $totalPVs = 0
            $totalPVCs = 0
            foreach ($aks in $AKSClusters) {
                if ($aks.PersistentVolumeCapacityGB -and $aks.PersistentVolumeCapacityGB -ne '' -and $null -ne $aks.PersistentVolumeCapacityGB) {
                    $totalPVStorageGB += [double]$aks.PersistentVolumeCapacityGB
                }
                if ($aks.PersistentVolumeCount -and $aks.PersistentVolumeCount -ne '' -and $null -ne $aks.PersistentVolumeCount) {
                    $totalPVs += [int]$aks.PersistentVolumeCount
                }
                if ($aks.PersistentVolumeClaimCount -and $aks.PersistentVolumeClaimCount -ne '' -and $null -ne $aks.PersistentVolumeClaimCount) {
                    $totalPVCs += [int]$aks.PersistentVolumeClaimCount
                }
            }
            $ResourceType = "AKS Clusters (Total PVs: $totalPVs, PVCs: $totalPVCs)"
            $totalSize = [math]::Round($totalPVStorageGB, 2)
            $totalSizeTB = [math]::Round($totalPVStorageGB / 1000, 4)
            $totalSizeTiB = [math]::Round($totalPVStorageGB / 1024, 4)
        }
        
        # Only add summary row if we have resources of this type
        if ($count -gt 0) {
            $summaryRows += [PSCustomObject]@{ 
                Subscription = $Subscription
                ResourceType = $ResourceType
                Region = "All"
                Count = $count
                TotalSizeGB = $totalSize
                TotalSizeTB = $totalSizeTB
                TotalSizeTiB = $totalSizeTiB
            }
        }  
    }  
}

# Add gap after overall totals
$summaryRows += [PSCustomObject]@{ 
    Subscription = ""
    ResourceType = ""
    Region = ""
    Count = ""
    TotalSizeGB = ""
    TotalSizeTB = ""
    TotalSizeTiB = ""
}

# Add VM regional breakdown
if ($VMs.Count -and $Selected.VM) {
    # Add VM header with bracket formatting like Excel example
    
    $vmRegionalSummary = $VMs | Group-Object Region | ForEach-Object {
        $totalDiskSize = ($_.Group | Measure-Object -Property VMDiskSizeGB -Sum).Sum
        if ($totalDiskSize -eq $null) { $totalDiskSize = 0 }
        $totalDiskSizeTB = [math]::Round($totalDiskSize / 1000, 4)
        $totalDiskSizeTiB = [math]::Round($totalDiskSize / 1024, 4)
        [PSCustomObject]@{
            Subscription = "All"
            ResourceType = "VM"
            Region = $_.Name
            Count = $_.Count
            TotalSizeGB = $totalDiskSize
            TotalSizeTB = $totalDiskSizeTB
            TotalSizeTiB = $totalDiskSizeTiB
        }
    } | Sort-Object Region
    
    $summaryRows += $vmRegionalSummary
    
}

# Add Storage Account regional breakdown if selected
if ($StorageAccounts.Count -and $Selected.STORAGE) {
    # Add Storage header with bracket formatting like Excel example
    $storageRegionalSummary = $StorageAccounts | Group-Object Region | ForEach-Object {
        $totalCapacityBytes = ($_.Group | Measure-Object -Property UsedCapacityBytes -Sum).Sum
        if ($totalCapacityBytes -eq $null) { $totalCapacityBytes = 0 }
        $totalBlobCount = ($_.Group | Measure-Object -Property BlobCount -Sum).Sum
        if ($totalBlobCount -eq $null) { $totalBlobCount = 0 }
        $totalCapacityGB = [math]::round(($totalCapacityBytes / 1000000000), 2)  # Convert bytes to GB
        $totalCapacityTB = [math]::Round($totalCapacityBytes / 1000000000000, 4)  # Convert bytes to TB
        $totalCapacityTiB = [math]::Round($totalCapacityBytes / 1099511627776, 4)  # Convert bytes to TiB
        [PSCustomObject]@{
            Subscription = "All"
            ResourceType = "Storage Account (Total Blobs: $totalBlobCount)"
            Region = $_.Name
            Count = $_.Count
            TotalSizeGB = $totalCapacityGB
            TotalSizeTB = $totalCapacityTB
            TotalSizeTiB = $totalCapacityTiB
        }
    } | Sort-Object Region
    
    $summaryRows += $storageRegionalSummary  
}

# Add File Share regional breakdown if selected
if ($FileShares.Count -and $Selected.FILESHARE) {
    $fileShareRegionalSummary = $FileShares | Group-Object Region | ForEach-Object {
        $totalCapacityBytes = ($_.Group | Measure-Object -Property UsedCapacityBytes -Sum).Sum
        if ($totalCapacityBytes -eq $null) { $totalCapacityBytes = 0 }
        $totalCapacityGB = [math]::round(($totalCapacityBytes / 1000000000), 2)  # Convert bytes to GB
        $totalCapacityTB = [math]::Round($totalCapacityBytes / 1000000000000, 4)  # Convert bytes to TB
        $totalCapacityTiB = [math]::Round($totalCapacityBytes / 1099511627776, 4)  # Convert bytes to TiB
        [PSCustomObject]@{
            Subscription = "All"
            ResourceType = "File Share"
            Region = $_.Name
            Count = $_.Count
            TotalSizeGB = $totalCapacityGB
            TotalSizeTB = $totalCapacityTB
            TotalSizeTiB = $totalCapacityTiB
        }
    } | Sort-Object Region
    
    $summaryRows += $fileShareRegionalSummary  
}

# Add NetApp Files regional breakdown if selected
if ($NetAppVolumes.Count -and $Selected.NETAPP) {
    $netAppRegionalSummary = $NetAppVolumes | Group-Object Region | ForEach-Object {
        $totalCapacityBytes = ($_.Group | Measure-Object -Property UsedCapacityBytes -Sum).Sum
        if ($totalCapacityBytes -eq $null) { $totalCapacityBytes = 0 }
        $totalCapacityGB = [math]::round(($totalCapacityBytes / 1000000000), 2)  # Convert bytes to GB
        $totalCapacityTB = [math]::Round($totalCapacityBytes / 1000000000000, 4)  # Convert bytes to TB
        $totalCapacityTiB = [math]::Round($totalCapacityBytes / 1099511627776, 4)  # Convert bytes to TiB
        [PSCustomObject]@{
            Subscription = "All"
            ResourceType = "NetApp Files Volume"
            Region = $_.Name
            Count = $_.Count
            TotalSizeGB = $totalCapacityGB
            TotalSizeTB = $totalCapacityTB
            TotalSizeTiB = $totalCapacityTiB
        }
    } | Sort-Object Region
    
    $summaryRows += $netAppRegionalSummary  
}

# Add SQL Managed Instances regional breakdown if selected
if ($SqlInstancesInventory.Count -and $Selected.SQL) {
    $sqlMIRegionalSummary = $SqlInstancesInventory | Group-Object Region | ForEach-Object {
        $totalStorageUsed = ($_.Group | Measure-Object -Property StorageUsedGB -Sum).Sum
        if ($totalStorageUsed -eq $null) { $totalStorageUsed = 0 }
        $totalStorageTB = [math]::Round($totalStorageUsed / 1000, 4)
        $totalStorageTiB = [math]::Round($totalStorageUsed / 1024, 4)
        [PSCustomObject]@{
            Subscription = "All"
            ResourceType = "SQL Managed Instances"
            Region = $_.Name
            Count = $_.Count
            TotalSizeGB = [math]::Round($totalStorageUsed, 2)
            TotalSizeTB = $totalStorageTB
            TotalSizeTiB = $totalStorageTiB
        }
    } | Sort-Object Region

    $summaryRows += $sqlMIRegionalSummary
}

# Add SQL Databases regional breakdown if selected
if ($SqlDbInventory.Count -and $Selected.SQL) {
    $sqlDBRegionalSummary = $SqlDbInventory | Group-Object Region | ForEach-Object {
        $totalMaxSize = Get-CVSqlDbSizeTotal -Rows $_.Group
        if ($totalMaxSize -eq $null) { $totalMaxSize = 0 }
        $totalSizeTB = [math]::Round($totalMaxSize / 1000, 4)
        $totalSizeTiB = [math]::Round($totalMaxSize / 1024, 4)
        [PSCustomObject]@{
            Subscription = "All"
            ResourceType = "SQL Databases"
            Region = $_.Name
            Count = $_.Count
            TotalSizeGB = [math]::Round($totalMaxSize, 2)
            TotalSizeTB = $totalSizeTB
            TotalSizeTiB = $totalSizeTiB
        }
    } | Sort-Object Region

    $summaryRows += $sqlDBRegionalSummary
}

# Add CosmosDB regional breakdown if selected
if ($CosmosDBs.Count -gt 0 -and $Selected.COSMOS) {
    $cosmosRegionalSummary = $CosmosDBs | Group-Object Location | ForEach-Object {
        $totalDataUsage = 0
        foreach ($cosmos in $_.Group) {
            if ($cosmos.DataUsage -ne $null -and $cosmos.DataUsage -ne '') {
                $totalDataUsage += [double]$cosmos.DataUsage
            }
        }
        $totalStorageGB = if ($totalDataUsage -gt 0) { [math]::Round($totalDataUsage / 1000000000, 4) } else { 0 }
        $totalStorageTB = if ($totalDataUsage -gt 0) { [math]::Round($totalDataUsage / 1000000000000, 4) } else { 0 }
        $totalStorageTiB = if ($totalDataUsage -gt 0) { [math]::Round($totalDataUsage / 1099511627776, 4) } else { 0 }
        [PSCustomObject]@{
            Subscription = "All"
            ResourceType = "CosmosDB"
            Region = $_.Name
            Count = $_.Count
            TotalSizeGB = $totalStorageGB
            TotalSizeTB = $totalStorageTB
            TotalSizeTiB = $totalStorageTiB
        }
    } | Sort-Object Region

    $summaryRows += $cosmosRegionalSummary
}

# Add MySQL regional breakdown if selected
if ($MySQLServers.Count -gt 0 -and $Selected.SQL) {
    $mysqlRegionalSummary = $MySQLServers | Group-Object Location | ForEach-Object {
        $totalStorageUsedGB = 0
        foreach ($mysql in $_.Group) {
            if ($mysql.StorageUsedGB -ne $null -and $mysql.StorageUsedGB -ne '') {
                $totalStorageUsedGB += [double]$mysql.StorageUsedGB
            }
        }
        $totalStorageTB = if ($totalStorageUsedGB -gt 0) { [math]::Round($totalStorageUsedGB / 1000, 4) } else { 0 }
        $totalStorageTiB = if ($totalStorageUsedGB -gt 0) { [math]::Round($totalStorageUsedGB / 1024, 4) } else { 0 }
        [PSCustomObject]@{
            Subscription = "All"
            ResourceType = "MySQL Servers"
            Region = $_.Name
            Count = $_.Count
            TotalSizeGB = [math]::Round($totalStorageUsedGB, 4)
            TotalSizeTB = $totalStorageTB
            TotalSizeTiB = $totalStorageTiB
        }
    } | Sort-Object Region

    $summaryRows += $mysqlRegionalSummary
}

# Add PostgreSQL regional breakdown if selected
if ($PostgreSQLServers.Count -gt 0 -and $Selected.SQL) {
    $postgresRegionalSummary = $PostgreSQLServers | Group-Object Location | ForEach-Object {
        $totalStorageUsedGB = 0
        foreach ($postgres in $_.Group) {
            if ($postgres.StorageUsedGB -ne $null -and $postgres.StorageUsedGB -ne '') {
                $totalStorageUsedGB += [double]$postgres.StorageUsedGB
            }
        }
        $totalStorageTB = if ($totalStorageUsedGB -gt 0) { [math]::Round($totalStorageUsedGB / 1000, 4) } else { 0 }
        $totalStorageTiB = if ($totalStorageUsedGB -gt 0) { [math]::Round($totalStorageUsedGB / 1024, 4) } else { 0 }
        [PSCustomObject]@{
            Subscription = "All"
            ResourceType = "PostgreSQL Servers"
            Region = $_.Name
            Count = $_.Count
            TotalSizeGB = [math]::Round($totalStorageUsedGB, 4)
            TotalSizeTB = $totalStorageTB
            TotalSizeTiB = $totalStorageTiB
        }
    } | Sort-Object Region

    $summaryRows += $postgresRegionalSummary
}

# Add AKS regional breakdown if selected
if ($AKSClusters.Count -gt 0 -and $Selected.AKS) {
    $aksRegionalSummary = $AKSClusters | Group-Object Region | ForEach-Object {
        $totalPVStorageGB = 0
        $totalPVs = 0
        $totalPVCs = 0
        foreach ($aks in $_.Group) {
            if ($aks.PersistentVolumeCapacityGB -and $aks.PersistentVolumeCapacityGB -ne '' -and $null -ne $aks.PersistentVolumeCapacityGB) {
                $totalPVStorageGB += [double]$aks.PersistentVolumeCapacityGB
            }
            if ($aks.PersistentVolumeCount -and $aks.PersistentVolumeCount -ne '' -and $null -ne $aks.PersistentVolumeCount) {
                $totalPVs += [int]$aks.PersistentVolumeCount
            }
            if ($aks.PersistentVolumeClaimCount -and $aks.PersistentVolumeClaimCount -ne '' -and $null -ne $aks.PersistentVolumeClaimCount) {
                $totalPVCs += [int]$aks.PersistentVolumeClaimCount
            }
        }
        $totalStorageTB = if ($totalPVStorageGB -gt 0) { [math]::Round($totalPVStorageGB / 1000, 4) } else { 0 }
        $totalStorageTiB = if ($totalPVStorageGB -gt 0) { [math]::Round($totalPVStorageGB / 1024, 4) } else { 0 }
        [PSCustomObject]@{
            Subscription = "All"
            ResourceType = "AKS Clusters (PVs: $totalPVs, PVCs: $totalPVCs)"
            Region = $_.Name
            Count = $_.Count
            TotalSizeGB = [math]::Round($totalPVStorageGB, 4)
            TotalSizeTB = $totalStorageTB
            TotalSizeTiB = $totalStorageTiB
        }
    } | Sort-Object Region

    $summaryRows += $aksRegionalSummary
}

# Add gap after overall summary
$summaryRows += [PSCustomObject]@{ 
    ResourceType = ""
    Region = $null
    Count = $null
    TotalSizeGB = $null
    TotalSizeTB = $null
    TotalSizeTiB = $null
}

# Add subscription-level summaries header
$summaryRows += [PSCustomObject]@{ 
    Subscription = "[ Subscription level Summary ]"
    ResourceType = ""
    Region = ""
    Count = ""
    TotalSizeGB = ""
    TotalSizeTB = ""
    TotalSizeTiB = ""
}

# Loop through each subscription we already processed
foreach ($sub in $subs) {
    $subscriptionName = $sub.Name
    # Add subscription header
    $summaryRows += [PSCustomObject]@{ 
        Subscription = $subscriptionName
        ResourceType = ""
        Region = ""
        Count = ""
        TotalSizeGB = ""
        TotalSizeTB = ""
        TotalSizeTiB = ""
    }
    
    # Process VMs for this subscription
    if ($Selected.VM) {
        $subscriptionVMs = $VMs | Where-Object { $_.Subscription -eq $subscriptionName }
        if ($subscriptionVMs.Count -gt 0) {
            # Add VM resource type total for this subscription
            $totalVMDiskSize = ($subscriptionVMs | Measure-Object -Property VMDiskSizeGB -Sum).Sum
            if ($totalVMDiskSize -eq $null) { $totalVMDiskSize = 0 }
            $totalVMDiskSizeTB = [math]::Round($totalVMDiskSize / 1000, 4)
            $totalVMDiskSizeTiB = [math]::Round($totalVMDiskSize / 1024, 4)
            
            $summaryRows += [PSCustomObject]@{
                Subscription = $subscriptionName
                ResourceType = "VM"
                Region = "All"
                Count = $subscriptionVMs.Count
                TotalSizeGB = $totalVMDiskSize
                TotalSizeTB = $totalVMDiskSizeTB
                TotalSizeTiB = $totalVMDiskSizeTiB
            }
            
            # Add regional breakdown for VMs in this subscription
            $vmRegionalBreakdown = $subscriptionVMs | Group-Object Region | ForEach-Object {
                $totalDiskSize = ($_.Group | Measure-Object -Property VMDiskSizeGB -Sum).Sum
                if ($totalDiskSize -eq $null) { $totalDiskSize = 0 }
                $totalDiskSizeTB = [math]::Round($totalDiskSize / 1000, 4)
                $totalDiskSizeTiB = [math]::Round($totalDiskSize / 1024, 4)
                [PSCustomObject]@{
                    Subscription = $subscriptionName
                    ResourceType = "VM"
                    Region = $_.Name
                    Count = $_.Count
                    TotalSizeGB = $totalDiskSize
                    TotalSizeTB = $totalDiskSizeTB
                    TotalSizeTiB = $totalDiskSizeTiB
                }
            } | Sort-Object Region
            
            $summaryRows += $vmRegionalBreakdown
        }
    }
    
    # Process Storage Accounts for this subscription
    if ($Selected.STORAGE) {
        $subscriptionStorage = $StorageAccounts | Where-Object { $_.Subscription -eq $subscriptionName }
        if ($subscriptionStorage.Count -gt 0) {
            # Add Storage resource type total for this subscription
            $totalStorageCapacityBytes = ($subscriptionStorage | Measure-Object -Property UsedCapacityBytes -Sum).Sum
            if ($totalStorageCapacityBytes -eq $null) { $totalStorageCapacityBytes = 0 }
            $totalBlobCount = ($subscriptionStorage | Measure-Object -Property BlobCount -Sum).Sum
            if ($totalBlobCount -eq $null) { $totalBlobCount = 0 }
            $totalStorageCapacityGB = [math]::round(($totalStorageCapacityBytes / 1000000000), 2)
            $totalStorageCapacityTB = [math]::Round($totalStorageCapacityBytes / 1000000000000, 4)
            $totalStorageCapacityTiB = [math]::Round($totalStorageCapacityBytes / 1099511627776, 4)
            
            $summaryRows += [PSCustomObject]@{
                Subscription = $subscriptionName
                ResourceType = "Storage Account (Total Blobs: $totalBlobCount)"
                Region = "All"
                Count = $subscriptionStorage.Count
                TotalSizeGB = $totalStorageCapacityGB
                TotalSizeTB = $totalStorageCapacityTB
                TotalSizeTiB = $totalStorageCapacityTiB
            }
            
            # Add regional breakdown for Storage Accounts in this subscription
            $storageRegionalBreakdown = $subscriptionStorage | Group-Object Region | ForEach-Object {
                $totalCapacityBytes = ($_.Group | Measure-Object -Property UsedCapacityBytes -Sum).Sum
                if ($totalCapacityBytes -eq $null) { $totalCapacityBytes = 0 }
                $totalBlobCount = ($_.Group | Measure-Object -Property BlobCount -Sum).Sum
                if ($totalBlobCount -eq $null) { $totalBlobCount = 0 }
                $totalCapacityGB = [math]::round(($totalCapacityBytes / 1000000000), 2)
                $totalCapacityTB = [math]::Round($totalCapacityBytes / 1000000000000, 4)
                $totalCapacityTiB = [math]::Round($totalCapacityBytes / 1099511627776, 4)
                [PSCustomObject]@{
                    Subscription = $subscriptionName
                    ResourceType = "Storage Account (Total Blobs: $totalBlobCount)"
                    Region = $_.Name
                    Count = $_.Count
                    TotalSizeGB = $totalCapacityGB
                    TotalSizeTB = $totalCapacityTB
                    TotalSizeTiB = $totalCapacityTiB
                }
            } | Sort-Object Region
            
            $summaryRows += $storageRegionalBreakdown
        }
    }
    
    # Process File Shares for this subscription
    if ($Selected.FILESHARE) {
        $subscriptionFileShares = $FileShares | Where-Object { $_.Subscription -eq $subscriptionName }
        if ($subscriptionFileShares.Count -gt 0) {
            # Add File Share resource type total for this subscription
            $totalFileShareCapacityBytes = ($subscriptionFileShares | Measure-Object -Property UsedCapacityBytes -Sum).Sum
            if ($totalFileShareCapacityBytes -eq $null) { $totalFileShareCapacityBytes = 0 }
            $totalFileShareCapacityGB = [math]::round(($totalFileShareCapacityBytes / 1000000000), 2)
            $totalFileShareCapacityTB = [math]::Round($totalFileShareCapacityBytes / 1000000000000, 4)
            $totalFileShareCapacityTiB = [math]::Round($totalFileShareCapacityBytes / 1099511627776, 4)
            
            $summaryRows += [PSCustomObject]@{
                Subscription = $subscriptionName
                ResourceType = "File Share"
                Region = "All"
                Count = $subscriptionFileShares.Count
                TotalSizeGB = $totalFileShareCapacityGB
                TotalSizeTB = $totalFileShareCapacityTB
                TotalSizeTiB = $totalFileShareCapacityTiB
            }
            
            # Add regional breakdown for File Shares in this subscription
            $fileShareRegionalBreakdown = $subscriptionFileShares | Group-Object Region | ForEach-Object {
                $totalCapacityBytes = ($_.Group | Measure-Object -Property UsedCapacityBytes -Sum).Sum
                if ($totalCapacityBytes -eq $null) { $totalCapacityBytes = 0 }
                $totalCapacityGB = [math]::round(($totalCapacityBytes / 1000000000), 2)
                $totalCapacityTB = [math]::Round($totalCapacityBytes / 1000000000000, 4)
                $totalCapacityTiB = [math]::Round($totalCapacityBytes / 1099511627776, 4)
                [PSCustomObject]@{
                    Subscription = $subscriptionName
                    ResourceType = "File Share"
                    Region = $_.Name
                    Count = $_.Count
                    TotalSizeGB = $totalCapacityGB
                    TotalSizeTB = $totalCapacityTB
                    TotalSizeTiB = $totalCapacityTiB
                }
            } | Sort-Object Region
            
            $summaryRows += $fileShareRegionalBreakdown
        }
    }
    
    # Process NetApp Files for this subscription
    if ($Selected.NETAPP) {
        $subscriptionNetAppVolumes = $NetAppVolumes | Where-Object { $_.Subscription -eq $subscriptionName }
        if ($subscriptionNetAppVolumes.Count -gt 0) {
            # Add NetApp Files resource type total for this subscription
            $totalNetAppCapacityBytes = ($subscriptionNetAppVolumes | Measure-Object -Property UsedCapacityBytes -Sum).Sum
            if ($totalNetAppCapacityBytes -eq $null) { $totalNetAppCapacityBytes = 0 }
            $totalNetAppCapacityGB = [math]::round(($totalNetAppCapacityBytes / 1000000000), 2)
            $totalNetAppCapacityTB = [math]::Round($totalNetAppCapacityBytes / 1000000000000, 4)
            $totalNetAppCapacityTiB = [math]::Round($totalNetAppCapacityBytes / 1099511627776, 4)
            
            $summaryRows += [PSCustomObject]@{
                Subscription = $subscriptionName
                ResourceType = "NetApp Files Volume"
                Region = "All"
                Count = $subscriptionNetAppVolumes.Count
                TotalSizeGB = $totalNetAppCapacityGB
                TotalSizeTB = $totalNetAppCapacityTB
                TotalSizeTiB = $totalNetAppCapacityTiB
            }
            
            # Add regional breakdown for NetApp Files in this subscription
            $netAppRegionalBreakdown = $subscriptionNetAppVolumes | Group-Object Region | ForEach-Object {
                $totalCapacityBytes = ($_.Group | Measure-Object -Property UsedCapacityBytes -Sum).Sum
                if ($totalCapacityBytes -eq $null) { $totalCapacityBytes = 0 }
                $totalCapacityGB = [math]::round(($totalCapacityBytes / 1000000000), 2)
                $totalCapacityTB = [math]::Round($totalCapacityBytes / 1000000000000, 4)
                $totalCapacityTiB = [math]::Round($totalCapacityBytes / 1099511627776, 4)
                [PSCustomObject]@{
                    Subscription = $subscriptionName
                    ResourceType = "NetApp Files Volume"
                    Region = $_.Name
                    Count = $_.Count
                    TotalSizeGB = $totalCapacityGB
                    TotalSizeTB = $totalCapacityTB
                    TotalSizeTiB = $totalCapacityTiB
                }
            } | Sort-Object Region
            
            $summaryRows += $netAppRegionalBreakdown
        }
    }
    
    # Process SQL for this subscription
    if ($Selected.SQL) {
        # SQL Managed Instances per-subscription summary
        $subscriptionSqlMI = $SqlInstancesInventory | Where-Object { $_.Subscription -eq $subscriptionName }
        if ($subscriptionSqlMI.Count -gt 0) {
            # Add SQL Managed Instances resource type total for this subscription
            $totalMIStorageUsed = ($subscriptionSqlMI | Measure-Object -Property StorageUsedGB -Sum).Sum
            if ($totalMIStorageUsed -eq $null) { $totalMIStorageUsed = 0 }
            $totalMIStorageTB = [math]::Round($totalMIStorageUsed / 1000, 4)
            $totalMIStorageTiB = [math]::Round($totalMIStorageUsed / 1024, 4)
            
            $summaryRows += [PSCustomObject]@{
                Subscription = $subscriptionName
                ResourceType = "SQL Managed Instances"
                Region = "All"
                Count = $subscriptionSqlMI.Count
                TotalSizeGB = [math]::Round($totalMIStorageUsed, 2)
                TotalSizeTB = $totalMIStorageTB
                TotalSizeTiB = $totalMIStorageTiB
            }
            
            # Add regional breakdown for SQL Managed Instances in this subscription
            $sqlMIRegionalBreakdown = $subscriptionSqlMI | Group-Object Region | ForEach-Object {
                $totalStorageUsed = ($_.Group | Measure-Object -Property StorageUsedGB -Sum).Sum
                if ($totalStorageUsed -eq $null) { $totalStorageUsed = 0 }
                $totalStorageTB = [math]::Round($totalStorageUsed / 1000, 4)
                $totalStorageTiB = [math]::Round($totalStorageUsed / 1024, 4)
                [PSCustomObject]@{
                    Subscription = $subscriptionName
                    ResourceType = "SQL Managed Instances"
                    Region = $_.Name
                    Count = $_.Count
                    TotalSizeGB = [math]::Round($totalStorageUsed, 2)
                    TotalSizeTB = $totalStorageTB
                    TotalSizeTiB = $totalStorageTiB
                }
            } | Sort-Object Region
            
            $summaryRows += $sqlMIRegionalBreakdown
        }
        
        # SQL Databases per-subscription summary
        $subscriptionSqlDB = $SqlDbInventory | Where-Object { $_.Subscription -eq $subscriptionName }
        if ($subscriptionSqlDB.Count -gt 0) {
            # Add SQL Databases resource type total for this subscription
            $totalDBMaxSize = Get-CVSqlDbSizeTotal -Rows $subscriptionSqlDB
            if ($totalDBMaxSize -eq $null) { $totalDBMaxSize = 0 }
            $totalDBSizeTB = [math]::Round($totalDBMaxSize / 1000, 4)
            $totalDBSizeTiB = [math]::Round($totalDBMaxSize / 1024, 4)
            
            $summaryRows += [PSCustomObject]@{
                Subscription = $subscriptionName
                ResourceType = "SQL Databases"
                Region = "All"
                Count = $subscriptionSqlDB.Count
                TotalSizeGB = [math]::Round($totalDBMaxSize, 2)
                TotalSizeTB = $totalDBSizeTB
                TotalSizeTiB = $totalDBSizeTiB
            }
            
            # Add regional breakdown for SQL Databases in this subscription
            $sqlDBRegionalBreakdown = $subscriptionSqlDB | Group-Object Region | ForEach-Object {
                $totalMaxSize = Get-CVSqlDbSizeTotal -Rows $_.Group
                if ($totalMaxSize -eq $null) { $totalMaxSize = 0 }
                $totalSizeTB = [math]::Round($totalMaxSize / 1000, 4)
                $totalSizeTiB = [math]::Round($totalMaxSize / 1024, 4)
                [PSCustomObject]@{
                    Subscription = $subscriptionName
                    ResourceType = "SQL Databases"
                    Region = $_.Name
                    Count = $_.Count
                    TotalSizeGB = [math]::Round($totalMaxSize, 2)
                    TotalSizeTB = $totalSizeTB
                    TotalSizeTiB = $totalSizeTiB
                }
            } | Sort-Object Region
            
            $summaryRows += $sqlDBRegionalBreakdown
        }
    }
    
    # CosmosDB per-subscription summary
    if ($Selected.COSMOS -and $CosmosDBs.Count -gt 0) {
        $subscriptionCosmosDBs = $CosmosDBs | Where-Object { $_.Subscription -eq $subscriptionName }
        
        if ($subscriptionCosmosDBs.Count -gt 0) {
            # Calculate totals
            $totalDataUsage = 0
            foreach ($cosmos in $subscriptionCosmosDBs) {
                if ($cosmos.DataUsage -ne $null -and $cosmos.DataUsage -ne '') {
                    $totalDataUsage += [double]$cosmos.DataUsage
                }
            }
            $totalStorageGB = if ($totalDataUsage -gt 0) { [math]::Round($totalDataUsage / 1000000000, 4) } else { 0 }
            $totalStorageTB = if ($totalDataUsage -gt 0) { [math]::Round($totalDataUsage / 1000000000000, 4) } else { 0 }
            $totalStorageTiB = if ($totalDataUsage -gt 0) { [math]::Round($totalDataUsage / 1099511627776, 4) } else { 0 }
            
            $summaryRows += [PSCustomObject]@{
                Subscription = $subscriptionName
                ResourceType = "CosmosDB"
                Region = "All"
                Count = $subscriptionCosmosDBs.Count
                TotalSizeGB = $totalStorageGB
                TotalSizeTB = $totalStorageTB
                TotalSizeTiB = $totalStorageTiB
            }
            
            # Add regional breakdown for CosmosDB in this subscription
            $cosmosRegionalBreakdown = $subscriptionCosmosDBs | Group-Object Location | ForEach-Object {
                $totalDataUsage = 0
                foreach ($cosmos in $_.Group) {
                    if ($cosmos.DataUsage -ne $null -and $cosmos.DataUsage -ne '') {
                        $totalDataUsage += [double]$cosmos.DataUsage
                    }
                }
                $totalStorageGB = if ($totalDataUsage -gt 0) { [math]::Round($totalDataUsage / 1000000000, 4) } else { 0 }
                $totalStorageTB = if ($totalDataUsage -gt 0) { [math]::Round($totalDataUsage / 1000000000000, 4) } else { 0 }
                $totalStorageTiB = if ($totalDataUsage -gt 0) { [math]::Round($totalDataUsage / 1099511627776, 4) } else { 0 }
                [PSCustomObject]@{
                    Subscription = $subscriptionName
                    ResourceType = "CosmosDB"
                    Region = $_.Name
                    Count = $_.Count
                    TotalSizeGB = $totalStorageGB
                    TotalSizeTB = $totalStorageTB
                    TotalSizeTiB = $totalStorageTiB
                }
            } | Sort-Object Region
            
            $summaryRows += $cosmosRegionalBreakdown
        }
    }
    
    # MySQL per-subscription summary
    if ($Selected.SQL -and $MySQLServers.Count -gt 0) {
        $subscriptionMySQLServers = $MySQLServers | Where-Object { $_.Subscription -eq $subscriptionName }
        
        if ($subscriptionMySQLServers.Count -gt 0) {
            # Calculate totals
            $totalStorageUsedGB = 0
            foreach ($mysql in $subscriptionMySQLServers) {
                if ($mysql.StorageUsedGB -ne $null -and $mysql.StorageUsedGB -ne '') {
                    $totalStorageUsedGB += [double]$mysql.StorageUsedGB
                }
            }
            $totalStorageTB = if ($totalStorageUsedGB -gt 0) { [math]::Round($totalStorageUsedGB / 1000, 4) } else { 0 }
            $totalStorageTiB = if ($totalStorageUsedGB -gt 0) { [math]::Round($totalStorageUsedGB / 1024, 4) } else { 0 }
            
            $summaryRows += [PSCustomObject]@{
                Subscription = $subscriptionName
                ResourceType = "MySQL Servers"
                Region = "All"
                Count = $subscriptionMySQLServers.Count
                TotalSizeGB = [math]::Round($totalStorageUsedGB, 4)
                TotalSizeTB = $totalStorageTB
                TotalSizeTiB = $totalStorageTiB
            }
            
            # Add regional breakdown for MySQL in this subscription
            $mysqlRegionalBreakdown = $subscriptionMySQLServers | Group-Object Location | ForEach-Object {
                $totalStorageUsedGB = 0
                foreach ($mysql in $_.Group) {
                    if ($mysql.StorageUsedGB -ne $null -and $mysql.StorageUsedGB -ne '') {
                        $totalStorageUsedGB += [double]$mysql.StorageUsedGB
                    }
                }
                $totalStorageTB = if ($totalStorageUsedGB -gt 0) { [math]::Round($totalStorageUsedGB / 1000, 4) } else { 0 }
                $totalStorageTiB = if ($totalStorageUsedGB -gt 0) { [math]::Round($totalStorageUsedGB / 1024, 4) } else { 0 }
                [PSCustomObject]@{
                    Subscription = $subscriptionName
                    ResourceType = "MySQL Servers"
                    Region = $_.Name
                    Count = $_.Count
                    TotalSizeGB = [math]::Round($totalStorageUsedGB, 4)
                    TotalSizeTB = $totalStorageTB
                    TotalSizeTiB = $totalStorageTiB
                }
            } | Sort-Object Region
            
            $summaryRows += $mysqlRegionalBreakdown
        }
    }
    
    # PostgreSQL per-subscription summary
    if ($Selected.SQL -and $PostgreSQLServers.Count -gt 0) {
        $subscriptionPostgreSQLServers = $PostgreSQLServers | Where-Object { $_.Subscription -eq $subscriptionName }
        
        if ($subscriptionPostgreSQLServers.Count -gt 0) {
            # Calculate totals
            $totalStorageUsedGB = 0
            foreach ($postgres in $subscriptionPostgreSQLServers) {
                if ($postgres.StorageUsedGB -ne $null -and $postgres.StorageUsedGB -ne '') {
                    $totalStorageUsedGB += [double]$postgres.StorageUsedGB
                }
            }
            $totalStorageTB = if ($totalStorageUsedGB -gt 0) { [math]::Round($totalStorageUsedGB / 1000, 4) } else { 0 }
            $totalStorageTiB = if ($totalStorageUsedGB -gt 0) { [math]::Round($totalStorageUsedGB / 1024, 4) } else { 0 }
            
            $summaryRows += [PSCustomObject]@{
                Subscription = $subscriptionName
                ResourceType = "PostgreSQL Servers"
                Region = "All"
                Count = $subscriptionPostgreSQLServers.Count
                TotalSizeGB = [math]::Round($totalStorageUsedGB, 4)
                TotalSizeTB = $totalStorageTB
                TotalSizeTiB = $totalStorageTiB
            }
            
            # Add regional breakdown for PostgreSQL in this subscription
            $postgresRegionalBreakdown = $subscriptionPostgreSQLServers | Group-Object Location | ForEach-Object {
                $totalStorageUsedGB = 0
                foreach ($postgres in $_.Group) {
                    if ($postgres.StorageUsedGB -ne $null -and $postgres.StorageUsedGB -ne '') {
                        $totalStorageUsedGB += [double]$postgres.StorageUsedGB
                    }
                }
                $totalStorageTB = if ($totalStorageUsedGB -gt 0) { [math]::Round($totalStorageUsedGB / 1000, 4) } else { 0 }
                $totalStorageTiB = if ($totalStorageUsedGB -gt 0) { [math]::Round($totalStorageUsedGB / 1024, 4) } else { 0 }
                [PSCustomObject]@{
                    Subscription = $subscriptionName
                    ResourceType = "PostgreSQL Servers"
                    Region = $_.Name
                    Count = $_.Count
                    TotalSizeGB = [math]::Round($totalStorageUsedGB, 4)
                    TotalSizeTB = $totalStorageTB
                    TotalSizeTiB = $totalStorageTiB
                }
            } | Sort-Object Region
            
            $summaryRows += $postgresRegionalBreakdown
        }
    }
    
    # AKS per-subscription summary
    if ($Selected.AKS -and $AKSClusters.Count -gt 0) {
        $subscriptionAKSClusters = $AKSClusters | Where-Object { $_.Subscription -eq $subscriptionName }
        
        if ($subscriptionAKSClusters.Count -gt 0) {
            # Calculate totals
            $totalPVStorageGB = 0
            $totalPVs = 0
            $totalPVCs = 0
            foreach ($aks in $subscriptionAKSClusters) {
                if ($aks.PersistentVolumeCapacityGB -and $aks.PersistentVolumeCapacityGB -ne '' -and $null -ne $aks.PersistentVolumeCapacityGB) {
                    $totalPVStorageGB += [double]$aks.PersistentVolumeCapacityGB
                }
                if ($aks.PersistentVolumeCount -and $aks.PersistentVolumeCount -ne '' -and $null -ne $aks.PersistentVolumeCount) {
                    $totalPVs += [int]$aks.PersistentVolumeCount
                }
                if ($aks.PersistentVolumeClaimCount -and $aks.PersistentVolumeClaimCount -ne '' -and $null -ne $aks.PersistentVolumeClaimCount) {
                    $totalPVCs += [int]$aks.PersistentVolumeClaimCount
                }
            }
            $totalStorageTB = if ($totalPVStorageGB -gt 0) { [math]::Round($totalPVStorageGB / 1000, 4) } else { 0 }
            $totalStorageTiB = if ($totalPVStorageGB -gt 0) { [math]::Round($totalPVStorageGB / 1024, 4) } else { 0 }
            
            $summaryRows += [PSCustomObject]@{
                Subscription = $subscriptionName
                ResourceType = "AKS Clusters (PVs: $totalPVs, PVCs: $totalPVCs)"
                Region = "All"
                Count = $subscriptionAKSClusters.Count
                TotalSizeGB = [math]::Round($totalPVStorageGB, 4)
                TotalSizeTB = $totalStorageTB
                TotalSizeTiB = $totalStorageTiB
            }
            
            # Add regional breakdown for AKS in this subscription
            $aksRegionalBreakdown = $subscriptionAKSClusters | Group-Object Region | ForEach-Object {
                $totalPVStorageGB = 0
                $totalPVs = 0
                $totalPVCs = 0
                foreach ($aks in $_.Group) {
                    if ($aks.PersistentVolumeCapacityGB -and $aks.PersistentVolumeCapacityGB -ne '' -and $null -ne $aks.PersistentVolumeCapacityGB) {
                        $totalPVStorageGB += [double]$aks.PersistentVolumeCapacityGB
                    }
                    if ($aks.PersistentVolumeCount -and $aks.PersistentVolumeCount -ne '' -and $null -ne $aks.PersistentVolumeCount) {
                        $totalPVs += [int]$aks.PersistentVolumeCount
                    }
                    if ($aks.PersistentVolumeClaimCount -and $aks.PersistentVolumeClaimCount -ne '' -and $null -ne $aks.PersistentVolumeClaimCount) {
                        $totalPVCs += [int]$aks.PersistentVolumeClaimCount
                    }
                }
                $totalStorageTB = if ($totalPVStorageGB -gt 0) { [math]::Round($totalPVStorageGB / 1000, 4) } else { 0 }
                $totalStorageTiB = if ($totalPVStorageGB -gt 0) { [math]::Round($totalPVStorageGB / 1024, 4) } else { 0 }
                [PSCustomObject]@{
                    Subscription = $subscriptionName
                    ResourceType = "AKS Clusters (PVs: $totalPVs, PVCs: $totalPVCs)"
                    Region = $_.Name
                    Count = $_.Count
                    TotalSizeGB = [math]::Round($totalPVStorageGB, 4)
                    TotalSizeTB = $totalStorageTB
                    TotalSizeTiB = $totalStorageTiB
                }
            } | Sort-Object Region
            
            $summaryRows += $aksRegionalBreakdown
        }
    }
    
    # Backup coverage per-subscription summary
    if ($Selected.BACKUP -and $BackupItems.Count -gt 0) {
        $subBackup = $BackupItems | Where-Object { $_.Subscription -eq $subscriptionName }
        if ($subBackup.Count -gt 0) {
            $protected = ($subBackup | Where-Object { $_.ProtectionState -eq 'Protected' }).Count
            $summaryRows += [PSCustomObject]@{
                Subscription = $subscriptionName
                ResourceType = "Backup Items (Protected: $protected)"
                Region = "All"
                Count = $subBackup.Count
                TotalSizeGB = ""
                TotalSizeTB = ""
                TotalSizeTiB = ""
            }
        }
    }

    # Unmanaged disks per-subscription summary
    if ($Selected.UNMANAGEDDISKS -and $UnmanagedDiskItems.Count -gt 0) {
        $subDisks = $UnmanagedDiskItems | Where-Object { $_.Subscription -eq $subscriptionName }
        if ($subDisks.Count -gt 0) {
            $unattached = ($subDisks | Where-Object { $_.AttachedToVM -eq 'Unattached' }).Count
            $totalDiskGB = ($subDisks | Measure-Object DiskSizeGB -Sum).Sum
            $summaryRows += [PSCustomObject]@{
                Subscription = $subscriptionName
                ResourceType = "Disks (Unattached: $unattached)"
                Region = "All"
                Count = $subDisks.Count
                TotalSizeGB = [math]::Round($totalDiskGB, 2)
                TotalSizeTB = [math]::Round($totalDiskGB / 1000, 4)
                TotalSizeTiB = [math]::Round($totalDiskGB / 1024, 4)
            }
        }
    }

    # AVS per-subscription summary
    if ($Selected.AVS -and $AVSClusters.Count -gt 0) {
        $subAVS = $AVSClusters | Where-Object { $_.Subscription -eq $subscriptionName }
        if ($subAVS.Count -gt 0) {
            $totalHosts = ($subAVS | Measure-Object TotalHostCount -Sum).Sum
            $summaryRows += [PSCustomObject]@{
                Subscription = $subscriptionName
                ResourceType = "AVS Private Clouds (Total Hosts: $totalHosts)"
                Region = "All"
                Count = $subAVS.Count
                TotalSizeGB = ""
                TotalSizeTB = ""
                TotalSizeTiB = ""
            }
        }
    }

    # Add gap after each subscription
    $summaryRows += [PSCustomObject]@{ 
        Subscription = ""
        ResourceType = ""
        Region = ""
        Count = ""
        TotalSizeGB = ""
        TotalSizeTB = ""
        TotalSizeTiB = ""
    }
}


# Export summary if we have any rows (Data Protection artifact - skip entirely in a Cloud-Rewind-only run).
if ($summaryRows.Count -and -not $SkipDataProtection) {
    Write-Progress -Id 5 -Activity "Generating Output Files" -Status "Writing comprehensive summary..." -PercentComplete 75
    $summaryRows | Export-CVCsv -Path (Join-Path $outdir "azure_inventory_summary_$dateStr.csv")
    Write-Host "azure_inventory_summary_$dateStr.csv file has been written to $outdir" -ForegroundColor Cyan
}

Write-Host "`n=== All Output Files Created Successfully ===" -ForegroundColor Green

# ============================================================
# JSON EXPORT (when OutputFormat is json or both)
# ============================================================
if (($OutputFormat -eq "json" -or $OutputFormat -eq "both") -and -not $SkipDataProtection) {
    Write-Progress -Id 5 -Activity "Generating Output Files" -Status "Writing JSON output..." -PercentComplete 80

    # Build standardized summary block from $summaryRows
    $jsonSummary = @{}
    foreach ($row in $summaryRows) {
        $rt = $row.ResourceType
        if ($rt -and $rt -ne "") {
            if (-not $jsonSummary.ContainsKey($rt)) {
                $jsonSummary[$rt] = @{ count = 0; total_storage_gb = 0.0; notes = "" }
            }
            $jsonSummary[$rt].count      += [int]($row.Count -as [double])
            $jsonSummary[$rt].total_storage_gb += [double]($row.TotalSizeGB -as [double])
        }
    }

    # Collect all workload arrays
    $allWorkloads = @{}
    if ($VMs)               { $allWorkloads["azure_vms"]            = @($VMs) }
    if ($StorageAccounts)   { $allWorkloads["azure_storage"]        = @($StorageAccounts) }
    if ($FileShares)        { $allWorkloads["azure_file_shares"]    = @($FileShares) }
    if ($NetAppVolumes)     { $allWorkloads["azure_netapp"]         = @($NetAppVolumes) }
    # These names must match the collections declared at :757-775. They previously read $SQLDatabases /
    # $CosmosAccounts, which are assigned nowhere - and because each read is `if`-guarded, that failed silently:
    # azure_sql and azure_cosmos were simply absent from every JSON this script has ever written.
    if ($SqlDbInventory)         { $allWorkloads["azure_sql"]           = @($SqlDbInventory) }
    if ($SqlInstancesInventory)  { $allWorkloads["azure_sql_mi"]        = @($SqlInstancesInventory) }
    if ($SqlMIDbInventory)       { $allWorkloads["azure_sql_mi_dbs"]    = @($SqlMIDbInventory) }
    if ($MySQLServers)           { $allWorkloads["azure_mysql"]         = @($MySQLServers) }
    if ($PostgreSQLServers)      { $allWorkloads["azure_postgresql"]    = @($PostgreSQLServers) }
    if ($CosmosDBs)              { $allWorkloads["azure_cosmos"]        = @($CosmosDBs) }
    if ($AKSClusters)       { $allWorkloads["azure_aks"]            = @($AKSClusters) }
    if ($BackupItems)       { $allWorkloads["azure_backup"]         = @($BackupItems) }
    if ($UnmanagedDiskItems){ $allWorkloads["azure_disks"]          = @($UnmanagedDiskItems) }
    if ($AVSClusters)       { $allWorkloads["azure_avs"]            = @($AVSClusters) }

    $jsonDoc = @{
        metadata = @{
            cloud            = "azure"
            tenant_id        = (Get-AzContext).Tenant.Id
            subscriptions    = @($subs | ForEach-Object { $_.Id })
            generated_at     = (Get-Date -Format "o")
            script_version   = "2.0"
            env_tag_name     = $EnvTagName
            env_tag_values   = @($EnvTagValues)
        }
        summary   = $jsonSummary
        workloads = $allWorkloads
    }

    $jsonPath = Join-Path $outdir ("azure_sizing_" + $dateStr + ".json")
    $jsonDoc | ConvertTo-Json -Depth 10 -Compress:$false | Set-Content -Path $jsonPath -Encoding UTF8
    Write-Host "azure_sizing_$dateStr.json written to $outdir" -ForegroundColor Cyan
}

Write-Progress -Id 5 -Activity "Generating Output Files" -Status "Creating ZIP archive..." -PercentComplete 90

# Aggregated diagnostics summary (warning/error counts + which services/subscriptions were skipped and why).
Write-CVSummary -Title 'Azure Sizing Run Summary'
Stop-Transcript

# Zip results (always include everything in outdir — CSVs + JSON if present)
$zipfile = $runPaths.ZipPath  
Add-Type -AssemblyName System.IO.Compression.FileSystem  
[IO.Compression.ZipFile]::CreateFromDirectory($outdir, $zipfile)  

# Complete all progress indicators
Write-Progress -Id 5 -Activity "Generating Output Files" -Completed

# The per-run output folder is kept under Output/ (loose CSVs/JSON) alongside the ZIP - nothing is deleted.
  
# Show final results on console
Write-Host "`nInventory complete. Results in $zipfile`n" -ForegroundColor Green
if ($OutputFormat -eq "json" -or $OutputFormat -eq "both") {
    Write-Host "JSON sizing report (azure_sizing_$dateStr.json) is included in the ZIP for Sales AI Hub upload." -ForegroundColor Cyan
}
Write-Host "All output files have been compressed into the ZIP archive. Please provide to Commvault representative." -ForegroundColor Cyan

}
catch {
    # Test-CVConsoleReady exists precisely for this: only use the console layer if it actually initialized.
    if ((Get-Command Test-CVConsoleReady -ErrorAction SilentlyContinue) -and (Test-CVConsoleReady)) {
        Write-CVLog "Critical error in main execution" -Level Error -Source 'Main' -Exception $_
        Write-CVSummary -Title 'Azure Sizing Run Summary (aborted)'
    } else {
        Write-Host "Critical error in main execution: $_" -ForegroundColor Red
    }
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}
