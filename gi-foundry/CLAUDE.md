# GI Partners — Azure AI Foundry Project
## Claude Code Project Plan

> **Purpose:** This CLAUDE.md is the authoritative task list and architecture reference for
> building the GI Partners Azure AI Foundry environment. Work through phases in order.
> Each phase has a clear acceptance criterion before moving on.

---

## Repo Layout (target state)

```
gi-foundry/
├── CLAUDE.md                          <- this file
├── version.md                         <- version tracking for all versioned files
|
├── foundry-iac/                       <- Phase 1: Bicep IaC
│   ├── main.bicep
│   ├── modules/
│   │   ├── openai.bicep
│   │   ├── foundry.bicep
│   │   ├── keyvault.bicep
│   │   └── network.bicep
│   ├── parameters/
│   │   ├── prod.bicepparam
│   │   └── dev.bicepparam
│   └── .github/
│       └── workflows/
│           └── bicep-validate.yml
|
├── scripts/                           <- Phase 2: PowerShell scripts
│   ├── Deploy-Foundry.ps1
│   ├── Rotate-OAIKey.ps1
│   └── Rotate-MCPClientSecret.ps1
|
├── universal-print/                   <- Phase 5: Universal Print automation
│   ├── Register-Printers.ps1
│   ├── Set-PrinterShares.ps1
│   ├── printers.csv                   <- template (populate per-site)
│   └── README.md
|
└── exchange-mcp/                      <- Phase 3+4: Exchange Online MCP (Azure Functions)
    ├── function_app.py                <- MCP tool definitions (Python v2 model)
    ├── host.json                      <- Functions host config (MCP extension enabled)
    ├── local.settings.json            <- Local dev settings (gitignored)
    ├── requirements.txt               <- Python dependencies
    ├── azure.yaml                     <- azd service definition
    ├── infra/                         <- azd-managed Bicep for Function App resources
    │   ├── main.bicep
    │   ├── main.parameters.json
    │   └── modules/
    │       ├── functionapp.bicep      <- Function App + App Service Plan + Storage
    │       ├── apicenter.bicep        <- Azure API Center resource + MCP registration
    │       └── roleassignments.bicep  <- MI grants: Graph Mail.Read + KV Secrets User
    ├── .vscode/
    │   └── mcp.json                   <- Local and remote server entries for VS Code testing
    ├── Register-MCPInApiCenter.ps1    <- PS7: idempotent API Center registration/update
    └── README.md
```

---

## Working Rules

- **PowerShell version:** Always target PowerShell 7 (`#Requires -Version 7.0`).
- **Secrets:** Never log, echo, or write secrets to disk in plaintext. Always route to Key Vault.
- **Error handling:** All PS scripts use `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`. All TS uses try/catch with structured error returns.
- **version.md:** Update the version table in `version.md` any time a file receives a version bump. No release without it.
- **WhatIf support:** Every destructive PowerShell script must support `[CmdletBinding(SupportsShouldProcess)]` and `$PSCmdlet.ShouldProcess`.
- **Comments:** Every function and every Bicep resource block gets a single-line `# purpose` comment.

---

## Phase 1 — Bicep IaC (foundry-iac/)

**Goal:** A fully parameterized, modular Bicep stack that deploys the entire Foundry
environment from scratch into a clean resource group. Must pass `what-if` before any
prod deployment.

### Task 1.1 — network.bicep
Create `foundry-iac/modules/network.bicep`.

**Spec:**
- Virtual Network: `vnet-gipartners-ai-prod`, address space `10.100.0.0/16`
- Two subnets:
  - `snet-private-endpoints` — `10.100.1.0/24`, `privateEndpointNetworkPolicies = Disabled`
  - `snet-foundry-managed` — `10.100.2.0/24`, delegated to `Microsoft.MachineLearningServices/workspaces`
- Four Private DNS Zones (linked to VNet, `registrationEnabled = false`):
  - `privatelink.openai.azure.com`
  - `privatelink.vaultcore.azure.net`
  - `privatelink.blob.core.windows.net`
  - `privatelink.api.azureml.ms`
- Storage Account: `sagipartnersaiprod`, Standard LRS, `publicNetworkAccess = Disabled`, TLS 1.2 minimum, no public blob access
- **Outputs:** `privateEndpointSubnetId`, `oaiPrivateDnsZoneId`, `kvPrivateDnsZoneId`, `storageAccountId`
- **Params:** `location`, `baseName`, `environment`, `tags`

**Acceptance:** `az bicep build --file network.bicep` produces no errors. `what-if` against an empty RG shows only Creates.

---

### Task 1.2 — keyvault.bicep
Create `foundry-iac/modules/keyvault.bicep`.

**Spec:**
- Key Vault: `kv-gipartners-ai-{environment}`, RBAC auth model (not vault access policies)
- `enableSoftDelete = true`, `softDeleteRetentionInDays = 90`
- `enablePurgeProtection = true`
- `publicNetworkAccess = Disabled`
- Private endpoint on `snet-private-endpoints` with DNS zone group pointing to `privatelink.vaultcore.azure.net`
- RBAC assignment: IT Admin group object ID → `Key Vault Secrets Officer` on the vault scope
- **Outputs:** `keyVaultId`, `keyVaultName`, `keyVaultUri`
- **Params:** `location`, `baseName`, `environment`, `tags`, `subnetId`, `privateDnsZoneId`, `itAdminGroupObjectId`

**Acceptance:** No Bicep build errors. Vault created with correct soft-delete settings confirmed via `az keyvault show`.

---

### Task 1.3 — openai.bicep
Create `foundry-iac/modules/openai.bicep`.

**Spec:**
- Cognitive Services account: `oai-gipartners-{environment}`, kind `OpenAI`, sku `S0`
- `customSubDomainName = gipartners-oai`
- `publicNetworkAccess = Disabled`, `networkAcls.defaultAction = Deny`
- System-assigned managed identity
- Three model deployments (use `@batchSize(1)` to prevent capacity race):
  - `gpt-4o-prod` — model `gpt-4o` version `2024-11-20`, capacity = `gpt4oTpmK` param (default 150)
  - `embed-large-prod` — model `text-embedding-3-large` version `1`, capacity 350
  - `gpt-4o-mini-prod` — model `gpt-4o-mini` version `2024-07-18`, capacity 500
- Private endpoint + DNS zone group on `privatelink.openai.azure.com`
- After deploy: store `listKeys().key1` into Key Vault secret `oai-key1-current` via a `Microsoft.KeyVault/vaults/secrets` resource (reference the KV by name param)
- **Outputs:** `openAiResourceId`, `endpoint`
- **Params:** `location`, `baseName`, `environment`, `tags`, `subnetId`, `privateDnsZoneId`, `gpt4oTpmK`, `keyVaultName`

**Acceptance:** Build clean. `az cognitiveservices account deployment list` shows 3 deployments after apply.

---

### Task 1.4 — foundry.bicep
Create `foundry-iac/modules/foundry.bicep`.

**Spec:**
- Hub resource: `hub-gipartners-ai-{environment}`, kind `Hub`, system-assigned MI
- `managedNetwork.isolationMode` = `AllowOnlyApprovedOutbound` when `enableManagedVnet = true`, else `Disabled`
- Key Vault and Storage Account attached via `keyVault` and `storageAccount` properties
- One connection resource on the Hub:
  - Name: `oai-gipartners-prod`
  - Category: `AzureOpenAI`, authType: `ApiKey`
  - `isSharedToAll = true`
  - `credentials.key` = `listKeys(openAiResourceId, '2023-05-01').key1`
  - metadata: `ApiType=Azure`, `ApiVersion=2024-10-21`, `ResourceId={openAiResourceId}`
- Project resource: `proj-gipartners-ai-{environment}`, kind `Project`, `hubResourceId = hub.id`
- **Outputs:** `hubName`, `hubId`, `projectId`
- **Params:** `location`, `baseName`, `environment`, `tags`, `enableManagedVnet`, `openAiResourceId`, `openAiEndpoint`, `keyVaultId`, `storageAccountId`

**Acceptance:** Hub appears in Azure AI Foundry portal. Project is visible under the Hub. Connection test passes in Foundry portal.

---

### Task 1.5 — main.bicep
Create `foundry-iac/main.bicep`.

**Spec:**
- `targetScope = 'resourceGroup'`
- Parameters: `environment` (default `prod`), `location` (default `resourceGroup().location`), `baseName` (default `gipartners`), `enableManagedVnet` (bool, default `true`), `itAdminGroupObjectId` (string, mandatory), `gpt4oTpmK` (int, default 150)
- Shared `tags` var: `{ Environment, Owner: 'IT-Infrastructure', CostCenter: 'IT-AI', ManagedBy: 'Bicep-IaC' }`
- Module chain in dependency order: `network` → `kv` → `openai` → `foundry`
- Pass outputs between modules (no hard-coded resource IDs)
- **Outputs:** `foundryHubName`, `openAiEndpoint`, `keyVaultUri`

**Acceptance:** `az deployment group validate` returns no errors against prod parameter file.

---

### Task 1.6 — Parameter files
Create both `foundry-iac/parameters/prod.bicepparam` and `dev.bicepparam`.

**prod values:**
```
environment         = 'prod'
location            = 'eastus2'
baseName            = 'gipartners'
enableManagedVnet   = true
itAdminGroupObjectId = '<placeholder — fill before deploy>'
gpt4oTpmK           = 150
```

**dev values:** same except `environment = 'dev'`, `enableManagedVnet = false`, `gpt4oTpmK = 30`

---

### Task 1.7 — bicep-validate.yml (GitHub Actions)
Create `.github/workflows/bicep-validate.yml` inside `foundry-iac/`.

**Spec:**
- Trigger: `pull_request`, paths `foundry-iac/**`
- Runner: `ubuntu-latest`
- Steps: `actions/checkout@v4` → `azure/login@v2` (secret `AZURE_CREDENTIALS`) → `az deployment group what-if` against `prod.bicepparam`
- The `AZURE_CREDENTIALS` service principal must be scoped to **Reader + Template Deployment Operator** only (document this in a comment in the workflow file)

---

## Phase 2 — PowerShell Scripts (scripts/)

**Goal:** Three production-ready PS7 scripts that can be run standalone or from the
Azure Automation Account. All support `-WhatIf`.

### Task 2.1 — Deploy-Foundry.ps1
Create `scripts/Deploy-Foundry.ps1`.

**Spec:**
- `#Requires -Version 7.0` and `-Modules Az.Accounts, Az.Resources`
- `[CmdletBinding(SupportsShouldProcess)]`
- Parameters: `Environment` (ValidateSet prod/dev/test, default prod)
- Pre-flight checks:
  1. Verify `Get-AzContext` is populated — throw if not logged in
  2. Create RG `rg-ai-foundry-{Environment}` in `eastus2` if it doesn't exist, with tags
  3. Register all 5 required providers if not already `Registered`:
     `Microsoft.CognitiveServices`, `Microsoft.MachineLearningServices`,
     `Microsoft.Authorization`, `Microsoft.Network`, `Microsoft.Storage`, `Microsoft.KeyVault`
- `Write-Log` helper: prefixes `[HH:mm:ss]` and tees to a timestamped log file in `./logs/`
- In WhatIf mode: run `New-AzResourceGroupDeployment -WhatIf`
- In normal mode: run full deployment, capture outputs, log them (no secrets in outputs)
- Final output: display `foundryHubName`, `openAiEndpoint`, `keyVaultUri`

---

### Task 2.2 — Rotate-OAIKey.ps1
Create `scripts/Rotate-OAIKey.ps1`.

**Spec:**
- `#Requires -Version 7.0`
- `[CmdletBinding(SupportsShouldProcess)]`
- Mandatory params: `ResourceGroup`, `OpenAIAccountName`, `KeyVaultName`, `FoundryHubName`
- Optional: `SubscriptionId` (defaults to current context)
- Two helper functions:
  - `Set-FoundryKeyVersion [Key1|Key2]` — updates the Foundry Hub AML connection credential to the specified key using `az ml connection update`
  - `Invoke-KeyRegenAndStore [Key1|Key2]` — calls ARM REST `regenerateKey` endpoint, waits 10 seconds, reads new value, writes to Key Vault secret `oai-{key1|key2}-current`. Never prints the key value.
- Six-phase rotation sequence with `Write-Log` at each phase:
  1. Switch Foundry → Key2
  2. `Start-Sleep 30` (propagation pause)
  3. Regenerate + store Key1
  4. Switch Foundry → Key1
  5. `Start-Sleep 30`
  6. Regenerate + store Key2
- Final summary: confirm active key is Key1, print KV secret names (not values)

---

### Task 2.3 — Rotate-MCPClientSecret.ps1
Create `scripts/Rotate-MCPClientSecret.ps1`.

**Spec:**
- `#Requires -Version 7.0`
- `[CmdletBinding(SupportsShouldProcess)]`
- Mandatory params: `AppObjectId`, `KeyVaultName`
- Uses `Connect-MgGraph -Scopes 'Application.ReadWrite.All'` (caller must already be authenticated)
- Steps:
  1. Add new password credential: `DisplayName = "MCP-Secret-{yyyy-MM}"`, `EndDateTime = +1 year`
  2. Store new secret in Key Vault secret `mcp-exchange-client-secret` (never print value)
  3. List all existing secrets on the app, sorted by `EndDateTime` descending
  4. Remove all except the 2 most recent
  5. Log what was removed
- Final message: "Rotation complete. Restart MCP server to pick up new secret."

---

## Phase 3 — Universal Print (universal-print/)

**Goal:** Idempotent PS7 scripts that can register printers and manage shares from a CSV.
Safe to re-run — skips already-registered/shared items.

### Task 3.1 — printers.csv template
Create `universal-print/printers.csv`.

**Columns:** `PrinterDisplayName`, `ShareName`, `GroupName`, `Office`, `Floor`

Populate with 3 placeholder rows to illustrate the format:
```
HP LaserJet 4200 (SF3),SF-3F-HP4200,GRP-SF-Office,San Francisco,3
Konica Minolta C227 (NY),NY-2F-KM-C227,GRP-NY-Office,New York,2
Ricoh MP C3004 (LA),LA-1F-Ricoh-C3004,GRP-LA-Office,Los Angeles,1
```

---

### Task 3.2 — Register-Printers.ps1
Create `universal-print/Register-Printers.ps1`.

**Spec:**
- `#Requires -Version 7.0`
- `[CmdletBinding(SupportsShouldProcess)]`
- Must be run **on the connector host machine** (document this in comment header)
- Scope: `Printer.ReadWrite.All`
- Logic:
  - Accept optional `-PrinterName` param to register a single printer (default: all)
  - Fetch existing registered printers to skip duplicates
  - For each printer visible to the connector: if not already registered, call `New-MgPrint` equivalent
  - `Write-Log` every registration attempt with success/skip/fail status
- Include a `Test-ConnectorInstalled` helper that checks for the `UniversalPrintConnector` Windows service and throws a helpful error if absent

---

### Task 3.3 — Set-PrinterShares.ps1
Create `universal-print/Set-PrinterShares.ps1`.

**Spec:**
- `#Requires -Version 7.0`
- `[CmdletBinding(SupportsShouldProcess)]`
- Param: `-CsvPath` (default `.\printers.csv`)
- Scopes: `Printer.ReadWrite.All`, `PrinterShare.ReadWrite.All`, `Group.Read.All`
- Per-row logic (idempotent — skip if share already exists with matching name):
  1. Look up printer by `PrinterDisplayName` — warn and skip if not found
  2. Look up share by `ShareName` — create if absent, skip if present
  3. Look up group by `GroupName` — warn and skip if not found
  4. Add group to share allowed groups if not already assigned
- Summary at end: `{n} shares created, {n} skipped, {n} errors`

---

### Task 3.4 — universal-print/README.md
Document:
- Prerequisites (licenses, connector install, Printer Administrator role)
- How to populate `printers.csv`
- Run order: Register-Printers.ps1 first, then Set-PrinterShares.ps1
- Troubleshooting table (5 common issues from the tutorial)

---

## Phase 3 — Exchange Online MCP: Entra App Registration (exchange-mcp/)

**Goal:** Create and configure the Entra ID app registration that the Azure Function will
use to authenticate against Microsoft Graph. This is done once before any code is written.

### Task 3.1 — Entra App Registration (PowerShell)

Run the following once as a Global Administrator. Record outputs into Key Reference Values.

**Spec:**
- Create app registration: `DisplayName = 'MCP-ExchangeOnlineArchive'`, `SignInAudience = AzureADMyOrg`
- Add Graph application permissions:
  - `Mail.Read` (id `570282fd-fa5c-430d-a7fd-fc8dc98a9dca`, type `Role`)
  - `Mail.ReadBasic.All` (id `7b9103a5-4610-446b-9670-80643382c1fa`, type `Role`)
  - `User.Read.All` (id `df021288-bdef-4463-88db-98f22de89214`, type `Role`)
- Create a client secret: `DisplayName = 'MCP-Initial'`, `EndDateTime = +1 year`
- Store secret immediately into Key Vault secret `mcp-exchange-client-secret` — never echo to console
- Store app client ID into Key Vault secret `mcp-entra-client-id`
- Create service principal: `New-MgServicePrincipal -AppId $app.AppId`
- Grant admin consent via portal (document the manual step): Entra portal -> App registrations -> API permissions -> Grant admin consent

**Acceptance:** `Test-ApplicationAccessPolicy` returns `AccessCheckResult: Granted` for a test mailbox.

---

### Task 3.2 — ApplicationAccessPolicy (Exchange Online PowerShell)

Restrict the Graph app to only approved mailboxes — prevents lateral movement if the app is compromised.

**Spec:**
- Connect via `Connect-ExchangeOnline`
- Create policy scoped to mail-enabled security group `MCP-ArchiveAccess@gipartners.com`:
  ```
  New-ApplicationAccessPolicy
    -AppId <mcp-app-client-id>
    -PolicyScopeGroupId MCP-ArchiveAccess@gipartners.com
    -AccessRight RestrictAccess
    -Description 'Restrict Exchange MCP app to approved archive mailboxes only'
  ```
- Verify with `Test-ApplicationAccessPolicy` against at least one in-scope and one out-of-scope mailbox

**Acceptance:** Out-of-scope mailbox returns `AccessCheckResult: Denied`.

---

## Phase 4 — Exchange Online MCP: Azure Functions + API Center (exchange-mcp/)

**Goal:** A cloud-hosted, serverless MCP server on Azure Functions (Python v2 model) that
exposes three Exchange archive tools, authenticated via Entra managed identity, registered
in Azure API Center for Foundry discoverability, and connectable from Claude Desktop.

### Architecture

```
Claude Desktop / Foundry Agent
        |
        | HTTPS + mcp_extension system key
        v
Azure Functions App  (exchange-mcp)
  /runtime/webhooks/mcp
        |
        | DefaultAzureCredential (system-assigned MI)
        v
Microsoft Graph API  ->  Exchange Online Archive
        |
        | (also)
        v
Azure Key Vault  (secrets at startup)
        |
        v
Azure API Center  (organizational tool catalog — Foundry discoverability)
```

**Key properties vs. the old NSSM Windows service approach:**
- No local process to manage — scales to zero, bursts automatically
- System-assigned Managed Identity eliminates stored client secrets in prod
- Registered in API Center = visible in Foundry portal Tools catalog with one click
- `azd up` handles all infrastructure and code deployment in one command
- Logs in Azure Monitor / Application Insights, not local text files

---

### Task 4.1 — requirements.txt
Create `exchange-mcp/requirements.txt`.

**Spec — exact packages:**
```
azure-functions>=1.21.0
azure-identity>=1.17.0
msgraph-sdk>=1.5.0
azure-keyvault-secrets>=4.8.0
```

Note: `azure-functions` 1.21+ includes the MCP trigger extension support for Python.
Do not pin to exact versions — use `>=` so `azd` can resolve compatible sets.

---

### Task 4.2 — host.json
Create `exchange-mcp/host.json`.

**Spec:**
```json
{
  "version": "2.0",
  "logging": {
    "applicationInsights": {
      "samplingSettings": {
        "isEnabled": true,
        "excludedTypes": "Request"
      }
    }
  },
  "extensionBundle": {
    "id": "Microsoft.Azure.Functions.ExtensionBundle",
    "version": "[4.*, 5.0.0)"
  }
}
```

The extension bundle at version 4.x includes the MCP trigger. Do not downgrade below 4.x.

---

### Task 4.3 — azure.yaml
Create `exchange-mcp/azure.yaml`.

**Spec:**
```yaml
name: exchange-archive-mcp
services:
  exchange-mcp:
    project: .
    language: python
    host: function
```

This tells `azd` the service name, language, and that it deploys to Azure Functions.

---

### Task 4.4 — infra/main.bicep and main.parameters.json
Create the azd infrastructure entry point at `exchange-mcp/infra/main.bicep`.

**Spec:**
- `targetScope = 'subscription'` (azd convention — creates RG then delegates)
- Parameters: `environmentName` (string), `location` (string), `keyVaultName` (string, the existing KV from Phase 1), `apiCenterName` (string, default `apic-gipartners-mcp`)
- Creates resource group: `rg-exchange-mcp-${environmentName}`
- Calls three modules: `functionapp.bicep`, `apicenter.bicep`, `roleassignments.bicep`
- Outputs: `functionAppName`, `functionAppHostname`, `mcpEndpoint` (`https://{hostname}/runtime/webhooks/mcp`)

Create `exchange-mcp/infra/main.parameters.json`:
```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "environmentName": { "value": "${AZURE_ENV_NAME}" },
    "location":        { "value": "${AZURE_LOCATION}" },
    "keyVaultName":    { "value": "${KEY_VAULT_NAME}" }
  }
}
```

The `${...}` tokens are substituted by `azd` from `.azure/{env}/.env` at deploy time.

---

### Task 4.5 — infra/modules/functionapp.bicep
Create `exchange-mcp/infra/modules/functionapp.bicep`.

**Spec:**
- App Service Plan: `asp-exchange-mcp-{env}`, kind `linux`, sku `Y1` (Consumption — scale to zero)
- Storage Account for Functions runtime: `saexmcp{env}`, Standard LRS, TLS 1.2, no public blob
- Application Insights: `appi-exchange-mcp-{env}`, linked to Log Analytics workspace
- Function App: `func-exchange-mcp-{env}`
  - `kind = 'functionapp,linux'`
  - `properties.reserved = true` (required for Linux)
  - `siteConfig.pythonVersion = '3.11'`
  - `siteConfig.appSettings`:
    - `AzureWebJobsStorage` — storage connection string
    - `FUNCTIONS_EXTENSION_VERSION = '~4'`
    - `FUNCTIONS_WORKER_RUNTIME = 'python'`
    - `APPLICATIONINSIGHTS_CONNECTION_STRING` — from App Insights resource
    - `KEY_VAULT_NAME` — from param (the shared KV from Phase 1)
    - `GRAPH_TENANT_ID` — from param
    - `MCP_ALLOWED_MAILBOXES` — comma-separated UPNs allowed (defense-in-depth beyond ApplicationAccessPolicy)
  - System-assigned managed identity: `identity.type = 'SystemAssigned'`
  - `publicNetworkAccess = 'Enabled'` — Functions MCP endpoint must be publicly reachable for Foundry Agent Service
- **Outputs:** `functionAppName`, `functionAppPrincipalId`, `functionAppHostname`

---

### Task 4.6 — infra/modules/roleassignments.bicep
Create `exchange-mcp/infra/modules/roleassignments.bicep`.

**Spec — grant the Function App's managed identity:**
- `Key Vault Secrets User` on the existing Key Vault (by resource ID param) — to read secrets at startup
- No direct Graph API role assignment needed — Graph app permissions are granted to the Entra app registration from Phase 3, not to the MI. The Function App authenticates to Graph using the Entra app's client credentials retrieved from Key Vault, not its own MI directly.

> **Note:** In a future hardening pass, the Entra app registration can be replaced with
> Workload Identity Federation so the Function App MI token is exchanged directly for
> Graph tokens — eliminating the stored client secret entirely. Document this as a
> follow-on task in the README.

---

### Task 4.7 — infra/modules/apicenter.bicep
Create `exchange-mcp/infra/modules/apicenter.bicep`.

**Spec:**
- API Center resource: `apic-gipartners-mcp`, Standard tier
- This resource becomes the organizational tool catalog visible in Foundry portal
- **Outputs:** `apiCenterName`, `apiCenterResourceId`

Note: The actual API registration (registering the MCP server as an asset) is done
post-deploy via `Register-MCPInApiCenter.ps1` (Task 4.9), not in Bicep, because the
Function App hostname isn't known until after first deploy.

---

### Task 4.8 — function_app.py
Create `exchange-mcp/function_app.py`.

This is the core of the MCP server. Uses the Azure Functions Python v2 programming model
with the MCP trigger.

**Spec:**

**Imports and app init:**
```python
import azure.functions as func
import logging
import json
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient
from msgraph import GraphServiceClient
from msgraph.generated.users.item.mail_folders.item.messages.messages_request_builder import (
    MessagesRequestBuilder,
)
import os

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)
```

**Startup — secret retrieval:**
- At module load, read `KEY_VAULT_NAME` from env. If present, use `DefaultAzureCredential` + `SecretClient` to retrieve `mcp-entra-client-id` and `mcp-exchange-client-secret`. Store in module-level variables.
- If `KEY_VAULT_NAME` is absent (local dev), fall back to `ENTRA_CLIENT_ID` and `ENTRA_CLIENT_SECRET` env vars directly.
- Build a `GraphServiceClient` using `ClientSecretCredential(tenant_id, client_id, client_secret)`.
- Log "Graph client initialized" (never log credential values).

**Tool 1 — search_archive_mail:**
```python
@app.mcp_tool(name="search_archive_mail",
              description="Search Exchange Online archive mailbox for messages matching a query.")
async def search_archive_mail(tool_context: func.McpToolContext) -> str:
```
- Extract `user_email`, `query`, `top` (default 20, max 50) from `tool_context.arguments`
- Call `graph.users.by_user_id(user_email).mail_folders.by_mail_folder_id('archive').messages.get()`
  with request config: `$search="{query}"`, `$top={top}`, `$select=id,subject,from,receivedDateTime,bodyPreview,hasAttachments`
- Return JSON string: array of `{id, subject, from, from_name, received, preview (300 chars), attachments}`
- Wrap entire body in try/except — on error return `json.dumps({"error": True, "message": str(e)})`

**Tool 2 — get_mail_by_date_range:**
```python
@app.mcp_tool(name="get_mail_by_date_range",
              description="Retrieve archive messages received within a date range. Dates must be ISO 8601 (YYYY-MM-DD).")
async def get_mail_by_date_range(tool_context: func.McpToolContext) -> str:
```
- Extract `user_email`, `start_date`, `end_date`, optional `from_address`, `top` (1–100, default 50)
- Validate dates: parse with `datetime.fromisoformat`, raise `ValueError` if invalid or start > end
- Build OData filter: `receivedDateTime ge {start}T00:00:00Z and receivedDateTime le {end}T23:59:59Z`
- If `from_address` present: append `and from/emailAddress/address eq '{escaped}'` (escape `'` as `''`)
- `$orderby=receivedDateTime desc`, `$select=id,subject,from,receivedDateTime,bodyPreview,hasAttachments,importance`
- Return JSON: `{messages: [...], count: n, filter: "...", truncated: bool}`

**Tool 3 — list_archive_folders:**
```python
@app.mcp_tool(name="list_archive_folders",
              description="List the folder hierarchy of a user's Exchange Online archive mailbox.")
async def list_archive_folders(tool_context: func.McpToolContext) -> str:
```
- Extract `user_email`, `max_depth` (1–5, default 3)
- Get root archive folder: `graph.users.by_user_id(user_email).mail_folders.by_mail_folder_id('archive').get()`
- Implement async recursive `_fetch_children(user_email, folder_id, depth, max_depth)`:
  - Returns `[]` when `depth >= max_depth`
  - Calls `.child_folders.get()` with `$select=id,displayName,totalItemCount,unreadItemCount&$top=50`
  - Recurses for each child
  - Returns list of `{id, display_name, message_count, unread_count, child_folders?}`
- Return JSON: `{hierarchy: {...}, total_messages: n, max_depth_traversed: n}`

**Allowed mailbox guard (defense-in-depth):**
- At the top of each tool handler, check `user_email` against `MCP_ALLOWED_MAILBOXES` env var (comma-separated)
- If the env var is set and `user_email` is not in the list, return `{"error": True, "message": "Mailbox not in approved list"}` — do not raise an exception (keeps MCP response shape valid)

---

### Task 4.9 — Register-MCPInApiCenter.ps1
Create `exchange-mcp/Register-MCPInApiCenter.ps1`.

**Spec:**
- `#Requires -Version 7.0`
- `[CmdletBinding(SupportsShouldProcess)]`
- Params: `ApiCenterName`, `ResourceGroup`, `FunctionAppName`, `SubscriptionId`
- Idempotent: check if an API named `exchange-archive-mcp` already exists in API Center; update if present, create if absent
- Steps:
  1. Derive MCP endpoint: `https://{FunctionAppName}.azurewebsites.net/runtime/webhooks/mcp`
  2. Get `mcp_extension` system key from Function App via ARM: `Invoke-RestMethod` to `listKeys` action
  3. Upsert API definition in API Center:
     - Title: `Exchange Online Archive MCP`
     - Description: `MCP server providing Claude and Foundry agents access to Exchange Online archive mailboxes`
     - Type: `mcp`
     - Lifecycle stage: `production`
  4. Upsert deployment entry with the live endpoint URL
  5. Configure authentication entry: `apiKey`, key name `x-functions-key`
  6. Store the `mcp_extension` system key into Key Vault secret `mcp-functions-extension-key` — never echo
- Final output: API Center portal URL to the registered MCP server

**Acceptance:** MCP server appears in Foundry portal under Tools catalog after running this script.

---

### Task 4.10 — .vscode/mcp.json
Create `exchange-mcp/.vscode/mcp.json`.

**Spec:**
```json
{
  "servers": {
    "exchange-mcp-local": {
      "type": "stdio",
      "command": "func",
      "args": ["start"],
      "cwd": "${workspaceFolder}",
      "env": {
        "ENTRA_CLIENT_ID": "${input:clientId}",
        "ENTRA_CLIENT_SECRET": "${input:clientSecret}",
        "ENTRA_TENANT_ID": "${input:tenantId}"
      }
    },
    "exchange-mcp-remote": {
      "type": "http",
      "url": "https://${input:funcAppName}.azurewebsites.net/runtime/webhooks/mcp",
      "headers": {
        "x-functions-key": "${input:mcpExtensionKey}"
      }
    }
  }
}
```

This file lets developers switch between local (`func start`) and deployed remote during testing without editing config.

---

### Task 4.11 — exchange-mcp/README.md
Document:

**Prerequisites:**
- Python 3.11+
- Azure Functions Core Tools v4.x (`npm install -g azure-functions-core-tools@4`)
- Azure Developer CLI (`winget install Microsoft.Azd`)
- Phase 3 Entra app registration complete; secrets in Key Vault

**Local development:**
```bash
cd exchange-mcp
pip install -r requirements.txt
# Copy local.settings.json.example to local.settings.json and fill values
func start
# Test with MCP Inspector:
npx @modelcontextprotocol/inspector http://localhost:7071/runtime/webhooks/mcp
```

**Deploy to Azure:**
```bash
azd auth login
azd up   # provisions infra + deploys code; prompts for env name and location
```

**Post-deploy:**
```powershell
.\Register-MCPInApiCenter.ps1 -ApiCenterName apic-gipartners-mcp `
    -ResourceGroup rg-exchange-mcp-prod `
    -FunctionAppName <output from azd up> `
    -SubscriptionId <sub-id>
```

**Connect Claude Desktop (direct, bypassing Foundry):**
```json
{
  "mcpServers": {
    "exchange-archive": {
      "type": "http",
      "url": "https://<funcappname>.azurewebsites.net/runtime/webhooks/mcp",
      "headers": { "x-functions-key": "<mcp_extension_system_key>" }
    }
  }
}
```

**Connect via Foundry portal:**
Foundry portal -> project -> Build -> Tools -> Add tool -> Model Context Protocol
(or browse organizational catalog if API Center is configured)

**Example tool calls:**
```json
{ "name": "list_archive_folders", "arguments": { "user_email": "jsmith@gipartners.com" } }
{ "name": "search_archive_mail",  "arguments": { "user_email": "jsmith@gipartners.com", "query": "TechCore" } }
{ "name": "get_mail_by_date_range", "arguments": { "user_email": "jsmith@gipartners.com", "start_date": "2023-07-01", "end_date": "2023-09-30" } }
```

**Security notes:**
- ApplicationAccessPolicy restricts mailbox scope (Phase 3 Task 3.2)
- `MCP_ALLOWED_MAILBOXES` app setting adds a second layer in the function code
- Client secret is in Key Vault; MI reads it at cold start — no secret in app settings
- Future: replace client secret with Workload Identity Federation (MI -> Graph token exchange)

---

## Phase 5 — Universal Print (universal-print/)

**Goal:** Idempotent PS7 scripts that can register printers and manage shares from a CSV.
Safe to re-run — skips already-registered/shared items. (Spec unchanged from original plan.)

### Task 5.1 — printers.csv, Register-Printers.ps1, Set-PrinterShares.ps1, README.md
See original Phase 3 task specs — content is identical, only the phase number changed.

---

## Phase 6 — version.md (repo root)

Create `version.md` in the repo root tracking all versioned files.

**Initial table:**

| File | Version | Description |
|------|---------|-------------|
| foundry-iac/main.bicep | 1.0.0 | Orchestration entry point |
| foundry-iac/modules/network.bicep | 1.0.0 | VNet, DNS zones, storage |
| foundry-iac/modules/keyvault.bicep | 1.0.0 | Key Vault with private endpoint |
| foundry-iac/modules/openai.bicep | 1.0.0 | Azure OpenAI + model deployments |
| foundry-iac/modules/foundry.bicep | 1.0.0 | Foundry Hub, Project, OAI connection |
| foundry-iac/parameters/prod.bicepparam | 1.0.0 | Production parameters |
| foundry-iac/parameters/dev.bicepparam | 1.0.0 | Dev/test parameters |
| scripts/Deploy-Foundry.ps1 | 1.0.0 | Deployment driver with pre-flight |
| scripts/Rotate-OAIKey.ps1 | 1.0.0 | Zero-downtime OpenAI key rotation |
| scripts/Rotate-MCPClientSecret.ps1 | 1.0.0 | MCP Entra app secret rotation |
| exchange-mcp/function_app.py | 1.0.0 | MCP tools: search, date range, folders |
| exchange-mcp/host.json | 1.0.0 | Functions host config |
| exchange-mcp/requirements.txt | 1.0.0 | Python dependencies |
| exchange-mcp/azure.yaml | 1.0.0 | azd service definition |
| exchange-mcp/infra/main.bicep | 1.0.0 | azd infrastructure entry point |
| exchange-mcp/infra/modules/functionapp.bicep | 1.0.0 | Function App + App Service Plan |
| exchange-mcp/infra/modules/apicenter.bicep | 1.0.0 | Azure API Center resource |
| exchange-mcp/infra/modules/roleassignments.bicep | 1.0.0 | MI role grants |
| exchange-mcp/Register-MCPInApiCenter.ps1 | 1.0.0 | Idempotent API Center registration |
| universal-print/Register-Printers.ps1 | 1.0.0 | Universal Print connector registration |
| universal-print/Set-PrinterShares.ps1 | 1.0.0 | Bulk share assignment from CSV |

---

## Key Reference Values (fill before deploying)

```
Tenant ID:                    <fill>
Subscription ID:              <fill>
IT Admin Group OID:           <fill>
MCP App Client ID:            <fill — from Phase 3 Task 3.1>
MCP App Object ID:            <fill — from Phase 3 Task 3.1, needed for secret rotation>
MCP-ArchiveAccess group UPN:  MCP-ArchiveAccess@gipartners.com  (create in Entra before Task 3.2)
Existing Foundry type:        <fill — Classic Hub or New Foundry resource, from az resource query>
Existing Foundry RG:          <fill>
```

---

## Phase Completion Checklist

- [ ] **Phase 1** — All 5 Bicep modules + main.bicep + both param files build clean and pass `what-if`
- [ ] **Phase 2** — All 3 PS scripts pass `-WhatIf` without errors; `Rotate-OAIKey.ps1` tested against dev OpenAI resource
- [ ] **Phase 3** — Entra app created; `Test-ApplicationAccessPolicy` returns Granted for in-scope mailbox, Denied for out-of-scope
- [ ] **Phase 4** — `azd up` succeeds; MCP Inspector hits live endpoint; all 3 tools return data; server visible in Foundry Tools catalog
- [ ] **Phase 5** — Universal Print scripts run idempotently; second run produces zero errors
- [ ] **Phase 6** — `version.md` reflects all files; no file lacks a version entry
