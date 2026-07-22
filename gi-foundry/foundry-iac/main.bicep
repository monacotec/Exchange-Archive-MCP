// main.bicep — Orchestration entry point; composes all Foundry infrastructure modules

targetScope = 'resourceGroup'

// ── Parameters ───────────────────────────────────────────────────────────────
@description('Environment tag: prod | dev | test')
param environment string = 'prod'

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Base name used to derive all resource names')
param baseName string = 'gipartners'

@description('Enable managed VNet on Foundry Hub — WARNING: irreversible after creation')
param enableManagedVnet bool = true

@description('Object ID of the Entra ID IT Admin security group (required for Key Vault RBAC)')
param itAdminGroupObjectId string

@description('GPT-4o tokens-per-minute quota in thousands (e.g. 150 = 150K TPM)')
param gpt4oTpmK int = 150

// ── Shared Tags ──────────────────────────────────────────────────────────────
var tags = {
  Environment: environment
  Owner:       'IT-Infrastructure'
  CostCenter:  'IT-AI'
  ManagedBy:   'Bicep-IaC'
}

// ── Module: Network ──────────────────────────────────────────────────────────
module network './modules/network.bicep' = {
  name: 'network'
  params: {
    location:    location
    baseName:    baseName
    environment: environment
    tags:        tags
  }
}

// ── Module: Key Vault ────────────────────────────────────────────────────────
module kv './modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    location:              location
    baseName:              baseName
    environment:           environment
    tags:                  tags
    subnetId:              network.outputs.privateEndpointSubnetId
    privateDnsZoneId:      network.outputs.kvPrivateDnsZoneId
    itAdminGroupObjectId:  itAdminGroupObjectId
  }
}

// ── Module: Azure OpenAI ─────────────────────────────────────────────────────
module openai './modules/openai.bicep' = {
  name: 'openai'
  params: {
    location:         location
    baseName:         baseName
    environment:      environment
    tags:             tags
    subnetId:         network.outputs.privateEndpointSubnetId
    privateDnsZoneId: network.outputs.oaiPrivateDnsZoneId
    gpt4oTpmK:        gpt4oTpmK
  }
}

// ── Module: Foundry Hub + Project ────────────────────────────────────────────
module foundry './modules/foundry.bicep' = {
  name: 'foundry'
  params: {
    location:          location
    baseName:          baseName
    environment:       environment
    tags:              tags
    enableManagedVnet: enableManagedVnet
    openAiResourceId:  openai.outputs.openAiResourceId
    openAiEndpoint:    openai.outputs.endpoint
    keyVaultId:        kv.outputs.keyVaultId
    storageAccountId:  network.outputs.storageAccountId
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────
output foundryHubName string = foundry.outputs.hubName
output openAiEndpoint string = openai.outputs.endpoint
output keyVaultUri    string = kv.outputs.keyVaultUri
