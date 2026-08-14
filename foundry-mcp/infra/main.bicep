// foundry-mcp/infra/main.bicep — azd infrastructure entry point
// Version: 3.4.0
//
// Rev 2026-07-13 (v3): targetScope changed subscription → resourceGroup. Deployment
// lands in an EXISTING resource group (org convention: finresgroup, alongside the
// other GI MCPs) instead of creating rg-exchange-mcp-{env}. Requires:
//   azd env set AZURE_RESOURCE_GROUP finresgroup
//   azd config set alpha.resourceGroupDeployments on   (no-op if already GA)
// Name hashes are seeded with resourceGroup().id so this deploy cannot collide with
// the soft-deleted vault from the earlier subscription-scoped attempt (purge
// protection reserves old names for 90 days).

targetScope = 'resourceGroup'

@description('azd environment name (e.g. prod, dev)')
param environmentName string

@description('Azure region — defaults to the resource group location')
param location string = resourceGroup().location

@description('Entra tenant ID used for Graph authentication')
param graphTenantId string

@description('Name for the Azure API Center resource')
param apiCenterName string = 'apic-gipartners-mcp'

@description('Set to false (azd env var DEPLOY_API_CENTER) when an API Center already exists org-wide — Phase 5 registers into it by name instead. String-typed because azd env substitution cannot produce a bool.')
param deployApiCenter string = 'true'

@description('Object ID of the deploying admin — azd fills this from AZURE_PRINCIPAL_ID; granted Secrets Officer on the vault')
param principalId string = ''

@description('Adopt an existing vault by name instead of generating one (azd env var KEY_VAULT_NAME). The vault must be in this resource group; the module updates it in place.')
param keyVaultNameOverride string = ''

@description('Client ID of the shared Entra app reg — Easy Auth validates inbound tokens against it')
param entraClientId string = '9519ca68-dae2-4add-8309-4bdd1fa45e79'

// Declared here, not only applied by script: ARM REPLACES a resource's tag set
// on deployment, so anything set out-of-band (Set-ResourceTags.ps1) is wiped by
// the next provision unless the template asserts it too.
// Keep in step with Set-ResourceTags.ps1 -- if the two sets diverge, each
// deployment strips whatever the template omits.
var tags = {
  Environment: environmentName
  ManagedBy:   'azd'
  Service:     'exchange-archive-mcp'
  Project:     'Exchange Archive MCP'
  Owner:       'IT-Infrastructure'
  CostCenter:  'IT-AI'
}

// Vault names cap at 24 chars and are globally reserved while soft-deleted, so the
// generated name is a hash seeded with the RG — never the (possibly long, hyphenated)
// env name. An override adopts a pre-existing vault (e.g. one that survived an RG move).
var keyVaultName = empty(keyVaultNameOverride)
  ? 'kv-exmcp-${take(uniqueString(resourceGroup().id, environmentName), 10)}'
  : keyVaultNameOverride

// ── Function App module (Flex Consumption + built-in MCP auth) ────────────────
module functionApp './modules/functionapp.bicep' = {
  name:  'functionapp'
  params: {
    location:           location
    environment:        environmentName
    tags:               tags
    keyVaultName:       keyVaultName
    graphTenantId:      graphTenantId
    entraClientId:      entraClientId
    entraIdentifierUri: 'api://exchange-mcp'
    deployerPrincipalId: principalId
  }
}

// ── Key Vault module (dedicated; includes MI → Secrets User grant) ────────────
module keyVault './modules/keyvault.bicep' = {
  name:  'keyvault'
  params: {
    location:               location
    tags:                   tags
    keyVaultName:            keyVaultName
    functionAppPrincipalId:  functionApp.outputs.functionAppPrincipalId
    adminPrincipalId:        principalId
    logAnalyticsWorkspaceId: functionApp.outputs.lawId
  }
}

var apiCenterEnabled = toLower(deployApiCenter) == 'true'

// ── API Center module (skippable when the org catalog already exists) ─────────
module apiCenter './modules/apicenter.bicep' = if (apiCenterEnabled) {
  name:  'apicenter'
  params: {
    location:      location
    apiCenterName: apiCenterName
    tags:          tags
  }
}

// ── Outputs (azd surfaces these as deployment outputs) ────────────────────────
output functionAppName     string = functionApp.outputs.functionAppName
output functionAppHostname string = functionApp.outputs.functionAppHostname
output mcpEndpoint         string = 'https://${functionApp.outputs.functionAppHostname}/runtime/webhooks/mcp'
output apiCenterName       string = apiCenter.?outputs.apiCenterName ?? apiCenterName
output keyVaultName        string = keyVault.outputs.keyVaultName
output keyVaultUri         string = keyVault.outputs.keyVaultUri
output uaiClientId         string = functionApp.outputs.uaiClientId
output uaiPrincipalId      string = functionApp.outputs.uaiPrincipalId
