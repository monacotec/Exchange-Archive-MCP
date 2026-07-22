# Build Plan — Foundry Exchange Archive MCP (Hardened)

**Project:** `exchange-mcp` (Azure Functions / Foundry-discoverable)
**Owner:** Jeff (GI Partners)
**Status:** Approved for build — rev 2; hardening required before write tools
**Last updated:** 2026-05-23
**Security baseline:** [`security-baseline/mcp-security-considerations.md`](../security-baseline/mcp-security-considerations.md)

---

## 1. Goal

A cloud-hosted MCP server on Azure Functions giving Claude (via the Connectors UI) **and Foundry agents** read-only access to a curated set of Exchange Online archive mailboxes — discoverable via Azure API Center, audited centrally, and authenticated per-user (not via a shared function key).

The current draft in [`foundry-mcp/`](../foundry-mcp/) ships read-only with `x-functions-key`. This plan hardens it to the security baseline before any expansion.

---

## 2. Critical security deltas vs current draft

The current `function_app.py` violates three sections of the security baseline. These must be closed *before* the server hosts more than the current three read-only tools:

| § | Gap in current draft | Resolution |
|---|---|---|
| §1 Auth | Shared static `x-functions-key` for every caller | OAuth 2.1 / JWT bearer with `aud`/`iss`/`exp` validation; 15–30 min lifetime; per-user identity |
| §11 Logging | All audit entries share one acting identity (the Function App MI) | Propagate caller `oid`/`upn` via OBO; log `user_identity` per call |
| §2 Confused Deputy | App-only `ClientSecretCredential` holds `Mail.Read` across the entire allowlist | On-Behalf-Of flow (OBO) — tokens scoped to caller |
| **§19** | **PRM endpoint not served; client can't discover auth server per MCP 2025-06-18** | **Add `/.well-known/oauth-protected-resource` route** |

---

## 3. Locked decisions

| Decision | Choice | Why |
|---|---|---|
| Runtime | Azure Functions Python v2, **MCP extension (GA)** | Foundry portal native; **built-in Entra auth and OBO** (rev 2); managed runtime patching (§14) |
| Identity | OAuth 2.1 (Entra) bearer in; OBO to Graph | Per-user identity end-to-end; defeats Confused Deputy |
| Auth implementation | **Configure native extension auth first; hand-roll only if it doesn't fit** | The extension solves the §1 + §11 + §2 gaps for us in most cases. See `CHANGES.md` §2. |
| Secrets | Key Vault + system-assigned MI | No secrets in app settings or image (§7, §8) |
| Network | VNet-integrated Function App + Private Endpoint on Key Vault | §6 network segmentation |
| Tool scope | Read-only in v1 — `search_archive_mail`, `get_mail_by_date_range`, `list_archive_folders` | Write tools require the Local MCP's two-step confirm pattern (deferred to v2) |
| Mailbox scoping | Exchange `ApplicationAccessPolicy` + `MCP_ALLOWED_MAILBOXES` defense-in-depth | Layered authorization (§5) |
| Discoverability | Azure API Center registration | Foundry portal can browse the org catalog |
| Audit | App Insights (primary) + Exchange unified audit (corroborating) + Log Analytics workspace `la-gipartners-mcp` | App Insights is authoritative; Exchange log requires `AuditOwner` config — see `docs/audit-verification.md` |

---

## 4. Phase breakdown

| Phase | Scope | Effort | Exit criteria |
|---|---|---|---|
| 0 | Entra app registration + ApplicationAccessPolicy + KV provisioning + `AuditOwner` check | 0.5 d | App reg has correct delegated + app scopes; KV holds secrets; audit verification logged |
| 1 | IaC (Bicep) — Function App, VNet, KV, API Center, role assignments | 1 d | `azd up` clean against empty RG |
| 2 | **Configure** native Entra auth on the MCP extension (fallback: hand-roll JWT middleware) | 0.5–1.5 d | Tokens validated; per-user identity in App Insights |
| 3 | **Configure** OBO to Graph (fallback: hand-roll with msal.ConfidentialClientApplication) | 0.5–1 d | Audit entries show caller UPN, not the MI |
| 4 | Wire 3 read-only tools to OBO Graph client + add PRM endpoint | 1 d | Tools work end-to-end through Foundry portal; PRM returns 200 |
| 5 | API Center registration; Claude Desktop **Connectors UI** wiring; tests | 0.5 d | Foundry catalog lists the server; Claude can call it via Connectors |
| 6 | Security hardening pass against the full checklist (including §19 deltas) | 1 d | All §1–§19 items signed off |

**Total:** **4.5–6.5 days** depending on Phase 2–3 outcome.

Write tools (`restore`/`copy`/`move`) are explicitly deferred to a v2 plan that ports the Local MCP's two-step confirm pattern.

---

## 5. Phase 0 — Prerequisites (0.5 day)

### 5.1 Entra app registration

Script: [`foundry-mcp/scripts/Register-EntraApp.ps1`](../foundry-mcp/scripts/Register-EntraApp.ps1) (exists). Update to issue:

- **API exposed:** `api://exchange-mcp/.default` with scopes `Archive.Read`.
- **Delegated permissions on Graph:** `Mail.Read`, `User.Read`, `offline_access` (the OBO target).
- **Public client = false** (this app receives tokens, doesn't initiate flows).
- **Redirect URIs:**
  - `http://localhost` (the loopback used by `Connect-MgGraph` in the Local MCP — keep both MCPs on one app reg)
  - `https://claude.ai/api/mcp/auth_callback` (Claude Connectors UI callback)
  - `https://claude.com/api/mcp/auth_callback` (Anthropic has flagged this as the future callback domain)
  - Foundry portal callback (from `Get-AzAdApplication` after Foundry consents)
- **Token version:** v2.

### 5.2 ApplicationAccessPolicy

Script: [`foundry-mcp/scripts/Set-ApplicationAccessPolicy.ps1`](../foundry-mcp/scripts/Set-ApplicationAccessPolicy.ps1) (exists). Restrict the **OBO target Entra app's effective access** to the `MCP-ArchiveAccess` mail-enabled security group.

> Note: with OBO + delegated scopes, this is belt-and-suspenders — the delegated token already constrains to the signed-in user. Keep the policy for defense-in-depth (§5).

### 5.3 Key Vault

Already provisioned in Phase 1 of `gi-foundry/CLAUDE.md`. Add three new secrets:

- `mcp-jwt-audience` = `api://exchange-mcp`
- `mcp-jwt-issuer` = `https://login.microsoftonline.com/{tenant_id}/v2.0`
- `mcp-jwks-uri` = `https://login.microsoftonline.com/{tenant_id}/discovery/v2.0/keys`

> If Phase 2 uses the extension's native auth, these secrets are unused at runtime but remain in KV for the hand-roll fallback and for the PRM endpoint configuration.

### 5.4 Audit verification

Run the check in [`docs/audit-verification.md`](../docs/audit-verification.md) against the test mailbox. Record the result.

**Exit:** App reg manifest reviewed; KV secrets in place; ApplicationAccessPolicy applied; audit verification logged.

---

## 6. Phase 1 — Infrastructure (1 day)

### 6.1 Bicep stack additions ([`foundry-mcp/infra/`](../foundry-mcp/infra/))

```
infra/
├── main.bicep                 # Function App + ASP + Storage + VNet integration
├── main.parameters.json
└── modules/
    ├── functionapp.bicep      # FA, Plan (EP1 elastic), App Insights, VNet integration
    ├── apicenter.bicep        # API Center resource + MCP API registration
    ├── roleassignments.bicep  # MI → KV Secrets User; MI → Storage Blob Data Contributor
    └── privatelink.bicep      # Private endpoints for KV + Storage
```

Key settings on `functionapp.bicep`:

- `httpsOnly = true`
- `minTlsVersion = '1.2'`
- `ftpsState = 'Disabled'`
- `WEBSITE_RUN_FROM_PACKAGE = 1`
- `vnetRouteAllEnabled = true`, integrated with `snet-foundry-managed`
- **No** `MCP_ENTRA_CLIENT_SECRET` app setting — secrets come from KV at cold start
- **Strip the host-key auth path** — `function.json` `authLevel = ANONYMOUS` on the MCP endpoint. The extension's native Entra auth (or our middleware fallback) takes over.
- **Parameterise the credential type** so a future switch from `client_secret` → Workload Identity Federation is a config change, not a code change.

### 6.2 Outputs

- `functionAppName`, `functionAppPrincipalId`, `functionAppDefaultHostName`, `apicenterMcpUri`.

**Exit:** `azd provision` succeeds on an empty RG; private endpoints resolve internally.

---

## 7. Phase 2 — Entra bearer auth (0.5–1.5 days)

### 7.1 Default path — configure the extension's native auth

The Azure Functions MCP extension (GA) has built-in Entra ID auth and streamable-HTTP transport. The reference template `Azure-Samples/remote-mcp-functions-python` ships with this configured. Steps:

1. Diff the reference template against `foundry-mcp/function_app.py`. Adopt the extension's configured auth pattern.
2. In `host.json`, configure the `extensions.mcp` block to require Entra bearer auth against our app reg (audience `api://exchange-mcp`).
3. The extension exposes the authenticated user via the request context; the tool handlers receive `tool_context.user` populated with the validated claims.
4. Tests: tampered signature → 401, expired token → 401, wrong audience → 401, `alg: none` token → 401, missing scope → 403.

If the extension's auth fits, **Phase 2 is done in half a day**. Skip §7.2 entirely.

### 7.2 Fallback path — hand-rolled JWT middleware

If the extension's native auth can't be configured for our scenario (e.g., we need claims the extension doesn't expose, or we need a custom error response shape), revert to the rev 1 plan: a `auth/jwt_middleware.py` module using `PyJWKClient`:

```python
# auth/jwt_middleware.py — fallback only
import jwt
from jwt import PyJWKClient

class JwtConfig:
    audience: str       # from KV: mcp-jwt-audience
    issuer:   str       # from KV: mcp-jwt-issuer
    jwks_uri: str       # from KV: mcp-jwks-uri

_jwk_client = PyJWKClient(cfg.jwks_uri, cache_keys=True, lifespan=3600)

def verify_bearer(req) -> AuthenticatedUser:
    hdr = req.headers.get("Authorization", "")
    if not hdr.startswith("Bearer "):
        raise AuthError("missing_bearer")
    raw = hdr[7:]
    signing_key = _jwk_client.get_signing_key_from_jwt(raw).key
    claims = jwt.decode(
        raw, signing_key,
        algorithms=["RS256"],           # lock algorithm — never "none"
        audience=cfg.audience,
        issuer=cfg.issuer,
        options={"require": ["exp", "aud", "iss", "sub"]},
    )
    return AuthenticatedUser(
        oid=claims["oid"],
        upn=claims.get("preferred_username") or claims.get("upn"),
        scope=claims.get("scp", "").split(),
        raw_token=raw,                  # needed for OBO in Phase 3
    )
```

Wire as `@require_auth` decorator on each MCP tool. Same test set as §7.1.

### 7.3 RBAC enum + tool-permission map

Regardless of which path is used, define permissions as enums (security baseline §1):

```python
# auth/authorization.py
class Permission(str, Enum):
    READ_ARCHIVE = "archive:read"
    LIST_FOLDERS = "archive:list-folders"

TOOL_PERMISSIONS = {
    "search_archive_mail":    Permission.READ_ARCHIVE,
    "get_mail_by_date_range": Permission.READ_ARCHIVE,
    "list_archive_folders":   Permission.LIST_FOLDERS,
}
```

Tool handlers check both scope (token-level) and permission (RBAC-level).

**Exit:** All MCP requests require a valid Entra-issued bearer; App Insights shows per-user `oid` in custom dimensions. Phase 2 path (extension-native vs hand-roll) is documented in the repo README.

---

## 8. Phase 3 — On-Behalf-Of to Graph (0.5–1 day)

### 8.1 Default path — extension's native OBO

The GA extension supports OBO natively: when a tool handler asks for a Graph token, the extension performs the OBO exchange using the inbound user's token. No `msal.ConfidentialClientApplication` code in our repo.

Practically: in the tool handler, request a Graph client via the extension's helper, scoped to `https://graph.microsoft.com/Mail.Read`. The returned client is per-user.

If that works for our scenario, **Phase 3 is done in half a day**. Skip §8.2.

### 8.2 Fallback path — hand-rolled OBO with MSAL

If the extension doesn't expose OBO in the shape we need, fall back to the rev 1 design:

```python
# auth/graph_obo.py — fallback only
from msal import ConfidentialClientApplication

_msal_app = ConfidentialClientApplication(
    client_id=client_id_from_kv,
    client_credential=client_secret_from_kv,   # still needed for OBO assertion
    authority=f"https://login.microsoftonline.com/{tenant_id}",
)

def graph_client_for(user: AuthenticatedUser) -> GraphServiceClient:
    result = _msal_app.acquire_token_on_behalf_of(
        user_assertion=user.raw_token,
        scopes=["https://graph.microsoft.com/Mail.Read"],
    )
    if "access_token" not in result:
        raise AuthError(f"obo_failed: {result.get('error_description')}")
    return GraphServiceClient(credentials=StaticTokenCredential(result["access_token"]))
```

### 8.3 Consequences (both paths)

- The Graph token is now **scoped to the caller**, not the app. `Mail.Read` here is delegated, not application.
- `MCP_ALLOWED_MAILBOXES` becomes structurally redundant (the delegated token can only read its own mailbox) — keep it for defense-in-depth and as an org-policy fence.
- Audit logs now meaningfully reflect *who* read what (App Insights primary; verify Exchange unified log per `docs/audit-verification.md`).

### 8.4 Token cache

OBO tokens cached **in-memory per-instance** by default (extension-native handles this; fallback uses `msal.SerializableTokenCache`).

Promote to Azure Cache for Redis (private endpoint, keyed by `(user.oid, scope_set)`, TTL = token expiry minus 60s) **only if** token-acquisition latency observably hurts. Don't pay for Redis on day 1.

> **Future:** Workload Identity Federation removes the need for `client_secret` in MSAL even in the fallback path. The Bicep is parameterised for this swap (Phase 1).

**Exit:** Per-user audit trail in App Insights; Exchange unified audit log corroborates per `docs/audit-verification.md`; `client_id` of OBO calls matches the MCP app.

---

## 9. Phase 4 — Re-wire tools + add PRM endpoint (1 day)

### 9.1 Tool re-wiring

Update each tool in `function_app.py`:

```python
@app.mcp_tool(name="search_archive_mail", ...)
@require_auth(scopes=["Archive.Read"])       # or extension-native equivalent
async def search_archive_mail(tool_context):
    user  = tool_context.user
    graph = graph_client_for(user)           # OBO token (per-user)
    if guard := check_mailbox_allowed(user.upn): return json.dumps(guard)
    # ...existing Graph call...
```

Three tools, same shape:

| Tool | Permission | Notes |
|---|---|---|
| `search_archive_mail` | `archive:read` | KQL via Graph `$search`; cap top=50 |
| `get_mail_by_date_range` | `archive:read` | `$filter` on `receivedDateTime`; cap top=100 |
| `list_archive_folders` | `archive:list-folders` | Recurse `childFolders`, max_depth ≤ 5 |

### 9.2 Protected Resource Metadata endpoint (RFC 9728)

Add a route returning OAuth 2.0 Protected Resource Metadata per MCP spec 2025-06-18:

```python
@app.route(route=".well-known/oauth-protected-resource", auth_level=func.AuthLevel.ANONYMOUS)
def protected_resource_metadata(req: func.HttpRequest) -> func.HttpResponse:
    return func.HttpResponse(
        json.dumps({
            "resource": MCP_SERVER_URL,
            "authorization_servers": [JWT_ISSUER],
            "scopes_supported": ["api://exchange-mcp/Archive.Read"],
            "bearer_methods_supported": ["header"],
            "resource_documentation": f"{MCP_SERVER_URL}/docs",
            "mcp_protocol_version": "2025-06-18",
            "resource_type": "mcp-server"
        }),
        mimetype="application/json",
        status_code=200,
    )
```

Details in [`docs/protected-resource-metadata.md`](../docs/protected-resource-metadata.md).

**Exit:** All three tools work via Foundry portal and Claude (Connectors UI) with OAuth. PRM endpoint returns 200 with valid JSON.

---

## 10. Phase 5 — Discoverability + clients (0.5 day)

### 10.1 API Center

Run [`foundry-mcp/Register-MCPInApiCenter.ps1`](../foundry-mcp/Register-MCPInApiCenter.ps1) (exists) — idempotent. Registers:

- API: `exchange-mcp`, kind `mcp`.
- Version: from `version.md`.
- Definition: JSON-RPC `tools/list` snapshot.
- Auth metadata: OAuth 2.1 details so Foundry portal can prompt for consent. Include the PRM endpoint URL.

### 10.2 Claude Desktop config — **via Connectors UI, not config file**

> **This changed from rev 1.** Anthropic's published doc: "To configure remote MCP servers for use in Claude Desktop, add them via Settings > Connectors. Claude Desktop will not connect to remote servers that are configured directly via `claude_desktop_config.json`."

Steps for each user:

1. Open Claude Desktop → **Settings → Connectors → Add custom connector**.
2. Server URL: `https://func-exchange-mcp-prod.azurewebsites.net/runtime/webhooks/mcp`.
3. Claude Desktop performs the OAuth dance against the URL it discovered from the PRM endpoint.
4. User consents to `Archive.Read` scope.
5. Server appears in the user's connector list; tokens managed by Claude Desktop, refreshed automatically.

**Entra app pre-req:** `https://claude.ai/api/mcp/auth_callback` (and `https://claude.com/api/mcp/auth_callback`) must be in the redirect-URI allowlist — added in Phase 0 §5.1.

Full walkthrough in [`docs/claude-desktop-wiring.md`](../docs/claude-desktop-wiring.md).

### 10.3 Foundry portal

Foundry portal → project → **Build** → **Tools** → **Add tool** → **Model Context Protocol** → browse API Center catalog → **Exchange Online Archive MCP**. Foundry portal handles the OAuth dance per user.

**Exit:** Foundry agent invocation shows the agent owner's UPN in Exchange audit log (per Phase 0 audit verification).

---

## 11. Phase 6 — Security hardening (1 day)

Walk `security-baseline/mcp-security-considerations.md` Quick Reference Checklist:

| § | Item | Status after Phases 0–5 | Action |
|---|---|---|---|
| §1 | OAuth 2.1 / JWT with aud/iss/exp validation | ✅ Phase 2 | — |
| §1 | Short-lived tokens 15–30 min | Verify Entra token lifetime policy | Tenant policy doc |
| §1 | RBAC enums, not strings | ✅ Phase 2 | — |
| §2 | Strict redirect URI allowlist | App reg config — includes claude.ai callback | Manual review |
| §3 | Token passthrough disabled | ✅ OBO ≠ passthrough; server issues a new Graph token | Code review |
| §4 | Input validation — OData injection in `from_address` | Current code escapes single quotes only | Add allowlist regex for email format |
| §4 | Prompt injection — gate destructive actions | N/A v1 (no writes) | Document for v2 |
| §5 | Least privilege — only `Mail.Read` delegated | ✅ Phase 3 | — |
| §6 | Listener: never 0.0.0.0 | Function App ingress, private | ✅ |
| §6 | VNet integration + private endpoints on KV, Storage | ✅ Phase 1 | — |
| §7 | AES-256 at rest; TLS 1.2+ in transit | Azure defaults + `minTlsVersion=1.2` | ✅ |
| §7 | No secrets in image/repo | ✅ KV + MI | grep verification |
| §8 | Non-root container, image scan | Functions managed runtime | Defender for Cloud on |
| §9 | Sessions tied to verified identity, server-side | JWT is stateless; OBO cache is server-side | ✅ |
| §10 | Third-party MCP code reviewed | N/A — only our code | — |
| §11 | Per-call audit: user_identity, tool_name, in/out summary | ✅ App Insights custom dimensions | Configure Log Analytics workbook |
| §11 | Alerts on auth failure spikes + unusual tool volumes | App Insights alert rules | Configure |
| §11 | Exchange unified log corroborates per-user attribution | Phase 0 audit verification | Logged result |
| §12 | Human-in-the-loop on destructive actions | N/A v1 | Required before v2 write tools |
| §13 | Rate limit per user | Add APIM in front, or Functions extension | Add APIM consumption tier |
| §14 | Patch schedule, SBOM | Functions runtime auto-patched; Dependabot on `requirements.txt` | GH config |
| §15 | Multi-tenant isolation | Single-tenant (GI only) | Document scope |
| §16 | Compliance mapping (SOC 2 / internal IT policy) | Map controls to ITGC matrix | Doc |
| **§19** | **PRM endpoint at `/.well-known/oauth-protected-resource`** | **✅ Phase 4** | **curl verification** |
| **§19** | **Resource Indicator on token requests** | **Claude Desktop + Foundry portal send `resource=`** | **JWT inspection** |
| **§19** | **MCP server classified as OAuth 2.1 resource server, not auth server** | **By design** | **Doc** |

**IaC verification rows** (2026-07-20 addendum — code patches tracked in [`DAY-ZERO-HYGIENE.md`](../DAY-ZERO-HYGIENE.md); these rows are the *demonstrations* that each fix holds in the deployed environment):

| § | Item | Verification |
|---|---|---|
| IaC-1 | `AzureWebJobsStorage` identity-based, no key in app settings | `az functionapp config appsettings list` shows no `AccountKey=`; storage account has `allowSharedKeyAccess: false` |
| IaC-2 | OpenAI connections keyless in both `openai.bicep` and `foundry.bicep` | `grep listKeys` in both files returns nothing; role assignment exists on the consuming identity |
| IaC-3 | No secrets in deployment history | `az deployment operation group list -g finresgroup` — grep for key material, must not appear |
| IaC-4 | CI cannot leak secrets | Latest `bicep-validate.yml` run log has no key material; `azure/login` step uses OIDC, `AZURE_CREDENTIALS` repo secret deleted |
| IaC-5 | Key Vault diagnostic logging | `kv-exmcp-gi` diagnostic setting forwards the `AuditEvent` category (not `categoryGroup: 'audit'`) to Log Analytics; a KQL query returns `SecretGet` events |
| IaC-6 | Public-endpoint posture stated, not assumed | Endpoint is public **by design** (Foundry Agent Service reachability); Easy Auth fail-closed is the actual defense — document, and evaluate `ipSecurityRestrictions` as defense-in-depth |

**Exit:** Checklist signed off; release tagged `v1.0.0`; runbook published in IT wiki.

---

## 12. File layout (target)

```
foundry-mcp/
├── function_app.py                       # MCP tool definitions + PRM endpoint
├── auth/                                 # only populated if Phase 2/3 fallback is used
│   ├── __init__.py
│   ├── authorization.py                  # enums + role/permission map
│   ├── jwt_middleware.py                 # bearer validation (fallback only)
│   └── graph_obo.py                      # OBO to Graph (fallback only)
├── tools/
│   ├── __init__.py
│   ├── search_archive_mail.py
│   ├── get_mail_by_date_range.py
│   └── list_archive_folders.py
├── host.json                             # extensions.mcp config — Entra auth
├── local.settings.json.example
├── requirements.txt                      # msal + pyjwt[crypto] only used in fallback
├── azure.yaml
├── infra/
│   ├── main.bicep
│   ├── main.parameters.json
│   └── modules/
│       ├── functionapp.bicep
│       ├── apicenter.bicep
│       ├── roleassignments.bicep
│       └── privatelink.bicep
├── tests/
│   ├── test_auth.py                      # works for either path
│   ├── test_obo.py                       # works for either path
│   ├── test_tools.py
│   └── test_prm.py                       # NEW — PRM endpoint shape
├── scripts/
│   ├── Register-EntraApp.ps1
│   ├── Set-ApplicationAccessPolicy.ps1
│   └── Rotate-MCPClientSecret.ps1
├── Register-MCPInApiCenter.ps1
├── version.md
└── README.md                              # rewrite — Connectors UI; remove x-functions-key sections
```

---

## 13. Risks

1. **Extension-native auth gaps.** The default Phase 2/3 path depends on the extension's auth + OBO matching our needs. If a quirk (claim shape, scope handling) breaks us, we fall back to the hand-rolled middleware. Spike work in Week 1 answers this before we commit.
2. **OBO + Foundry portal flow.** If Foundry doesn't yet propagate user tokens correctly, Phase 4 may need a fallback to client credentials *for Foundry only* with a documented audit caveat. **Mitigation:** validate Phase 5 against Foundry early; fail fast.
3. **Redis private endpoint cost.** Phase 3 cache adds infra cost. **Mitigation:** start with in-memory per-instance cache; Redis only if we see token-acquisition latency issues. (Unchanged from rev 1.)
4. **APIM for §13 rate limiting** adds significant cost on a Consumption tier. **Mitigation:** start with Function App built-in throttling; add APIM only if abuse observed.
5. **Token lifetime policy** at the tenant level may already cap below 30 min — coordinate with IT before assuming default Entra lifetimes.
6. **PRM endpoint cached aggressively by clients.** If we change auth servers, clients may not pick it up immediately. **Mitigation:** TTL in PRM response.

---

## 14. Out of scope (v1)

- Write tools (`restore`/`copy`/`move`) — deferred to v2 with ported two-step confirm.
- eDiscovery / compliance search.
- Calendar, contacts, tasks.
- Shared mailbox / public folder.
- Cross-tenant access.
- Workload Identity Federation (tracked for future iteration; Bicep parameterised for the swap; `Rotate-MCPClientSecret.ps1` exists meanwhile).

---

## 15. Acceptance for production go-live

1. All Phase 6 checklist items signed off in writing, **including §19 deltas**.
2. Penetration test against the Function App endpoint (bearer with no scope, expired token, replayed token, alg:none, wrong audience, missing PRM) — all rejected.
3. End-to-end test: a Foundry agent invocation by user A reading user A's archive → App Insights shows `user_identity=A`; Exchange unified log corroborates (per Phase 0 verification).
4. End-to-end test: user A's token used to attempt user B's mailbox → blocked at Graph (delegated scope) *and* logged.
5. Disaster: rotate `mcp-exchange-client-secret` via existing `Rotate-MCPClientSecret.ps1` — no service disruption (cold-start picks up new value within 10 min).
6. PRM endpoint accessibility test: `curl https://<host>/.well-known/oauth-protected-resource` returns valid RFC 9728 JSON.
7. Runbook published covering: revoke a token, isolate the Function App, pull audit log slice from Log Analytics by user/time window.
