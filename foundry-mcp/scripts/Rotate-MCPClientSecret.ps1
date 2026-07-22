#Requires -Version 7.0
# Rev 2026-07-02: session teardown moved to try/finally (finding 46); -RevokeOld switch added (finding 47).
<#
.SYNOPSIS
    Rotates the Entra ID client secret for the Exchange Online Archive MCP app registration.

.DESCRIPTION
    Adds a new client secret to the MCP app registration, stores it in Key Vault,
    then removes all but the two most recent secrets. After rotation, the MCP server
    (Azure Function App) must be restarted to pick up the new secret from Key Vault.

    NEVER logs or echoes the secret value.

.PARAMETER AppObjectId
    Object ID of the MCP Entra ID app registration (NOT the client/application ID).

.PARAMETER KeyVaultName
    Key Vault where the new secret is stored as 'mcp-exchange-client-secret'.

.PARAMETER RevokeOld
    Removes ALL secrets except the newest. Run this AFTER the Function App has
    restarted and confirmed pickup of the new secret. Without this switch the
    script keeps the two newest secrets for zero-downtime overlap — but note the
    retiring secret stays live until you revoke it (finding 47); Graph does not
    permit shortening an existing passwordCredential's EndDateTime, so explicit
    revocation is the mechanism for closing the overlap window.

.EXAMPLE
    # Rotate (keeps previous secret live for overlap)
    .\Rotate-MCPClientSecret.ps1 -AppObjectId '<object-id>' -KeyVaultName 'kv-gipartners-ai-prod'

.EXAMPLE
    # After the Function App restart is verified: close the overlap window
    .\Rotate-MCPClientSecret.ps1 -AppObjectId '<object-id>' -KeyVaultName 'kv-gipartners-ai-prod' -RevokeOld
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $AppObjectId,
    [Parameter(Mandatory)] [string] $KeyVaultName,
    [switch] $RevokeOld
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Verify Graph SDK module is available ─────────────────────────────────────
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Applications)) {
    throw "Microsoft.Graph.Applications module not found. Run: Install-Module Microsoft.Graph -Scope CurrentUser"
}

# ── Connect to Graph ─────────────────────────────────────────────────────────
Write-Host 'Connecting to Microsoft Graph...' -ForegroundColor Cyan
Connect-MgGraph -Scopes 'Application.ReadWrite.All' -NoWelcome

try {

    # ── Step 1: Add new secret (skipped in -RevokeOld mode) ──────────────────────
    $displayName = "MCP-Secret-$(Get-Date -Format 'yyyy-MM')"
    if (-not $RevokeOld) {
        Write-Host "Adding new secret '$displayName'..." -ForegroundColor Yellow
    }

    if (-not $RevokeOld -and $PSCmdlet.ShouldProcess($AppObjectId, "Add new client secret '$displayName'")) {
        $newSecret = Add-MgApplicationPassword -ApplicationId $AppObjectId -PasswordCredential @{
            DisplayName = $displayName
            EndDateTime = (Get-Date).AddYears(1)
        }

        # ── Step 2: Store in Key Vault immediately — never echo the value ─────────
        Write-Host "Storing new secret in Key Vault '$KeyVaultName'..." -ForegroundColor Yellow
        Set-AzKeyVaultSecret `
            -VaultName $KeyVaultName `
            -Name 'mcp-exchange-client-secret' `
            -SecretValue (ConvertTo-SecureString $newSecret.SecretText -AsPlainText -Force) | Out-Null

        # Clear from memory
        $newSecret = $null

        Write-Host "New secret stored in Key Vault. Value NOT displayed." -ForegroundColor Green
    }

    # ── Step 3: Remove old secrets ────────────────────────────────────────────────
    # Default: keep the 2 newest (zero-downtime overlap during rotation).
    # -RevokeOld: keep ONLY the newest — closes the overlap window (finding 47).
    $keepCount = if ($RevokeOld) { 1 } else { 2 }
    Write-Host "Cleaning up old secrets (keeping $keepCount most recent)..." -ForegroundColor Cyan

    $allSecrets = (Get-MgApplication -ApplicationId $AppObjectId).PasswordCredentials |
        Sort-Object EndDateTime -Descending

    $toRemove = $allSecrets | Select-Object -Skip $keepCount

    if ($toRemove) {
        foreach ($old in $toRemove) {
            if ($PSCmdlet.ShouldProcess($old.DisplayName, 'Remove expired client secret')) {
                Remove-MgApplicationPassword -ApplicationId $AppObjectId -KeyId $old.KeyId
                Write-Host "  Removed: $($old.DisplayName) (expired $($old.EndDateTime.ToString('yyyy-MM-dd')))" -ForegroundColor Yellow
            }
        }
    } else {
        Write-Host '  No old secrets to remove.' -ForegroundColor Green
    }

    Write-Host "`n[DONE] Secret rotation complete." -ForegroundColor Green
    Write-Host "       Restart the Exchange MCP Azure Function App to pick up the new secret."
    Write-Host "       Key Vault: $KeyVaultName  |  Secret: mcp-exchange-client-secret`n"
    if (-not $RevokeOld) {
        Write-Host "       Once pickup is confirmed, re-run with -RevokeOld to retire the previous secret." -ForegroundColor Yellow
    }
}
finally {
    # Findings 45/46 (remediated 2026-07-02): guaranteed disconnect even when
    # $ErrorActionPreference='Stop' throws mid-run (per gi-foundry CLAUDE.md rule).
    if (Get-MgContext) {
        Disconnect-MgGraph | Out-Null
        Write-Host 'Disconnected from Microsoft Graph.' -ForegroundColor DarkGray
    }
}
