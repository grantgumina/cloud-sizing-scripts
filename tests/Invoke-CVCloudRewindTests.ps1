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
Assert-CV 'BillableData = 1'     $sum[0].BillableDataResources 1
Assert-CV 'BillableConfig = 1'   $sum[0].BillableConfigResources 1
Assert-CV 'NonBillableConfig = 1'$sum[0].NonBillableConfigResources 1
Assert-CV 'TotalBillable = 2'    $sum[0].TotalBillableResources 2
Assert-CV 'TotalCount = 3'       $sum[0].TotalClassifiedResources 3

# Every count column names its unit, and AccountName leads (matching the details CSV).
$sumCols = @($sum[0].PSObject.Properties.Name)
Assert-CV 'AccountName leads'    $sumCols[0] 'AccountName'
Assert-CV 'Account second'       $sumCols[1] 'Account'
foreach ($c in $sumCols | Where-Object { $_ -notin 'AccountName','Account' }) {
    Assert-CV "$c names its unit" ($c -like '*Resources') $true
}
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

function CountOf { param([string]$Haystack, [string]$Needle) ([regex]::Matches($Haystack, [regex]::Escape($Needle))).Count }

Write-Host "`n[13] Azure Resource Graph KQL builder"
$kql  = Get-CVAzureCloudRewindGraphQuery
$aztx = Get-CVAzureCloudRewindTaxonomy
# Every taxonomy type is present (types can never silently drop out of the query).
foreach ($t in (@($aztx.Billable) + @($aztx.NonBillable))) { Assert-CV "kql has $t" ($kql.Contains($t)) $true }
# Each attach/exclusion predicate is present.
Assert-CV 'disk predicate'  ($kql.Contains("isnotempty(managedBy) and isempty(tostring(properties.osType))")) $true
Assert-CV 'pip predicate'   ($kql.Contains("isnotempty(tostring(properties.ipConfiguration.id))")) $true
Assert-CV 'vmss predicate'  ($kql.Contains("tostring(properties.orchestrationMode) =~ 'Uniform'")) $true
Assert-CV 'sqldb predicate' ($kql.Contains("name !~ 'master'")) $true
Assert-CV 'nic predicate'   ($kql.Contains("isnotempty(tostring(properties.virtualMachine.id))")) $true
# Paging contract: query targets the resources table and projects id.
Assert-CV 'targets resources' ($kql.TrimStart().StartsWith('resources')) $true
Assert-CV 'projects id'       ($kql.Contains('| project id')) $true
# GUARD (the important regression test): each conditional type appears EXACTLY ONCE - inside its guarded clause,
# never also in the unconditional in~ list (a leak there would count unattached disks/IPs/NICs and the master DB).
foreach ($ct in @('Microsoft.Compute/disks','Microsoft.Network/publicIPAddresses','Microsoft.Compute/virtualMachineScaleSets','Microsoft.Sql/servers/databases','Microsoft.Network/networkInterfaces')) {
    Assert-CV "$ct appears once (guarded)" (CountOf $kql "'$ct'") 1
    Assert-CV "$ct is guarded"             ($kql.Contains("type =~ '$ct' and")) $true
}

Write-Host "`n[14] ARG row normalization (pure)"
$nameById = @{ 'sub1' = 'Sub One' }; $tenantById = @{ 'sub1' = 'ten1' }
$argRow = [pscustomobject]@{ id='/r'; name='vm1'; type='microsoft.compute/virtualmachines'; resourceGroup='rg1'; location='eastus'; subscriptionId='sub1'; tenantId='rawten'; tags=[pscustomobject]@{ Env='Prod' } }
$n = ConvertFrom-CVAzureGraphRow -Row $argRow -NameById $nameById -TenantById $tenantById
Assert-CV 'type canonicalized'    $n.Type 'Microsoft.Compute/virtualMachines'
Assert-CV 'sub name mapped'       $n.SubscriptionName 'Sub One'
Assert-CV 'tenant mapped'         $n.TenantId 'ten1'
Assert-CV 'tags -> IDictionary'   ($n.Tags -is [System.Collections.IDictionary]) $true
Assert-CV 'tag value'             (Get-CVTagValue -Tags $n.Tags -Key 'Env') 'Prod'
Assert-CV 'canonical type miss'   (Get-CVAzureCloudRewindCanonicalType 'foo/bar') 'foo/bar'
Assert-CV 'null tags -> empty'    ((ConvertTo-CVAzureGraphTagHashtable $null).Count) 0
Assert-CV 'idict tags preserved'  ((ConvertTo-CVAzureGraphTagHashtable @{ A='1' })['A']) '1'

Write-Host "`n[15] Discovery dispatcher (ARM path) returns a FLAT normalized array (not nested)"
function Write-CVLog { param($Message, $Level, $Source) }            # no-op stub (console layer not loaded in tests)
function Set-AzContext { param($SubscriptionId) }                    # no-op
function Get-AzResource {
    @(
        [pscustomobject]@{ ResourceType='Microsoft.Compute/virtualMachines'; Name='vm1'; ResourceGroupName='rg1'; Location='eastus'; ResourceId='/id1'; Tags=@{ Env='Prod' } }
        [pscustomobject]@{ ResourceType='Microsoft.Storage/storageAccounts'; Name='sa1'; ResourceGroupName='rg2'; Location='westus'; ResourceId='/id2'; Tags=@{} }
        [pscustomobject]@{ ResourceType='Microsoft.Foo/bar';                  Name='x';   ResourceGroupName='rg3'; Location='eastus'; ResourceId='/id3'; Tags=@{} }  # not in taxonomy -> dropped
    )
}
$dispSubs = @([pscustomobject]@{ Id='sub1'; Name='Sub One'; TenantId='ten1' })
$disc = @(Invoke-CVAzureCloudRewindDiscovery -Backend Arm -Subs $dispSubs)
Assert-CV 'dispatcher returns 2 (foo dropped)' $disc.Count 2
Assert-CV 'element is NOT a nested array'      ($disc[0] -is [System.Array]) $false
Assert-CV 'ResourceGroup is a plain string'    ($disc[0].ResourceGroup -is [string]) $true
Assert-CV 'SubscriptionName mapped'            $disc[0].SubscriptionName 'Sub One'
Assert-CV 'Type preserved'                     $disc[0].Type 'Microsoft.Compute/virtualMachines'

Write-Host "`n[16] Tenant-aware Graph discovery (multi-tenant coverage + context switching)"
# Context starts on tenantB; subs span tenantA (2) + tenantB (1).
#
# The Search-AzGraph stub is deliberately CONTEXT-AWARE: it returns rows only for subscriptions belonging to the
# tenant the context is currently on, exactly like the real cmdlet (one Graph query only ever sees the current
# context's tenant). A context-blind stub cannot catch the bug this test exists for - a $currentTenant left
# pinned to the ORIGINAL context means the loop never switches back to that tenant after moving away, and its
# subscriptions silently return zero rows. Whichever tenant that is depends on hashtable key order, so the
# real-world symptom was an undercount that came and went between runs with no code change.
$script:SetCtxTenants  = @()
$script:CtxTenant      = 'tenantB'
$script:MtTenantOfSub  = @{ subA1 = 'tenantA'; subA2 = 'tenantA'; subB1 = 'tenantB' }
function Get-AzContext { [pscustomobject]@{ Tenant = [pscustomobject]@{ Id = $script:CtxTenant }; Subscription = [pscustomobject]@{ Id = 'subB1' } } }
function Set-AzContext { param($TenantId, $SubscriptionId, $Context, $ErrorAction) if ($TenantId) { $script:SetCtxTenants += "$TenantId"; $script:CtxTenant = "$TenantId" } }
function Search-AzGraph { param($Query, $Subscription, $First, $SkipToken)
    @($Subscription | Where-Object { $script:MtTenantOfSub["$_"] -eq $script:CtxTenant } | ForEach-Object { [pscustomobject]@{ id="/subs/$_/vm"; name="vm-$_"; type='microsoft.compute/virtualmachines'; resourceGroup='rg'; location='eastus'; subscriptionId=$_; tenantId='t'; tags=$null } }) }
$mtSubs = @(
    [pscustomobject]@{ Id='subA1'; Name='A1'; TenantId='tenantA' }
    [pscustomobject]@{ Id='subA2'; Name='A2'; TenantId='tenantA' }
    [pscustomobject]@{ Id='subB1'; Name='B1'; TenantId='tenantB' }
)
$g = @(Invoke-CVAzureCloudRewindGraphDiscovery -Subs $mtSubs)
Assert-CV 'covers all 3 subs across 2 tenants' $g.Count 3
Assert-CV 'switched context to tenantA'        ($script:SetCtxTenants -contains 'tenantA') $true
Assert-CV 'subA2 present (2nd sub of tenantA)'  ([bool](@($g | Where-Object { $_.Name -eq 'vm-subA2' }).Count)) $true
# The regression guard: tenantB is the STARTING context, so it is the tenant a stale $currentTenant strands.
Assert-CV 'subB1 present (starting tenant)'     ([bool](@($g | Where-Object { $_.Name -eq 'vm-subB1' }).Count)) $true

Write-Host ("`n{0}  {1} passed, {2} failed  {0}" -f ('=' * 6), $script:Pass, $script:Fail) -ForegroundColor ($script:Fail ? 'Red' : 'Green')
exit ($script:Fail -gt 0 ? 1 : 0)
