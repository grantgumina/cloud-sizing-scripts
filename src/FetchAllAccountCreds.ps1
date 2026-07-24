#requires -Version 7.0
<#
.SYNOPSIS
    Fetches temporary AWS credentials for all SSO-accessible accounts and runs
    the CV sizing script across all of them, producing a single combined JSON.

.DESCRIPTION
    Prerequisites:
      1. AWS CLI v2 installed  (winget install Amazon.AWSCLI)
      2. An active SSO login:  aws sso login --profile <any-sso-profile>
         OR you already have AWS_ACCESS_KEY_ID / SECRET / SESSION_TOKEN env vars
         set for an account that can call SSO list-accounts (typically the master).
      3. CVAWSCloudSizingScript.ps1 in the same directory.

.PARAMETER SsoStartUrl
    Your SSO start URL, e.g. https://commvault.awsapps.com/start

.PARAMETER SsoRegion
    AWS region where SSO is hosted (usually us-east-1).

.PARAMETER Regions
    Comma-separated list of AWS regions to inventory in each account.
    Defaults to the four most common US regions.

.PARAMETER OutputFormat
    Passed through to the sizing script: csv | json | both. Default: json.

.PARAMETER PreferredRolePriority
    Ordered list of role name substrings to prefer when an account has multiple
    roles. The first match wins. Default tries ReadOnly before Full-access roles.

.EXAMPLE
    # If you already have env vars set (from the SSO portal copy-paste):
    .\FetchAllAccountCreds.ps1 -SsoStartUrl "https://commvault.awsapps.com/start" -SsoRegion us-east-1

.EXAMPLE
    # Specify regions explicitly:
    .\FetchAllAccountCreds.ps1 -SsoStartUrl "https://commvault.awsapps.com/start" `
        -SsoRegion us-east-1 -Regions "us-east-1,us-east-2,us-west-2"
#>
param (
    [Parameter(Mandatory = $true)]
    [string]$SsoStartUrl,

    [string]$SsoRegion = "us-east-1",

    [string]$Regions = "us-east-1,us-east-2,us-west-1,us-west-2",

    [ValidateSet("csv", "json", "both")]
    [string]$OutputFormat = "json",

    [string]$OutputDir = (Join-Path $PSScriptRoot "output"),

    [string[]]$PreferredRolePriority = @("ReadOnly", "ViewOnly", "Reader", "FullAccess", "Administrator", "")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot
$SizingScript = Join-Path $ScriptDir "CVAWSCloudSizingScript.ps1"
$CredsFile = Join-Path $ScriptDir "Creds_all_accounts.txt"
$Timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"

if (-not (Test-Path $SizingScript)) {
    Write-Error "CVAWSCloudSizingScript.ps1 not found at $SizingScript"
    exit 1
}

# Check AWS CLI is available
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Error "AWS CLI not found. Install with: winget install Amazon.AWSCLI"
    exit 1
}

Write-Host "`n=== Step 1: Get SSO access token ===" -ForegroundColor Cyan

# Find the cached SSO token on disk (aws sso login stores it here)
$SsoCacheDir = Join-Path $env:USERPROFILE ".aws\sso\cache"
$SsoToken = $null

if (Test-Path $SsoCacheDir) {
    $tokenFiles = Get-ChildItem $SsoCacheDir -Filter "*.json" | Sort-Object LastWriteTime -Descending
    foreach ($f in $tokenFiles) {
        try {
            $content = Get-Content $f.FullName -Raw | ConvertFrom-Json
            # Match by startUrl OR by presence of accessToken with a recent expiry
            $urlMatch = $content.startUrl -and (
                $content.startUrl -eq $SsoStartUrl -or
                $content.startUrl -like "*$($SsoStartUrl.Split('/')[2])*"
            )
            $hasToken = $content.accessToken -and (-not $content.startUrl)
            if ($content.accessToken -and ($urlMatch -or $hasToken)) {
                $SsoToken = $content.accessToken
                Write-Host "Found SSO token in: $($f.Name) (expires: $($content.expiresAt))" -ForegroundColor Green
                break
            }
        } catch { }
    }
}

if (-not $SsoToken) {
    Write-Host "No cached SSO token found. Running 'aws sso login'..." -ForegroundColor Yellow
    aws sso login --sso-session default 2>&1
    # Retry after login — pick the most recently written token file
    $tokenFiles = Get-ChildItem $SsoCacheDir -Filter "*.json" | Sort-Object LastWriteTime -Descending
    foreach ($f in $tokenFiles) {
        try {
            $content = Get-Content $f.FullName -Raw | ConvertFrom-Json
            if ($content.accessToken) {
                $SsoToken = $content.accessToken
                Write-Host "Found SSO token in: $($f.Name)" -ForegroundColor Green
                break
            }
        } catch { }
    }
    if (-not $SsoToken) {
        Write-Error "Still no SSO token after login attempt. Please run: aws sso login --sso-session default"
        exit 1
    }
}

Write-Host "`n=== Step 2: List all SSO accounts ===" -ForegroundColor Cyan

# Helper: attempt list-accounts and return parsed JSON, or $null on failure
function Invoke-SsoListAccounts {
    param([string]$Token, [string]$Region, [string]$NextToken)
    $cliArgs = @("sso", "list-accounts",
        "--access-token", $Token,
        "--region", $Region,
        "--output", "json")
    if ($NextToken) { $cliArgs += @("--next-token", $NextToken) }
    $raw = (aws @cliArgs 2>&1)
    try { return $raw | ConvertFrom-Json } catch { return $null }
}

# Test the current token — if it fails, force a fresh sso login
$testResult = Invoke-SsoListAccounts -Token $SsoToken -Region $SsoRegion
if (-not $testResult) {
    Write-Host "SSO token invalid or expired. Running 'aws sso login --sso-session default'..." -ForegroundColor Yellow
    aws sso login --sso-session default 2>&1
    # Re-read token from cache
    $SsoToken = $null
    $tokenFiles = Get-ChildItem $SsoCacheDir -Filter "*.json" | Sort-Object LastWriteTime -Descending
    foreach ($f in $tokenFiles) {
        try {
            $content = Get-Content $f.FullName -Raw | ConvertFrom-Json
            if ($content.accessToken) { $SsoToken = $content.accessToken; break }
        } catch { }
    }
    if (-not $SsoToken) {
        Write-Error "Still no valid SSO token. Please run: aws sso login --sso-session default"
        exit 1
    }
    $testResult = Invoke-SsoListAccounts -Token $SsoToken -Region $SsoRegion
    if (-not $testResult) {
        Write-Error "SSO list-accounts still failing after fresh login. Check your SSO configuration."
        exit 1
    }
}

$accounts = @()
$nextToken = $null
do {
    $result = Invoke-SsoListAccounts -Token $SsoToken -Region $SsoRegion -NextToken $nextToken
    if (-not $result) { Write-Error "Failed to list SSO accounts."; exit 1 }
    $accounts += $result.accountList
    $nextToken = if ($result.PSObject.Properties['nextToken']) { $result.nextToken } else { $null }
} while ($nextToken)

Write-Host "Found $($accounts.Count) accounts" -ForegroundColor Green

Write-Host "`n=== Step 3: Get roles + fetch credentials for each account ===" -ForegroundColor Cyan

$successCount = 0
$skipCount = 0
$credsLines = @()

foreach ($account in $accounts) {
    $accountId   = $account.accountId
    $accountName = $account.accountName -replace '[^a-zA-Z0-9_-]', '-'

    Write-Host "  [$accountId] $accountName" -NoNewline

    # List available roles for this account
    try {
        $rolesJson = (aws sso list-account-roles `
            --access-token $SsoToken `
            --account-id $accountId `
            --region $SsoRegion `
            --output json 2>&1) | ConvertFrom-Json
        $roles = $rolesJson.roleList
    } catch {
        Write-Host " — SKIP (cannot list roles: $_)" -ForegroundColor Yellow
        $skipCount++
        continue
    }

    if (-not $roles -or $roles.Count -eq 0) {
        Write-Host " — SKIP (no roles)" -ForegroundColor Yellow
        $skipCount++
        continue
    }

    # Pick best role based on priority list
    $chosenRole = $null
    foreach ($priority in $PreferredRolePriority) {
        $match = $roles | Where-Object { $_.roleName -like "*$priority*" } | Select-Object -First 1
        if ($match) { $chosenRole = $match; break }
    }
    if (-not $chosenRole) { $chosenRole = $roles[0] }

    Write-Host " — role: $($chosenRole.roleName)" -NoNewline

    # Get temporary credentials via SSO
    try {
        $credsJson = (aws sso get-role-credentials `
            --access-token $SsoToken `
            --account-id $accountId `
            --role-name $chosenRole.roleName `
            --region $SsoRegion `
            --output json 2>&1) | ConvertFrom-Json
        $creds = $credsJson.roleCredentials
    } catch {
        Write-Host " — SKIP (cannot get creds: $_)" -ForegroundColor Yellow
        $skipCount++
        continue
    }

    $profileName = "$accountName-$accountId"
    $credsLines += "[$profileName]"
    $credsLines += "aws_access_key_id = $($creds.accessKeyId)"
    $credsLines += "aws_secret_access_key = $($creds.secretAccessKey)"
    $credsLines += "aws_session_token = $($creds.sessionToken)"
    $credsLines += ""

    Write-Host " — OK" -ForegroundColor Green
    $successCount++
}

Write-Host "`nCredentials fetched: $successCount / $($accounts.Count) accounts ($skipCount skipped)" -ForegroundColor Cyan

if ($successCount -eq 0) {
    Write-Error "No credentials could be fetched. Cannot proceed."
    exit 1
}

# Write credentials file
$credsLines | Set-Content -Path $CredsFile -Encoding UTF8
Write-Host "Credentials file written: $CredsFile" -ForegroundColor Green

Write-Host "`n=== Step 3b: Ensure required AWS PowerShell modules are installed ===" -ForegroundColor Cyan
$requiredModules = @("AWS.Tools.ElastiCache", "AWS.Tools.Backup")
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Host "  Installing $mod..." -ForegroundColor Yellow
        Install-Module -Name $mod -Force -AllowClobber -Scope CurrentUser -ErrorAction SilentlyContinue
        Write-Host "  $mod installed." -ForegroundColor Green
    } else {
        Write-Host "  $mod already available." -ForegroundColor Gray
    }
}

Write-Host "`n=== Step 4: Running sizing script across all $successCount accounts ===" -ForegroundColor Cyan
Write-Host "Output directory: $OutputDir" -ForegroundColor Cyan
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

# The sizing script relies on uninitialized variables being treated as $null.
# Disable strict mode for the duration of the call so it runs correctly.
# Push to OutputDir so the sizing script (which uses Get-Location) writes there.
Set-StrictMode -Off
Push-Location $OutputDir
try {
    & $SizingScript `
        -AllLocalProfiles `
        -ProfileLocation $CredsFile `
        -Regions $Regions `
        -OutputFormat $OutputFormat
} finally {
    Pop-Location
}
Set-StrictMode -Version Latest

Write-Host "`n=== Done ===" -ForegroundColor Green
Write-Host "Output files are in: $OutputDir" -ForegroundColor Green

# Find and display the combined JSON file
$jsonFiles = Get-ChildItem -Path $OutputDir -Filter "aws_sizing_*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
if ($jsonFiles) {
    Write-Host "Combined JSON report: $($jsonFiles[0].FullName)" -ForegroundColor Cyan
} else {
    Write-Host "No combined JSON found in $OutputDir — check per-account Excel files in that directory." -ForegroundColor Yellow
}

# Clean up credentials file (contains temp secrets)
Remove-Item $CredsFile -Force -ErrorAction SilentlyContinue
Write-Host "Credentials file deleted." -ForegroundColor Gray
