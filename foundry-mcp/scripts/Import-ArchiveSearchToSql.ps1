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

.PARAMETER CreateDatabase
    Create the target database if it does not exist (then apply the schema).
    Use on first run. Creates a database only -- never drops or overwrites one.

.PARAMETER VerifyOnly
    Check schema + index content and mutate nothing. Exits 1 if anything is off.

.EXAMPLE
    # First run: create the database, apply the schema, load nothing yet.
    .\Import-ArchiveSearchToSql.ps1 -CreateDatabase -SchemaOnly

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
    # Integrated = Windows auth via sqlcmd (LocalDB / on-prem).
    # Entra      = Azure SQL via System.Data.SqlClient with an access token from
    #              the Azure CLI session -- no browser prompt, and independent of
    #              domain/hybrid join or tenant federation.
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
    # Per-attempt wait for an eDiscovery estimate. On timeout the loader waits
    # a second budget on the SAME run before giving up on that window.
    [int]    $EstimateBudgetSeconds = 300,
    [switch] $CreateDatabase,
    [switch] $SchemaOnly,
    [switch] $VerifyOnly,
    [switch] $KeepSearches
)

$version = '1.4.0'
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

    # LocalDB automatic instances shut down after ~5 minutes idle and get a NEW
    # named pipe when they restart. This loader has long SQL-idle stretches (a
    # ~2 min estimate probe, then export + download), so the instance can be
    # gone by the time the next batch runs -- surfacing as 'Server is not found
    # or not accessible' or a bogus 'Login failed for user' (both seen live
    # 2026-08-14; one restart also detached the database). Start-LocalDb is
    # therefore called before every SQL phase AND from the retry handler, where
    # it is the actual remedy rather than just a wait.
    $isLocalDb  = $SqlServer -match '^\(localdb\)\\(.+)$'
    $dbInstance = if ($isLocalDb) { $matches[1] } else { $null }
    $script:HaveLocalDbTool = [bool](Get-Command sqllocaldb -ErrorAction SilentlyContinue)

    function Start-LocalDb {
        param([switch]$Report)
        if (-not $isLocalDb -or -not $script:HaveLocalDbTool) { return }
        $null = & sqllocaldb start $dbInstance 2>&1
        if ($Report) {
            $m = (& sqllocaldb info $dbInstance 2>&1 | Select-String -Pattern '^State:\s*(.+)$')
            $state = if ($m) { $m.Matches.Groups[1].Value.Trim() } else { 'unknown' }
            Ok "LocalDB instance '$dbInstance' state: $state"
        }
    }

    if ($isLocalDb -and -not $script:HaveLocalDbTool) {
        Info 'sqllocaldb not on PATH - cannot keep the LocalDB instance alive across idle gaps'
    }
    Start-LocalDb -Report

    $schemaFile = Join-Path $PSScriptRoot '..\sql\archive-index-schema.sql'
    if (-not (Test-Path $schemaFile)) { throw "Schema file not found: $schemaFile" }

    # ── Azure SQL executor (token auth via System.Data.SqlClient) ─────────────
    $script:SqlAccessToken = $null
    function Get-SqlAccessToken {
        if (-not $script:SqlAccessToken) {
            $script:SqlAccessToken = az account get-access-token --resource 'https://database.windows.net/' --query accessToken -o tsv 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $script:SqlAccessToken) {
                throw 'Could not obtain an Azure SQL access token from the az session (run az login and retry).'
            }
        }
        return $script:SqlAccessToken
    }

    # Azure SQL transient fault numbers: connection reset / throttling / failover
    # / serverless resume. Worth retrying; anything else is a real error.
    $script:SqlTransient = @(4060, 40197, 40501, 40613, 49918, 49919, 49920, 10928, 10929, 10053, 10054, 10060, 233, 64, 20)

    # NOTE: the parameter is $Database, never $Db. A [Parameter()] attribute
    # promotes a function to an ADVANCED function, which inherits the common
    # parameters -- and -Debug carries the alias 'db', so a $Db parameter is
    # rejected at parse time ("conflicts with the parameter alias of the same
    # name for parameter 'Debug'").
    function Invoke-SqlViaToken {
        param([Parameter(Mandatory)][string]$Sql, [string]$Database, [int]$MaxAttempts = 4)
        if (-not $Database) { $Database = $SqlDatabase }
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            try { return Invoke-SqlViaTokenOnce -Sql $Sql -Database $Database }
            catch {
                # $conn.Open() throwing a SqlException reaches us wrapped in a
                # MethodInvocationException: the catch type filter matches on the
                # INNER exception, but $_.Exception is the wrapper, which has no
                # .Number -- reading it blind throws under StrictMode and turns a
                # retryable blip into a crash. Unwrap to the SqlException first.
                $ex = $_.Exception
                while ($ex -and $ex -isnot [System.Data.SqlClient.SqlException]) { $ex = $ex.InnerException }
                if (-not $ex) { throw }
                $num = $ex.Number
                if ($attempt -ge $MaxAttempts -or $num -notin $script:SqlTransient) { throw }
                $wait = 5 * $attempt
                Info "transient SQL error $num (attempt $attempt/$MaxAttempts) - retrying in ${wait}s..."
                Start-Sleep -Seconds $wait
            }
        }
    }

    function Invoke-SqlViaTokenOnce {
        param([Parameter(Mandatory)][string]$Sql, [string]$Database)
        if (-not $Database) { $Database = $SqlDatabase }
        $conn = [System.Data.SqlClient.SqlConnection]::new(
            "Server=tcp:$SqlServer,1433;Initial Catalog=$Database;Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;")
        $conn.AccessToken = Get-SqlAccessToken
        $out = [System.Collections.Generic.List[string]]::new()
        try {
            $conn.Open()
            # GO is a sqlcmd batch separator, not T-SQL -- split it out here.
            foreach ($batch in ($Sql -split '(?im)^\s*GO\s*$')) {
                if (-not $batch.Trim()) { continue }
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = $batch
                $cmd.CommandTimeout = 300   # bulk staging inserts can be chunky
                $reader = $cmd.ExecuteReader()
                try {
                    do {
                        while ($reader.Read()) {
                            $vals = for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                                if ($reader.IsDBNull($i)) { '' } else { [string]$reader.GetValue($i) }
                            }
                            [void]$out.Add(($vals -join '  '))
                        }
                    } while ($reader.NextResult())
                } finally { $reader.Close(); $cmd.Dispose() }
            }
            return ($out -join "`n").Trim()
        } finally { $conn.Dispose() }
    }

    # ── sqlcmd wrapper (Integrated auth: LocalDB / on-prem) ───────────────────
    # -I: QUOTED_IDENTIFIER ON (the OFF default breaks filtered indexes, err 1934)
    # -b: non-zero exit on SQL error, so failures actually fail
    # Azure SQL serverless: the FIRST connection to a paused database triggers
    # the resume AND fails with 40613. Retry through the wake-up window rather
    # than treating it as fatal.
    function Invoke-SqlCmd {
        param(
            [string]$Query,
            [string]$InputFile,
            [string]$Db,
            [switch]$Scalar,
            [int]$MaxAttempts = 5
        )
        if (-not $Db) { $Db = $SqlDatabase }

        # Azure SQL: connect with an ACCESS TOKEN, not sqlcmd -G. With ODBC 17,
        # -G alone means ActiveDirectoryIntegrated, which needs a FEDERATED
        # tenant (AD FS/WS-Trust) -- hybrid Entra join is not enough, and it
        # fails 0xCAA9001F "supported only in federation flow" (2026-08-14).
        # -G -U would prompt a browser on every invocation. A bearer token from
        # the az session works regardless of join or federation state, needs no
        # extra modules, and keeps SQL text out of any shell.
        if ($SqlAuth -eq 'Entra') {
            $sqlText = if ($InputFile) { Get-Content -LiteralPath $InputFile -Raw } else { $Query }
            return Invoke-SqlViaToken -Sql $sqlText -Database $Db
        }

        # NEVER pass SQL through -Q. Any embedded double quote -- and KQL like
        # subject:"First Day at GI Partners" is full of them -- terminates the
        # Win32 argument string, so sqlcmd receives stray arguments and exits 1
        # ("Unexpected argument", hit live 2026-08-14). Writing the batch to a
        # file and using -i removes shell quoting from the picture entirely, and
        # the file needs its UTF-8 BOM regardless: classic sqlcmd reads input
        # files in the ANSI codepage without one and silently mojibakes every
        # em-dash and curly quote.
        $tempQueryFile = $null
        if (-not $InputFile) {
            $tempQueryFile = Join-Path $env:TEMP ("arcidx-q-{0}.sql" -f (New-Guid).Guid.Substring(0, 8))
            Set-Content -LiteralPath $tempQueryFile -Value $Query -Encoding utf8BOM
            $InputFile = $tempQueryFile
        }

        $argsBase = @('-S', $SqlServer, '-d', $Db, '-I', '-b', '-i', $InputFile)
        $argsBase += '-E'
        if ($Scalar) { $argsBase += @('-h', '-1', '-W') }

        try {
            for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
                $out = & sqlcmd @argsBase 2>&1
                $text = ($out | Out-String).Trim()
                if ($LASTEXITCODE -eq 0) { return $text }
                if ($text -match '40613|not currently available|is paused') {
                    Info "database waking (attempt $attempt/$MaxAttempts) - retrying in 30s..."
                    Start-Sleep -Seconds 30
                    continue
                }
                # LocalDB instance stopped (idle timeout) or restarted onto a new
                # pipe. Restart it and retry -- the restart IS the fix, so this
                # branch acts rather than just sleeping. Patterns cover every
                # message seen live: stopped instance, stale pipe, and the
                # mid-start login failure. A genuine permission or SQL error
                # still surfaces because none of these patterns match it.
                if ($isLocalDb -and $attempt -lt $MaxAttempts -and
                    $text -match 'Login failed for user|Cannot open database|not found or not accessible|Login timeout expired|SQL Server Network Interfaces|error has occurred while establishing') {
                    Info "LocalDB instance unavailable (attempt $attempt/$MaxAttempts) - restarting it and retrying..."
                    Start-LocalDb
                    Start-Sleep -Seconds 3
                    continue
                }
                throw "sqlcmd failed (exit $LASTEXITCODE): $text"
            }
            throw "sqlcmd could not reach $SqlDatabase after $MaxAttempts attempts (serverless wake-up window exceeded)."
        }
        finally {
            if ($tempQueryFile) { Remove-Item $tempQueryFile -Force -ErrorAction SilentlyContinue }
        }
    }

    function Get-SqlScalar([string]$Q) {
        $v = Invoke-SqlCmd -Query $Q -Scalar
        return ($v -split "`n" | Where-Object { $_ -and $_ -notmatch '^\(\d+ rows affected\)$' } | Select-Object -First 1).Trim()
    }

    # ── Database bootstrap (creates only; never drops or overwrites) ──────────
    # Defined after the sqlcmd helpers because PowerShell resolves functions at
    # call time, not parse time.
    # sys.databases, NOT DB_ID(): in Azure SQL, DB_ID('other-db') evaluated from
    # master returns NULL because cross-database metadata does not resolve that
    # way, so the check reported a live database as missing (2026-08-14).
    # sys.databases in master lists every database on the logical server and
    # behaves identically on LocalDB / on-prem.
    $dbExists = (Invoke-SqlCmd -Db 'master' -Scalar `
        -Query "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name = N'$SqlDatabase';")
    $dbExists = ($dbExists -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1).Trim()
    if ($dbExists -eq '1') {
        Ok "database exists: $SqlDatabase"
    } elseif ($CreateDatabase -and -not $VerifyOnly) {
        if ($PSCmdlet.ShouldProcess($SqlServer, "create database $SqlDatabase")) {
            [void](Invoke-SqlCmd -Db 'master' -Query "IF DB_ID('$SqlDatabase') IS NULL CREATE DATABASE [$SqlDatabase];")
            Ok "database created: $SqlDatabase"
        }
    } else {
        throw "Database '$SqlDatabase' does not exist on $SqlServer. Re-run with -CreateDatabase to create it."
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
    # The MERGE proc is the last step of every load -- check it here rather than
    # discovering it is missing after an export has already been paid for.
    $procExists = Get-SqlScalar "SET NOCOUNT ON; SELECT CASE WHEN OBJECT_ID('archive.usp_MergeStaging','P') IS NULL THEN 0 ELSE 1 END;"
    if ($procExists -eq '1') { Ok 'procedure present: archive.usp_MergeStaging' } else { Bad 'procedure MISSING: archive.usp_MergeStaging' }

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
    # Start and WAIT are separate on purpose: a timeout must be able to keep
    # waiting on the estimate already running, not POST estimateStatistics again
    # (which restarts the clock and never converges on a slow window).
    function Start-EstimateRun([string]$SearchId) {
        [void](Invoke-Graph POST "$CASES/$caseId/searches/$SearchId/estimateStatistics" $null)
    }
    function Wait-Estimate([string]$SearchId, [int]$BudgetSeconds) {
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
    function Get-Estimate([string]$SearchId, [int]$BudgetSeconds = $EstimateBudgetSeconds) {
        Start-EstimateRun $SearchId
        $est = Wait-Estimate $SearchId $BudgetSeconds
        if ($est.Status -eq 'timeout') {
            # Keep waiting on the SAME run rather than giving up: big windows on
            # a busy service routinely exceed the first budget (2026-08-14, a
            # 1037-match window timed out and lost the whole plan).
            Info "  estimate still running after ${BudgetSeconds}s - waiting up to ${BudgetSeconds}s more (not restarting it)"
            $est = Wait-Estimate $SearchId $BudgetSeconds
        }
        return $est
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
    # KnownCount carries a count we can infer without paying for a probe.
    $stack.Push([PSCustomObject]@{ From = $StartDate.Date; To = $EndDate.Date; KnownCount = -1 })
    $probes  = 0
    $skipped = 0

    while ($stack.Count -gt 0) {
        $w = $stack.Pop()
        $label = "{0}..{1}" -f $w.From.ToString('yyyy-MM-dd'), $w.To.ToString('yyyy-MM-dd')

        # A window we already know exceeds the ceiling only needs splitting, and
        # splitting needs no search and no estimate -- skip straight to it.
        if ($w.KnownCount -gt $ExportItemLimit) {
            $est = @{ Status = 'succeeded'; Count = $w.KnownCount; Size = 0 }
            $sid = $null
            Info "window $label : $($w.KnownCount) matches (inherited from its sibling - probe skipped)"
        } else {
            $probes++
            $kql = Get-KqlForWindow $w.From $w.To
            $sid = New-Search $kql
            $est = Get-Estimate $sid
        }

        if ($est.Status -ne 'succeeded') {
            Bad "window $label estimate $($est.Status) - skipped (re-run to retry just this window with -StartDate $($w.From.ToString('yyyy-MM-dd')) -EndDate $($w.To.ToString('yyyy-MM-dd')))"
            if ($sid) { Remove-Search $sid }
            $skipped++
            continue
        }
        if ($est.Count -eq 0) {
            Note "  window $label : 0 matches (skip)"
            if ($sid) { Remove-Search $sid }
            # Everything the parent held must be in the sibling, which is the
            # next item on the stack -- hand it the count so it never probes.
            if ($w.PSObject.Properties.Match('ParentCount').Count -gt 0 -and
                $w.ParentCount -gt 0 -and $stack.Count -gt 0) {
                $sib = $stack.Pop()
                $sib | Add-Member -NotePropertyName KnownCount -NotePropertyValue $w.ParentCount -Force
                $stack.Push($sib)
            }
            continue
        }
        if ($est.Count -le $ExportItemLimit) {
            Ok "window $label : $($est.Count) matches - exportable"
            [void]$plan.Add([PSCustomObject]@{ From = $w.From; To = $w.To; Count = $est.Count; SearchId = $sid; Kql = $kql })
            continue
        }

        if ($sid) { Remove-Search $sid }
        $span = ($w.To - $w.From).Days
        if ($span -le 1) {
            Bad "window $label has $($est.Count) matches in <=1 day - cannot split further; export will cap at $ExportItemLimit and this window stays INCOMPLETE"
            $kql2 = Get-KqlForWindow $w.From $w.To
            $sid2 = New-Search $kql2
            [void]$plan.Add([PSCustomObject]@{ From = $w.From; To = $w.To; Count = $est.Count; SearchId = $sid2; Kql = $kql2 })
            continue
        }
        $mid = $w.From.AddDays([Math]::Floor($span / 2))
        Info "window $label : $($est.Count) matches > ceiling - splitting at $($mid.ToString('yyyy-MM-dd'))"
        # Push right first so the LEFT half pops next; if the left turns out
        # empty it hands its ParentCount to the right half sitting beneath it.
        $stack.Push([PSCustomObject]@{ From = $mid.AddDays(1); To = $w.To;  KnownCount = -1; ParentCount = $est.Count })
        $stack.Push([PSCustomObject]@{ From = $w.From;         To = $mid;   KnownCount = -1; ParentCount = $est.Count })
    }

    # Measure-Object returns NOTHING for an empty pipeline, so .Sum throws under
    # StrictMode -- which is exactly how a fully-skipped plan crashed the run
    # instead of reporting itself (2026-08-14).
    $plannedTotal = 0
    if ($plan.Count -gt 0) { $plannedTotal = ($plan | Measure-Object -Property Count -Sum).Sum }
    Ok "plan: $($plan.Count) window(s), $plannedTotal matches, after $probes probe(s)"
    if ($plan.Count -eq 0) {
        if ($skipped -gt 0) {
            throw "No exportable windows: $skipped window(s) failed their estimate (see above). The searches are transient -- just re-run; the eDiscovery service is usually faster on a second attempt."
        }
        throw "No exportable windows -- nothing matched '$Query' between $($StartDate.ToString('yyyy-MM-dd')) and $($EndDate.ToString('yyyy-MM-dd'))."
    }
    if ($skipped -gt 0) { Info "$skipped window(s) were skipped after estimate failures - re-run to pick them up (already-loaded windows will simply update)" }

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

        # The plan phase spends minutes in Graph with no SQL traffic, which is
        # long enough for a LocalDB instance to idle out. Nudge it awake before
        # the first batch rather than relying on the retry.
        Start-LocalDb

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
    Start-LocalDb
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
