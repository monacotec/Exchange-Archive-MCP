# CHANGES — Revision 2

Plain-language summary of what moved between the rev 1 bundle (`MCP-Exchange-Archive-bundle.zip`) and rev 2 (this package).

If you read nothing else, read this file. Everything else is just the detail.

---

## The five things that changed, in plain English

### 1. The spike no longer uses MSAL.PS

**Before:** Phase 0 spike installed and used `MSAL.PS` for the interactive sign-in.

**After:** Phase 0 spike uses `Microsoft.Graph.Authentication` (`Connect-MgGraph`) — the supported Microsoft module.

**Why:** Microsoft's own docs now state plainly: *"There is no official PowerShell module or wrapper for MSAL libraries maintained by the Entra SDK team. Consider using maintained higher level SDKs."* `MSAL.PS` still installs and works, but a "not supported by Microsoft" module sitting on the auth path of an executive archive reader is exactly the supply-chain risk §10 of our own security baseline warns about. `Connect-MgGraph` uses MSAL.NET under the hood, has a built-in encrypted token cache, supports interactive + silent refresh, and is what Microsoft documents and supports.

**What this changes downstream:** The `Lib/Invoke-GraphRequest.ps1` retry helper gets simpler — you can lean on the typed `Invoke-MgGraphRequest` cmdlet for most calls and only hand-roll `Invoke-RestMethod` where you need the raw `client-request-id` header.

---

### 2. Foundry plan Phases 2 and 3 may collapse to half a day each

**Before:** Phase 2 (1.5 d) hand-rolled `jwt_middleware.py` with `pyjwt[crypto]` + `PyJWKClient`. Phase 3 (1 d) hand-rolled OBO with `msal.ConfidentialClientApplication.acquire_token_on_behalf_of(...)`.

**After:** Phase 2 becomes "configure the Functions MCP extension's built-in Entra auth" and Phase 3 becomes "configure native OBO." The hand-rolled code is the **fallback** if the built-in doesn't fit, not the default.

**Why:** When rev 1 was drafted, the Azure Functions MCP extension was in public preview. It went GA in late 2025, with native OBO authentication and streamable-HTTP transport built in. Microsoft markets this exact change — "solving the security pain point that has historically prevented AI agents from accessing sensitive downstream enterprise data" — and the reference template (`Azure-Samples/remote-mcp-functions-python`) ships configured for Entra auth out of the box.

**What this changes downstream:** Phase 2 is renamed "**configure native Entra auth**" with a fallback subsection for the hand-rolled middleware. The hand-rolled middleware is still documented because (a) it's the §1 requirement of the baseline and (b) some teams will need it if they don't go all-in on the extension. But the default path is "configure, don't code."

---

### 3. MCP spec 2025-06-18 adds two mandatory items that weren't in rev 1

**Before:** Neither plan mentioned RFC 9728 (Protected Resource Metadata) or RFC 8707 (Resource Indicators).

**After:** Both plans require a `.well-known/oauth-protected-resource` endpoint on the Foundry MCP, and a `resource=` parameter on token requests from the client side. The security baseline has a new appendix for the 2025-06-18 deltas.

**Why:** The June 2025 MCP authorization spec formalized MCP servers as OAuth 2.1 *resource servers* (not authorization servers) and made PRM mandatory. The previous fallback to default endpoints (`/authorize`, `/token`, `/register`) was removed. MCP clients now discover the auth server via PRM. If we skip this, Claude's connector UI and Foundry's catalog tooling may not register the server correctly.

**What this changes downstream:** A ~30-line addition to `function_app.py` (the PRM endpoint), one extra parameter in the Claude Desktop connector setup, and a new checklist appendix.

---

### 4. The Claude Desktop config block was using an obsolete pathway

**Before:** Foundry plan §10.2 showed a `claude_desktop_config.json` entry with `"type": "http"` and an inline `auth.type: oauth2` block for the remote server.

**After:** Foundry plan §10.2 says: register the server via **Settings → Connectors** in Claude Desktop. The `claude_desktop_config.json` pathway is for local stdio servers only.

**Why:** Anthropic's published doc is explicit: *"To configure remote MCP servers for use in Claude Desktop, add them via Settings > Connectors. Claude Desktop will not connect to remote servers that are configured directly via claude_desktop_config.json."* The old example would silently not work, and would cost a day of "why won't it connect" debugging.

**What this changes downstream:** The Entra app's redirect-URI allowlist must include `https://claude.ai/api/mcp/auth_callback` (and the `claude.com` variant Anthropic has flagged as upcoming). The Local MCP's stdio config in `claude_desktop_config.json` is unchanged — that pathway still works for stdio.

---

### 5. Audit log claim needs verification, not assumption

**Before:** Foundry Phase 3 exit criterion said "per-user audit trail in Exchange unified audit log."

**After:** Same exit criterion, but with a verification step that confirms `MailItemsAccessed` is in each target user's `AuditOwner` set, and a note that the App Insights custom dimensions are the authoritative audit source — Exchange unified log is corroborating, not primary.

**Why:** M365 mailbox auditing is on by default at the tenant level, but mailbox-owner actions (which an OBO'd "user reading their own archive" qualifies as) are only audited if the right actions are enabled in `AuditOwner`. On E5 + Purview Audit Premium this is usually fine; outside that it's not. Confirming once, before the runbook makes the claim, is cheap.

**What this changes downstream:** A one-line check added to Phase 0 prerequisites. A clarifying note in `SECURITY.md` about which audit sink is authoritative.

---

## What did NOT change

To save you re-reading: the rev 1 design was sound in most respects. None of the following moved:

- **Two-step confirm for write tools.** Local MCP Phase 2's HMAC-token + TTL + dry-run pattern stands. It's good prompt-injection defense and survives the spec updates.
- **Delegated-only, no app-only.** Still the right call for both servers in v1.
- **Single-tenant Entra app.** Still right.
- **ApplicationAccessPolicy as defense-in-depth.** Still right; "structurally redundant under OBO" is true but defense-in-depth is the whole point.
- **Bicep / azd as the deployment pattern.** Still right.
- **Audit goes to App Insights + Log Analytics.** Still right; the only change is treating Exchange unified log as corroborating, not primary.
- **All sixteen security baseline sections.** Still authoritative; the 2025-06-18 deltas are an appendix, not a rewrite.

---

## File map: rev 1 → rev 2

What got renamed, moved, or replaced:

| Rev 1 location | Rev 2 location | Note |
|---|---|---|
| `BUILD-PLAN-Local-MCP.md` | `plans/LOCAL-MCP-PLAN.md` | Updated; section markers preserved. |
| `BUILD-PLAN-Foundry-MCP.md` | `plans/FOUNDRY-MCP-PLAN.md` | Phases 2–3 rewritten; rest preserved. |
| `README.md` | `README.md` | New build order section. |
| `files/DESIGN.md` | `local-mcp/DESIGN.md` | Auth section rewritten (Microsoft.Graph.Authentication). |
| `files/PLAN.md` | *(merged into `plans/LOCAL-MCP-PLAN.md`)* | Duplicated content removed. |
| `files/SECURITY.md` | `local-mcp/SECURITY.md` | Audit-sink clarification added. |
| `files/Spike-ArchiveAccess.ps1` | `local-mcp/spike/Spike-ArchiveAccess.ps1` | Rewritten on Microsoft.Graph.Authentication. |
| `files/version.md` | *(merged into root `version.md`)* | One version table for the whole suite. |
| `gi-foundry/exchange-mcp/` | `foundry-mcp/` | Same contents, simpler path. |
| `gi-foundry/exchange-mcp/function_app.py` | `foundry-mcp/function_app.py` | PRM endpoint added; OBO swap documented inline. |
| `gi-foundry/CLAUDE.md` | *(unchanged — stays in the gi-foundry repo)* | Not duplicated here. |
| `mcp-security-ps1/` | `security-baseline/` | Renamed; content unchanged except new appendix. |
| `mcp-security-ps1/mcp-security-considerations.md` | `security-baseline/mcp-security-considerations.md` | New §19: 2025-06-18 spec deltas. |
| `mcp-security-ps1/0[1-4]-*.ps1` | `security-baseline/reference-impl/0[1-4]-*.ps1` | Moved into `reference-impl/` subfolder; signal that they're reference patterns, not the production auth code. |
| *(new)* | `plans/BUILD-ORDER.md` | Explicit cross-plan ordering. |
| *(new)* | `docs/claude-desktop-wiring.md` | Connectors UI vs config file. |
| *(new)* | `docs/audit-verification.md` | The `MailItemsAccessed` / `AuditOwner` check. |
| *(new)* | `docs/protected-resource-metadata.md` | The RFC 9728 endpoint. |

---

## Decisions to revisit during the spike week

Two things deserve an explicit go/no-go before phase 1 ships:

1. **Does `Microsoft.Graph.Authentication` give us everything `MSAL.PS` did?** Specifically: silent refresh from a cache file, named app reg (not the default Graph Command Line Tools client ID), and the ability to extract a raw access token for direct `Invoke-RestMethod` calls when we need custom headers. Spike answers all three.
2. **Does the Functions MCP extension's built-in Entra auth give us per-user identity on the Graph OBO call?** If yes, the hand-rolled `jwt_middleware.py` and `graph_obo.py` are gone. If no, they're back in. Half a day with the reference template answers this.

Decide both before locking the Phase 1 scope.
