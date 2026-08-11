#requires -Version 7.2
<#
    Tests for the per-resource resilience SIGNAL export (New-CVSignalRow / Get-CVSignalColumns /
    Sort-CVSignalRows in src/common/CVSizing.Resilience.ps1). No cloud SDKs required.

    History, because the invariants below are reactions to real defects:
      - <cloud>_resilience_controls_*.csv was a static legend, identical every run - it described the checks, never
        the estate. Deleted.
      - <cloud>_resilience_gaps_*.csv was one row PER CONTROL with a count, so it named the estate's worst control
        but never which resources to look at. Then it became one row per resource with Gap_<id> = True/False/blank.
      - That still threw data away: Gap_st-xregion = False discarded 'Standard_RAGRS', so no consumer could tell
        RA-GRS from GRS from GZRS or re-decide what counts as geo-redundant.
    The export is now judgement-free: raw signal VALUES, no verdicts, every resource of an assessed type.
    Scoring lives on the backend.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Console.ps1')     # Export-CVCsv
. (Join-Path $PSScriptRoot '..' 'src' 'common' 'CVSizing.Resilience.ps1')

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }

$ctl = @{
    VM      = @(
        New-CVControl -Id 'v-backup'  -Title 'Backed up'   -Category RecoveryReady -Severity Critical -Test { param($r) Get-CVTri $r.BackupEnabled }
        New-CVControl -Id 'v-xregion' -Title 'Secondary'   -Category Availability  -Severity High     -Test { param($r) Get-CVTri $r.BackupCrossRegion }
    )
    Storage = @(
        # Multi-input control: raw field names handle this naturally as two columns.
        New-CVControl -Id 's-ret'     -Title 'Retention'   -Category RecoveryReady -Severity High     -Test {
            param($r) if ($null -eq $r.RetainedBackups -and $null -eq $r.TxLogDays) { return $null }
            [bool](([int]$r.RetainedBackups -ge 35) -or ([int]$r.TxLogDays -ge 35)) }
        New-CVControl -Id 's-sku'     -Title 'Geo SKU'     -Category Availability  -Severity High     -Test { param($r) Get-CVTri $r.SkuName }
    )
}
$maps = Get-CVSignalFieldMap -ControlSets $ctl
$fm   = @{ VM = @{ Name='VMName'; SizeGB='VMDiskSizeGB' }; Storage = @{ Name='AccountName'; SizeGB='UsedGB' } }

Write-Host "`n[1] Signal fields are derived from the control definitions, not hand-listed"
Assert-CV 'VM fields'      (($maps.VM      | Sort-Object) -join ',') 'BackupCrossRegion,BackupEnabled'
Assert-CV 'Storage fields' (($maps.Storage | Sort-Object) -join ',') 'RetainedBackups,SkuName,TxLogDays'
# A multi-input control contributes ALL of its inputs - the old Gap_<id> shape could only hold one value.
Assert-CV 'multi-input control yields multiple columns' ([bool](($maps.Storage -contains 'RetainedBackups') -and ($maps.Storage -contains 'TxLogDays'))) $true

Write-Host "`n[2] Values are published verbatim - no verdicts anywhere"
$vm = [pscustomobject]@{ Subscription='S1'; ResourceGroup='RG'; Region='eastus'; VMName='vm1'; VMDiskSizeGB=327
                         BackupEnabled=$false; BackupDataStatus='Ok'; SnapshotDataStatus='Failed' }
$r = New-CVSignalRow -Resource $vm -ResourceType 'VM' -SignalFields $maps.VM -FieldMap $fm.VM
Assert-CV 'raw value, not a verdict'  $r.BackupEnabled $false
Assert-CV 'identity: Scope'           $r.Scope 'S1'
Assert-CV 'identity: ResourceName'    $r.ResourceName 'vm1'
Assert-CV 'SizeGB'                    $r.SizeGB 327
Assert-CV 'SizeTB derived'            $r.SizeTB 0.327
foreach ($gone in @('Status','GapCount','RiskWeight','ResilienceScore','WorstSeverity','CriticalGaps',
                    'GapCategories','GapTitles','AssessedControls','UnassessedControls','AssessmentComplete')) {
    Assert-CV "no '$gone' column" ($null -eq $r.PSObject.Properties[$gone]) $true
}
Assert-CV 'no Gap_* columns at all' (@($r.PSObject.Properties | Where-Object { $_.Name -like 'Gap_*' }).Count) 0

Write-Host "`n[3] Collection status is kept - it explains WHY a signal is blank"
Assert-CV 'BackupDataStatus carried'   $r.BackupDataStatus 'Ok'
Assert-CV 'SnapshotDataStatus carried' $r.SnapshotDataStatus 'Failed'

Write-Host "`n[4] `$false and blank stay distinguishable"
# The entire point: 'we measured it and it is off' must not look like 'we never measured it'.
Assert-CV 'measured false is $false'   ($r.BackupEnabled -eq $false) $true
Assert-CV 'unmeasured is absent'       ($null -eq $r.PSObject.Properties['BackupCrossRegion']) $true
$csv = [IO.Path]::Combine([IO.Path]::GetTempPath(), "sig-$([guid]::NewGuid().ToString('N').Substring(0,8)).csv")
@($r) | Export-CVCsv -Path $csv -PreferredOrder (Get-CVSignalColumns -ControlSets $ctl) -KeepDeclaredColumns
$rt = Import-Csv $csv
Assert-CV 'CSV: measured false -> "False"' $rt[0].BackupEnabled 'False'
Assert-CV 'CSV: unmeasured -> empty'       ([string]::IsNullOrEmpty($rt[0].BackupCrossRegion)) $true

Write-Host "`n[5] Schema is fixed - declared columns appear even when nothing carries them"
$cols = Get-CVSignalColumns -ControlSets $ctl
Assert-CV 'identity columns first'  (($cols[0..3]) -join ',') 'Scope,ResourceGroup,ResourceType,ResourceName'
foreach ($c in @('BackupEnabled','BackupCrossRegion','RetainedBackups','TxLogDays','SkuName',
                 'BackupDataStatus','SnapshotDataStatus','ResourceId','SizeGB','SizeTB')) {
    Assert-CV "column '$c' declared" ([bool]($cols -contains $c)) $true
}
# A VM row carries none of the Storage signals, yet those columns must still be in the header.
$hdr = (Get-Content $csv)[0]
foreach ($c in @('RetainedBackups','TxLogDays','SkuName')) {
    Assert-CV "header keeps unpopulated '$c'" ([bool]($hdr -match [regex]::Escape($c))) $true
}
Assert-CV 'header column count = declared count' (($hdr -split ',').Count) $cols.Count
# Without -KeepDeclaredColumns the file narrows, which is the old gap-report behaviour - assert the switch matters.
@($r) | Export-CVCsv -Path $csv -PreferredOrder $cols
Assert-CV 'without the switch, absent columns drop' ([bool]((Get-Content $csv)[0] -notmatch 'TxLogDays')) $true
Remove-Item $csv -Force -ErrorAction SilentlyContinue

Write-Host "`n[6] Every resource gets a row - no filtering, because filtering needs a verdict"
$clean = [pscustomobject]@{ Subscription='S1'; ResourceGroup='RG'; Region='eastus'; VMName='perfect'
                            VMDiskSizeGB=10; BackupEnabled=$true; BackupCrossRegion=$true }
$cr = New-CVSignalRow -Resource $clean -ResourceType 'VM' -SignalFields $maps.VM -FieldMap $fm.VM
Assert-CV 'fully compliant resource still emitted' ($null -ne $cr) $true
$blank = [pscustomobject]@{ Subscription='S1'; ResourceGroup='RG'; Region='eastus'; VMName='unknown-all'; VMDiskSizeGB=$null }
$br = New-CVSignalRow -Resource $blank -ResourceType 'VM' -SignalFields $maps.VM -FieldMap $fm.VM
Assert-CV 'resource with no signals still emitted' ($null -ne $br) $true
Assert-CV 'unmeasured size stays blank, not 0'     ($null -eq $br.SizeGB) $true

Write-Host "`n[7] Field-name variation across clouds is absorbed"
$cos = [pscustomobject]@{ Subscription='S1'; ResourceGroupName='RG-C'; Location='westus'; AccountName='c1'
                          Id='/subscriptions/s/../c1'; UsedGB=5; SkuName='Standard_RAGRS' }
$cr2 = New-CVSignalRow -Resource $cos -ResourceType 'Storage' -SignalFields $maps.Storage -FieldMap $fm.Storage
Assert-CV 'ResourceGroupName probed' $cr2.ResourceGroup 'RG-C'
Assert-CV 'Location probed as Region' $cr2.Region 'westus'
Assert-CV 'Id probed as ResourceId'   $cr2.ResourceId '/subscriptions/s/../c1'
Assert-CV 'string signal preserved verbatim' $cr2.SkuName 'Standard_RAGRS'
$aws = [pscustomobject]@{ AwsAccountId='1234'; Region='us-east-1'; VMName='i-abc'; VMDiskSizeGB=8
                          Arn='arn:aws:ec2:us-east-1:1234:instance/i-abc'; BackupEnabled=$true }
$ar = New-CVSignalRow -Resource $aws -ResourceType 'VM' -SignalFields $maps.VM -FieldMap $fm.VM
Assert-CV 'AwsAccountId probed as Scope' $ar.Scope '1234'
Assert-CV 'Arn probed as ResourceId'     $ar.ResourceId 'arn:aws:ec2:us-east-1:1234:instance/i-abc'

Write-Host "`n[8] Ordering is deterministic and carries no judgement"
$rows = @(
    (New-CVSignalRow -Resource ([pscustomobject]@{ Subscription='S2'; VMName='b'; VMDiskSizeGB=1 })    -ResourceType 'VM'      -SignalFields $maps.VM      -FieldMap $fm.VM)
    (New-CVSignalRow -Resource ([pscustomobject]@{ Subscription='S1'; AccountName='z'; UsedGB=9999 })  -ResourceType 'Storage' -SignalFields $maps.Storage -FieldMap $fm.Storage)
    (New-CVSignalRow -Resource ([pscustomobject]@{ Subscription='S1'; VMName='a'; VMDiskSizeGB=5 })    -ResourceType 'VM'      -SignalFields $maps.VM      -FieldMap $fm.VM)
)
$sorted = Sort-CVSignalRows -Rows $rows
Assert-CV 'scope, then type, then name (1)' "$($sorted[0].Scope)/$($sorted[0].ResourceType)/$($sorted[0].ResourceName)" 'S1/Storage/z'
Assert-CV 'scope, then type, then name (2)' "$($sorted[1].Scope)/$($sorted[1].ResourceType)/$($sorted[1].ResourceName)" 'S1/VM/a'
Assert-CV 'scope, then type, then name (3)' "$($sorted[2].Scope)/$($sorted[2].ResourceType)/$($sorted[2].ResourceName)" 'S2/VM/b'

Write-Host "`n[9] Real catalogs produce a usable schema for all three clouds"
$repoRoot = Split-Path -Parent (Join-Path $PSScriptRoot '..' 'src')
foreach ($spec in @(@{c='Azure';f='Get-CVAzureResilienceControls';min=20},
                    @{c='GCP';  f='Get-CVGcpResilienceControls';  min=20},
                    @{c='AWS';  f='Get-CVAwsResilienceControls';  min=18})) {
    . (Join-Path $repoRoot 'src' 'common' "CVSizing.Resilience.$($spec.c).ps1")
    $sets = & $spec.f
    $c = Get-CVSignalColumns -ControlSets $sets
    Assert-CV "$($spec.c): schema has identity + signals" ([bool]($c.Count -ge ($spec.min + $script:CVSignalIdentityColumns.Count))) $true
    Assert-CV "$($spec.c): no duplicate columns" (($c | Group-Object | Where-Object Count -gt 1).Count) 0
    Assert-CV "$($spec.c): no Gap_ columns leaked in" (@($c | Where-Object { $_ -like 'Gap_*' }).Count) 0
}

Write-Host "`n[10] Every signal field is documented in CYBER_RESILIENCE_REPORT.md"
# The doc is now the schema reference for the backend, so an undocumented column is a real defect. The previous
# version of this guard only checked control IDs, which is why the doc could describe Gap_<id> semantics long
# after the export stopped emitting them.
$docPath = Join-Path $repoRoot 'CYBER_RESILIENCE_REPORT.md'
Assert-CV 'CYBER_RESILIENCE_REPORT.md exists' (Test-Path -LiteralPath $docPath) $true
$doc = Get-Content -Raw $docPath
$allFields = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($spec in @('Azure','GCP','AWS')) {
    . (Join-Path $repoRoot 'src' 'common' "CVSizing.Resilience.$spec.ps1")
    $sets = & $(switch ($spec) { 'Azure' {'Get-CVAzureResilienceControls'} 'GCP' {'Get-CVGcpResilienceControls'} default {'Get-CVAwsResilienceControls'} })
    foreach ($t in $sets.Keys) { foreach ($c in $sets[$t]) { foreach ($f in (Get-CVControlSignalFields -Control $c)) { [void]$allFields.Add($f) } } }
}
$undocumented = @($allFields | Where-Object { $doc -notmatch [regex]::Escape('`' + $_ + '`') })
Assert-CV 'every signal field appears in the doc' $undocumented.Count 0
if ($undocumented.Count) { Write-Host "        undocumented: $($undocumented -join ', ')" -ForegroundColor DarkYellow }
# Identity and status columns are part of the published schema too.
foreach ($c in ($script:CVSignalIdentityColumns + $script:CVSignalStatusColumns)) {
    Assert-CV "schema column '$c' documented" ([bool]($doc -match [regex]::Escape('`' + $c + '`'))) $true
}
# And the doc must not still describe the retired verdict model.
foreach ($dead in @('RiskWeight','ResilienceScore','GapCount','WorstSeverity')) {
    Assert-CV "doc no longer presents '$dead' as a column" ([bool]($doc -match ('\|\s*`' + [regex]::Escape($dead) + '`\s*\|'))) $false
}

Write-Host ("`n======  {0} passed, {1} failed  ======`n" -f $script:Pass, $script:Fail) `
           -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
