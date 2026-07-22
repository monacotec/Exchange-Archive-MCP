#Requires -Version 7.0
# Rev 2026-07-02: session teardown moved to try/finally (finding 44); -DisableWAM added per PS7 convention.
<#
.SYNOPSIS
    Creates an Exchange Online ApplicationAccessPolicy to restrict the MCP app to approved mailboxes.

.DESCRIPTION
    Scopes the MCP Entra app registration's Graph access to only mailboxes that are
    members of MCP-ArchiveAccess@gipartners.com. Prevents the app from reading any
    mailbox outside that group even if Graph permissions are broad.

    The MCP-ArchiveAccess mail-enabled security group must exist in Entra ID before
    running this script. Add users to the group to grant archive access.

.PARAMETER AppClientId
    Client ID (application ID) of the MCP Entra app registration.

.PARAMETER AdminUpn
    UPN of an Exchange Administrator account to authenticate with.

.PARAMETER TestMailbox
    UPN of a mailbox to verify the policy works after creation.

.EXAMPLE
    .\Set-ApplicationAccessPolicy.ps1 `
        -AppClientId '<client-id>' `
        -AdminUpn 'admin@gipartners.com' `
        -TestMailbox 'jsmith@gipartners.com'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $AppClientId,
    [Parameter(Mandatory)] [string] $AdminUpn,
    [string] $TestMailbox,
    [string] $PolicyGroupUpn = 'MCP-ArchiveAccess@gipartners.com'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Verify ExchangeOnlineManagement module ────────────────────────────────────
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    throw "ExchangeOnlineManagement module not found. Run: Install-Module ExchangeOnlineManagement"
}

# ── Connect to Exchange Online ────────────────────────────────────────────────
Write-Host "Connecting to Exchange Online as $AdminUpn..." -ForegroundColor Cyan
Connect-ExchangeOnline -UserPrincipalName $AdminUpn -ShowBanner:$false -DisableWAM  # -DisableWAM: PS7 convention

try {

    # ── Create ApplicationAccessPolicy ───────────────────────────────────────────
    Write-Host "Creating ApplicationAccessPolicy scoped to '$PolicyGroupUpn'..." -ForegroundColor Yellow

    if ($PSCmdlet.ShouldProcess($AppClientId, 'Create ApplicationAccessPolicy')) {
        New-ApplicationAccessPolicy `
            -AppId $AppClientId `
            -PolicyScopeGroupId $PolicyGroupUpn `
            -AccessRight RestrictAccess `
            -Description 'Restrict Exchange MCP app to approved archive mailboxes only'

        Write-Host "Policy created." -ForegroundColor Green
    }

    # ── Verify policy ─────────────────────────────────────────────────────────────
    if ($TestMailbox) {
        Write-Host "`nVerifying policy against test mailbox '$TestMailbox'..." -ForegroundColor Cyan
        $result = Test-ApplicationAccessPolicy -AppId $AppClientId -Identity $TestMailbox
        Write-Host "  Result: $($result.AccessCheckResult)" -ForegroundColor (
            if ($result.AccessCheckResult -eq 'Granted') { 'Green' } else { 'Red' }
        )

        if ($result.AccessCheckResult -ne 'Granted') {
            Write-Warning "Test mailbox returned '$($result.AccessCheckResult)'. Ensure '$TestMailbox' is a member of '$PolicyGroupUpn'."
        }
    }

    Write-Host "`n[DONE] ApplicationAccessPolicy configured." -ForegroundColor Green
    Write-Host "       Add mailboxes to '$PolicyGroupUpn' to grant archive access."
}
finally {
    # Finding 44 (remediated 2026-07-02): guaranteed disconnect even when
    # $ErrorActionPreference='Stop' throws mid-run (per gi-foundry CLAUDE.md rule).
    if (Get-ConnectionInformation) {
        Disconnect-ExchangeOnline -Confirm:$false
        Write-Host 'Disconnected from Exchange Online.' -ForegroundColor DarkGray
    }
}
