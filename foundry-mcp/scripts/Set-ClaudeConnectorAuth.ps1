#Requires -Version 7.0
# Version: 1.2.0
<#
.SYNOPSIS
    Fixes and diagnoses the Entra side of Claude Desktop's custom connector OAuth.

.DESCRIPTION
    Claude Desktop's connector flow against this MCP fails in a known sequence:

      1. "Automatic client registration isn't supported" — Entra has no Dynamic
         Client Registration; the connector needs the client ID set manually.
      2. "Authorization with Exchange Archive MCP failed" (Entra Trace ID toast) —
         the claude.ai/claude.com callback URIs sit on the WEB platform, so Entra
         treats the client as CONFIDENTIAL and rejects the secretless PKCE token
         exchange (AADSTS7000218). They must be on the PUBLIC CLIENT platform.
      3. Possible consent block — if the tenant restricts user consent, the
         Archive.Read (and Graph OBO) scopes need a tenant-wide admin grant.
      4. AADSTS9010010 "resource parameter doesn't match requested scopes" —
         Claude sends resource=<connector URL> (RFC 8707) while the PRM endpoint
         advertised the api://exchange-mcp scope. The connector URL must itself
         be an identifierUri on the app reg, and the PRM scopes must be prefixed
         with it (function_app.py v2.2.0 + this script's identifier-URI step).

    This script (Graph permissions used by the signed-in admin:
    Application.ReadWrite.All, AuditLog.Read.All, DelegatedPermissionGrant.ReadWrite.All):

      1. Signs into Azure (interactive browser; never device code)
      2. Moves both Claude callback URIs web -> publicClient (idempotent)
      3. Pulls the app's recent FAILED sign-ins from the Entra sign-in log and
         translates the AADSTS codes into plain-English next steps
      4. Reports the app's delegated-consent grants; with -GrantAdminConsent,
         creates the missing tenant-wide grants (Archive.Read on the app itself
         plus the Graph delegated scopes from the app's requiredResourceAccess)
      5. Logs every mutation with timestamp + UPN

    AFTER a clean run, in Claude Desktop: edit the connector, set
    OAuth Client ID = 9519ca68-dae2-4add-8309-4bdd1fa45e79 (client secret blank),
    and click Connect.

.EXAMPLE
    .\Set-ClaudeConnectorAuth.ps1
    .\Set-ClaudeConnectorAuth.ps1 -GrantAdminConsent
#>
[CmdletBinding()]
param(
    [string]$TenantId = '9c1b0b26-717a-4eda-9d7e-7eebc00066bf',
    [string]$AppId    = '9519ca68-dae2-4add-8309-4bdd1fa45e79',

    # The exact URL Claude Desktop connects to — becomes an identifierUri on the
    # app reg so Entra accepts it as the RFC 8707 resource.
    [string]$McpEndpoint = 'https://func-exchange-mcp-archive-mailbox-mcp.azurewebsites.net/runtime/webhooks/mcp',

    # Create tenant-wide admin consent grants for the app's delegated scopes.
    [switch]$GrantAdminConsent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$claudeCallbacks = @(
    'https://claude.ai/api/mcp/auth_callback'
    'https://claude.com/api/mcp/auth_callback'
)

# AADSTS error codes this flow is known to produce, with the fix for each.
$knownErrors = @{
    7000218 = 'Token exchange demanded a client secret -> callback URI was on the WEB platform. This script fixes that (step 3); retry Connect after this run.'
    65001   = 'Consent required and user consent is blocked by tenant policy -> re-run this script with -GrantAdminConsent.'
    65004   = 'User declined consent, or consent prompt was blocked -> retry; if it recurs, use -GrantAdminConsent.'
    90094   = 'Admin approval required for this app -> re-run this script with -GrantAdminConsent.'
    50011   = "Redirect URI mismatch -> a callback URI is missing from the app reg. Verify both claude.ai and claude.com callbacks are listed (this script's step 2/3)."
    500113  = 'No reply address registered -> same fix as 50011.'
    70011   = 'Invalid scope requested -> compare the PRM scopes_supported against the Archive.Read scope exposed on api://exchange-mcp.'
}

$logDir  = Join-Path $PSScriptRoot '..\logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("connector-auth-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
function Write-MutationLog ($action) {
    $upn = az account show --query user.name -o tsv
    "{0:o}  {1}  {2}" -f (Get-Date), $upn, $action | Add-Content -Path $logFile
}

function Ok  ($t) { Write-Host "  [PASS] $t" -ForegroundColor Green }
function No  ($t) { Write-Host "  [FAIL] $t" -ForegroundColor Red }
function Info($t) { Write-Host "  [info] $t" -ForegroundColor DarkGray }

function Invoke-GraphRest {
    param(
        [Parameter(Mandatory)][ValidateSet('get','post','patch')] [string]$Method,
        [Parameter(Mandatory)][string]$Url,
        [hashtable]$Body
    )
    if ($Body) {
        # az.cmd mangles inline JSON quoting on Windows - pass the body via file.
        $bodyFile = Join-Path $env:TEMP "graph-body-$([guid]::NewGuid()).json"
        try {
            $Body | ConvertTo-Json -Depth 10 | Set-Content -Path $bodyFile -Encoding utf8
            az rest --method $Method --url $Url --headers 'Content-Type=application/json' --body "@$bodyFile" -o json | ConvertFrom-Json
        }
        finally { Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue }
    }
    else {
        az rest --method $Method --url $Url -o json | ConvertFrom-Json
    }
}

# Look up a service principal by appId. Deliberately uses ?$filter= instead of the
# servicePrincipals(appId='...') key syntax: the az.cmd batch wrapper re-parses
# arguments, and bare parentheses in an unquoted URL break cmd parsing ("-o was
# unexpected at this time"). The filter form contains spaces, which forces
# PowerShell to quote the whole argument - immune to the batch re-parse.
function Get-SpByAppId ([string]$LookupAppId) {
    $url = 'https://graph.microsoft.com/v1.0/servicePrincipals?' +
           ('$filter=appId eq ''{0}''' -f $LookupAppId)
    $sp = (Invoke-GraphRest -Method get -Url $url).value | Select-Object -First 1
    if (-not $sp) { throw "No service principal found for appId $LookupAppId" }
    $sp
}

# ── 1. Auth (interactive browser; Graph scope needed throughout) ──────────────
Write-Host "`n=== 1. Azure authentication ===" -ForegroundColor Cyan
$graphOk = $false
$acct = az account show -o json 2>$null | ConvertFrom-Json
if ($acct) {
    az ad app show --id $AppId --query appId -o none 2>$null
    if ($LASTEXITCODE -eq 0) { $graphOk = $true }
}
if (-not $graphOk) {
    Info 'Graph token missing/expired - opening browser sign-in.'
    az login --tenant $TenantId --scope 'https://graph.microsoft.com//.default' --output none
}
$acct = az account show -o json | ConvertFrom-Json
Ok "Signed in as $($acct.user.name)."

# ── 2. Read current platform assignment ───────────────────────────────────────
Write-Host "`n=== 2. Current redirect URIs ===" -ForegroundColor Cyan
$appJson = az ad app show --id $AppId -o json | ConvertFrom-Json
$webUris = @($appJson.web.redirectUris)
$pubUris = @($appJson.publicClient.redirectUris)
Info "web          : $($webUris -join ', ')"
Info "publicClient : $($pubUris -join ', ')"

$targetPub = @($pubUris + $claudeCallbacks | Select-Object -Unique)
$targetWeb = @($webUris | Where-Object { $_ -notin $claudeCallbacks })

# ── 3. Move Claude callbacks web -> publicClient ──────────────────────────────
Write-Host "`n=== 3. Platform fix ===" -ForegroundColor Cyan
$alreadyDone = (-not (Compare-Object $targetPub $pubUris)) -and (-not (Compare-Object $targetWeb $webUris))
if ($alreadyDone) {
    Ok 'Claude callbacks already on the public-client platform. Nothing to change.'
}
else {
    Write-MutationLog "PATCH application $AppId : web.redirectUris=[$($targetWeb -join ', ')] publicClient.redirectUris=[$($targetPub -join ', ')]"
    Invoke-GraphRest -Method patch -Url "https://graph.microsoft.com/v1.0/applications/$($appJson.id)" -Body @{
        web          = @{ redirectUris = @($targetWeb) }
        publicClient = @{ redirectUris = @($targetPub) }
    } | Out-Null
    Ok 'Moved Claude callbacks to the public-client platform.'
}

# ── 3b. Identifier URI = connector URL (fixes AADSTS9010010) ──────────────────
Write-Host "`n=== 3b. Identifier URI for the RFC 8707 resource ===" -ForegroundColor Cyan
$idUris = @($appJson.identifierUris)
Info "current: $($idUris -join ', ')"
if ($idUris -contains $McpEndpoint) {
    Ok 'Connector URL already registered as an identifier URI.'
}
else {
    Write-MutationLog "PATCH application $AppId : add identifierUri $McpEndpoint"
    Invoke-GraphRest -Method patch -Url "https://graph.microsoft.com/v1.0/applications/$($appJson.id)" -Body @{
        identifierUris = @($idUris + $McpEndpoint)
    } | Out-Null
    Ok "Added identifier URI: $McpEndpoint"
}

# ── 4. Recent failed sign-ins for this app (why did Connect actually fail?) ───
Write-Host "`n=== 4. Recent sign-in failures (Entra log) ===" -ForegroundColor Cyan
try {
    $url = "https://graph.microsoft.com/v1.0/auditLogs/signIns?" +
           ('$filter=appId eq ''{0}''&$top=15' -f $AppId)
    $signIns = (Invoke-GraphRest -Method get -Url $url).value
    $failures = @($signIns | Where-Object { $_.status.errorCode -ne 0 } | Select-Object -First 5)
    if (-not $failures.Count) {
        Info 'No failed sign-ins recorded for this app (log ingestion can lag a few minutes).'
    }
    foreach ($f in $failures) {
        $code = [int]$f.status.errorCode
        No ("{0}  AADSTS{1}  {2}" -f $f.createdDateTime, $code, $f.status.failureReason)
        if ($knownErrors.ContainsKey($code)) { Write-Host "         FIX: $($knownErrors[$code])" -ForegroundColor Yellow }
    }
}
catch {
    Info "Could not read sign-in logs ($($_.Exception.Message)) - needs AuditLog.Read.All + Entra P1/P2. Continuing."
}

# ── 5. Consent grants ─────────────────────────────────────────────────────────
Write-Host "`n=== 5. Delegated consent grants ===" -ForegroundColor Cyan
$sp = Get-SpByAppId $AppId
$grantsUrl = "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?" + ('$filter=clientId eq ''{0}''' -f $sp.id)
$grants = @((Invoke-GraphRest -Method get -Url $grantsUrl).value)

# Build the desired grant set: the app's own Archive.Read, plus every delegated
# Graph scope declared in requiredResourceAccess.
$desired = @(@{ resourceAppId = $AppId; scopes = @('Archive.Read') })
foreach ($rra in $appJson.requiredResourceAccess) {
    $delegatedIds = @($rra.resourceAccess | Where-Object type -eq 'Scope' | ForEach-Object id)
    if (-not $delegatedIds.Count) { continue }
    $resSp = Get-SpByAppId $rra.resourceAppId
    $names = @($resSp.oauth2PermissionScopes | Where-Object { $_.id -in $delegatedIds } | ForEach-Object value)
    if ($names.Count) { $desired += @{ resourceAppId = $rra.resourceAppId; scopes = $names } }
}

foreach ($d in $desired) {
    $resSp = Get-SpByAppId $d.resourceAppId
    $existing = $grants | Where-Object { $_.resourceId -eq $resSp.id -and $_.consentType -eq 'AllPrincipals' } | Select-Object -First 1
    $have    = if ($existing) { @($existing.scope -split '\s+' | Where-Object { $_ }) } else { @() }
    $missing = @($d.scopes | Where-Object { $_ -notin $have })

    if (-not $missing.Count) {
        Ok "$($resSp.displayName): all scopes granted ($($d.scopes -join ', '))"
    }
    elseif (-not $GrantAdminConsent) {
        No "$($resSp.displayName): missing tenant-wide grant for [$($missing -join ', ')] - re-run with -GrantAdminConsent if Connect fails on consent"
    }
    elseif ($existing) {
        Write-MutationLog "PATCH oauth2PermissionGrant $($existing.id): add scopes [$($missing -join ', ')] on $($resSp.displayName)"
        Invoke-GraphRest -Method patch -Url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants/$($existing.id)" -Body @{
            scope = (($have + $missing) -join ' ')
        } | Out-Null
        Ok "$($resSp.displayName): granted [$($missing -join ', ')]"
    }
    else {
        Write-MutationLog "POST oauth2PermissionGrant: AllPrincipals [$($d.scopes -join ' ')] on $($resSp.displayName) for client $($sp.displayName)"
        Invoke-GraphRest -Method post -Url 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants' -Body @{
            clientId    = $sp.id
            consentType = 'AllPrincipals'
            resourceId  = $resSp.id
            scope       = ($d.scopes -join ' ')
        } | Out-Null
        Ok "$($resSp.displayName): granted [$($d.scopes -join ', ')]"
    }
}

Write-Host @"

Done. Now in Claude Desktop:
  1. Settings -> Connectors -> Exchange Archive -> Edit
  2. OAuth Client ID:  $AppId
     (leave OAuth Client Secret blank - PKCE public client)
  3. Connect -> sign in with your GI account -> consent to Archive.Read

If Connect still fails, re-run this script - section 4 will show the exact
AADSTS code for the newest attempt, with the fix next to it.

Mutation log: $logFile
"@ -ForegroundColor Cyan
