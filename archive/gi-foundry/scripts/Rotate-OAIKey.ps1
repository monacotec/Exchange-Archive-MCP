#Requires -Version 7.0
<#
.SYNOPSIS
    Zero-downtime rotation of Azure OpenAI API keys.

.DESCRIPTION
    Rotates both Azure OpenAI keys using a six-phase approach that keeps the Foundry
    Hub connection live throughout. After rotation both keys are freshly regenerated
    and their new values are stored in Key Vault. The active key left in Foundry is Key1.

    Phase sequence:
      1. Switch Foundry Hub connection -> Key2  (Key2 is still valid)
      2. Wait 30s for credential propagation
      3. Regenerate Key1 + store in Key Vault
      4. Switch Foundry Hub connection -> Key1  (fresh Key1)
      5. Wait 30s
      6. Regenerate Key2 + store in Key Vault

    NEVER logs or echoes key values to console or log files.

.PARAMETER ResourceGroup
    Resource group containing the Azure OpenAI resource and Foundry Hub.

.PARAMETER OpenAIAccountName
    Name of the Azure OpenAI Cognitive Services account.

.PARAMETER KeyVaultName
    Key Vault where rotated key values are stored.

.PARAMETER FoundryHubName
    Name of the Azure AI Foundry Hub (for connection update via az ml).

.PARAMETER SubscriptionId
    Target subscription. Defaults to current Az context subscription.

.EXAMPLE
    .\Rotate-OAIKey.ps1 -ResourceGroup rg-ai-foundry-prod `
        -OpenAIAccountName oai-gipartners-prod `
        -KeyVaultName kv-gipartners-ai-prod `
        -FoundryHubName hub-gipartners-ai-prod
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $OpenAIAccountName,
    [Parameter(Mandatory)] [string] $KeyVaultName,
    [Parameter(Mandatory)] [string] $FoundryHubName,
    [string] $SubscriptionId = (Get-AzContext).Subscription.Id
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Helper: switch Foundry Hub connection to a given key ─────────────────────
function Set-FoundryKeyVersion {
    param([ValidateSet('Key1', 'Key2')] [string] $KeyName)

    Write-Host "  Switching Foundry Hub connection to $KeyName..." -ForegroundColor Cyan

    if ($PSCmdlet.ShouldProcess($FoundryHubName, "Set OpenAI connection to $KeyName")) {
        # Retrieve connection JSON from Foundry
        $connJson = az ml connection show `
            --name "oai-gipartners-prod" `
            --workspace-name $FoundryHubName `
            --resource-group $ResourceGroup `
            --output json

        if ($LASTEXITCODE -ne 0) { throw "Failed to retrieve Foundry connection." }
        $conn = $connJson | ConvertFrom-Json

        # Get the target key value from ARM (not stored in a variable longer than needed)
        $keys      = Get-AzCognitiveServicesAccountKey -ResourceGroupName $ResourceGroup -Name $OpenAIAccountName
        $targetKey = if ($KeyName -eq 'Key1') { $keys.Key1 } else { $keys.Key2 }

        # Patch the credential and write to a temp file (ARM requires file input)
        $conn.credentials.key = $targetKey
        $tmpFile = [System.IO.Path]::GetTempFileName() + '.json'
        try {
            $conn | ConvertTo-Json -Depth 10 | Set-Content -Path $tmpFile
            az ml connection update `
                --file $tmpFile `
                --workspace-name $FoundryHubName `
                --resource-group $ResourceGroup | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Failed to update Foundry connection." }
        } finally {
            Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        }

        # Clear key from memory
        $targetKey = $null
        Write-Host "  Foundry Hub connection updated to $KeyName." -ForegroundColor Green
    }
}

# ── Helper: regenerate a key and store new value in Key Vault ─────────────────
function Invoke-KeyRegenAndStore {
    param([ValidateSet('Key1', 'Key2')] [string] $KeyName)

    Write-Host "  Regenerating $KeyName..." -ForegroundColor Yellow

    if ($PSCmdlet.ShouldProcess($OpenAIAccountName, "Regenerate $KeyName")) {
        # Call ARM regenerateKey REST endpoint
        $token  = (Get-AzAccessToken).Token
        $apiUri = "https://management.azure.com/subscriptions/$SubscriptionId" +
                  "/resourceGroups/$ResourceGroup/providers/" +
                  "Microsoft.CognitiveServices/accounts/$OpenAIAccountName" +
                  "/regenerateKey?api-version=2023-05-01"

        $body = @{ keyName = $KeyName } | ConvertTo-Json
        Invoke-RestMethod -Uri $apiUri -Method POST `
            -Headers @{ Authorization = "Bearer $token" } `
            -Body $body -ContentType 'application/json' | Out-Null

        # Allow ARM to propagate the new key before reading it back
        Start-Sleep -Seconds 10

        # Read new value and store in Key Vault — never assign to a logged variable
        $keys          = Get-AzCognitiveServicesAccountKey -ResourceGroupName $ResourceGroup -Name $OpenAIAccountName
        $secretName    = "oai-$($KeyName.ToLower())-current"
        $secretValue   = if ($KeyName -eq 'Key1') { $keys.Key1 } else { $keys.Key2 }
        $secureSecret  = ConvertTo-SecureString $secretValue -AsPlainText -Force

        Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $secretName -SecretValue $secureSecret | Out-Null

        # Clear from memory
        $secretValue  = $null
        $secureSecret = $null
        $keys         = $null

        Write-Host "  $KeyName regenerated and stored in Key Vault as '$secretName'." -ForegroundColor Green
    }
}

# ── Main rotation sequence ────────────────────────────────────────────────────
Write-Host "`n=== Azure OpenAI Key Rotation ===" -ForegroundColor Magenta
Write-Host "Resource     : $OpenAIAccountName"
Write-Host "Resource Group: $ResourceGroup"
Write-Host "Key Vault    : $KeyVaultName`n"

Write-Host '[Phase 1] Switching Foundry Hub to Key2...'
Set-FoundryKeyVersion -KeyName 'Key2'

Write-Host '[Pause]   Waiting 30s for credential propagation...'
if (-not $WhatIfPreference) { Start-Sleep -Seconds 30 }

Write-Host '[Phase 2] Regenerating Key1...'
Invoke-KeyRegenAndStore -KeyName 'Key1'

Write-Host '[Phase 3] Switching Foundry Hub back to Key1...'
Set-FoundryKeyVersion -KeyName 'Key1'

Write-Host '[Pause]   Waiting 30s for credential propagation...'
if (-not $WhatIfPreference) { Start-Sleep -Seconds 30 }

Write-Host '[Phase 4] Regenerating Key2...'
Invoke-KeyRegenAndStore -KeyName 'Key2'

Write-Host "`n[DONE] Both keys rotated. Foundry Hub is using Key1." -ForegroundColor Green
Write-Host "       New values stored in Key Vault: $KeyVaultName"
Write-Host "       Secrets: oai-key1-current, oai-key2-current`n"
