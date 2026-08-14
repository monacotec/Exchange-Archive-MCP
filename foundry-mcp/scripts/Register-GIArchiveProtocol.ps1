#Requires -Version 5.1
<#
.SYNOPSIS
    Registers the giparchive: URL protocol handler.

.DESCRIPTION
    By default, registers giparchive: to invoke Open-ArchiveMessage.ps1, which
    searches EVERY folder in EVERY Outlook store (primary mailbox + Online
    Archive) by Internet Message-ID and always opens the result in classic
    Outlook. This replaces the earlier archiveopen.exe-based registration,
    which only resolves messages that are physically in the Online Archive
    folder and fails (with a "not found, use webmail" prompt) for anything
    still in Inbox/Sent/Deleted Items/Calendar/etc.

    Pass -HandlerType ArchiveOpenExe to register the old archiveopen.exe
    behavior instead, if you want to keep using that binary directly.

    Per-user (HKCU) registration is used so no elevation is required. Use
    -Scope Machine to register under HKLM/HKCR instead (requires an elevated
    session); PDQ Deploy can run this with -Scope Machine -Force for
    fleet-wide rollout.

.PARAMETER HandlerType
    'PowerShellAllFolders' (default) - registers Open-ArchiveMessage.ps1,
        which searches all folders/stores and always opens in classic Outlook.
    'ArchiveOpenExe' - registers the original archiveopen.exe path (Online
        Archive folder only).

.PARAMETER ScriptPath
    Path to Open-ArchiveMessage.ps1. Only used when -HandlerType
    PowerShellAllFolders. Defaults to C:\GI\Open-ArchiveMessage.ps1.

.PARAMETER ExePath
    Path to archiveopen.exe. Only used when -HandlerType ArchiveOpenExe.
    Defaults to C:\GI\archiveopen.exe.

.PARAMETER Scope
    'User' (default, HKCU, no elevation needed) or 'Machine' (HKLM/HKCR,
    needs admin).

.PARAMETER Force
    Overwrite an existing giparchive registration without prompting.

.EXAMPLE
    .\Register-GIArchiveProtocol.ps1 -WhatIf

.EXAMPLE
    .\Register-GIArchiveProtocol.ps1 -Force

.EXAMPLE
    .\Register-GIArchiveProtocol.ps1 -HandlerType ArchiveOpenExe -Force

.EXAMPLE
    .\Register-GIArchiveProtocol.ps1 -Scope Machine -Force

.NOTES
    Version:    2.0.0
    Log path:   C:\GI\Logs\Register-GIArchiveProtocol_<timestamp>.log
    Compatible: PowerShell 5.1 and 7.x, PDQ Deploy
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('PowerShellAllFolders', 'ArchiveOpenExe')]
    [string]$HandlerType = 'PowerShellAllFolders',

    [string]$ScriptPath = 'C:\GI\Open-ArchiveMessage.ps1',

    [string]$ExePath = 'C:\GI\archiveopen.exe',

    [ValidateSet('User', 'Machine')]
    [string]$Scope = 'User',

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# --- Logging setup ---
$logDir = 'C:\GI\Logs'
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$logPath = Join-Path $logDir "Register-GIArchiveProtocol_$timestamp.log"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $logPath -Value $line -Encoding ASCII
}

Write-Log "Starting giparchive protocol registration. HandlerType=$HandlerType Scope=$Scope"

# --- Build the command line for the chosen handler type ---
if ($HandlerType -eq 'PowerShellAllFolders') {
    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        Write-Log "WARNING: $ScriptPath was not found on this machine. Registering anyway; links will fail until the file is present." 'WARN'
    }
    $pwshExe = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    $commandValue = '"' + $pwshExe + '" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '" "%1"'
}
else {
    if (-not (Test-Path -LiteralPath $ExePath)) {
        Write-Log "WARNING: $ExePath was not found on this machine. Registering anyway; links will fail until the file is present." 'WARN'
    }
    $commandValue = '"' + $ExePath + '" "%1"'
}

# --- Resolve registry root ---
switch ($Scope) {
    'User'    { $rootPath = 'HKCU:\Software\Classes\giparchive' }
    'Machine' { $rootPath = 'HKLM:\Software\Classes\giparchive' }
}

if ((Test-Path -LiteralPath $rootPath) -and -not $Force) {
    Write-Log "giparchive is already registered at $rootPath. Re-run with -Force to overwrite." 'WARN'
    return
}

if ($PSCmdlet.ShouldProcess($rootPath, "Register giparchive protocol -> $commandValue")) {
    try {
        # Root key
        New-Item -Path $rootPath -Force | Out-Null
        Set-ItemProperty -LiteralPath $rootPath -Name '(Default)' -Value 'URL:GI Archive Protocol'
        Set-ItemProperty -LiteralPath $rootPath -Name 'URL Protocol' -Value ''

        # shell\open\command
        $commandPath = Join-Path $rootPath 'shell\open\command'
        New-Item -Path $commandPath -Force | Out-Null
        Set-ItemProperty -LiteralPath $commandPath -Name '(Default)' -Value $commandValue

        Write-Log "Registered giparchive protocol under $rootPath"
        Write-Log "HandlerType: $HandlerType"
        Write-Log "Command: $commandValue"
        Write-Log "Registration complete."
    }
    catch {
        Write-Log "ERROR: $($_.Exception.Message)" 'ERROR'
        throw
    }
}
else {
    Write-Log "WhatIf: would register giparchive protocol under $rootPath with command: $commandValue"
}
