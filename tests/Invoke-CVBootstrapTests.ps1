#requires -Version 7.2
<#
    Tests that a script copied out WITHOUT src/common/ fails fast with one actionable message.

    Why: dot-sourcing a missing file is NON-terminating in PowerShell. Before the guarded preamble, an incomplete
    copy printed ~10 cascading CommandNotFoundExceptions, silently skipped Assert-CVPreflight (so module
    validation never ran), left $runPaths null, and then died mid-inventory with no output files. Users reported
    this as "the script doesn't work" - which is exactly what it looked like.

    These tests actually run each script in a temp directory with no common/ folder and assert the contract.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }

$srcRoot = Join-Path $PSScriptRoot '..' 'src'
$scripts = @('CVAzureCloudSizingScript.ps1','CVAWSCloudSizingScript.ps1','CVGoogleCloudSizingScript.ps1','CVM365SizingScript.ps1')

Write-Host "`n[1] A script with no src/common/ exits 1 and names what is missing"
foreach ($name in $scripts) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("cv-boot-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        Copy-Item -LiteralPath (Join-Path $srcRoot $name) -Destination $tmp
        $target = Join-Path $tmp $name
        # M365 has mandatory parameters; supply dummies so we reach the bootstrap check rather than a prompt.
        $argv = if ($name -eq 'CVM365SizingScript.ps1') { @('-TenantId','t','-ClientId','c') } else { @() }
        $out  = & pwsh -NoProfile -NonInteractive -File $target @argv 2>&1 | Out-String
        $code = $LASTEXITCODE

        Assert-CV "$name exits 1" $code 1
        Assert-CV "$name says the shared layer is missing" ([bool]($out -match 'shared layer')) $true
        Assert-CV "$name names CVSizing.Console.ps1"       ([bool]($out -match 'CVSizing\.Console\.ps1')) $true
        Assert-CV "$name tells the user what to do"        ([bool]($out -match 'src/common')) $true
        # The old failure mode: cascading CommandNotFoundException noise instead of one clear message.
        Assert-CV "$name does not cascade CommandNotFound" ([bool]($out -notmatch 'CommandNotFoundException')) $true
    } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host "`n[2] With common/ present the bootstrap does NOT fire"
# Guards against a preamble that lists a file the repo does not actually ship - which would make every run fail.
foreach ($name in $scripts) {
    $body = Get-Content -Raw (Join-Path $srcRoot $name)
    $listed = @()
    if ($body -match '(?s)\$cvRequired\s*=\s*@\((.*?)\)') {
        $listed = @([regex]::Matches($Matches[1], "'([^']+\.ps1)'") | ForEach-Object { $_.Groups[1].Value })
    }
    Assert-CV "$name declares its required files" ([bool]($listed.Count -gt 0)) $true
    $absent = @($listed | Where-Object { -not (Test-Path -LiteralPath (Join-Path $srcRoot 'common' $_)) })
    Assert-CV "$name requires only files that exist" $absent.Count 0
    if ($absent.Count) { Write-Host "        missing from src/common: $($absent -join ', ')" -ForegroundColor DarkYellow }
}

Write-Host ("`n======  {0} passed, {1} failed  ======`n" -f $script:Pass, $script:Fail) `
           -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
