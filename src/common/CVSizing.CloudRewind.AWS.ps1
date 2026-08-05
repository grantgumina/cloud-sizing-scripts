<#
    CVSizing.CloudRewind.AWS.ps1 - AWS Cloud Rewind taxonomy + classification.

    DERIVED taxonomy (NOT authoritative): the AWS "supported resources" doc lists which types Cloud Rewind can
    protect but does NOT mark billable vs non-billable (that split is in a gated KB article). These arrays apply
    the authoritative Azure pattern (article 89349) to the AWS supported list: primary/protectable = billable,
    attachments + pure config = non-billable. Confirm/adjust against the AWS KB article; every entry is a one-line edit.

    Discovery uses the Resource Groups Tagging API (Get-RGTResource) per region, which returns each resource's ARN
    and tags. Classification keys off a "service:resource-type" token parsed from the ARN.

    First-cut caveats (documented, refine later):
      - Attach/exclusion (unattached EBS volumes / unassociated Elastic IPs / root-vs-data volume) is NOT yet applied
        - every billable-type resource the Tagging API returns is counted. The Azure sizer excludes unattached/OS;
          the AWS analog needs per-resource describe calls (Get-EC2Volume / Get-EC2Address). Flagged for follow-up.
      - The Tagging API only returns taggable resource types; classic ELBs and a few types may not appear.
#>

# Billable / non-billable "service:resource-type" ARN tokens.
function Get-CVAwsCloudRewindTaxonomy {
    [CmdletBinding()] param()
    $billable = @(
        'ec2:instance'                       # EC2 instance        [Data]
        'ec2:volume'                         # EBS volume          [Data]
        'rds:db'                             # RDS instance
        'rds:cluster'                        # Aurora cluster
        'elasticfilesystem:file-system'      # EFS
        'dynamodb:table'                     # DynamoDB
        'ec2:vpc'                            # VPC
        'elasticloadbalancing:loadbalancer'  # ALB / NLB (and classic where returned)
        'ec2:natgateway'                     # NAT gateway
        'ec2:elastic-ip'                     # Elastic IP
        'lambda:function'                    # Lambda
    )
    $nonBillable = @(
        'ec2:subnet'
        'ec2:network-interface'
        'ec2:route-table'
        'ec2:internet-gateway'
        'ec2:dhcp-options'
        'ec2:security-group'
        'ec2:network-acl'
        'ec2:key-pair'
        'acm:certificate'
        'route53:hostedzone'
        'rds:og'                             # option group
        'rds:pg'                             # parameter group
        'rds:cluster-pg'                     # cluster parameter group
        'rds:subgrp'                         # subnet group
        'rds:secgrp'                         # DB security group
        'elasticloadbalancing:targetgroup'
        'elasticfilesystem:access-point'
        'elasticfilesystem:mount-target'
    )
    # Services whose ARNs carry no resource-type token (arn:aws:svc:region:acct:name) - classified by service alone.
    $nonBillableServices = @('sqs', 'sns')
    return @{ Billable = $billable; NonBillable = $nonBillable; NonBillableServices = $nonBillableServices }
}

# Parse an ARN into a "service:resource-type" token. Handles type/id, type:id, and bare-id ARN forms.
#   arn:aws:ec2:us-east-1:123:instance/i-abc   -> ec2:instance
#   arn:aws:rds:us-east-1:123:db:mydb          -> rds:db
#   arn:aws:sqs:us-east-1:123:myqueue          -> sqs:myqueue  (no type token -> service used via fallback)
function Get-CVAwsArnType {
    param([string]$Arn)
    if ([string]::IsNullOrWhiteSpace($Arn)) { return '' }
    $parts = "$Arn" -split ':', 6
    if ($parts.Count -lt 6) { return '' }
    $service  = $parts[2]
    $resource = $parts[5]
    if ($resource.Contains('/'))      { $rtype = ($resource -split '/', 2)[0] }
    elseif ($resource.Contains(':'))  { $rtype = ($resource -split ':', 2)[0] }
    else                              { $rtype = $resource }   # bare id, no type token
    return ("{0}:{1}" -f $service, $rtype)
}

# Billable ($true) / non-billable ($false) / not-in-taxonomy ($null) for an ARN.
function Get-CVAwsCloudRewindBillable {
    param([string]$Arn, [Parameter(Mandatory)]$Taxonomy)
    $token   = Get-CVAwsArnType -Arn $Arn
    if ([string]::IsNullOrWhiteSpace($token)) { return $null }
    if (@($Taxonomy.Billable)    -contains $token) { return $true }
    if (@($Taxonomy.NonBillable) -contains $token) { return $false }
    $service = ($token -split ':', 2)[0]
    if (@($Taxonomy.NonBillableServices) -contains $service) { return $false }
    return $null
}

# Data vs Config: Data = EC2 instance or EBS volume; everything else Config (mirrors Azure's narrow Data set).
function Get-CVAwsCloudRewindClass {
    param([string]$Token)
    if ($Token -eq 'ec2:instance' -or $Token -eq 'ec2:volume') { return 'Data' }
    return 'Config'
}

function Get-CVAwsCloudRewindCategory {
    param([string]$Token)
    switch ($Token) {
        'ec2:instance'                      { 'EC2 Instance';    break }
        'ec2:volume'                        { 'EBS Volume';      break }
        'rds:db'                            { 'RDS Instance';    break }
        'rds:cluster'                       { 'Aurora Cluster';  break }
        'elasticfilesystem:file-system'     { 'EFS File System'; break }
        'dynamodb:table'                    { 'DynamoDB Table';  break }
        'ec2:vpc'                           { 'VPC';             break }
        'elasticloadbalancing:loadbalancer' { 'Load Balancer';   break }
        'ec2:natgateway'                    { 'NAT Gateway';     break }
        'ec2:elastic-ip'                    { 'Elastic IP';      break }
        'lambda:function'                   { 'Lambda Function'; break }
        default { "$Token" }
    }
}

function Get-CVAwsCloudRewindReason {
    param([string]$Token)
    'Billable resource type'   # attach/exclusion refinement is a follow-up (see file header)
}
