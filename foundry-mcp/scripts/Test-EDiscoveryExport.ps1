# Version: 1.3.0
# 1.3.0: full run output captured to a timestamped log under foundry-mcp\logs\
#        (transcript; flushed on early exits too since the process ends).
# Test-EDiscoveryExport.ps1 — reproduces the archive_get_search_results EXPORT leg
# app-only, printing the RAW HTTP status/body at every step so the failure names
# itself (vs. the tool's generic "Request failed."). Phase 1 of
# plans/BUGFIX-ARCHIVE-EXPORT-PLAN.md; doubles as the standing regression check
# (Phase 4).
#
# Read-only except it POSTs an exportReport (report-only; no content package, and
# report exports are what the tool already does — this changes no mailbox data).
# Runs app-only (client credentials via the KV secret) — same identity the
# Function App uses on its fallback path. PS7 or PS5.1.
#
# USAGE:
#   .\Test-EDiscoveryExport.ps1 -SearchId 961affb6-d37b-4950-b772-51042a2b431d
#   (search ids are in the bug report; the small CY2023 one is fastest.)

param(
    [Parameter(Mandatory)][string]$SearchId,
    [string]$CaseId,                       # optional; auto-located if omitted
    [string]$SubscriptionId = 'db17a4a4-f677-498a-b4a2-eb401ba9cf29',
    [string]$TenantId  = '9c1b0b26-717a-4eda-9d7e-7eebc00066bf',
    [string]$AppId     = '9519ca68-dae2-4add-8309-4bdd1fa45e79',
    [string]$VaultName = 'kv-exmcp-gi',
    [string]$PurviewAppId = 'b26e684c-5068-4120-a679-64a5d2c909d9',
    [int]$TimeoutSec = 180
)

$ErrorActionPreference = 'Stop'

# Capture the whole run to a log file in the project (foundry-mcp\logs\).
$script:LogDir = Join-Path $PSScriptRoot '..\logs'
if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
$script:LogPath = Join-Path (Resolve-Path $script:LogDir).Path ("ediscovery-export-{0}.log" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
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

function Ok  ($t) { Write-Host "  [PASS] $t" -ForegroundColor Green }
function No  ($t) { Write-Host "  [FAIL] $t" -ForegroundColor Red }
function Info($t) { Write-Host "  [info] $t" -ForegroundColor DarkGray }

$base = 'https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases'

# ── 0. Azure sign-in (interactive browser; needed to read the KV secret) ─────
Write-Host "`n=== 0. Azure sign-in (super-jmonaco) ===" -ForegroundColor Cyan
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) not found on PATH.' }
$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) {
    Info 'No active az session - opening browser sign-in...'
    az login --tenant $TenantId --output none
    $acct = az account show -o json | ConvertFrom-Json
}
if ($acct.id -ne $SubscriptionId) {
    az account set --subscription $SubscriptionId
    $acct = az account show -o json | ConvertFrom-Json
}
# Verify the session can actually read the vault secret before we go further.
$probe = az keyvault secret show --vault-name $VaultName --name mcp-exchange-client-secret --query id -o tsv 2>$null
if (-not $probe) {
    Info 'Could not read the client secret with the current session - re-authenticating...'
    az login --tenant $TenantId --output none
    az account set --subscription $SubscriptionId
    $probe = az keyvault secret show --vault-name $VaultName --name mcp-exchange-client-secret --query id -o tsv 2>$null
    if (-not $probe) { throw "Signed in as $($acct.user.name) but cannot read mcp-exchange-client-secret from $VaultName (needs Key Vault Secrets User/Officer)." }
}
Ok "Signed in as $($acct.user.name); Key Vault secret readable."

function Get-AppToken ($resourceDefault) {
    $secret = az keyvault secret show --vault-name $VaultName --name mcp-exchange-client-secret --query value -o tsv
    if (-not $secret) { throw "Could not read client secret from $VaultName (az signed in?)" }
    (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
        grant_type = 'client_credentials'; client_id = $AppId; client_secret = $secret; scope = $resourceDefault
    }).access_token
}

# HTTP helper that ALWAYS returns status + body + headers, never throws on 4xx.
function Invoke-Http ($Method, $Uri, $Token, $BodyObj) {
    $headers = @{ Authorization = "Bearer $Token" }
    $params = @{ Method = $Method; Uri = $Uri; Headers = $headers }
    if ($BodyObj) { $params.Body = ($BodyObj | ConvertTo-Json -Depth 6); $params.ContentType = 'application/json' }
    if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('SkipHttpErrorCheck')) { $params.SkipHttpErrorCheck = $true }
    try {
        $r = Invoke-WebRequest @params
        return @{ Status = [int]$r.StatusCode; Body = $r.Content; Headers = $r.Headers }
    }
    catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { -1 }
        $body = try { $_.ErrorDetails.Message } catch { $_.Exception.Message }
        return @{ Status = $status; Body = $body; Headers = @{} }
    }
}

Write-Host "`n=== 1. App-only token ===" -ForegroundColor Cyan
$graphToken = Get-AppToken 'https://graph.microsoft.com/.default'
Ok 'Graph app token acquired.'

# ── Locate the case containing the search ─────────────────────────────────────
Write-Host "`n=== 2. Locate case for search $SearchId ===" -ForegroundColor Cyan
if (-not $CaseId) {
    $cases = (Invoke-RestMethod -Uri ($base + '?$top=100') -Headers @{ Authorization = "Bearer $graphToken" }).value
    foreach ($c in $cases) {
        $probe = Invoke-Http GET "$base/$($c.id)/searches/$SearchId" $graphToken $null
        if ($probe.Status -eq 200) { $CaseId = $c.id; Ok "Found in case '$($c.displayName)' ($CaseId)"; break }
    }
    if (-not $CaseId) { throw "Search $SearchId not found in any app-owned case." }
}
else { Info "Using provided CaseId $CaseId" }

# ── 3. POST exportReport ──────────────────────────────────────────────────────
Write-Host "`n=== 3. POST exportReport ===" -ForegroundColor Cyan
$exp = Invoke-Http POST "$base/$CaseId/searches/$SearchId/exportReport" $graphToken @{
    displayName = "diag-report-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    exportCriteria = 'searchHits'
    additionalOptions = 'none'
}
Write-Host ("  HTTP {0}" -f $exp.Status) -ForegroundColor $(if($exp.Status -in 200,201,202){'Green'}else{'Red'})
$loc = $null
foreach ($h in 'Location','location','Operation-Location','Azure-AsyncOperation') {
    if ($exp.Headers[$h]) { $loc = ($exp.Headers[$h] | Select-Object -First 1); Info ("{0}: {1}" -f $h, $loc) }
}
if ($exp.Body) { Info ("body: " + ($exp.Body -replace '\s+',' ').Substring(0, [Math]::Min(500, $exp.Body.Length))) }
if ($exp.Status -notin 200,201,202) {
    No 'exportReport rejected. ^ The status + body above is the root cause (e.g. 402=billing, 403=permission).'
    exit 2
}

# Operation id from Location (or from body if async-op shape).
$opId = $null
if ($loc -and ($loc -match "operations[/(]'?([0-9a-fA-F-]{16,})")) { $opId = $Matches[1] }
if (-not $opId -and $exp.Body -and ($exp.Body -match '"id"\s*:\s*"([0-9a-fA-F-]{16,})"')) { $opId = $Matches[1] }
if (-not $opId) { No "Could not extract an operation id from Location/body — parse mismatch (see raw above)."; exit 2 }
Ok "operation id: $opId"

# ── 4. Poll the operation ─────────────────────────────────────────────────────
Write-Host "`n=== 4. Poll operation ===" -ForegroundColor Cyan
$op = $null
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
    $r = Invoke-Http GET "$base/$CaseId/operations/$opId" $graphToken $null
    if ($r.Status -ne 200) { No "operation GET HTTP $($r.Status): $($r.Body)"; exit 2 }
    $op = $r.Body | ConvertFrom-Json
    $st = "$($op.status)".ToLower()
    Info ("status={0}  percent={1}" -f $op.status, $op.percentProgress)
    if ($st -in 'succeeded','partiallysucceeded','failed') { break }
    Start-Sleep -Seconds 6
}
if ("$($op.status)".ToLower() -eq 'failed') {
    No 'operation FAILED server-side. Error detail:'
    $op.error | ConvertTo-Json -Depth 6 | Write-Host
    exit 2
}
Ok "operation $($op.status)"
Info ("exportFileMetadata entries: " + (@($op.exportFileMetadata).Count))
foreach ($f in @($op.exportFileMetadata)) { Info ("  {0}  {1} bytes  url={2}" -f $f.fileName, $f.size, ($f.downloadUrl -replace '\?.*','?<sas-elided>')) }

# ── 5. Download report to disk ────────────────────────────────────────────────
Write-Host "`n=== 5. Download report (MicrosoftPurviewEDiscovery token) ===" -ForegroundColor Cyan
if (-not @($op.exportFileMetadata).Count) { No 'No exportFileMetadata to download.'; exit 2 }
$dlToken = Get-AppToken "$PurviewAppId/.default"
$first = @($op.exportFileMetadata)[0]
$dlHeaders = @{ Authorization = "Bearer $dlToken"; 'X-AllowWithAADToken' = 'true' }
$zipPath = Join-Path $env:TEMP ("ediag-{0}.zip" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
$p = @{ Method='GET'; Uri=$first.downloadUrl; Headers=$dlHeaders; OutFile=$zipPath }
if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('SkipHttpErrorCheck')) { $p.SkipHttpErrorCheck = $true }
try { Invoke-WebRequest @p | Out-Null; $code = 200 }
catch { $code = if($_.Exception.Response){[int]$_.Exception.Response.StatusCode}else{-1}; $errb = $_.ErrorDetails.Message }
if (-not (Test-Path $zipPath)) { $code = -1 }
$len = if (Test-Path $zipPath) { (Get-Item $zipPath).Length } else { 0 }
Write-Host ("  download HTTP {0}  ({1} bytes -> {2})" -f $code, $len, $zipPath) -ForegroundColor $(if($code -eq 200){'Green'}else{'Red'})
if ($code -ne 200) { No "Download failed. ^ status+token is the cause (401/403 = download token/permission). $errb"; exit 2 }

# ── 6. Inspect + PARSE the report (replicates download_report_items) ──────────
# This is the leg the tool does that this script previously did not. It reveals
# whether the report ZIP layout / CSV columns changed (new-eDiscovery backend)
# and broke the parser -> the tool's "no parsable item report" -> Request failed.
Write-Host "`n=== 6. Report contents + parse ===" -ForegroundColor Cyan
$extract = Join-Path $env:TEMP ("ediag-x-{0}" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
try { Expand-Archive -Path $zipPath -DestinationPath $extract -Force }
catch { No "Not a valid zip / expand failed: $($_.Exception.Message)"; exit 2 }

$allFiles = Get-ChildItem $extract -Recurse -File
Write-Host "  ZIP members:" -ForegroundColor Cyan
foreach ($f in $allFiles) { Info ("  {0}  ({1} bytes)" -f $f.FullName.Substring($extract.Length+1), $f.Length) }

$csvs = $allFiles | Where-Object { $_.Extension -ieq '.csv' }
if (-not $csvs) {
    No 'NO .csv in the report package. The tool then raises "no parsable item report found" -> Request failed.'
    Write-Host '  ^^ ROOT CAUSE CANDIDATE: report-only export no longer ships a per-item CSV (new-eDiscovery format change).' -ForegroundColor Yellow
    exit 2
}

# Mirror the tool's ranker: prefer a CSV with "item" in the name, else any CSV.
$chosen = ($csvs | Where-Object { $_.Name -match '(?i)item' } | Select-Object -First 1)
if (-not $chosen) { $chosen = $csvs | Select-Object -First 1 }
Info ("Chosen CSV (tool would pick this): {0}" -f $chosen.Name)

foreach ($csv in $csvs) {
    Write-Host ("`n  --- {0} ---" -f $csv.Name) -ForegroundColor Cyan
    $rows = @()
    try { $rows = Import-Csv -Path $csv.FullName } catch { No "  Import-Csv failed: $($_.Exception.Message)"; continue }
    $headers = @()
    if ($rows.Count) { $headers = $rows[0].PSObject.Properties.Name }
    else {
        # header-only file: read the first line
        $firstLine = (Get-Content $csv.FullName -TotalCount 1)
        Info ("  header line: {0}" -f $firstLine)
    }
    Info ("  rows: {0}   columns: {1}" -f $rows.Count, ($headers -join ' | '))
    if ($rows.Count) {
        $r0 = $rows[0]
        Info '  first row (values truncated):'
        foreach ($h in $headers) { Info ("     {0} = {1}" -f $h, ([string]$r0.$h).Substring(0,[Math]::Min(80,([string]$r0.$h).Length))) }
    }
}

# Replicate the tool's column mapping against the chosen CSV to see what maps.
Write-Host "`n  === Tool column-mapping check (chosen CSV) ===" -ForegroundColor Cyan
$map = @{
    subject = @('subject/title','subject','title')
    from    = @('sender/author','sender','from','author','sender address')
    received= @('date received','received date','received time','received','date','date sent','sent date')
    folder  = @('compliance item path','folder path','original path','parent folder path','parent folder','location path','folder','original folder path','path','location','location name')
    item_id = @('item id','immutable id','immutableid','document id','id','itemid','unique id')
    internet_message_id = @('internet message id','internetmessageid','message id','internet messageid')
}
$chosenRows = @(); try { $chosenRows = Import-Csv $chosen.FullName } catch {}
$present = @(); if ($chosenRows.Count) { $present = $chosenRows[0].PSObject.Properties.Name } elseif ((Get-Content $chosen.FullName -TotalCount 1)) { $present = (Get-Content $chosen.FullName -TotalCount 1).Split(',') }
$presentLower = $present | ForEach-Object { $_.Trim().Trim('"').ToLower() }
foreach ($field in $map.Keys) {
    $hit = $map[$field] | Where-Object { $presentLower -contains $_ } | Select-Object -First 1
    if ($hit) { Ok ("{0,-20} <- '{1}'" -f $field, $hit) } else { No ("{0,-20} UNMAPPED" -f $field) }
}
if (-not $chosenRows.Count) {
    Write-Host "`n  ROOT CAUSE: chosen CSV has 0 data rows -> tool's _parse_items_csv returns empty -> 'no parsable item report' -> Request failed." -ForegroundColor Yellow
}
else {
    Ok ("Chosen CSV has {0} data rows; tool would return items. If mappings above are UNMAPPED, items return with blank fields (not a throw)." -f $chosenRows.Count)
}

Info "Cleanup: Remove-Item '$zipPath','$extract' -Recurse -Force"
Write-Host "`nLog saved to: $script:LogPath" -ForegroundColor Cyan
Write-Host 'Give the log file (or paste its contents) back to Claude - the ZIP members + chosen-CSV rows/columns pinpoint any parser issue.' -ForegroundColor Cyan
Stop-Transcript | Out-Null
