# version.md — Foundry MCP

Version table for the Foundry MCP only. The Local MCP tracks its own files in [`../local-mcp/version.md`](../local-mcp/version.md).

Rows carried over from `gi-foundry/version.md` when `exchange-mcp/` and the three MCP scripts moved here (2026-07-02). The `1.1.0` bumps are the Day-Zero Hygiene patches — see [`../DAY-ZERO-HYGIENE.md`](../DAY-ZERO-HYGIENE.md).

## Tracked files

| File | Version | Description |
|------|---------|-------------|
| `function_app.py` | 3.3.0 | Results add open_desktop_url (giparchive: handler link) alongside open_url; E2 archive_get_search_results; two-layer data path |
| `ediscovery.py` | 1.5.0 | giparchive_url() desktop-handler link; broadened folder columns + raw headers; owa_message_url(); one-case-per-caller; E2 exportReport flow |
| `desktop-handler/ArchiveOpen.csproj` | 1.0.0 | NEW — .NET 8 self-contained WinExe project for the giparchive: protocol handler |
| `desktop-handler/Program.cs` | 1.0.0 | NEW — validates Message-ID, Outlook COM AdvancedSearch (proptag 0x1035001F), Display, OWA fallback, logging |
| `desktop-handler/build.ps1` | 1.0.0 | NEW — dotnet publish self-contained single-file + optional Artifact Signing signtool sign/verify |
| `desktop-handler/register-dev.ps1` | 1.0.0 | NEW — HKCU giparchive: registration for local dev testing |
| `scripts/Initialize-ArtifactSigning.ps1` | 1.0.0 | NEW — provisions Artifact Signing (RP, account, identity-verifier role; Phase Profile: cert profile + signer role) |
| `host.json` | 2.1.0 | webhookAuthorizationLevel=Anonymous — atomic cutover: Easy Auth (fail-closed) ships in the same deploy |
| `requirements.txt` | 2.1.0 | azure-functions>=2.2.0 stable (2.x needs Python 3.13 — Requires-Python filters it from 3.11 builds) |
| `azure.yaml` | 1.0.0 | azd service definition |
| `infra/main.bicep` | 3.2.0 | Wires Log Analytics workspace ID into keyvault module (finding 14) |
| `infra/main.parameters.json` | 2.2.0 | Added KEY_VAULT_NAME, API_CENTER_NAME, DEPLOY_API_CENTER tokens |
| `infra/modules/functionapp.bicep` | 2.2.0 | Easy Auth allowedAudiences: endpoint-URL + client-ID forms added (AADSTS9010010 fix); lawId output; FC1; fail-closed |
| `scripts/Add-FederatedCredential.ps1` | 1.0.0 | NEW — links UAI to app reg (WIF); OBO runs secret-free |
| `scripts/Verify-Deployment.ps1` | 1.0.0 | NEW — post-deploy exit checks (indexing, key, gate, PRM) |
| `scripts/Complete-KvCutover.ps1` | 1.0.0 | NEW — verifies kv-exmcp-gi migration, soft-deletes kv-exmcp-m63g6qb2pp (2026-07-21 vault rename) |
| `scripts/Remove-FoundrySpike.ps1` | 1.0.0 | NEW — deletes spike Foundry account super-m11489gu-eastus2 + project, optional -Purge |
| `scripts/Set-ClaudeConnectorAuth.ps1` | 1.2.0 | Adds identifier-URI step (connector URL as RFC 8707 resource); diagnostics + `-GrantAdminConsent` |
| `scripts/Get-McpErrorTrace.ps1` | 1.0.3 | NEW — pulls App Insights exception behind a correlation_id via az rest (avoids broken az monitor extension) |
| `scripts/Test-EDiscoveryAppAccess.ps1` | 1.1.0 | NEW — app-only token roles + eDiscovery API replay; proved case-ownership is the app-only gate |
| `scripts/Get-EDiscoverySearchStatus.ps1` | 1.1.0 | NEW — reads an app-created search's estimate app-only; dumps all count fields + bound sources |
| `scripts/Get-EDiscoveryAlertConfig.ps1` | 1.0.0 | NEW — read-only inventory of alert policies/activity alerts watching eDiscovery, to scope MCP-only alert suppression (PS 5.1) |
| `scripts/Get-EDiscoveryAuditActor.ps1` | 1.1.0 | READ-ONLY; unified-audit FreeText query showing MCP eDiscovery actor/entity ("Exchange Archive MCP") for alert-tuning suppression key (PS 5.1) |
| `scripts/Test-OutlookArchiveOpen.ps1` | 1.2.0 | D0 spike (PASSED 2026-07-22): Outlook COM AdvancedSearch proves online-archive open by PR_INTERNET_MESSAGE_ID proptag 0x1035001F; validates giparchive: handler (local, PS 5.1) |
| `scripts/Test-ArchiveGraphAccess.ps1` | 1.2.1 | NEW — probes archive well-known names + /search/query with full paging and id-walk; produced the CLOSED verdict in docs/online-archive-graph-findings.md |
| `scripts/Get-ArchiveConfig.ps1` | 1.0.0 | NEW — PS 5.1-only EXO archive config read (AutoExpandingArchiveEnabled); PS7 WAM broker crashes on this machine |
| `scripts/Initialize-EDiscoveryAccess.ps1` | 1.0.0 | NEW — E0 prereqs: Graph app roles (eDiscovery.\*, Download.Read), Purview SP + eDiscovery Manager, standing case (PS 5.1) |
| `scripts/Invoke-EDiscoverySpike.ps1` | 1.1.0 | E0 spike PASSED 2026-07-22 (15 hits, ~90s): noncustodialSources bind is the source mechanism (inline additionalSources rejected) |
| `infra/modules/keyvault.bicep` | 0.3.0 | AuditEvent diagnostic setting → Log Analytics (finding 14); admin Secrets Officer grant |
| `infra/modules/apicenter.bicep` | 1.0.0 | Azure API Center resource |
| `Register-MCPInApiCenter.ps1` | 1.0.0 | Idempotent API Center registration |
| `scripts/Register-EntraApp.ps1` | 2.0.0 | Rewritten to rev-2 shared-app-reg / delegated-OBO design (updates app 9519ca68; exposes api://exchange-mcp Archive.Read; no application Roles) |
| `scripts/Set-ApplicationAccessPolicy.ps1` | 1.1.0 | Mailbox scope restriction; try/finally disconnect (day-zero task 5) |
| `scripts/Rotate-MCPClientSecret.ps1` | 1.1.0 | Secret rotation; `-RevokeOld` (day-zero tasks 5–6) |
| `README.md` | rev 2 | Pre-hardening draft; rewritten in FOUNDRY-MCP-PLAN Phase 5 |

## Release process

1. Bump the file's internal version header.
2. Update this table.
3. Tag: `foundry-mcp-vX.Y.Z`.
