#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication
# Version: 1.1.0
# 1.1.0: default roster = every user observed connecting in the 30d sign-in
#        logs (jmonaco, super-jmonaco, xtsai, egordon, dfishbaum, dave) plus
#        jeff + sandesh (approved 2026-08-11). Individual assignments are
#        interim — Jeff will replace them with a group assignment later.
#        Per-user resolution failures now flag red and continue instead of
#        aborting the run between mutations.
<#
.SYNOPSIS
    Apply the 2026-08-11 audit's remaining tightening items to the shared
    'Exchange Archive MCP' app registration. Idempotent; every mutation logged.

.DESCRIPTION
    Closes the four findings left open by Audit-AppPermissions.ps1:

      1. Remove the REDUNDANT Graph app role eDiscovery.Read.All (assignment
         and, if declared, the requiredResourceAccess entry). ReadWrite.All
         supersedes it. Re-test the export path afterward:
         .\Test-EDiscoveryExport.ps1
      2. Add owner(s) to the app registration and enterprise app (default:
         the signed-in admin).
      3. Set "user assignment required" = Yes on the enterprise app and assign
         the approved users. Default roster: every user observed connecting in
         the 30d sign-in logs plus jeff + sandesh (approved 2026-08-11). Anyone
         NOT assigned is blocked at sign-in after this step. Interim measure -
         to be replaced by a security-group assignment.
      4. Remove the legacy v1 redirect URI
         https://login.microsoftonline.com/common/oauth2/nativeclient
         (local MCP uses WAM broker + loopback; the connector uses the
         claude.ai/claude.com callbacks).

    Re-running after success prints all [OK] and changes nothing. Supports
    -WhatIf. Mutations are logged with timestamp + actor UPN to
    foundry-mcp\logs\tighten-appreg-<ts>.log (transcript captures the full run).

    Graph scopes (delegated, interactive browser - never device code):
    Application.ReadWrite.All, AppRoleAssignment.ReadWrite.All, User.Read.All

.EXAMPLE
    .\Tighten-AppRegistration.ps1
.EXAMPLE
    .\Tighten-AppRegistration.ps1 -AssignUsers jmonaco@gipartners.com, xtsai@gipartners.com, egordon@gipartners.com
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$AppId    = '9519ca68-dae2-4add-8309-4bdd1fa45e79',
    [string]$TenantId = '9c1b0b26-717a-4eda-9d7e-7eebc00066bf',
    # Owners to ensure on the app registration + enterprise app. Empty = the signed-in user.
    [string[]]$Owners = @(),
    # Users allowed to sign in once assignment is required. Interim roster:
    # to be replaced by a security-group assignment.
    [string[]]$AssignUsers = @(
        'jmonaco@gipartners.com'
        'super-jmonaco@gipartners.com'
        'xtsai@gipartners.com'
        'egordon@gipartners.com'
        'dfishbaum@gipartners.com'
        'dave@gipartners.com'
        'jeff@gipartners.com'
        'sandesh@gipartners.com'
    ),
    # Skip step 3 (leave sign-in open to all tenant users).
    [switch]$SkipAssignmentRequired
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogDir = Join-Path $PSScriptRoot '..\logs'
if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
$script:LogPath = Join-Path (Resolve-Path $script:LogDir).Path ("tighten-appreg-{0}.log" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
Start-Transcript -Path $script:LogPath | Out-Null
Write-Host "Logging this run to: $script:LogPath" -ForegroundColor DarkGray

$graphResourceAppId = '00000003-0000-0000-c000-000000000000'
$legacyRedirect     = 'https://login.microsoftonline.com/common/oauth2/nativeclient'
$defaultRoleId      = '00000000-0000-0000-0000-000000000000'

$issues = [System.Collections.Generic.List[string]]::new()
function Ok   ([string]$m) { Write-Host "[OK] $m" -ForegroundColor Green }
function Bad  ([string]$m) { Write-Host "[!!] $m" -ForegroundColor Red; [void]$issues.Add($m) }
function Info ([string]$m) { Write-Host "     $m" -ForegroundColor Yellow }
function Write-MutationLog ([string]$Action) {
    $actor = (Get-MgContext).Account
    $line  = "{0}  MUTATE  actor={1}  {2}" -f (Get-Date).ToUniversalTime().ToString('o'), $actor, $Action
    Write-Host "     $line" -ForegroundColor DarkGray
}

Write-Host 'Connecting to Microsoft Graph (requires Application Administrator or higher)...' -ForegroundColor Cyan
Connect-MgGraph -TenantId $TenantId -Scopes 'Application.ReadWrite.All','AppRoleAssignment.ReadWrite.All','User.Read.All' -NoWelcome

try {
    $appFilter = [Uri]::EscapeDataString("appId eq '$AppId'")
    $app = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=$appFilter" -OutputType PSObject).value)[0]
    $sp  = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$appFilter" -OutputType PSObject).value)[0]
    if (-not $app -or -not $sp) { throw "App registration or service principal for $AppId not found." }
    Ok "$($app.displayName) (app $($app.id), SP $($sp.id))"

    function Resolve-UserId ([string]$Upn) {
        $u = @((Invoke-MgGraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/users?`$filter=" + [Uri]::EscapeDataString("userPrincipalName eq '$Upn'") + '&$select=id,userPrincipalName') -OutputType PSObject).value)[0]
        if (-not $u) { throw "User $Upn not found in the tenant." }
        return $u.id
    }

    # ── 1. Remove redundant app role eDiscovery.Read.All ─────────────────────
    Write-Host "`n=== 1. Remove redundant Graph app role eDiscovery.Read.All ===" -ForegroundColor Cyan
    $graphSp = @((Invoke-MgGraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=" + [Uri]::EscapeDataString("appId eq '$graphResourceAppId'")) -OutputType PSObject).value)[0]
    $readRole = @($graphSp.appRoles | Where-Object { $_.value -eq 'eDiscovery.Read.All' })[0]
    if (-not $readRole) { throw 'Could not resolve the eDiscovery.Read.All role id on the Graph SP.' }

    $assignments = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments" -OutputType PSObject).value)
    $stale = @($assignments | Where-Object { $_.resourceId -eq $graphSp.id -and $_.appRoleId -eq $readRole.id })
    if ($stale.Count -eq 0) {
        Ok 'eDiscovery.Read.All assignment: absent'
    } elseif ($PSCmdlet.ShouldProcess('service principal', 'remove eDiscovery.Read.All appRoleAssignment')) {
        foreach ($a in $stale) {
            Write-MutationLog "DELETE appRoleAssignment $($a.id) (Graph/eDiscovery.Read.All)"
            Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments/$($a.id)" | Out-Null
        }
        Ok 'eDiscovery.Read.All assignment removed - re-test export: .\Test-EDiscoveryExport.ps1'
    }

    # Drop the declaration too, if present.
    $rraAll   = @($app.requiredResourceAccess)
    $graphRra = @($rraAll | Where-Object { $_.resourceAppId -eq $graphResourceAppId })[0]
    if ($graphRra -and (@($graphRra.resourceAccess | Where-Object { $_.id -eq $readRole.id }).Count -gt 0)) {
        if ($PSCmdlet.ShouldProcess('application', 'remove eDiscovery.Read.All from requiredResourceAccess')) {
            $newAccess = @($graphRra.resourceAccess | Where-Object { $_.id -ne $readRole.id })
            $newRra = @($rraAll | Where-Object { $_.resourceAppId -ne $graphResourceAppId })
            $newRra += @{ resourceAppId = $graphResourceAppId; resourceAccess = $newAccess }
            Write-MutationLog 'PATCH application requiredResourceAccess: drop eDiscovery.Read.All declaration'
            Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$($app.id)" `
                -Body (@{ requiredResourceAccess = $newRra } | ConvertTo-Json -Depth 10) -ContentType 'application/json' | Out-Null
            Ok 'eDiscovery.Read.All declaration removed'
        }
    } else {
        Ok 'eDiscovery.Read.All declaration: absent'
    }

    # ── 2. Owners ─────────────────────────────────────────────────────────────
    Write-Host "`n=== 2. Owners ===" -ForegroundColor Cyan
    $ownerUpns = if ($Owners.Count) { $Owners } else { @((Get-MgContext).Account) }
    foreach ($pair in @(@{ kind = 'applications'; id = $app.id }, @{ kind = 'servicePrincipals'; id = $sp.id })) {
        $current = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/$($pair.kind)/$($pair.id)/owners?`$select=id,userPrincipalName" -OutputType PSObject).value)
        foreach ($upn in $ownerUpns) {
            $uid = Resolve-UserId $upn
            if (@($current | Where-Object { $_.id -eq $uid }).Count -gt 0) {
                Ok "$($pair.kind) owner: $upn (already present)"
            } elseif ($PSCmdlet.ShouldProcess($pair.kind, "add owner $upn")) {
                Write-MutationLog "POST $($pair.kind)/$($pair.id)/owners/`$ref add $upn"
                Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/$($pair.kind)/$($pair.id)/owners/`$ref" `
                    -Body (@{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$uid" } | ConvertTo-Json) -ContentType 'application/json' | Out-Null
                Ok "$($pair.kind) owner added: $upn"
            }
        }
    }

    # ── 3. User assignment required + assignments ─────────────────────────────
    Write-Host "`n=== 3. User assignment required ===" -ForegroundColor Cyan
    if ($SkipAssignmentRequired) {
        Info 'Skipped by -SkipAssignmentRequired.'
    } else {
        # Assign users FIRST so nobody approved is locked out between the two mutations.
        $assigned = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignedTo" -OutputType PSObject).value)
        foreach ($upn in $AssignUsers) {
            try { $uid = Resolve-UserId $upn }
            catch { Bad "cannot assign ${upn}: $($_.Exception.Message)"; continue }
            if (@($assigned | Where-Object { $_.principalId -eq $uid }).Count -gt 0) {
                Ok "assigned: $upn (already)"
            } elseif ($PSCmdlet.ShouldProcess('enterprise app', "assign user $upn")) {
                Write-MutationLog "POST appRoleAssignedTo: $upn (default role)"
                Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignedTo" `
                    -Body (@{ principalId = $uid; resourceId = $sp.id; appRoleId = $defaultRoleId } | ConvertTo-Json) -ContentType 'application/json' | Out-Null
                Ok "assigned: $upn"
            }
        }
        if ($sp.appRoleAssignmentRequired) {
            Ok 'appRoleAssignmentRequired: already true'
        } elseif ($PSCmdlet.ShouldProcess('enterprise app', 'set appRoleAssignmentRequired = true')) {
            Write-MutationLog 'PATCH servicePrincipal appRoleAssignmentRequired=true'
            Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)" `
                -Body (@{ appRoleAssignmentRequired = $true } | ConvertTo-Json) -ContentType 'application/json' | Out-Null
            Ok 'appRoleAssignmentRequired set to true'
        }
        Info "Sign-in now limited to: $($AssignUsers -join ', ')"
        Info 'Interim per-user assignments — when the security group exists, assign the group in'
        Info 'the portal (Enterprise app > Users and groups) and remove the individual entries.'
    }

    # ── 4. Legacy redirect URI ────────────────────────────────────────────────
    Write-Host "`n=== 4. Legacy nativeclient redirect URI ===" -ForegroundColor Cyan
    $pubUris = @()
    if ($app.PSObject.Properties.Match('publicClient').Count -gt 0 -and $app.publicClient -and $app.publicClient.PSObject.Properties.Match('redirectUris').Count -gt 0) {
        $pubUris = @($app.publicClient.redirectUris)
    }
    if ($pubUris -notcontains $legacyRedirect) {
        Ok 'legacy nativeclient redirect URI: absent'
    } elseif ($PSCmdlet.ShouldProcess('application', "remove redirect URI $legacyRedirect")) {
        $kept = @($pubUris | Where-Object { $_ -ne $legacyRedirect })
        Write-MutationLog "PATCH application publicClient.redirectUris: remove $legacyRedirect"
        Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$($app.id)" `
            -Body (@{ publicClient = @{ redirectUris = $kept } } | ConvertTo-Json -Depth 5) -ContentType 'application/json' | Out-Null
        Ok "legacy redirect URI removed ($($kept.Count) public-client URIs remain)"
    }

    Write-Host ''
    if ($issues.Count -eq 0) {
        Write-Host 'ALL STEPS APPLIED / VERIFIED.' -ForegroundColor Green
        Write-Host 'Next: 1) .\Test-EDiscoveryExport.ps1 (confirm export path post role-removal)' -ForegroundColor Yellow
        Write-Host '      2) .\Audit-AppPermissions.ps1 (expect ALL CHECKS GREEN)' -ForegroundColor Yellow
        Write-Host '      3) Reconnect + one tool call in Claude (confirm assignment gating kept you in)' -ForegroundColor Yellow
    } else {
        Write-Host "PROBLEMS ($($issues.Count)):" -ForegroundColor Red
        for ($i = 0; $i -lt $issues.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $issues[$i]) -ForegroundColor Red }
    }
}
finally {
    if (Get-MgContext) { Disconnect-MgGraph | Out-Null; Write-Host 'Disconnected from Microsoft Graph.' -ForegroundColor DarkGray }
    Write-Host "`nLog saved to: $script:LogPath" -ForegroundColor Cyan
    Stop-Transcript | Out-Null
}
