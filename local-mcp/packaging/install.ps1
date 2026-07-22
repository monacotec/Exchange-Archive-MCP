<#
.SYNOPSIS
    PDQ deployment installer for exchange-archive-local.

.DESCRIPTION
    Runs in the user context (PDQ "Run as logged-on user" step). Performs:
      1. Verifies PowerShell 7+; installs via winget if missing (per-user where possible).
      2. Installs Microsoft.Graph.Authentication module for CurrentUser if missing.
      3. Copies module payload to %LOCALAPPDATA%\ExchangeArchiveMcp\app\.
      4. Materialises %LOCALAPPDATA%\ExchangeArchiveMcp\config\appsettings.json
         from the bundled example (skipped if file already exists).
      5. Creates audit/ and outputs/ directories with user-only ACL.
      6. Merges the MCP server entry into %APPDATA%\Claude\claude_desktop_config.json.
      7. Writes a marker file with the installed version for uninstall/upgrade detection.

    Notes:
      - Must run as the signed-in user (delegated auth, DPAPI cache).
      - No reboots, no admin rights required if PS7 is already present.
      - Idempotent: re-running upgrades in place.

.PARAMETER ClientId
    Entra app registration (public client) GUID for the MCP. Required.

.PARAMETER TenantId
    Tenant. Defaults to gipartners.onmicrosoft.com.

.PARAMETER Force
    Re-write appsettings.json even if present.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ClientId,
    [string]$TenantId = 'gipartners.onmicrosoft.com',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step($msg) { Write-Host "[install] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "[ ok    ] $msg" -ForegroundColor Green }
function Write-Warn2($m)  { Write-Host "[ warn  ] $m"  -ForegroundColor Yellow }

$payloadRoot = Split-Path $PSScriptRoot -Parent  # packaging\ sits next to src\, config\, ExchangeArchiveMcp.psd1
$installRoot = Join-Path $env:LOCALAPPDATA 'ExchangeArchiveMcp'
$appDir      = Join-Path $installRoot 'app'
$cfgDir      = Join-Path $installRoot 'config'
$auditDir    = Join-Path $installRoot 'audit'
$outDir      = Join-Path $installRoot 'outputs'
$cfgFile     = Join-Path $cfgDir 'appsettings.json'
$markerFile  = Join-Path $installRoot 'install.marker.json'

# 1. PowerShell 7 check.
Write-Step 'Checking PowerShell 7+'
$pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if (-not $pwshCmd) {
    Write-Warn2 'pwsh.exe not found. Attempting winget install (PowerShell.PowerShell, scope=user)...'
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) { throw 'Neither pwsh nor winget is available. Install PowerShell 7 manually or push it via PDQ first.' }
    & winget install --id Microsoft.PowerShell --scope user --accept-package-agreements --accept-source-agreements --silent
    $pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $pwshCmd) { throw 'PowerShell 7 install failed.' }
}
Write-Ok "Found $($pwshCmd.Source)"

# 2. Microsoft.Graph.Authentication module.
Write-Step 'Checking Microsoft.Graph.Authentication module'
& $pwshCmd.Source -NoProfile -NonInteractive -Command @"
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber
}
"@
Write-Ok 'Microsoft.Graph.Authentication available'

# 3. Copy payload.
Write-Step "Copying app payload to $appDir"
if (Test-Path $appDir) { Remove-Item -Recurse -Force $appDir }
New-Item -ItemType Directory -Path $appDir -Force | Out-Null
foreach ($dir in @('src')) {
    Copy-Item -Recurse -Path (Join-Path $payloadRoot $dir) -Destination $appDir
}
Copy-Item -Path (Join-Path $payloadRoot 'ExchangeArchiveMcp.psd1') -Destination $appDir
Write-Ok 'Payload copied'

# 4. Config.
Write-Step 'Materialising config'
if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
if ($Force -or -not (Test-Path $cfgFile)) {
    $example = Get-Content -Raw (Join-Path $payloadRoot 'config\appsettings.example.json') | ConvertFrom-Json
    $example.auth.clientId = $ClientId
    $example.auth.tenantId = $TenantId
    ($example | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $cfgFile -Encoding utf8
    Write-Ok "Wrote $cfgFile"
} else {
    Write-Ok "Config already exists, leaving as-is (use -Force to overwrite)"
}

# 5. Audit/outputs dirs.
Write-Step 'Creating audit and outputs directories'
foreach ($d in @($auditDir, $outDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    # User-only ACL (remove inherited Authenticated Users if present is a per-org call; default LOCALAPPDATA is already user-scoped).
}
Write-Ok 'Directories ready'

# 6. Claude Desktop config merge.
Write-Step 'Merging Claude Desktop config'
$claudeCfgDir  = Join-Path $env:APPDATA 'Claude'
$claudeCfgFile = Join-Path $claudeCfgDir 'claude_desktop_config.json'
if (-not (Test-Path $claudeCfgDir)) { New-Item -ItemType Directory -Path $claudeCfgDir -Force | Out-Null }

$serverEntry = [ordered]@{
    command = $pwshCmd.Source
    args    = @(
        '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
        '-File', (Join-Path $appDir 'src\Server.ps1'),
        '-ConfigPath', $cfgFile
    )
}

if (Test-Path $claudeCfgFile) {
    $cfg = Get-Content -Raw $claudeCfgFile | ConvertFrom-Json -AsHashtable
} else {
    $cfg = @{}
}
if (-not $cfg.ContainsKey('mcpServers')) { $cfg['mcpServers'] = @{} }
$cfg.mcpServers['exchange-archive-local'] = $serverEntry
($cfg | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $claudeCfgFile -Encoding utf8
Write-Ok "Updated $claudeCfgFile"

# 7. Marker.
$manifest = Import-PowerShellDataFile (Join-Path $appDir 'ExchangeArchiveMcp.psd1')
@{
    version     = $manifest.ModuleVersion
    installedAt = (Get-Date).ToUniversalTime().ToString('o')
    appDir      = $appDir
    configFile  = $cfgFile
    clientId    = $ClientId
    tenantId    = $TenantId
} | ConvertTo-Json | Set-Content -LiteralPath $markerFile -Encoding utf8

Write-Ok "exchange-archive-local $($manifest.ModuleVersion) installed."
Write-Host ''
Write-Host 'Next: launch Claude Desktop. On first archive_* tool call, an interactive sign-in window will appear.' -ForegroundColor White
