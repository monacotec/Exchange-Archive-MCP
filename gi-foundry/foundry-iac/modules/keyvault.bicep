// keyvault.bicep — Key Vault with RBAC auth model, soft-delete, purge protection, private endpoint

param location string
param baseName string
param environment string
param tags object
param subnetId string
param privateDnsZoneId string
param itAdminGroupObjectId string

var kvName = 'kv-${baseName}-ai-${environment}'

// ── Key Vault ────────────────────────────────────────────────────────────────
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name:     kvName
  location: location
  tags:     tags
  properties: {
    sku:                     { family: 'A', name: 'standard' }
    tenantId:                subscription().tenantId
    enableRbacAuthorization: true   // RBAC model — no vault access policies
    enableSoftDelete:        true
    softDeleteRetentionInDays: 90
    enablePurgeProtection:   true   // prevents permanent deletion during retention period
    publicNetworkAccess:     'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass:        'AzureServices'
    }
  }
}

// ── Private Endpoint ─────────────────────────────────────────────────────────
resource kvPe 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name:     'pe-${kvName}'
  location: location
  tags:     tags
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: 'kv-connection'
        properties: {
          privateLinkServiceId: kv.id
          groupIds:             ['vault']
        }
      }
    ]
  }
}

resource kvDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = {
  parent: kvPe
  name:   'kv-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name:       'keyvault-dns'
        properties: { privateDnsZoneId: privateDnsZoneId }
      }
    ]
  }
}

// ── RBAC — IT Admin group gets Secrets Officer on this vault ─────────────────
resource kvSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name:  guid(kv.id, itAdminGroupObjectId, 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions',
                        'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')  // Key Vault Secrets Officer
    principalId:      itAdminGroupObjectId
    principalType:    'Group'
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────
output keyVaultId   string = kv.id
output keyVaultName string = kv.name
output keyVaultUri  string = kv.properties.vaultUri
