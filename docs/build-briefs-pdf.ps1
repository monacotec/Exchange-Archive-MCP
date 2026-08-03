# Version: 1.0.0
# build-briefs-pdf.ps1 — bundle the two visual briefs into ONE PDF.
#
# Combines docs/leadership-brief.html + docs/azure-architecture.html into a
# single print-tuned standalone HTML (forced light theme, colors preserved,
# page break between), then renders it to PDF with headless Edge/Chrome
# (local, offline — no network). PS 5.1 or 7.
#
# Output: docs/Exchange-Archive-MCP-Briefs.pdf
# Fallback: if no headless browser is found, the combined HTML is still written
#           and you can open it and "Print -> Save as PDF".

param(
    [string]$DocsDir = $PSScriptRoot,
    [ValidateSet('Letter','A4')][string]$PageSize = 'Letter'
)

$ErrorActionPreference = 'Stop'
function Ok  ($t) { Write-Host "  [ok]   $t" -ForegroundColor Green }
function Info($t) { Write-Host "  [..]   $t" -ForegroundColor DarkGray }
function Warn($t) { Write-Host "  [warn] $t" -ForegroundColor Yellow }

$lead = Join-Path $DocsDir 'leadership-brief.html'
$arch = Join-Path $DocsDir 'azure-architecture.html'
foreach ($f in @($lead,$arch)) { if (-not (Test-Path $f)) { throw "Missing source: $f" } }

$combined = Join-Path $DocsDir 'briefs-combined.html'
$pdf      = Join-Path $DocsDir 'Exchange-Archive-MCP-Briefs.pdf'

# ── Assemble the combined print document ──────────────────────────────────────
Write-Host "`n=== 1. Assemble combined HTML ===" -ForegroundColor Cyan
$leadHtml = Get-Content $lead -Raw
$archHtml = Get-Content $arch -Raw

# Final print override (placed LAST so it wins): force light palette for the
# PDF regardless of OS theme, keep background colors, one page per brief.
$printCss = @"
<style>
  html,body{margin:0;padding:0;background:#fff}
  .page-break{break-before:page;page-break-before:always;height:0}
  @media print{
    @page{ size:$PageSize; margin:12mm }
    *{ -webkit-print-color-adjust:exact; print-color-adjust:exact }
    :root, :root[data-theme="dark"], :root[data-theme="light"]{
      --ground:#FFFFFF; --surface:#FFFFFF; --ink:#182029; --muted:#586474;
      --line:#E4E8ED; --accent:#0F625E; --accent-soft:#E5F0EF;
      --good:#2E7D57; --good-soft:#E6F1EA; --good-ink:#1F5D40; --chip:#FBFCFD;
      --shadow:none;
    }
    .brief,.wrap{ padding:0 !important; background:#fff !important; min-height:0 !important }
    .sheet{ box-shadow:none !important; border:none !important; border-radius:0 !important; max-width:none !important; padding:6mm 4mm !important }
    .anim,.reveal,.step{ opacity:1 !important; transform:none !important; animation:none !important }
  }
</style>
"@

$doc = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>Exchange Archive MCP - Briefs</title>
</head>
<body>
$leadHtml
<div class="page-break"></div>
$archHtml
$printCss
</body>
</html>
"@

Set-Content -Path $combined -Value $doc -Encoding utf8
Ok "combined -> $combined"

# ── Find a headless browser ───────────────────────────────────────────────────
Write-Host "`n=== 2. Locate headless browser ===" -ForegroundColor Cyan
$candidates = @(
    (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe')
)
$browser = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $browser) {
    foreach ($n in 'msedge','chrome') { $c = Get-Command $n -ErrorAction SilentlyContinue; if ($c) { $browser = $c.Source; break } }
}
if (-not $browser) {
    Warn 'No headless Edge/Chrome found.'
    Write-Host "  Combined HTML is ready: open it and use Print -> Save as PDF ($PageSize)." -ForegroundColor Yellow
    Write-Host "  $combined" -ForegroundColor Yellow
    return
}
Ok "using $browser"

# ── Render to PDF ─────────────────────────────────────────────────────────────
Write-Host "`n=== 3. Render PDF ===" -ForegroundColor Cyan
if (Test-Path $pdf) { Remove-Item $pdf -Force }
$fileUrl = 'file:///' + ($combined -replace '\\','/')
$outArg  = '--print-to-pdf=' + $pdf
& $browser '--headless=new' '--disable-gpu' '--no-pdf-header-footer' '--print-to-pdf-no-header' $outArg $fileUrl 2>$null

# Some builds need a moment to flush the file.
for ($i=0; $i -lt 10 -and -not (Test-Path $pdf); $i++) { Start-Sleep -Milliseconds 500 }

if (Test-Path $pdf) {
    $kb = [math]::Round((Get-Item $pdf).Length / 1KB, 1)
    Ok "PDF written: $pdf ($kb KB)"
}
else {
    Warn 'Headless render did not produce a PDF (EDR may block headless Chromium).'
    Write-Host "  Fallback: open $combined and Print -> Save as PDF." -ForegroundColor Yellow
}
Write-Host ""
