#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication
# Version: 1.0.0
<#
.SYNOPSIS
    Adds the federated identity credential (Workload Identity Federation) linking
    the Function App's user-assigned managed identity to the shared Entra app reg.

.DESCRIPTION
    Phase 2 step. With this credential in place, the Function App's OBO exchange
    proves its identity with a managed-identity assertion instead of the client
    secret — the secret becomes fallback-only. Idempotent: skips creation when a
    credential with the same name already exists.

    Get the UAI principal ID from the deployment outputs:
        azd env get-values | findstr uaiPrincipalId

.PARAMETER UaiPrincipalId
    Principal (object) ID of the user-assigned managed identity
    (deployment output 'uaiPrincipalId').

.PARAMETER AppObjectId
    Object ID of the shared Entra app registration. Defaults to Exchange Archive MCP.

.PARAMETER TenantId
    Entra tenant GUID.

.EXAMPLE
    .\Add-FederatedCredential.ps1 -UaiPrincipalId '<guid from azd output>'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string] $UaiPrincipalId,
    [string] $AppObjectId = '3954b941-6262-4953-9741-173d42fce9bd',
    [string] $TenantId    = '9c1b0b26-717a-4eda-9d7e-7eebc00066bf'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ficName = 'mcp-function-managed-identity'

Write-Host 'Connecting to Microsoft Graph...' -ForegroundColor Cyan
Connect-MgGraph -TenantId $TenantId -Scopes 'Application.ReadWrite.All' -NoWelcome

try {
    $listUri = "https://graph.microsoft.com/v1.0/applications/$AppObjectId/federatedIdentityCredentials"
    $existing = @((Invoke-MgGraphRequest -Method GET -Uri $listUri -OutputType PSObject).value)

    $match = $existing | Where-Object { $_.name -eq $ficName }
    if ($match) {
        if ($match.subject -eq $UaiPrincipalId) {
            Write-Host "Federated credential '$ficName' already exists with the correct subject." -ForegroundColor Green
            return
        }
        Write-Host "Federated credential '$ficName' exists with a DIFFERENT subject ($($match.subject)) — updating." -ForegroundColor Yellow
        if ($PSCmdlet.ShouldProcess($ficName, 'Update federated identity credential subject')) {
            Invoke-MgGraphRequest -Method PATCH -Uri "$listUri/$($match.id)" `
                -Body (@{ subject = $UaiPrincipalId } | ConvertTo-Json) -ContentType 'application/json'
            Write-Host 'Updated.' -ForegroundColor Green
        }
        return
    }

    if ($PSCmdlet.ShouldProcess($ficName, 'Create federated identity credential')) {
        $body = @{
            name        = $ficName
            issuer      = "https://login.microsoftonline.com/$TenantId/v2.0"
            subject     = $UaiPrincipalId
            audiences   = @('api://AzureADTokenExchange')
            description = 'WIF: Exchange Archive MCP Function App UAI → app reg (OBO client assertion, no client secret)'
        } | ConvertTo-Json -Depth 5
        Invoke-MgGraphRequest -Method POST -Uri $listUri -Body $body -ContentType 'application/json' | Out-Null
        Write-Host "Federated credential '$ficName' created." -ForegroundColor Green
        Write-Host '  OBO now runs secret-free; mcp-exchange-client-secret in KV is fallback-only.' -ForegroundColor DarkGray
    }
}
finally {
    if (Get-MgContext) {
        Disconnect-MgGraph | Out-Null
        Write-Host 'Disconnected from Microsoft Graph.' -ForegroundColor DarkGray
    }
}
