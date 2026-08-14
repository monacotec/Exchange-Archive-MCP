// openai.bicep — Azure OpenAI resource, model deployments, private endpoint, Key Vault secret store

param location string
param baseName string
param environment string
param tags object
param subnetId string
param privateDnsZoneId string
param gpt4oTpmK int = 150

var oaiName = 'oai-${baseName}-${environment}'

// ── Azure OpenAI Account ─────────────────────────────────────────────────────
resource openAi 'Microsoft.CognitiveServices/accounts@2023-05-01' = {
  name:     oaiName
  location: location
  tags:     tags
  kind:     'OpenAI'
  sku:      { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    customSubDomainName: '${baseName}-oai'
    publicNetworkAccess: 'Disabled'  // private endpoint only
    networkAcls: {
      defaultAction:       'Deny'
      virtualNetworkRules: []
      ipRules:             []
    }
  }
}

// ── Model Deployments ────────────────────────────────────────────────────────
// @batchSize(1) prevents capacity race conditions during simultaneous deploys
var models = [
  { name: 'gpt-4o-prod',      model: 'gpt-4o',               version: '2024-11-20', tpmK: gpt4oTpmK }
  { name: 'embed-large-prod', model: 'text-embedding-3-large', version: '1',         tpmK: 350       }
  { name: 'gpt-4o-mini-prod', model: 'gpt-4o-mini',           version: '2024-07-18', tpmK: 500       }
]

@batchSize(1)
resource deployments 'Microsoft.CognitiveServices/accounts/deployments@2023-05-01' = [
  for m in models: {
    parent: openAi
    name:   m.name
    sku:    { name: 'Standard', capacity: m.tpmK }
    properties: {
      model: { format: 'OpenAI', name: m.model, version: m.version }
    }
  }
]

// ── Private Endpoint ─────────────────────────────────────────────────────────
resource oaiPe 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name:     'pe-${oaiName}'
  location: location
  tags:     tags
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: 'oai-connection'
        properties: {
          privateLinkServiceId: openAi.id
          groupIds:             ['account']
        }
      }
    ]
  }
}

resource oaiDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: oaiPe
  name:   'oai-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name:       'openai-dns'
        properties: { privateDnsZoneId: privateDnsZoneId }
      }
    ]
  }
}

// ── Key handling (finding 6 — remediated 2026-07-02) ─────────────────────────
// The previous revision materialized listKeys().key1 into a Key Vault secret here.
// ARM captures fully-resolved property values in the deployment operation record,
// readable by anyone with resource-group Reader — so the "vaulted" key also lived
// in deployment history. The Hub connection is now keyless (authType 'AAD' in
// foundry.bicep); no key is materialized anywhere in this stack.
//
// NOTE: prior deployment records may still contain the old key. Rotate key1 once
// after this revision deploys, then purge the orphaned 'oai-key1-current' secret.
// See DAY-ZERO-HYGIENE.md §Manual steps.

// ── Outputs ──────────────────────────────────────────────────────────────────
output openAiResourceId string = openAi.id
output endpoint         string = openAi.properties.endpoint
