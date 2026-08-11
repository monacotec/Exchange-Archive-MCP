#Requires -Version 7.0
# Rev 2026-07-02: session teardown moved to try/finally (finding 46); -RevokeOld switch added (finding 47).
# Rev 2026-08-11: AppObjectId/KeyVaultName now default to the Exchange Archive MCP
#   app + prod KV (run `-RevokeOld` bare to settle the secret-overlap audit finding).
#   Keep-selection made deterministic: both current secrets share one expiry date,
#   so "newest by EndDateTime" was a coin flip that could delete the LIVE secret --
#   the keeper is now identified by matching credential Hint against the KV value,
#   with creation-date order as the fallback.
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
    # Object ID (not client ID) of the 'Exchange Archive MCP' app registration.
    [string] $AppObjectId  = '3954b941-6262-4953-9741-173d42fce9bd',
    [string] $KeyVaultName = 'kv-gipartners-ai-prod',
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

    $allSecrets = @((Get-MgApplication -ApplicationId $AppObjectId).PasswordCredentials |
        Sort-Object StartDateTime -Descending)

    # Same-day creations share an EndDateTime, making "newest" ambiguous — and
    # deleting the credential Key Vault holds would break the OBO fallback path.
    # The LIVE credential is the one whose Hint (first chars of the value, which
    # Graph does return) prefixes the KV-stored secret; pin it to the keep slot.
    $kvValue = $null
    try {
        $kvValue = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name 'mcp-exchange-client-secret' -AsPlainText -ErrorAction Stop
    } catch {
        Write-Host "  (Key Vault value not readable — keeping creation-date order: $($_.Exception.Message))" -ForegroundColor DarkGray
    }
    if ($kvValue) {
        $live = @($allSecrets | Where-Object { $_.Hint -and $kvValue.StartsWith($_.Hint) })
        if ($live.Count -ge 1) {
            Write-Host "  Live secret identified via Key Vault hint match: $($live[0].DisplayName)" -ForegroundColor Green
            $allSecrets = @($live) + @($allSecrets | Where-Object { $_.KeyId -notin $live.KeyId })
        } else {
            Write-Warning 'No credential Hint matches the Key Vault value — the KV secret may be stale. Aborting removal; run a fresh rotation (no -RevokeOld) first.'
            return
        }
        $kvValue = $null
    }

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
