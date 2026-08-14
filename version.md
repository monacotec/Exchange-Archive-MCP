# Version Tracking — Exchange Archive MCP (suite)

Single suite manifest per the house convention (one `version.md` at the repo root
listing every versioned file). The per-component `version.md` files
(`foundry-mcp/`, `local-mcp/`, `gi-foundry/`, `security-baseline/reference-impl/`)
are now **redirect stubs** pointing here — record version bumps in this file.

**Suite:** Rev 2.0 (security-gated). Merged 2026-08-03.

---

## Suite-level files

| File | Version | Notes |
|---|---|---|
| `README.md` | rev 2 | Suite overview (refreshed 2026-07-22) |
| `CHANGES.md` | — | Change history |
| `REMEDIATION-GUIDE.md` | — | 49-finding adversarially-verified remediation guide |
| `DAY-ZERO-HYGIENE.md` | — | Day-zero hygiene checklist (code patches applied; manual steps open) |
| `BUG-archive-export-failure.md` | — | Export-latency bug report (fixed in function_app 3.4.0) |
| `exchange-archive-mcp-online-archive-fix.md` | — | Original Graph-based online-archive fix notes; superseded by the eDiscovery data path but kept as cited rationale |
| `docs/` | — | Operational docs, timelines, briefs, runbooks |
| `plans/` | — | Build plans + decision records |
| `version.md` | 2.0.0 | This merged suite manifest |
| `.env.example` | 1.0.0 | Template for the root `.env` (archive-index SQL target); real `.env` is gitignored |

---

## foundry-mcp — cloud MCP (Azure Functions, eDiscovery data path)

Release: bump the file's internal version header → update its row here → tag `foundry-mcp-vX.Y.Z`.

| File | Version | Description |
|------|---------|-------------|
| `function_app.py` | 3.7.0 | Long-poll the async legs server-side (estimate/export ~90s in 5s steps) — rapid client re-polling plus think-time left the MCP connection idle past the front end's ~230s kill, dropping sessions mid-conversation. (3.6.1: audit payload embedded in trace message; 3.6.0: honest jump-link guidance) |
| `ediscovery.py` | 1.7.0 | ensure_export() dedupe cache (prewarm ↔ results converge on one export); specific download errors; giparchive_url(); one-case-per-caller |
| `desktop-handler/ArchiveOpen.csproj` | 1.1.0 | .NET 8 self-contained WinExe project for the giparchive: handler |
| `desktop-handler/Program.cs` | 1.1.0 | Message-ID validation, Outlook COM AdvancedSearch (proptag 0x1035001F) PER-STORE, Display, OWA fallback, logging |
| `desktop-handler/build.ps1` | 1.1.0 | dotnet publish single-file + optional Artifact Signing via the `sign` CLI (artifact-signing, azure-cli cred) + verify |
| `desktop-handler/Get-SigningTools.ps1` | 1.0.0 | Stages Microsoft's `sign` CLI into ./signtool-cli/ (repo path; EDR blocks the global tool store) |
| `desktop-handler/register-dev.ps1` | 1.0.0 | HKCU giparchive: registration for local dev testing |
| `host.json` | 2.2.0 | Extension bundle PINNED to exact [4.44.0] — the floating [4.*, 5.0.0) range silently adopted preview 4.46.0 on a host recycle (~post 2026-08-04), breaking tools/list for new MCP sessions ("no tools available"). Never float a preview bundle in prod. (2.1.0: webhookAuthorizationLevel=Anonymous — atomic Easy Auth cutover) |
| `requirements.txt` | 2.1.0 | azure-functions stable pin |
| `azure.yaml` | 1.0.0 | azd service definition |
| `infra/main.bicep` | 3.2.0 | Wires Log Analytics workspace ID into keyvault module (finding 14) |
| `infra/main.parameters.json` | 2.2.0 | KEY_VAULT_NAME, API_CENTER_NAME, DEPLOY_API_CENTER tokens |
| `infra/modules/functionapp.bicep` | 2.3.0 | alwaysReady http=1 (idle scale-to-zero broke connector connects — matches the live 2026-08-12 fix). (2.2.0: Easy Auth allowedAudiences endpoint-URL + client-ID forms; lawId output; FC1; fail-closed) |
| `infra/modules/keyvault.bicep` | 0.3.0 | AuditEvent diagnostic → Log Analytics (finding 14); admin Secrets Officer grant |
| `infra/modules/apicenter.bicep` | 1.0.0 | Azure API Center resource |
| `Register-MCPInApiCenter.ps1` | 1.0.0 | Idempotent API Center registration |
| `scripts/Register-EntraApp.ps1` | 2.0.0 | rev-2 shared-app-reg / delegated-OBO (app 9519ca68; api://exchange-mcp Archive.Read) |
| `scripts/Set-ApplicationAccessPolicy.ps1` | 1.1.0 | Mailbox scope restriction; try/finally disconnect |
| `scripts/Rotate-MCPClientSecret.ps1` | 1.2.0 | Secret rotation; `-RevokeOld` with KV-hint keeper match (same-day expiries made "newest" a coin flip); prod defaults baked in |
| `scripts/Add-FederatedCredential.ps1` | 1.0.0 | Links UAI to app reg (WIF); secret-free OBO |
| `scripts/Verify-Deployment.ps1` | 1.0.0 | Post-deploy exit checks (indexing, key, gate, PRM) |
| `scripts/Complete-KvCutover.ps1` | 1.0.0 | Verifies kv-exmcp-gi migration, soft-deletes old vault |
| `scripts/Remove-FoundrySpike.ps1` | 1.0.0 | Deletes spike Foundry account + project |
| `scripts/Set-ClaudeConnectorAuth.ps1` | 1.2.0 | Connector URL identifier-URI + web→public-client; `-GrantAdminConsent`; sign-in diagnostics |
| `scripts/Get-McpErrorTrace.ps1` | 1.0.3 | App Insights exception behind a correlation_id via az rest |
| `scripts/Get-McpUserActivity.ps1` | 1.3.0 | Per-user tool-call/error lookup: allowlist check, app state, telemetry sanity, v3.6.1 message-embedded audit JSON |
| `scripts/Get-McpSigninTrace.ps1` | 1.1.0 | Deploy/config history + raw request dump + Entra sign-in log per app (pre-tool-layer failures) |
| `scripts/Get-McpBundleHistory.ps1` | 1.1.0 | Live bundle version via /admin/host/status (az-tunneled) + trace history; caught the 4.44.0→4.46.0 drift |
| `scripts/Audit-AppPermissions.ps1` | 1.2.0 | Read-only least-privilege audit vs code-verified baseline + posture checks (owners, assignment, secrets, redirects); transcript to logs/ |
| `scripts/Tighten-AppRegistration.ps1` | 1.1.1 | Applies the audit's tightening items: drop eDiscovery.Read.All, owners, assignment-required + user assignments (interim 8-user roster pending group), legacy redirect removal; idempotent, mutation-logged. APPLIED 2026-08-11 — all green |
| `infra/modules/sqlhost.bicep` | 1.0.0 | Shared Azure SQL logical server for MCP data stores: Entra-only auth, always-on tier (no serverless auto-pause), databases as an array (one per MCP), firewall allowlist. Deployed independently of azd |
| `scripts/Initialize-McpSqlHost.ps1` | 1.1.0 | Provision/verify the shared SQL host: deploy bicep, verify server+DBs via ARM, grant contained users (Function App MI + access group) by SID, prove connectivity. `-AddDatabase` for the next MCP; `-VerifyOnly` |
| `sql/archive-index-schema.sql` | 1.0.0 | Archive message index: LoadRun provenance, Message + staging, classification/coverage/mojibake views, MERGE proc. Idempotent per statement; indexes guarded individually |
| `scripts/Import-ArchiveSearchToSql.ps1` | 1.2.0 | eDiscovery -> SQL loader/verifier: auto-bisects date windows past the 500-item export ceiling (no 100/call cap — reads the report CSV), UTF-8-BOM staging load, MERGE dedupe by internet message id, `-VerifyOnly`. 1.1.1: all SQL routed through UTF-8-BOM `-i` files — a KQL double quote broke `-Q` argument parsing. 1.1.0: `-CreateDatabase`, LocalDB pre-start + startup-transient retry, MERGE-proc presence check |
| `scripts/Set-McpAlwaysReady.ps1` | 1.1.0 | Diagnose/fix idle drop-offs: timed PRM probes + Flex alwaysReady http=1 (-Apply, full functionAppConfig round-trip — sparse PATCH fails ARM validation); scale-to-zero cold starts break the MCP client's connect timeout |
| `scripts/Enable-McpAccessRequests.ps1` | 1.1.2 | Group-based access (SG-Exchange-Archive-MCP-Users): create/seed group, assign to app, optional per-user cleanup; scripted Identity Governance access package (My Access request + approval) — the enterprise-app Self-service blade doesn't exist for custom OIDC apps. APPLIED 2026-08-11 (group/members/assignment/catalog/package/roleScope) |
| `scripts/Initialize-EDiscoveryAccess.ps1` | 1.0.0 | E0 prereqs: Graph app roles, Purview SP + eDiscovery Manager, standing case (PS 5.1) |
| `scripts/Invoke-EDiscoverySpike.ps1` | 1.1.0 | E0 spike (PASSED): noncustodialSources bind mechanism |
| `scripts/Test-EDiscoveryAppAccess.ps1` | 1.2.0 | app-only token roles + API replay; baseline = ReadWrite.All only (Read.All removed 2026-08-11), legacy-case 401s reframed as expected gate checks, transcript to logs/ |
| `scripts/Get-EDiscoverySearchStatus.ps1` | 1.1.0 | reads an app-created search's estimate app-only |
| `scripts/Get-EDiscoveryAlertConfig.ps1` | 1.0.0 | read-only inventory of alert policies watching eDiscovery (PS 5.1) |
| `scripts/Get-EDiscoveryAuditActor.ps1` | 1.1.0 | unified-audit actor/entity for alert-tuning suppression (PS 5.1) |
| `scripts/Test-EDiscoveryExport.ps1` | 1.3.0 | Full export-leg repro + unzip/parse/column-map (BUGFIX Phase 1 + regression); transcript to logs/ |
| `scripts/Test-OutlookArchiveOpen.ps1` | 1.2.0 | D0 spike (PASSED): Outlook COM open by proptag 0x1035001F |
| `scripts/Get-ArchiveConfig.ps1` | 1.0.0 | PS 5.1 EXO archive config read (AutoExpandingArchiveEnabled) |
| `scripts/Initialize-ArtifactSigning.ps1` | 1.2.0 | Provisions Artifact Signing (account, roles, cert profile); post-rename role names + live token probe |
| `scripts/Export-AzureInventory.ps1` | 1.0.0 | Read-only Azure/Entra config snapshot → foundry-mcp/inventory/ |
| `README.md` | rev 2 | Pre-hardening draft; rewritten in FOUNDRY-MCP-PLAN Phase 5 |

---

## local-mcp — local stdio MCP (PowerShell 7)

**Current release:** `0.3.2` (archive_search scope: archive | primary | both — results tagged with store). The `.psd1` `ModuleVersion` is public-facing.
Release: bump `.psd1` → walk this table → Pester green (`Invoke-Pester ./tests/Pester`) → tag `local-mcp-vX.Y.Z`.
Phase markers: 0.0.x spike · 0.2.0 read-only · **0.3.0 write tools (current)** · 0.4.0 HTTPS hosted · 1.0.0 stable.

| Path | Current | Anchor |
|---|---|---|
| `ExchangeArchiveMcp.psd1` | `0.3.2` | `ModuleVersion` (source of truth) |
| `src/Server.ps1` | `0.3.3` | `# Version:` |
| `src/Auth/Connect-McpGraph.ps1` | `0.2.0` | `# Version:` |
| `src/Auth/Resolve-UserContext.ps1` | `0.2.0` | `# Version:` |
| `src/Lib/Invoke-McpGraph.ps1` | `0.2.0` | `# Version:` |
| `src/Lib/Get-ArchiveRoot.ps1` | `0.4.0` | `# Version:` |
| `src/Lib/ConvertTo-KqlQuery.ps1` | `0.3.0` | `# Version:` |
| `src/Lib/Write-AuditLog.ps1` | `0.2.0` | `# Version:` |
| `src/Lib/New-ConfirmationToken.ps1` | `0.2.0` | `# Version:` |
| `src/Lib/Test-ReplayGuard.ps1` | `0.1.0` | `# Version:` |
| `src/Lib/Resolve-MailFolder.ps1` | `0.1.0` | `# Version:` |
| `src/Lib/Invoke-WriteOp.ps1` | `0.1.0` | `# Version:` |
| `src/Tools/Search-Archive.ps1` | `0.4.0` | `# Version:` |
| `src/Tools/Get-ArchiveMessage.ps1` | `0.2.0` | `# Version:` |
| `src/Tools/Get-ArchiveAttachment.ps1` | `0.2.0` | `# Version:` |
| `src/Tools/List-ArchiveFolders.ps1` | `0.2.1` | `# Version:` |
| `src/Tools/Get-ArchiveStats.ps1` | `0.2.1` | `# Version:` |
| `src/Tools/Restore-ArchiveItem.ps1` | `0.1.0` | `# Version:` |
| `src/Tools/Copy-ArchiveToPrimary.ps1` | `0.1.0` | `# Version:` |
| `src/Tools/Move-ArchiveToPrimary.ps1` | `0.1.0` | `# Version:` |
| `src/Transport/StdioTransport.ps1` | `0.1.0` | `# Version:` |
| `spike/Spike-ArchiveAccess.ps1` | `0.2.0` | `.NOTES Version:` |
| `config/appsettings.example.json` | `0.3.0` | `"schemaVersion"` |
| `DESIGN.md` / `SECURITY.md` / `README.md` | rev 2 | header date |

> `local-mcp` hits the same Graph-cannot-read-archive wall as the cloud MCP; its Graph-based read path works only if/when Microsoft ships archive parity, else it needs the eDiscovery treatment (open decision).

---

## gi-foundry — Azure AI Foundry IaC & origin repo

The Exchange MCP was born here (`gi-foundry/exchange-mcp/`) then promoted to the
top-level `foundry-mcp/` on 2026-07-02. The `exchange-mcp/` subfolder here is the
**superseded original**; `foundry-mcp/` is authoritative. Also holds Foundry Hub
IaC, key/secret rotation, and (unrelated) universal-print assets.

| File | Version | Description |
|------|---------|-------------|
| `CLAUDE.md` | 1.0.0 | Project plan |
| `foundry-iac/main.bicep` | 1.1.0 | Orchestration entry point |
| `foundry-iac/modules/network.bicep` | 1.0.0 | VNet, DNS, shared storage |
| `foundry-iac/modules/keyvault.bicep` | 1.0.0 | Key Vault + private endpoint |
| `foundry-iac/modules/openai.bicep` | 1.1.0 | Azure OpenAI + deployments (keyless, finding 6) |
| `foundry-iac/modules/foundry.bicep` | 1.1.0 | Hub/Project/OAI connection (AAD keyless) |
| `foundry-iac/parameters/prod.bicepparam` | 1.0.0 | Prod params |
| `foundry-iac/parameters/dev.bicepparam` | 1.0.0 | Dev params |
| `foundry-iac/.github/workflows/bicep-validate.yml` | 1.1.0 | Bicep validation (OIDC login) |
| `scripts/Deploy-Foundry.ps1` | 1.0.0 | Deployment driver |
| `scripts/Rotate-OAIKey.ps1` | 1.0.0 | OpenAI key rotation (retire at keyless cutover) |
| `scripts/Rotate-MCPClientSecret.ps1` | 1.1.0 | MCP secret rotation |
| `scripts/Register-EntraApp.ps1` | 1.1.0 | Entra app setup |
| `scripts/Set-ApplicationAccessPolicy.ps1` | 1.1.0 | Mailbox scope restriction |
| `universal-print/Register-Printers.ps1` | 1.0.0 | Universal Print registration |
| `universal-print/Set-PrinterShares.ps1` | 1.0.0 | Bulk share assignment |

_(gi-foundry `exchange-mcp/` file versions are historical; live copies are under `foundry-mcp/` above.)_

---

## security-baseline/reference-impl — MCP security reference (patterns only)

> Do not copy patterns from this package until its fix pass (findings 1, 8, 9, 19, 24, 33 + Lesson 11) lands — gated before Local MCP Phase 3.

| File | Version | Notes |
|---|---|---|
| `01-Authorization.ps1` | 1.0.0 | Initial |
| `02-JwtService.ps1` | 1.0.0 | Initial |
| `03-AuthMiddleware.ps1` | 1.0.0 | Initial |
| `04-ToolPermissions.ps1` | 1.0.0 | Initial |
| `Start-McpServer.ps1` | 1.0.0 | Initial |
| `mcp-security-considerations.md` | 1.0.0 | Three-source reference doc |

---

## Archived — see `archive/OLD-superseded-2026-08-03.zip`

Moved out of the working tree 2026-08-03 (superseded; recoverable from git + the zip):

- `Test-ArchiveGraphAccess.ps1` — Graph-access diagnostic; conclusion settled.
- `ArchiveMailbox.Graph.ps1` — companion module for the original Graph-based fix.
- `exchange_online_archive_110gb_mailbox_issue.md` — original May-2026 issue notes.
- `MCP-Exchange-Archive-safeguards-addendum.zip` — consumed input bundle.

Earlier archive: `archive/OLD-MCP-Archive-Mailbox-design-lineage-2026-07-13.zip`.
