// functionapp.bicep — Flex Consumption Function App with built-in MCP auth
// Version: 2.3.0
//
// Rev 2026-08-12 (v2.3.0): alwaysReady http=1 declared (idle scale-to-zero
// broke connector connects; keeps the live Set-McpAlwaysReady.ps1 fix from
// being reverted by provisioning). Header version also re-synced with the
// suite manifest (file said 2.1.0 while the manifest said 2.2.0).
//
// Rev 2026-07-13 (v2): migrated Y1 classic Consumption → FLEX Consumption (FC1).
// The MCP extension (mcpToolTrigger) and built-in MCP auth (Easy Auth) require
// Flex — the Y1 deploy never indexed the tools. Pattern lifted from
// Azure-Samples/remote-mcp-functions-python (infra/app/api.bicep).
//
// This module also ships the Phase 2 auth cutover ATOMICALLY per the amended
// build order: Easy Auth (authsettingsV2, fail-closed Return401) activates in
// the same deploy that host.json flips webhookAuthorizationLevel → Anonymous.
// There is no window with an ungated endpoint: authsettingsV2 rejects
// unauthenticated requests before any function code runs.
//
// Identity model:
//   - USER-ASSIGNED MI  → host storage (AzureWebJobsStorage__*), deployment
//     container, App Insights AAD ingestion, and the OBO client assertion
//     (federated identity credential on the app reg — created post-deploy by
//     scripts/Add-FederatedCredential.ps1).
//   - SYSTEM-ASSIGNED MI → Key Vault Secrets User (granted in keyvault.bicep)
//     for the OBO client-secret fallback path.

param location string
param environment string
param tags object
param keyVaultName string
param graphTenantId string

@description('Client ID of the shared Entra app reg (Exchange Archive MCP) that Easy Auth validates tokens against')
param entraClientId string

@description('Application ID URI exposed by the app reg — becomes the allowed audience and the PRM default scope root')
param entraIdentifierUri string = 'api://exchange-mcp'

@description('Object ID of the deploying admin (azd AZURE_PRINCIPAL_ID). Granted Storage Blob Data Contributor so azd can upload the deployment package — required because shared-key access is disabled. Empty string skips the grant.')
param deployerPrincipalId string = ''

var funcName    = 'func-exchange-mcp-${environment}'
var planName    = 'asp-exchange-mcp-${environment}'
var uaiName     = 'uai-exchange-mcp-${environment}'
var appiName    = 'appi-exchange-mcp-${environment}'
var lawName     = 'law-exchange-mcp-${environment}'
// Storage names: 3-24 chars, lowercase alnum only — env identity travels via hash.
var envHash     = take(uniqueString(resourceGroup().id, environment), 10)
var storageName = 'saexmcp${envHash}'
var deployContainerName = 'app-package-${take(funcName, 32)}-${envHash}'

// ── User-assigned managed identity ───────────────────────────────────────────
resource uai 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name:     uaiName
  location: location
  tags:     tags
}

// ── Log Analytics + Application Insights ─────────────────────────────────────
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name:     lawName
  location: location
  tags:     tags
  properties: {
    sku:             { name: 'PerGB2018' }
    retentionInDays: 90
  }
}

resource appi 'Microsoft.Insights/components@2020-02-02' = {
  name:     appiName
  location: location
  tags:     tags
  kind:     'web'
  properties: {
    Application_Type:    'web'
    WorkspaceResourceId: law.id
  }
}

// ── Storage (host state + deployment package) — identity-only data plane ─────
resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name:     storageName
  location: location
  tags:     tags
  sku:      { name: 'Standard_LRS' }
  kind:     'StorageV2'
  properties: {
    allowBlobPublicAccess:    false
    allowSharedKeyAccess:     false     // finding 5: identity-only, no account keys anywhere
    supportsHttpsTrafficOnly: true
    minimumTlsVersion:        'TLS1_2'
  }

  resource blobService 'blobServices' = {
    name: 'default'
    resource deployContainer 'containers' = {
      name: deployContainerName
    }
  }
}

// UAI → storage: Blob Data Owner (host + deployment package) and Queue Data
// Contributor (host features). Role propagation can lag first deploy — retry,
// don't debug.
resource uaiBlobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name:  guid(storage.id, uai.id, 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
    principalId:      uai.properties.principalId
    principalType:    'ServicePrincipal'
  }
}

resource uaiQueueContrib 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name:  guid(storage.id, uai.id, '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
    principalId:      uai.properties.principalId
    principalType:    'ServicePrincipal'
  }
}

// Deployer → storage: Storage Blob Data Contributor. With shared-key access off,
// `azd`/`func` upload the zip package using the deploying user's AAD token, which
// needs a data-plane blob role (control-plane Owner is NOT sufficient).
resource deployerBlobContrib 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployerPrincipalId != '') {
  name:  guid(storage.id, deployerPrincipalId, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId:      deployerPrincipalId
    principalType:    'User'
  }
}

// UAI → App Insights: Monitoring Metrics Publisher (AAD-authenticated ingestion)
resource uaiMetricsPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name:  guid(appi.id, uai.id, '3913510d-42f4-4e42-8a64-420c390055eb')
  scope: appi
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')
    principalId:      uai.properties.principalId
    principalType:    'ServicePrincipal'
  }
}

// ── Flex Consumption plan ─────────────────────────────────────────────────────
resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name:     planName
  location: location
  tags:     tags
  kind:     'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true
  }
}

// ── Function App (Flex) ───────────────────────────────────────────────────────
resource funcApp 'Microsoft.Web/sites@2024-04-01' = {
  name:     funcName
  location: location
  // azd maps the 'exchange-mcp' service in azure.yaml to this app via azd-service-name.
  tags:     union(tags, { 'azd-service-name': 'exchange-mcp' })
  kind:     'functionapp,linux'
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${uai.id}': {}
    }
  }
  properties: {
    serverFarmId:        plan.id
    httpsOnly:           true
    publicNetworkAccess: 'Enabled'   // gated by authsettingsV2 below (fail-closed Return401)
    functionAppConfig: {
      deployment: {
        storage: {
          type:  'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deployContainerName}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: uai.id
          }
        }
      }
      scaleAndConcurrency: {
        instanceMemoryMB:     2048
        maximumInstanceCount: 40
        // One always-warm instance: Flex scales to zero when idle and the
        // post-idle cold start exceeds the MCP client's connect timeout
        // ("Couldn't reach Exchange Archive MCP", 2026-08-12). Applied live
        // via scripts/Set-McpAlwaysReady.ps1; declared here so provisioning
        // cannot silently revert it. Bills continuously (~single-digit USD/day).
        alwaysReady: [
          {
            name:          'http'
            instanceCount: 1
          }
        ]
      }
      runtime: {
        name:    'python'
        // 3.13 required: azure-functions 2.x (mcp_tool decorators) declares a
        // Requires-Python floor that filters it OUT of pip resolution on 3.11 —
        // the build fails with "No matching distribution". Matches the reference template.
        version: '3.13'
      }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState:     'Disabled'
    }
  }

  resource appSettings 'config' = {
    name: 'appsettings'
    properties: {
      // Host storage — identity-based, no keys (finding 5)
      AzureWebJobsStorage__credential:     'managedidentity'
      AzureWebJobsStorage__clientId:       uai.properties.clientId
      AzureWebJobsStorage__blobServiceUri: storage.properties.primaryEndpoints.blob
      AzureWebJobsStorage__queueServiceUri: storage.properties.primaryEndpoints.queue

      // App Insights — AAD-authenticated ingestion via the UAI
      APPLICATIONINSIGHTS_CONNECTION_STRING:    appi.properties.ConnectionString
      APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'ClientId=${uai.properties.clientId};Authorization=AAD'

      // App configuration
      KEY_VAULT_NAME:        keyVaultName
      GRAPH_TENANT_ID:       graphTenantId
      MCP_ALLOWED_MAILBOXES: ''    // populate post-deploy; checked against VERIFIED caller UPN

      // Built-in MCP auth + OBO via managed-identity federated credential
      WEBSITE_AUTH_PRM_DEFAULT_WITH_SCOPES:   '${entraIdentifierUri}/Archive.Read'
      OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID: uai.properties.clientId
      WEBSITE_AUTH_AAD_ALLOWED_TENANTS:       graphTenantId
    }
  }

  // Easy Auth — fail-closed. Every request (except platform discovery routes)
  // must carry a valid Entra token for audience api://exchange-mcp.
  resource authSettings 'config' = {
    name: 'authsettingsV2'
    properties: {
      globalValidation: {
        requireAuthentication:       true
        unauthenticatedClientAction: 'Return401'
        redirectToProvider:          'azureactivedirectory'
      }
      httpSettings: {
        requireHttps: true
        routes:       { apiPrefix: '/.auth' }
        forwardProxy: { convention: 'NoProxy' }
      }
      identityProviders: {
        azureActiveDirectory: {
          enabled: true
          registration: {
            openIdIssuer:            '${az.environment().authentication.loginEndpoint}${graphTenantId}/v2.0'
            clientId:                entraClientId
            clientSecretSettingName: 'OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID'
          }
          login: {
            loginParameters: [
              'scope=openid profile email ${entraIdentifierUri}/Archive.Read'
            ]
          }
          validation: {
            jwtClaimChecks: {}
            // Three audience forms, all legitimate depending on how the token was
            // requested: the legacy api:// URI, the endpoint-URL identifier URI
            // (what Claude Desktop's RFC 8707 flow produces — the scope's URI
            // prefix becomes the aud), and the raw client ID (v2 tokens when
            // requestedAccessTokenVersion=2).
            allowedAudiences: [
              entraIdentifierUri
              'https://${funcName}.azurewebsites.net/runtime/webhooks/mcp'
              entraClientId
              'api://${entraClientId}'
            ]
            defaultAuthorizationPolicy: {
              allowedPrincipals:   {}
              allowedApplications: [entraClientId]
            }
          }
          isAutoProvisioned: false
        }
      }
      login: {
        routes: { logoutEndpoint: '/.auth/logout' }
        tokenStore: {
          enabled:                     true
          tokenRefreshExtensionHours:  72
          fileSystem:                  {}
          azureBlobStorage:            {}
        }
        preserveUrlFragmentsForLogins: false
        allowedExternalRedirectUrls:   []
        cookieExpiration: {
          convention:        'FixedTime'
          timeToExpiration:  '08:00:00'
        }
        nonce: {
          validateNonce:           true
          nonceExpirationInterval: '00:05:00'
        }
      }
      platform: {
        enabled:        true
        runtimeVersion: '~1'
      }
    }
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────
output functionAppName        string = funcApp.name
output functionAppPrincipalId string = funcApp.identity.principalId   // system MI → KV grant
output functionAppHostname    string = funcApp.properties.defaultHostName
output uaiClientId            string = uai.properties.clientId
output uaiPrincipalId         string = uai.properties.principalId     // FIC subject
output lawId                  string = law.id                         // KV diagnostic sink
