<#
.SYNOPSIS
    Microsoft 365 Sizing Script - Discover protectable M365 workloads for Commvault scoping.

.DESCRIPTION
    Connects to Microsoft Graph API and Exchange Online to inventory:
      - Exchange Online mailboxes (size, type, archive status)
      - SharePoint Online sites (storage used and quota)
      - OneDrive for Business accounts (storage used)
      - Microsoft Teams (team count, channel counts)
      - Microsoft 365 Groups
    Generates CSV reports and a ZIP archive suitable for Commvault pre-sales sizing.

.PARAMETER TenantId
    Azure AD Tenant ID (required).

.PARAMETER ClientId
    App registration Client ID with appropriate Graph API permissions (required).
    Required Graph API permissions (Application):
      - Mail.Read, MailboxSettings.Read           (Exchange/mailboxes)
      - Sites.Read.All                            (SharePoint)
      - Files.Read.All                            (OneDrive)
      - TeamSettings.Read.All                     (Teams)
      - Group.Read.All                            (M365 Groups)
      - Reports.Read.All                          (usage reports)
      - User.Read.All                             (user enumeration)

.PARAMETER ClientSecret
    App registration client secret (required for app-only auth).

.PARAMETER CertificatePath
    Path to a PFX certificate for app-only auth (alternative to ClientSecret).

.PARAMETER CertificatePassword
    Password for the PFX certificate.

.PARAMETER UseInteractiveLogin
    Use interactive (delegated) login instead of app-only auth. Requires Exchange Online module.

.PARAMETER Types
    Restrict inventory to specific workload types.
    Valid values: Exchange, SharePoint, OneDrive, Teams, Groups
    If omitted, all workloads are inventoried.

.EXAMPLE
    .\CVM365SizingScript.ps1 -TenantId "40ed1e38-..." -ClientId "..." -ClientSecret "..."

.EXAMPLE
    .\CVM365SizingScript.ps1 -TenantId "40ed1e38-..." -ClientId "..." -ClientSecret "..." -Types Exchange,OneDrive

.EXAMPLE
    .\CVM365SizingScript.ps1 -TenantId "40ed1e38-..." -ClientId "..." -CertificatePath ".\cert.pfx" -CertificatePassword "p@ss"

.OUTPUTS
    Creates a timestamped output directory with:
      - m365_exchange_mailboxes_YYYY-MM-DD_HHMMSS.csv
      - m365_sharepoint_sites_YYYY-MM-DD_HHMMSS.csv
      - m365_onedrive_accounts_YYYY-MM-DD_HHMMSS.csv
      - m365_teams_YYYY-MM-DD_HHMMSS.csv
      - m365_groups_YYYY-MM-DD_HHMMSS.csv
      - m365_inventory_summary_YYYY-MM-DD_HHMMSS.csv
      - m365_sizing_script_output_YYYY-MM-DD_HHMMSS.log
      - m365_sizing_YYYY-MM-DD_HHMMSS.zip

.NOTES
    Requires:
      - PowerShell 7+
      - Microsoft.Graph PowerShell SDK: Install-Module Microsoft.Graph -Scope CurrentUser
      - (Optional for mailbox detail) ExchangeOnlineManagement: Install-Module ExchangeOnlineManagement -Scope CurrentUser
#>

param(
    [Parameter(Mandatory=$true)]  [string]   $TenantId,
    [Parameter(Mandatory=$true)]  [string]   $ClientId,
    [string]   $ClientSecret,
    [string]   $CertificatePath,
    [string]   $CertificatePassword,
    [switch]   $UseInteractiveLogin,
    [string[]] $Types,  # Exchange, SharePoint, OneDrive, Teams, Groups
    [ValidateSet("csv","json","both")][string]$OutputFormat = "csv"  # Output format: csv (default), json, or both
)

[System.Threading.Thread]::CurrentThread.CurrentCulture   = 'en-US'
[System.Threading.Thread]::CurrentThread.CurrentUICulture = 'en-US'

# ---------------------------------------------------------------
# Type selection
# ---------------------------------------------------------------
$ValidTypes = @('EXCHANGE','SHAREPOINT','ONEDRIVE','TEAMS','GROUPS')
if ($Types) {
    $Types = $Types | ForEach-Object { $_.Trim().ToUpper() }
    $bad   = $Types | Where-Object { $ValidTypes -notcontains $_ }
    if ($bad.Count -gt 0) {
        Write-Error "Invalid type(s): $($bad -join ', '). Valid: Exchange, SharePoint, OneDrive, Teams, Groups"
        exit 1
    }
    $Selected = @{}
    $Types | ForEach-Object { $Selected[$_] = $true }
} else {
    $Selected = @{}
    $ValidTypes | ForEach-Object { $Selected[$_] = $true }
}

# ---------------------------------------------------------------
# Output directory & logging
# ---------------------------------------------------------------
$dateStr = Get-Date -Format "yyyy-MM-dd_HHmmss"
$outDir  = Join-Path $PWD ("m365-inv-" + $dateStr)
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$logFile = Join-Path $outDir "m365_sizing_script_output_$dateStr.log"
Start-Transcript -Path $logFile -Append | Out-Null

Write-Host "=== Microsoft 365 Resource Inventory Started ===" -ForegroundColor Green
Write-Host "  TenantId : $TenantId" -ForegroundColor Cyan
Write-Host "  Types    : $($Selected.Keys -join ', ')" -ForegroundColor Cyan

# ---------------------------------------------------------------
# Module installation
# ---------------------------------------------------------------
function Ensure-Module {
    param([string]$Name)
    if (-not (Get-Module -ListAvailable -Name $Name)) {
        Write-Host "Installing module $Name ..." -ForegroundColor Yellow
        try { Install-Module $Name -Scope CurrentUser -Force -AllowClobber } catch { Write-Warning "Could not install $Name : $_" }
    }
    try { Import-Module $Name -ErrorAction Stop } catch { Write-Warning "Could not load $Name : $_" }
}

Ensure-Module "Microsoft.Graph.Authentication"
Ensure-Module "Microsoft.Graph.Users"
Ensure-Module "Microsoft.Graph.Reports"
Ensure-Module "Microsoft.Graph.Teams"
Ensure-Module "Microsoft.Graph.Groups"
Ensure-Module "Microsoft.Graph.Sites"

# ---------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------
$Scopes = @(
    "https://graph.microsoft.com/.default"
)

try {
    if ($UseInteractiveLogin) {
        Connect-MgGraph -TenantId $TenantId -Scopes $Scopes -ErrorAction Stop
        Write-Host "Connected to Microsoft Graph (interactive)" -ForegroundColor Green
    } elseif ($CertificatePath) {
        $certPwd = if ($CertificatePassword) { ConvertTo-SecureString $CertificatePassword -AsPlainText -Force } else { $null }
        $cert    = if ($certPwd) { New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertificatePath, $certPwd) }
                   else          { New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertificatePath) }
        Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -Certificate $cert -ErrorAction Stop
        Write-Host "Connected to Microsoft Graph (certificate)" -ForegroundColor Green
    } elseif ($ClientSecret) {
        $secSecret = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
        $cred      = New-Object System.Management.Automation.PSCredential($ClientId, $secSecret)
        Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $cred -ErrorAction Stop
        Write-Host "Connected to Microsoft Graph (client secret)" -ForegroundColor Green
    } else {
        Write-Error "Provide -ClientSecret, -CertificatePath, or -UseInteractiveLogin."
        exit 1
    }
} catch {
    Write-Error "Failed to connect to Microsoft Graph: $_"
    exit 1
}

# ---------------------------------------------------------------
# Helper: Graph paged GET
# ---------------------------------------------------------------
function Invoke-GraphPagedGet {
    param([string]$Uri, [int]$MaxPages = 500)
    $results = @()
    $nextLink = $Uri
    $page = 0
    while ($nextLink -and $page -lt $MaxPages) {
        $page++
        try {
            $resp = Invoke-MgGraphRequest -Method GET -Uri $nextLink -ErrorAction Stop
            if ($resp.value) { $results += $resp.value }
            $nextLink = $resp.'@odata.nextLink'
        } catch {
            Write-Warning "Graph paged GET failed ($Uri): $_"
            break
        }
    }
    return $results
}

# ---------------------------------------------------------------
# Exchange Online — mailbox report via Graph usage reports
# ---------------------------------------------------------------
$Mailboxes    = @()
$SPSites      = @()
$ODAccounts   = @()
$Teams        = @()
$Groups       = @()

if ($Selected.EXCHANGE) {
    Write-Host "`nInventorying Exchange Online mailboxes..." -ForegroundColor Green
    try {
        # Graph Reports API — mailbox usage detail (last 180 days)
        $reportUri = "https://graph.microsoft.com/v1.0/reports/getMailboxUsageDetail(period='D180')?`$format=application/json"
        $mbxRaw    = Invoke-GraphPagedGet -Uri $reportUri

        foreach ($mbx in $mbxRaw) {
            $Mailboxes += [PSCustomObject]@{
                UserPrincipalName       = $mbx.userPrincipalName
                DisplayName             = $mbx.displayName
                IsDeleted               = $mbx.isDeleted
                DeletedDate             = $mbx.deletedDate
                CreatedDate             = $mbx.createdDate
                LastActivityDate        = $mbx.lastActivityDate
                ItemCount               = $mbx.itemCount
                StorageUsedGB           = [math]::Round(($mbx.storageUsedInBytes  / 1GB), 4)
                StorageUsedMB           = [math]::Round(($mbx.storageUsedInBytes  / 1MB), 2)
                IssueWarningQuotaGB     = [math]::Round(($mbx.issueWarningQuotaInBytes  / 1GB), 4)
                ProhibitSendQuotaGB     = [math]::Round(($mbx.prohibitSendQuotaInBytes  / 1GB), 4)
                ProhibitSendReceiveQuotaGB = [math]::Round(($mbx.prohibitSendReceiveQuotaInBytes / 1GB), 4)
                HasArchive              = $mbx.hasArchive
                ArchiveItemCount        = $mbx.archiveItemCount
                ArchiveStorageUsedGB    = if ($mbx.archiveStorageUsedInBytes) { [math]::Round($mbx.archiveStorageUsedInBytes / 1GB, 4) } else { 0 }
            }
        }

        Write-Host "  Found $($Mailboxes.Count) mailboxes" -ForegroundColor Cyan
    } catch {
        Write-Warning "Exchange mailbox inventory failed: $_"
    }
}

# ---------------------------------------------------------------
# SharePoint Online — site usage
# ---------------------------------------------------------------
if ($Selected.SHAREPOINT) {
    Write-Host "`nInventorying SharePoint Online sites..." -ForegroundColor Green
    try {
        $spUri = "https://graph.microsoft.com/v1.0/reports/getSharePointSiteUsageDetail(period='D180')?`$format=application/json"
        $spRaw = Invoke-GraphPagedGet -Uri $spUri

        foreach ($site in $spRaw) {
            $SPSites += [PSCustomObject]@{
                SiteUrl                 = $site.siteUrl
                OwnerDisplayName        = $site.ownerDisplayName
                OwnerPrincipalName      = $site.ownerPrincipalName
                IsDeleted               = $site.isDeleted
                LastActivityDate        = $site.lastActivityDate
                FileCount               = $site.fileCount
                ActiveFileCount         = $site.activeFileCount
                PageViewCount           = $site.pageViewCount
                StorageUsedGB           = [math]::Round(($site.storageUsedInBytes / 1GB), 4)
                StorageAllocatedGB      = [math]::Round(($site.storageAllocatedInBytes / 1GB), 4)
                RootWebTemplate         = $site.rootWebTemplate
            }
        }

        Write-Host "  Found $($SPSites.Count) SharePoint sites" -ForegroundColor Cyan
    } catch {
        Write-Warning "SharePoint inventory failed: $_"
    }
}

# ---------------------------------------------------------------
# OneDrive for Business — account usage
# ---------------------------------------------------------------
if ($Selected.ONEDRIVE) {
    Write-Host "`nInventorying OneDrive for Business accounts..." -ForegroundColor Green
    try {
        $odUri = "https://graph.microsoft.com/v1.0/reports/getOneDriveUsageAccountDetail(period='D180')?`$format=application/json"
        $odRaw = Invoke-GraphPagedGet -Uri $odUri

        foreach ($od in $odRaw) {
            $ODAccounts += [PSCustomObject]@{
                SiteUrl                 = $od.siteUrl
                OwnerDisplayName        = $od.ownerDisplayName
                OwnerPrincipalName      = $od.ownerPrincipalName
                IsDeleted               = $od.isDeleted
                LastActivityDate        = $od.lastActivityDate
                FileCount               = $od.fileCount
                ActiveFileCount         = $od.activeFileCount
                StorageUsedGB           = [math]::Round(($od.storageUsedInBytes / 1GB), 4)
                StorageAllocatedGB      = [math]::Round(($od.storageAllocatedInBytes / 1GB), 4)
            }
        }

        Write-Host "  Found $($ODAccounts.Count) OneDrive accounts" -ForegroundColor Cyan
    } catch {
        Write-Warning "OneDrive inventory failed: $_"
    }
}

# ---------------------------------------------------------------
# Microsoft Teams
# ---------------------------------------------------------------
if ($Selected.TEAMS) {
    Write-Host "`nInventorying Microsoft Teams..." -ForegroundColor Green
    try {
        $teamsUri = "https://graph.microsoft.com/v1.0/teams?`$select=id,displayName,description,visibility,isArchived,createdDateTime&`$top=999"
        $teamsRaw = Invoke-GraphPagedGet -Uri $teamsUri

        foreach ($team in $teamsRaw) {
            # Get channel count
            $channelCount = 0
            try {
                $chUri = "https://graph.microsoft.com/v1.0/teams/$($team.id)/channels?`$select=id&`$top=1&`$count=true"
                $chResp = Invoke-MgGraphRequest -Method GET -Uri $chUri -Headers @{'ConsistencyLevel'='eventual'} -ErrorAction SilentlyContinue
                $channelCount = if ($chResp.'@odata.count') { $chResp.'@odata.count' } else { ($chResp.value | Measure-Object).Count }
            } catch {}

            $Teams += [PSCustomObject]@{
                TeamId          = $team.id
                DisplayName     = $team.displayName
                Description     = $team.description
                Visibility      = $team.visibility
                IsArchived      = $team.isArchived
                CreatedDateTime = $team.createdDateTime
                ChannelCount    = $channelCount
            }
        }

        Write-Host "  Found $($Teams.Count) Teams" -ForegroundColor Cyan
    } catch {
        Write-Warning "Teams inventory failed: $_"
    }
}

# ---------------------------------------------------------------
# Microsoft 365 Groups
# ---------------------------------------------------------------
if ($Selected.GROUPS) {
    Write-Host "`nInventorying Microsoft 365 Groups..." -ForegroundColor Green
    try {
        $groupUri = "https://graph.microsoft.com/v1.0/groups?`$filter=groupTypes/any(c:c+eq+'Unified')&`$select=id,displayName,mail,createdDateTime,visibility,membershipRule,membershipRuleProcessingState&`$top=999"
        $groupsRaw = Invoke-GraphPagedGet -Uri $groupUri

        foreach ($grp in $groupsRaw) {
            $memberCount = 0
            try {
                $mResp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$($grp.id)/members/`$count" -Headers @{'ConsistencyLevel'='eventual'} -ErrorAction SilentlyContinue
                $memberCount = if ($mResp -is [int]) { $mResp } else { 0 }
            } catch {}

            $Groups += [PSCustomObject]@{
                GroupId         = $grp.id
                DisplayName     = $grp.displayName
                Mail            = $grp.mail
                Visibility      = $grp.visibility
                CreatedDateTime = $grp.createdDateTime
                MemberCount     = $memberCount
                IsDynamic       = ($grp.membershipRule -ne $null)
            }
        }

        Write-Host "  Found $($Groups.Count) M365 Groups" -ForegroundColor Cyan
    } catch {
        Write-Warning "M365 Groups inventory failed: $_"
    }
}

# ---------------------------------------------------------------
# Export CSVs
# ---------------------------------------------------------------
Write-Host "`n=== Writing output files ===" -ForegroundColor Green

if ($Selected.EXCHANGE   -and $Mailboxes.Count)   { $Mailboxes  | Export-Csv (Join-Path $outDir "m365_exchange_mailboxes_$dateStr.csv")   -NoTypeInformation; Write-Host "  m365_exchange_mailboxes_$dateStr.csv" -ForegroundColor Cyan }
if ($Selected.SHAREPOINT -and $SPSites.Count)      { $SPSites    | Export-Csv (Join-Path $outDir "m365_sharepoint_sites_$dateStr.csv")     -NoTypeInformation; Write-Host "  m365_sharepoint_sites_$dateStr.csv" -ForegroundColor Cyan }
if ($Selected.ONEDRIVE   -and $ODAccounts.Count)   { $ODAccounts | Export-Csv (Join-Path $outDir "m365_onedrive_accounts_$dateStr.csv")    -NoTypeInformation; Write-Host "  m365_onedrive_accounts_$dateStr.csv" -ForegroundColor Cyan }
if ($Selected.TEAMS      -and $Teams.Count)        { $Teams      | Export-Csv (Join-Path $outDir "m365_teams_$dateStr.csv")                -NoTypeInformation; Write-Host "  m365_teams_$dateStr.csv" -ForegroundColor Cyan }
if ($Selected.GROUPS     -and $Groups.Count)       { $Groups     | Export-Csv (Join-Path $outDir "m365_groups_$dateStr.csv")               -NoTypeInformation; Write-Host "  m365_groups_$dateStr.csv" -ForegroundColor Cyan }

# ---------------------------------------------------------------
# Summary CSV
# ---------------------------------------------------------------
$summaryRows = @()

if ($Selected.EXCHANGE -and $Mailboxes.Count -gt 0) {
    $totalMailboxGB  = ($Mailboxes | Measure-Object StorageUsedGB -Sum).Sum
    $archiveCount    = ($Mailboxes | Where-Object HasArchive -eq $true).Count
    $archiveGB       = ($Mailboxes | Measure-Object ArchiveStorageUsedGB -Sum).Sum
    $activeCount     = ($Mailboxes | Where-Object { $_.IsDeleted -ne $true }).Count
    $summaryRows += [PSCustomObject]@{ Workload='Exchange Online'; Count=$Mailboxes.Count; ActiveCount=$activeCount; TotalStorageGB=[math]::Round($totalMailboxGB,2); Notes="Archives: $archiveCount, Archive storage: $([math]::Round($archiveGB,2)) GB" }
}
if ($Selected.SHAREPOINT -and $SPSites.Count -gt 0) {
    $totalSPGB = ($SPSites | Measure-Object StorageUsedGB -Sum).Sum
    $summaryRows += [PSCustomObject]@{ Workload='SharePoint Online'; Count=$SPSites.Count; ActiveCount=($SPSites | Where-Object { $_.LastActivityDate -and ((Get-Date) - [datetime]$_.LastActivityDate).TotalDays -lt 90 }).Count; TotalStorageGB=[math]::Round($totalSPGB,2); Notes='' }
}
if ($Selected.ONEDRIVE -and $ODAccounts.Count -gt 0) {
    $totalODGB = ($ODAccounts | Measure-Object StorageUsedGB -Sum).Sum
    $summaryRows += [PSCustomObject]@{ Workload='OneDrive for Business'; Count=$ODAccounts.Count; ActiveCount=($ODAccounts | Where-Object { $_.IsDeleted -ne $true }).Count; TotalStorageGB=[math]::Round($totalODGB,2); Notes='' }
}
if ($Selected.TEAMS -and $Teams.Count -gt 0) {
    $totalChannels = ($Teams | Measure-Object ChannelCount -Sum).Sum
    $summaryRows += [PSCustomObject]@{ Workload='Microsoft Teams'; Count=$Teams.Count; ActiveCount=($Teams | Where-Object { $_.IsArchived -ne $true }).Count; TotalStorageGB='N/A'; Notes="Total channels: $totalChannels" }
}
if ($Selected.GROUPS -and $Groups.Count -gt 0) {
    $summaryRows += [PSCustomObject]@{ Workload='M365 Groups'; Count=$Groups.Count; ActiveCount=$Groups.Count; TotalStorageGB='N/A'; Notes='' }
}

if ($summaryRows.Count -gt 0) {
    $summaryRows | Export-Csv (Join-Path $outDir "m365_inventory_summary_$dateStr.csv") -NoTypeInformation
    Write-Host "  m365_inventory_summary_$dateStr.csv" -ForegroundColor Cyan
}

# ---------------------------------------------------------------
# JSON EXPORT (when OutputFormat is json or both)
# ---------------------------------------------------------------
if ($OutputFormat -eq "json" -or $OutputFormat -eq "both") {
    Write-Host "`nWriting JSON sizing output..." -ForegroundColor Green

    $jsonSummary = @{}
    $allWorkloads = @{}

    if ($Mailboxes.Count -gt 0) {
        $allWorkloads["m365_mailboxes"]  = @($Mailboxes)
        $totalMbxGB = [math]::Round(($Mailboxes | Measure-Object StorageUsedGB -Sum).Sum, 2)
        $jsonSummary["Exchange"]         = @{ count = $Mailboxes.Count; total_storage_gb = $totalMbxGB; notes = "Archives: $(($Mailboxes | Where-Object HasArchive -eq $true).Count)" }
    }
    if ($SPSites.Count -gt 0) {
        $allWorkloads["m365_sharepoint"] = @($SPSites)
        $totalSPGB = [math]::Round(($SPSites | Measure-Object StorageUsedGB -Sum).Sum, 2)
        $jsonSummary["SharePoint"]       = @{ count = $SPSites.Count; total_storage_gb = $totalSPGB; notes = "" }
    }
    if ($ODAccounts.Count -gt 0) {
        $allWorkloads["m365_onedrive"]   = @($ODAccounts)
        $totalODGB = [math]::Round(($ODAccounts | Measure-Object StorageUsedGB -Sum).Sum, 2)
        $jsonSummary["OneDrive"]         = @{ count = $ODAccounts.Count; total_storage_gb = $totalODGB; notes = "" }
    }
    if ($Teams.Count -gt 0) {
        $allWorkloads["m365_teams"]      = @($Teams)
        $totalChannels = ($Teams | Measure-Object ChannelCount -Sum).Sum
        $jsonSummary["Teams"]            = @{ count = $Teams.Count; total_storage_gb = 0; notes = "Total channels: $totalChannels" }
    }
    if ($Groups.Count -gt 0) {
        $allWorkloads["m365_groups"]     = @($Groups)
        $jsonSummary["Groups"]           = @{ count = $Groups.Count; total_storage_gb = 0; notes = "" }
    }

    $jsonDoc = @{
        metadata = @{
            cloud          = "m365"
            tenant_id      = $TenantId
            generated_at   = (Get-Date -Format "o")
            script_version = "2.0"
        }
        summary   = $jsonSummary
        workloads = $allWorkloads
    }

    $jsonPath = Join-Path $outDir ("m365_sizing_" + $dateStr + ".json")
    $jsonDoc | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8
    Write-Host "  m365_sizing_$dateStr.json" -ForegroundColor Cyan
}

# ---------------------------------------------------------------
# ZIP archive
# ---------------------------------------------------------------
Stop-Transcript

$zipFile = Join-Path $PWD ("m365_sizing_" + $dateStr + ".zip")
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($outDir, $zipFile)

Remove-Item -Path $outDir -Recurse -Force

Write-Host "`nInventory complete. Results in $zipFile" -ForegroundColor Green
if ($OutputFormat -eq "json" -or $OutputFormat -eq "both") {
    Write-Host "JSON sizing report (m365_sizing_$dateStr.json) included in ZIP for Sales AI Hub upload." -ForegroundColor Cyan
}
Write-Host "Provide the ZIP file to your Commvault representative." -ForegroundColor Cyan

Disconnect-MgGraph -ErrorAction SilentlyContinue
