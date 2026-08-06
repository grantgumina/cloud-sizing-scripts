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

Write-Host ("`n======  {0} passed, {1} failed  ======`n" -f $script:Pass, $script:Fail) `
           -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
