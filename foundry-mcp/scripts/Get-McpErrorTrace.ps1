#Requires -Version 7.0
# Version: 1.0.3
<#
.SYNOPSIS
    Pulls the server-side exception behind an MCP tool's correlation_id.

.DESCRIPTION
    The MCP returns {"error":true,"message":"Request failed.","correlation_id":X}
    by design (no detail leaks to the caller). The full exception lives in App
    Insights / Log Analytics. This script (read-only):

      1. Signs into Azure (interactive browser; never device code)
      2. Shows the Function App's most recent deployment (so you know which
         code version is actually live)
      3. Queries the Log Analytics workspace for the correlation id, then pulls
         every trace/exception row from the same operation

    NOTE: App Insights ingestion lags 1-5 minutes. If a correlation id from a
    moment ago returns nothing, wait and re-run.

.EXAMPLE
    .\Get-McpErrorTrace.ps1 -CorrelationId 14eb17a0-eade-4eb0-ac61-fcf9878fe123
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CorrelationId,
    [string]$SubscriptionId  = 'db17a4a4-f677-498a-b4a2-eb401ba9cf29',
    [string]$ResourceGroup   = 'finresgroup',
    [string]$WorkspaceName   = 'law-exchange-mcp-archive-mailbox-mcp',
    [string]$FunctionAppName = 'func-exchange-mcp-archive-mailbox-mcp',
    [int]$HoursBack          = 6
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ok  ($t) { Write-Host "  [PASS] $t" -ForegroundColor Green }
function Info($t) { Write-Host "  [info] $t" -ForegroundColor DarkGray }

function Invoke-LaQuery ([string]$CustomerId, [string]$Kql) {
    $bodyFile = Join-Path $env:TEMP "la-query-$([guid]::NewGuid()).json"
    try {
        @{ query = $Kql; timespan = "PT${HoursBack}H" } | ConvertTo-Json | Set-Content $bodyFile -Encoding utf8
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
        Write-Host '  [warn] Query returned no table payload (check the error above).' -ForegroundColor Yellow
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
                Write-Host ("  {0,-16} {1}" -f $cols[$i], $val)
            }
        }
    }
}

# ── 1. Auth ───────────────────────────────────────────────────────────────────
Write-Host "`n=== 1. Azure authentication ===" -ForegroundColor Cyan
$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) { az login --output none; $acct = az account show -o json | ConvertFrom-Json }
if ($acct.id -ne $SubscriptionId) { az account set --subscription $SubscriptionId }
Ok "Signed in as $((az account show -o json | ConvertFrom-Json).user.name)."

# ── 2. Which code is live? (best-effort — never blocks the trace pull) ────────
Write-Host "`n=== 2. Latest deployment on $FunctionAppName ===" -ForegroundColor Cyan
try {
    $deployUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
                 "/providers/Microsoft.Web/sites/$FunctionAppName/deployments?api-version=2023-12-01"
    # The SCM-proxied deployments endpoint sometimes appends an HTML error page
    # AFTER the JSON payload - trim anything from the first '<' onward.
    $raw = (az rest --method get --url $deployUrl -o json 2>$null | Out-String)
    $cut = $raw.IndexOf('<')
    if ($cut -gt 0) { $raw = $raw.Substring(0, $cut) }
    $deps = ($raw | ConvertFrom-Json).value |
            Sort-Object { $_.properties.received_time } -Descending | Select-Object -First 1
    Info ("time: {0}   status: {1}   active: {2}" -f $deps.properties.end_time,
         ($deps.properties.status -eq 4 ? 'success' : "code $($deps.properties.status)"), $deps.properties.active)
    Info 'Compare against version.md / your last azd deploy to confirm the expected version is live.'
}
catch {
    Info "Could not read deployment history ($($_.Exception.Message)) - continuing to the trace pull."
}

# ── 3. Find the correlation id ────────────────────────────────────────────────
Write-Host "`n=== 3. Rows matching $CorrelationId ===" -ForegroundColor Cyan
# Deliberately NOT `az monitor log-analytics workspace show`: loading the az
# `application-insights` extension is blocked on this machine (EDR denies the
# dist-info read), which kills every `az monitor` command. Plain ARM works.
$wsUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
         "/providers/Microsoft.OperationalInsights/workspaces/$WorkspaceName" + '?api-version=2023-09-01'
$cid = (az rest --method get --url $wsUrl -o json | ConvertFrom-Json).properties.customerId
if (-not $cid) { throw "Could not resolve Log Analytics workspace customerId for $WorkspaceName." }
Info "workspace customerId: $cid"
$hits = Invoke-LaQuery $cid ((
    "union isfuzzy=true AppTraces, AppExceptions " +
    "| where tostring(column_ifexists('Message','')) has '{0}' " +
    "   or tostring(column_ifexists('OuterMessage','')) has '{0}' " +
    "   or tostring(column_ifexists('Properties','')) has '{0}' " +
    "| project TimeGenerated, Type, Message = tostring(column_ifexists('Message','')), " +
    "  OuterMessage = tostring(column_ifexists('OuterMessage','')), OperationId " +
    "| take 20") -f $CorrelationId)
Show-LaTable $hits

$opIds = @()
if ($hits -and $hits.PSObject.Properties.Match('tables').Count) {
    $opIds = @($hits.tables | ForEach-Object { $t = $_; $oidIdx = [array]::IndexOf(@($t.columns.name), 'OperationId'); $t.rows | ForEach-Object { $_[$oidIdx] } } | Where-Object { $_ } | Select-Object -Unique)
}
if (-not $opIds.Count) {
    Write-Host "`n  No rows yet - ingestion lag is 1-5 min. Re-run in a few minutes." -ForegroundColor Yellow
    exit 0
}

# ── 4. Full operation detail (exceptions + traces) ────────────────────────────
Write-Host "`n=== 4. Full detail for operation(s): $($opIds -join ', ') ===" -ForegroundColor Cyan
$opList = ($opIds | ForEach-Object { "'$_'" }) -join ','
$detail = Invoke-LaQuery $cid (
    "union isfuzzy=true AppExceptions, AppTraces | where OperationId in ($opList) | sort by TimeGenerated asc " +
    "| project TimeGenerated, Type, SeverityLevel, Message = tostring(column_ifexists('Message','')), " +
    "ExceptionType = tostring(column_ifexists('ExceptionType','')), OuterMessage = tostring(column_ifexists('OuterMessage','')), " +
    "InnermostMessage = tostring(column_ifexists('InnermostMessage','')), Details = tostring(column_ifexists('Details','')) | take 50")
Show-LaTable $detail

Write-Host "`nPaste the output back to Claude to continue diagnosis." -ForegroundColor Cyan
