#Requires -Version 7.0
# Version: 1.3.0
# 1.3.0: read audit fields from the v3.6.1 message-embedded JSON
#        ('mcp_tool_call {json}') instead of customDimensions, which the
#        built-in Functions telemetry never ingested. Pre-3.6.1 rows have no
#        payload and group under a blank user.
# 1.2.0: full run output now captured to a timestamped log file under
#        foundry-mcp\logs\ (transcript), path printed at end of run.
# 1.1.0: zero rows for EVERY user over 60h means the user filter isn't the
#        problem. Added: telemetry sanity sweep (any rows at all, 14d), function
#        app runtime state + App Insights wiring check, and an unfiltered
#        request summary so "no traffic" and "broken telemetry" look different.
<#
.SYNOPSIS
    Pulls all MCP server-side logging for one user's tool calls (read-only).

.DESCRIPTION
    Companion to Get-McpErrorTrace.ps1 for when you have a USER, not a
    correlation id. function_app.py audit-logs every tool call (mcp_tool_call
    trace with user_identity/tool_name/output_summary custom dimensions) and
    logs the full exception behind every generic "Request failed" response.

    This script (mutates nothing):
      1. Signs into Azure (interactive browser; never device code)
      2. Reads MCP_ALLOWED_MAILBOXES off the Function App — the #1 cause of a
         new user erroring: a non-empty allowlist that omits them makes every
         tool call fail by design (PermissionError -> "Request failed.")
      3. Queries Log Analytics for every trace/exception mentioning the UPN
      4. Pulls full operation detail (exception type + message) for each hit
      5. Summarizes failed HTTP requests in the window (Easy Auth 401s land
         here even when the tool layer is never reached)

    If nothing turns up at all, the failure happened before the app code ran
    (consent prompt, Easy Auth rejection, connector config) — check Entra
    portal > Sign-in logs for the user next.

    NOTE: App Insights ingestion lags 1-5 minutes.

.EXAMPLE
    .\Get-McpUserActivity.ps1 -UserUpn xtsai@gipartners.com -HoursBack 24
#>
[CmdletBinding()]
param(
    [string]$UserUpn         = 'xtsai@gipartners.com',
    [string]$SubscriptionId  = 'db17a4a4-f677-498a-b4a2-eb401ba9cf29',
    [string]$ResourceGroup   = 'finresgroup',
    [string]$WorkspaceName   = 'law-exchange-mcp-archive-mailbox-mcp',
    [string]$FunctionAppName = 'func-exchange-mcp-archive-mailbox-mcp',
    [int]$HoursBack          = 24
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Capture the whole run to a log file in the project (foundry-mcp\logs\).
$script:LogDir = Join-Path $PSScriptRoot '..\logs'
if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
$script:LogPath = Join-Path (Resolve-Path $script:LogDir).Path ("mcp-user-activity-{0}.log" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
Start-Transcript -Path $script:LogPath | Out-Null

trap {
    # sweep:error-logging (linear script) -- no try/finally here, so without this a
    # terminating error kills the run and the transcript ends with no reason
    # recorded. Log it, close the transcript, then rethrow.
    Write-Host "  [!!] unhandled error: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo) { Write-Host "       at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" -ForegroundColor DarkGray }
    try { Stop-Transcript | Out-Null } catch { }
    break
}
Write-Host "Logging this run to: $script:LogPath" -ForegroundColor DarkGray

function Ok   ($t) { Write-Host "  [PASS] $t" -ForegroundColor Green }
function Warn ($t) { Write-Host "  [warn] $t" -ForegroundColor Yellow }
function Info ($t) { Write-Host "  [info] $t" -ForegroundColor DarkGray }

function Invoke-LaQuery ([string]$CustomerId, [string]$Kql, [string]$Timespan = "PT${HoursBack}H") {
    $bodyFile = Join-Path $env:TEMP "la-query-$([guid]::NewGuid()).json"
    try {
        @{ query = $Kql; timespan = $Timespan } | ConvertTo-Json | Set-Content $bodyFile -Encoding utf8
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
                if ($val.Length -gt 1200) { $val = $val.Substring(0, 1200) + ' ...[truncated]' }
                Write-Host ("  {0,-18} {1}" -f $cols[$i], $val)
            }
        }
    }
}

# ── 1. Auth ───────────────────────────────────────────────────────────────────
Write-Host "`n=== 1. Azure authentication ===" -ForegroundColor Cyan
$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) { az login --output none; $acct = az account show -o json | ConvertFrom-Json }
if ($acct.id -ne $SubscriptionId) { az account set --subscription $SubscriptionId }
# Live token probe (cached sessions lie under the 4h CA sign-in frequency).
# sweep:auth-probe -- a token for management.azure.com does NOT prove the
# CLI's other ARM audience is still valid: on 2026-08-14 this probe passed
# and the next call failed AADSTS70043. Probe with a real read instead.
$null = az group show -n $ResourceGroup -o none 2>$null
if ($LASTEXITCODE -ne 0) {
    Warn 'Cached az session is stale (CA 4h window). Re-authenticating...'
    az logout 2>$null; az login --output none
    az account set --subscription $SubscriptionId
}
Ok "Signed in as $((az account show -o json | ConvertFrom-Json).user.name)."

# ── 2. Allowlist check (most likely cause for a NEW user) ────────────────────
Write-Host "`n=== 2. MCP_ALLOWED_MAILBOXES on $FunctionAppName ===" -ForegroundColor Cyan
$settingsUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
               "/providers/Microsoft.Web/sites/$FunctionAppName/config/appsettings/list?api-version=2023-12-01"
$settings = (az rest --method post --url $settingsUrl -o json | ConvertFrom-Json).properties
$allowRaw = ''
if ($settings.PSObject.Properties.Match('MCP_ALLOWED_MAILBOXES').Count -gt 0) { $allowRaw = [string]$settings.MCP_ALLOWED_MAILBOXES }
if (-not $allowRaw.Trim()) {
    Info 'MCP_ALLOWED_MAILBOXES is empty -> allowlist disabled, all verified callers pass. Not the cause.'
} else {
    $allowed = @($allowRaw -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
    Info "allowlist: $($allowed -join ', ')"
    if ($UserUpn.ToLower() -in $allowed) {
        Ok "$UserUpn IS in the allowlist - the error is something else; see the traces below."
    } else {
        Warn "$UserUpn is NOT in the allowlist. Every tool call from them fails by design with"
        Warn '"Request failed." (PermissionError server-side). If they SHOULD have access, add their'
        Warn 'UPN to MCP_ALLOWED_MAILBOXES (comma-separated) on the Function App and restart it.'
    }
}

# ── 3. Function app runtime state + App Insights wiring ──────────────────────
Write-Host "`n=== 3. Function app state and telemetry wiring ===" -ForegroundColor Cyan
$siteUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
           "/providers/Microsoft.Web/sites/$FunctionAppName" + '?api-version=2023-12-01'
$site = (az rest --method get --url $siteUrl -o json | ConvertFrom-Json).properties
if ($site.state -eq 'Running') { Ok "app state: Running (last modified $($site.lastModifiedTimeUtc))" }
else { Warn "app state: $($site.state) — a stopped/broken host rejects every call and emits NO telemetry. Start it and the mystery is probably solved." }
$hasAiConn = ($settings.PSObject.Properties.Match('APPLICATIONINSIGHTS_CONNECTION_STRING').Count -gt 0) -and [string]$settings.APPLICATIONINSIGHTS_CONNECTION_STRING
if ($hasAiConn) { Ok 'APPLICATIONINSIGHTS_CONNECTION_STRING is set' }
else { Warn 'APPLICATIONINSIGHTS_CONNECTION_STRING is MISSING — the app emits no telemetry at all; every log query below will be empty regardless of traffic.' }

# ── 4. Telemetry sanity: is ANYTHING landing in this workspace? ──────────────
Write-Host "`n=== 4. Telemetry sanity sweep (any producer, last 14 days) ===" -ForegroundColor Cyan
$wsUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
         "/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName" + '?api-version=2023-09-01'
$cid = (az rest --method get --url $wsUrl -o json | ConvertFrom-Json).properties.customerId
if (-not $cid) { throw "Could not resolve Log Analytics workspace customerId for $WorkspaceName." }
Info "workspace customerId: $cid"
$sanity = Invoke-LaQuery $cid (
    "union isfuzzy=true AppTraces, AppExceptions, AppRequests " +
    "| summarize Rows = count(), Newest = max(TimeGenerated) by Type | sort by Newest desc") 'P14D'
Show-LaTable $sanity
$toolSanity = Invoke-LaQuery $cid (
    "AppTraces | where Message startswith 'mcp_tool_call' " +
    "| extend d = parse_json(substring(Message, 14)) " +
    "| summarize Calls = count(), Newest = max(TimeGenerated) by User = tostring(d.user_identity)") 'P14D'
Show-LaTable $toolSanity
Info 'Zero rows everywhere = telemetry pipeline or app-down problem, NOT a user problem.'
Info 'Rows exist but Newest is days old = the MCP stopped receiving traffic at that moment; correlate with the last deploy.'

# ── 5. All rows mentioning the user ───────────────────────────────────────────
Write-Host "`n=== 5. Traces/exceptions mentioning $UserUpn (last ${HoursBack}h) ===" -ForegroundColor Cyan

$hits = Invoke-LaQuery $cid ((
    "union isfuzzy=true AppTraces, AppExceptions " +
    "| where tostring(column_ifexists('Properties','')) has '{0}' " +
    "   or tostring(column_ifexists('Message','')) has '{0}' " +
    "| extend d = parse_json(substring(tostring(column_ifexists('Message','')), 14)) " +
    "| project TimeGenerated, Type, Tool = tostring(d.tool_name), " +
    "  Output = tostring(d.output_summary), Message = tostring(column_ifexists('Message','')), OperationId " +
    "| sort by TimeGenerated asc | take 40") -f $UserUpn)
Show-LaTable $hits

$opIds = @()
if ($hits -and $hits.PSObject.Properties.Match('tables').Count) {
    $opIds = @($hits.tables | ForEach-Object { $t = $_; $oidIdx = [array]::IndexOf(@($t.columns.name), 'OperationId'); $t.rows | ForEach-Object { $_[$oidIdx] } } | Where-Object { $_ } | Select-Object -Unique)
}

# ── 6. Full operation detail for each hit ─────────────────────────────────────
if ($opIds.Count) {
    Write-Host "`n=== 6. Full detail for operation(s): $($opIds -join ', ') ===" -ForegroundColor Cyan
    $opList = ($opIds | ForEach-Object { "'$_'" }) -join ','
    $detail = Invoke-LaQuery $cid (
        "union isfuzzy=true AppExceptions, AppTraces | where OperationId in ($opList) | sort by TimeGenerated asc " +
        "| project TimeGenerated, Type, SeverityLevel, Message = tostring(column_ifexists('Message','')), " +
        "ExceptionType = tostring(column_ifexists('ExceptionType','')), OuterMessage = tostring(column_ifexists('OuterMessage','')), " +
        "InnermostMessage = tostring(column_ifexists('InnermostMessage','')) | take 60")
    Show-LaTable $detail
} else {
    Write-Host "`n=== 6. No tool-layer rows for this user ===" -ForegroundColor Cyan
    Warn 'The MCP audit-logs EVERY tool call with the verified caller UPN. Zero rows means either'
    Warn 'ingestion lag (wait 5 min, re-run) or the request never reached the app code: Easy Auth'
    Warn 'rejected the sign-in, consent was declined, or the connector setup failed client-side.'
    Warn "Next stop: Entra portal > Users > $UserUpn > Sign-in logs (filter to the last day)."
}

# ── 7. HTTP requests in the window, ALL result codes (Easy Auth 401s land here) ──
Write-Host "`n=== 7. Requests on the Function App by result code (last ${HoursBack}h) ===" -ForegroundColor Cyan
$reqs = Invoke-LaQuery $cid (
    "AppRequests " +
    "| summarize Count = count(), First = min(TimeGenerated), Last = max(TimeGenerated) by Name, ResultCode " +
    "| sort by Count desc | take 30")
Show-LaTable $reqs
Info 'No rows at all = no request telemetry, matching whatever section 4 showed.'
Info '401/403 spikes with no matching tool traces = rejected before the tool layer (auth/consent).'

Write-Host "`nLog saved to: $script:LogPath" -ForegroundColor Cyan
Write-Host 'Give the log file (or paste its contents) back to Claude to continue diagnosis.' -ForegroundColor Cyan
Stop-Transcript | Out-Null
