#Requires -Version 7.0
<#
.SYNOPSIS
    Generate the "Welcome to GI Partners" report from the archive index.

.DESCRIPTION
    Reads archive.vMessageSignal (the noise-filtered view) for new-hire
    announcements and renders a self-contained HTML report in the house style:
    a hiring timeline by year, the roster of names with announcement dates, who
    sent the announcements over time, and a provenance block.

    Source of truth is the SQL index built by Import-ArchiveSearchToSql.ps1 --
    metadata only, no message bodies. Names come from the subject line, which
    means the report can only name people whose announcement carried a name;
    the count of unnamed announcements is reported honestly rather than hidden.

    Read-only: issues SELECTs and writes one HTML file.

.EXAMPLE
    .\New-WelcomeToGipReport.ps1

.EXAMPLE
    .\New-WelcomeToGipReport.ps1 -Since 2024-01-01 -OutFile C:\GI\welcome.html
#>
[CmdletBinding()]
param(
    [string]   $SqlServer,
    [string]   $SqlDatabase,
    [string]   $SubjectLike = 'First Day at GI Partners%',
    [datetime] $Since       = '2000-01-01',
    [string]   $OutFile
)

$version = '1.1.0'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogDir = Join-Path $PSScriptRoot '..\logs'
if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
$script:LogPath = Join-Path (Resolve-Path $script:LogDir).Path ("welcome-report-{0}.log" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
Start-Transcript -Path $script:LogPath | Out-Null

function Step ([string]$m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Ok   ([string]$m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Info ([string]$m) { Write-Host "  $m" -ForegroundColor Yellow }

try {
    Write-Host "New-WelcomeToGipReport $version" -ForegroundColor Cyan

    # ── Config ────────────────────────────────────────────────────────────────
    Step '1. Config'
    $envPath = Join-Path $PSScriptRoot '..\..\.env'
    $envVals = @{}
    if (Test-Path $envPath) {
        foreach ($line in Get-Content -LiteralPath $envPath) {
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { $envVals[$matches[1]] = $matches[2].Trim().Trim('"').Trim("'") }
        }
    }
    if (-not $SqlServer)   { $SqlServer   = if ($envVals.ContainsKey('ARCHIVE_SQL_SERVER'))   { $envVals['ARCHIVE_SQL_SERVER'] }   else { 'gip-mcp-hub-sql.database.windows.net' } }
    if (-not $SqlDatabase) { $SqlDatabase = if ($envVals.ContainsKey('ARCHIVE_SQL_DATABASE')) { $envVals['ARCHIVE_SQL_DATABASE'] } else { 'ArchiveIndex' } }
    if (-not $OutFile)     { $OutFile     = Join-Path $PSScriptRoot '..\..\docs\welcome-to-gip.html' }
    Ok "source: $SqlServer / $SqlDatabase"

    # ── Query ─────────────────────────────────────────────────────────────────
    Step '2. Read the index'
    $token = az account get-access-token --resource 'https://database.windows.net/' --query accessToken -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Could not obtain an Azure SQL access token from the CLI session.' }

    $conn = [System.Data.SqlClient.SqlConnection]::new(
        "Server=tcp:$SqlServer,1433;Initial Catalog=$SqlDatabase;Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;")
    $conn.AccessToken = $token
    $rows = [System.Collections.Generic.List[object]]::new()
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        # Parameterised -- subject patterns are data, never string-built SQL.
        $cmd.CommandText = @'
SELECT Subject, SenderAddress, ReceivedUtc, StoreKind, FolderPath
FROM archive.vMessageSignal
WHERE Subject LIKE @pattern AND ReceivedUtc >= @since
ORDER BY ReceivedUtc ASC;
'@
        [void]$cmd.Parameters.AddWithValue('@pattern', $SubjectLike)
        [void]$cmd.Parameters.AddWithValue('@since', $Since)
        $r = $cmd.ExecuteReader()
        while ($r.Read()) {
            [void]$rows.Add([PSCustomObject]@{
                Subject = [string]$r['Subject']
                Sender  = if ($r.IsDBNull($r.GetOrdinal('SenderAddress'))) { '' } else { [string]$r['SenderAddress'] }
                Received = [datetime]$r['ReceivedUtc']
                Store   = if ($r.IsDBNull($r.GetOrdinal('StoreKind'))) { 'unknown' } else { [string]$r['StoreKind'] }
            })
        }
        $r.Close()
    } finally { $conn.Dispose() }
    Ok "$($rows.Count) announcement row(s) matched"
    if ($rows.Count -eq 0) { throw "Nothing matched '$SubjectLike'. Load the index first with Import-ArchiveSearchToSql.ps1." }

    # ── Extract names ─────────────────────────────────────────────────────────
    Step '3. Extract new-hire names'
    # Subjects appear as "First Day at GI Partners", "... : Name" and "... - Name".
    # Anything after the separator is the name; no separator means the name was
    # only in the body, which this index deliberately does not store.
    $named = [System.Collections.Generic.List[object]]::new()
    $unnamed = 0
    foreach ($row in $rows) {
        $s = ($row.Subject -replace '\s+', ' ').Trim()
        if ($s -match '(?i)^First Day at GI Partners\s*[:\-\u2013\u2014]\s*(.+)$') {
            $name = $matches[1].Trim(' .!-')
            # Drop trailing artefacts that are not part of a person's name.
            $name = ($name -replace '(?i)\s*[\(\[].*$', '').Trim()
            if ($name -and $name.Length -le 60 -and $name -notmatch '\d{3}') {
                [void]$named.Add([PSCustomObject]@{ Name = $name; Received = $row.Received; Sender = $row.Sender; Store = $row.Store })
                continue
            }
        }
        $unnamed++
    }
    # One row per person: earliest announcement wins (later ones are re-sends).
    $roster = $named | Group-Object { $_.Name.ToLower() } | ForEach-Object {
        $first = $_.Group | Sort-Object Received | Select-Object -First 1
        [PSCustomObject]@{ Name = $first.Name; Received = $first.Received; Sender = $first.Sender; Store = $first.Store; Mentions = $_.Count }
    } | Sort-Object Received -Descending
    Ok "$($roster.Count) distinct people named; $unnamed announcement(s) carried no name in the subject"

    # ── Render ────────────────────────────────────────────────────────────────
    Step '4. Render report'
    function E([string]$t) { [System.Net.WebUtility]::HtmlEncode($t) }

    $byYear = $roster | Group-Object { $_.Received.Year } | Sort-Object Name
    $maxYear = ($byYear | Measure-Object -Property Count -Maximum).Maximum
    $yearBars = ($byYear | ForEach-Object {
        $pct = if ($maxYear -gt 0) { [int](($_.Count / $maxYear) * 100) } else { 0 }
        "<div class=""bar-row""><span class=""yr"">$(E $_.Name)</span><span class=""track""><span class=""fill"" style=""width:$pct%""></span></span><span class=""ct"">$($_.Count)</span></div>"
    }) -join "`n"

    $rosterRows = ($roster | ForEach-Object {
        $store = if ($_.Store -eq 'ArchiveMailBox') { 'archive' } else { 'primary' }
        "<tr><td class=""nm"">$(E $_.Name)</td><td class=""dt"">$($_.Received.ToString('yyyy-MM-dd'))</td><td class=""sn"">$(E $_.Sender)</td><td><span class=""store $store"">$store</span></td></tr>"
    }) -join "`n"

    $senders = $roster | Group-Object Sender | Sort-Object Count -Descending | ForEach-Object {
        $span = $_.Group | Sort-Object Received
        $lo = $span[0].Received.ToString('MMM yyyy'); $hi = $span[-1].Received.ToString('MMM yyyy')
        "<div class=""chip""><div class=""cat"">$($_.Count) announcement$(if($_.Count -ne 1){'s'})</div><div class=""nm"">$(E $_.Name)</div><div class=""rl"">$lo &ndash; $hi</div></div>"
    }
    $senderChips = $senders -join "`n"

    $first = ($roster | Sort-Object Received | Select-Object -First 1)
    $last  = ($roster | Sort-Object Received | Select-Object -Last 1)
    $archiveCount = @($roster | Where-Object { $_.Store -eq 'ArchiveMailBox' }).Count
    $primaryCount = $roster.Count - $archiveCount

    $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Welcome to GI Partners - New Hire Announcements</title>
</head>
<body>
<style>
  :root{
    --ground:#F5F7F8; --surface:#FFFFFF; --ink:#182029; --muted:#586474;
    --line:#E4E8ED; --accent:#0F625E; --accent-soft:#E5F0EF;
    --good:#2E7D57; --good-soft:#E6F1EA; --good-ink:#1F5D40; --chip:#FBFCFD;
    --shadow:0 1px 2px rgba(24,32,41,.04), 0 8px 24px rgba(24,32,41,.06);
    --serif:Georgia,"Iowan Old Style","Times New Roman",serif;
    --sans:system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    --mono:"SFMono-Regular",Consolas,"Liberation Mono",Menlo,monospace;
  }
  @media (prefers-color-scheme:dark){
    :root:not([data-theme="light"]){
      --ground:#0D1316; --surface:#141B1F; --ink:#EAF0F2; --muted:#9AA7B2;
      --line:#233138; --accent:#54CFC5; --accent-soft:#102E2C;
      --good:#5BC28C; --good-soft:#14291F; --good-ink:#7FD4A5; --chip:#101619;
      --shadow:0 1px 2px rgba(0,0,0,.3), 0 10px 30px rgba(0,0,0,.35);
    }
  }
  :root[data-theme="dark"]{
    --ground:#0D1316; --surface:#141B1F; --ink:#EAF0F2; --muted:#9AA7B2;
    --line:#233138; --accent:#54CFC5; --accent-soft:#102E2C;
    --good:#5BC28C; --good-soft:#14291F; --good-ink:#7FD4A5; --chip:#101619;
    --shadow:0 1px 2px rgba(0,0,0,.3), 0 10px 30px rgba(0,0,0,.35);
  }
  *{box-sizing:border-box}
  body{margin:0}
  .wrap{font-family:var(--sans); background:var(--ground); color:var(--ink);
    line-height:1.5; -webkit-font-smoothing:antialiased; min-height:100vh; padding:clamp(20px,4vw,56px) 16px;}
  .sheet{max-width:960px; margin:0 auto; background:var(--surface); border:1px solid var(--line);
    border-radius:14px; box-shadow:var(--shadow); padding:clamp(24px,4vw,52px);}
  .eyebrow{font-size:.72rem; letter-spacing:.14em; text-transform:uppercase; color:var(--accent); font-weight:600; margin:0 0 12px;}
  h1{font-family:var(--serif); font-weight:600; font-size:clamp(1.7rem,4vw,2.5rem); line-height:1.1; margin:0 0 10px; letter-spacing:-.01em;}
  .thesis{font-size:clamp(1rem,2vw,1.12rem); color:var(--muted); margin:0; max-width:64ch;}
  .meta{display:flex; flex-wrap:wrap; gap:8px 18px; margin-top:18px; font-size:.8rem; color:var(--muted); font-variant-numeric:tabular-nums;}
  .meta span{display:inline-flex; align-items:center; gap:7px}
  .dot{width:6px;height:6px;border-radius:50%;background:var(--accent);display:inline-block}
  .rule{height:1px;background:var(--line);border:0;margin:28px 0}
  .stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin:0 0 26px}
  .stat{background:var(--accent-soft);border:1px solid color-mix(in srgb,var(--accent) 28%,transparent);border-radius:11px;padding:14px 16px}
  .stat .v{font-family:var(--serif);font-size:1.9rem;line-height:1;color:var(--ink);font-variant-numeric:tabular-nums}
  .stat .k{font-size:.72rem;letter-spacing:.08em;text-transform:uppercase;color:var(--accent);font-weight:700;margin-top:6px}
  .section-label{font-size:.74rem;letter-spacing:.13em;text-transform:uppercase;color:var(--muted);font-weight:600;margin:30px 0 14px}
  .bar-row{display:flex;align-items:center;gap:12px;margin-bottom:9px;font-variant-numeric:tabular-nums}
  .bar-row .yr{width:3.4em;font-size:.85rem;color:var(--muted);font-weight:600}
  .bar-row .track{flex:1;height:22px;background:var(--chip);border:1px solid var(--line);border-radius:6px;overflow:hidden}
  .bar-row .fill{display:block;height:100%;background:var(--accent);opacity:.85}
  .bar-row .ct{width:2.2em;text-align:right;font-size:.85rem;color:var(--ink);font-weight:600}
  table{width:100%;border-collapse:collapse;font-size:.9rem}
  thead th{text-align:left;font-size:.68rem;letter-spacing:.09em;text-transform:uppercase;color:var(--muted);font-weight:700;padding:0 10px 9px;border-bottom:1px solid var(--line)}
  tbody td{padding:9px 10px;border-bottom:1px solid var(--line);vertical-align:middle}
  tbody tr:hover{background:var(--chip)}
  td.nm{font-weight:600;color:var(--ink)}
  td.dt{font-variant-numeric:tabular-nums;color:var(--muted);white-space:nowrap}
  td.sn{font-family:var(--mono);font-size:.78rem;color:var(--muted);word-break:break-word}
  .store{font-size:.63rem;letter-spacing:.05em;text-transform:uppercase;font-weight:700;border-radius:100px;padding:2px 8px;white-space:nowrap}
  .store.archive{color:var(--accent);background:var(--accent-soft);border:1px solid color-mix(in srgb,var(--accent) 26%,transparent)}
  .store.primary{color:var(--good-ink);background:var(--good-soft);border:1px solid color-mix(in srgb,var(--good) 26%,transparent)}
  .tablewrap{overflow-x:auto}
  .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(232px,1fr));gap:12px}
  .chip{background:var(--chip);border:1px solid var(--line);border-radius:11px;padding:13px 14px}
  .chip .cat{font-size:.63rem;letter-spacing:.09em;text-transform:uppercase;color:var(--muted);font-weight:700}
  .chip .nm{font-family:var(--mono);font-size:.8rem;color:var(--ink);margin:4px 0 5px;word-break:break-word}
  .chip .rl{font-size:.82rem;color:var(--muted)}
  footer{margin-top:32px;padding-top:16px;border-top:1px solid var(--line);font-size:.76rem;color:var(--muted)}
  footer code{font-family:var(--mono);font-size:.9em;color:var(--ink)}
  @media print{.wrap{background:#fff;padding:0}.sheet{box-shadow:none;border:none;max-width:none}}
/* theme-toggle:start */
  .theme-toggle{position:fixed;top:14px;right:14px;z-index:50;width:38px;height:38px;border-radius:50%;
    border:1px solid var(--line);background:var(--surface);color:var(--muted);cursor:pointer;
    box-shadow:var(--shadow);display:grid;place-items:center;font-size:.95rem;line-height:1;padding:0}
  .theme-toggle:hover{border-color:var(--accent);color:var(--accent)}
  .theme-toggle:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
  .theme-toggle .ti-moon{display:none}
  :root[data-theme="dark"] .theme-toggle .ti-moon{display:inline}
  :root[data-theme="dark"] .theme-toggle .ti-sun{display:none}
  @media (prefers-color-scheme:dark){
    :root:not([data-theme="light"]) .theme-toggle .ti-moon{display:inline}
    :root:not([data-theme="light"]) .theme-toggle .ti-sun{display:none}
  }
  @media print{.theme-toggle{display:none}}
/* theme-toggle:end */
</style>
<div class="wrap">
  <article class="sheet">
    <p class="eyebrow">People &amp; Culture &middot; Archive Report</p>
    <h1>Welcome to GI Partners</h1>
    <p class="thesis">Every new-hire announcement we can account for, reconstructed from the email archive. Names come from the announcement subject line; the report says plainly how many could not be named that way.</p>
    <div class="meta">
      <span><i class="dot"></i>$($first.Received.ToString('MMMM yyyy')) &ndash; $($last.Received.ToString('MMMM yyyy'))</span>
      <span>Generated $(Get-Date -Format 'd MMM yyyy')</span>
      <span>Source: ArchiveIndex</span>
    </div>

    <hr class="rule"/>

    <div class="stats">
      <div class="stat"><div class="v">$($roster.Count)</div><div class="k">People named</div></div>
      <div class="stat"><div class="v">$($rows.Count)</div><div class="k">Announcements</div></div>
      <div class="stat"><div class="v">$($byYear.Count)</div><div class="k">Years covered</div></div>
      <div class="stat"><div class="v">$unnamed</div><div class="k">Unnamed in subject</div></div>
    </div>

    <p class="section-label">Arrivals by year</p>
    $yearBars

    <p class="section-label">The roster &mdash; newest first</p>
    <div class="tablewrap">
      <table>
        <thead><tr><th>Name</th><th>Announced</th><th>Sent by</th><th>Found in</th></tr></thead>
        <tbody>
$rosterRows
        </tbody>
      </table>
    </div>

    <p class="section-label">Who sent the announcements</p>
    <div class="grid">
$senderChips
    </div>

    <footer>
      Built from <code>archive.vMessageSignal</code> &mdash; the noise-filtered view of the archive index, which holds message <strong>metadata only</strong> (subject, sender, date, folder), never message bodies or attachments.
      $archiveCount of these announcements survive only in the In-Place Archive; $primaryCount are still in the primary mailbox.
      $unnamed announcement$(if($unnamed -ne 1){'s'}) carried no name in the subject line &mdash; those names live in the message body, which this index deliberately does not store, so they are counted but not listed.
      Regenerate with <code>New-WelcomeToGipReport.ps1</code>.
    </footer>
  </article>
</div>
<!-- theme-toggle:start -->
<button class="theme-toggle" type="button" aria-label="Toggle dark mode" title="Toggle light / dark"><span class="ti-sun">&#9788;</span><span class="ti-moon">&#9789;</span></button>
<script>
(function(){
  var KEY='gip-theme', root=document.documentElement;
  try{ var saved=localStorage.getItem(KEY); if(saved){ root.setAttribute('data-theme',saved); } }catch(e){}
  var btn=document.querySelector('.theme-toggle');
  if(!btn){ return; }
  btn.addEventListener('click',function(){
    var sysDark=window.matchMedia&&window.matchMedia('(prefers-color-scheme:dark)').matches;
    var current=root.getAttribute('data-theme')||(sysDark?'dark':'light');
    var next=current==='dark'?'light':'dark';
    root.setAttribute('data-theme',next);
    try{ localStorage.setItem(KEY,next); }catch(e){}
  });
})();
</script>
<!-- theme-toggle:end -->
</body>
</html>
"@

    $outDir = Split-Path -Parent $OutFile
    if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    Set-Content -LiteralPath $OutFile -Value $html -Encoding utf8
    $resolved = (Resolve-Path $OutFile).Path
    Ok "report written: $resolved"
    Info "roster: $($roster.Count) people, $($rows.Count) announcements, $unnamed unnamed"
    Write-Host "`nOpen it:  $resolved" -ForegroundColor Cyan
}
catch {
    # sweep:error-logging -- a terminating error propagates PAST finally, so without this
    # it prints to the console only after Stop-Transcript has run and the log
    # ends with no reason recorded. Log it, then rethrow.
    Write-Host "  [!!] unhandled error: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo) { Write-Host "       at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" -ForegroundColor DarkGray }
    throw
}
finally {
    Write-Host "`nLog saved to: $script:LogPath" -ForegroundColor Cyan
    Stop-Transcript | Out-Null
}
