// keyvault.bicep — dedicated Key Vault for the Exchange Archive MCP
// Version: 0.3.0
//
// Rev 2026-07-21 (0.3.0): AuditEvent diagnostic setting → Log Analytics (finding 14).
//
// Rev 2026-07-13: the plan assumed a shared KV from the gi-foundry Phase 1 stack
// (kv-gipartners-ai-prod). Recon confirmed that stack is not deployed, so this MCP
// provisions its own vault in rg-exchange-mcp-{env}.
//
// DEVIATION from FOUNDRY-MCP-PLAN §6.1 (documented, revisit in Phase 6):
// publicNetworkAccess stays Enabled because (a) the Consumption (Y1) plan cannot
// use VNet integration or private endpoints, and (b) the foundry VNet this plan
// expected to join does not exist. Compensating controls: RBAC-only authorization
// (no access policies), soft-delete + purge protection, and the Function App's
// AuthLevel.FUNCTION gate on the MCP endpoint. Private endpoint upgrade path is
// EP1 plan + VNet — tracked for v2 / Phase 6 hardening.

param location string
param tags object

@description('Vault name — computed in main.bicep so functionapp.bicep can reference it without a dependency cycle')
param keyVaultName string

@description('Principal ID of the Function App managed identity (Key Vault Secrets User grant)')
param functionAppPrincipalId string

@description('Object ID of the deploying admin (azd principal) — granted Secrets Officer so the Phase 0 secret writes work without a manual role assignment. Empty string skips the grant.')
param adminPrincipalId string = ''

@description('Log Analytics workspace resource ID for vault audit logging (REMEDIATION-GUIDE finding 14). Empty string skips the diagnostic setting.')
param logAnalyticsWorkspaceId string = ''

var kvName = keyVaultName

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name:     kvName
  location: location
  tags:     tags
  properties: {
    sku:      { family: 'A', name: 'standard' }
    tenantId: tenant().tenantId
    enableRbacAuthorization:  true   // RBAC model — no vault access policies
    enableSoftDelete:         true
    softDeleteRetentionInDays: 90
    enablePurgeProtection:    true
    publicNetworkAccess:      'Enabled'   // see DEVIATION note above
    networkAcls: {
      defaultAction: 'Allow'
      bypass:        'AzureServices'
    }
  }
}

// Vault audit trail (finding 14): forward AuditEvent — the explicit category, NOT
// categoryGroup 'audit' (the group can silently change membership between API
// versions) — to the same Log Analytics workspace as the Function App telemetry.
// SecretGet/SecretList events corroborate which identity read the OBO secret.
resource kvDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (logAnalyticsWorkspaceId != '') {
  name:  'kv-audit-to-law'
  scope: kv
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'AuditEvent'
        enabled:  true
      }
    ]
  }
}

// Key Vault Secrets User (4633458b-17de-408a-b874-0445c86b69e6) — read-only secret access
resource kvSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name:  guid(kv.id, functionAppPrincipalId, '4633458b-17de-408a-b874-0445c86b69e6')
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId(
                        'Microsoft.Authorization/roleDefinitions',
                        '4633458b-17de-408a-b874-0445c86b69e6')
    principalId:      functionAppPrincipalId
    principalType:    'ServicePrincipal'
  }
}

// Key Vault Secrets Officer (b86a8fe4-44ce-4948-aee5-eccb2c155cd7) — lets the deploying
// admin run Register-EntraApp.ps1 -CreateOboSecret against this vault immediately.
resource kvSecretsOfficerAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (adminPrincipalId != '') {
  name:  guid(kv.id, adminPrincipalId, 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId(
                        'Microsoft.Authorization/roleDefinitions',
                        'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
    principalId:      adminPrincipalId
    principalType:    'User'
  }
}

output keyVaultName string = kv.name
output keyVaultId   string = kv.id
output keyVaultUri  string = kv.properties.vaultUri
