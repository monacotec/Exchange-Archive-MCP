#Requires -Version 7.0
# Version: 1.1.0
# 1.1.0: PATCH now round-trips the FULL functionAppConfig — ARM validates the
#        whole object, so a sparse {scaleAndConcurrency} patch fails with
#        "Runtime name and version must be provided" (observed live
#        2026-08-12). Also: abort on az PATCH failure ($LASTEXITCODE) and
#        StrictMode-safe read-back.
<#
.SYNOPSIS
    Diagnose / fix the "Couldn't reach Exchange Archive MCP" drop-offs
    (Flex Consumption scale-to-zero cold starts).

.DESCRIPTION
    Symptom (2026-08-11, ref ofid_8d930262afac7547): the connector works while
    the app is warm, then "Couldn't reach ..." after idle. Flex Consumption
    scales to ZERO with no always-ready instances; the next connection pays a
    cold start the MCP client's connect timeout does not tolerate.

    Default run (read-only):
      1. Timed probes of the anonymous PRM endpoint via az (dodges the
         per-process HTTPS block) - a slow/failed first probe followed by a
         fast second one is the cold-start signature.
      2. Shows the app's current scaleAndConcurrency config (alwaysReady).

    With -Apply:
      3. Sets alwaysReady http = 1 so one instance stays warm at all times.
         COST: an always-ready Flex instance bills continuously (baseline
         rate for the configured instance memory) instead of per-execution.

    Mutations logged with timestamp + actor; transcript to foundry-mcp\logs\.

.EXAMPLE
    .\Set-McpAlwaysReady.ps1            # probe + show config only
.EXAMPLE
    .\Set-McpAlwaysReady.ps1 -Apply     # set alwaysReady http=1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SubscriptionId  = 'db17a4a4-f677-498a-b4a2-eb401ba9cf29',
    [string]$ResourceGroup   = 'finresgroup',
    [string]$FunctionAppName = 'func-exchange-mcp-archive-mailbox-mcp',
    [int]$AlwaysReadyCount   = 1,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogDir = Join-Path $PSScriptRoot '..\logs'
if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
$script:LogPath = Join-Path (Resolve-Path $script:LogDir).Path ("mcp-alwaysready-{0}.log" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
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

function Ok   ([string]$m) { Write-Host "[OK] $m" -ForegroundColor Green }
function Bad  ([string]$m) { Write-Host "[!!] $m" -ForegroundColor Red }
function Info ([string]$m) { Write-Host "     $m" -ForegroundColor Yellow }
function Write-MutationLog ([string]$Action) {
    $actor = (az account show -o json | ConvertFrom-Json).user.name
    Write-Host ("     {0}  MUTATE  actor={1}  {2}" -f (Get-Date).ToUniversalTime().ToString('o'), $actor, $Action) -ForegroundColor DarkGray
}

# ── 1. Auth ───────────────────────────────────────────────────────────────────
Write-Host "`n=== 1. Azure authentication ===" -ForegroundColor Cyan
$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) { az login --output none; $acct = az account show -o json | ConvertFrom-Json }
if ($acct.id -ne $SubscriptionId) { az account set --subscription $SubscriptionId }
# sweep:auth-probe -- a token for management.azure.com does NOT prove the
# CLI's other ARM audience is still valid: on 2026-08-14 this probe passed
# and the next call failed AADSTS70043. Probe with a real read instead.
$null = az group show -n $ResourceGroup -o none 2>$null
if ($LASTEXITCODE -ne 0) {
    Info 'Cached az session is stale (CA 4h window). Re-authenticating...'
    az logout 2>$null; az login --output none
    az account set --subscription $SubscriptionId
}
Ok "Signed in as $((az account show -o json | ConvertFrom-Json).user.name)."

# ── 2. Timed reachability probes (PRM endpoint, anonymous, az-tunneled) ──────
Write-Host "`n=== 2. Timed endpoint probes (cold vs warm) ===" -ForegroundColor Cyan
$prmUrl = "https://$FunctionAppName.azurewebsites.net/.well-known/oauth-protected-resource"
foreach ($i in 1..3) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = az rest --method get --skip-authorization-header --url $prmUrl -o json 2>&1
    $sw.Stop()
    if ($LASTEXITCODE -eq 0) {
        Ok ("probe {0}: responded in {1:n1}s" -f $i, $sw.Elapsed.TotalSeconds)
    } else {
        Bad ("probe {0}: FAILED after {1:n1}s - {2}" -f $i, $sw.Elapsed.TotalSeconds, (("$out" -replace '\s+', ' ').Substring(0, [Math]::Min(200, "$out".Length))))
    }
    if ($i -lt 3) { Start-Sleep -Seconds 2 }
}
Info 'Slow/failed probe 1 + fast probes 2-3 = cold start. All fast = app was already warm'
Info '(a warm-state run proves nothing about the idle case - the config below is what matters).'

# ── 3. Current scale config ───────────────────────────────────────────────────
Write-Host "`n=== 3. Flex scale configuration ===" -ForegroundColor Cyan
$siteUrl = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
           "/providers/Microsoft.Web/sites/$FunctionAppName" + '?api-version=2023-12-01'
$site = (az rest --method get --url $siteUrl -o json | ConvertFrom-Json).properties
$fac = $null
if ($site.PSObject.Properties.Match('functionAppConfig').Count -gt 0) { $fac = $site.functionAppConfig }
if (-not $fac) { throw 'Site has no functionAppConfig - not a Flex Consumption app? Inspect manually.' }
$scale = $fac.scaleAndConcurrency
Info ("maximumInstanceCount: {0}   instanceMemoryMB: {1}" -f $scale.maximumInstanceCount, $scale.instanceMemoryMB)
$arHttp = $null
$arList = @()
if ($scale.PSObject.Properties.Match('alwaysReady').Count -gt 0 -and $scale.alwaysReady) { $arList = @($scale.alwaysReady) }
foreach ($a in $arList) { Info ("alwaysReady: {0} = {1}" -f $a.name, $a.instanceCount) }
$arHttp = $arList | Where-Object { $_.name -eq 'http' } | Select-Object -First 1
if ($arHttp -and [int]$arHttp.instanceCount -ge $AlwaysReadyCount) {
    Ok "alwaysReady http already >= $AlwaysReadyCount - scale-to-zero is not the cause; dig into AppServicePlatformLogs next."
} else {
    Bad 'no alwaysReady http instances - the app scales to ZERO when idle. Cold starts explain the drop-offs.'
    if (-not $Apply) { Info "Re-run with -Apply to set alwaysReady http = $AlwaysReadyCount." }
}

# ── 4. Apply ──────────────────────────────────────────────────────────────────
if ($Apply -and (-not $arHttp -or [int]$arHttp.instanceCount -lt $AlwaysReadyCount)) {
    Write-Host "`n=== 4. Set alwaysReady http = $AlwaysReadyCount ===" -ForegroundColor Cyan
    if ($PSCmdlet.ShouldProcess($FunctionAppName, "set alwaysReady http=$AlwaysReadyCount")) {
        # ARM validates the WHOLE functionAppConfig on PATCH — a sparse
        # {scaleAndConcurrency} body fails with "Runtime name and version must
        # be provided". Round-trip the full current config with only
        # alwaysReady changed.
        $newAr = @($arList | Where-Object { $_.name -ne 'http' }) + @([PSCustomObject]@{ name = 'http'; instanceCount = $AlwaysReadyCount })
        if ($scale.PSObject.Properties.Match('alwaysReady').Count -gt 0) { $scale.alwaysReady = $newAr }
        else { $scale | Add-Member -NotePropertyName alwaysReady -NotePropertyValue $newAr }
        $patch = @{ properties = @{ functionAppConfig = $fac } }
        $bodyFile = Join-Path $env:TEMP "ar-patch-$([guid]::NewGuid()).json"
        try {
            $patch | ConvertTo-Json -Depth 20 | Set-Content $bodyFile -Encoding utf8
            Write-MutationLog "PATCH sites/$FunctionAppName functionAppConfig (full round-trip) alwaysReady http=$AlwaysReadyCount"
            az rest --method patch --url $siteUrl --headers 'Content-Type=application/json' --body "@$bodyFile" -o none
            if ($LASTEXITCODE -ne 0) { throw "ARM PATCH failed (az exit $LASTEXITCODE) - see the error above; nothing was verified." }
        } finally { Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue }
        # Read back (StrictMode-safe: alwaysReady may be absent on failure).
        $scale2 = ((az rest --method get --url $siteUrl -o json | ConvertFrom-Json).properties.functionAppConfig).scaleAndConcurrency
        $ar2List = @()
        if ($scale2.PSObject.Properties.Match('alwaysReady').Count -gt 0 -and $scale2.alwaysReady) { $ar2List = @($scale2.alwaysReady) }
        $ar2 = $ar2List | Where-Object { $_.name -eq 'http' } | Select-Object -First 1
        if ($ar2 -and [int]$ar2.instanceCount -ge $AlwaysReadyCount) {
            Ok "alwaysReady http = $($ar2.instanceCount) confirmed. Give it ~2 min, then reconnect the connector."
            Info 'COST: one always-ready instance bills continuously at the baseline rate for'
            Info "$($scale2.instanceMemoryMB) MB - roughly single-digit USD/day; review on the next cost pass."
        } else {
            Bad 'PATCH accepted but read-back does not show the alwaysReady http entry - inspect in the portal.'
        }
    }
}

Write-Host "`nLog saved to: $script:LogPath" -ForegroundColor Cyan
Write-Host 'Give the log file (or paste its contents) back to Claude to continue diagnosis.' -ForegroundColor Cyan
Stop-Transcript | Out-Null
