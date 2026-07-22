# Build Plan — Local Exchange Archive MCP

**Project:** `exchange-archive-mcp` (local / stdio)
**Owner:** Jeff (GI Partners)
**Status:** Approved for build — rev 2
**Last updated:** 2026-05-23
**Security baseline:** [`security-baseline/mcp-security-considerations.md`](../security-baseline/mcp-security-considerations.md)

---

## 1. Goal

Ship a PowerShell 7 MCP server that lets Claude Desktop read, search, and (with explicit human confirmation) restore items from each user's Exchange Online **archive mailbox**. Delegated auth only — the server can do exactly what the signed-in user can do, no more.

eDiscovery and compliance search are out of scope.

---

## 2. Locked decisions

| Decision | Choice | Why |
|---|---|---|
| Backend | Microsoft Graph (no EWS, no COM) | EWS deprecated; Graph is supported path |
| Auth library | **`Microsoft.Graph.Authentication` (Connect-MgGraph)** | Supported by Microsoft; uses MSAL.NET under the hood; built-in encrypted token cache. **Replaces `MSAL.PS`** — see `CHANGES.md` §1. |
| Auth flow | Delegated, interactive + PKCE | No service account; permissions = user's |
| Transport | stdio (Phase 1), HTTPS Streamable (Phase 3) | Validate locally before hosting |
| Language | PowerShell 7 | User preference; first-class Graph SDK |
| Write tools | Two-step confirm + audit + dry-run default | Defeat prompt-injected one-shot mutations |
| Hosted user model (Phase 3) | Per-user OAuth | No privilege laundering |

---

## 3. Phase breakdown

| Phase | Scope | Effort | Exit criteria |
|---|---|---|---|
| 0 | Spike — `Connect-MgGraph` → enumerate archive folders on Jeff's mailbox | 0.5 d | `Spike-ArchiveAccess.ps1` returns folder tree; second run is silent |
| 1 | Read-only stdio MCP (5 tools) wired into Claude Desktop, Pester green | 2 d | Claude can search/list/read archive on Jeff's box |
| 2 | Write tools (restore/copy/move), two-step confirm, audit log, dry-run | 2 d | Move/copy of 10-item batch round-trips successfully with audit entry |
| 3 | HTTPS transport, per-user OAuth, encrypted token cache, ACA deploy | 2 d | Two users on different boxes use the hosted instance with isolated tokens |
| 4 | Hardening to security checklist; production rollout | 1 d | All `mcp-security-considerations.md` items verified, including §19 deltas |

**Total:** ~7.5 days focused work.

---

## 4. Phase 0 — Spike (0.5 day)

**Deliverable:** [`local-mcp/spike/Spike-ArchiveAccess.ps1`](../local-mcp/spike/Spike-ArchiveAccess.ps1).

Steps:
1. Register Entra app — single-tenant, public client, delegated `Mail.Read`, `Mail.ReadWrite`, `User.Read`, `offline_access`. Redirect URIs:
   - `http://localhost` (loopback for `Connect-MgGraph`)
   - `https://claude.ai/api/mcp/auth_callback` (for the future Foundry MCP — register now to avoid a second consent later)
2. `Install-Module Microsoft.Graph.Authentication -Scope CurrentUser`.
3. `Connect-MgGraph -ClientId <app-id> -TenantId <tenant-id> -Scopes Mail.Read,User.Read,offline_access`.
4. `Invoke-MgGraphRequest -Uri 'v1.0/me/mailFolders?$filter=displayName eq ''Archive''&includeHiddenFolders=true'`.
5. Walk `childFolders` recursively; print tree + item counts.
6. **Second run** must be silent — no browser prompt — confirming the token cache works.

**Exit:**
- Archive folder hierarchy printed to console
- Token cache at `%LOCALAPPDATA%\Microsoft\Graph\TokenCache\` exists (Microsoft.Graph.Authentication uses MSAL.NET's standard cache)
- Second invocation completes without browser prompt
- The check from [`docs/audit-verification.md`](../docs/audit-verification.md) has been run against Jeff's mailbox

---

## 5. Phase 1 — Read-only stdio MCP (2 days)

### 5.1 Repo scaffold

```
exchange-archive-mcp/
├── ExchangeArchiveMcp.psd1            # manifest, ModuleVersion = source of truth
├── src/
│   ├── Server.ps1                     # stdio entry — JSON-RPC 2.0 loop
│   ├── Auth/
│   │   ├── Connect-McpGraph.ps1       # wraps Connect-MgGraph with our app reg + scopes
│   │   └── Resolve-UserContext.ps1
│   ├── Tools/
│   │   ├── Search-Archive.ps1
│   │   ├── Get-ArchiveMessage.ps1
│   │   ├── Get-ArchiveAttachment.ps1
│   │   ├── List-ArchiveFolders.ps1
│   │   └── Get-ArchiveStats.ps1
│   ├── Lib/
│   │   ├── Invoke-McpGraph.ps1        # thin wrapper over Invoke-MgGraphRequest; retry, client-request-id
│   │   ├── ConvertTo-KqlQuery.ps1
│   │   └── Write-AuditLog.ps1
│   └── Transport/
│       └── StdioTransport.ps1
├── tests/Pester/
├── config/appsettings.example.json
├── DESIGN.md                          # link to ../local-mcp/DESIGN.md
├── SECURITY.md                        # link to ../local-mcp/SECURITY.md
├── version.md
└── README.md
```

> **Note on Lib/Invoke-McpGraph.ps1:** with `Microsoft.Graph.Authentication` we lean on `Invoke-MgGraphRequest` for ~80% of calls. The wrapper only exists to add (a) consistent `client-request-id` headers for correlation, (b) retry with backoff on 429/503, and (c) MCP-shaped error translation. Much smaller than the rev 1 design assumed.

### 5.2 MCP protocol surface (Phase 1)

- JSON-RPC 2.0 over stdio.
- Methods: `initialize`, `tools/list`, `tools/call`, `ping`.
- Notifications: `notifications/cancelled` honoured during long Graph paging.
- Capabilities advertised: `tools` only.

### 5.3 Read tools

| Tool | Scope | Notes |
|---|---|---|
| `archive_search` | `Mail.Read` | KQL-style; 10k Graph ceiling; pagination cursor |
| `archive_get_message` | `Mail.Read` | Full body + headers by ID |
| `archive_download_attachment` | `Mail.Read` | Writes to `/mnt/user-data/outputs` |
| `archive_list_folders` | `Mail.Read` | Tree + item counts; walks hidden folders |
| `archive_get_stats` | `Mail.Read` | Size, count, quota |

### 5.4 Tool dispatcher

`Server.ps1` parses each JSON-RPC request, validates the method, looks up the tool name in a hashtable populated at startup, invokes with validated `arguments`. Tool functions return PS objects; dispatcher serialises to MCP `content` array (text blocks; attachments → resource links). Errors thrown as typed exceptions in `Lib`; dispatcher translates to MCP error responses.

### 5.5 Auth flow

- First run: `Connect-MgGraph -Scopes ... -ClientId ... -TenantId ...` triggers interactive browser sign-in.
- Token cache: MSAL.NET's default cache at `%LOCALAPPDATA%\Microsoft\Graph\TokenCache\`. DPAPI-encrypted via the user's profile (CurrentUser scope by default on Windows).
- Subsequent runs: silent refresh handled by the SDK. If silent fails and no TTY → return MCP error directing the user to run `Connect-ExchangeArchiveMcp` once.

### 5.6 Testing (Pester 5)

- `Mock Invoke-MgGraphRequest` for unit tests.
- `tests/Pester/Tools.Search.Tests.ps1`, `.Folders.Tests.ps1`, etc.
- One smoke test gated by `GI_E2E=1` against a test mailbox.
- CI: run on `pwsh` GH Actions runner.

### 5.7 Claude Desktop wiring

```jsonc
{
  "mcpServers": {
    "exchange-archive": {
      "command": "pwsh",
      "args": ["-NoLogo", "-File", "C:\\path\\to\\src\\Server.ps1"]
    }
  }
}
```

> **Stdio-only.** This config file pathway works fine for local stdio servers and is unchanged from rev 1. The Foundry MCP, which is remote/HTTP, uses the **Connectors UI** instead — see [`docs/claude-desktop-wiring.md`](../docs/claude-desktop-wiring.md).

**Exit:** Claude Desktop lists all 5 tools, search returns ≥1 message, attachment downloads to outputs folder, Pester green, audit log shows `debug` entries for each read.

---

## 6. Phase 2 — Write tools (2 days)

### 6.1 Three new tools

| Tool | Scope | Risk |
|---|---|---|
| `archive_restore_item` | `Mail.ReadWrite` | Restore to original primary-mailbox folder |
| `archive_copy_to_primary` | `Mail.ReadWrite` | Copy to explicit destination; archive retained |
| `archive_move_to_primary` | `Mail.ReadWrite` | Move to explicit destination; archive removed |

### 6.2 Two-step confirm pattern

1. `*_preview` call resolves target item IDs, validates destination, returns:
   ```json
   {
     "items": [...],
     "count": 23,
     "destination": "Inbox/Restored",
     "confirmation_token": "ct_8f3a...",
     "expires_at": "2026-05-21T14:38:21Z",
     "requires_human_review": false
   }
   ```
   `confirmation_token` is HMAC-SHA256 over `{tool, sha256(item_ids), dest_folder_id, expires_at}`, 5-min TTL.
2. `*_execute` validates HMAC + expiry, performs Graph operation.

### 6.3 Guardrails

- `dry_run: true` is the **default** on every write tool. Mutation requires explicit `dry_run: false`.
- Count > 100 → `requires_human_review: true` in preview; execute refuses unless `acknowledged_bulk: true` is also passed.
- Confirmation token is single-use (token ID logged; replay returns error).
- No free-form Graph passthrough tool. Ever.

### 6.4 HMAC key

- Generated at first run by `New-ConfirmationToken.ps1`.
- DPAPI-encrypted at `%LOCALAPPDATA%\ExchangeArchiveMcp\hmac.key`.
- Rotated on `Reset-ExchangeArchiveMcp -RotateHmac`.

### 6.5 Audit log

`%LOCALAPPDATA%\ExchangeArchiveMcp\audit\YYYY-MM-DD.jsonl`, append-only (no edit tool). One entry per write call:

```json
{
  "ts": "2026-05-21T14:33:21Z",
  "caller_upn": "jmonaco@gipartners.com",
  "tool": "archive_move_to_primary",
  "mode": "execute",
  "params_redacted": { "item_count": 23, "destination_folder": "Inbox/Restored" },
  "confirmation_token_id": "ct_8f3a...",
  "graph_request_id": "a1b2c3...",
  "result": "success",
  "duration_ms": 1842
}
```

### 6.6 Pester additions

- HMAC tamper test (flip a byte → reject).
- TTL expiry test (advance clock → reject).
- Replay test (same token twice → second rejected).
- Bulk-ack test (count=150, no `acknowledged_bulk` → refuse).

**Exit:** A `move` of 10 items between archive and primary round-trips; audit log contains preview + execute entries; tampered token is rejected.

---

## 7. Phase 3 — HTTPS transport + Azure hosting (2 days)

### 7.1 Transport

- HTTP Streamable per MCP spec.
- TLS 1.2 minimum; prefer 1.3.
- Bearer-token auth; tokens issued by Entra ID against the same app reg.
- Per-request user identity derived from `oid` claim; **never** trusted from request body.
- Rate limit: 60 req/min/user at transport layer.
- **Serve `/.well-known/oauth-protected-resource`** per RFC 9728 — see [`docs/protected-resource-metadata.md`](../docs/protected-resource-metadata.md). Required by MCP spec 2025-06-18.

**Transport hardening tasks** (design lessons carried from the `security-baseline/reference-impl` review — port the lessons, never the code; see 2026-07-20 addendum):

| Task | Detail | Finding |
|---|---|---|
| Per-request error boundary | One malformed request must not crash the listener — isolate, return a JSON-RPC error, keep serving | 9 |
| Bounded request-body read | Hard ceiling (1 MB) via a bounded read loop — never trust `Content-Length` (it is `-1` for chunked transfers) | 24 |
| `Origin`/`Host` validation on every request | Even behind auth — a bearer token alone is not a CSRF/DNS-rebinding defense | 10, 49 |
| Generic client-facing auth errors | Return `"Authentication failed."`; log the specific reason (audience, expiry, signature) server-side only | 11 |
| Listen-prefix validation | Reject wildcard/`0.0.0.0` binds in `MCP_LISTEN_PREFIX` at startup | 23 |
| Structured JSON auth-event logging | To the audit sink, never `Write-Host` | 26 |
| **Bind confirmation token to caller `oid`** | Add the verified Entra `oid` to the HMAC input (`DESIGN.md §6.2`) — **gate: multi-user hosting must not ship without this**, or a token minted in one session replays from another | 39 |
| Replay-guard store keyed by user | Move `Test-ReplayGuard` from process memory to a per-user server-side store | 38 |

### 7.2 Per-user token cache (hosted)

- Azure Storage blob per user, encrypted with a Key Vault–wrapped DEK.
- KEK access via Container App managed identity.
- Private endpoint–only storage account.
- Soft-delete + versioning on.

### 7.3 Deploy target

- Azure Container Apps in `rg-exchange-mcp-prod`.
- Image built from `pwsh:7.4` base; non-root user; read-only root FS.
- Outbound NSG: `graph.microsoft.com:443`, `login.microsoftonline.com:443` only.
- Ingress: HTTPS only, custom domain, mTLS optional Phase 4.
- App Insights for ops logs; audit goes to append blob + Log Analytics workspace `la-gipartners-mcp`.

### 7.4 Entra config

- Same single-tenant app reg (`exchange-archive-mcp`) — add hosted callback URI.
- Public client (no secret). PKCE required.
- Conditional Access: enforce MFA on the app reg.

**Exit:** Two users on two laptops use `https://exchange-archive-mcp.gipartners.com/mcp` with isolated tokens; audit log in Log Analytics shows correct `caller_upn` for each.

---

## 8. Phase 4 — Security hardening (1 day)

Walk the `mcp-security-considerations.md` Quick Reference Checklist top-to-bottom, including the new **§19 — 2025-06-18 spec deltas** appendix. Specific items that need explicit attention for this server:

| § | Item | Verification |
|---|---|---|
| 1 | Token `aud`/`iss`/`exp` validated on every request (Phase 3 only) | Unit test with tampered claims |
| 3 | Token passthrough disabled | Code review — server never forwards client bearer to Graph |
| 4 | Input validation — KQL builder rejects raw OData injection | Pester fuzz tests on `ConvertTo-KqlQuery` |
| 5 | Least privilege — only the 4 delegated scopes, no application scopes | `Get-MgServicePrincipal` matches manifest |
| 6 | Listener on `127.0.0.1` (local HTTP variant) | netstat check |
| 7 | All cache files DPAPI / Key Vault — never plaintext | grep for plaintext secrets in repo |
| 11 | Audit fields satisfy minimum log schema (§11 table) | Sample entry inspection |
| 12 | Write tools gated by two-step confirm | Already in Phase 2 |
| 13 | Rate limit 60 req/min/user (hosted) | Load test |
| 14 | Dependabot or equivalent on `Microsoft.Graph.*` modules | GH config |
| **19** | **PRM endpoint served at `/.well-known/oauth-protected-resource`** (Phase 3) | **curl check** |
| **19** | **Resource Indicator (RFC 8707) on token requests from client** (Phase 3) | **JWT inspection** |

**Exit:** Checklist signed off; tag `v1.0.0`; document in `SECURITY.md` which items are deferred (e.g. multi-tenant — N/A for single-tenant deploy).

---

## 9. Risks

1. **Hidden-folder traversal gaps.** Pre-cloud-archive items may not be Graph-visible. Document the gap; skip EWS fallback unless blocking.
2. **Graph throttling.** `Invoke-McpGraph` must honour `Retry-After`; backoff 1/2/4/8/16s then fail.
3. **Destructive `move` semantics.** `move` removes archive original. Mitigated by two-step confirm + audit; `copy` is the safer default in tool descriptions.
4. **Token cache theft.** MSAL.NET's cache uses DPAPI on Windows, tied to user/machine pair. Key Vault DEK hosted.
5. **Prompt injection.** Last line of defence is the MCP layer — see two-step confirm, dry-run default, bulk ack, no Graph passthrough.

---

## 10. Open decisions

> Resolved 2026-07-02 (remediation finding 21): **dry-run defaults ON** for every write tool. This is a locked, load-bearing prompt-injection control, not an open decision — see `local-mcp/DESIGN.md` and the Pester regression test asserting the default.

- Audit sink in Phase 2: local JSONL only, or wire Log Analytics now? **Default:** local only; wire LA in Phase 3.
- Hosted target: Azure Container Apps assumed; confirm before Phase 3 kickoff.
- Confirmation token TTL: 5 min default; revisit after Phase 2 user testing.
- **Client ID for `Connect-MgGraph`:** Use our own app reg from day 1 (don't fall back to the default Graph Command Line Tools client ID). Decided in spike.

---

## 11. Out of scope

- eDiscovery / compliance search
- Calendar, contacts, tasks
- Shared mailbox / public folder access
- EWS fallback
- Outbound mail (send)
- Mailbox-level settings, retention policies, holds
- Hard delete operations
