// foundry.bicep — AI Foundry Hub, Azure OpenAI connection, and Project

param location string
param baseName string
param environment string
param tags object
param enableManagedVnet bool
param openAiResourceId string
param openAiEndpoint string
param keyVaultId string
param storageAccountId string

var hubName  = 'hub-${baseName}-ai-${environment}'
var projName = 'proj-${baseName}-ai-${environment}'

// ── Foundry Hub ──────────────────────────────────────────────────────────────
resource hub 'Microsoft.MachineLearningServices/workspaces@2024-04-01' = {
  name:     hubName
  location: location
  tags:     tags
  kind:     'Hub'
  identity: { type: 'SystemAssigned' }
  properties: {
    keyVault:       keyVaultId
    storageAccount: storageAccountId
    managedNetwork: {
      // AllowOnlyApprovedOutbound is irreversible — confirm before prod deploy
      isolationMode: enableManagedVnet ? 'AllowOnlyApprovedOutbound' : 'Disabled'
    }
  }
}

// ── Azure OpenAI Connection on Hub (keyless — findings 13/30, remediated 2026-07-02) ──
// authType 'AAD' replaces the inline listKeys() ApiKey credential: no static
// full-data-plane key exists to leak or rotate. isSharedToAll stays TRUE by design —
// with no key in the connection there is nothing to widen; Projects inherit the
// connection and authenticate with their own managed identities via the role
// assignments below.
resource oaiConnection 'Microsoft.MachineLearningServices/workspaces/connections@2024-04-01' = {
  parent: hub
  name:   'oai-${baseName}-prod'
  properties: {
    category:      'AzureOpenAI'
    target:        openAiEndpoint
    authType:      'AAD'
    isSharedToAll: true  // all Projects under this Hub inherit the connection
    metadata: {
      ApiType:    'Azure'
      ApiVersion: '2024-10-21'
      ResourceId: openAiResourceId
    }
  }
}

// ── Foundry Project ──────────────────────────────────────────────────────────
resource project 'Microsoft.MachineLearningServices/workspaces@2024-04-01' = {
  name:     projName
  location: location
  tags:     tags
  kind:     'Project'
  identity: { type: 'SystemAssigned' }
  properties: {
    hubResourceId: hub.id
  }
}

// ── RBAC: Cognitive Services OpenAI User on the OpenAI account ───────────────
// The role must go to the identity that actually issues inference — the Project
// (agents run in Project scope) — with the Hub MI included for portal/test paths.
// Role definition: 5e0bd9bd-7b93-4f28-af87-19fc36ad61bd (Cognitive Services OpenAI User)
// Assumes the OpenAI account is in this resource group (true in this stack).
resource openAiAccount 'Microsoft.CognitiveServices/accounts@2023-05-01' existing = {
  name: last(split(openAiResourceId, '/'))
}

var oaiUserRoleDefId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')

resource projectOaiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name:  guid(openAiAccount.id, project.id, 'oai-user')
  scope: openAiAccount
  properties: {
    roleDefinitionId: oaiUserRoleDefId
    principalId:      project.identity.principalId
    principalType:    'ServicePrincipal'
  }
}

resource hubOaiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name:  guid(openAiAccount.id, hub.id, 'oai-user')
  scope: openAiAccount
  properties: {
    roleDefinitionId: oaiUserRoleDefId
    principalId:      hub.identity.principalId
    principalType:    'ServicePrincipal'
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────
output hubName   string = hub.name
output hubId     string = hub.id
output projectId string = project.id
