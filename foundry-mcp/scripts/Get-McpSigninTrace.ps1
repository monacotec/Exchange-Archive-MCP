#Requires -Version 7.0
# Version: 1.1.0
# 1.1.0: full run output now captured to a timestamped log file under
#        foundry-mcp\logs\ (transcript), path printed at end of run.
<#
.SYNOPSIS
    Diagnose why NO requests are reaching the MCP (read-only).

.DESCRIPTION
    Follow-up to Get-McpUserActivity.ps1 for the 2026-08-11 finding: telemetry
    pipeline healthy, app Running, but zero AppRequests / mcp_tool_call rows
    since 2026-08-04 ~17:35 while the app was last modified 2026-08-03 16:18.
    Failures in the Easy Auth / connector layer never reach the app code, so
    this script looks at the layers that DO record them:

      1. Function app deployment + config-change history (what happened Aug 3?)
      2. Raw dump of the last 14 days of AppRequests (all of them - there are ~15)
      3. Raw dump of the last mcp_tool_call traces WITH raw Properties, to reveal
         the actual custom-dimension schema (user summary came back blank)
      4. Entra sign-in log entries for the Exchange Archive MCP app (ALL users,
         last N days): who tried to sign in, when, and the exact failure code -
         this is where a broken Easy Auth / consent / CA block shows up.

    Sign-in log read requires a directory role (Reports Reader or higher) on
    the account you az login with. If it 403s, use Entra portal > Monitoring >
    Sign-in logs, filter Application = 'Exchange Archive MCP'.

.EXAMPLE
    .\Get-McpSigninTrace.ps1 -DaysBack 8
#>
[CmdletBinding()]
param(
    [string]$AppId           = '9519ca68-dae2-4add-8309-4bdd1fa45e79',
    [string]$SubscriptionId  = 'db17a4a4-f677-498a-b4a2-eb401ba9cf29',
    [string]$ResourceGroup   = 'finresgroup',
    [string]$WorkspaceName   = 'law-exchange-mcp-archive-mailbox-mcp',
    [string]$FunctionAppName = 'func-exchange-mcp-archive-mailbox-mcp',
    [int]$DaysBack           = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Capture the whole run to a log file in the project (foundry-mcp\logs\).
$script:LogDir = Join-Path $PSScriptRoot '..\logs'
if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
$script:LogPath = Join-Path (Resolve-Path $script:LogDir).Path ("mcp-signin-trace-{0}.log" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
Start-Transcript -Path $script:LogPath | Out-Null

function Ok   ($t) { Write-Host "  [PASS] $t" -ForegroundColor Green }
function Warn ($t) { Write-Host "  [warn] $t" -ForegroundColor Yellow }
function Info ($t) { Write-Host "  [info] $t" -ForegroundColor DarkGray }

function Invoke-LaQuery ([string]$CustomerId, [string]$Kql, [string]$Timespan = "P${DaysBack}D") {
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
                if ($val.Length -gt 1500) { $val = $val.Substring(0, 1500) + ' ...[truncated]' }
                Write-Host ("  {0,-18} {1}" -f $cols[$i], $val)
            }
        }
    }
}

Write-Host "Logging this run to: $script:LogPath" -ForegroundColor DarkGray

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

# ── 2. What changed on/around Aug 3? Deployments + activity log ──────────────
Write-Host "`n=== 2. Function app deployments and control-plane changes (last ${DaysBack}d) ===" -ForegroundColor Cyan
try {
    $deployUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
                 "/providers/Microsoft.Web/sites/$FunctionAppName/deployments?api-version=2023-12-01"
    $raw = (az rest --method get --url $deployUrl -o json 2>$null | Out-String)
    $cut = $raw.IndexOf('<')
    if ($cut -gt 0) { $raw = $raw.Substring(0, $cut) }
    $deps = @(($raw | ConvertFrom-Json).value | Sort-Object { $_.properties.received_time } -Descending | Select-Object -First 5)
    foreach ($d in $deps) {
        Info ("deploy  time: {0}   status: {1}   active: {2}" -f $d.properties.end_time,
             ($d.properties.status -eq 4 ? 'success' : "code $($d.properties.status)"), $d.properties.active)
    }
    if (-not $deps.Count) { Info 'no zip/scm deployments recorded' }
} catch { Warn "Could not read deployment history: $($_.Exception.Message)" }

try {
    $startIso = (Get-Date).AddDays(-$DaysBack).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $alFilter = [Uri]::EscapeDataString("eventTimestamp ge '$startIso' and resourceGroupName eq '$ResourceGroup'")
    $alUrl = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Insights/eventtypes/management/values" +
             "?api-version=2015-04-01&`$filter=$alFilter&`$select=eventTimestamp,operationName,caller,status,resourceId"
    $events = @((az rest --method get --url $alUrl -o json | ConvertFrom-Json).value |
        Where-Object { $_.resourceId -like "*$FunctionAppName*" -and $_.status.value -eq 'Succeeded' -and $_.operationName.value -notlike '*/read' } |
        Select-Object -First 20)
    if ($events.Count) {
        foreach ($e in $events) {
            Info ("change  {0}   {1}   by {2}" -f $e.eventTimestamp, $e.operationName.localizedValue, $e.caller)
        }
    } else { Info 'no successful write operations on the function app in the activity log window' }
} catch { Warn "Could not read activity log: $($_.Exception.Message)" }

# ── 3. Raw dump: every request + the last tool calls ─────────────────────────
Write-Host "`n=== 3. ALL AppRequests, last ${DaysBack}d (raw) ===" -ForegroundColor Cyan
$wsUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
         "/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName" + '?api-version=2023-09-01'
$cid = (az rest --method get --url $wsUrl -o json | ConvertFrom-Json).properties.customerId
if (-not $cid) { throw "Could not resolve Log Analytics workspace customerId for $WorkspaceName." }
$reqs = Invoke-LaQuery $cid (
    "AppRequests | sort by TimeGenerated desc " +
    "| project TimeGenerated, Name, ResultCode, Success, DurationMs, Url, OperationId | take 30") 'P14D'
Show-LaTable $reqs

Write-Host "`n=== 4. Last mcp_tool_call traces with RAW properties (schema check) ===" -ForegroundColor Cyan
$tools = Invoke-LaQuery $cid (
    "AppTraces | where Message == 'mcp_tool_call' | sort by TimeGenerated desc " +
    "| project TimeGenerated, Properties = tostring(Properties) | take 12") 'P14D'
Show-LaTable $tools

# ── 5. Entra sign-in attempts against the MCP app (all users) ────────────────
Write-Host "`n=== 5. Entra sign-in log: app $AppId, last ${DaysBack}d, ALL users ===" -ForegroundColor Cyan
try {
    $sinceIso = (Get-Date).AddDays(-$DaysBack).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $siFilter = [Uri]::EscapeDataString("appId eq '$AppId' and createdDateTime ge $sinceIso")
    $siUrl = "https://graph.microsoft.com/v1.0/auditLogs/signIns?`$filter=$siFilter&`$top=50"
    $signins = @((az rest --method get --resource 'https://graph.microsoft.com' --url $siUrl -o json | ConvertFrom-Json).value)
    if (-not $signins.Count) {
        Warn 'ZERO interactive sign-in attempts against this app in the window. Nobody is even reaching'
        Warn 'the Entra sign-in step -> the failure is upstream in the Claude connector handshake'
        Warn '(PRM metadata fetch, connector URL, or the MCP endpoint itself). Test the endpoint next:'
        Warn "  https://$FunctionAppName.azurewebsites.net/.well-known/oauth-protected-resource"
    }
    foreach ($s in $signins) {
        $err = $s.status.errorCode
        $line = "{0}  {1}  error={2}  CA={3}" -f $s.createdDateTime, $s.userPrincipalName, $err, $s.conditionalAccessStatus
        if ($err -eq 0) { Ok $line } else {
            Warn $line
            Warn ("        reason: {0}" -f $s.status.failureReason)
        }
    }
} catch {
    Warn "Sign-in log query failed ($($_.Exception.Message))."
    Warn 'Fallback: Entra portal > Monitoring > Sign-in logs > filter Application = Exchange Archive MCP.'
}

Write-Host "`nLog saved to: $script:LogPath" -ForegroundColor Cyan
Write-Host 'Give the log file (or paste its contents) back to Claude to continue diagnosis.' -ForegroundColor Cyan
Stop-Transcript | Out-Null
