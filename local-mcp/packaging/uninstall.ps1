<#
.SYNOPSIS
    Removes exchange-archive-local from the current user profile.

.DESCRIPTION
    - Removes the MCP server entry from claude_desktop_config.json (preserves others).
    - Deletes app payload, config, and token cache.
    - KEEPS audit logs by default (compliance). Pass -PurgeAudit to delete them too.
#>
[CmdletBinding()]
param(
    [switch]$PurgeAudit,
    [switch]$PurgeOutputs
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$installRoot = Join-Path $env:LOCALAPPDATA 'ExchangeArchiveMcp'

Write-Host '[uninstall] Removing Claude Desktop MCP entry...' -ForegroundColor Cyan
$claudeCfgFile = Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'
if (Test-Path $claudeCfgFile) {
    $cfg = Get-Content -Raw $claudeCfgFile | ConvertFrom-Json -AsHashtable
    if ($cfg.ContainsKey('mcpServers') -and $cfg.mcpServers.ContainsKey('exchange-archive-local')) {
        $cfg.mcpServers.Remove('exchange-archive-local')
        ($cfg | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $claudeCfgFile -Encoding utf8
        Write-Host '  removed entry'
    }
}

Write-Host '[uninstall] Removing app + token cache...' -ForegroundColor Cyan
foreach ($p in @('app','config','msal.cache.bin','hmac.key.bin','install.marker.json')) {
    $full = Join-Path $installRoot $p
    if (Test-Path $full) { Remove-Item -Recurse -Force $full }
}

if ($PurgeAudit) {
    $a = Join-Path $installRoot 'audit'
    if (Test-Path $a) { Remove-Item -Recurse -Force $a; Write-Host '  audit logs purged' }
}
if ($PurgeOutputs) {
    $o = Join-Path $installRoot 'outputs'
    if (Test-Path $o) { Remove-Item -Recurse -Force $o; Write-Host '  outputs purged' }
}

# Remove root if empty.
if ((Test-Path $installRoot) -and -not (Get-ChildItem $installRoot -Force)) {
    Remove-Item -Force $installRoot
}

Write-Host '[uninstall] Done.' -ForegroundColor Green
