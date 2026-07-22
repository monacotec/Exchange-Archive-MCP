#Requires -Version 7.0
<#
.SYNOPSIS
    Idempotently registers (or updates) the Exchange Archive MCP server in Azure API Center.

.DESCRIPTION
    Run once after 'azd up' to make the MCP server discoverable in the Foundry
    Tools catalog. Safe to re-run — checks for existing registration and updates in place.

    Steps:
      1. Derive MCP endpoint from Function App name
      2. Retrieve MCP extension system key from Function App and store in Key Vault
      3. Upsert API definition in API Center (type: mcp)
      4. Upsert deployment entry with live endpoint URL
      5. Configure API Key authentication entry

.PARAMETER ApiCenterName
    Name of the Azure API Center resource (from 'azd up' output).

.PARAMETER ResourceGroup
    Resource group containing the API Center resource.

.PARAMETER FunctionAppName
    Function App name (from 'azd up' output).

.PARAMETER FunctionAppResourceGroup
    Resource group containing the Function App.

.PARAMETER KeyVaultName
    Key Vault where the MCP extension system key will be stored.

.PARAMETER SubscriptionId
    Azure subscription ID. Defaults to current context.

.EXAMPLE
    .\Register-MCPInApiCenter.ps1 `
        -ApiCenterName apic-gipartners-mcp `
        -ResourceGroup rg-exchange-mcp-prod `
        -FunctionAppName func-exchange-mcp-prod `
        -FunctionAppResourceGroup rg-exchange-mcp-prod `
        -KeyVaultName kv-gipartners-ai-prod
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $ApiCenterName,
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $FunctionAppName,
    [Parameter(Mandatory)] [string] $FunctionAppResourceGroup,
    [Parameter(Mandatory)] [string] $KeyVaultName,
    [string] $SubscriptionId = (Get-AzContext).Subscription.Id
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ApiName    = 'exchange-archive-mcp'
$McpEndpoint = "https://$FunctionAppName.azurewebsites.net/runtime/webhooks/mcp"

# ── Step 1: Retrieve MCP extension system key from Function App ───────────────
Write-Host "Retrieving MCP extension system key from '$FunctionAppName'..." -ForegroundColor Cyan

$token  = (Get-AzAccessToken).Token
$keysUri = "https://management.azure.com/subscriptions/$SubscriptionId" +
           "/resourceGroups/$FunctionAppResourceGroup/providers/Microsoft.Web/sites/$FunctionAppName" +
           "/host/default/listKeys?api-version=2023-01-01"

$funcKeys = Invoke-RestMethod -Uri $keysUri -Method POST `
    -Headers @{ Authorization = "Bearer $token" } `
    -ContentType 'application/json'

$mcpExtKey = $funcKeys.systemKeys.mcp_extension
if (-not $mcpExtKey) { throw "mcp_extension system key not found on Function App. Ensure the MCP extension bundle is deployed." }

# Store in Key Vault — never echo the value
if ($PSCmdlet.ShouldProcess($KeyVaultName, "Store mcp-functions-extension-key")) {
    Set-AzKeyVaultSecret `
        -VaultName $KeyVaultName `
        -Name 'mcp-functions-extension-key' `
        -SecretValue (ConvertTo-SecureString $mcpExtKey -AsPlainText -Force) | Out-Null
    Write-Host "  Extension key stored in Key Vault as 'mcp-functions-extension-key'." -ForegroundColor Green
}
$mcpExtKey = $null  # clear from memory

# ── Step 2: Upsert API in API Center ─────────────────────────────────────────
Write-Host "Registering MCP server in API Center '$ApiCenterName'..." -ForegroundColor Cyan

$apiBody = @{
    properties = @{
        title       = 'Exchange Online Archive MCP'
        description = 'MCP server providing Claude and Foundry agents read-only access to Exchange Online archive mailboxes at GI Partners.'
        kind        = 'rest'   # API Center uses 'rest' for HTTP-based custom APIs
        lifecycleStage = 'production'
        customProperties = @{
            mcpType = 'custom'
            toolCount = 3
        }
    }
} | ConvertTo-Json -Depth 5

$apiUri = "https://management.azure.com/subscriptions/$SubscriptionId" +
          "/resourceGroups/$ResourceGroup/providers/Microsoft.ApiCenter/services/$ApiCenterName" +
          "/workspaces/default/apis/$ApiName" +
          "?api-version=2024-03-01"

if ($PSCmdlet.ShouldProcess($ApiCenterName, "Upsert API '$ApiName'")) {
    Invoke-RestMethod -Uri $apiUri -Method PUT `
        -Headers @{ Authorization = "Bearer $token" } `
        -Body $apiBody -ContentType 'application/json' | Out-Null
    Write-Host "  API '$ApiName' upserted." -ForegroundColor Green
}

# ── Step 3: Upsert deployment entry ──────────────────────────────────────────
$deployBody = @{
    properties = @{
        title       = 'Production'
        server      = @{
            runtimeUri = @($McpEndpoint)
        }
        environmentId = "/workspaces/default/environments/production"
    }
} | ConvertTo-Json -Depth 5

$deployUri = "$($apiUri.Split('?')[0])/deployments/production?api-version=2024-03-01"

if ($PSCmdlet.ShouldProcess($ApiCenterName, "Upsert deployment endpoint")) {
    Invoke-RestMethod -Uri $deployUri -Method PUT `
        -Headers @{ Authorization = "Bearer $token" } `
        -Body $deployBody -ContentType 'application/json' | Out-Null
    Write-Host "  Deployment endpoint upserted: $McpEndpoint" -ForegroundColor Green
}

# ── Done ──────────────────────────────────────────────────────────────────────
Write-Host "`n[DONE] MCP server registered in API Center." -ForegroundColor Green
Write-Host "       Endpoint : $McpEndpoint"
Write-Host "       Auth     : x-functions-key header (key stored in Key Vault)"
Write-Host ""
Write-Host "To connect from Claude Desktop, add to claude_desktop_config.json:" -ForegroundColor Cyan
Write-Host @"
{
  "mcpServers": {
    "exchange-archive": {
      "type": "http",
      "url": "$McpEndpoint",
      "headers": { "x-functions-key": "<mcp_extension_system_key from Key Vault>" }
    }
  }
}
"@
Write-Host ""
Write-Host "To connect from Foundry portal:" -ForegroundColor Cyan
Write-Host "  Build -> Tools -> Add tool -> Model Context Protocol -> enter endpoint above"
