#Requires -Version 7.0
# Version: 1.1.0
# 1.1.0: (a) live current-bundle probe via ARM listkeys + /admin/host/status
#        (az-tunneled, so the per-process HTTPS block doesn't bite); (b) version
#        summary now parsed client-side from the Host Status JSON — the KQL
#        path-regex missed it (version is a JSON field, not a path segment).
<#
.SYNOPSIS
    Show which Functions extension-bundle versions the host loaded over time (read-only).

.DESCRIPTION
    host.json pins Microsoft.Azure.Functions.ExtensionBundle.Preview with a
    FLOATING range [4.*, 5.0.0). The MCP extension ships inside that bundle, so
    a host recycle can silently adopt a newer preview bundle with breaking MCP
    handshake changes - no deploy, no config change, nothing in the activity
    log. Symptom observed 2026-08-11: new connector sessions get "no tools
    available" while established sessions still call tools fine; last known-good
    new-session behavior ~2026-08-04.

    The host logs the bundle it loads at every startup. This script pulls those
    rows from Log Analytics and summarizes version-by-time, so a version flip
    right after the last-good date is the smoking gun. The fix is then to PIN
    host.json to the last-good version and redeploy.

.EXAMPLE
    .\Get-McpBundleHistory.ps1 -DaysBack 30
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId  = 'db17a4a4-f677-498a-b4a2-eb401ba9cf29',
    [string]$ResourceGroup   = 'finresgroup',
    [string]$WorkspaceName   = 'law-exchange-mcp-archive-mailbox-mcp',
    [string]$FunctionAppName = 'func-exchange-mcp-archive-mailbox-mcp',
    [int]$DaysBack           = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Capture the whole run to a log file in the project (foundry-mcp\logs\).
$script:LogDir = Join-Path $PSScriptRoot '..\logs'
if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
$script:LogPath = Join-Path (Resolve-Path $script:LogDir).Path ("mcp-bundle-history-{0}.log" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
Start-Transcript -Path $script:LogPath | Out-Null
Write-Host "Logging this run to: $script:LogPath" -ForegroundColor DarkGray

function Ok   ($t) { Write-Host "  [PASS] $t" -ForegroundColor Green }
function Warn ($t) { Write-Host "  [warn] $t" -ForegroundColor Yellow }
function Info ($t) { Write-Host "  [info] $t" -ForegroundColor DarkGray }

function Invoke-LaQuery ([string]$CustomerId, [string]$Kql) {
    $bodyFile = Join-Path $env:TEMP "la-query-$([guid]::NewGuid()).json"
    try {
        @{ query = $Kql; timespan = "P${DaysBack}D" } | ConvertTo-Json | Set-Content $bodyFile -Encoding utf8
        az rest --method post `
            --resource 'https://api.loganalytics.io' `
            --url "https://api.loganalytics.io/v1/workspaces/$CustomerId/query" `
            --headers 'Content-Type=application/json' `
            --body "@$bodyFile" -o json | ConvertFrom-Json
    }
    finally { Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue }
}

function Show-LaTable ($result) {
    if (-not $result -or -not ($result.PSObject.Properties.Match('tables').Count)) {
        Warn 'Query returned no table payload (check the error above).'
        return
    }
    foreach ($table in $result.tables) {
        $cols = @($table.columns | ForEach-Object name)
        foreach ($row in $table.rows) {
            Write-Host ('  ' + ('-' * 76)) -ForegroundColor DarkGray
            for ($i = 0; $i -lt $cols.Count; $i++) {
                $val = [string]$row[$i]
                if (-not $val) { continue }
                if ($val.Length -gt 800) { $val = $val.Substring(0, 800) + ' ...[truncated]' }
                Write-Host ("  {0,-14} {1}" -f $cols[$i], $val)
            }
        }
    }
}

# ── 1. Auth ───────────────────────────────────────────────────────────────────
Write-Host "`n=== 1. Azure authentication ===" -ForegroundColor Cyan
$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) { az login --output none; $acct = az account show -o json | ConvertFrom-Json }
if ($acct.id -ne $SubscriptionId) { az account set --subscription $SubscriptionId }
$null = az account get-access-token --resource 'https://management.azure.com/' -o json 2>$null
if ($LASTEXITCODE -ne 0) {
    Warn 'Cached az session is stale (CA 4h window). Re-authenticating...'
    az logout 2>$null; az login --output none
    az account set --subscription $SubscriptionId
}
Ok "Signed in as $((az account show -o json | ConvertFrom-Json).user.name)."

$wsUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
         "/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName" + '?api-version=2023-09-01'
$cid = (az rest --method get --url $wsUrl -o json | ConvertFrom-Json).properties.customerId
if (-not $cid) { throw "Could not resolve Log Analytics workspace customerId for $WorkspaceName." }
Info "workspace customerId: $cid"

# ── 2. CURRENT live bundle version (admin/host/status via az — bypasses the
#       per-process HTTPS block that 000s plain curl/pwsh on this machine) ─────
Write-Host "`n=== 2. Current live host + bundle version ===" -ForegroundColor Cyan
try {
    $keysUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
               "/providers/Microsoft.Web/sites/$FunctionAppName/host/default/listkeys?api-version=2023-12-01"
    # Master key stays in memory only — never printed, never logged.
    $master = (az rest --method post --url $keysUrl -o json | ConvertFrom-Json).masterKey
    if (-not $master) { throw 'listkeys returned no masterKey' }
    $status = az rest --method get --skip-authorization-header `
        --url "https://$FunctionAppName.azurewebsites.net/admin/host/status" `
        --headers "x-functions-key=$master" -o json | ConvertFrom-Json
    Ok ("host version: {0}   state: {1}" -f $status.version, $status.state)
    $bundleNow = $null
    if ($status.PSObject.Properties.Match('extensionBundle').Count -gt 0 -and $status.extensionBundle) {
        $bundleNow = $status.extensionBundle.version
        Ok "extension bundle NOW: $($status.extensionBundle.id) $bundleNow"
    } else {
        Warn 'host status did not report an extensionBundle block.'
    }
    if ($bundleNow) {
        if ($bundleNow -eq '4.44.0') {
            Warn 'Bundle UNCHANGED since the 2026-07-20 observation (4.44.0). Drift is NOT the cause;'
            Warn 'suspect the claude.ai MCP client moved past what this preview extension speaks.'
            Warn 'Direction: UPGRADE the host.json pin to the newest preview bundle and redeploy.'
        } else {
            Warn "Bundle CHANGED: 4.44.0 (Jul 20) -> $bundleNow (now). The floating [4.*, 5.0.0) range"
            Warn 'adopted a new preview build on a host recycle - likely the tools/list breaker.'
            Warn 'Direction: pin host.json to 4.44.0 and redeploy; escalate to latest only if that fails.'
        }
    }
} catch {
    Warn "Live status probe failed: $($_.Exception.Message)"
}

# ── 3. Historical bundle observations from Log Analytics (parsed client-side) ─
Write-Host "`n=== 3. Historical bundle versions (Host Status traces, last ${DaysBack}d) ===" -ForegroundColor Cyan
$raw = Invoke-LaQuery $cid (
    "AppTraces " +
    "| where Message has 'ExtensionBundle' or Message has 'extension bundle' " +
    "| project TimeGenerated, Message | sort by TimeGenerated asc | take 200")
$observations = @{}
if ($raw -and $raw.PSObject.Properties.Match('tables').Count) {
    foreach ($table in $raw.tables) {
        foreach ($row in $table.rows) {
            $msg = [string]$row[1]
            if ($msg -match '(?s)extensionBundle.{0,200}?"version"\s*:\s*"(\d+\.\d+\.\d+)"') {
                $v = $matches[1]
                if (-not $observations.ContainsKey($v)) { $observations[$v] = @{ First = $row[0]; Last = $row[0]; N = 0 } }
                $observations[$v].Last = $row[0]
                $observations[$v].N++
            }
        }
    }
}
if ($observations.Count) {
    foreach ($v in ($observations.Keys | Sort-Object)) {
        $o = $observations[$v]
        Info ("version {0}   observations: {1}   first: {2}   last: {3}" -f $v, $o.N, $o.First, $o.Last)
    }
    Info 'NOTE: Host Status traces only appear when the admin status endpoint is queried,'
    Info 'so gaps mean "not observed", not "not running". Section 2 is the live truth.'
} else {
    Warn 'No bundle versions parseable from traces in the window.'
}

# ── 4. Host starts (recycle timeline) ─────────────────────────────────────────
Write-Host "`n=== 4. Host start events (recycle timeline, last ${DaysBack}d) ===" -ForegroundColor Cyan
$starts = Invoke-LaQuery $cid (
    "AppTraces | where Message startswith 'Host started' or Message has 'Job host started' " +
    "| summarize Starts = count(), First = min(TimeGenerated), Last = max(TimeGenerated) by bin(TimeGenerated, 1d) " +
    "| project Day = format_datetime(TimeGenerated_bin, 'yyyy-MM-dd'), Starts | sort by Day asc")
Show-LaTable $starts

Write-Host "`nLog saved to: $script:LogPath" -ForegroundColor Cyan
Write-Host 'Give the log file (or paste its contents) back to Claude to continue diagnosis.' -ForegroundColor Cyan
Stop-Transcript | Out-Null
