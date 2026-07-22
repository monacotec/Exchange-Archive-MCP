# Version: 1.0.0
# register-dev.ps1 — register (or remove) the giparchive: protocol handler under
# HKCU for LOCAL DEVELOPMENT/TESTING on this machine only. Production registration
# is done by the Intune package (D3), not this script.
#
# Per-user (HKCU) so it needs no admin and runs the handler in your session (COM
# to your running Outlook). Run in either PowerShell edition.

param(
    [string]$ExePath = (Join-Path $PSScriptRoot 'dist\ArchiveOpen.exe'),
    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'
$root = 'HKCU:\Software\Classes\giparchive'

if ($Unregister) {
    if (Test-Path $root) { Remove-Item $root -Recurse -Force; Write-Host 'Unregistered giparchive:.' -ForegroundColor Green }
    else { Write-Host 'giparchive: was not registered.' -ForegroundColor DarkGray }
    return
}

if (-not (Test-Path $ExePath)) { throw "Handler exe not found: $ExePath  (run build.ps1 first)" }
$ExePath = (Resolve-Path $ExePath).Path

New-Item -Path $root -Force | Out-Null
New-ItemProperty -Path $root -Name '(default)' -Value 'URL:GIP Archive Open' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $root -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null

$cmdKey = Join-Path $root 'shell\open\command'
New-Item -Path $cmdKey -Force | Out-Null
# %1 = the full giparchive: URI. Quoted so it is passed as a single argument.
New-ItemProperty -Path $cmdKey -Name '(default)' -Value ('"{0}" "%1"' -f $ExePath) -PropertyType String -Force | Out-Null

Write-Host "Registered giparchive: -> $ExePath" -ForegroundColor Green
Write-Host 'Test with:' -ForegroundColor Cyan
Write-Host '  Start-Process ''giparchive:v1?mid=%3CBY5PR04MB7076EC79A15D313B9EBA12D2C7F59@BY5PR04MB7076.namprd04.prod.outlook.com%3E''' -ForegroundColor DarkGray
Write-Host '(That is the D0 known-good Message-ID, url-encoded. Outlook should open it.)' -ForegroundColor DarkGray
