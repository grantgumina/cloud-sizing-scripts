#requires -Version 7.2
<#  Dependency-free tests for the shared permission classifier in src/common/CVSizing.Console.ps1:
    Get-CVCategory (message -> category), Test-CVPermissionError, Get-CVDeniedAction.

    These are the load-bearing pieces for graceful permission handling across all three clouds, so they
    are asserted against the REAL denial/disabled-API messages captured during the audit.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Console.ps1')

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }
function New-Err { param([string]$Msg) [System.Management.Automation.ErrorRecord]::new([System.Exception]::new($Msg), 'x', 'NotSpecified', $null) }

# Real messages (verbatim shapes from the audits).
$awsMsg   = "User: arn:aws:iam::491085382896:user/CVSizing is not authorized to perform: elasticache:DescribeCacheClusters on resource: arn:aws:elasticache:us-east-1:491085382896:cluster:* because no identity-based policy allows the elasticache:DescribeCacheClusters action"
$s3Msg    = "Access Denied"
$ec2Msg   = "You are not authorized to perform this operation. Encoded authorization failure message: ... (UnauthorizedOperation)"
$azActMsg = "The client 'app' with object id '...' does not have authorization to perform action 'Microsoft.RecoveryServices/vaults/read' over scope '/subscriptions/...' or the scope is invalid."
$azCodeMsg= "Operation returned an invalid status code 'Forbidden' (AuthorizationFailed)"
$gcpPermA = "PERMISSION_DENIED: 456789 - The caller does not have storage.buckets.list access to the Google Cloud Storage bucket."
$gcpPermB = "Permission 'compute.instances.list' denied on resource (or it may not exist)."
$gcpDisA  = "Compute Engine API has not been used in project 123 before or it is disabled."
$gcpDisB  = "Cloud Asset API is not enabled. SERVICE_DISABLED"
$throttle = "Rate exceeded"
$timeout  = "The operation timed out"

Write-Host "`n[1] Get-CVCategory -> Permission for all three clouds' denial text"
Assert-CV 'aws not-authorized -> Permission'   (Get-CVCategory $awsMsg)   'Permission'
Assert-CV 's3 Access Denied -> Permission'     (Get-CVCategory $s3Msg)    'Permission'
Assert-CV 'ec2 UnauthorizedOperation -> Permission' (Get-CVCategory $ec2Msg) 'Permission'
Assert-CV 'azure does-not-have-authorization -> Permission' (Get-CVCategory $azActMsg) 'Permission'
Assert-CV 'azure AuthorizationFailed -> Permission' (Get-CVCategory $azCodeMsg) 'Permission'
Assert-CV 'gcp PERMISSION_DENIED -> Permission' (Get-CVCategory $gcpPermA) 'Permission'
Assert-CV 'gcp Permission-denied -> Permission' (Get-CVCategory $gcpPermB) 'Permission'

Write-Host "`n[2] Disabled-API is NOT a permission problem (ApiDisabled wins, checked first)"
Assert-CV 'gcp has-not-been-used -> ApiDisabled' (Get-CVCategory $gcpDisA) 'ApiDisabled'
Assert-CV 'gcp SERVICE_DISABLED -> ApiDisabled'  (Get-CVCategory $gcpDisB) 'ApiDisabled'

Write-Host "`n[3] Non-permission failures classify elsewhere"
Assert-CV 'rate exceeded -> Transient' (Get-CVCategory $throttle) 'Transient'
Assert-CV 'timed out -> Timeout'       (Get-CVCategory $timeout)  'Timeout'

Write-Host "`n[4] Test-CVPermissionError (string, Exception, ErrorRecord)"
Assert-CV 'string aws -> true'          (Test-CVPermissionError $awsMsg) $true
Assert-CV 'ErrorRecord aws -> true'     (Test-CVPermissionError (New-Err $awsMsg)) $true
Assert-CV 'Exception azure -> true'     (Test-CVPermissionError ([System.Exception]::new($azActMsg))) $true
Assert-CV 'gcp perm -> true'            (Test-CVPermissionError $gcpPermA) $true
Assert-CV 'api-disabled -> false'       (Test-CVPermissionError $gcpDisA) $false
Assert-CV 'throttle -> false'           (Test-CVPermissionError $throttle) $false
Assert-CV 'null -> false'               (Test-CVPermissionError $null) $false

Write-Host "`n[5] Get-CVDeniedAction extracts the named action, else null"
Assert-CV 'aws action'   (Get-CVDeniedAction $awsMsg)   'elasticache:DescribeCacheClusters'
Assert-CV 'azure action' (Get-CVDeniedAction $azActMsg) 'Microsoft.RecoveryServices/vaults/read'
Assert-CV 'gcp access-form action'  (Get-CVDeniedAction $gcpPermA) 'storage.buckets.list'
Assert-CV 'gcp permission-form action' (Get-CVDeniedAction $gcpPermB) 'compute.instances.list'
Assert-CV 'ErrorRecord input works'  (Get-CVDeniedAction (New-Err $awsMsg)) 'elasticache:DescribeCacheClusters'
Assert-CV 'unnamed denial -> null'   ($null -eq (Get-CVDeniedAction $s3Msg)) $true

Write-Host ("`n======  {0} passed, {1} failed  ======`n" -f $script:Pass, $script:Fail) `
           -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
