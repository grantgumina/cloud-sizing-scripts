#requires -Version 7.2
<#
    Show-CVConsoleDemo.ps1 - Visual demo / manual verification harness for the shared console layer.

    Exercises every rendering feature so you can eyeball the polish in each tier.

    Examples:
        pwsh -File tools/Show-CVConsoleDemo.ps1                 # auto tier (Spectre if installed + TTY)
        pwsh -File tools/Show-CVConsoleDemo.ps1 -ForceRich      # force the Spectre path (falls back if absent)
        pwsh -File tools/Show-CVConsoleDemo.ps1 -NonInteractive # force the plain-headless path
        pwsh -File tools/Show-CVConsoleDemo.ps1 | cat           # headless via redirection (what a container sees)
#>
[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [switch]$Quiet,
    [switch]$ForcePlain,
    [switch]$ForceRich,
    [switch]$ShowDebug
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Console.ps1')

$log = Join-Path ([System.IO.Path]::GetTempPath()) "cvdemo_$([DateTime]::Now.ToString('yyyyMMdd_HHmmss')).log"

Initialize-CVConsole -Cloud AWS -LogPath $log -Title 'CV Cloud Sizing - Console Demo' `
    -NonInteractive:$NonInteractive -Quiet:$Quiet -ForcePlain:$ForcePlain -ForceRich:$ForceRich -ShowDebug:$ShowDebug | Out-Null

$cap = Get-CVConsoleCapability -NonInteractive:$NonInteractive -Quiet:$Quiet -ForcePlain:$ForcePlain -ForceRich:$ForceRich
Write-CVLog "Render tier: $($cap.Tier) - $($cap.Reason)" -Level Info -Source 'Demo'

Write-CVSection 'Authentication'
Write-CVLog 'Connected to account 1234-5678-9012 (prod-payments)' -Level Success -Source 'Auth'
Write-CVLog 'Region set: us-east-1, us-west-2, eu-west-1' -Level Info -Source 'Auth'

Write-CVSection 'Collection'
$services = 'EC2','S3','RDS','EFS','DynamoDB'
Start-CVProgress -Id 'main' -Activity 'Collecting AWS inventory' -Total $services.Count
foreach ($s in $services) {
    Update-CVProgress -Id 'main' -Status "Scanning $s" -Increment
    Write-CVLog "Found resources in $s" -Level Info -Source $s
    Start-Sleep -Milliseconds 250
}
Complete-CVProgress -Id 'main'

Write-CVSection 'Simulated failures (dedup demo)'
Write-CVLog 'This flood of per-region errors should collapse to ONE console line + a summary row:' -Level Info -Source 'Demo'
foreach ($r in 'us-east-1','us-west-2','eu-west-1','ap-south-1','sa-east-1','ca-central-1') {
    Write-CVLog "Failed to get ElastiCache for region $r : User is not authorized to perform elasticache:DescribeCacheClusters" `
        -Level Error -Source 'ElastiCache' -Scope @{ Region = $r }
}
Write-CVLog 'Skipping AWSBackup - required module AWS.Tools.Backup not installed' -Level Warning -Source 'AWSBackup'

Write-CVSummary -Title 'Sizing Run Summary'

Write-Host ""
Write-Host "Full detail was written to: $log"
