<#
    CVSizing.CloudRewind.ps1 - Cloud-agnostic Cloud Rewind sizing engine.

    Cloud Rewind (Appranix) bills for only SOME cloud resources. This engine is provider-neutral: each cloud
    script supplies its OWN taxonomy (billable / non-billable native resource-type lists) and its own
    attach/exclusion tests, then this layer classifies, builds the per-resource CSV rows, and rolls up the
    billable-vs-non-billable summary. Mirrors the CVSizing.Resilience.* split (engine here, per-cloud files
    alongside: CVSizing.CloudRewind.Azure.ps1 / .AWS.ps1 / .GCP.ps1).

    Model (from the reference Azure sizer / support article 89349):
      - Each resource is BILLABLE, NON-BILLABLE, or neither (not in the taxonomy -> ignored, never counted).
      - Independently, each is DATA or CONFIG (Data = compute instance or attached data disk; else Config).
      - The per-resource CSV lists BILLABLE resources only; the summary CSV keeps the full
        Billable/NonBillable x Data/Config breakdown per account, as resource counts.
#>

#region ---------------------------------------------------------------- Run-wide resource filter

# Shared by the DP service loops and the CR sweep. Union semantics: when BOTH a resource-group filter and a
# tag filter are supplied, a resource matches if it is in ANY listed resource group OR carries ANY listed
# Key=Value tag ("...with those tags OR in those resource groups"). Empty filters -> everything matches.
function Test-CVResourceMatch {
    [CmdletBinding()]
    param(
        [string]$ResourceGroup,
        $Tags,                              # the resource's tags (IDictionary) or $null
        [string[]]$FilterResourceGroups = @(),
        [string[]]$FilterTags = @()         # each entry "Key=Value"
    )
    $rgSet  = @($FilterResourceGroups | Where-Object { $_ -and "$_".Trim() })
    $tagSet = @($FilterTags          | Where-Object { $_ -and "$_".Trim() })
    if (-not $rgSet.Count -and -not $tagSet.Count) { return $true }

    $rgMatch = $false
    if ($rgSet.Count -and $ResourceGroup) {
        $rgMatch = [bool](@($rgSet | Where-Object { $_.Trim() -ieq "$ResourceGroup".Trim() }).Count)
    }

    $tagMatch = $false
    if ($tagSet.Count -and $Tags -is [System.Collections.IDictionary]) {
        foreach ($ft in $tagSet) {
            $parts = "$ft" -split '=', 2
            if ($parts.Count -lt 2) { continue }
            $k = $parts[0].Trim(); $v = $parts[1].Trim()
            $rv = $Tags[$k]
            if ($null -ne $rv -and ("$rv".Trim() -ieq $v)) { $tagMatch = $true; break }
        }
    }

    if ($rgSet.Count -and $tagSet.Count) { return ($rgMatch -or $tagMatch) }
    if ($rgSet.Count) { return $rgMatch }
    return $tagMatch
}

# Extract the distinct tag keys referenced by a -Tags filter (["Env=Prod","App=Bill"] -> ["Env","App"]).
# These become stable Tag_<key> columns on every CR row.
function Get-CVFilterTagKeys {
    [CmdletBinding()] param([string[]]$FilterTags = @())
    @($FilterTags | ForEach-Object { ("$_" -split '=', 2)[0].Trim() } | Where-Object { $_ } | Select-Object -Unique)
}

#endregion

#region ---------------------------------------------------------------- Classification helpers

# Billable ($true), non-billable ($false), or not-in-taxonomy ($null -> ignored).
function Get-CVCloudRewindBillable {
    [CmdletBinding()]
    param([string]$ResourceType, [Parameter(Mandatory)]$Taxonomy)
    if (@($Taxonomy.Billable)    -contains $ResourceType) { return $true }
    if (@($Taxonomy.NonBillable) -contains $ResourceType) { return $false }
    return $null
}

function ConvertTo-CVTagString {
    param($Tags)
    if (-not $Tags) { return '' }
    if ($Tags -is [System.Collections.IDictionary]) {
        return (($Tags.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ')
    }
    return "$Tags"
}

function Get-CVTagValue {
    param($Tags, [string]$Key)
    if ($Tags -is [System.Collections.IDictionary]) {
        $v = $Tags[$Key]
        if ($null -ne $v) { return "$v" }
    }
    return ''
}

#endregion

#region ---------------------------------------------------------------- Row builder

# Canonical Cloud Rewind CSV row (one billable resource). $Fields carries the provider-normalized values;
# this enforces a stable column order across all three clouds.
#
# Column order is tuned for reading the CSV in a spreadsheet: scope (account -> region -> resource group), then
# the resource and its billing verdict, then topology. The two widest columns - ResourceId and the flattened
# Tags blob - are pushed to the far right so they never push the useful columns off-screen; Tag_<key> columns
# (one per key referenced by the -Tags filter) sit just before Tags.
#
# Data/Config classification is NOT a column here - it drives the summary CSV's Billable/NonBillable x
# Data/Config rollup instead (see Get-CVCloudRewindSummary), where the split is actually actionable.
function New-CVCloudRewindRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Fields,
        $Tags,
        [string[]]$FilterTagKeys = @()
    )
    $row = [ordered]@{
        CloudProvider    = $Fields.CloudProvider
        AccountName      = $Fields.AccountName
        Account          = $Fields.Account
        TenantOrOrg      = $Fields.TenantOrOrg
        Region           = $Fields.Region
        ResourceGroup    = $Fields.ResourceGroup
        ResourceName     = $Fields.ResourceName
        ResourceType     = $Fields.ResourceType
        ResourceState    = $Fields.ResourceState
        Billable         = 'Yes'
        BillableReason   = $Fields.BillableReason
        VpcOrVNet        = $Fields.VpcOrVNet
        Subnet           = $Fields.Subnet
        AvailabilityZone = $Fields.AvailabilityZone
        HasPublicIp      = $Fields.HasPublicIp
        DiscoveredAt     = $Fields.DiscoveredAt
        ResourceId       = $Fields.ResourceId
    }
    foreach ($k in @($FilterTagKeys)) { if ($k) { $row["Tag_$k"] = (Get-CVTagValue -Tags $Tags -Key $k) } }
    $row.Tags = (ConvertTo-CVTagString $Tags)
    return [pscustomobject]$row
}

#endregion

#region ---------------------------------------------------------------- Summary

# Roll classified resources (billable AND non-billable, in-taxonomy only) into the per-account breakdown.
# Each input item: { Account; AccountName; Billable([bool]); ResourceClass('Data'|'Config') }.
#
# Every numeric column counts RESOURCES, never bytes - hence the ...Resources suffix. These summaries sit next
# to per-service CSVs full of SizeGB/UsedTiB columns, and a bare "BillableData = 12" reads as 12 GB of data
# rather than 12 resources. Naming the unit in the header is the cheapest fix.
#
# TotalClassifiedResources counts only resources that matched the billable OR non-billable taxonomy: anything
# in neither list is discarded before it reaches here, as are resources dropped by the per-cloud inclusion
# tests (unattached disks/IPs, OS disks, the system master DB, Flexible VMSS). It is therefore NOT the account's
# total resource count, and "Classified" is in the name to stop it being read that way.
#
# Billable/Data/Config deliberately keep Cloud Rewind's own vocabulary (support article 89349) so these numbers
# reconcile against a Commvault quote. Note NonBillableDataResources is structurally always 0 on Azure - no
# non-billable Azure type classifies as Data - but the column is kept for a consistent cross-cloud schema.
function Get-CVCloudRewindSummary {
    [CmdletBinding()]
    param([object[]]$Classified = @())
    if (-not $Classified.Count) { return @() }
    $rows = $Classified | Group-Object Account | ForEach-Object {
        $g = $_.Group
        $bd  = @($g | Where-Object {      $_.Billable -and $_.ResourceClass -eq 'Data'   }).Count
        $bc  = @($g | Where-Object {      $_.Billable -and $_.ResourceClass -eq 'Config' }).Count
        $nbd = @($g | Where-Object { -not $_.Billable -and $_.ResourceClass -eq 'Data'   }).Count
        $nbc = @($g | Where-Object { -not $_.Billable -and $_.ResourceClass -eq 'Config' }).Count
        [pscustomobject]@{
            AccountName                = $g[0].AccountName
            Account                    = $_.Name
            BillableDataResources      = $bd
            BillableConfigResources    = $bc
            NonBillableDataResources   = $nbd
            NonBillableConfigResources = $nbc
            TotalBillableResources     = ($bd + $bc)
            TotalNonBillableResources  = ($nbd + $nbc)
            TotalClassifiedResources   = ($bd + $bc + $nbd + $nbc)
        }
    }
    return @($rows | Sort-Object AccountName)
}

#endregion
