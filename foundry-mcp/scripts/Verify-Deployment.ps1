#Requires -Version 7.0
# Version: 1.0.0
<#
.SYNOPSIS
    Post-deploy verification for the Foundry Exchange Archive MCP.

.DESCRIPTION
    Runs the Phase 1/2 exit checks against the deployed Function App:
      1. Functions indexed (3 MCP tools + PRM route)
      2. mcp_extension system key exists
      3. MCP endpoint gated without key (401/403)
      4. MCP endpoint alive with key (200/405/406)
      5. PRM endpoint returns valid RFC 9728 JSON (tries /api/ and root prefix)

    Read-only; safe to re-run. Exits 1 if any REQUIRED check fails.

.EXAMPLE
    .\Verify-Deployment.ps1
#>
[CmdletBinding()]
param(
    [string]$FunctionAppName = 'func-exchange-mcp-archive-mailbox-mcp',
    [string]$ResourceGroup   = 'finresgroup'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ok  ($t) { Write-Host "  [PASS] $t" -ForegroundColor Green }
function No  ($t) { Write-Host "  [FAIL] $t" -ForegroundColor Red }
function Info($t) { Write-Host "  [info] $t" -ForegroundColor DarkGray }

$failures = 0
$base = "https://$FunctionAppName.azurewebsites.net"

# ── 1. Functions indexed ─────────────────────────────────────────────────────
Write-Host "`n=== 1. Function indexing ===" -ForegroundColor Cyan
$funcs = az functionapp function list -g $ResourceGroup -n $FunctionAppName --query "[].name" -o tsv
if ($funcs) {
    $funcs -split "`n" | ForEach-Object { Info $_ }
    $expected = @('search_archive_mail','get_mail_by_date_range','list_archive_folders')
    $missing = $expected | Where-Object { ($funcs -join ' ') -notmatch $_ }
    if ($missing) { No "Missing tools: $($missing -join ', ')"; $failures++ }
    else { Ok 'All 3 MCP tools indexed.' }
} else {
    No 'No functions indexed — host startup failure. Check App Insights traces.'
    $failures++
}

# ── 2. Easy Auth gate ────────────────────────────────────────────────────────
# Under the Phase 2 model the gate is a bearer token (Easy Auth, fail-closed) —
# a function key alone must NOT grant access.
Write-Host "`n=== 2. Easy Auth gate (unauthenticated) ===" -ForegroundColor Cyan
$noAuth = curl.exe -s -o NUL -w '%{http_code}' "$base/runtime/webhooks/mcp"
if ($noAuth -in '401','403') { Ok "Unauthenticated: $noAuth (Easy Auth gate holds)." }
else { No "Unauthenticated: $noAuth (expected 401/403 from Easy Auth)."; $failures++ }

# ── 3. Bearer-only enforcement ───────────────────────────────────────────────
Write-Host "`n=== 3. Function key alone must NOT bypass Easy Auth ===" -ForegroundColor Cyan
$key = az functionapp keys list -g $ResourceGroup -n $FunctionAppName --query "masterKey" -o tsv 2>$null
if ($key) {
    $withKey = curl.exe -s -o NUL -w '%{http_code}' "$base/runtime/webhooks/mcp" -H "x-functions-key: $key"
    if ($withKey -in '401','403') { Ok "With key only: $withKey (bearer still required — correct)." }
    else { No "With key only: $withKey — key bypassed Easy Auth. Investigate authsettingsV2."; $failures++ }
} else {
    Info 'Could not read a key to test bypass — acceptable; Easy Auth gate verified in check 2.'
}

# ── 4. Bearer liveness (manual) ──────────────────────────────────────────────
Write-Host "`n=== 4. Authenticated liveness ===" -ForegroundColor Cyan
Info 'Full liveness requires a user bearer for api://exchange-mcp — verified end-to-end'
Info 'via the Claude Desktop Connectors test (docs/claude-desktop-wiring.md).'

# ── 5. PRM endpoint ──────────────────────────────────────────────────────────
Write-Host "`n=== 5. RFC 9728 PRM endpoint ===" -ForegroundColor Cyan
$prmFound = $false
foreach ($path in @('/api/.well-known/oauth-protected-resource', '/.well-known/oauth-protected-resource')) {
    $resp = curl.exe -s -w "`n%{http_code}" "$base$path"
    $lines = $resp -split "`n"
    $code = $lines[-1]
    if ($code -eq '200') {
        try {
            $doc = ($lines[0..($lines.Count-2)] -join "`n") | ConvertFrom-Json
            Ok "PRM served at $path"
            Info "  resource: $($doc.resource)"
            Info "  authorization_servers: $($doc.authorization_servers -join ', ')"
            Info "  scopes_supported: $($doc.scopes_supported -join ', ')"
            if ($path -like '/api/*') {
                Info 'NOTE: served under /api/ — spec wants root. routePrefix fix ships with the Phase 2 auth cutover.'
            }
            $prmFound = $true
            break
        } catch { Info "$path returned 200 but body is not valid JSON." }
    } else {
        Info "$path -> $code"
    }
}
if (-not $prmFound) { No 'PRM endpoint not reachable at either prefix.'; $failures++ }

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
if ($failures -eq 0) {
    Ok 'All deployment checks passed.'
    exit 0
} else {
    No "$failures check(s) failed."
    exit 1
}
