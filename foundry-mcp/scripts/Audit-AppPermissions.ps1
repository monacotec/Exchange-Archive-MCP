#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication
# Version: 1.1.0
# 1.1.0: email/profile/openid reclassified as expected — they are OIDC sign-in
#        claim scopes consented by Set-ClaudeConnectorAuth.ps1; Easy Auth's
#        caller-identity claims (preferred_username) depend on them.
# Audit-AppPermissions.ps1 — read-only least-privilege audit of the shared
# 'Exchange Archive MCP' app registration (local stdio MCP + Foundry MCP).
#
# Enumerates every delegated grant and app-role assignment actually consented in
# the tenant and compares them against the CODE-VERIFIED baseline (what the two
# MCPs demonstrably use), then checks registration posture (owners, assignment
# requirement, secrets, redirect URIs). Mutates NOTHING — every recommendation
# is printed for a deliberate manual follow-up.
#
# Code-verified baseline (2026-08-11):
#   Delegated (Graph)  Mail.Read        — foundry OBO data path (function_app.py GRAPH_SCOPE)
#                      Mail.ReadWrite   — local MCP write tools (restore/copy/move)
#                      User.Read        — sign-in basics (local-mcp appsettings scopes)
#                      offline_access   — refresh tokens for the local session
#   App role (Graph)   eDiscovery.ReadWrite.All — foundry archive data path (ediscovery.py;
#                      approved app-only model 2026-07-22, ARCHIVE-DATA-PATH-PLAN §5)
#   App role (Purview) eDiscovery.Download.Read — export package downloads
#   Self (api://exchange-mcp) Archive.Read — the connector scope this app exposes
#
#   Flagged as REDUNDANT if present:
#     App role (Graph) eDiscovery.Read.All — superseded by eDiscovery.ReadWrite.All
#     (Initialize-EDiscoveryAccess.ps1 granted both). Remove in the portal, then
#     re-run Test-EDiscoveryExport.ps1 to confirm the export path still works.
#
# Graph permissions required by THIS audit session (delegated, interactive browser
# auth — never device code): Application.Read.All, Directory.Read.All

[CmdletBinding()]
param(
    [string] $AppId    = '9519ca68-dae2-4add-8309-4bdd1fa45e79',
    [string] $TenantId = '9c1b0b26-717a-4eda-9d7e-7eebc00066bf'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$graphResourceAppId   = '00000003-0000-0000-c000-000000000000'  # Microsoft Graph
$purviewResourceAppId = 'b26e684c-5068-4120-a679-64a5d2c909d9'  # MicrosoftPurviewEDiscovery

# Baselines. Keys are "<resourceAppId>|<permission name>".
$expectedDelegated = @(
    "$graphResourceAppId|Mail.Read",
    "$graphResourceAppId|Mail.ReadWrite",
    "$graphResourceAppId|User.Read",
    "$graphResourceAppId|offline_access"
)
# OIDC sign-in claim scopes: consented tenant-wide by Set-ClaudeConnectorAuth.ps1.
# Easy Auth / connector sign-in uses these for the caller-identity claims that
# function_app.py _get_caller() reads — keep them.
$oidcSignInScopes = @(
    "$graphResourceAppId|openid",
    "$graphResourceAppId|email",
    "$graphResourceAppId|profile"
)
$expectedAppRoles = @(
    "$graphResourceAppId|eDiscovery.ReadWrite.All",
    "$purviewResourceAppId|eDiscovery.Download.Read"
)
$redundantAppRoles = @{
    "$graphResourceAppId|eDiscovery.Read.All" = 'Superseded by eDiscovery.ReadWrite.All. Remove, then re-test with Test-EDiscoveryExport.ps1.'
}
$legacyRedirects = @('https://login.microsoftonline.com/common/oauth2/nativeclient')

$issues = [System.Collections.Generic.List[string]]::new()
function Ok   ([string]$m) { Write-Host "[OK] $m" -ForegroundColor Green }
function Bad  ([string]$m) { Write-Host "[!!] $m" -ForegroundColor Red; [void]$issues.Add($m) }
function Info ([string]$m) { Write-Host "     $m" -ForegroundColor Yellow }

Write-Host "Connecting to Microsoft Graph (read-only scopes)..." -ForegroundColor Cyan
Connect-MgGraph -TenantId $TenantId -Scopes 'Application.Read.All','Directory.Read.All' -NoWelcome

try {
    Write-Host "`n=== 1. Locate app registration and service principal ===" -ForegroundColor Cyan
    $appFilter = [Uri]::EscapeDataString("appId eq '$AppId'")
    $app = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=$appFilter" -OutputType PSObject).value)[0]
    if (-not $app) { throw "App registration $AppId not found." }
    $sp = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$appFilter" -OutputType PSObject).value)[0]
    if (-not $sp) { throw "Service principal for $AppId not found." }
    Ok "$($app.displayName) (app objectId $($app.id), SP objectId $($sp.id))"

    # Resolve a resource SP's scope/role names by id, cached.
    $resourceSpCache = @{}
    function Get-ResourceSp([string]$ResourceSpObjectId) {
        if (-not $resourceSpCache.ContainsKey($ResourceSpObjectId)) {
            $resourceSpCache[$ResourceSpObjectId] = Invoke-MgGraphRequest -Method GET `
                -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$ResourceSpObjectId`?`$select=id,appId,displayName,appRoles,oauth2PermissionScopes" -OutputType PSObject
        }
        return $resourceSpCache[$ResourceSpObjectId]
    }

    Write-Host "`n=== 2. Delegated grants (oauth2PermissionGrants) ===" -ForegroundColor Cyan
    $grants = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/oauth2PermissionGrants" -OutputType PSObject).value)
    $seenDelegated = [System.Collections.Generic.List[string]]::new()
    foreach ($g in $grants) {
        $res = Get-ResourceSp $g.resourceId
        $consent = if ($g.consentType -eq 'AllPrincipals') { 'admin, all users' } else { "user $($g.principalId)" }
        foreach ($scope in ($g.scope -split '\s+' | Where-Object { $_ })) {
            $key = "$($res.appId)|$scope"
            [void]$seenDelegated.Add($key)
            if ($key -in $expectedDelegated) {
                Ok "delegated $($res.displayName)/$scope ($consent) — required by code"
            } elseif ($key -in $oidcSignInScopes) {
                Ok "delegated $($res.displayName)/$scope ($consent) — OIDC sign-in claims (Easy Auth / connector sign-in)"
            } elseif ($res.appId -eq $AppId) {
                Ok "delegated (self) $scope ($consent) — the connector scope this app exposes"
            } else {
                Bad "delegated $($res.displayName)/$scope ($consent) — NOT in the code-verified baseline; review and remove"
            }
        }
    }
    foreach ($miss in ($expectedDelegated | Where-Object { $_ -notin $seenDelegated })) {
        Bad "expected delegated grant missing: $miss (a tool path will fail at consent time)"
    }

    Write-Host "`n=== 3. Application permissions (appRoleAssignments) ===" -ForegroundColor Cyan
    $roleAssignments = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments" -OutputType PSObject).value)
    $seenRoles = [System.Collections.Generic.List[string]]::new()
    foreach ($ra in $roleAssignments) {
        $res  = Get-ResourceSp $ra.resourceId
        $role = @($res.appRoles | Where-Object { $_.id -eq $ra.appRoleId })[0]
        $name = if ($role) { $role.value } else { $ra.appRoleId }
        $key  = "$($res.appId)|$name"
        [void]$seenRoles.Add($key)
        if ($key -in $expectedAppRoles) {
            Ok "app role $($res.displayName)/$name — required (eDiscovery data path / export download)"
        } elseif ($redundantAppRoles.ContainsKey($key)) {
            Bad "app role $($res.displayName)/$name — REDUNDANT. $($redundantAppRoles[$key])"
        } else {
            Bad "app role $($res.displayName)/$name — NOT in the code-verified baseline; review and remove"
        }
    }
    foreach ($miss in ($expectedAppRoles | Where-Object { $_ -notin $seenRoles })) {
        Bad "expected app role missing: $miss (eDiscovery data path will fail)"
    }

    Write-Host "`n=== 4. Declared vs granted (requiredResourceAccess drift) ===" -ForegroundColor Cyan
    foreach ($rra in @($app.requiredResourceAccess)) {
        $resSp = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$([Uri]::EscapeDataString("appId eq '$($rra.resourceAppId)'"))" -OutputType PSObject).value)[0]
        foreach ($acc in @($rra.resourceAccess)) {
            if ($acc.type -eq 'Scope') {
                $s = @($resSp.oauth2PermissionScopes | Where-Object { $_.id -eq $acc.id })[0]
                $key = "$($rra.resourceAppId)|$($s.value)"
                if ($key -notin $seenDelegated) { Info "declared but not granted (harmless, prune for tidiness): delegated $($resSp.displayName)/$($s.value)" }
            } else {
                $r = @($resSp.appRoles | Where-Object { $_.id -eq $acc.id })[0]
                $key = "$($rra.resourceAppId)|$($r.value)"
                if ($key -notin $seenRoles) { Info "declared but not granted (harmless, prune for tidiness): app role $($resSp.displayName)/$($r.value)" }
            }
        }
    }
    Ok 'declared-permission drift review complete'

    Write-Host "`n=== 5. Registration posture ===" -ForegroundColor Cyan
    $owners = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/applications/$($app.id)/owners" -OutputType PSObject).value)
    if ($owners.Count -gt 0) { Ok "owners: $($owners.Count)" } else { Bad 'no owners set — add yourself so ownership survives admin churn' }

    if ($sp.appRoleAssignmentRequired) { Ok 'user assignment required: Yes' }
    else { Bad "user assignment required: No — any tenant user can sign in to this app. Set to Yes on the enterprise app and assign the approved users (heads-up: this also gates the Claude connector's Easy Auth sign-ins)." }

    if ($app.signInAudience -eq 'AzureADMyOrg') { Ok 'sign-in audience: AzureADMyOrg (single tenant)' }
    else { Bad "sign-in audience is $($app.signInAudience) — should be AzureADMyOrg" }

    $secrets = @($app.passwordCredentials)
    if ($secrets.Count -le 1) { Ok "client secrets: $($secrets.Count)" }
    else {
        $exp = ($secrets | ForEach-Object { ([datetime]$_.endDateTime).ToString('yyyy-MM-dd') }) -join ', '
        Bad "client secrets: $($secrets.Count) (expiries: $exp) — one is likely a superseded rotation leftover; delete the older one (Rotate-MCPClientSecret.ps1 note applies). If the FIC/managed-identity OBO path is confirmed in prod, consider removing secrets entirely."
    }

    $webUris = @()
    if ($app.PSObject.Properties.Match('web').Count -gt 0 -and $app.web -and $app.web.PSObject.Properties.Match('redirectUris').Count -gt 0) { $webUris = @($app.web.redirectUris) }
    $pubUris = @()
    if ($app.PSObject.Properties.Match('publicClient').Count -gt 0 -and $app.publicClient -and $app.publicClient.PSObject.Properties.Match('redirectUris').Count -gt 0) { $pubUris = @($app.publicClient.redirectUris) }
    foreach ($u in ($webUris + $pubUris)) {
        if ($u -in $legacyRedirects) { Bad "legacy redirect URI present: $u — remove unless something still uses the v1 nativeclient endpoint" }
    }
    Ok "redirect URIs reviewed ($($webUris.Count) web, $($pubUris.Count) public client)"

    Write-Host ''
    if ($issues.Count -eq 0) {
        Write-Host 'ALL CHECKS GREEN — grants match the code-verified baseline.' -ForegroundColor Green
    } else {
        Write-Host "TIGHTENING OPPORTUNITIES ($($issues.Count)):" -ForegroundColor Red
        for ($i = 0; $i -lt $issues.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $issues[$i]) -ForegroundColor Red }
        Write-Host "`nThis script changed nothing. Apply removals in Entra portal > App registrations / Enterprise applications, one at a time, re-testing between steps." -ForegroundColor Yellow
    }
    if ($issues.Count -gt 0) { exit 1 }
}
finally {
    Disconnect-MgGraph | Out-Null
}
