#requires -Version 7.2
<#  Tests for the shared Excel writer (src/common/CVSizing.Console.ps1 Export-CVExcelWorkbook) used by the
    Azure and GCP scripts. Verifies: graceful skip when ImportExcel is absent; a Summary sheet plus one detail
    sheet per type; empty types produce no sheet; shared types (FlexDB) combine; the union-of-columns projection
    keeps heterogeneous Tag_* columns; and no ImportExcel warnings leak to the host.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Console.ps1')

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }

$log = Join-Path ([System.IO.Path]::GetTempPath()) "cvxltest_$PID.log"
Initialize-CVConsole -Cloud Azure -LogPath $log -Title 't' -NonInteractive | Out-Null

# Heterogeneous rows (VMs carry different Tag_* columns); FlexDB shared across two workload keys; one empty type.
$vm1 = [pscustomobject]@{ VMName='vm1'; VMDiskSizeGB=100; backup_enabled=$true;  Tag_env='prod' }
$vm2 = [pscustomobject]@{ VMName='vm2'; VMDiskSizeGB=50;  backup_enabled=$false; Tag_owner='team' }
$my  = [pscustomobject]@{ Name='my1'; StorageGB=20 }
$pg  = [pscustomobject]@{ Name='pg1'; StorageGB=30 }
$wl = [ordered]@{
    azure_vms        = @{ Items=@($vm1,$vm2); Type='VM';     SizeField='VMDiskSizeGB' }
    azure_mysql      = @{ Items=@($my);       Type='FlexDB'; SizeField='StorageGB' }
    azure_postgresql = @{ Items=@($pg);       Type='FlexDB'; SizeField='StorageGB' }
    azure_empty      = @{ Items=@();          Type='Empty';  SizeField=$null }
}
$out = Join-Path ([System.IO.Path]::GetTempPath()) "cvxltest_$PID.xlsx"

if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    Write-Host "`n[1] ImportExcel not installed -> graceful skip (returns null)"
    Assert-CV 'returns null when ImportExcel absent' ($null -eq (Export-CVExcelWorkbook -Path $out -Workloads $wl)) $true
} else {
    Write-Host "`n[1] Workbook shape, union columns, aggregation, no leaked warnings"
    $warn = $(Export-CVExcelWorkbook -Path $out -Workloads $wl) 3>&1 2>&1
    Assert-CV 'no ImportExcel warnings leaked' (@($warn | Where-Object { "$_" -match 'WARNING|Autosize|libgdiplus' }).Count) 0
    Assert-CV 'workbook created'               (Test-Path $out) $true

    Import-Module ImportExcel -Force 3>$null
    $sheets = @((Get-ExcelSheetInfo $out).Name)
    Assert-CV 'Summary sheet is first'         $sheets[0] 'Summary'
    Assert-CV 'VM detail sheet present'        ($sheets -contains 'VM') $true
    Assert-CV 'FlexDB detail sheet present'    ($sheets -contains 'FlexDB') $true
    Assert-CV 'empty type -> no sheet'         ($sheets -contains 'Empty') $false

    $vmCols = @(Import-Excel -Path $out -WorksheetName 'VM')[0].PSObject.Properties.Name
    Assert-CV 'union keeps Tag_env'            ($vmCols -contains 'Tag_env') $true
    Assert-CV 'union keeps Tag_owner'          ($vmCols -contains 'Tag_owner') $true
    Assert-CV 'FlexDB combined -> 2 rows'      (@(Import-Excel -Path $out -WorksheetName 'FlexDB').Count) 2

    $flex = @(@(Import-Excel -Path $out -WorksheetName 'Summary') | Where-Object { $_.Service -eq 'FlexDB' })
    Assert-CV 'summary aggregates FlexDB to 1 row' $flex.Count 1
    Assert-CV 'summary FlexDB count = 2'           ([int]$flex[0].Count) 2
    Assert-CV 'summary FlexDB total GB = 50'       ([double]$flex[0].TotalSizeGB) 50
}
Remove-Item $out, $log -Force -ErrorAction SilentlyContinue

Write-Host ("`n======  {0} passed, {1} failed  ======`n" -f $script:Pass, $script:Fail) `
           -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
