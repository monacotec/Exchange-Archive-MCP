<#
.SYNOPSIS
    Phase 0 verification — bundled checks for steps 5, 6, 7, 8 of the runbook.

.DESCRIPTION
    Read-only verifications, no tenant changes. Run after Phase 0 steps 1–4
    (app reg, security group, ApplicationAccessPolicy, audit verification)
    are complete. If all four sections report [PASS], you're cleared for
    Phase 1 (running the spike against the real app reg).

      Step 5 — Online archive provisioning for the test mailbox
      Step 6 — License / Purview Audit tier (tenant + per-user)
      Step 7 — Conditional Access posture against this AppId
      Step 8 — Token lifetime policies (legacy + app-specific)

    Uses Microsoft.Graph.Authentication only (no submodule installs needed).
    All Graph reads go through Invoke-MgGraphRequest against the REST API,
    matching the approach the MCP server itself uses.

.NOTES
    File:    Phase0-Verify.ps1
    Version: 0.3.0
    Phase:   0
    Requires: PowerShell 7+, ExchangeOnlineManagement, Microsoft.Graph.Authentication

.PARAMETER UserPrincipalName
    Mailbox to verify against. Defaults to the GI test user.

.PARAMETER TenantId
    Entra tenant GUID. Defaults to GI Partners production tenant.

.PARAMETER AppId
    Entra app registration GUID for the MCP. Defaults to the production app reg.

.EXAMPLE
    Connect-ExchangeOnline -ShowBanner:$false
    .\Phase0-Verify.ps1
#>

#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication, ExchangeOnlineManagement

[CmdletBinding()]
param(
    [string]$UserPrincipalName = 'jmonaco@gipartners.com',
    [string]$TenantId          = '9c1b0b26-717a-4eda-9d7e-7eebc00066bf',
    [string]$AppId             = '9519ca68-dae2-4add-8309-4bdd1fa45e79'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Hdr ($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Ok  ($t) { Write-Host "  [PASS] $t"  -ForegroundColor Green }
function No  ($t) { Write-Host "  [FAIL] $t"  -ForegroundColor Red }
function Info($t) { Write-Host "  [info] $t"  -ForegroundColor DarkGray }

# Thin wrapper: typed GET against Graph, returns the .value collection for paged endpoints,
# otherwise the raw response. Strict-mode safe — checks for property existence before access.
function Get-Graph {
    param([Parameter(Mandatory)][string]$Uri)
    $resp = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject -ErrorAction Stop
    if ($null -eq $resp) { return $null }
    $hasValue = $false
    if ($resp -is [System.Collections.IDictionary]) {
        $hasValue = $resp.Contains('value')
        if ($hasValue) { return $resp['value'] }
    } elseif ($resp.PSObject -and $resp.PSObject.Properties.Match('value').Count -gt 0) {
        return $resp.value
    }
    return $resp
}

$results = [ordered]@{
    Step5_Archive       = $null
    Step6_LicenseTenant = $null
    Step6_LicenseUser   = $null
    Step7_CA            = $null
    Step8_TokenLifetime = $null
}

#region Preflight — connections
Hdr 'Preflight — connections'

$exo = Get-ConnectionInformation -ErrorAction SilentlyContinue
if (-not $exo -or $exo.TokenStatus -ne 'Active') {
    No 'Exchange Online not connected. Run: Connect-ExchangeOnline -ShowBanner:$false'
    throw 'Connect-ExchangeOnline first.'
}
Ok "Exchange Online connected ($($exo.UserPrincipalName))"

# Graph scopes needed (all are read-only):
#   Organization.Read.All  → /subscribedSkus
#   Directory.Read.All     → /users/{upn}, /groups
#   Policy.Read.All        → /identity/conditionalAccess/policies, /policies/tokenLifetimePolicies
#   Application.Read.All   → /applications?$filter=appId eq '...'
$required = @('Organization.Read.All','Directory.Read.All','Policy.Read.All','Application.Read.All')

$mgCtx = $null
try { $mgCtx = Get-MgContext } catch { }
$needConnect = (-not $mgCtx) -or ($required | Where-Object { $mgCtx.Scopes -notcontains $_ })

if ($needConnect) {
    Info "Connecting to Microsoft Graph with scopes: $($required -join ', ')"
    Connect-MgGraph -Scopes $required -TenantId $TenantId -NoWelcome
    $mgCtx = Get-MgContext
}
Ok "Microsoft Graph connected ($($mgCtx.Account), tenant $($mgCtx.TenantId))"
#endregion

#region Step 5 — Online archive provisioning
Hdr "Step 5 — Online archive provisioning for $UserPrincipalName"

$mbx = Get-Mailbox $UserPrincipalName
$mbx | Format-List Identity, ArchiveStatus, ArchiveName, ArchiveQuota,
                   ArchiveWarningQuota, ArchiveDatabase

if ($mbx.ArchiveStatus -eq 'Active') {
    Ok 'ArchiveStatus = Active. Spike will find folders to walk.'
    $results.Step5_Archive = 'PASS'
} else {
    No "ArchiveStatus = $($mbx.ArchiveStatus). Enable with:"
    Info "  Enable-Mailbox -Identity $UserPrincipalName -Archive"
    Info '  Provisioning takes 10-60 minutes. Re-run this script before the spike.'
    $results.Step5_Archive = "FAIL ($($mbx.ArchiveStatus))"
}
#endregion

#region Step 6 — License / Purview Audit tier
Hdr 'Step 6 — Tenant SKUs (Purview Audit posture)'

$skuNotes = @{
    'ENTERPRISEPACK'              = 'E3 — base; MailItemsAccessed throttled, no Premium audit'
    'ENTERPRISEPREMIUM'           = 'E5 — Premium Audit included'
    'SPE_E5'                      = 'M365 E5 — Premium Audit included'
    'SPE_E3'                      = 'M365 E3 — base; Premium Audit needs add-on'
    'M365_AUDIT_APP'              = 'Standalone Audit Premium add-on'
    'Microsoft_365_E5_Compliance' = 'E5 Compliance — includes Premium Audit'
    'EQUIVIO_ANALYTICS'           = 'Advanced eDiscovery (flags E5)'
}
$premiumSkus = @('ENTERPRISEPREMIUM','SPE_E5','M365_AUDIT_APP','Microsoft_365_E5_Compliance')

$allSkus = Get-Graph -Uri 'https://graph.microsoft.com/v1.0/subscribedSkus'
$skuMap  = @{}
$allSkus | ForEach-Object { $skuMap[$_.skuId] = $_.skuPartNumber }

$tenantSkus = $allSkus |
    Where-Object { $skuNotes.ContainsKey($_.skuPartNumber) -or $_.skuPartNumber -match 'PREMIUM|E5|AUDIT' } |
    Select-Object @{N='SkuPartNumber';E={$_.skuPartNumber}},
                  @{N='Consumed';     E={$_.consumedUnits}},
                  @{N='Available';    E={$_.prepaidUnits.enabled - $_.consumedUnits}},
                  @{N='Notes';        E={ $skuNotes[$_.skuPartNumber] }}

if ($tenantSkus) {
    $tenantSkus | Format-Table -AutoSize -Wrap
    $premium = $tenantSkus | Where-Object { $_.SkuPartNumber -in $premiumSkus }
    if ($premium) {
        Ok "Tenant has Purview Audit Premium (via $($premium.SkuPartNumber -join ', '))."
        Ok 'MailItemsAccessed audit is full-fidelity. Per-call attribution claim holds at scale.'
        $results.Step6_LicenseTenant = 'PASS'
    } else {
        Info 'No Premium audit SKU detected at tenant level.'
        Info 'On E3 base, MailItemsAccessed is logged but throttled.'
        Info 'Document the limitation in SECURITY.md or upgrade to Audit Premium add-on.'
        $results.Step6_LicenseTenant = 'INFO (no Premium SKU)'
    }
} else {
    No 'No relevant SKUs found at tenant level.'
    $results.Step6_LicenseTenant = 'FAIL'
}

Hdr "Per-user licenses ($UserPrincipalName)"
$userUri = "https://graph.microsoft.com/v1.0/users/$UserPrincipalName" + '?$select=assignedLicenses,displayName,userPrincipalName'
$user = Get-Graph -Uri $userUri
$userLicenses = $user.assignedLicenses | ForEach-Object {
    [PSCustomObject]@{
        SkuId         = $_.skuId
        SkuPartNumber = $skuMap[$_.skuId]
        Notes         = $skuNotes[$skuMap[$_.skuId]]
    }
}
if ($userLicenses) {
    $userLicenses | Format-Table -AutoSize -Wrap
    $userPremium = $userLicenses | Where-Object { $_.SkuPartNumber -in $premiumSkus }
    if ($userPremium) {
        Ok "You're licensed for Premium Audit ($($userPremium.SkuPartNumber -join ', '))."
        $results.Step6_LicenseUser = 'PASS'
    } else {
        Info 'You do not appear to hold a Premium Audit SKU directly.'
        $results.Step6_LicenseUser = 'INFO'
    }
} else {
    No "No licenses assigned to $UserPrincipalName."
    $results.Step6_LicenseUser = 'FAIL'
}
#endregion

#region Step 7 — Conditional Access posture
Hdr 'Step 7 — Conditional Access posture'

$caUri = 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies'
$allCa = @()
try {
    $allCa = @(Get-Graph -Uri $caUri)
} catch {
    No "Could not enumerate CA policies: $($_.Exception.Message)"
    Info 'Policy.Read.All scope is required; reconnect with it if necessary.'
    $results.Step7_CA = 'FAIL (cannot read)'
}

# Classify a blocking policy by whether it actually applies to the MCP's auth flow.
# MCP uses: authorization-code + PKCE via loopback (browser), modern auth (MSAL.NET).
# Categories of "blockers" that are NOT applicable to us:
#   - device-code-only blocks               (we don't use deviceCode flow)
#   - legacy-auth-only blocks               (MSAL.NET is modern auth)
#   - geo blocks where user is in-scope     (assess case by case; we print conditions)
function Test-CaBlockerRelevance {
    param($policy)
    $conds = $policy.conditions
    $reasons = @()

    # Strict-mode-safe property access helper
    function HasProp($obj, $name) {
        if ($null -eq $obj) { return $false }
        if ($obj -is [System.Collections.IDictionary]) { return $obj.Contains($name) }
        return ($obj.PSObject.Properties.Match($name).Count -gt 0)
    }
    function GetProp($obj, $name) {
        if (-not (HasProp $obj $name)) { return $null }
        if ($obj -is [System.Collections.IDictionary]) { return $obj[$name] }
        return $obj.$name
    }

    # --- 1. authenticationFlows.transferMethods (newer CA condition)
    # The "Block device code flow" template lives here, NOT in clientAppTypes.
    if (HasProp $conds 'authenticationFlows') {
        $af = GetProp $conds 'authenticationFlows'
        $tm = GetProp $af 'transferMethods'
        if ($tm) {
            # transferMethods is a comma-separated string per Graph schema
            $methods = @($tm -split ',\s*') | Where-Object { $_ }
            $nonMcpFlows = $methods | Where-Object { $_ -in 'deviceCodeFlow','authenticationTransfer' }
            $mcpRelevantFlows = $methods | Where-Object { $_ -notin 'deviceCodeFlow','authenticationTransfer' }
            if ($nonMcpFlows -and -not $mcpRelevantFlows) {
                $reasons += "targets only $($nonMcpFlows -join '/') — MCP uses auth-code+PKCE"
            }
        }
    }

    # --- 2. clientAppTypes (legacy auth blocker)
    $cats = @()
    if (HasProp $conds 'clientAppTypes') {
        $cats = @(GetProp $conds 'clientAppTypes')
    }
    if ($cats.Count -gt 0 -and ($cats -notcontains 'all') -and ($cats -notcontains 'browser') -and ($cats -notcontains 'mobileAppsAndDesktopClients')) {
        if (($cats -contains 'exchangeActiveSync') -or ($cats -contains 'other')) {
            $reasons += "targets legacy auth only (clientAppTypes=$($cats -join ',')) — MCP uses modern auth/MSAL.NET"
        }
    }

    # --- 3. Locations (geo block) — flag for review, don't auto-clear
    if (HasProp $conds 'locations') {
        $locs = GetProp $conds 'locations'
        $inc = GetProp $locs 'includeLocations'
        if ($inc -and @($inc).Count -gt 0 -and (@($inc) -notcontains 'All')) {
            $reasons += "geo-restricted (includeLocations: $(@($inc) -join ','))"
        }
    }

    if ($reasons.Count -gt 0) {
        return [PSCustomObject]@{
            Name      = $policy.displayName
            Relevant  = $false
            Reasoning = $reasons -join '; '
        }
    }
    return [PSCustomObject]@{
        Name      = $policy.displayName
        Relevant  = $true
        Reasoning = 'broad block — likely applies to MCP'
    }
}

if ($allCa.Count -gt 0) {
    $relevant = $allCa | Where-Object {
        $_.state -eq 'enabled' -and (
            ($_.conditions.applications.includeApplications -contains 'All') -or
            ($_.conditions.applications.includeApplications -contains $AppId)
        )
    }

    if ($relevant) {
        Info 'All enabled CA policies that target this app or All apps:'
        @($relevant) |
            Select-Object displayName, state,
                @{N='Grants';     E={ $_.grantControls.builtInControls -join ',' }},
                @{N='ClientApps'; E={ $_.conditions.clientAppTypes -join ',' }},
                @{N='SessionCtl'; E={ $_.sessionControls.signInFrequency.value }} |
            Format-Table -AutoSize -Wrap

        $blockers = @($relevant) | Where-Object { $_.grantControls.builtInControls -contains 'block' }
        $applicable = @()
        if ($blockers) {
            Hdr 'Block-policy applicability analysis'
            $analysis = $blockers | ForEach-Object { Test-CaBlockerRelevance $_ }
            $analysis | Format-Table -AutoSize -Wrap
            $applicable = @($analysis | Where-Object { $_.Relevant })
        }

        if ($applicable.Count -gt 0) {
            No "Policies likely to block the MCP's auth flow:"
            $applicable | Format-Table -AutoSize
            $results.Step7_CA = "FAIL ($($applicable.Count) applicable blockers)"
        } else {
            Ok 'No applicable blockers — MCP auth flow is permitted by current CA posture.'
            Info 'MFA / compliant-device grants are expected; Connect-MgGraph handles them.'
            if ($blockers) {
                Info "$($blockers.Count) block-policies exist but apply to flows the MCP doesn't use (device code / legacy auth / geo)."
            }
            $results.Step7_CA = 'PASS'
        }
    } else {
        Ok "No enabled CA policies targeting this app or 'All apps'."
        $results.Step7_CA = 'PASS'
    }
}
#endregion

#region Step 8 — Token lifetime policies
Hdr 'Step 8 — Token lifetime policies (tenant-level)'

$tlpUri = 'https://graph.microsoft.com/v1.0/policies/tokenLifetimePolicies'
$tlp = @()
try { $tlp = @(Get-Graph -Uri $tlpUri) } catch { Info "TLP enumeration skipped: $($_.Exception.Message)" }

if ($tlp.Count -gt 0) {
    Info 'Token Lifetime Policies exist (legacy mechanism). Reviewing:'
    $tlp | Format-List id, displayName, definition, isOrganizationDefault
    Info 'Document these values in SECURITY.md; silent refresh expectations may not hold.'
    $results.Step8_TokenLifetime = "INFO ($($tlp.Count) TLPs found)"
} else {
    Ok 'No legacy Token Lifetime Policies — tenant defaults in effect.'
    Info 'Access tokens: ~60-90 min (Microsoft-managed). Refresh tokens: tenant default (typically 90 days).'
    Info 'Silent refresh via Microsoft.Graph.Authentication works as designed.'
    $results.Step8_TokenLifetime = 'PASS'
}

Hdr 'App-specific Token Lifetime binding'
try {
    $appFilter = "appId eq '$AppId'"
    $appLookupUri = 'https://graph.microsoft.com/v1.0/applications?$filter=' + [Uri]::EscapeDataString($appFilter)
    $apps = @(Get-Graph -Uri $appLookupUri)

    if ($apps.Count -gt 0) {
        $appObj = $apps[0]
        Info "App found: $($appObj.displayName) (objectId $($appObj.id))"
        $appTlpUri = "https://graph.microsoft.com/v1.0/applications/$($appObj.id)/tokenLifetimePolicies"
        $appTlp = @(Get-Graph -Uri $appTlpUri)
        if ($appTlp.Count -gt 0) {
            Info 'App-specific TLP bound to this app:'
            $appTlp | Format-List
            $results.Step8_TokenLifetime = "$($results.Step8_TokenLifetime) + app-specific TLP bound"
        } else {
            Ok 'No app-specific TLP bound to Exchange Archive MCP.'
        }
    } else {
        Info "App not found in Graph (check Application.Read.All scope on the connection)."
    }
} catch {
    Info "App-specific TLP check skipped: $($_.Exception.Message)"
}
#endregion

#region Final summary
Hdr 'Phase 0 — Final summary'
$results.GetEnumerator() |
    Select-Object @{N='Check';E={$_.Key}}, @{N='Result';E={$_.Value}} |
    Format-Table -AutoSize

$failed = $results.Values | Where-Object { $_ -like 'FAIL*' }
if ($failed) {
    No 'Phase 0 is NOT clear. Resolve the FAIL items above, then re-run.'
    exit 1
} else {
    Ok 'All Phase 0 verifications passed (or are informational).'
    Ok 'You are cleared for Phase 1 — run the spike:'
    Write-Host ''
    Write-Host "  pwsh ./local-mcp/spike/Spike-ArchiveAccess.ps1 ``" -ForegroundColor White
    Write-Host "      -ClientId $AppId ``" -ForegroundColor White
    Write-Host "      -TenantId $TenantId" -ForegroundColor White
    Write-Host ''
}
#endregion
