# Version Tracking — gi-foundry

All versioned files are listed here. Update this table with every commit that bumps a file.
No release without a matching version.md entry.

## Current Versions

| File | Version | Description |
|------|---------|-------------|
| CLAUDE.md | 1.0.0 | Claude Code project plan |
| foundry-iac/main.bicep | 1.1.0 | Orchestration entry point |
| foundry-iac/modules/network.bicep | 1.0.0 | VNet, DNS zones, shared storage |
| foundry-iac/modules/keyvault.bicep | 1.0.0 | Key Vault with private endpoint |
| foundry-iac/modules/openai.bicep | 1.1.0 | Azure OpenAI + model deployments |
| foundry-iac/modules/foundry.bicep | 1.1.0 | Foundry Hub, Project, OAI connection |
| foundry-iac/parameters/prod.bicepparam | 1.0.0 | Production parameters |
| foundry-iac/parameters/dev.bicepparam | 1.0.0 | Dev/test parameters |
| foundry-iac/.github/workflows/bicep-validate.yml | 1.1.0 | GitHub Actions Bicep validation |
| scripts/Deploy-Foundry.ps1 | 1.0.0 | Deployment driver with pre-flight checks |
| scripts/Rotate-OAIKey.ps1 | 1.0.0 | Zero-downtime OpenAI key rotation |
| scripts/Rotate-MCPClientSecret.ps1 | 1.1.0 | MCP Entra app secret rotation |
| scripts/Register-EntraApp.ps1 | 1.1.0 | Phase 3 one-time Entra app setup |
| scripts/Set-ApplicationAccessPolicy.ps1 | 1.1.0 | Exchange mailbox scope restriction |
| exchange-mcp/function_app.py | 1.0.0 | MCP tools: search, date range, folders |
| exchange-mcp/host.json | 1.0.0 | Functions host config (extension bundle 4.x) |
| exchange-mcp/requirements.txt | 1.0.0 | Python dependencies |
| exchange-mcp/azure.yaml | 1.0.0 | azd service definition |
| exchange-mcp/infra/main.bicep | 1.0.0 | azd infrastructure entry point |
| exchange-mcp/infra/main.parameters.json | 1.0.0 | azd parameter tokens |
| exchange-mcp/infra/modules/functionapp.bicep | 1.1.0 | Function App + App Service Plan |
| exchange-mcp/infra/modules/apicenter.bicep | 1.0.0 | Azure API Center resource |
| exchange-mcp/infra/modules/roleassignments.bicep | 1.0.0 | MI Key Vault Secrets User grant |
| exchange-mcp/Register-MCPInApiCenter.ps1 | 1.0.0 | Idempotent API Center registration |
| universal-print/Register-Printers.ps1 | 1.0.0 | Universal Print connector registration |
| universal-print/Set-PrinterShares.ps1 | 1.0.0 | Bulk share assignment from CSV |

## Changelog

### 1.1.0 — 2026-07-02 (Day-Zero Hygiene Pass — see ../DAY-ZERO-HYGIENE.md)
- `openai.bicep`: removed `listKeys()` → Key Vault secret materialization (finding 6); `keyVaultName` param removed
- `foundry.bicep`: Hub OpenAI connection `ApiKey` → `AAD` keyless; `Cognitive Services OpenAI User` role assignments for Hub + Project MIs; `isSharedToAll` retained true (findings 13, 30)
- `main.bicep`: dropped `keyVaultName` wiring to openai module
- `bicep-validate.yml`: OIDC federated login replaces `AZURE_CREDENTIALS` secret; dropped `--result-format FullResourcePayloads` (findings 7, 12)
- `functionapp.bicep`: `allowSharedKeyAccess: false`; identity-based `AzureWebJobsStorage__accountName`; MI role assignments Blob Data Owner + Queue Data Contributor; auth-level cutover gate comment (finding 5)
- `Register-EntraApp.ps1`, `Set-ApplicationAccessPolicy.ps1`, `Rotate-MCPClientSecret.ps1`: guaranteed session disconnect via try/finally (findings 44–46); `-DisableWAM` on Exchange connect per PS7 convention
- `Rotate-MCPClientSecret.ps1`: `-RevokeOld` switch to close the rotation overlap window (finding 47)
- NOT changed: `Rotate-OAIKey.ps1` (findings 22/43) — superseded by keyless connection; fix or retire at keyless cutover verification

### 1.0.0 — 2026-05-23
- Initial project scaffold
- Phases 1–5 all files created per CLAUDE.md spec
- MCP server: Azure Functions Python v2 + Azure API Center (replaces NSSM Windows service)
