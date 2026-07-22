#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication
# Rev 2026-07-13 (v2.0.0): rewritten to the rev-2 shared-app-reg / delegated-OBO design
#   (FOUNDRY-MCP-PLAN §5.1; REMEDIATION-GUIDE Lesson 1). The rev-1 version created a
#   separate app with APPLICATION permissions (Mail.Read Role) — the confused-deputy
#   pattern. This version UPDATES the existing shared app reg instead:
#     - delegated Graph permissions only (never application Roles)
#     - exposes api://exchange-mcp with the Archive.Read delegated scope
#     - Claude Connectors redirect URIs on the web platform
#     - access token version 2
#     - optional OBO client secret (required for the MSAL OBO fallback path and for
#       the Functions MCP extension's OBO exchange) stored straight to Key Vault
#   Session teardown stays in try/finally (finding 45).
<#
.SYNOPSIS
    Configures the shared Entra app registration for the Foundry Exchange Archive MCP.

.DESCRIPTION
    Idempotent Phase 0 setup. Both MCPs (local stdio + Foundry) share one app
    registration; the local MCP's loopback/WAM public-client setup is left untouched.
    This script layers on what the Foundry MCP needs:

      1. Verifies the app exists and reports its current state.
      2. Warns if any APPLICATION (Role) Graph permissions are present — the rev-2
         design is delegated-only. Removal is deliberate and manual.
      3. Ensures delegated Graph permissions: Mail.Read, User.Read, offline_access.
      4. Sets the Application ID URI (api://exchange-mcp) and adds the Archive.Read
         delegated scope if missing.
      5. Ensures web redirect URIs for the Claude Connectors UI callbacks.
      6. Sets requestedAccessTokenVersion = 2.
      7. With -CreateOboSecret: creates a 1-year client secret and stores it in
         Key Vault (mcp-exchange-client-secret) together with mcp-entra-client-id
         and the JWT validation trio (mcp-jwt-audience / issuer / jwks-uri).
         NEVER echoes the secret.

    Admin consent for any newly added delegated permissions must still be granted
    in the portal — the script prints the link.

.PARAMETER AppId
    Client ID of the shared app registration. Defaults to the GI Partners
    'Exchange Archive MCP' app created in Local MCP Phase 0.

.PARAMETER TenantId
    Entra tenant GUID.

.PARAMETER KeyVaultName
    Key Vault for secret storage. Required when -CreateOboSecret is set; the JWT
    validation secrets are also written when this is supplied. Requires Az.KeyVault
    and an authenticated Az context.

.PARAMETER CreateOboSecret
    Create and store the OBO client secret. Omit for a config-only run.

.EXAMPLE
    # Config-only pass (no secret):
    .\Register-EntraApp.ps1

.EXAMPLE
    # Full Phase 0 including the OBO secret into KV:
    .\Register-EntraApp.ps1 -KeyVaultName 'kv-gipartners-ai-prod' -CreateOboSecret
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $AppId    = '9519ca68-dae2-4add-8309-4bdd1fa45e79',
    [string] $TenantId = '9c1b0b26-717a-4eda-9d7e-7eebc00066bf',
    [string] $KeyVaultName,
    [switch] $CreateOboSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($CreateOboSecret -and -not $KeyVaultName) {
    throw '-CreateOboSecret requires -KeyVaultName (the secret is stored, never displayed).'
}

$identifierUri = 'api://exchange-mcp'
$graphResourceId = '00000003-0000-0000-c000-000000000000'
# Delegated (Scope) permission IDs on Microsoft Graph
$delegatedScopes = @(
    @{ Id = '570282fd-fa5c-430d-a7fd-fc8dc98a9dca'; Name = 'Mail.Read' }
    @{ Id = 'e1fe6dd8-ba31-4d61-89e7-88639da4683d'; Name = 'User.Read' }
    @{ Id = '7427e0e9-2fba-42fe-b0c0-848c9e6a8182'; Name = 'offline_access' }
)
$webRedirects = @(
    'https://claude.ai/api/mcp/auth_callback'
    'https://claude.com/api/mcp/auth_callback'
)

Write-Host 'Connecting to Microsoft Graph (requires Application Administrator or higher)...' -ForegroundColor Cyan
Connect-MgGraph -TenantId $TenantId -Scopes 'Application.ReadWrite.All' -NoWelcome

try {
    # ── Step 1: Locate the shared app ─────────────────────────────────────────
    $lookupUri = 'https://graph.microsoft.com/v1.0/applications?$filter=' +
                 [Uri]::EscapeDataString("appId eq '$AppId'")
    $apps = @((Invoke-MgGraphRequest -Method GET -Uri $lookupUri -OutputType PSObject).value)
    if ($apps.Count -eq 0) {
        throw "App registration with appId $AppId not found. Create the shared app reg first (Local MCP Phase 0 step 1)."
    }
    $app = $apps[0]
    Write-Host "Found: $($app.displayName) (objectId $($app.id))" -ForegroundColor Green

    $patch = @{}
    $consentNeeded = $false

    # ── Step 2: Application-permission (Role) audit — warn only ──────────────
    $graphRra = @($app.requiredResourceAccess) | Where-Object { $_.resourceAppId -eq $graphResourceId }
    $existingAccess = if ($graphRra) { @($graphRra.resourceAccess) } else { @() }
    $appOnlyRoles = @($existingAccess | Where-Object { $_.type -eq 'Role' })
    if ($appOnlyRoles.Count -gt 0) {
        Write-Warning "App has $($appOnlyRoles.Count) APPLICATION permission(s) on Graph. Rev-2 design is delegated-only (REMEDIATION-GUIDE Lesson 1). Review and remove them in the portal — this script will not remove permissions."
    }

    # ── Step 3: Ensure delegated Graph permissions ────────────────────────────
    $missingScopes = @($delegatedScopes | Where-Object { $_.Id -notin @($existingAccess | ForEach-Object { $_.id }) })
    if ($missingScopes.Count -gt 0) {
        Write-Host "Adding delegated permissions: $($missingScopes.Name -join ', ')" -ForegroundColor Yellow
        $merged = @($existingAccess) + @($missingScopes | ForEach-Object { @{ id = $_.Id; type = 'Scope' } })
        $otherRra = @($app.requiredResourceAccess) | Where-Object { $_.resourceAppId -ne $graphResourceId }
        $patch.requiredResourceAccess = @($otherRra) + @(@{ resourceAppId = $graphResourceId; resourceAccess = $merged })
        $consentNeeded = $true
    } else {
        Write-Host 'Delegated Graph permissions already present.' -ForegroundColor Green
    }

    # ── Step 4: Application ID URI + Archive.Read scope ───────────────────────
    if (@($app.identifierUris) -notcontains $identifierUri) {
        Write-Host "Setting Application ID URI: $identifierUri" -ForegroundColor Yellow
        $patch.identifierUris = @(@($app.identifierUris) + $identifierUri | Select-Object -Unique)
    }

    $existingApiScopes = @()
    if ($app.api -and $app.api.oauth2PermissionScopes) { $existingApiScopes = @($app.api.oauth2PermissionScopes) }
    $archiveRead = $existingApiScopes | Where-Object { $_.value -eq 'Archive.Read' }
    if (-not $archiveRead) {
        Write-Host 'Adding exposed scope: Archive.Read' -ForegroundColor Yellow
        $newScope = @{
            id                      = [guid]::NewGuid().ToString()
            value                   = 'Archive.Read'
            type                    = 'Admin'
            isEnabled               = $true
            adminConsentDisplayName = 'Read Exchange archive mailbox'
            adminConsentDescription = "Allows the application to read items in the signed-in user's Exchange Online archive mailbox via the Exchange Archive MCP."
        }
        $patch.api = @{
            oauth2PermissionScopes      = @($existingApiScopes | ForEach-Object {
                # re-emit existing scopes untouched (PATCH replaces the collection)
                @{
                    id = $_.id; value = $_.value; type = $_.type; isEnabled = $_.isEnabled
                    adminConsentDisplayName = $_.adminConsentDisplayName
                    adminConsentDescription = $_.adminConsentDescription
                    userConsentDisplayName  = $_.userConsentDisplayName
                    userConsentDescription  = $_.userConsentDescription
                }
            }) + $newScope
            requestedAccessTokenVersion = 2
        }
    } else {
        Write-Host 'Archive.Read scope already exposed.' -ForegroundColor Green
        $tokenVersion = if ($app.api) { $app.api.requestedAccessTokenVersion } else { $null }
        if ($tokenVersion -ne 2) {
            $patch.api = @{ requestedAccessTokenVersion = 2 }
        }
    }

    # ── Step 5: Claude Connectors web redirect URIs ───────────────────────────
    $existingWeb = @()
    if ($app.web -and $app.web.redirectUris) { $existingWeb = @($app.web.redirectUris) }
    $missingWeb = @($webRedirects | Where-Object { $_ -notin $existingWeb })
    if ($missingWeb.Count -gt 0) {
        Write-Host "Adding web redirect URIs: $($missingWeb -join ', ')" -ForegroundColor Yellow
        $patch.web = @{ redirectUris = @($existingWeb + $missingWeb | Select-Object -Unique) }
    } else {
        Write-Host 'Claude Connectors redirect URIs already present.' -ForegroundColor Green
    }

    # ── Apply patch ───────────────────────────────────────────────────────────
    if ($patch.Count -gt 0) {
        if ($PSCmdlet.ShouldProcess($app.displayName, "PATCH application ($($patch.Keys -join ', '))")) {
            Invoke-MgGraphRequest -Method PATCH `
                -Uri "https://graph.microsoft.com/v1.0/applications/$($app.id)" `
                -Body ($patch | ConvertTo-Json -Depth 10) `
                -ContentType 'application/json' | Out-Null
            Write-Host 'Application updated.' -ForegroundColor Green
        }
    } else {
        Write-Host 'No application changes needed — already at rev-2 spec.' -ForegroundColor Green
    }

    # ── Step 6: OBO secret + Key Vault ────────────────────────────────────────
    if ($KeyVaultName) {
        Import-Module Az.KeyVault -ErrorAction Stop
        if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
            throw 'No Az context. Run Connect-AzAccount before using -KeyVaultName.'
        }

        $kvWrites = [ordered]@{
            'mcp-entra-client-id' = $AppId
            'mcp-jwt-audience'    = $identifierUri
            'mcp-jwt-issuer'      = "https://login.microsoftonline.com/$TenantId/v2.0"
            'mcp-jwks-uri'        = "https://login.microsoftonline.com/$TenantId/discovery/v2.0/keys"
        }
        foreach ($name in $kvWrites.Keys) {
            if ($PSCmdlet.ShouldProcess("$KeyVaultName/$name", 'Set Key Vault secret')) {
                Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $name `
                    -SecretValue (ConvertTo-SecureString $kvWrites[$name] -AsPlainText -Force) | Out-Null
                Write-Host "  KV secret set: $name" -ForegroundColor Green
            }
        }

        if ($CreateOboSecret) {
            if ($PSCmdlet.ShouldProcess($app.displayName, 'Create OBO client secret (1 year)')) {
                $secretBody = @{
                    passwordCredential = @{
                        displayName = "MCP-OBO-$(Get-Date -Format 'yyyy-MM')"
                        endDateTime = (Get-Date).AddYears(1).ToUniversalTime().ToString('o')
                    }
                } | ConvertTo-Json -Depth 5
                $secret = Invoke-MgGraphRequest -Method POST `
                    -Uri "https://graph.microsoft.com/v1.0/applications/$($app.id)/addPassword" `
                    -Body $secretBody -ContentType 'application/json' -OutputType PSObject
                Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name 'mcp-exchange-client-secret' `
                    -SecretValue (ConvertTo-SecureString $secret.secretText -AsPlainText -Force) | Out-Null
                $secret = $null   # never echo; clear from memory
                Write-Host '  OBO client secret created and stored as mcp-exchange-client-secret.' -ForegroundColor Green
                Write-Host '  Rotate via Rotate-MCPClientSecret.ps1 (supports -RevokeOld).' -ForegroundColor DarkGray
            }
        }
    } elseif ($CreateOboSecret) {
        # unreachable due to the parameter guard, kept for clarity
    } else {
        Write-Host 'No -KeyVaultName supplied — skipped KV secret writes (config-only run).' -ForegroundColor DarkGray
    }

    # ── Summary ───────────────────────────────────────────────────────────────
    Write-Host ''
    Write-Host 'Phase 0 app-reg state:' -ForegroundColor Cyan
    Write-Host "  AppId              : $AppId"
    Write-Host "  Application ID URI : $identifierUri"
    Write-Host "  Exposed scope      : Archive.Read"
    Write-Host "  Token version      : 2"
    if ($consentNeeded) {
        Write-Host ''
        Write-Host '[ACTION REQUIRED] Grant admin consent for the newly added delegated permissions:' -ForegroundColor Magenta
        Write-Host "  https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/$AppId"
    }
}
finally {
    # Findings 45/46: guaranteed disconnect even when a step throws mid-run.
    if (Get-MgContext) {
        Disconnect-MgGraph | Out-Null
        Write-Host 'Disconnected from Microsoft Graph.' -ForegroundColor DarkGray
    }
}
