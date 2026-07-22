<#
.SYNOPSIS
    Deploy this repo's source to the locally-registered exchange-archive-local MCP runtime.

.DESCRIPTION
    This is the single source-of-truth step for the LOCAL dev -> runtime loop on a
    developer/operator machine, where the Claude Desktop MCP server entry
    "exchange-archive-local" launches from a fixed runtime directory (default
    C:\GI\MCP-Archive\src\Server.ps1) rather than from this repo directly.

    It does three things, in order, and refuses to deploy if step 1 fails:
      1. GATE: runs the full Pester suite (tests\Pester) with Pester 5. Any failure
         aborts the deploy -- broken code never reaches the runtime.
      2. MIRROR: copies the runtime payload (src\ + ExchangeArchiveMcp.psd1, and a
         refreshed config\appsettings.example.json) into -RuntimeRoot. The live
         config\appsettings.json is NEVER touched.
      3. VERIFY: re-hashes src\ + the manifest in both trees and asserts they are
         byte-identical, then reminds you to restart the MCP server.

    NOTE: This is distinct from packaging\install.ps1, which is the ORG-WIDE PDQ
    rollout (per-user %LOCALAPPDATA%\ExchangeArchiveMcp\app, server name
    "exchange-archive-local", but a different LOCATION). deploy-local.ps1 targets the hand-placed runtime that
    is actually registered on this machine. Both ultimately copy the same payload
    (src\ + manifest) produced from this repo.

.PARAMETER RuntimeRoot
    The directory the registered MCP server runs from. Default: C:\GI\MCP-Archive
    (matches the "exchange-archive-local" entry in %APPDATA%\Claude\claude_desktop_config.json).

.PARAMETER SkipTests
    Skip the Pester gate. Strongly discouraged; provided only for emergency hotfix
    flows where the suite is known-green from a prior run in the same session.

.EXAMPLE
    pwsh -NoProfile -File packaging\deploy-local.ps1
    # Runs tests, mirrors to C:\GI\MCP-Archive, verifies, then prompts you to restart.
#>
[CmdletBinding()]
param(
    [string]$RuntimeRoot = 'C:\GI\MCP-Archive',
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step($m) { Write-Host "[deploy] $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "[  ok  ] $m" -ForegroundColor Green }
function Write-Die($m)  { Write-Host "[ fail ] $m" -ForegroundColor Red }

$repoRoot = Split-Path $PSScriptRoot -Parent   # packaging\ sits next to src\, config\, the manifest

# The runtime payload: exactly what must exist under $RuntimeRoot for Server.ps1 to run.
# (Matches the payload set in build-pdq-package.ps1.)
$payloadDirs  = @('src')
$payloadFiles = @('ExchangeArchiveMcp.psd1')

# ---------------------------------------------------------------------------
# 1. GATE -- full Pester suite must pass.
# ---------------------------------------------------------------------------
if ($SkipTests) {
    Write-Host "[ warn ] -SkipTests set: deploying WITHOUT running the Pester gate." -ForegroundColor Yellow
} else {
    Write-Step 'Running Pester gate (tests\Pester)'
    Import-Module Pester -MinimumVersion 5.0.0 -ErrorAction Stop
    $cfg = New-PesterConfiguration
    $cfg.Run.Path        = (Join-Path $repoRoot 'tests\Pester')
    $cfg.Run.PassThru    = $true
    $cfg.Output.Verbosity = 'Normal'
    $result = Invoke-Pester -Configuration $cfg
    if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') {
        Write-Die "Pester gate failed ($($result.FailedCount) failed / $($result.TotalCount) total). Deploy aborted."
        exit 1
    }
    Write-Ok "Pester gate passed ($($result.PassedCount)/$($result.TotalCount))"
}

# ---------------------------------------------------------------------------
# 2. MIRROR -- copy payload into the runtime, preserving live config.
# ---------------------------------------------------------------------------
if (-not (Test-Path $RuntimeRoot)) {
    throw "RuntimeRoot '$RuntimeRoot' does not exist. Create it (and its config\appsettings.json) before first deploy, or pass -RuntimeRoot."
}

foreach ($dir in $payloadDirs) {
    $srcDir = Join-Path $repoRoot $dir
    $dstDir = Join-Path $RuntimeRoot $dir
    Write-Step "Mirroring $dir\ -> $dstDir"
    # PowerShell-native mirror (Copy-Item, not robocopy: robocopy's attribute/ACL
    # copy step intermittently returns ERROR 5 against this runtime path even when
    # plain writes succeed). Two passes: (a) copy/overwrite every source file,
    # (b) prune destination files and empty dirs that no longer exist in source.
    # src\ holds no runtime-generated state, so full mirror semantics are safe.
    Get-ChildItem -LiteralPath $srcDir -Recurse -File -Force | ForEach-Object {
        $rel    = $_.FullName.Substring($srcDir.Length).TrimStart('\')
        $target = Join-Path $dstDir $rel
        $tdir   = Split-Path $target -Parent
        if (-not (Test-Path $tdir)) { New-Item -ItemType Directory -Path $tdir -Force | Out-Null }
        Copy-Item -LiteralPath $_.FullName -Destination $target -Force
    }
    if (Test-Path $dstDir) {
        Get-ChildItem -LiteralPath $dstDir -Recurse -File -Force | ForEach-Object {
            $rel = $_.FullName.Substring($dstDir.Length).TrimStart('\')
            if (-not (Test-Path (Join-Path $srcDir $rel))) {
                Write-Host "[ prune ] $rel" -ForegroundColor DarkYellow
                Remove-Item -LiteralPath $_.FullName -Force
            }
        }
        Get-ChildItem -LiteralPath $dstDir -Recurse -Directory -Force |
            Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
                if (-not (Get-ChildItem -LiteralPath $_.FullName -Force)) { Remove-Item -LiteralPath $_.FullName -Force }
            }
    }
}

foreach ($file in $payloadFiles) {
    Write-Step "Copying $file"
    Copy-Item -LiteralPath (Join-Path $repoRoot $file) -Destination (Join-Path $RuntimeRoot $file) -Force
}

# Refresh the example config only (never the live appsettings.json).
$exampleSrc = Join-Path $repoRoot 'config\appsettings.example.json'
$exampleDst = Join-Path $RuntimeRoot 'config\appsettings.example.json'
if (Test-Path $exampleSrc) {
    if (-not (Test-Path (Split-Path $exampleDst -Parent))) { New-Item -ItemType Directory -Path (Split-Path $exampleDst -Parent) -Force | Out-Null }
    Copy-Item -LiteralPath $exampleSrc -Destination $exampleDst -Force
    Write-Ok 'Refreshed config\appsettings.example.json (live appsettings.json untouched)'
}

# ---------------------------------------------------------------------------
# 3. VERIFY -- payload in both trees must be byte-identical.
# ---------------------------------------------------------------------------
Write-Step 'Verifying runtime payload matches repo'
function Get-PayloadHashes($root) {
    $h = [ordered]@{}
    foreach ($dir in $payloadDirs) {
        Get-ChildItem (Join-Path $root $dir) -Recurse -File -Force | ForEach-Object {
            $rel = $_.FullName.Substring($root.Length).TrimStart('\')
            $h[$rel] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }
    }
    foreach ($file in $payloadFiles) {
        $h[$file] = (Get-FileHash -LiteralPath (Join-Path $root $file) -Algorithm SHA256).Hash
    }
    $h
}
$repoH = Get-PayloadHashes $repoRoot
$rtH   = Get-PayloadHashes $RuntimeRoot
$mismatch = @()
foreach ($k in ($repoH.Keys + $rtH.Keys | Sort-Object -Unique)) {
    if (-not $rtH.Contains($k))   { $mismatch += "missing in runtime: $k" }
    elseif (-not $repoH.Contains($k)) { $mismatch += "stale in runtime: $k" }
    elseif ($repoH[$k] -ne $rtH[$k])  { $mismatch += "differs: $k" }
}
if ($mismatch.Count -gt 0) {
    Write-Die "Payload verification FAILED:`n  $($mismatch -join "`n  ")"
    exit 2
}
Write-Ok "Runtime payload is identical to repo ($($repoH.Count) files)."

Write-Host ''
Write-Host 'Deploy complete. Restart the "exchange-archive-local" MCP server in Claude Desktop' -ForegroundColor White
Write-Host '(it dot-sources src\ at startup, so changes take effect only after a restart).' -ForegroundColor White
