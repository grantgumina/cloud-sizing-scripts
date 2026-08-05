<#
    CVSizing.CloudRewind.Azure.ps1 - Azure Cloud Rewind taxonomy + inclusion rules.

    AUTHORITATIVE: the billable / non-billable lists and the attach/exclusion logic are ported verbatim from the
    reference Cloud Rewind Azure sizer (support article 89349). Shared engine lives in CVSizing.CloudRewind.ps1.

    Classification is driven by each resource's ARM type (from Get-AzResource .ResourceType). Attach/exclusion
    checks issue targeted read-only Az calls (disk / public IP / NIC / VMSS) and require Az.Compute + Az.Network.
#>

# Billable vs non-billable native ARM types (article 89349).
function Get-CVAzureCloudRewindTaxonomy {
    [CmdletBinding()] param()
    $billable = @(
        'Microsoft.Web/sites'
        'Microsoft.Network/applicationGateways'
        'Microsoft.Network/azureFirewalls'
        'Microsoft.KeyVault/vaults'
        'Microsoft.Network/loadBalancers'
        'Microsoft.Compute/disks'                     # managed data disks only (see inclusion test)
        'Microsoft.Network/natGateways'
        'Microsoft.Network/publicIPAddresses'         # attached only
        'Microsoft.Sql/servers'
        'Microsoft.Sql/servers/databases'             # excludes the system 'master' DB
        'Microsoft.Storage/storageAccounts'
        'Microsoft.Compute/virtualMachines'
        'Microsoft.Network/virtualNetworks'
        'Microsoft.Compute/virtualMachineScaleSets'   # Uniform orchestration only
    )
    $nonBillable = @(
        'Microsoft.Web/serverfarms'
        'Microsoft.Compute/availabilitySets'
        'Microsoft.Network/networkInterfaces'         # attached only
        'Microsoft.Network/networkSecurityGroups'
        'Microsoft.Network/privateEndpoints'
        'Microsoft.Network/routeTables'
        'Microsoft.Network/virtualNetworkPeerings'
        'Microsoft.Compute/images'
        'Microsoft.Compute/virtualMachineScaleSets/virtualMachines'
    )
    return @{ Billable = $billable; NonBillable = $nonBillable }
}

# Data vs Config: Data = VM or managed data disk; everything else Config.
function Get-CVAzureCloudRewindClass {
    param([string]$ResourceType)
    if ($ResourceType -eq 'Microsoft.Compute/virtualMachines' -or $ResourceType -eq 'Microsoft.Compute/disks') { return 'Data' }
    return 'Config'
}

# Friendly category label for the CSV.
function Get-CVAzureCloudRewindCategory {
    param([string]$ResourceType)
    switch ($ResourceType) {
        'Microsoft.Compute/virtualMachines'         { 'Virtual Machine';     break }
        'Microsoft.Compute/disks'                   { 'Managed Disk';        break }
        'Microsoft.Compute/virtualMachineScaleSets' { 'VM Scale Set';        break }
        'Microsoft.Storage/storageAccounts'         { 'Storage Account';     break }
        'Microsoft.Sql/servers'                     { 'SQL Server';          break }
        'Microsoft.Sql/servers/databases'           { 'SQL Database';        break }
        'Microsoft.Web/sites'                       { 'App Service';         break }
        'Microsoft.Network/virtualNetworks'         { 'Virtual Network';     break }
        'Microsoft.Network/loadBalancers'           { 'Load Balancer';       break }
        'Microsoft.Network/applicationGateways'     { 'Application Gateway'; break }
        'Microsoft.Network/azureFirewalls'          { 'Azure Firewall';      break }
        'Microsoft.Network/natGateways'             { 'NAT Gateway';         break }
        'Microsoft.Network/publicIPAddresses'       { 'Public IP Address';   break }
        'Microsoft.KeyVault/vaults'                 { 'Key Vault';           break }
        default { ("$ResourceType" -replace '.*/', '') }
    }
}

# Reason a resource is / isn't counted (for the BillableReason column; also drives the console log). Pure.
function Get-CVAzureCloudRewindReason {
    param([string]$ResourceType)
    switch ($ResourceType) {
        'Microsoft.Compute/disks'             { 'Attached data disk';   break }
        'Microsoft.Network/publicIPAddresses' { 'Attached public IP';   break }
        'Microsoft.Compute/virtualMachineScaleSets' { 'Uniform scale set'; break }
        default { 'Billable resource type' }
    }
}

# Inclusion test - returns $true to COUNT the resource, $false to EXCLUDE it (unattached / orphaned / OS disk /
# system master DB / Flexible VMSS). Ported from the reference sizer's Test-IsAttachedResource + inline guards.
# Issues targeted read-only Az calls; the caller must have the current subscription context set.
function Test-CVAzureCloudRewindInclude {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Resource)   # a Get-AzResource item: .ResourceType, .ResourceGroupName, .Name

    $type = $Resource.ResourceType
    $rg   = $Resource.ResourceGroupName
    $name = $Resource.Name

    switch ($type) {
        'Microsoft.Sql/servers/databases' {
            # Exclude the system master DB.
            return (-not ($name -match '/master$'))
        }
        'Microsoft.Compute/virtualMachineScaleSets' {
            # Count Uniform scale sets only (Flexible excluded).
            $vmss = Get-AzVmss -ResourceGroupName $rg -VMScaleSetName $name -ErrorAction SilentlyContinue
            if ($vmss -and $vmss.OrchestrationMode -ne 'Uniform') { return $false }
            return $true
        }
        'Microsoft.Compute/disks' {
            # Data disks only, and attached only (exclude OS disks and unattached/orphaned disks).
            $disk = Get-AzDisk -ResourceGroupName $rg -DiskName $name -ErrorAction SilentlyContinue
            if ($null -eq $disk) { return $false }
            if ($disk.OsType)    { return $false }
            return ($null -ne $disk.ManagedBy)
        }
        'Microsoft.Network/publicIPAddresses' {
            $pip = Get-AzPublicIpAddress -ResourceGroupName $rg -Name $name -ErrorAction SilentlyContinue
            if ($null -eq $pip) { return $false }
            return ($null -ne $pip.IpConfiguration)
        }
        'Microsoft.Network/networkInterfaces' {
            $nic = Get-AzNetworkInterface -ResourceGroupName $rg -Name $name -ErrorAction SilentlyContinue
            if ($null -eq $nic) { return $false }
            return ($null -ne $nic.VirtualMachine)
        }
        default { return $true }
    }
}
