# Version: 1.0.0
# Get-ArchiveConfig.ps1 — reads the mailbox archive configuration.
#
# RUN THIS IN WINDOWS POWERSHELL 5.1 ("powershell.exe", NOT pwsh):
#   the ExchangeOnlineManagement WAM broker crashes under PowerShell 7 on this
#   machine (NullReferenceException in RuntimeBroker, even with -DisableWAM).
#   Sign in as super-jmonaco@gipartners.com when the browser opens.
#
# Purpose: determine AutoExpandingArchiveEnabled for jmonaco@gipartners.com.
#   True  -> Graph's inability to address the Online Archive is the documented
#            auto-expanded-archive limitation; the MCP needs a non-Graph data
#            path (Purview/eDiscovery). No support ticket will change it.
#   False -> Graph SHOULD address this archive; the 404s are a defect worth a
#            Microsoft support case before any redesign.
#
# PS 5.1-compatible syntax throughout (no ternary, no null-coalescing).

param(
    [string]$Upn = 'jmonaco@gipartners.com'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    throw 'ExchangeOnlineManagement module not installed. Run: Install-Module ExchangeOnlineManagement -Scope CurrentUser'
}

Import-Module ExchangeOnlineManagement

try {
    Connect-ExchangeOnline -ShowBanner:$false

    Write-Host "`n=== Mailbox archive configuration: $Upn ===" -ForegroundColor Cyan
    Get-Mailbox -Identity $Upn |
        Select-Object DisplayName, ArchiveStatus, ArchiveState, ArchiveGuid,
                      AutoExpandingArchiveEnabled, ArchiveQuota, ArchiveWarningQuota,
                      ArchiveDatabase |
        Format-List

    Write-Host '=== Org-level setting ===' -ForegroundColor Cyan
    Get-OrganizationConfig | Select-Object AutoExpandingArchiveEnabled | Format-List

    Write-Host '=== Mailbox locations (aux archives appear here if auto-expanded) ===' -ForegroundColor Cyan
    try {
        Get-MailboxLocation -User $Upn |
            Select-Object MailboxLocationType, MailboxGuid, DatabaseLocation |
            Format-Table -AutoSize
    }
    catch {
        Write-Host "  Get-MailboxLocation unavailable: $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}
finally {
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}

Write-Host "`nPaste the output back to Claude." -ForegroundColor Cyan
