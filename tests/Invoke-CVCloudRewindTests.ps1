#requires -Version 7.2
<#  Dependency-free tests for the Cloud Rewind engine + Azure taxonomy
    (src/common/CVSizing.CloudRewind.ps1 and CVSizing.CloudRewind.Azure.ps1).

    The attach/exclusion branches of Test-CVAzureCloudRewindInclude call Az cmdlets; small stub functions below
    shadow them so the logic is exercised deterministically without the Az modules installed. #>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.CloudRewind.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.CloudRewind.Azure.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.CloudRewind.AWS.ps1')
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.CloudRewind.GCP.ps1')

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }

function NewRes { param($Type, $Name, $Rg = 'rg1') [pscustomobject]@{ ResourceType = $Type; Name = $Name; ResourceGroupName = $Rg } }

# --- Az stubs (shadow the real cmdlets; key off the resource name) ---
function Get-AzDisk { param($ResourceGroupName, $DiskName, $ErrorAction)
    switch -Wildcard ($DiskName) {
        '*osdisk*'         { return [pscustomobject]@{ OsType = 'Linux'; ManagedBy = '/vm1' } }
        '*unattacheddisk*' { return [pscustomobject]@{ OsType = $null;   ManagedBy = $null } }
        '*missingdisk*'    { return $null }
        default            { return [pscustomobject]@{ OsType = $null;   ManagedBy = '/vm1' } } } }
function Get-AzPublicIpAddress { param($ResourceGroupName, $Name, $ErrorAction)
    switch -Wildcard ($Name) {
        '*unattached*' { return [pscustomobject]@{ IpConfiguration = $null } }
        '*missing*'    { return $null }
        default        { return [pscustomobject]@{ IpConfiguration = [pscustomobject]@{ Id = '/ipcfg' } } } } }
function Get-AzNetworkInterface { param($ResourceGroupName, $Name, $ErrorAction)
    switch -Wildcard ($Name) {
        '*unattached*' { return [pscustomobject]@{ VirtualMachine = $null } }
        '*missing*'    { return $null }
        default        { return [pscustomobject]@{ VirtualMachine = [pscustomobject]@{ Id = '/vm1' } } } } }
function Get-AzVmss { param($ResourceGroupName, $VMScaleSetName, $ErrorAction)
    switch -Wildcard ($VMScaleSetName) {
        '*flexible*' { return [pscustomobject]@{ OrchestrationMode = 'Flexible' } }
        '*missing*'  { return $null }
        default      { return [pscustomobject]@{ OrchestrationMode = 'Uniform' } } } }

$tax = Get-CVAzureCloudRewindTaxonomy

Write-Host "`n[1] Billable classification (in/out of taxonomy)"
Assert-CV 'VM is billable'            (Get-CVCloudRewindBillable -ResourceType 'Microsoft.Compute/virtualMachines' -Taxonomy $tax) $true
Assert-CV 'serverfarm non-billable'   (Get-CVCloudRewindBillable -ResourceType 'Microsoft.Web/serverfarms'         -Taxonomy $tax) $false
Assert-CV 'unlisted type -> null'     ($null -eq (Get-CVCloudRewindBillable -ResourceType 'Microsoft.Foo/bar'      -Taxonomy $tax)) $true

Write-Host "`n[2] Data vs Config class"
Assert-CV 'VM   -> Data'    (Get-CVAzureCloudRewindClass 'Microsoft.Compute/virtualMachines') 'Data'
Assert-CV 'disk -> Data'    (Get-CVAzureCloudRewindClass 'Microsoft.Compute/disks')           'Data'
Assert-CV 'storage-> Config'(Get-CVAzureCloudRewindClass 'Microsoft.Storage/storageAccounts') 'Config'
Assert-CV 'LB    -> Config' (Get-CVAzureCloudRewindClass 'Microsoft.Network/loadBalancers')   'Config'

Write-Host "`n[3] Category + reason labels"
Assert-CV 'VM category'       (Get-CVAzureCloudRewindCategory 'Microsoft.Compute/virtualMachines') 'Virtual Machine'
Assert-CV 'unknown -> leaf'   (Get-CVAzureCloudRewindCategory 'Microsoft.Foo/bar')                 'bar'
Assert-CV 'disk reason'       (Get-CVAzureCloudRewindReason   'Microsoft.Compute/disks')           'Attached data disk'
Assert-CV 'pip reason'        (Get-CVAzureCloudRewindReason   'Microsoft.Network/publicIPAddresses') 'Attached public IP'

Write-Host "`n[4] Inclusion - pure branches (master DB, default)"
Assert-CV 'SQL master excluded' (Test-CVAzureCloudRewindInclude -Resource (NewRes 'Microsoft.Sql/servers/databases' 'srv/master')) $false
Assert-CV 'SQL app db included'  (Test-CVAzureCloudRewindInclude -Resource (NewRes 'Microsoft.Sql/servers/databases' 'srv/appdb'))  $true
Assert-CV 'storage default true' (Test-CVAzureCloudRewindInclude -Resource (NewRes 'Microsoft.Storage/storageAccounts' 'sa1'))      $true

Write-Host "`n[5] Inclusion - attach/exclusion via Az stubs"
Assert-CV 'attached data disk'   (Test-CVAzureCloudRewindInclude -Resource (NewRes 'Microsoft.Compute/disks' 'datadisk1'))       $true
Assert-CV 'OS disk excluded'     (Test-CVAzureCloudRewindInclude -Resource (NewRes 'Microsoft.Compute/disks' 'osdisk1'))         $false
Assert-CV 'unattached disk excl' (Test-CVAzureCloudRewindInclude -Resource (NewRes 'Microsoft.Compute/disks' 'unattacheddisk1')) $false
Assert-CV 'missing disk excl'    (Test-CVAzureCloudRewindInclude -Resource (NewRes 'Microsoft.Compute/disks' 'missingdisk1'))    $false
Assert-CV 'attached PIP'         (Test-CVAzureCloudRewindInclude -Resource (NewRes 'Microsoft.Network/publicIPAddresses' 'pip1'))          $true
Assert-CV 'unattached PIP excl'  (Test-CVAzureCloudRewindInclude -Resource (NewRes 'Microsoft.Network/publicIPAddresses' 'unattachedpip')) $false
Assert-CV 'attached NIC'         (Test-CVAzureCloudRewindInclude -Resource (NewRes 'Microsoft.Network/networkInterfaces' 'nic1'))          $true
Assert-CV 'unattached NIC excl'  (Test-CVAzureCloudRewindInclude -Resource (NewRes 'Microsoft.Network/networkInterfaces' 'unattachednic')) $false
Assert-CV 'uniform VMSS'         (Test-CVAzureCloudRewindInclude -Resource (NewRes 'Microsoft.Compute/virtualMachineScaleSets' 'vmss1'))        $true
Assert-CV 'flexible VMSS excl'   (Test-CVAzureCloudRewindInclude -Resource (NewRes 'Microsoft.Compute/virtualMachineScaleSets' 'flexiblevmss')) $false

Write-Host "`n[6] Run-wide filter predicate (union semantics)"
$tg = @{ Environment = 'Production'; App = 'Billing' }
Assert-CV 'no filter -> include'   (Test-CVResourceMatch -ResourceGroup 'rgA' -Tags $tg) $true
Assert-CV 'RG match'               (Test-CVResourceMatch -ResourceGroup 'rgA' -Tags $tg -FilterResourceGroups @('rgA','rgB')) $true
Assert-CV 'RG no match'            (Test-CVResourceMatch -ResourceGroup 'rgZ' -Tags $tg -FilterResourceGroups @('rgA','rgB')) $false
Assert-CV 'tag match (ci value)'   (Test-CVResourceMatch -ResourceGroup 'rgZ' -Tags $tg -FilterTags @('Environment=production')) $true
Assert-CV 'tag no match'           (Test-CVResourceMatch -ResourceGroup 'rgZ' -Tags $tg -FilterTags @('Environment=Dev')) $false
Assert-CV 'union: RG hits'         (Test-CVResourceMatch -ResourceGroup 'rgA' -Tags $tg -FilterResourceGroups @('rgA') -FilterTags @('Environment=Dev')) $true
Assert-CV 'union: tag hits'        (Test-CVResourceMatch -ResourceGroup 'rgZ' -Tags $tg -FilterResourceGroups @('rgA') -FilterTags @('App=Billing')) $true
Assert-CV 'union: neither hits'    (Test-CVResourceMatch -ResourceGroup 'rgZ' -Tags $tg -FilterResourceGroups @('rgA') -FilterTags @('App=Other')) $false

Write-Host "`n[7] Filter tag key extraction (distinct)"
Assert-CV 'keys deduped' ((Get-CVFilterTagKeys -FilterTags @('Env=Prod','App=Bill','Env=Dev')) -join ',') 'Env,App'

Write-Host "`n[8] Tag helpers"
Assert-CV 'tag string sorted' (ConvertTo-CVTagString @{ b = '2'; a = '1' }) 'a=1; b=2'
Assert-CV 'tag value hit'     (Get-CVTagValue -Tags @{ Environment = 'Prod' } -Key 'Environment') 'Prod'
Assert-CV 'tag value miss'    (Get-CVTagValue -Tags @{ Environment = 'Prod' } -Key 'Missing') ''

Write-Host "`n[9] Row builder (stable columns + filter tag columns)"
$row = New-CVCloudRewindRow -Fields @{
    CloudProvider='Azure'; Account='sub1'; AccountName='Sub One'; TenantOrOrg='ten1'; Region='eastus'
    ResourceGroup='rg1'; ResourceName='vm1'; ResourceId='/id'; ResourceType='Microsoft.Compute/virtualMachines'
    ResourceState=''; BillableReason='Billable resource type'
    VpcOrVNet=''; Subnet=''; AvailabilityZone=''; HasPublicIp=''; DiscoveredAt='2026-08-04_120000'
} -Tags @{ Environment='Prod' } -FilterTagKeys @('Environment')
$cols = @($row.PSObject.Properties.Name)
Assert-CV 'first column CloudProvider' $cols[0] 'CloudProvider'
Assert-CV 'Billable = Yes'             $row.Billable 'Yes'
Assert-CV 'ResourceType renamed'       $row.ResourceType 'Microsoft.Compute/virtualMachines'
Assert-CV 'filter tag column present'  ($cols -contains 'Tag_Environment') $true
Assert-CV 'filter tag column value'    $row.'Tag_Environment' 'Prod'

# Readability contract: the wide columns sit at the far right, and the dropped columns stay dropped.
Assert-CV 'Tags is last column'        $cols[-1] 'Tags'
Assert-CV 'Tag_<key> just before Tags' $cols[-2] 'Tag_Environment'
Assert-CV 'ResourceId near the end'    $cols[-3] 'ResourceId'
foreach ($dropped in 'RunId','ResourceClass','CloudRewindCategory','NativeResourceType') {
    Assert-CV "$dropped column removed" ($cols -contains $dropped) $false
}

# Without a -Tags filter there are no Tag_<key> columns, but Tags must still be last.
$rowNoFilter = New-CVCloudRewindRow -Fields @{ CloudProvider='Azure'; ResourceName='vm1' } -Tags @{ Environment='Prod' }
Assert-CV 'Tags last without filter' (@($rowNoFilter.PSObject.Properties.Name))[-1] 'Tags'

Write-Host "`n[10] Summary rollup (billable/non-billable x Data/Config)"
$classified = @(
    [pscustomobject]@{ Account='sub1'; AccountName='Sub One'; Billable=$true;  ResourceClass='Data'   }
    [pscustomobject]@{ Account='sub1'; AccountName='Sub One'; Billable=$true;  ResourceClass='Config' }
    [pscustomobject]@{ Account='sub1'; AccountName='Sub One'; Billable=$false; ResourceClass='Config' }
)
$sum = @(Get-CVCloudRewindSummary -Classified $classified)
Assert-CV 'one account row'      $sum.Count 1
Assert-CV 'BillableData = 1'     $sum[0].BillableData 1
Assert-CV 'BillableConfig = 1'   $sum[0].BillableConfig 1
Assert-CV 'NonBillableConfig = 1'$sum[0].NonBillableConfig 1
Assert-CV 'TotalBillable = 2'    $sum[0].TotalBillable 2
Assert-CV 'TotalCount = 3'       $sum[0].TotalCount 3
Assert-CV 'empty -> no rows'     (@(Get-CVCloudRewindSummary -Classified @()).Count) 0

Write-Host "`n[11] AWS - ARN token parsing + classification (derived taxonomy)"
$awsTax = Get-CVAwsCloudRewindTaxonomy
Assert-CV 'arn ec2 instance'  (Get-CVAwsArnType 'arn:aws:ec2:us-east-1:123456789012:instance/i-abc') 'ec2:instance'
Assert-CV 'arn rds db'        (Get-CVAwsArnType 'arn:aws:rds:us-east-1:123:db:mydb') 'rds:db'
Assert-CV 'arn elb'           (Get-CVAwsArnType 'arn:aws:elasticloadbalancing:us-east-1:123:loadbalancer/app/my-lb/50dc') 'elasticloadbalancing:loadbalancer'
Assert-CV 'arn sqs (bare id)' (Get-CVAwsArnType 'arn:aws:sqs:us-east-1:123:myqueue') 'sqs:myqueue'
Assert-CV 'arn empty'         (Get-CVAwsArnType '') ''
Assert-CV 'EC2 billable'      (Get-CVAwsCloudRewindBillable 'arn:aws:ec2:us-east-1:123:instance/i-abc' $awsTax) $true
Assert-CV 'subnet non-bill'   (Get-CVAwsCloudRewindBillable 'arn:aws:ec2:us-east-1:123:subnet/subnet-abc' $awsTax) $false
Assert-CV 'sqs svc fallback'  (Get-CVAwsCloudRewindBillable 'arn:aws:sqs:us-east-1:123:myqueue' $awsTax) $false
Assert-CV 's3 not in taxonomy'($null -eq (Get-CVAwsCloudRewindBillable 'arn:aws:s3:::mybucket' $awsTax)) $true
Assert-CV 'EC2 -> Data'       (Get-CVAwsCloudRewindClass 'ec2:instance') 'Data'
Assert-CV 'EBS -> Data'       (Get-CVAwsCloudRewindClass 'ec2:volume') 'Data'
Assert-CV 'RDS -> Config'     (Get-CVAwsCloudRewindClass 'rds:db') 'Config'
Assert-CV 'EC2 category'      (Get-CVAwsCloudRewindCategory 'ec2:instance') 'EC2 Instance'

Write-Host "`n[12] GCP - asset-type classification (derived taxonomy, via shared engine)"
$gcpTax = Get-CVGcpCloudRewindTaxonomy
Assert-CV 'instance billable' (Get-CVCloudRewindBillable -ResourceType 'compute.googleapis.com/Instance' -Taxonomy $gcpTax) $true
Assert-CV 'subnet non-bill'   (Get-CVCloudRewindBillable -ResourceType 'compute.googleapis.com/Subnetwork' -Taxonomy $gcpTax) $false
Assert-CV 'unknown -> null'   ($null -eq (Get-CVCloudRewindBillable -ResourceType 'foo.googleapis.com/Bar' -Taxonomy $gcpTax)) $true
Assert-CV 'instance -> Data'  (Get-CVGcpCloudRewindClass 'compute.googleapis.com/Instance') 'Data'
Assert-CV 'network -> Config' (Get-CVGcpCloudRewindClass 'compute.googleapis.com/Network') 'Config'
Assert-CV 'asset types = 18'  (@(Get-CVGcpCloudRewindAssetTypes).Count) 18
Assert-CV 'GCP category'      (Get-CVGcpCloudRewindCategory 'compute.googleapis.com/Instance') 'Compute Engine Instance'

Write-Host ("`n{0}  {1} passed, {2} failed  {0}" -f ('=' * 6), $script:Pass, $script:Fail) -ForegroundColor ($script:Fail ? 'Red' : 'Green')
exit ($script:Fail -gt 0 ? 1 : 0)
