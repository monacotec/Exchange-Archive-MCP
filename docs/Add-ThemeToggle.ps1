#Requires -Version 7.0
<#
.SYNOPSIS
    Add (or refresh) the dark-mode toggle in the HTML reports.

.DESCRIPTION
    The reports already theme themselves from the reader's OS setting. This adds
    an explicit control so a reader can override it, persisted in localStorage
    so the choice survives a reload.

    Idempotent: re-running replaces the existing block rather than stacking
    copies, so it is safe to run after editing a report.

.EXAMPLE
    .\Add-ThemeToggle.ps1
.EXAMPLE
    .\Add-ThemeToggle.ps1 -Path .\welcome-to-gip.html
#>
[CmdletBinding()]
param([string[]]$Path)

$version = '1.0.0'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$MARK_CSS_A = '/* theme-toggle:start */'
$MARK_CSS_B = '/* theme-toggle:end */'
$MARK_HTML_A = '<!-- theme-toggle:start -->'
$MARK_HTML_B = '<!-- theme-toggle:end -->'

$css = @"
$MARK_CSS_A
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
$MARK_CSS_B
"@

$markup = @"
$MARK_HTML_A
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
$MARK_HTML_B
"@

if (-not $Path) {
    $Path = Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.html | Select-Object -ExpandProperty FullName
}

$changed = 0
foreach ($file in $Path) {
    $full = (Resolve-Path $file).Path
    $html = Get-Content -LiteralPath $full -Raw

    # Strip any previous block so re-runs replace rather than duplicate.
    $html = [regex]::Replace($html, [regex]::Escape($MARK_CSS_A) + '.*?' + [regex]::Escape($MARK_CSS_B), '', 'Singleline')
    $html = [regex]::Replace($html, [regex]::Escape($MARK_HTML_A) + '.*?' + [regex]::Escape($MARK_HTML_B), '', 'Singleline')

    $styleAt = $html.LastIndexOf('</style>')
    if ($styleAt -lt 0) { Write-Host "  [skip] $([System.IO.Path]::GetFileName($full)) - no <style> block" -ForegroundColor Yellow; continue }

    # String.Insert, not -replace: -replace takes no count argument, and a
    # replacement string would also reinterpret any $ in the CSS/JS.
    $html = $html.Insert($styleAt, "$css`n")

    # Some of these documents are FRAGMENTS rendered inside a host page (no
    # </body>), so append at the end when there is no body to close. Either way
    # the button precedes the script that wires it up.
    $bodyAt = $html.LastIndexOf('</body>')
    if ($bodyAt -ge 0) { $html = $html.Insert($bodyAt, "$markup`n") }
    else { $html = $html.TrimEnd() + "`n$markup`n" }

    $html = [regex]::Replace($html, '(\r?\n){3,}', "`n`n")

    Set-Content -LiteralPath $full -Value $html -Encoding utf8
    Write-Host "  [ok] $([System.IO.Path]::GetFileName($full))" -ForegroundColor Green
    $changed++
}
Write-Host "theme toggle applied to $changed file(s)" -ForegroundColor Cyan
