#Requires -Version 7.0
<#
.SYNOPSIS
    Load archive message metadata into SQL from a Purview eDiscovery search.
    Also the verifier for the index it builds (-VerifyOnly).

.DESCRIPTION
    Goes straight to eDiscovery app-only -- the same pipeline the MCP uses, and
    the same one Test-EDiscoveryExport.ps1 proved end to end -- so it is NOT
    subject to the MCP tool's 100-items-per-call ceiling: the report CSV carries
    every row of a search. The 500-item EXPORT ceiling still applies, so a query
    matching more than that is split automatically into date windows until each
    window fits, replacing the manual date bisection recorded in
    docs/archive-search-session-notes.md.

    Pipeline per run:
      1. Preflight: sqlcmd present, config resolved, Azure session live.
      2. Apply the schema (idempotent) -- sql/archive-index-schema.sql.
      3. Plan windows: probe the match count, bisect the date range while any
         window exceeds the export ceiling.
      4. Per window: export report -> download -> parse CSV -> stage -> MERGE.
      5. Verify server-side: row counts, mojibake tripwire, coverage by store.

    Idempotent: MERGE keys on internet message id, so re-running a window
    updates rather than duplicates. Re-running after success comes out green.

    COST/TIME: each window costs one estimate (~90-120s) plus one report export
    (~30-60s). A 1,000-match query typically means 5-8 probes; budget 15-30
    minutes and let it run. Report-only exports carry no content charges.

.PARAMETER Query
    KQL, without date bounds -- the loader adds those per window.
    e.g. 'subject:"First Day at GI Partners"'
         'from:jmonaco@gipartners.com AND to:jmonaco@gipartners.com'

.PARAMETER Tag
    Batch label stored on every load run (provenance). Defaults to a slug of
    the query plus the UTC date.

.PARAMETER VerifyOnly
    Check schema + index content and mutate nothing. Exits 1 if anything is off.

.EXAMPLE
    .\Import-ArchiveSearchToSql.ps1 -Query 'subject:"First Day at GI Partners"'

.EXAMPLE
    # Self-sent history, explicit range, custom label
    .\Import-ArchiveSearchToSql.ps1 `
        -Query 'from:jmonaco@gipartners.com AND to:jmonaco@gipartners.com' `
        -StartDate 2021-01-01 -EndDate 2026-12-31 -Tag self-sent

.EXAMPLE
    .\Import-ArchiveSearchToSql.ps1 -VerifyOnly
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]   $Query,
    [string]   $Tag,
    [datetime] $StartDate = '2000-01-01',
    [datetime] $EndDate   = (Get-Date).Date,
    [ValidateSet('received', 'sent')][string] $DateField = 'received',

    # SQL target. Falls back to .env (ARCHIVE_SQL_SERVER / ARCHIVE_SQL_DATABASE),
    # then to LocalDB for a workstation-local index.
    [string] $SqlServer,
    [string] $SqlDatabase,
    [ValidateSet('Integrated', 'Entra')][string] $SqlAuth = 'Integrated',

    # Azure / eDiscovery
    [string] $SubscriptionId = 'db17a4a4-f677-498a-b4a2-eb401ba9cf29',
    [string] $TenantId       = '9c1b0b26-717a-4eda-9d7e-7eebc00066bf',
    [string] $AppId          = '9519ca68-dae2-4add-8309-4bdd1fa45e79',
    [string] $VaultName      = 'kv-exmcp-gi',
    [string] $PurviewAppId   = 'b26e684c-5068-4120-a679-64a5d2c909d9',
    [string] $MailboxUpn     = 'jmonaco@gipartners.com',
    [string] $CaseName       = 'Archive Index Loader',

    [int]    $ExportItemLimit = 500,
    [switch] $SchemaOnly,
    [switch] $VerifyOnly,
    [switch] $KeepSearches
)

$version = '1.0.0'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Logging ───────────────────────────────────────────────────────────────────
$script:LogDir = Join-Path $PSScriptRoot '..\logs'
if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
$script:LogPath = Join-Path (Resolve-Path $script:LogDir).Path ("archive-sql-load-{0}.log" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
Start-Transcript -Path $script:LogPath | Out-Null

$script:Issues = [System.Collections.Generic.List[string]]::new()
function Step ([string]$m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Ok   ([string]$m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Bad  ([string]$m) { Write-Host "  [!!] $m" -ForegroundColor Red; [void]$script:Issues.Add($m) }
function Info ([string]$m) { Write-Host "  $m" -ForegroundColor Yellow }
function Note ([string]$m) { Write-Host "  $m" }

Write-Host "Import-ArchiveSearchToSql $version" -ForegroundColor Cyan
Write-Host "Log: $script:LogPath" -ForegroundColor DarkGray

try {
    # ── 1. Config + preflight ─────────────────────────────────────────────────
    Step '1. Preflight'

    if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
        throw 'sqlcmd not found on PATH. Install the SQL command-line tools (winget install Microsoft.SQLServer.CommandLineUtilities) and re-run.'
    }
    Ok "sqlcmd present: $((Get-Command sqlcmd).Source)"

    # .env at repo root; runtime params win (house convention: env values are a
    # fallback, explicit arguments override).
    $envPath = Join-Path $PSScriptRoot '..\..\.env'
    $envVals = @{}
    if (Test-Path $envPath) {
        foreach ($line in Get-Content -LiteralPath $envPath) {
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') {
                $envVals[$matches[1]] = $matches[2].Trim().Trim('"').Trim("'")
            }
        }
        Ok ".env loaded ($($envVals.Count) keys)"
    } else {
        Info "no .env at $envPath - using parameters/defaults"
    }
    if (-not $SqlServer)   { $SqlServer   = if ($envVals.ContainsKey('ARCHIVE_SQL_SERVER'))   { $envVals['ARCHIVE_SQL_SERVER'] }   else { '(localdb)\MSSQLLocalDB' } }
    if (-not $SqlDatabase) { $SqlDatabase = if ($envVals.ContainsKey('ARCHIVE_SQL_DATABASE')) { $envVals['ARCHIVE_SQL_DATABASE'] } else { 'ArchiveIndex' } }
    Ok "SQL target: $SqlServer / $SqlDatabase  (auth: $SqlAuth)"

    $schemaFile = Join-Path $PSScriptRoot '..\sql\archive-index-schema.sql'
    if (-not (Test-Path $schemaFile)) { throw "Schema file not found: $schemaFile" }

    # ── sqlcmd wrapper ────────────────────────────────────────────────────────
    # -I: QUOTED_IDENTIFIER ON (the OFF default breaks filtered indexes, err 1934)
    # -b: non-zero exit on SQL error, so failures actually fail
    # Azure SQL serverless: the FIRST connection to a paused database triggers
    # the resume AND fails with 40613. Retry through the wake-up window rather
    # than treating it as fatal.
    function Invoke-SqlCmd {
        param(
            [string]$Query,
            [string]$InputFile,
            [switch]$Scalar,
            [int]$MaxAttempts = 5
        )
        $argsBase = @('-S', $SqlServer, '-d', $SqlDatabase, '-I', '-b')
        if ($SqlAuth -eq 'Entra') { $argsBase += '-G' } else { $argsBase += '-E' }
        if ($Scalar) { $argsBase += @('-h', '-1', '-W') }
        if ($InputFile) {
            $argsBase += @('-i', $InputFile)
        } else {
            # -Q takes ONE argument: flatten to a single line so multi-statement
            # queries pass intact. (Safe here because no query uses '--'
            # comments, which would swallow the rest of the line.)
            $argsBase += @('-Q', ($Query -replace '\r?\n', ' '))
        }

        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            $out = & sqlcmd @argsBase 2>&1
            $text = ($out | Out-String).Trim()
            if ($LASTEXITCODE -eq 0) { return $text }
            if ($text -match '40613|not currently available|is paused') {
                Info "database waking (attempt $attempt/$MaxAttempts) - retrying in 30s..."
                Start-Sleep -Seconds 30
                continue
            }
            throw "sqlcmd failed (exit $LASTEXITCODE): $text"
        }
        throw "sqlcmd could not reach $SqlDatabase after $MaxAttempts attempts (serverless wake-up window exceeded)."
    }

    function Get-SqlScalar([string]$Q) {
        $v = Invoke-SqlCmd -Query $Q -Scalar
        return ($v -split "`n" | Where-Object { $_ -and $_ -notmatch '^\(\d+ rows affected\)$' } | Select-Object -First 1).Trim()
    }

    # ── 2. Schema ─────────────────────────────────────────────────────────────
    Step '2. Schema (idempotent)'
    if ($VerifyOnly) {
        Info 'VerifyOnly: skipping schema apply'
    } elseif ($PSCmdlet.ShouldProcess("$SqlServer/$SqlDatabase", 'apply archive-index schema')) {
        [void](Invoke-SqlCmd -InputFile (Resolve-Path $schemaFile).Path)
        Ok 'schema applied'
    }
    foreach ($obj in @('archive.Message', 'archive.MessageStaging', 'archive.LoadRun')) {
        $exists = Get-SqlScalar "SET NOCOUNT ON; SELECT CASE WHEN OBJECT_ID('$obj','U') IS NULL THEN 0 ELSE 1 END;"
        if ($exists -eq '1') { Ok "table present: $obj" } else { Bad "table MISSING: $obj" }
    }
    foreach ($vw in @('archive.vMessageClassified', 'archive.vMessageSignal', 'archive.vMojibakeTripwire', 'archive.vCoverage')) {
        $exists = Get-SqlScalar "SET NOCOUNT ON; SELECT CASE WHEN OBJECT_ID('$vw','V') IS NULL THEN 0 ELSE 1 END;"
        if ($exists -eq '1') { Ok "view present: $vw" } else { Bad "view MISSING: $vw" }
    }

    # ── Verification (shared by -VerifyOnly and the post-load pass) ───────────
    function Invoke-IndexVerification {
        Step 'Verification (server-side content checks)'
        $total  = Get-SqlScalar 'SET NOCOUNT ON; SELECT COUNT(*) FROM archive.Message;'
        $signal = Get-SqlScalar 'SET NOCOUNT ON; SELECT COUNT(*) FROM archive.vMessageSignal;'
        $runs   = Get-SqlScalar 'SET NOCOUNT ON; SELECT COUNT(*) FROM archive.LoadRun;'
        Ok "indexed messages: $total  (signal after noise filter: $signal; load runs: $runs)"

        # Counts alone never prove a load: check the CONTENT for the UTF-8-as-1252
        # signature that a BOM-less input file would have produced.
        $moji = Get-SqlScalar 'SET NOCOUNT ON; SELECT COUNT(*) FROM archive.vMojibakeTripwire;'
        if ($moji -eq '0') { Ok 'mojibake tripwire clean (0 rows)' }
        else { Bad "mojibake tripwire FIRED: $moji row(s) contain UTF-8-as-1252 damage - the load path lost its BOM; fix encoding and reload, do not clean the data" }

        $orphan = Get-SqlScalar "SET NOCOUNT ON; SELECT COUNT(*) FROM archive.Message WHERE MessageId IS NULL OR LTRIM(RTRIM(MessageId)) = N'';"
        if ($orphan -eq '0') { Ok 'no rows with an empty natural key' } else { Bad "$orphan row(s) have an empty MessageId" }

        $nullRecv = Get-SqlScalar 'SET NOCOUNT ON; SELECT COUNT(*) FROM archive.Message WHERE ReceivedUtc IS NULL;'
        if ($nullRecv -eq '0') { Ok 'every row has a received timestamp' } else { Info "$nullRecv row(s) have no ReceivedUtc (report column was blank)" }

        if ([int]$total -gt 0) {
            Note ''
            Note 'Coverage by store and year:'
            Note (Invoke-SqlCmd -Query 'SET NOCOUNT ON; SELECT StoreKind, ReceivedYear, Messages, SignalMessages FROM archive.vCoverage ORDER BY StoreKind, ReceivedYear;')
            Note ''
            Note 'Most recent indexed messages:'
            Note (Invoke-SqlCmd -Query 'SET NOCOUNT ON; SELECT TOP 5 CONVERT(char(10), ReceivedUtc, 23) AS Received, LEFT(SenderAddress, 30) AS Sender, LEFT(Subject, 46) AS Subject, COALESCE(NoiseReason, N''-'') AS Noise FROM archive.vMessageClassified ORDER BY ReceivedUtc DESC;')
        }
    }

    if ($VerifyOnly) {
        Invoke-IndexVerification
        Write-Host ''
        if ($script:Issues.Count -eq 0) {
            Write-Host 'ALL CHECKS GREEN' -ForegroundColor Green
        } else {
            Write-Host "PROBLEMS ($($script:Issues.Count)):" -ForegroundColor Red
            for ($i = 0; $i -lt $script:Issues.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $script:Issues[$i]) -ForegroundColor Red }
        }
        Write-Host "`nLog: $script:LogPath" -ForegroundColor Cyan
        if ($script:Issues.Count -gt 0) { exit 1 } else { exit 0 }
    }

    if ($SchemaOnly) {
        Ok 'SchemaOnly: schema verified, nothing loaded'
        Write-Host "`nLog: $script:LogPath" -ForegroundColor Cyan
        exit 0
    }

    if (-not $Query) { throw 'A -Query is required unless -VerifyOnly / -SchemaOnly is used.' }
    if (-not $Tag) {
        $slug = ($Query -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLower()
        if ($slug.Length -gt 60) { $slug = $slug.Substring(0, 60) }
        $Tag = "$slug-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd'))"
    }
    Ok "batch tag: $Tag"

    # ── 3. Azure auth (live token probe -- cached sessions lie) ───────────────
    Step '3. Azure sign-in'
    $acct = az account show -o json 2>$null | ConvertFrom-Json
    if (-not $acct) { az login --tenant $TenantId --output none; $acct = az account show -o json | ConvertFrom-Json }
    if ($acct.id -ne $SubscriptionId) { az account set --subscription $SubscriptionId }
    $null = az account get-access-token --resource 'https://management.azure.com/' -o json 2>$null
    if ($LASTEXITCODE -ne 0) {
        Info 'cached session stale (CA 4h sign-in frequency) - re-authenticating'
        az logout 2>$null
        az login --tenant $TenantId --output none
        az account set --subscription $SubscriptionId
    }
    Ok "signed in as $((az account show -o json | ConvertFrom-Json).user.name)"

    $secret = az keyvault secret show --vault-name $VaultName --name mcp-exchange-client-secret --query value -o tsv
    if (-not $secret) { throw "Cannot read mcp-exchange-client-secret from $VaultName (needs Key Vault Secrets User)." }
    Ok 'client secret read from Key Vault (not displayed)'

    function Get-AppToken([string]$Scope) {
        (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
            grant_type = 'client_credentials'; client_id = $AppId; client_secret = $secret; scope = $Scope
        }).access_token
    }
    $graphToken = Get-AppToken 'https://graph.microsoft.com/.default'
    Ok 'app-only Graph token acquired'

    # ── eDiscovery helpers ────────────────────────────────────────────────────
    $CASES = 'https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases'
    function Invoke-Graph {
        param([string]$Method, [string]$Uri, $Body, [switch]$WithHeaders)
        $p = @{ Method = $Method; Uri = $Uri; Headers = @{ Authorization = "Bearer $graphToken" } }
        if ($Body) { $p.Body = ($Body | ConvertTo-Json -Depth 8); $p.ContentType = 'application/json' }
        if ($WithHeaders) {
            $r = Invoke-WebRequest @p
            $content = if ($r.Content) { $r.Content | ConvertFrom-Json } else { $null }
            return @{ Body = $content; Headers = $r.Headers }
        }
        return Invoke-RestMethod @p
    }

    # The app holds eDiscovery MANAGER, which reaches only cases the APP created
    # (a human-created case 401s app-only -- proven by Test-EDiscoveryAppAccess).
    # Hence a dedicated app-owned case for the loader.
    Step '4. eDiscovery case and data source'
    $case = (Invoke-Graph GET "$CASES`?`$top=100").value | Where-Object { $_.displayName -eq $CaseName } | Select-Object -First 1
    if (-not $case) {
        $case = Invoke-Graph POST $CASES @{
            displayName = $CaseName
            description = 'App-owned case for Import-ArchiveSearchToSql.ps1 (archive index loads). Report-only exports.'
        }
        Ok "case created: $CaseName ($($case.id))"
    } else {
        Ok "case reused: $CaseName ($($case.id))"
    }
    $caseId = $case.id

    $src = (Invoke-Graph GET "$CASES/$caseId/noncustodialDataSources").value | Select-Object -First 1
    if (-not $src) {
        $src = Invoke-Graph POST "$CASES/$caseId/noncustodialDataSources" @{
            dataSource = @{ '@odata.type' = 'microsoft.graph.security.userSource'; email = $MailboxUpn.ToLower() }
        }
        Ok "data source created for $MailboxUpn"
    } else {
        Ok "data source reused ($($src.id))"
    }
    $sourceId = $src.id

    function New-Search([string]$Kql) {
        $s = Invoke-Graph POST "$CASES/$caseId/searches" @{
            displayName                     = "sqlload-$((New-Guid).Guid.Substring(0,8))"
            description                     = "Import-ArchiveSearchToSql $version : $Tag"
            contentQuery                    = $Kql
            'noncustodialSources@odata.bind' = @("$CASES/$caseId/noncustodialDataSources/$sourceId")
        }
        return $s.id
    }
    function Get-Estimate([string]$SearchId, [int]$BudgetSeconds = 300) {
        [void](Invoke-Graph POST "$CASES/$caseId/searches/$SearchId/estimateStatistics" $null)
        $waited = 0
        while ($true) {
            $s = Invoke-Graph GET "$CASES/$caseId/searches/$SearchId`?`$expand=lastEstimateStatisticsOperation"
            $op = $s.lastEstimateStatisticsOperation
            $st = if ($op -and $op.status) { "$($op.status)".ToLower() } else { 'notstarted' }
            if ($st -eq 'succeeded') {
                return @{ Status = 'succeeded'; Count = [int]$op.indexedItemCount; Size = [int64]$op.indexedItemsSize }
            }
            if ($st -eq 'failed') { return @{ Status = 'failed'; Count = 0; Size = 0 } }
            if ($waited -ge $BudgetSeconds) { return @{ Status = 'timeout'; Count = -1; Size = 0 } }
            Start-Sleep -Seconds 10; $waited += 10
        }
    }
    function Remove-Search([string]$SearchId) {
        if ($KeepSearches) { return }
        try { [void](Invoke-Graph DELETE "$CASES/$caseId/searches/$SearchId" $null) } catch { Info "could not delete search $SearchId (harmless)" }
    }
    function Get-KqlForWindow([datetime]$From, [datetime]$To) {
        $f = $From.ToString('yyyy-MM-dd'); $t = $To.ToString('yyyy-MM-dd')
        return "$Query AND $DateField>=$f AND $DateField<=$t"
    }

    # ── 5. Plan windows (auto-bisect past the export ceiling) ────────────────
    Step "5. Plan date windows (export ceiling $ExportItemLimit/search)"
    Info 'each probe runs an eDiscovery estimate (~90-120s) - this is the slow part'
    $plan  = [System.Collections.Generic.List[object]]::new()
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push([PSCustomObject]@{ From = $StartDate.Date; To = $EndDate.Date })
    $probes = 0

    while ($stack.Count -gt 0) {
        $w = $stack.Pop()
        $probes++
        $kql = Get-KqlForWindow $w.From $w.To
        $sid = New-Search $kql
        $est = Get-Estimate $sid
        $label = "{0}..{1}" -f $w.From.ToString('yyyy-MM-dd'), $w.To.ToString('yyyy-MM-dd')

        if ($est.Status -ne 'succeeded') {
            Bad "window $label estimate $($est.Status) - skipped (re-run to retry this window)"
            Remove-Search $sid
            continue
        }
        if ($est.Count -eq 0) {
            Note "  window $label : 0 matches (skip)"
            Remove-Search $sid
            continue
        }
        if ($est.Count -le $ExportItemLimit) {
            Ok "window $label : $($est.Count) matches - exportable"
            [void]$plan.Add([PSCustomObject]@{ From = $w.From; To = $w.To; Count = $est.Count; SearchId = $sid; Kql = $kql })
            continue
        }

        Remove-Search $sid
        $span = ($w.To - $w.From).Days
        if ($span -le 1) {
            Bad "window $label has $($est.Count) matches in <=1 day - cannot split further; export will cap at $ExportItemLimit and this window stays INCOMPLETE"
            $sid2 = New-Search $kql
            [void]$plan.Add([PSCustomObject]@{ From = $w.From; To = $w.To; Count = $est.Count; SearchId = $sid2; Kql = $kql })
            continue
        }
        $mid = $w.From.AddDays([Math]::Floor($span / 2))
        Info "window $label : $($est.Count) matches > ceiling - splitting at $($mid.ToString('yyyy-MM-dd'))"
        $stack.Push([PSCustomObject]@{ From = $mid.AddDays(1); To = $w.To })
        $stack.Push([PSCustomObject]@{ From = $w.From;         To = $mid })
    }

    $plannedTotal = ($plan | Measure-Object -Property Count -Sum).Sum
    Ok "plan: $($plan.Count) window(s), $plannedTotal matches, after $probes probe(s)"
    if ($plan.Count -eq 0) { throw 'No exportable windows -- nothing matched the query in the given range.' }

    # ── 6. Export, parse, load each window ───────────────────────────────────
    Step '6. Export, parse and load'
    $colMap = @{
        MessageId     = @('internet message id', 'internetmessageid', 'message id')
        ItemId        = @('immutable id', 'immutableid', 'item id', 'document id')
        Subject       = @('subject/title', 'subject', 'title')
        SenderAddress = @('sender/author', 'sender', 'from', 'author', 'sender address')
        ReceivedUtc   = @('received', 'date received', 'received date', 'date', 'email date sent')
        FolderPath    = @('original path', 'compound path', 'folder path', 'parent folder path', 'location path')
        StoreKind     = @('location sub type', 'locationsubtype')
        SizeBytes     = @('size', 'native size')
    }
    function Resolve-Column($Headers, [string[]]$Candidates) {
        $lower = @{}
        foreach ($h in $Headers) { if ($h) { $lower[$h.Trim().Trim('"').ToLower()] = $h } }
        foreach ($c in $Candidates) { if ($lower.ContainsKey($c)) { return $lower[$c] } }
        return $null
    }
    function ConvertTo-SqlLiteral($Value) {
        if ($null -eq $Value) { return 'NULL' }
        $s = [string]$Value
        if (-not $s.Trim()) { return 'NULL' }
        return "N'" + $s.Replace("'", "''") + "'"
    }
    function ConvertTo-SqlDate($Value) {
        if (-not $Value) { return 'NULL' }
        $dt = [datetime]::MinValue
        if ([datetime]::TryParse([string]$Value, [ref]$dt)) {
            return "'" + $dt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss') + "'"
        }
        return 'NULL'
    }

    $downloadToken = Get-AppToken "$PurviewAppId/.default"
    $grandStaged = 0; $grandInserted = 0; $grandUpdated = 0
    $windowIndex = 0

    foreach ($w in $plan) {
        $windowIndex++
        $label = "{0}..{1}" -f $w.From.ToString('yyyy-MM-dd'), $w.To.ToString('yyyy-MM-dd')
        Info "[$windowIndex/$($plan.Count)] window $label ($($w.Count) matches)"

        # LoadRun row first: provenance survives even if the export fails.
        $runIdRaw = Get-SqlScalar (@"
SET NOCOUNT ON;
INSERT INTO archive.LoadRun (Tag, KqlQuery, WindowStart, WindowEnd, MatchedCount, SearchId, Status)
VALUES ($(ConvertTo-SqlLiteral $Tag), $(ConvertTo-SqlLiteral $w.Kql), '$($w.From.ToString('yyyy-MM-dd'))', '$($w.To.ToString('yyyy-MM-dd'))', $($w.Count), $(ConvertTo-SqlLiteral $w.SearchId), N'running');
SELECT CAST(SCOPE_IDENTITY() AS int);
"@)
        $runId = [int]$runIdRaw
        Note "  LoadRunId $runId"

        # exportReport -> operation id from the 202 Location header
        $exp = Invoke-Graph POST "$CASES/$caseId/searches/$($w.SearchId)/exportReport" @{
            displayName       = "sqlload-report-$((New-Guid).Guid.Substring(0,8))"
            exportCriteria    = 'searchHits'
            additionalOptions = 'none'
        } -WithHeaders
        $loc = @('Location', 'location') | ForEach-Object { if ($exp.Headers[$_]) { $exp.Headers[$_] | Select-Object -First 1 } } | Where-Object { $_ } | Select-Object -First 1
        $opId = $null
        if ($loc -and ($loc -match "operations[/(]'?([0-9a-fA-F-]{16,})")) { $opId = $matches[1] }
        if (-not $opId) { Bad "window $label : no operation id in exportReport response - skipped"; continue }

        $op = $null; $waited = 0
        while ($true) {
            $op = Invoke-Graph GET "$CASES/$caseId/operations/$opId"
            $st = "$($op.status)".ToLower()
            if ($st -in @('succeeded', 'partiallysucceeded')) { break }
            if ($st -eq 'failed') { break }
            if ($waited -ge 600) { break }
            Start-Sleep -Seconds 10; $waited += 10
        }
        if ("$($op.status)".ToLower() -notin @('succeeded', 'partiallysucceeded')) {
            Bad "window $label : export operation $($op.status) after ${waited}s - skipped"
            [void](Invoke-SqlCmd -Query "UPDATE archive.LoadRun SET Status=N'export-failed', CompletedUtc=SYSUTCDATETIME() WHERE LoadRunId=$runId;")
            continue
        }

        $files = @($op.exportFileMetadata)
        if (-not $files.Count) { Bad "window $label : export produced no files - skipped"; continue }
        $zip = Join-Path $env:TEMP ("arcidx-{0}.zip" -f (New-Guid).Guid.Substring(0, 8))
        Invoke-WebRequest -Method GET -Uri $files[0].downloadUrl -OutFile $zip `
            -Headers @{ Authorization = "Bearer $downloadToken"; 'X-AllowWithAADToken' = 'true' } | Out-Null
        $extract = Join-Path $env:TEMP ("arcidx-x-{0}" -f (New-Guid).Guid.Substring(0, 8))
        Expand-Archive -Path $zip -DestinationPath $extract -Force

        $csv = Get-ChildItem $extract -Recurse -File -Filter *.csv |
               Where-Object { $_.Name -match '(?i)item' } | Select-Object -First 1
        if (-not $csv) { $csv = Get-ChildItem $extract -Recurse -File -Filter *.csv | Select-Object -First 1 }
        if (-not $csv) { Bad "window $label : no CSV in the report package - skipped"; continue }
        $rows = @(Import-Csv -LiteralPath $csv.FullName)
        Note "  report: $($csv.Name), $($rows.Count) row(s)"

        if ($rows.Count -eq 0) {
            [void](Invoke-SqlCmd -Query "UPDATE archive.LoadRun SET Status=N'empty-report', RetrievedCount=0, ExportOpId=$(ConvertTo-SqlLiteral $opId), CompletedUtc=SYSUTCDATETIME() WHERE LoadRunId=$runId;")
            Remove-Item $zip, $extract -Recurse -Force -ErrorAction SilentlyContinue
            continue
        }

        $headers = $rows[0].PSObject.Properties.Name
        $cols = @{}
        foreach ($k in $colMap.Keys) { $cols[$k] = Resolve-Column $headers $colMap[$k] }
        foreach ($required in @('MessageId', 'Subject', 'ReceivedUtc')) {
            if (-not $cols[$required]) { Bad "window $label : report has no column mapping to $required (export format changed?)" }
        }

        # Build the staging load as a UTF-8 *with BOM* .sql file. Classic sqlcmd
        # reads input files in the system ANSI codepage unless a BOM is present;
        # without it every em-dash and curly quote in a subject loads as
        # mojibake and no count-based check notices (the tripwire view exists
        # because that bit us once).
        $sqlFile = Join-Path $env:TEMP ("arcidx-load-{0}.sql" -f (New-Guid).Guid.Substring(0, 8))
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine('SET NOCOUNT ON;')
        [void]$sb.AppendLine('TRUNCATE TABLE archive.MessageStaging;')
        [void]$sb.AppendLine('GO')
        $batch = 0
        foreach ($r in $rows) {
            if ($batch -eq 0) {
                [void]$sb.AppendLine('INSERT INTO archive.MessageStaging (MessageId, ItemId, Subject, SenderAddress, ReceivedUtc, FolderPath, StoreKind, SizeBytes) VALUES')
            }
            $size = 'NULL'
            if ($cols['SizeBytes']) {
                $sv = [string]$r.($cols['SizeBytes'])
                if ($sv -match '^\d+$') { $size = $sv }
            }
            $vals = @(
                (ConvertTo-SqlLiteral $(if ($cols['MessageId'])     { $r.($cols['MessageId']) }     else { $null })),
                (ConvertTo-SqlLiteral $(if ($cols['ItemId'])        { $r.($cols['ItemId']) }        else { $null })),
                (ConvertTo-SqlLiteral $(if ($cols['Subject'])       { $r.($cols['Subject']) }       else { $null })),
                (ConvertTo-SqlLiteral $(if ($cols['SenderAddress']) { $r.($cols['SenderAddress']) } else { $null })),
                (ConvertTo-SqlDate    $(if ($cols['ReceivedUtc'])   { $r.($cols['ReceivedUtc']) }   else { $null })),
                (ConvertTo-SqlLiteral $(if ($cols['FolderPath'])    { $r.($cols['FolderPath']) }    else { $null })),
                (ConvertTo-SqlLiteral $(if ($cols['StoreKind'])     { $r.($cols['StoreKind']) }     else { $null })),
                $size
            ) -join ', '
            $batch++
            $terminator = if ($batch -ge 200) { ';' } else { ',' }
            [void]$sb.AppendLine("($vals)$terminator")
            if ($batch -ge 200) { [void]$sb.AppendLine('GO'); $batch = 0 }
        }
        if ($batch -gt 0) {
            # Last emitted row ended with ',' -- close the statement.
            $text = $sb.ToString().TrimEnd("`r", "`n")
            $text = $text.Substring(0, $text.Length - 1) + ';'
            $sb = [System.Text.StringBuilder]::new($text)
            [void]$sb.AppendLine(''); [void]$sb.AppendLine('GO')
        }
        [void]$sb.AppendLine("EXEC archive.usp_MergeStaging @LoadRunId = $runId;")
        Set-Content -LiteralPath $sqlFile -Value $sb.ToString() -Encoding utf8BOM

        $mergeOut = Invoke-SqlCmd -InputFile $sqlFile
        Note ("  " + (($mergeOut -split "`n" | Where-Object { $_.Trim() }) -join "`n  "))
        $nums = [regex]::Matches($mergeOut, '\d+') | ForEach-Object { [int]$_.Value }
        $staged = if ($nums.Count -ge 3) { $nums[-3] } else { $rows.Count }
        $ins    = if ($nums.Count -ge 3) { $nums[-2] } else { 0 }
        $upd    = if ($nums.Count -ge 3) { $nums[-1] } else { 0 }
        $grandStaged += $staged; $grandInserted += $ins; $grandUpdated += $upd

        [void](Invoke-SqlCmd -Query "UPDATE archive.LoadRun SET Status=N'loaded', RetrievedCount=$($rows.Count), ExportOpId=$(ConvertTo-SqlLiteral $opId), CompletedUtc=SYSUTCDATETIME() WHERE LoadRunId=$runId;")
        Ok "window $label loaded: staged $staged, inserted $ins, updated $upd"

        Remove-Item $zip, $extract, $sqlFile -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Search $w.SearchId
    }

    Ok "load complete: staged $grandStaged, inserted $grandInserted, updated $grandUpdated across $($plan.Count) window(s)"

    # ── 7. Verify ─────────────────────────────────────────────────────────────
    Invoke-IndexVerification

    Write-Host ''
    if ($script:Issues.Count -eq 0) {
        Write-Host 'ALL CHECKS GREEN' -ForegroundColor Green
        Write-Host "  Query the index:  SELECT * FROM archive.vMessageSignal ORDER BY ReceivedUtc DESC;" -ForegroundColor Yellow
    } else {
        Write-Host "PROBLEMS ($($script:Issues.Count)):" -ForegroundColor Red
        for ($i = 0; $i -lt $script:Issues.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $script:Issues[$i]) -ForegroundColor Red }
    }
}
finally {
    Write-Host "`nLog saved to: $script:LogPath" -ForegroundColor Cyan
    Stop-Transcript | Out-Null
}
if ($script:Issues.Count -gt 0) { exit 1 }
