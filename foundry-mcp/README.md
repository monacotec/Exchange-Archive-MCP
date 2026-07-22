# exchange-mcp — Exchange Online Archive MCP Server

Cloud-hosted MCP server on Azure Functions (Python v2) that gives Claude and
Foundry agents read-only access to Exchange Online archive mailboxes at GI Partners.

## Architecture

```
Claude Desktop / Foundry Agent
    |  HTTPS + x-functions-key
    v
Azure Function App  (func-exchange-mcp-prod)
  /runtime/webhooks/mcp
    |  DefaultAzureCredential (system-assigned MI)
    v
Azure Key Vault  ->  client ID + secret  ->  Graph ClientSecretCredential
    v
Microsoft Graph API  ->  Exchange Online Archive
    v
Azure API Center  (organizational tool catalog — Foundry discoverability)
```

## Prerequisites

- Python 3.11+
- [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local):
  `npm install -g azure-functions-core-tools@4 --unsafe-perm true`
- [Azure Developer CLI](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd):
  `winget install Microsoft.Azd`
- Phase 3 Entra app registration complete (run `scripts/Register-EntraApp.ps1`)
- Phase 3 ApplicationAccessPolicy set (run `scripts/Set-ApplicationAccessPolicy.ps1`)

## Local Development

```bash
cd exchange-mcp

# Install dependencies
pip install -r requirements.txt

# Copy and fill local settings
cp local.settings.json.example local.settings.json
# Edit local.settings.json with your ENTRA_CLIENT_ID, ENTRA_CLIENT_SECRET, ENTRA_TENANT_ID

# Start the function locally
func start

# Test with MCP Inspector (in a second terminal)
npx @modelcontextprotocol/inspector http://localhost:7071/runtime/webhooks/mcp
```

## Deploy to Azure

```bash
# Authenticate
azd auth login

# First deploy — provisions infrastructure and deploys code
# Prompts for: environment name (e.g. prod), Azure location (e.g. eastus2)
# Set KEY_VAULT_NAME env var first:
export KEY_VAULT_NAME=kv-gipartners-ai-prod   # or $env:KEY_VAULT_NAME = '...' in PowerShell
azd up

# Re-deploy code only (no infra changes)
azd deploy
```

## Post-Deploy: Register in API Center

```powershell
.\Register-MCPInApiCenter.ps1 `
    -ApiCenterName apic-gipartners-mcp `
    -ResourceGroup rg-exchange-mcp-prod `
    -FunctionAppName func-exchange-mcp-prod `
    -FunctionAppResourceGroup rg-exchange-mcp-prod `
    -KeyVaultName kv-gipartners-ai-prod
```

## Connect Claude Desktop (direct)

Add to `%APPDATA%\Claude\claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "exchange-archive": {
      "type": "http",
      "url": "https://func-exchange-mcp-prod.azurewebsites.net/runtime/webhooks/mcp",
      "headers": {
        "x-functions-key": "<mcp_extension_system_key from Key Vault secret mcp-functions-extension-key>"
      }
    }
  }
}
```

## Connect via Foundry Portal

Foundry portal → your project → **Build** → **Tools** → **Add tool** → **Model Context Protocol**

If API Center is configured, browse the organizational catalog to find **Exchange Online Archive MCP**.

## Example Tool Calls

```json
{ "name": "list_archive_folders",
  "arguments": { "user_email": "jsmith@gipartners.com" } }

{ "name": "search_archive_mail",
  "arguments": { "user_email": "jsmith@gipartners.com", "query": "TechCore acquisition" } }

{ "name": "get_mail_by_date_range",
  "arguments": {
    "user_email":  "jsmith@gipartners.com",
    "start_date":  "2023-07-01",
    "end_date":    "2023-09-30",
    "from_address": "advisor@example.com"
  }
}
```

## Security Controls

| Layer | Mechanism |
|-------|-----------|
| Transport | HTTPS only; `httpsOnly = true` on Function App |
| Endpoint auth | `x-functions-key` MCP extension system key |
| Mailbox scope | Exchange `ApplicationAccessPolicy` → `MCP-ArchiveAccess` group |
| Defense-in-depth | `MCP_ALLOWED_MAILBOXES` app setting checked in code |
| Secrets | Managed identity reads from Key Vault at cold start; no secrets in app settings |
| Audit | All Graph reads logged via Application Insights + Exchange unified audit log |

## Post-Deploy: Set Allowed Mailboxes

After deploying, update the `MCP_ALLOWED_MAILBOXES` app setting:

```powershell
az functionapp config appsettings set `
  --name func-exchange-mcp-prod `
  --resource-group rg-exchange-mcp-prod `
  --settings "MCP_ALLOWED_MAILBOXES=jsmith@gipartners.com,mbrown@gipartners.com"
```

## Future: Workload Identity Federation (eliminate client secret)

Replace the stored client secret with Workload Identity Federation so the Function App
managed identity token is exchanged directly for a Graph token — no secret to rotate.
See: https://learn.microsoft.com/azure/active-directory/develop/workload-identity-federation
