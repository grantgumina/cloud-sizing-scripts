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

# ---------------------------------------------------------------------------
# Azure Resource Graph discovery (default backend). One paged Search-AzGraph query across all subscriptions
# replaces the per-subscription Get-AzResource sweep AND the per-resource Get-Az* attach calls above. The ARM
# path (Get-AzResource + Test-CVAzureCloudRewindInclude) is retained as an automatic fallback.
# ---------------------------------------------------------------------------

# Pure. Build the KQL query FROM the taxonomy (types never drift). Non-conditional types go in one `type in~ (...)`
# list; the 5 conditional types each get a guarded clause carrying the attach/exclusion rule (mirrors
# Test-CVAzureCloudRewindInclude). Returns billable AND non-billable in-taxonomy types (the summary counts both).
# `id` MUST stay in the projection or Resource Graph returns no SkipToken and paging breaks.
function Get-CVAzureCloudRewindGraphQuery {
    [CmdletBinding()]
    param([hashtable]$Taxonomy = (Get-CVAzureCloudRewindTaxonomy))

    $conditional = [ordered]@{
        'Microsoft.Compute/disks'                   = "isnotempty(managedBy) and isempty(tostring(properties.osType))"
        'Microsoft.Network/publicIPAddresses'       = "isnotempty(tostring(properties.ipConfiguration.id))"
        'Microsoft.Compute/virtualMachineScaleSets' = "tostring(properties.orchestrationMode) =~ 'Uniform'"
        'Microsoft.Sql/servers/databases'           = "name !~ 'master'"
        'Microsoft.Network/networkInterfaces'       = "isnotempty(tostring(properties.virtualMachine.id))"
    }

    $allTypes = @(@($Taxonomy.Billable) + @($Taxonomy.NonBillable))
    $uncond   = @($allTypes | Where-Object { -not $conditional.Contains($_) })

    $clauses = New-Object System.Collections.Generic.List[string]
    if ($uncond.Count) {
        $clauses.Add("type in~ (" + (($uncond | ForEach-Object { "'$_'" }) -join ', ') + ")")
    }
    foreach ($t in $conditional.Keys) {
        if ($allTypes -contains $t) { $clauses.Add("(type =~ '$t' and $($conditional[$t]))") }
    }
    $where = ($clauses -join "`n     or ")

    return @"
resources
| where $where
| project id, name, type, resourceGroup, location, subscriptionId, tenantId, tags
"@
}

# Pure. Resource Graph 'tags' is a dynamic column - PSCustomObject in current Az.ResourceGraph, IDictionary in
# older builds. Normalize to a (case-insensitive) hashtable that Test-CVResourceMatch / New-CVCloudRewindRow accept.
function ConvertTo-CVAzureGraphTagHashtable {
    param($Tags)
    $h = @{}
    if ($null -eq $Tags) { return $h }
    if ($Tags -is [System.Collections.IDictionary]) {
        foreach ($k in $Tags.Keys) { $h["$k"] = "$($Tags[$k])" }
        return $h
    }
    foreach ($p in $Tags.PSObject.Properties) { $h[$p.Name] = "$($p.Value)" }
    return $h
}

# Pure. Resource Graph stores 'type' lowercase; map it back to the taxonomy's canonical ARM casing so the CSV
# ResourceType column reads identically to the ARM backend (classifiers are case-insensitive, so this is cosmetic).
function Get-CVAzureCloudRewindCanonicalType {
    param([string]$Type, [hashtable]$Taxonomy = (Get-CVAzureCloudRewindTaxonomy))
    foreach ($t in (@($Taxonomy.Billable) + @($Taxonomy.NonBillable))) { if ($t -ieq $Type) { return $t } }
    return $Type
}

# Pure. Normalize ONE Resource Graph row into the common discovery shape consumed by the sweep.
function ConvertFrom-CVAzureGraphRow {
    param($Row, [hashtable]$NameById = @{}, [hashtable]$TenantById = @{}, [hashtable]$Taxonomy = (Get-CVAzureCloudRewindTaxonomy))
    $subId = [string]$Row.subscriptionId
    [pscustomobject]@{
        Type             = (Get-CVAzureCloudRewindCanonicalType -Type ([string]$Row.type) -Taxonomy $Taxonomy)
        Name             = [string]$Row.name
        ResourceGroup    = [string]$Row.resourceGroup
        Location         = [string]$Row.location
        SubscriptionId   = $subId
        SubscriptionName = $(if ($NameById.ContainsKey($subId))   { $NameById[$subId] }   else { $subId })
        TenantId         = $(if ($TenantById.ContainsKey($subId)) { $TenantById[$subId] } else { [string]$Row.tenantId })
        Id               = [string]$Row.id
        Tags             = (ConvertTo-CVAzureGraphTagHashtable $Row.tags)
    }
}

# Live. TENANT-AWARE paged Search-AzGraph -> normalized, already-attach-filtered discovery list. A single
# Search-AzGraph call only sees the CURRENT context's tenant, so subscriptions are grouped by TenantId and
# queried one tenant at a time (switching context per tenant), then merged. Tenants that can't be reached
# (MFA / conditional access) are skipped with a warning. The original context is restored at the end.
function Invoke-CVAzureCloudRewindGraphDiscovery {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Subs, [hashtable]$Taxonomy = (Get-CVAzureCloudRewindTaxonomy))

    $query    = Get-CVAzureCloudRewindGraphQuery -Taxonomy $Taxonomy
    # $byTenant is ORDERED so tenants are always processed in the order their subscriptions were supplied.
    # A plain @{} enumerates by hash bucket, which made the whole sweep order-dependent: whether a given tenant
    # was visited before or after the context moved decided if its resources were found at all.
    $nameById = @{}; $tenantById = @{}; $byTenant = [ordered]@{}
    foreach ($s in $Subs) {
        $sid = "$($s.Id)"; $tid = "$($s.TenantId)"
        $nameById[$sid] = $s.Name; $tenantById[$sid] = $s.TenantId
        # .Contains, not .ContainsKey - [ordered]@{} is an OrderedDictionary, which has no ContainsKey method.
        if (-not $byTenant.Contains($tid)) { $byTenant[$tid] = New-Object System.Collections.Generic.List[object] }
        $byTenant[$tid].Add($s)
    }

    $out = New-Object System.Collections.Generic.List[object]
    $origContext = $null
    try { $origContext = Get-AzContext } catch { }
    $currentTenant = ''
    if ($origContext -and $origContext.Tenant) { $currentTenant = "$($origContext.Tenant.Id)" }

    # NOTE: no try/finally around this loop and no @()/if-expressions inside it - both force the PowerShell
    # interpreter, whose array-subexpression binder throws "Argument types do not match". Use .ToArray(),
    # plain foreach (handles $null/single/array), and if-statements instead.
    foreach ($tid in $byTenant.Keys) {
        $tenantSubs = $byTenant[$tid].ToArray()
        $subIds = New-Object System.Collections.Generic.List[string]
        foreach ($ts in $tenantSubs) { $subIds.Add("$($ts.Id)") }

        # Switch context to this tenant so Search-AzGraph queries it with the right token (skip if already current).
        # $currentTenant MUST be updated after every successful switch. Leaving it pinned to the ORIGINAL context
        # means the tenant matching that original value is never switched to - and once the loop has already moved
        # the context elsewhere, its subscriptions are queried under the wrong tenant's token and Resource Graph
        # returns zero rows for them, with no error. Hashtable key order then decides which tenant silently
        # vanishes, so the same code undercounts on one run and not the next.
        if ($tid -ne $currentTenant) {
            try {
                Set-AzContext -TenantId $tid -SubscriptionId $tenantSubs[0].Id -ErrorAction Stop | Out-Null
                $currentTenant = $tid
            }
            catch {
                Write-CVLog "Cloud Rewind: cannot access tenant $tid ($($_.Exception.Message)); skipping $($tenantSubs.Count) subscription(s) there." -Level Warning -Source 'CloudRewind'
                continue
            }
        }

        $skip = $null; $guard = 0
        do {
            $p = @{ Query = $query; Subscription = $subIds.ToArray(); First = 1000 }   # -First defaults to 100 - must set 1000
            if ($skip) { $p.SkipToken = $skip }
            $page = Search-AzGraph @p
            $rows = $page
            if ($page -and $page.PSObject.Properties['Data']) { $rows = $page.Data }
            foreach ($row in $rows) {
                if ($null -eq $row) { continue }
                $out.Add((ConvertFrom-CVAzureGraphRow -Row $row -NameById $nameById -TenantById $tenantById -Taxonomy $Taxonomy))
            }
            $skip = $null
            if ($page -and $page.PSObject.Properties['SkipToken']) { $skip = $page.SkipToken }
            $guard++
            if ($guard -gt 10000) { throw 'Cloud Rewind Graph paging exceeded safety cap' }
        } while ($skip)
    }

    # Restore the original context (best-effort). On a mid-loop throw the dispatcher falls back to ARM (which resets context per subscription).
    if ($origContext) { try { Set-AzContext -Context $origContext -ErrorAction SilentlyContinue | Out-Null } catch { } }
    return $out.ToArray()
}

# Live. The original Get-AzResource + Test-CVAzureCloudRewindInclude sweep, normalized to the same discovery shape.
function Get-CVAzureCloudRewindArmDiscovery {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Subs, [hashtable]$Taxonomy = (Get-CVAzureCloudRewindTaxonomy))
    $out      = New-Object System.Collections.Generic.List[object]
    $shownErr = $false
    foreach ($sub in $Subs) {
        try { Set-AzContext -SubscriptionId $sub.Id | Out-Null }
        catch { Write-CVLog "Cloud Rewind: cannot set context for $($sub.Name): $($_.Exception.Message)" -Level Warning -Source 'CloudRewind'; continue }
        $resources = @()
        try { $resources = @(Get-AzResource) }
        catch { Write-CVLog "Cloud Rewind: Get-AzResource failed in $($sub.Name): $($_.Exception.Message)" -Level Warning -Source 'CloudRewind'; continue }
        foreach ($r in $resources) {
            if ($null -eq (Get-CVCloudRewindBillable -ResourceType $r.ResourceType -Taxonomy $Taxonomy)) { continue }
            try { if (-not (Test-CVAzureCloudRewindInclude -Resource $r)) { continue } }
            catch {
                if (-not $shownErr) { $shownErr = $true; Write-Host "[CloudRewind] inclusion check error on $($r.ResourceType): $($_.Exception.Message)" -ForegroundColor DarkYellow }
                continue
            }
            $out.Add([pscustomobject]@{
                Type = $r.ResourceType; Name = $r.Name; ResourceGroup = $r.ResourceGroupName; Location = $r.Location
                SubscriptionId = $sub.Id; SubscriptionName = $sub.Name; TenantId = $sub.TenantId; Id = $r.ResourceId; Tags = $r.Tags
            })
        }
    }
    return $out.ToArray()
}

# Live. Dispatcher: Graph (default) with automatic ARM fallback when Az.ResourceGraph is missing or Search-AzGraph throws.
function Invoke-CVAzureCloudRewindDiscovery {
    [CmdletBinding()]
    param([ValidateSet('Graph','Arm')][string]$Backend = 'Graph', [Parameter(Mandatory)]$Subs)
    $tax = Get-CVAzureCloudRewindTaxonomy
    if ($Backend -eq 'Graph') {
        $ready = $false
        try { if (-not (Get-Module Az.ResourceGraph)) { Import-Module Az.ResourceGraph -ErrorAction Stop }; $ready = $true }
        catch { Write-CVLog "Cloud Rewind: Az.ResourceGraph not available ($($_.Exception.Message)); falling back to ARM (Get-AzResource) discovery." -Level Warning -Source 'CloudRewind' }
        if ($ready) {
            try {
                $items = Invoke-CVAzureCloudRewindGraphDiscovery -Subs $Subs -Taxonomy $tax
                Write-CVLog ("Cloud Rewind: Resource Graph returned {0} in-taxonomy resource(s) across {1} subscription(s)." -f @($items).Count, @($Subs).Count) -Level Info -Source 'CloudRewind'
                return $items          # emit elements; the caller wraps with @() (do NOT ,@()-wrap - it nests)
            } catch {
                Write-CVLog "Cloud Rewind: Search-AzGraph failed ($($_.Exception.Message)); falling back to ARM (Get-AzResource) discovery." -Level Warning -Source 'CloudRewind'
            }
        }
    }
    Write-CVLog "Cloud Rewind: using ARM (Get-AzResource) discovery." -Level Info -Source 'CloudRewind'
    $armItems = Get-CVAzureCloudRewindArmDiscovery -Subs $Subs -Taxonomy $tax
    return $armItems          # emit elements; the caller wraps with @() (do NOT ,@()-wrap - it nests)
}
