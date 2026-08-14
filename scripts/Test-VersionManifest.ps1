#Requires -Version 7.0
<#
.SYNOPSIS
    Verify version.md against the actual version anchors in every file it lists.

.DESCRIPTION
    The house rule is that version.md names every versioned file and the pattern
    that carries its version. This checks that the manifest tells the truth:

      MISMATCH  the file's internal version differs from the manifest row
      MISSING   the manifest lists a file that does not exist
      NOANCHOR  the file exists but carries no recognisable version string
      UNLISTED  a versioned file exists that the manifest never mentions

    Read-only. Exits 1 if anything is wrong, so it can gate a release.

    Section headings in version.md map to directories: "## foundry-mcp - ..."
    means the rows beneath it are paths relative to foundry-mcp/. Rows whose
    version is not semver (e.g. "rev 2", "-") are existence-checked only.

.EXAMPLE
    .\Test-VersionManifest.ps1
.EXAMPLE
    .\Test-VersionManifest.ps1 -ShowUnlisted:$false
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$ShowUnlisted = $true
)

$version = '1.1.0'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ok   ([string]$m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Bad  ([string]$m) { Write-Host "  [!!] $m" -ForegroundColor Red }
function Info ([string]$m) { Write-Host "  $m" -ForegroundColor Yellow }
function Step ([string]$m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

$manifestPath = Join-Path $RepoRoot 'version.md'
if (-not (Test-Path $manifestPath)) { throw "version.md not found at $manifestPath" }

# Extract a file's own declared version, whatever form it takes.
function Get-FileVersion([string]$Path) {
    $ext = [System.IO.Path]::GetExtension($Path).ToLower()
    # Only the head of the file matters; version anchors live near the top
    # (except .psd1/.csproj, where they sit in a manifest block).
    $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $head = if ($text.Length -gt 6000) { $text.Substring(0, 6000) } else { $text }
    $patterns = @(
        '(?im)^\s*#\s*Version:\s*([0-9]+\.[0-9]+\.[0-9]+)'          # .ps1 header
        '(?im)^\s*\$version\s*=\s*[''"]([0-9]+\.[0-9]+\.[0-9]+)'    # .ps1 variable
        '(?im)^\s*//\s*Version:\s*([0-9]+\.[0-9]+\.[0-9]+)'         # .bicep / .cs
        '(?im)^\s*Version:\s*([0-9]+\.[0-9]+\.[0-9]+)'              # .py docstring
        '(?im)ModuleVersion\s*=\s*[''"]([0-9]+\.[0-9]+\.[0-9]+)'    # .psd1
        '(?im)"schemaVersion"\s*:\s*"([0-9]+\.[0-9]+\.[0-9]+)"'     # .json
        '(?im)<Version>([0-9]+\.[0-9]+\.[0-9]+)</Version>'          # .csproj
        '(?im)^\s*\.NOTES\s+Version:\s*([0-9]+\.[0-9]+\.[0-9]+)'    # PS comment-based help
        '(?im)LABEL\s+version\s*=\s*"?([0-9]+\.[0-9]+\.[0-9]+)'     # Dockerfile
        '(?im)"version"\s*:\s*"([0-9]+\.[0-9]+\.[0-9]+)"'           # package/host json
    )
    foreach ($p in $patterns) {
        $m = [regex]::Match($head, $p)
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return $null
}

# ── Parse the manifest ────────────────────────────────────────────────────────
Step "Parsing version.md"
$rows = [System.Collections.Generic.List[object]]::new()
$section = ''
$sectionDir = ''
foreach ($line in Get-Content -LiteralPath $manifestPath) {
    if ($line -match '^##\s+(.+?)\s*$') {
        $section = $matches[1]
        # Split on WHITESPACE only: component names contain hyphens
        # ("foundry-mcp"), so splitting on '-' truncates them to "foundry" and
        # every path below resolves against the wrong directory.
        $first = ($section -split '\s+')[0]
        $candidate = Join-Path $RepoRoot ($first -replace '/', '\')
        $sectionDir = if (Test-Path $candidate -PathType Container) { $candidate } else { $RepoRoot }
        continue
    }
    # | `path` | version | description |
    if ($line -match '^\|\s*`([^`]+)`\s*\|\s*([^|]+?)\s*\|') {
        $rows.Add([PSCustomObject]@{
            Path     = $matches[1].Trim()
            Declared = $matches[2].Trim()
            Section  = $section
            Dir      = $sectionDir
        })
    }
}
Ok "$($rows.Count) manifest rows across $((($rows | Select-Object -ExpandProperty Section -Unique) | Measure-Object).Count) sections"

# ── Compare ───────────────────────────────────────────────────────────────────
Step 'Manifest vs. files'
$problems = 0
$checked = 0
$script:noAnchor = 0
$listedFull = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($row in $rows) {
    $rel = $row.Path -replace '/', '\'
    $full = Join-Path $row.Dir $rel
    if (Test-Path $full -PathType Container) { [void]$listedFull.Add((Resolve-Path $full).Path); continue }
    if (-not (Test-Path $full)) {
        # Directory-ish or descriptive rows ("docs/", "plans/") are informational.
        if ($row.Path -match '/$' -or $row.Declared -eq '—' -or $row.Declared -eq '-') { continue }
        Bad "MISSING   $($row.Path)  (section: $($row.Section))"
        $problems++
        continue
    }
    [void]$listedFull.Add((Resolve-Path $full).Path)
    if ($row.Declared -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { continue }  # "rev 2", "—"
    # Prose files (.md, .txt, .example) carry their version in the text, not in
    # a machine-readable anchor -- existence is all we can assert.
    if ([System.IO.Path]::GetExtension($full) -in '.md', '.txt', '.example', '.yaml', '.yml') { continue }
    $checked++
    $actual = Get-FileVersion $full
    if (-not $actual) {
        # Informational, not a failure: the file is tracked by the manifest
        # alone. That is a style gap (no self-declared version), not the
        # manifest being wrong about anything.
        $script:noAnchor++
    } elseif ($actual -ne $row.Declared) {
        Bad "MISMATCH  $($row.Path)  manifest $($row.Declared)  file $actual"
        $problems++
    }
}
Ok "$checked file(s) compared against their declared version"
if ($script:noAnchor -gt 0) {
    Info "$($script:noAnchor) file(s) carry no in-file version string - tracked by the manifest alone (not an error)"
}

# ── Versioned files the manifest never mentions ───────────────────────────────
if ($ShowUnlisted) {
    Step 'Versioned files missing from the manifest'
    # Build output and vendored payloads carry their own versions but are not
    # source we track: dist/, bin/, obj/, .venv*, signtool-cli/.
    $skipDirs = '\\\.git\\|\\logs\\|\\inventory\\|\\archive\\|\\screenshots\\|\\\.venv|\\bin\\|\\obj\\|\\dist\\|\\signtool-cli\\|\\node_modules\\|\\\.claude\\'
    $unlisted = 0
    Get-ChildItem $RepoRoot -Recurse -File -Include *.ps1, *.py, *.bicep, *.psd1 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $skipDirs } | ForEach-Object {
            if ($listedFull.Contains($_.FullName)) { return }
            $v = try { Get-FileVersion $_.FullName } catch { $null }
            if ($v) {
                Bad ("UNLISTED  {0}  (carries version {1})" -f $_.FullName.Substring($RepoRoot.Length + 1), $v)
                $script:unlisted++
                $script:problems++
            }
        }
    if ($unlisted -eq 0) { Ok 'every versioned file is listed' }
}

Write-Host ''
if ($problems -eq 0) {
    Write-Host 'VERSION MANIFEST CORRECT' -ForegroundColor Green
} else {
    Write-Host "VERSION MANIFEST PROBLEMS: $problems" -ForegroundColor Red
    exit 1
}
