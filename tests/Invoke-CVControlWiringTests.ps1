#requires -Version 7.2
<#
    Invoke-CVControlWiringTests.ps1 - Are the resilience controls actually WIRED to collected data?

    A control whose Test reads a field that no inventory row ever sets can never return Met or Gap. It returns
    Unknown on every resource in every environment, forever - silently. Nothing else in the suite catches that,
    because the control is syntactically fine, the engine handles it correctly, and Unknown is a legitimate
    outcome. It only shows up as a permanently blank column in the customer's report.

    This was not hypothetical. Found in the field:
      - Azure vm-xregion / vm-immutable read BackupCrossRegion / BackupImmutable: never set. An SE reported that
        "only enrollment in Recovery Services is being evaluated" for Azure VMs. They were right.
      - Azure st-immutable read ImmutabilityLocked: never set.
      - AWS rs-retention read AutomatedSnapshotRetentionPeriod, but the row carries ...RetentionDays.
      - Azure cos-pitr / cos-xregion / db-xregion / fx-xregion read invented field names.
    18 of 79 controls were dead. The five name mismatches are fixed; the rest are tracked in the allow-list below
    with a reason, so the count can only go DOWN without a deliberate edit.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Join-Path $PSScriptRoot '..' 'src')
. (Join-Path $repoRoot 'src' 'common' 'CVSizing.Resilience.ps1')
. (Join-Path $PSScriptRoot 'CVTestControlEvaluator.ps1')   # control Tests are not executed in production

$script:Pass = 0; $script:Fail = 0
function Assert-CV { param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") { $script:Pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $Name (expected '$Expected', got '$Actual')" -ForegroundColor Red } }

<#
    KNOWN-UNWIRED controls: the signal is genuinely not collected yet (it needs an API call the scripts do not
    make), as opposed to a field-name typo. Each is listed with what it would take. Removing an entry from this
    list is how you record that a signal is now collected; ADDING one should be a deliberate decision, because a
    control that cannot be evaluated inflates UnassessedControls and makes the report look broken.
#>
$script:KnownUnwired = @{
    # Every Azure entry that used to live here is now collected - vault immutability and cross-region restore
    # from the vault posture read, deletion protection from resource locks, AKS KMS from SecurityProfile, AKS
    # backup from DataProtection backup instances, and Azure Files backup by attributing items already collected
    # to the individual share. Only GCP entries remain.
    'GCP/pd-schedule'     = 'needs gcloud compute disks describe -> resourcePolicies (snapshot schedules)'
    'GCP/pd-nodelete'     = 'needs the instance attachment autoDelete flag'
    'GCP/fs-xregion'      = 'needs Filestore backup location vs instance location comparison'
    'GCP/gke-xregion'     = 'needs Backup for GKE backup-plan region'
    'GCP/gke-secretenc'   = 'needs GKE databaseEncryption (CMEK) from cluster describe'
    'GCP/vm-backup'       = 'needs resourcePolicies (snapshot schedule) - distinct from snapshots merely existing'
    'GCP/vm-immutable'    = 'needs snapshot/vault immutability, which GCP does not expose per-disk today'
}

# Every file that could populate a field on an inventory row. The control definitions themselves are excluded -
# they READ fields, and counting a control's own reference as "set" would defeat the whole check.
$srcFiles = @(Get-ChildItem -Path (Join-Path $repoRoot 'src') -Recurse -Filter *.ps1 |
                Where-Object { $_.Name -notlike 'CVSizing.Resilience.*' })

<#
    PER-CLOUD, not one concatenated blob. A single $srcText made a field count as wired for EVERY cloud the
    moment ANY cloud set it, so every field name shared between clouds - CmkEncrypted, SoftDeleteEnabled,
    HasBackup, EncryptedAtRest, PublicAccessBlocked, HasBackupPlan - was untested in at least one of them.

    That was not hypothetical: HasBackupPlan is set only in CVGoogleCloudSizingScript.ps1, yet Azure/aks-backup
    passed this check and was absent from the allow-list, so Azure AKS backup coverage silently shipped blank
    while CYBER_RESILIENCE_SIGNALS.md claimed it was collected.

    A cloud sees: its own cloud script, the shared commons that any cloud can enrich rows through, and its own
    per-cloud helpers - but never another cloud's script or helpers.
#>
$script:CVAgnosticCommons = @('CVSizing.Console.ps1', 'CVSizing.CloudRewind.ps1', 'CVSizing.Kubectl.ps1')
$script:CVCloudScript     = @{ Azure = 'CVAzureCloudSizingScript.ps1'
                              AWS   = 'CVAWSCloudSizingScript.ps1'
                              GCP   = 'CVGoogleCloudSizingScript.ps1' }

$script:CVCloudText = @{}
foreach ($cloud in $script:CVCloudScript.Keys) {
    $files = @($srcFiles | Where-Object {
        $_.Name -eq $script:CVCloudScript[$cloud] -or
        $_.Name -in $script:CVAgnosticCommons -or
        $_.Name -like "*.$cloud.ps1"
    })
    $script:CVCloudText[$cloud] = ($files | ForEach-Object { Get-Content -Raw $_.FullName }) -join "`n"
}
# Guard the split itself: a typo in the filters would silently produce empty text and pass everything.
foreach ($cloud in @('Azure','AWS','GCP')) {
    Assert-CV "per-cloud source text built for $cloud" ([bool]($script:CVCloudText[$cloud].Length -gt 10000)) $true
}
# Prove the isolation is real. HasBackupPlan was the field that exposed the leak, but Azure now collects it, so
# the isolation proof uses XRegionBackup - a GCP-only field with no Azure equivalent.
Assert-CV 'GCP sees XRegionBackup'              ([bool]($script:CVCloudText['GCP']   -match 'XRegionBackup')) $true
Assert-CV 'Azure does NOT see it (leak closed)' ([bool]($script:CVCloudText['Azure'] -match 'XRegionBackup')) $false

function Test-CVFieldIsPopulated {
    <#
      .SYNOPSIS  Does anything outside the control definitions assign this property name, IN THIS CLOUD?
      .PARAMETER Cloud  Azure | AWS | GCP. Required: a global search is what let a GCP-only field mark an
                        Azure control as wired.
    #>
    param([string]$Field, [Parameter(Mandatory)][ValidateSet('Azure','AWS','GCP')][string]$Cloud)
    $srcText = $script:CVCloudText[$Cloud]
    $e = [regex]::Escape($Field)
    return  ($srcText -match "\b$e\s*=")               -or   # Field = value            (bare hashtable key)
            ($srcText -match "[""']$e[""']\s*=")        -or   # "Field" = value          (quoted hashtable key)
            ($srcText -match "\.Add\(\s*[""']$e[""']")  -or   # .Add("Field", value)
            ($srcText -match "-NotePropertyName\s+$e\b")-or   # Add-Member -NotePropertyName Field
            ($srcText -match "\[\s*[""']$e[""']\s*\]")        # $obj["Field"] = value
}

Write-Host "`n[0] Detector sanity - it must find real assignments and miss absent ones"
# Guard the guard: a broken detector would silently pass everything.
Assert-CV 'finds a bare hashtable key'   (Test-CVFieldIsPopulated 'BackupEnabled'           -Cloud Azure) $true
Assert-CV 'finds an .Add() key'          (Test-CVFieldIsPopulated 'BackupStorageRedundancy' -Cloud Azure) $true
Assert-CV 'finds a quoted hashtable key' (Test-CVFieldIsPopulated 'BackupPolicyBackupType'  -Cloud Azure) $true
Assert-CV 'finds an Add-Member field'    (Test-CVFieldIsPopulated 'XRegionBackup'           -Cloud GCP)   $true
Assert-CV 'misses a field nobody sets'   (Test-CVFieldIsPopulated 'TotallyFakeFieldXyz'     -Cloud Azure) $false
# The isolation itself, at the detector level: GCP sets XRegionBackup, Azure has no equivalent.
Assert-CV 'GCP: XRegionBackup populated'       (Test-CVFieldIsPopulated 'XRegionBackup' -Cloud GCP)   $true
Assert-CV 'Azure: XRegionBackup NOT populated' (Test-CVFieldIsPopulated 'XRegionBackup' -Cloud Azure) $false
# HasBackupPlan is now populated by BOTH clouds - Azure via DataProtection backup instances - so it no longer
# demonstrates isolation. Asserted here because it is the field whose leak motivated the whole per-cloud split.
Assert-CV 'GCP: HasBackupPlan populated'       (Test-CVFieldIsPopulated 'HasBackupPlan' -Cloud GCP)   $true
Assert-CV 'Azure: HasBackupPlan now populated' (Test-CVFieldIsPopulated 'HasBackupPlan' -Cloud Azure) $true

Write-Host "`n[1] Every control reads at least one field it could actually be given"
$unwired = @()
$checked = 0
foreach ($spec in @(@{c='Azure';f='Get-CVAzureResilienceControls'},
                    @{c='GCP';  f='Get-CVGcpResilienceControls'},
                    @{c='AWS';  f='Get-CVAwsResilienceControls'})) {
    . (Join-Path $repoRoot 'src' 'common' "CVSizing.Resilience.$($spec.c).ps1")
    $sets = & $spec.f
    foreach ($type in ($sets.Keys | Sort-Object)) {
        foreach ($ctl in $sets[$type]) {
            $checked++
            $fields = @([regex]::Matches($ctl.Test.ToString(), '\$r\.([A-Za-z_][A-Za-z0-9_]*)') |
                          ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            if (-not $fields.Count) { continue }   # a control with no $r.* reference is a constant; not our concern
            $missing = @($fields | Where-Object { -not (Test-CVFieldIsPopulated $_ -Cloud $spec.c) })
            # Only fully-dead controls matter: if ANY field it reads is populated, the control can produce a verdict.
            if ($missing.Count -eq $fields.Count) {
                $unwired += "$($spec.c)/$($ctl.Id)"
            }
        }
    }
}
Assert-CV 'controls were actually inspected' ([bool]($checked -ge 70)) $true

# Anything unwired must be a KNOWN entry. A NEW dead control fails the build.
$unexpected = @($unwired | Where-Object { -not $script:KnownUnwired.ContainsKey($_) })
Assert-CV 'no NEW unwired control introduced' $unexpected.Count 0
if ($unexpected.Count) {
    Write-Host "        These controls read fields nothing populates - they can never be evaluated:" -ForegroundColor DarkYellow
    $unexpected | ForEach-Object { Write-Host "          $_" -ForegroundColor DarkYellow }
    Write-Host "        Either point the Test at the field the inventory row actually carries, collect the" -ForegroundColor DarkYellow
    # Backtick, not backslash: PowerShell's escape in a double-quoted string. "\$script:KnownUnwired" rendered
    # as "\System.Collections.Hashtable" because the variable interpolated anyway.
    Write-Host "        signal, or add it to `$script:KnownUnwired with a reason." -ForegroundColor DarkYellow
}

# And the reverse: an allow-list entry that is now wired should be REMOVED, or the list rots into a lie.
$staleAllow = @($script:KnownUnwired.Keys | Where-Object { $_ -notin $unwired })
Assert-CV 'allow-list has no stale entries' $staleAllow.Count 0
if ($staleAllow.Count) {
    Write-Host "        Now wired - delete from \$script:KnownUnwired: $($staleAllow -join ', ')" -ForegroundColor DarkYellow
}

Write-Host "`n[2] The five field-name mismatches found in the field stay fixed"
# Each of these was a control reading an invented name while the data sat on the row under another.
$regressions = @(
    @{ Cloud='AWS';   Id='rs-retention'; Bad='AutomatedSnapshotRetentionPeriod';  Good='AutomatedSnapshotRetentionDays' }
    @{ Cloud='Azure'; Id='cos-pitr';     Bad='ContinuousBackup';                  Good='BackupPolicyBackupType' }
    @{ Cloud='Azure'; Id='cos-xregion';  Bad='GeoRedundant';                      Good='BackupPolicyBackupStorageRedundancy' }
    @{ Cloud='Azure'; Id='db-xregion';   Bad='GeoRedundant';                      Good='BackupStorageRedundancy' }
    @{ Cloud='Azure'; Id='fx-xregion';   Bad='GeoRedundant';                      Good='GeoRedundantBackup' }
)
foreach ($r in $regressions) {
    . (Join-Path $repoRoot 'src' 'common' "CVSizing.Resilience.$($r.Cloud).ps1")
    $sets = & $(if ($r.Cloud -eq 'AWS') { 'Get-CVAwsResilienceControls' } else { 'Get-CVAzureResilienceControls' })
    $ctl  = @($sets.Values | ForEach-Object { $_ } | Where-Object Id -eq $r.Id)[0]
    Assert-CV "$($r.Cloud)/$($r.Id) exists" ([bool]$ctl) $true
    if (-not $ctl) { continue }
    $body = $ctl.Test.ToString()
    Assert-CV "$($r.Id) reads $($r.Good)"        ([bool]($body -match [regex]::Escape($r.Good))) $true
    Assert-CV "$($r.Id) no longer reads $($r.Bad)" ([bool]($body -match ('\$r\.' + [regex]::Escape($r.Bad) + '\b'))) $false
}

Write-Host "`n[3] The repointed controls evaluate real values instead of always Unknown"
. (Join-Path $repoRoot 'src' 'common' 'CVSizing.Resilience.Azure.ps1')
. (Join-Path $repoRoot 'src' 'common' 'CVSizing.Resilience.AWS.ps1')
$az  = Get-CVAzureResilienceControls
$aws = Get-CVAwsResilienceControls
function Outcome { param($Set, $Id, $Row)
    ((Invoke-CVResilience -Resource $Row -Controls $Set).Results | Where-Object Id -eq $Id).Outcome }

Assert-CV 'cos-pitr Continuous -> Met'  (Outcome $az.Cosmos 'cos-pitr' ([pscustomobject]@{ BackupPolicyBackupType='Continuous' })) 'Met'
Assert-CV 'cos-pitr Periodic  -> Gap'   (Outcome $az.Cosmos 'cos-pitr' ([pscustomobject]@{ BackupPolicyBackupType='Periodic'   })) 'Gap'
Assert-CV 'cos-pitr blank     -> Unknown' (Outcome $az.Cosmos 'cos-pitr' ([pscustomobject]@{ BackupPolicyBackupType='' }))         'Unknown'
Assert-CV 'cos-xregion Geo    -> Met'   (Outcome $az.Cosmos 'cos-xregion' ([pscustomobject]@{ BackupPolicyBackupStorageRedundancy='Geo'   })) 'Met'
Assert-CV 'cos-xregion Local  -> Gap'   (Outcome $az.Cosmos 'cos-xregion' ([pscustomobject]@{ BackupPolicyBackupStorageRedundancy='Local' })) 'Gap'
Assert-CV 'db-xregion GeoZone -> Met'   (Outcome $az.SQL 'db-xregion' ([pscustomobject]@{ BackupStorageRedundancy='GeoZone' })) 'Met'
Assert-CV 'db-xregion Zone    -> Gap'   (Outcome $az.SQL 'db-xregion' ([pscustomobject]@{ BackupStorageRedundancy='Zone'    })) 'Gap'
Assert-CV 'fx-xregion Enabled -> Met'   (Outcome $az.FlexDB 'fx-xregion' ([pscustomobject]@{ GeoRedundantBackup='Enabled'  })) 'Met'
Assert-CV 'fx-xregion Disabled-> Gap'   (Outcome $az.FlexDB 'fx-xregion' ([pscustomobject]@{ GeoRedundantBackup='Disabled' })) 'Gap'
Assert-CV 'rs-retention 7  -> Met'      (Outcome $aws.Redshift 'rs-retention' ([pscustomobject]@{ AutomatedSnapshotRetentionDays=7 })) 'Met'
Assert-CV 'rs-retention 1  -> Gap'      (Outcome $aws.Redshift 'rs-retention' ([pscustomobject]@{ AutomatedSnapshotRetentionDays=1 })) 'Gap'
Assert-CV 'rs-retention absent -> Unknown' (Outcome $aws.Redshift 'rs-retention' ([pscustomobject]@{})) 'Unknown'

Write-Host "`n[4] Shared signal fields are populated PER RESOURCE TYPE, not merely somewhere"
<#
    Why this section exists. Test-CVFieldIsPopulated above searches the concatenation of every src file, so a
    field counts as wired for EVERY control that reads it as soon as ANY collection sets it. CmkEncrypted was
    set on storage accounts alone, yet it is read by disk-cmek, db-cmek, fx-cmek and cos-cmek - so four controls
    reported blank on every run while section [1] stayed green.

    This resolves each Azure resource type to the row-builder variable that actually constructs its rows, then
    asks whether the field is assigned on THAT builder. Fields added by a later enrichment pass (Add-Member on
    an already-built collection) are accepted globally, since text alone cannot tell which collection such a
    pass targets - so this is a floor, not a ceiling.
#>
<#
    Parameterised by cloud. It began Azure-only, which is how AWS/rds-vault and AWS/ddb-vault survived: both
    read AWSBackupProtected, which IS assigned in the AWS script - but only inside Process-EC2Instance. RDS
    referenced an unassigned local of the same name and DynamoDB never set it at all, so both controls were
    permanently Unknown while section [1]'s per-cloud text search saw the field and passed.
#>
$script:CVBuilderAst = @{}
$script:CVBuilderFieldCache = @{}
function Get-CVBuilderFields {
    <#
      .SYNOPSIS  Property names assigned on $<Builder> in $Cloud's script: hashtable literal keys, .Add("k",v)
                 and $b["k"] = v.
    #>
    param([string]$Builder, [Parameter(Mandatory)][ValidateSet('Azure','AWS','GCP')][string]$Cloud)
    # Memoised: each call does three full AST traversals, and FindAll with a scriptblock predicate is slow over a
    # 4,000-line script. Without this the section is called ~30 times and takes minutes instead of a second.
    $cacheKey = "$Cloud|$Builder"
    if ($script:CVBuilderFieldCache.ContainsKey($cacheKey)) { return $script:CVBuilderFieldCache[$cacheKey] }
    if (-not $script:CVBuilderAst.ContainsKey($Cloud)) {
        $script:CVBuilderAst[$Cloud] = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $repoRoot 'src' $script:CVCloudScript[$Cloud]), [ref]$null, [ref]$null)
    }
    $ast = $script:CVBuilderAst[$Cloud]
    $fields = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    # $builder = [ordered]@{ Key = ...; "Key" = ... }  /  [PSCustomObject]@{ ... }
    $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
        Where-Object { $_.Left.Extent.Text -eq "`$$Builder" } | ForEach-Object {
            $_.Right.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true) |
                ForEach-Object { foreach ($pair in $_.KeyValuePairs) { [void]$fields.Add(($pair.Item1.Extent.Text -replace '^[''"]|[''"]$', '')) } }
        }
    # $builder.Add("Key", value)
    $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true) |
        Where-Object { $_.Expression.Extent.Text -eq "`$$Builder" -and $_.Member.Extent.Text -eq 'Add' -and $_.Arguments.Count } |
        ForEach-Object { [void]$fields.Add(($_.Arguments[0].Extent.Text -replace '^[''"]|[''"]$', '')) }
    # $builder["Key"] = value
    $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
        Where-Object { $_.Left -is [System.Management.Automation.Language.IndexExpressionAst] -and $_.Left.Target.Extent.Text -eq "`$$Builder" } |
        ForEach-Object { [void]$fields.Add(($_.Left.Index.Extent.Text -replace '^[''"]|[''"]$', '')) }

    $script:CVBuilderFieldCache[$cacheKey] = $fields
    return $fields
}

# ResourceType -> the row-builder variable(s) that construct that type's rows. Spelling must match the source
# exactly: the extractor compares assignment extent text with case-sensitive -eq. A name that does not exist
# yields an empty set and silently makes that type's check vacuous - which is what AKS = 'aksObj' did.
$script:CVTypeBuilders = @{
    Azure = @{
        VM = @('vmObj'); Disk = @('diskObj'); Storage = @('azSAObj'); SQL = @('sqlObj')
        FlexDB = @('mysqlObj', 'postgresObj'); Cosmos = @('cosmosObj'); FileShare = @('fileShareObj')
        AKS = @('AKSCluster')
    }
    AWS = @{
        EC2 = @('ec2Obj'); EBS = @('volumeObj'); RDS = @('rdsObj'); S3 = @('s3Obj')
        EFS = @('efsObj'); DynamoDB = @('ddbObj'); Redshift = @('rsObj')
    }
}

$perTypeUnwired = @()
foreach ($cloud in @('Azure', 'AWS')) {
    $builders = $script:CVTypeBuilders[$cloud]
    $sets = & $(if ($cloud -eq 'Azure') { 'Get-CVAzureResilienceControls' } else { 'Get-CVAwsResilienceControls' })

    # Enrichment fields (Add-Member -NotePropertyName X) applied post-hoc to whole collections. Scoped to this
    # cloud - a global sweep here was the second half of the cross-cloud leak.
    $enriched = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [regex]::Matches($script:CVCloudText[$cloud], '-NotePropertyName\s+[''"]?([A-Za-z_][A-Za-z0-9_]*)') |
        ForEach-Object { [void]$enriched.Add($_.Groups[1].Value) }

    # Guard the mapping itself, per cloud.
    $emptyBuilders = @()
    foreach ($type in ($builders.Keys | Sort-Object)) {
        foreach ($b in $builders[$type]) {
            if (-not (Get-CVBuilderFields -Builder $b -Cloud $cloud).Count) { $emptyBuilders += "$type -> `$$b" }
        }
    }
    Assert-CV "${cloud}: every declared row builder resolves to real fields" $emptyBuilders.Count 0
    if ($emptyBuilders.Count) { $emptyBuilders | ForEach-Object { Write-Host "          names nothing in the $cloud script: $_" -ForegroundColor DarkYellow } }

    $unmappedTypes = @($sets.Keys | Where-Object { -not $builders.ContainsKey($_) })
    Assert-CV "${cloud}: every resource type has a builder mapping" $unmappedTypes.Count 0
    if ($unmappedTypes.Count) { Write-Host "        unmapped: $($unmappedTypes -join ', ')" -ForegroundColor DarkYellow }

    foreach ($type in ($sets.Keys | Sort-Object)) {
        if (-not $builders.ContainsKey($type)) { continue }
        $available = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($b in $builders[$type]) { foreach ($f in (Get-CVBuilderFields -Builder $b -Cloud $cloud)) { [void]$available.Add($f) } }
        foreach ($f in $enriched) { [void]$available.Add($f) }

        foreach ($ctl in $sets[$type]) {
            $fields = @([regex]::Matches($ctl.Test.ToString(), '\$r\.([A-Za-z_][A-Za-z0-9_]*)') |
                          ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            if (-not $fields.Count) { continue }
            if (-not @($fields | Where-Object { $available.Contains($_) }).Count) {
                # Allow-list key kept separate from the display text; deriving one from the other by string
                # surgery is how this check once reported its own allow-listed entries as failures.
                $perTypeUnwired += [pscustomobject]@{
                    Key     = "$cloud/$($ctl.Id)"
                    Display = "$cloud/$type/$($ctl.Id) [reads: $($fields -join ', ')]"
                }
            }
        }
    }
}

Assert-CV 'extraction works (Azure vmObj has VMName)'      ([bool](Get-CVBuilderFields -Builder 'vmObj'  -Cloud Azure).Contains('VMName'))   $true
Assert-CV 'extraction is scoped (vmObj lacks DiskName)'    ([bool](Get-CVBuilderFields -Builder 'vmObj'  -Cloud Azure).Contains('DiskName')) $false
Assert-CV 'extraction works (AWS rdsObj has MultiAZ)'      ([bool](Get-CVBuilderFields -Builder 'rdsObj' -Cloud AWS).Contains('MultiAZ'))    $true
Assert-CV 'extraction is cloud-scoped (rdsObj not in Azure)' (Get-CVBuilderFields -Builder 'rdsObj' -Cloud Azure).Count                     0

$perTypeUnexpected = @($perTypeUnwired | Where-Object { -not $script:KnownUnwired.ContainsKey($_.Key) })
Assert-CV 'no control is blank for its own resource type' $perTypeUnexpected.Count 0
if ($perTypeUnexpected.Count) {
    Write-Host "        These read no field their own resource type's row builder ever sets:" -ForegroundColor DarkYellow
    $perTypeUnexpected | ForEach-Object { Write-Host "          $($_.Display)" -ForegroundColor DarkYellow }
}

Write-Host "`n[5] A signal field must not be fed from a variable nothing ever assigns"
<#
    Section [4] proves the FIELD is on the row builder. It cannot prove the field has a value: a builder can
    assign `AWSBackupProtected = $awsBackupProtected` where $awsBackupProtected is never set in that function, so
    the row carries the field as $null forever and the control is permanently Unknown.

    That is exactly what AWS/rds-vault did. Only Process-EC2Instance ever called the AWS Backup lookup; RDS
    referenced a local of the same name that was never assigned. Section [4] passes it because the field is
    genuinely present on $rdsObj.

    Same defect class as the three undefined variables that silently dropped SQL and Cosmos from the Azure JSON
    export. Set-StrictMode would catch it at runtime; this catches it in the suite.
#>
function Get-CVUnassignedBuilderVars {
    <#
      .SYNOPSIS  Variables READ as a builder hashtable's values but never assigned in the enclosing function.
      .OUTPUTS   "<function>/<builder>.<Field> <- $<var>" for each offender.
    #>
    param([Parameter(Mandatory)][ValidateSet('Azure','AWS','GCP')][string]$Cloud, [string[]]$Builder)
    if (-not $script:CVBuilderAst.ContainsKey($Cloud)) {
        $script:CVBuilderAst[$Cloud] = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $repoRoot 'src' $script:CVCloudScript[$Cloud]), [ref]$null, [ref]$null)
    }
    $ast = $script:CVBuilderAst[$Cloud]
    $out = @()

    foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        # Everything assigned anywhere in this function, plus its parameters.
        $assigned = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
            ForEach-Object {
                $l = $_.Left
                if ($l -is [System.Management.Automation.Language.VariableExpressionAst]) { [void]$assigned.Add($l.VariablePath.UserPath) }
                elseif ($l -is [System.Management.Automation.Language.IndexExpressionAst] -and
                        $l.Target -is [System.Management.Automation.Language.VariableExpressionAst]) { [void]$assigned.Add($l.Target.VariablePath.UserPath) }
                elseif ($l -is [System.Management.Automation.Language.MemberExpressionAst] -and
                        $l.Expression -is [System.Management.Automation.Language.VariableExpressionAst]) { [void]$assigned.Add($l.Expression.VariablePath.UserPath) }
            }
        if ($fn.Body.ParamBlock) { $fn.Body.ParamBlock.Parameters | ForEach-Object { [void]$assigned.Add($_.Name.VariablePath.UserPath) } }
        # foreach ($x in ...) binds $x too.
        $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true) |
            ForEach-Object { [void]$assigned.Add($_.Variable.VariablePath.UserPath) }

        foreach ($b in $Builder) {
            $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
                Where-Object { $_.Left.Extent.Text -eq "`$$b" } | ForEach-Object {
                    $ht = $_.Right.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true)
                    if (-not $ht) { return }
                    foreach ($pair in $ht.KeyValuePairs) {
                        # Only flag a value that is JUST a bare variable - anything more is too complex to judge.
                        $v = $pair.Item2
                        $expr = $v.Extent.Text.Trim()
                        if ($expr -notmatch '^\$[A-Za-z_][A-Za-z0-9_]*$') { continue }
                        $name = $expr.Substring(1)
                        if ($assigned.Contains($name)) { continue }
                        if ($name -in @('null','true','false','_')) { continue }
                        $key = $pair.Item1.Extent.Text -replace '^[''"]|[''"]$', ''
                        $out += "$($fn.Name)/`$$b.$key <- `$$name"
                    }
                }
        }
    }
    return $out
}

$unassigned = @()
foreach ($cloud in @('Azure', 'AWS')) {
    $unassigned += @(Get-CVUnassignedBuilderVars -Cloud $cloud -Builder @($script:CVTypeBuilders[$cloud].Values | ForEach-Object { $_ }))
}
Assert-CV 'no builder field is fed from an unassigned variable' $unassigned.Count 0
if ($unassigned.Count) {
    Write-Host "        These row fields can only ever be `$null - the variable is never assigned in that function:" -ForegroundColor DarkYellow
    $unassigned | ForEach-Object { Write-Host "          $_" -ForegroundColor DarkYellow }
}

# The four CMK controls this section was written for. Each must now find CmkEncrypted on its own builder.
foreach ($pair in @(@{T='Disk';B='diskObj'}, @{T='SQL';B='sqlObj'}, @{T='Cosmos';B='cosmosObj'},
                    @{T='FlexDB';B='mysqlObj'}, @{T='FlexDB';B='postgresObj'}, @{T='Storage';B='azSAObj'})) {
    Assert-CV "$($pair.T): CmkEncrypted set on `$$($pair.B)" ([bool](Get-CVBuilderFields -Builder $pair.B -Cloud Azure).Contains('CmkEncrypted')) $true
}

Write-Host ("`n======  {0} passed, {1} failed  ======`n" -f $script:Pass, $script:Fail) `
           -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
