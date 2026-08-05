<#
    CVSizing.CloudRewind.GCP.ps1 - GCP Cloud Rewind taxonomy + classification.

    DERIVED taxonomy (NOT authoritative): the GCP "supported resources" doc lists protectable types but does NOT
    mark billable vs non-billable (that split is in a gated KB article). These arrays apply the authoritative Azure
    pattern (article 89349) to the GCP supported list. Confirm/adjust against the GCP KB article; each is a one-line edit.

    Discovery uses Cloud Asset Inventory (gcloud asset search-all-resources) per project, which returns each asset's
    assetType, labels, location, name and project. Classification keys off the full assetType string, so the shared
    engine's exact-match classifier is used directly.

    Judgment calls flagged in the plan:
      - Load Balancer counting: a single logical LB maps to many API objects; billable is defaulted to one-per-
        ForwardingRule, with the url-map / backend-service / target-pool / target-proxy objects non-billable.
      - External IP / disk attach-vs-unattached exclusion is NOT yet applied (first cut counts all billable-type
        assets). Cloud SQL is defaulted to Config-class (mirroring Azure's narrow Data = instance + disk).
#>

function Get-CVGcpCloudRewindTaxonomy {
    [CmdletBinding()] param()
    $billable = @(
        'compute.googleapis.com/Instance'        # Compute Engine instance  [Data]
        'compute.googleapis.com/Disk'            # Persistent disk          [Data]
        'sqladmin.googleapis.com/Instance'       # Cloud SQL
        'compute.googleapis.com/Network'         # VPC network
        'compute.googleapis.com/Address'         # External IP address
        'compute.googleapis.com/ForwardingRule'  # Load balancer (counted once per forwarding rule)
    )
    $nonBillable = @(
        'compute.googleapis.com/InstanceGroup'   # unmanaged instance group
        'compute.googleapis.com/HealthCheck'
        'compute.googleapis.com/Subnetwork'
        'compute.googleapis.com/Route'
        'compute.googleapis.com/Firewall'
        'compute.googleapis.com/SslCertificate'
        'compute.googleapis.com/UrlMap'
        'compute.googleapis.com/BackendService'
        'compute.googleapis.com/TargetPool'
        'compute.googleapis.com/TargetHttpProxy'
        'compute.googleapis.com/TargetHttpsProxy'
        'compute.googleapis.com/TargetTcpProxy'
    )
    return @{ Billable = $billable; NonBillable = $nonBillable }
}

# Union of asset types to request from Cloud Asset Inventory (--asset-types), so the summary can count both sides.
function Get-CVGcpCloudRewindAssetTypes {
    [CmdletBinding()] param()
    $tax = Get-CVGcpCloudRewindTaxonomy
    return @(@($tax.Billable) + @($tax.NonBillable))
}

# Data vs Config: Data = Compute instance or disk; everything else Config (mirrors Azure's narrow Data set).
function Get-CVGcpCloudRewindClass {
    param([string]$AssetType)
    if ($AssetType -eq 'compute.googleapis.com/Instance' -or $AssetType -eq 'compute.googleapis.com/Disk') { return 'Data' }
    return 'Config'
}

function Get-CVGcpCloudRewindCategory {
    param([string]$AssetType)
    switch ($AssetType) {
        'compute.googleapis.com/Instance'       { 'Compute Engine Instance'; break }
        'compute.googleapis.com/Disk'           { 'Persistent Disk';         break }
        'sqladmin.googleapis.com/Instance'      { 'Cloud SQL';               break }
        'compute.googleapis.com/Network'        { 'VPC Network';             break }
        'compute.googleapis.com/Address'        { 'External IP Address';     break }
        'compute.googleapis.com/ForwardingRule' { 'Load Balancer';           break }
        default { ("$AssetType" -replace '.*/', '') }
    }
}

function Get-CVGcpCloudRewindReason {
    param([string]$AssetType)
    'Billable resource type'   # attach/exclusion refinement is a follow-up (see file header)
}
