#requires -Version 7.2
<#
    Environment / engine-compatibility tests.

    These do NOT test our logic - they test that the PowerShell runtime under foot still behaves the way the
    sizing scripts assume. That distinction earns them their own file: a green run here means "the collection
    idioms the scripts are built on are safe on this pwsh", and a red run means "do not trust a customer run
    from this machine", regardless of whether any of our code changed.

    Why this exists: on PowerShell 7.6.3 / .NET 10.0.9, `@($list)` over a System.Collections.Generic.List[object]
    throws `ArgumentException: Argument types do not match` from the engine's own binder
    (PSToObjectArrayBinder.Bind -> PSEnumerableBinder.MaybeDebase -> Expression.Condition). Every collection the
    scripts accumulate into used to be a List[object], and every one of them is wrapped in @() somewhere, so a
    routine pwsh upgrade silently killed the resilience report mid-run and reported it as a one-line warning.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Console.ps1')

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }
function Assert-NoThrow { param([string]$Name, [scriptblock]$Script)
    try { & $Script | Out-Null; $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    catch { $script:Fail++; Write-Host "  FAIL  $Name -> $($_.Exception.GetType().Name): $($_.Exception.Message)" -ForegroundColor Red } }

Write-Host "`n[0] Runtime under test"
Write-Host ("  pwsh {0} / .NET {1} / {2}" -f $PSVersionTable.PSVersion, [System.Environment]::Version, $PSVersionTable.Platform)

Write-Host "`n[1] @() over every collection type the scripts accumulate into"
# The scripts standardized on List[psobject] specifically because List[object] is broken here. If a future
# runtime breaks psobject too, this fails loudly in CI instead of silently in front of a customer.
foreach ($t in 'psobject','string','int','hashtable','pscustomobject','double') {
    Assert-NoThrow "@() over an empty List[$t]"     { $l = New-Object "System.Collections.Generic.List[$t]"; ,@($l) }
}
Assert-NoThrow '@() over a populated List[psobject]' {
    $l = New-Object System.Collections.Generic.List[psobject]; $l.Add([pscustomobject]@{A=1}); $l.Add([pscustomobject]@{A=2}); ,@($l) }
Assert-NoThrow '@() over a ConcurrentBag[object]'    { ,@((New-Object System.Collections.Concurrent.ConcurrentBag[object])) }
Assert-NoThrow '@() over a ConcurrentQueue[string]'  { ,@((New-Object System.Collections.Concurrent.ConcurrentQueue[string])) }
Assert-NoThrow '@() over a List[psobject] held in a hashtable' {
    $h = @{ K = (New-Object System.Collections.Generic.List[psobject]) }; ,@($h.K) }

Write-Host "`n[2] No List[object] survives in src/ (the type that breaks @() on this runtime)"
$srcRoot  = Join-Path $PSScriptRoot '..' 'src'
# Match the fully-qualified declaration form every real site uses, so prose in doc comments that merely names
# the broken type does not fail the check.
$offenders = @(Select-String -Path (Join-Path $srcRoot '*.ps1'),(Join-Path $srcRoot 'common' '*.ps1') `
                             -Pattern 'System\.Collections\.Generic\.List\[object\]' -ErrorAction SilentlyContinue)
Assert-CV 'zero List[object] declarations in src/' $offenders.Count 0
if ($offenders.Count) { $offenders | ForEach-Object { Write-Host ("        {0}:{1}" -f (Split-Path $_.Path -Leaf), $_.LineNumber) -ForegroundColor DarkYellow } }

Write-Host "`n[3] Get-CVRunspaceResult unwraps a runspace output collection"
# The real defect: EndInvoke returns a PSDataCollection, and reading .VMs off it member-enumerates - which
# yields $null when the property is an EMPTY array, so `$acc += $result.VMs` appended a phantom null row.
$ps = [PowerShell]::Create().AddScript({ [pscustomobject]@{ Project='p1'; VMs=@(); Disks=@([pscustomobject]@{D=1}) } })
$raw = $ps.Invoke()
$ps.Dispose()
Assert-CV 'raw collection member-enumerates empty prop to null' ($null -eq $raw.VMs) $true
$unwrapped = Get-CVRunspaceResult $raw
Assert-CV 'unwrapped .Project'              $unwrapped.Project 'p1'
Assert-CV 'unwrapped empty prop stays array' ($null -eq $unwrapped.VMs) $false
Assert-CV 'unwrapped empty prop count = 0'   @($unwrapped.VMs).Count 0
Assert-CV 'unwrapped populated prop count=1' @($unwrapped.Disks).Count 1
Assert-CV 'null input -> null'               ($null -eq (Get-CVRunspaceResult $null)) $true

Write-Host "`n[4] ConvertTo-CVItemArray never appends a phantom element"
$acc = @(); $acc += ConvertTo-CVItemArray $null;                 Assert-CV 'accumulate null      -> 0' $acc.Count 0
$acc = @(); $acc += ConvertTo-CVItemArray @();                   Assert-CV 'accumulate empty     -> 0' $acc.Count 0
$acc = @(); $acc += ConvertTo-CVItemArray @($null,$null);        Assert-CV 'accumulate all-null  -> 0' $acc.Count 0
$acc = @(); $acc += ConvertTo-CVItemArray @(1,$null,2);          Assert-CV 'accumulate mixed     -> 2' $acc.Count 2
$acc = @(); $acc += ConvertTo-CVItemArray (New-Object System.Collections.Generic.List[psobject])
Assert-CV 'accumulate empty List -> 0' $acc.Count 0
# End-to-end: six projects that each find nothing must total zero, not six.
$acc = @(); 1..6 | ForEach-Object { $acc += ConvertTo-CVItemArray @() }
Assert-CV 'six empty projects -> 0 rows (no phantom count)' $acc.Count 0

Write-Host "`n[5] Type resolution without sweeping loaded assemblies"
# GetTypes() over every loaded assembly throws ReflectionTypeLoadException whenever any assembly has an
# unresolvable member - routine when hosted (VS Code PowerShell extension, Az modules).
Assert-NoThrow "resolve a missing type by name" { ('DefinitelyNotARealType_CV' -as [type]) }
Assert-CV 'missing type resolves to null' ($null -eq ('DefinitelyNotARealType_CV' -as [type])) $true
Assert-CV 'known type resolves'           ($null -ne ('System.String' -as [type]))             $true

Write-Host "`n[6] Automatic variables the scripts must not shadow"
# $IsWindows is read-only in PowerShell Core; assigning to it throws and leaves the local unset.
$threw = $false
try { Set-Variable -Name IsWindows -Value $false -ErrorAction Stop } catch { $threw = $true }
Assert-CV '$IsWindows is read-only (scripts must use their own name)' $threw $true
$srcHits = @(Select-String -Path (Join-Path $srcRoot '*.ps1'),(Join-Path $srcRoot 'common' '*.ps1') `
                           -Pattern '^\s*\$isWindows\s*=' -ErrorAction SilentlyContinue)
Assert-CV 'no script assigns to $isWindows' $srcHits.Count 0

Write-Host "`n[7] Portability guards over src/"
$allSrc = @((Join-Path $srcRoot '*.ps1'), (Join-Path $srcRoot 'common' '*.ps1'))
# A literal /tmp or C:\ path breaks on the other platform. Temp must come from [IO.Path]::GetTempPath().
$tmpHits = @(Select-String -Path $allSrc -Pattern "(?<!GetTempPath\(\)[^\r\n]{0,40})['`"](/tmp/|C:\\\\)" -ErrorAction SilentlyContinue |
                Where-Object { $_.Line -notmatch '^\s*#' })
Assert-CV 'no hardcoded /tmp or C:\ paths in src/' $tmpHits.Count 0
if ($tmpHits.Count) { $tmpHits | ForEach-Object { Write-Host ("        {0}:{1}" -f (Split-Path $_.Path -Leaf), $_.LineNumber) -ForegroundColor DarkYellow } }
# $env:USERPROFILE is null off Windows. Checked per FILE, not per line: the fallback is legitimately written
# across lines (`} elseif ($env:HOME) {` / `elseif ($env:USERPROFILE) {`). Comments are excluded so a note
# explaining the hazard does not fail the check.
$upOffenders = @()
foreach ($f in (Get-ChildItem -Path $allSrc -ErrorAction SilentlyContinue)) {
    $code = @(Get-Content $f.FullName | Where-Object { $_ -notmatch '^\s*#' })
    if (($code -match '\$env:USERPROFILE') -and -not ($code -match '\$env:HOME')) { $upOffenders += $f.Name }
}
Assert-CV 'every file using $env:USERPROFILE also handles $env:HOME' $upOffenders.Count 0
if ($upOffenders.Count) { $upOffenders | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkYellow } }
# Every cloud script must guard its dot-sources, or a missing common/ cascades instead of failing clearly.
foreach ($f in @('CVAzureCloudSizingScript.ps1','CVAWSCloudSizingScript.ps1','CVGoogleCloudSizingScript.ps1','CVM365SizingScript.ps1')) {
    $body = Get-Content -Raw (Join-Path $srcRoot $f)
    Assert-CV "$f guards its dot-sources" ([bool]($body -match '\$cvMissing\s*=' -and $body -match 'Test-Path -LiteralPath \(Join-Path \$cvCommonDir')) $true
}

Write-Host "`n[8] Output root is deterministic, not CWD-derived"
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Console.ps1')
$noRepo = Join-Path ([IO.Path]::GetTempPath()) ("cv-norepo-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $noRepo -Force | Out-Null
try {
    Push-Location ([IO.Path]::GetTempPath())
    # The defect: this used to return the CWD and discard $StartPath entirely.
    Assert-CV 'Get-CVBaseRoot honors -StartPath outside a repo' (Get-CVBaseRoot -StartPath $noRepo) $noRepo
    Pop-Location
    $rp = Initialize-CVRunPaths -Cloud 'Test' -TimeStamp '20260806_000000' -StartPath $noRepo -OutputRoot $noRepo
    Assert-CV '-OutputRoot wins'          $rp.Root $noRepo
    Assert-CV 'run dir under Output/'     ([bool]($rp.OutputDir -like (Join-Path (Join-Path $noRepo 'Output') '*'))) $true
} finally { Remove-Item -LiteralPath $noRepo -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host "`n[9] kubectl provisioning resolves os/arch instead of assuming linux-amd64"
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Kubectl.ps1')
$p1 = Get-CVKubectlPlatform -OS windows -Architecture amd64
Assert-CV 'windows-amd64 url'  $p1.UrlPath 'bin/windows/amd64/kubectl.exe'
$p2 = Get-CVKubectlPlatform -OS linux -Architecture amd64
Assert-CV 'linux-amd64 url'    $p2.UrlPath 'bin/linux/amd64/kubectl'
# The old code shipped this host a Linux amd64 binary regardless.
$p3 = Get-CVKubectlPlatform -OS darwin -Architecture arm64
Assert-CV 'darwin-arm64 url'   $p3.UrlPath 'bin/darwin/arm64/kubectl'
Assert-CV 'temp dir is not literal /tmp' ([bool]((Get-CVKubectlInstallDir) -notmatch '^/tmp/')) $true
$live = Get-CVKubectlPlatform
Assert-CV 'live platform detected' ([bool]($live.OS -in @('windows','darwin','linux'))) $true

Write-Host "`n[10] Module lists agree across script, README, docs and Dockerfile"
# These have drifted three times: docs/Azure.md and Dockerfile.azure both omitted Az.Network (fatal), and
# docs/AWS.md omitted AWS.Tools.ResourceGroupsTaggingAPI (fatal). A stale list is an unrunnable script.
$repoRoot = Split-Path -Parent $srcRoot
function Get-CVFatalModuleNames {
    param([string]$ScriptPath, [string]$Pattern)
    $body = Get-Content -Raw $ScriptPath
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($m in [regex]::Matches($body, $Pattern)) { [void]$names.Add($m.Groups[1].Value) }
    return @($names)
}
$azNeeded  = Get-CVFatalModuleNames (Join-Path $srcRoot 'CVAzureCloudSizingScript.ps1')  "'(Az\.[A-Za-z]+)'"
$awsNeeded = Get-CVFatalModuleNames (Join-Path $srcRoot 'CVAWSCloudSizingScript.ps1')    "'(AWS\.Tools\.[A-Za-z0-9]+)'"
$azDoc     = Get-Content -Raw (Join-Path $repoRoot 'docs' 'Azure.md')
$awsDoc    = Get-Content -Raw (Join-Path $repoRoot 'docs' 'AWS.md')
$azDocker  = Get-Content -Raw (Join-Path $repoRoot 'k8s' 'Dockerfile.azure')
$readme    = Get-Content -Raw (Join-Path $repoRoot 'README.md')
$azMissDoc    = @($azNeeded  | Where-Object { $azDoc    -notmatch [regex]::Escape($_) })
$azMissDocker = @($azNeeded  | Where-Object { $azDocker -notmatch [regex]::Escape($_) })
$awsMissDoc   = @($awsNeeded | Where-Object { $awsDoc   -notmatch [regex]::Escape($_) })
$azMissReadme = @($azNeeded  | Where-Object { $readme   -notmatch [regex]::Escape($_) })
Assert-CV 'docs/Azure.md lists every fatal Az module'      $azMissDoc.Count 0
Assert-CV 'Dockerfile.azure installs every fatal Az module' $azMissDocker.Count 0
Assert-CV 'docs/AWS.md lists every fatal AWS.Tools module'  $awsMissDoc.Count 0
Assert-CV 'README.md lists every fatal Az module'           $azMissReadme.Count 0
foreach ($pair in @(@{n='docs/Azure.md';v=$azMissDoc}, @{n='Dockerfile.azure';v=$azMissDocker}, @{n='docs/AWS.md';v=$awsMissDoc}, @{n='README.md';v=$azMissReadme})) {
    if ($pair.v.Count) { Write-Host ("        {0} missing: {1}" -f $pair.n, ($pair.v -join ', ')) -ForegroundColor DarkYellow }
}

Write-Host ("`n======  {0} passed, {1} failed  ======`n" -f $script:Pass, $script:Fail) `
           -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
