// network.bicep — VNet, subnets, Private DNS zones, and shared storage account

param location string
param baseName string
param environment string
param tags object

var vnetName    = 'vnet-${baseName}-ai-${environment}'
var storageName = 'sa${baseName}ai${environment}'

// ── Virtual Network ─────────────────────────────────────────────────────────
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name:     vnetName
  location: location
  tags:     tags
  properties: {
    addressSpace: { addressPrefixes: ['10.100.0.0/16'] }
    subnets: [
      {
        // Private endpoint subnet — network policies must be disabled for PE to work
        name: 'snet-private-endpoints'
        properties: {
          addressPrefix: '10.100.1.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        // Subnet delegated to Foundry managed network
        name: 'snet-foundry-managed'
        properties: {
          addressPrefix: '10.100.2.0/24'
          delegations: [
            {
              name: 'ml-delegation'
              properties: {
                serviceName: 'Microsoft.MachineLearningServices/workspaces'
              }
            }
          ]
        }
      }
    ]
  }
}

// ── Private DNS Zones ────────────────────────────────────────────────────────
var dnsZoneNames = [
  'privatelink.openai.azure.com'
  'privatelink.vaultcore.azure.net'
  'privatelink.blob.${az.environment().suffixes.storage}'
  'privatelink.api.azureml.ms'
]

resource privateDnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [
  for zone in dnsZoneNames: {
    name:     zone
    location: 'global'
    tags:     tags
  }
]

// Link each DNS zone to the VNet for resolution
resource dnsVnetLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [
  for (zone, i) in dnsZoneNames: {
    parent:   privateDnsZones[i]
    name:     'link-${vnetName}'
    location: 'global'
    properties: {
      virtualNetwork:      { id: vnet.id }
      registrationEnabled: false  // no auto-registration; manual records only
    }
  }
]

// ── Storage Account (Foundry artifact store) ─────────────────────────────────
resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name:     storageName
  location: location
  tags:     tags
  sku:      { name: 'Standard_LRS' }
  kind:     'StorageV2'
  properties: {
    allowBlobPublicAccess:    false
    supportsHttpsTrafficOnly: true
    minimumTlsVersion:        'TLS1_2'
    publicNetworkAccess:      'Disabled'
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────
output privateEndpointSubnetId string = vnet.properties.subnets[0].id
output oaiPrivateDnsZoneId     string = privateDnsZones[0].id
output kvPrivateDnsZoneId      string = privateDnsZones[1].id
output storageAccountId        string = storage.id
