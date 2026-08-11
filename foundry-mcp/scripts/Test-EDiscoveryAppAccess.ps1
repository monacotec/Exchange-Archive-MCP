# Version: 1.2.0
# 1.2.0 (2026-08-11): baseline updated for the least-privilege pass —
#   eDiscovery.Read.All was REMOVED as redundant (ReadWrite.All supersedes);
#   its absence is now the PASS and its presence the failure. The legacy
#   standing-case replay (section 4) is reframed as a gate check: those 401s
#   are the case-ownership gate working as designed (production uses
#   one-case-per-caller app-owned cases since ediscovery.py v1.7.0).
# Test-EDiscoveryAppAccess.ps1 — replays the function's app-only eDiscovery
# calls from your shell, to separate "token is wrong" from "service-side RBAC
# not propagated / case tier".
#
# What it does (read-only except the same noncustodialDataSource POST the
# function attempts):
#   1. Reads the app's client secret from Key Vault (az; you are signed in)
#   2. Gets an app-only Graph token via client_credentials — same identity
#      the function uses on its fallback path
#   3. DECODES the token and prints its `roles` claim — eDiscovery.Read.All /
#      eDiscovery.ReadWrite.All must be present (granted by
#      Initialize-EDiscoveryAccess.ps1)
#   4. GET the standing case, GET its noncustodialDataSources, then the same
#      POST the function makes — printing full status + body on failure
#
# Interpretation:
#   roles MISSING from token       -> app-role assignment hasn't propagated;
#                                     wait 15-30 min and re-run
#   roles present, calls 401/403   -> Purview-side RBAC (eDiscovery Manager
#                                     membership) still propagating (up to
#                                     ~60 min), or the case needs premium
#                                     features enabled for app-only access
#   everything 200/201             -> service is ready; retry the MCP tool
#
# Works in PS 5.1 or PS 7.

param(
    [string]$TenantId  = '9c1b0b26-717a-4eda-9d7e-7eebc00066bf',
    [string]$AppId     = '9519ca68-dae2-4add-8309-4bdd1fa45e79',
    [string]$VaultName = 'kv-exmcp-gi',
    [string]$CaseId    = '560a5270-0d08-484a-a905-63b642f5c30d',
    [string]$TestUpn   = 'jmonaco@gipartners.com'
)

$ErrorActionPreference = 'Stop'

# Capture the whole run to a log file in the project (foundry-mcp\logs\).
$script:LogDir = Join-Path $PSScriptRoot '..\logs'
if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
$script:LogPath = Join-Path (Resolve-Path $script:LogDir).Path ("ediscovery-appaccess-{0}.log" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
Start-Transcript -Path $script:LogPath | Out-Null
Write-Host "Logging this run to: $script:LogPath" -ForegroundColor DarkGray

function Ok  ($t) { Write-Host "  [PASS] $t" -ForegroundColor Green }
function No  ($t) { Write-Host "  [FAIL] $t" -ForegroundColor Red }
function Info($t) { Write-Host "  [info] $t" -ForegroundColor DarkGray }

# ── 1. Client secret from Key Vault ───────────────────────────────────────────
Write-Host "`n=== 1. Key Vault secret ===" -ForegroundColor Cyan
$secret = az keyvault secret show --vault-name $VaultName --name mcp-exchange-client-secret --query value -o tsv
if (-not $secret) { throw "Could not read mcp-exchange-client-secret from $VaultName (az signed in?)" }
Ok 'Secret retrieved (not displayed).'

# ── 2. App-only token (client_credentials — same as the function's fallback) ──
Write-Host "`n=== 2. App-only Graph token ===" -ForegroundColor Cyan
$tokenResp = Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
    -Body @{
        grant_type    = 'client_credentials'
        client_id     = $AppId
        client_secret = $secret
        scope         = 'https://graph.microsoft.com/.default'
    }
$token = $tokenResp.access_token
Ok 'Token acquired.'

# ── 3. Decode the roles claim ─────────────────────────────────────────────────
Write-Host "`n=== 3. Token roles claim ===" -ForegroundColor Cyan
$payload = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
$claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
$roles = @()
if ($claims.PSObject.Properties.Match('roles').Count -gt 0) { $roles = @($claims.roles) }
Info ("roles: " + ($(if ($roles.Count) { $roles -join ', ' } else { '(none)' })))
if ($roles -contains 'eDiscovery.ReadWrite.All') { Ok 'eDiscovery.ReadWrite.All present in token (the one required role)' }
else { No 'eDiscovery.ReadWrite.All MISSING from token - app-role assignment not propagated yet; wait and re-run' }
# Least-privilege pass 2026-08-11: Read.All was removed as redundant. Its
# absence is the desired state; presence means a cached token (~1h lifetime)
# or the removal has not propagated.
if ($roles -contains 'eDiscovery.Read.All') { No 'eDiscovery.Read.All STILL in token - removed 2026-08-11 as redundant; token may be cached (~1h) or removal not yet propagated' }
else { Ok 'eDiscovery.Read.All absent (removed 2026-08-11 - desired least-privilege state)' }

# ── 4. Legacy standing case: the case-ownership gate (401s are EXPECTED) ─────
# The app is an eDiscovery MANAGER and only reaches cases it created itself;
# this human-created case proved that gate on 2026-07-22. Production has used
# app-owned one-case-per-caller since ediscovery.py v1.7.0 — section 5 is the
# check that reflects the live data path.
Write-Host "`n=== 4. Legacy standing case (expected 401s - case-ownership gate) ===" -ForegroundColor Cyan
$headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }
$base = "https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases"

function Try-Call ($Method, $Url, $Body, $Label, [switch]$ExpectGated) {
    try {
        if ($Body) { $r = Invoke-RestMethod -Method $Method -Uri $Url -Headers $headers -Body $Body }
        else       { $r = Invoke-RestMethod -Method $Method -Uri $Url -Headers $headers }
        if ($ExpectGated) { Info "$Label -> unexpectedly SUCCEEDED (gate no longer applies to this case?)" }
        else { Ok $Label }
        return $r
    }
    catch {
        $status = ''
        $bodyText = ''
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
            try { $bodyText = $_.ErrorDetails.Message } catch {}
        }
        if ($ExpectGated -and $status -eq 401) {
            Ok ("{0} -> HTTP 401 (case-ownership gate intact - expected)" -f $Label)
        } else {
            No ("{0} -> HTTP {1}  {2}" -f $Label, $status, ($bodyText -replace '\s+', ' '))
        }
        return $null
    }
}

$case = Try-Call GET "$base/$CaseId" $null "GET legacy case $CaseId" -ExpectGated
if ($case) { Info ("case: '{0}'  status: {1}" -f $case.displayName, $case.status) }

Try-Call GET "$base/$CaseId/noncustodialDataSources" $null 'GET noncustodialDataSources (legacy case)' -ExpectGated | Out-Null

$ncBody = @{ dataSource = @{ '@odata.type' = 'microsoft.graph.security.userSource'; email = $TestUpn } } | ConvertTo-Json -Depth 5
Try-Call POST "$base/$CaseId/noncustodialDataSources" $ncBody "POST noncustodialDataSource (legacy case)" -ExpectGated | Out-Null

# ── 5. Case-ownership hypothesis ──────────────────────────────────────────────
# eDiscovery MANAGERS only see cases they created or are members of. The
# standing case was created by super-jmonaco, not the app. If the app can
# create and use ITS OWN case, the fix is app-owned-case, not broader rights.
Write-Host "`n=== 5. Can the app create and use its OWN case? ===" -ForegroundColor Cyan
$listing = Try-Call GET ($base + '?$top=5') $null 'GET case list (app-visible cases)'
if ($listing) { Info ("app sees {0} case(s)" -f @($listing.value).Count) }

$testCaseBody = @{
    displayName = ('mcp-appaccess-test-{0:yyyyMMddHHmmss}' -f (Get-Date))
    description = 'App-only access probe. Safe to delete.'
} | ConvertTo-Json
$testCase = Try-Call POST $base $testCaseBody 'POST create app-owned test case'
if ($testCase) {
    Info ("app-owned case id: {0}" -f $testCase.id)
    Try-Call GET "$base/$($testCase.id)" $null 'GET the app-owned case back' | Out-Null
    Try-Call POST "$base/$($testCase.id)/noncustodialDataSources" $ncBody "POST noncustodialDataSource in the app-owned case" | Out-Null
    # Cases must be closed before deletion; try close then delete, tolerate failure.
    Try-Call POST "$base/$($testCase.id)/close" $null 'close test case' | Out-Null
    Try-Call DELETE "$base/$($testCase.id)" $null 'delete test case' | Out-Null
    Write-Host "`n  If the app-owned calls PASSED while section 4 FAILED: the fix is app-owned-case (code change on Claude's side, no new permissions)." -ForegroundColor Yellow
}
else {
    Write-Host "`n  App cannot create cases either -> app-only is blocked service-side: Purview RBAC still propagating (wait ~30-60 min from init and re-run), or app-only needs premium features / eDiscovery Administrator." -ForegroundColor Yellow
}

Write-Host "`nLog saved to: $script:LogPath" -ForegroundColor Cyan
Write-Host 'Give the log file (or paste its contents) back to Claude.' -ForegroundColor Cyan
Stop-Transcript | Out-Null
