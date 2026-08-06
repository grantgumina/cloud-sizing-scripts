#requires -Version 7.2
<#
    Tests for the per-resource resilience gap report (New-CVGapRow / Sort-CVGapRows in
    src/common/CVSizing.Resilience.ps1). No cloud SDKs required.

    What this file replaced and why:
      - <cloud>_resilience_controls_*.csv was a static legend, identical on every run. It described the checks,
        never the estate.
      - <cloud>_resilience_gaps_*.csv was one row PER CONTROL with a count, so it could tell you the estate's
        worst control but never which resources to go look at.
    The gap report is one row per RESOURCE, carrying identity, data at risk, severity-weighted rank, and how
    much of the assessment was actually possible.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Console.ps1')     # Export-CVCsv (round-trip assertions)
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.ps1')

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }

$ctl = @(
    New-CVControl -Id 'r-backup'  -Title 'Managed backup'     -Category RecoveryReady -Severity Critical -Test { param($r) Get-CVTri $r.Backup }
    New-CVControl -Id 'r-xregion' -Title 'Secondary region'   -Category Availability  -Severity High     -Test { param($r) Get-CVTri $r.XRegion }
    New-CVControl -Id 'r-cmk'     -Title 'CMK encryption'     -Category DataExposure  -Severity Medium   -Test { param($r) Get-CVTri $r.Cmk }
)
$map = @{ Name = 'VMName'; SizeGB = 'VMDiskSizeGB' }
function New-Row { param($Name,$Backup,$XRegion,$Cmk,$Size=100,$Rg='RG-A',$Sub='IT Prod',$Id=$null)
    [pscustomobject]@{ Subscription=$Sub; ResourceGroup=$Rg; Region='eastus'; VMName=$Name
                       VMDiskSizeGB=$Size; ResourceId=$Id; Backup=$Backup; XRegion=$XRegion; Cmk=$Cmk } }
function Get-Gap { param($Row) New-CVGapRow -Resource $Row -ResourceType 'VM' -Evaluation (Invoke-CVResilience -Resource $Row -Controls $ctl) -FieldMap $map }

Write-Host "`n[1] A fully compliant, fully assessed resource produces NO row"
Assert-CV 'all Met -> null' ($null -eq (Get-Gap (New-Row -Name 'good01' -Backup $true -XRegion $true -Cmk $true))) $true

Write-Host "`n[2] A resource with gaps produces one row carrying identity and materiality"
$r = Get-Gap (New-Row -Name 'sql01' -Backup $false -XRegion $false -Cmk $true -Size 2048 -Id '/subscriptions/s/resourceGroups/RG-A/providers/Microsoft.Compute/virtualMachines/sql01')
Assert-CV 'Scope from Subscription'  $r.Scope 'IT Prod'
Assert-CV 'ResourceGroup'            $r.ResourceGroup 'RG-A'
Assert-CV 'ResourceType'             $r.ResourceType 'VM'
Assert-CV 'ResourceName from map'    $r.ResourceName 'sql01'
Assert-CV 'Region'                   $r.Region 'eastus'
Assert-CV 'ResourceId (ARM id)'      $r.ResourceId '/subscriptions/s/resourceGroups/RG-A/providers/Microsoft.Compute/virtualMachines/sql01'
Assert-CV 'SizeGB'                   $r.SizeGB 2048
Assert-CV 'SizeTB derived'           $r.SizeTB 2.048
Assert-CV 'Status = Gap'             $r.Status 'Gap'

Write-Host "`n[3] Severity rollups (counts only - no score or weight column)"
Assert-CV 'GapCount'        $r.GapCount 2
Assert-CV 'CriticalGaps'    $r.CriticalGaps 1
Assert-CV 'HighGaps'        $r.HighGaps 1
Assert-CV 'MediumGaps'      $r.MediumGaps 0
Assert-CV 'WorstSeverity'   $r.WorstSeverity 'Critical'
# Scoring belongs to the backend, so the report must not publish a competing number.
Assert-CV 'no RiskWeight column'      ($null -eq $r.PSObject.Properties['RiskWeight']) $true
Assert-CV 'no ResilienceScore column' ($null -eq $r.PSObject.Properties['ResilienceScore']) $true
Assert-CV 'GapCategories'   $r.GapCategories 'Availability; RecoveryReady'
Assert-CV 'GapTitles human' $r.GapTitles 'Managed backup; Secondary region'

Write-Host "`n[3b] One column per control, three-valued"
# True = gap found. False = checked and clean. BLANK = not checked / not applicable.
# Unknown must never render as False - that would assert "no gap here" about a control we never evaluated.
Assert-CV 'Gap_r-backup True (failed)'      $r.'Gap_r-backup' $true
Assert-CV 'Gap_r-xregion True (failed)'     $r.'Gap_r-xregion' $true
Assert-CV 'Gap_r-cmk False (passed)'        $r.'Gap_r-cmk' $false
Assert-CV 'GapIds column removed'           ($null -eq $r.PSObject.Properties['GapIds']) $true
$mixed = Get-Gap (New-Row -Name 'mix02' -Backup $false -XRegion $null -Cmk $true)
Assert-CV 'gap    -> True'          $mixed.'Gap_r-backup' $true
Assert-CV 'met    -> False'         $mixed.'Gap_r-cmk' $false
Assert-CV 'unknown-> blank not False' ($null -eq $mixed.'Gap_r-xregion') $true
# The distinction has to survive the CSV round-trip, not just the object.
$tmp = [IO.Path]::Combine([IO.Path]::GetTempPath(), "gapcols-$([guid]::NewGuid().ToString('N').Substring(0,8)).csv")
@($mixed) | Export-CVCsv -Path $tmp -PreferredOrder (Get-CVGapReportColumns)
$rt = Import-Csv $tmp
Assert-CV 'CSV: gap is "True"'      $rt[0].'Gap_r-backup' 'True'
Assert-CV 'CSV: met is "False"'     $rt[0].'Gap_r-cmk' 'False'
Assert-CV 'CSV: unknown is empty'   ([string]::IsNullOrEmpty($rt[0].'Gap_r-xregion')) $true
Remove-Item $tmp -Force -ErrorAction SilentlyContinue

Write-Host "`n[4] Confidence columns separate 'is a gap' from 'could not check'"
Assert-CV 'UnassessedControls 0'  $r.UnassessedControls 0
Assert-CV 'AssessedControls 3'    $r.AssessedControls 3
Assert-CV 'AssessmentComplete'    $r.AssessmentComplete $true
# One gap plus two unknowns is a materially weaker claim - the row has to say so.
$partial = Get-Gap (New-Row -Name 'mix01' -Backup $false -XRegion $null -Cmk $null)
Assert-CV 'partial: Status'             $partial.Status 'Gap'
Assert-CV 'partial: UnassessedControls 2' $partial.UnassessedControls 2
Assert-CV 'partial: AssessedControls 1'   $partial.AssessedControls 1
Assert-CV 'partial: not complete'       $partial.AssessmentComplete $false

Write-Host "`n[5] A resource nothing could be assessed on is included as NotAssessed"
$na = Get-Gap (New-Row -Name 'dev01' -Backup $null -XRegion $null -Cmk $null)
Assert-CV 'NotAssessed row exists'   ($null -ne $na) $true
Assert-CV 'Status = NotAssessed'     $na.Status 'NotAssessed'
Assert-CV 'contributes no gaps'      $na.GapCount 0
Assert-CV 'UnassessedControls 3'     $na.UnassessedControls 3
# The whole point: every control column blank, none of them False.
Assert-CV 'all-unknown -> Gap_r-backup blank'  ($null -eq $na.'Gap_r-backup') $true
Assert-CV 'all-unknown -> Gap_r-xregion blank' ($null -eq $na.'Gap_r-xregion') $true
Assert-CV 'all-unknown -> Gap_r-cmk blank'     ($null -eq $na.'Gap_r-cmk') $true
$falses = @($na.PSObject.Properties | Where-Object { $_.Name -like 'Gap_*' -and $_.Value -eq $false }).Count
Assert-CV 'no control reported as clean'       $falses 0

Write-Host "`n[6] Unmeasured size stays blank - a resource we could not size is not a small one"
$nosize = Get-Gap (New-Row -Name 'nos01' -Backup $false -XRegion $true -Cmk $true -Size $null)
Assert-CV 'SizeGB null not 0'  ($null -eq $nosize.SizeGB) $true
Assert-CV 'SizeTB null not 0'  ($null -eq $nosize.SizeTB) $true
$bad = Get-Gap (New-Row -Name 'bad01' -Backup $false -XRegion $true -Cmk $true -Size 'N/A')
Assert-CV 'non-numeric size -> null' ($null -eq $bad.SizeGB) $true

Write-Host "`n[7] Field-name variation across resource types is absorbed"
# Cosmos uses Location not Region; MySQL/Cosmos use ResourceGroupName; ids appear as Id / Arn / SelfLink.
$cosmos = [pscustomobject]@{ Subscription='IT Prod'; ResourceGroupName='RG-C'; Location='westus'; Name='cos01'
                             Id='/subscriptions/s/../cos01'; DataUsageGB=5; Backup=$false; XRegion=$true; Cmk=$true }
$cr = New-CVGapRow -Resource $cosmos -ResourceType 'Cosmos' -Evaluation (Invoke-CVResilience -Resource $cosmos -Controls $ctl) -FieldMap @{ Name='Name'; SizeGB='DataUsageGB' }
Assert-CV 'ResourceGroupName probed' $cr.ResourceGroup 'RG-C'
Assert-CV 'Location probed as Region' $cr.Region 'westus'
Assert-CV 'Id probed as ResourceId'   $cr.ResourceId '/subscriptions/s/../cos01'
$aws = [pscustomobject]@{ AwsAccountId='1234'; Region='us-east-1'; InstanceId='i-abc'
                          Arn='arn:aws:ec2:us-east-1:1234:instance/i-abc'; SizeGB=50; Backup=$false; XRegion=$true; Cmk=$true }
$ar = New-CVGapRow -Resource $aws -ResourceType 'EC2' -Evaluation (Invoke-CVResilience -Resource $aws -Controls $ctl) -FieldMap @{ Name='InstanceId'; SizeGB='SizeGB' }
Assert-CV 'AwsAccountId probed as Scope' $ar.Scope '1234'
Assert-CV 'Arn probed as ResourceId'     $ar.ResourceId 'arn:aws:ec2:us-east-1:1234:instance/i-abc'
$gcp = [pscustomobject]@{ Project='proj-1'; Region='us-central1'; VMName='gvm01'
                          SelfLink='https://www.googleapis.com/compute/v1/projects/proj-1/zones/z/instances/gvm01'
                          VMDiskSizeGB=20; Backup=$false; XRegion=$true; Cmk=$true }
$grow = New-CVGapRow -Resource $gcp -ResourceType 'VM' -Evaluation (Invoke-CVResilience -Resource $gcp -Controls $ctl) -FieldMap $map
Assert-CV 'Project probed as Scope'      $grow.Scope 'proj-1'
Assert-CV 'SelfLink probed as ResourceId' ([bool]($grow.ResourceId -like '*instances/gvm01')) $true
Assert-CV 'missing resource group -> blank, not an error' ([string]::IsNullOrEmpty("$($grow.ResourceGroup)")) $true

Write-Host "`n[8] Ranking still severity-first, derived at write time from the severity counts"
$rows = @(
    (Get-Gap (New-Row -Name 'small-critical' -Backup $false -XRegion $true  -Cmk $true  -Size 10))    # 1 Critical
    (Get-Gap (New-Row -Name 'unassessed'     -Backup $null  -XRegion $null  -Cmk $null  -Size 9999))  # nothing assessed
    (Get-Gap (New-Row -Name 'big-critical'   -Backup $false -XRegion $true  -Cmk $true  -Size 5000))  # 1 Critical
    (Get-Gap (New-Row -Name 'medium-only'    -Backup $true  -XRegion $true  -Cmk $false -Size 4000))  # 1 Medium
)
$sorted = Sort-CVGapRows -Rows $rows
Assert-CV 'biggest critical first'   $sorted[0].ResourceName 'big-critical'
Assert-CV 'then smaller critical'    $sorted[1].ResourceName 'small-critical'
Assert-CV 'then lower severity'      $sorted[2].ResourceName 'medium-only'
# A huge unassessed resource must not outrank a real finding just because it is large.
Assert-CV 'unassessed sorts last'    $sorted[3].ResourceName 'unassessed'

Write-Host "`n[9] Column contract"
$sets = @{ VM = $ctl }
$cols = Get-CVGapReportColumns -ControlSets $sets
foreach ($c in @('Scope','ResourceGroup','ResourceType','ResourceName','Region','ResourceId','SizeGB','SizeTB',
                 'Status','WorstSeverity','GapCount','AssessedControls','UnassessedControls','AssessmentComplete')) {
    Assert-CV "column '$c' declared" ([bool]($cols -contains $c)) $true
}
foreach ($gone in @('GapIds','RiskWeight','ResilienceScore')) {
    Assert-CV "'$gone' no longer declared" ([bool]($cols -contains $gone)) $false
}
foreach ($c in @('Gap_r-backup','Gap_r-xregion','Gap_r-cmk')) {
    Assert-CV "control column '$c' declared" ([bool]($cols -contains $c)) $true
}
Assert-CV 'Gap_* columns come after the fixed ones' ([bool]([array]::IndexOf($cols,'Gap_r-backup') -gt [array]::IndexOf($cols,'AssessmentComplete'))) $true
# The backend must be able to recompute any weighting from what IS published.
Assert-CV 'severity counts published for recomputation' ([bool](($cols -contains 'CriticalGaps') -and ($cols -contains 'HighGaps') -and ($cols -contains 'MediumGaps'))) $true
# A control shared by two resource types must not produce a duplicate column.
$dupSets = @{ VM = $ctl; Disk = $ctl }
$dupCols = Get-CVGapReportColumns -ControlSets $dupSets
Assert-CV 'shared control -> single column' (@($dupCols | Where-Object { $_ -eq 'Gap_r-backup' }).Count) 1
# Every property the builder emits must be in the declared order, or it silently lands at the end of the CSV.
$emitted = @($r.PSObject.Properties.Name)
$undeclared = @($emitted | Where-Object { $cols -notcontains $_ })
Assert-CV 'no emitted property missing from the column order' $undeclared.Count 0
if ($undeclared.Count) { Write-Host "        undeclared: $($undeclared -join ', ')" -ForegroundColor DarkYellow }

Write-Host "`n[10] Every control is documented in CYBER_RESILIENCE_REPORT.md"
# The gap report replaced the machine-readable control catalog CSV, so that document IS the legend now.
# Module lists in docs/ have silently drifted from the code three times; this stops the same thing happening
# to the control catalog, in both directions.
$repoRoot = Split-Path -Parent (Join-Path $PSScriptRoot '..' 'src')
$docPath  = Join-Path $repoRoot 'CYBER_RESILIENCE_REPORT.md'
Assert-CV 'CYBER_RESILIENCE_REPORT.md exists' (Test-Path -LiteralPath $docPath) $true
$readme   = Get-Content -Raw $docPath
$defined  = @()
foreach ($spec in @(@{c='Azure';f='Get-CVAzureResilienceControls'},
                    @{c='GCP';  f='Get-CVGcpResilienceControls'},
                    @{c='AWS';  f='Get-CVAwsResilienceControls'})) {
    . (Join-Path $repoRoot 'src' 'common' "CVSizing.Resilience.$($spec.c).ps1")
    $sets = & $spec.f
    foreach ($t in $sets.Keys) { foreach ($c in $sets[$t]) { $defined += [pscustomobject]@{ Cloud=$spec.c; Id=$c.Id; Severity=$c.Severity } } }
}
$defined = @($defined | Sort-Object Cloud, Id -Unique)
Assert-CV 'controls exist to document' ([bool]($defined.Count -gt 0)) $true

$undocumented = @($defined | Where-Object { $readme -notmatch [regex]::Escape('`' + $_.Id + '`') })
Assert-CV 'every control id appears in the doc' $undocumented.Count 0
if ($undocumented.Count) { $undocumented | ForEach-Object { Write-Host "        undocumented: $($_.Cloud) $($_.Id)" -ForegroundColor DarkYellow } }

$ids   = @($defined.Id | Sort-Object -Unique)
$inDoc = @([regex]::Matches($readme, '\|\s*`([a-z0-9]+-[a-z0-9]+)`\s*\|') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$stale = @($inDoc | Where-Object { $ids -notcontains $_ })
Assert-CV 'doc describes no control that no longer exists' $stale.Count 0
if ($stale.Count) { Write-Host "        stale: $($stale -join ', ')" -ForegroundColor DarkYellow }

# Severity drives RiskWeight and therefore the priority ordering, so a wrong severity in the docs misleads.
$sevWrong = @($defined | Where-Object { $_.Severity -eq 'Critical' -and
                $readme -notmatch ('`' + [regex]::Escape($_.Id) + '`[^\r\n]*\*\*Critical\*\*') })
Assert-CV 'Critical controls are marked Critical in the doc' $sevWrong.Count 0
if ($sevWrong.Count) { $sevWrong | ForEach-Object { Write-Host "        severity not shown: $($_.Cloud) $($_.Id)" -ForegroundColor DarkYellow } }

Write-Host ("`n======  {0} passed, {1} failed  ======`n" -f $script:Pass, $script:Fail) `
           -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
