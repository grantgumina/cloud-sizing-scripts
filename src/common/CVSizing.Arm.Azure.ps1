<#
    CVSizing.Arm.Azure.ps1 - thin ARM REST list helper, for the signals a cmdlet cannot report honestly.

    WHY THIS EXISTS. The tri-state discipline in this codebase turns on one distinction: did we look and find
    nothing, or were we unable to look? A cmdlet conflates them - `Get-Az...` returning an empty collection could
    mean the subscription has none, or that a 403 was swallowed, or that a module is absent. Both come back as
    "no rows", and treating that as "the customer has none" is how a fabricated gap gets published.

    An HTTP status code cannot be ambiguous:
        200 + empty value[]  -> a MEASURED zero. Safe to publish as $false / 'None'.
        403 / 404 / other    -> Unknown. Publish blank and record the collection status.

    It also removes a module dependency. Invoke-AzRestMethod ships in Az.Accounts, which is already a fatal
    requirement, so reading Microsoft.DataProtection (AKS backup) needs no Az.DataProtection install and no new
    permission beyond the reads a sizing run already asks for.

    Used for: Recovery Services vault settings (immutability / cross-region restore, whose PowerShell-model
    hydration on the list form could not be verified) and DataProtection backup instances (AKS backup coverage).
#>

function Invoke-CVAzRestList {
    <#
      .SYNOPSIS  GET an ARM list endpoint and report BOTH the outcome and the items, never one without the other.
      .PARAMETER Path       ARM path, e.g. /subscriptions/<id>/providers/Microsoft.DataProtection/backupVaults
      .PARAMETER ApiVersion Pinned explicitly by the caller. ARM defaults drift and a silently newer shape is
                            how a property path starts returning $null without anything erroring.
      .PARAMETER Fetch      Injectable for tests: a scriptblock taking a single URI string and returning an
                            object with .StatusCode and .Content. Defaults to Invoke-AzRestMethod.
      .OUTPUTS   pscustomobject { Ok; StatusCode; Items; Error }
                 Ok is $true ONLY for HTTP 200. Items is always an array (empty when none), so a caller can
                 distinguish "Ok with 0 items" (measured zero) from "-not Ok" (unknown) without null-checking.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ApiVersion,
        [scriptblock]$Fetch
    )

    $uri = if ($Path -match '\?') { "$Path&api-version=$ApiVersion" } else { "$Path" + "?api-version=$ApiVersion" }
    if (-not $Fetch) { $Fetch = { param($u) Invoke-AzRestMethod -Method GET -Path $u -ErrorAction Stop } }

    try {
        $resp = & $Fetch $uri
    } catch {
        return [pscustomobject]@{ Ok = $false; StatusCode = $null; Items = @(); Error = $_.Exception.Message }
    }
    if (-not $resp) {
        return [pscustomobject]@{ Ok = $false; StatusCode = $null; Items = @(); Error = 'no response' }
    }

    $code = $resp.StatusCode
    if ($code -ne 200) {
        # Surface a trimmed body: ARM puts the missing-permission name in it, which is what the operator needs.
        $detail = if ($resp.Content) { ([string]$resp.Content).Substring(0, [Math]::Min(300, ([string]$resp.Content).Length)) } else { '' }
        return [pscustomobject]@{ Ok = $false; StatusCode = $code; Items = @(); Error = $detail }
    }

    $items = @()
    if ($resp.Content) {
        try {
            $body = $resp.Content | ConvertFrom-Json
            # List endpoints wrap in value[]; a single-resource GET does not.
            if ($body -and $body.PSObject.Properties['value']) { $items = @($body.value | Where-Object { $_ }) }
            elseif ($body) { $items = @($body) }
        } catch {
            # 200 with a body we cannot parse is NOT a measured zero.
            return [pscustomobject]@{ Ok = $false; StatusCode = $code; Items = @(); Error = "unparseable body: $($_.Exception.Message)" }
        }
    }
    return [pscustomobject]@{ Ok = $true; StatusCode = $code; Items = $items; Error = '' }
}

function Get-CVAzureVaultSettingsMap {
    <#
      .SYNOPSIS  Recovery Services vault posture, keyed by lowercased vault ARM id.
      .DESCRIPTION
        Read over REST rather than off Get-AzRecoveryServicesVault's .Properties. The list form's hydration of
        the nested settings blocks could not be verified (no vault existed in any reachable subscription), and a
        design resting on unverified hydration would silently emit blank columns on every run.

        Raw enum strings are returned verbatim - 'Disabled' / 'Unlocked' / 'Locked' for immutability, where only
        'Locked' is genuinely WORM because an Unlocked policy can simply be removed.
      .OUTPUTS  pscustomobject { Ok; Settings } - Settings maps vaultId(lower) -> pscustomobject of raw values.
                Ok $false means the caller must record VAULTSETTINGS as Failed and leave the columns blank.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [string]$ApiVersion = '2024-04-01',
        [scriptblock]$Fetch
    )

    $res = Invoke-CVAzRestList -Path "/subscriptions/$SubscriptionId/providers/Microsoft.RecoveryServices/vaults" `
                               -ApiVersion $ApiVersion -Fetch $Fetch
    if (-not $res.Ok) { return [pscustomobject]@{ Ok = $false; Settings = @{}; Error = $res.Error; StatusCode = $res.StatusCode } }

    $map = @{}
    foreach ($v in $res.Items) {
        if (-not $v.id) { continue }
        $p = $v.properties
        $map[([string]$v.id).ToLower()] = [pscustomobject]@{
            VaultCrossRegionRestore      = "$($p.redundancySettings.crossRegionRestore)"
            VaultStorageRedundancy       = "$($p.redundancySettings.standardTierStorageRedundancy)"
            VaultImmutabilityState       = "$($p.securitySettings.immutabilitySettings.state)"
            VaultSoftDeleteState         = "$($p.securitySettings.softDeleteSettings.softDeleteState)"
            VaultSoftDeleteRetentionDays = $p.securitySettings.softDeleteSettings.softDeleteRetentionPeriodInDays
            VaultMultiUserAuth           = "$($p.securitySettings.multiUserAuthorization)"
        }
    }
    return [pscustomobject]@{ Ok = $true; Settings = $map; Error = ''; StatusCode = $res.StatusCode }
}

function Get-CVAzureDataProtectionInstances {
    <#
      .SYNOPSIS  DataProtection backup instances in a subscription, for AKS (and any other) backup coverage.
      .DESCRIPTION
        Azure AKS backup lives in a Microsoft.DataProtection Backup vault - NOT a Recovery Services vault - as a
        backup instance whose dataSourceInfo.resourceID points at the protected resource.

        Deliberately not Azure Resource Graph, even though Az.ResourceGraph is already a dependency: a Graph
        query returning zero rows cannot distinguish "this type is not indexed" from "none exist", and treating
        that as $false would publish "no cluster is backed up" wherever the type happens to be unindexed. REST
        returns a status code, so the zero case is provable.

        Zero backup vaults is itself conclusive: with no Backup vault there can be no AKS backup, so $false is
        measured rather than assumed. Mirrors the Recovery Services path, which already treats a successful
        enumeration returning none as a measured zero.
      .OUTPUTS  pscustomobject { Ok; Instances[]; VaultCount; Error }
                Each instance: { ResourceId; VaultName; DataSourceId; DataSourceType; ProtectionState }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [string]$ApiVersion = '2024-04-01',
        [scriptblock]$Fetch
    )

    $vaults = Invoke-CVAzRestList -Path "/subscriptions/$SubscriptionId/providers/Microsoft.DataProtection/backupVaults" `
                                  -ApiVersion $ApiVersion -Fetch $Fetch
    if (-not $vaults.Ok) {
        return [pscustomobject]@{ Ok = $false; Instances = @(); VaultCount = $null; Error = $vaults.Error; StatusCode = $vaults.StatusCode }
    }
    # 200 with no vaults: conclusive, and no further calls to make.
    if (-not $vaults.Items.Count) {
        return [pscustomobject]@{ Ok = $true; Instances = @(); VaultCount = 0; Error = ''; StatusCode = 200 }
    }

    $instances = [System.Collections.Generic.List[psobject]]::new()
    foreach ($v in $vaults.Items) {
        if (-not $v.id) { continue }
        $res = Invoke-CVAzRestList -Path "$($v.id)/backupInstances" -ApiVersion $ApiVersion -Fetch $Fetch
        if (-not $res.Ok) {
            # One unreadable vault means we cannot claim a complete picture for this subscription.
            return [pscustomobject]@{ Ok = $false; Instances = @(); VaultCount = $vaults.Items.Count
                                      Error = "vault '$($v.name)': $($res.Error)"; StatusCode = $res.StatusCode }
        }
        foreach ($bi in $res.Items) {
            $instances.Add([pscustomobject]@{
                ResourceId      = "$($bi.id)"
                VaultName       = "$($v.name)"
                DataSourceId    = "$($bi.properties.dataSourceInfo.resourceID)"
                DataSourceType  = "$($bi.properties.dataSourceInfo.datasourceType)"
                ProtectionState = "$($bi.properties.currentProtectionState)"
            })
        }
    }
    return [pscustomobject]@{ Ok = $true; Instances = @($instances); VaultCount = $vaults.Items.Count; Error = ''; StatusCode = 200 }
}
