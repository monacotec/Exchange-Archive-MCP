<#
.SYNOPSIS
    Build the PDQ-deployable zip for exchange-archive-local.

.DESCRIPTION
    Produces packaging\dist\exchange-archive-local-<version>.zip containing:
        src\
        config\appsettings.example.json
        ExchangeArchiveMcp.psd1
        packaging\install.ps1
        packaging\uninstall.ps1
        packaging\README-PDQ.txt

    Layout matches what install.ps1 expects (it walks Split-Path $PSScriptRoot -Parent).
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path $PSScriptRoot -Parent
$manifest = Import-PowerShellDataFile (Join-Path $repoRoot 'ExchangeArchiveMcp.psd1')
$version  = $manifest.ModuleVersion
$distDir  = Join-Path $PSScriptRoot 'dist'
$stage    = Join-Path $distDir "_stage_$version"

if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage 'packaging') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage 'config') -Force | Out-Null

Copy-Item -Recurse (Join-Path $repoRoot 'src')                      (Join-Path $stage 'src')
Copy-Item          (Join-Path $repoRoot 'ExchangeArchiveMcp.psd1')  (Join-Path $stage 'ExchangeArchiveMcp.psd1')
Copy-Item          (Join-Path $repoRoot 'config\appsettings.example.json') (Join-Path $stage 'config\appsettings.example.json')
Copy-Item          (Join-Path $PSScriptRoot 'install.ps1')          (Join-Path $stage 'packaging\install.ps1')
Copy-Item          (Join-Path $PSScriptRoot 'uninstall.ps1')        (Join-Path $stage 'packaging\uninstall.ps1')

@"
exchange-archive-local $version
================================
PDQ deployment notes:

Step type:   PowerShell  (Run as: Logged-on user)
Command:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\install.ps1 -ClientId "<APP_REG_GUID>" -TenantId "gipartners.onmicrosoft.com"

Success codes: 0

Uninstall:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\packaging\uninstall.ps1

Detection (PDQ Inventory):
    File exists: %LOCALAPPDATA%\ExchangeArchiveMcp\install.marker.json
    Or registry equivalent if you front this with an MSIX wrapper later.

Footprint:
    %LOCALAPPDATA%\ExchangeArchiveMcp\app\           module payload
    %LOCALAPPDATA%\ExchangeArchiveMcp\config\        user config
    %LOCALAPPDATA%\ExchangeArchiveMcp\audit\         JSONL audit logs (retained on uninstall by default)
    %LOCALAPPDATA%\ExchangeArchiveMcp\outputs\       attachment downloads
    %APPDATA%\Claude\claude_desktop_config.json      MCP server entry merged in

Requires:
    - PowerShell 7+ (installed by installer via winget if missing)
    - Microsoft.Graph.Authentication module (installed by installer to CurrentUser scope)
    - Claude Desktop (separately deployed)
"@ | Set-Content -LiteralPath (Join-Path $stage 'packaging\README-PDQ.txt') -Encoding utf8

if (-not (Test-Path $distDir)) { New-Item -ItemType Directory $distDir | Out-Null }
$zipPath = Join-Path $distDir "exchange-archive-local-$version.zip"
if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath
Remove-Item -Recurse -Force $stage

Write-Host "Built $zipPath" -ForegroundColor Green
Get-Item $zipPath | Select-Object FullName, Length, LastWriteTime
