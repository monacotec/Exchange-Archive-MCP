// sqlhost.bicep — shared Azure SQL logical server for MCP data stores
// Version: 1.0.0
//
// ONE logical server, MANY databases: the archive index today, one database per
// MCP as they are built. Deployed on its own (Initialize-McpSqlHost.ps1), NOT as
// part of the function app's azd pipeline — this is shared infrastructure whose
// lifecycle is independent of any single MCP.
//
// Design decisions and why:
//   - ENTRA-ONLY AUTH (azureADOnlyAuthentication: true). No SQL logins, no
//     passwords to store or rotate, consistent with the keyless posture the
//     rest of this suite moved to. Access is granted per database as contained
//     users (see Initialize-McpSqlHost.ps1 §users).
//   - ALWAYS-ON TIER by default (Standard S0). Serverless auto-pause would make
//     the first connection after idle fail with 40613 and wait out a resume —
//     the exact "restart" behaviour this host must not have, with multiple
//     users connecting at unpredictable times.
//   - PUBLIC ENDPOINT + firewall allowlist. Simplest thing that works for
//     workstation clients and the Function App. If this ever holds anything
//     more sensitive than mail METADATA, move to a private endpoint.
//   - Databases are a parameter array so adding the next MCP's database is a
//     one-line change, not a new template.

@description('Azure region. Keep with the rest of the suite unless there is a reason not to.')
param location string = resourceGroup().location

@description('Logical server name (must be globally unique; becomes <name>.database.windows.net).')
param serverName string

@description('Databases to create on the server. Each: { name, sku, tier, capacity, maxSizeBytes }.')
param databases array = [
  {
    name: 'ArchiveIndex'
    sku: 'S0'
    tier: 'Standard'
    capacity: 10
    maxSizeBytes: 268435456000 // 250 GB (S0 ceiling)
  }
]

@description('Entra principal that owns the server (admin). Use a GROUP where possible so ownership survives staff changes.')
param adminLogin string

@description('Object id of the Entra admin principal.')
param adminObjectId string

@description('Kind of Entra admin principal.')
@allowed(['User', 'Group', 'Application'])
param adminPrincipalType string = 'Group'

@description('Client IP ranges allowed through the server firewall. Each: { name, startIp, endIp }.')
param clientFirewallRules array = []

@description('Allow Azure services (the Function App) to reach the server. Uses the 0.0.0.0 sentinel rule.')
param allowAzureServices bool = true

@description('Tags applied to every resource.')
param tags object = {}

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: serverName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    restrictOutboundNetworkAccess: 'Disabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: adminPrincipalType
      login: adminLogin
      sid: adminObjectId
      tenantId: tenant().tenantId
      // Entra-only: SQL authentication is refused outright, so there is no
      // password on this server to leak, rotate, or find in a connection string.
      azureADOnlyAuthentication: true
    }
  }
}

resource dbs 'Microsoft.Sql/servers/databases@2023-08-01-preview' = [for db in databases: {
  parent: sqlServer
  name: db.name
  location: location
  tags: tags
  sku: {
    name: db.sku
    tier: db.tier
    capacity: db.capacity
  }
  properties: {
    // CI_AS matches the LocalDB default the schema was developed against. All
    // text columns are NVARCHAR, so collation never costs us Unicode fidelity.
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: db.maxSizeBytes
    zoneRedundant: false
  }
}]

// 0.0.0.0-0.0.0.0 is the documented sentinel for "Azure services and resources"
// — it does NOT open the server to the internet.
resource allowAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = if (allowAzureServices) {
  parent: sqlServer
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource clientRules 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = [for rule in clientFirewallRules: {
  parent: sqlServer
  name: rule.name
  properties: {
    startIpAddress: rule.startIp
    endIpAddress: rule.endIp
  }
}]

output sqlServerName string = sqlServer.name
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlServerPrincipalId string = sqlServer.identity.principalId
output databaseNames array = [for (db, i) in databases: db.name]
