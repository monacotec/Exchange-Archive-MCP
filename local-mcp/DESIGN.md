# DESIGN.md — Exchange Archive MCP

## Conventions

- **Language:** PowerShell 7. No PS 5.1 in the runtime path. If an Appx/legacy cmdlet is needed, shim it the way `Deploy-Claude-Code` does.
- **Style:** Verb-Noun cmdlet names, PascalCase parameters, `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'` at script scope.
- **Errors:** Throw typed exceptions from Lib; catch and translate to MCP error responses only in the dispatcher.
- **No COM, no EWS.** Graph only.
- **File naming for any generated PDF artifacts:** `<vendor> YYYY-MM-DD <amount>.pdf` (user preference; applies to incidental outputs only).

## Module layout

`ExchangeArchiveMcp.psd1` is the manifest. `RootModule` is empty; each tool and lib is dot-sourced by `Server.ps1` from `src/`. Manifest version is the source of truth for releases — bump in lockstep with `version.md`.

## MCP protocol

- JSON-RPC 2.0 over stdio (Phase 1) and Streamable HTTP (Phase 3).
- Methods implemented: `initialize`, `tools/list`, `tools/call`, `ping`.
- Notifications: `notifications/cancelled` (honoured during long Graph paging operations).
- Capabilities advertised: `tools` only. No prompts, no resources in v1.

## Tool dispatcher

`Server.ps1` parses each request, validates the method, looks up the tool name in a hashtable populated at startup, and invokes it with the validated `arguments` object. Tool functions return a PowerShell object; the dispatcher serialises to MCP's `content` array (text blocks; attachment downloads return a resource link).

## Authentication

### Local (stdio)
- `Microsoft.Graph.Authentication` (`Connect-MgGraph`) interactive flow on first run. Token cache is managed by MSAL.NET inside the SDK at `%LOCALAPPDATA%\Microsoft\Graph\TokenCache\`, DPAPI-encrypted under the CurrentUser scope.
- Silent refresh on subsequent calls is handled by the SDK. If silent acquisition fails and no TTY is present, the dispatcher returns an MCP error directing the user to run `Connect-ExchangeArchiveMcp` once.
- Replaces the rev-1 MSAL.PS path. See `CHANGES.md` §1 for the rationale.

### Hosted (HTTP, Phase 3)
- OAuth 2.0 authorization code with PKCE. Each user signs in through their own browser.
- Per-user token cache in encrypted blob storage; key wrapped by Azure Key Vault DEK.
- No shared service account. No app-only fallback.

### Entra app registration (one-time)
- Single-tenant (GI Partners).
- Delegated permissions: `Mail.Read`, `Mail.ReadWrite`, `User.Read`, `offline_access`.
- Redirect URIs: `http://localhost` (loopback, local) + the hosted callback URL.
- Public client (no client secret).

## Archive folder access

Graph exposes the archive via the user's hidden folder tree. `List-ArchiveFolders.ps1` calls:

```
GET /me/mailFolders?$filter=displayName eq 'Archive'&includeHiddenFolders=true
```

then walks `childFolders` recursively. Item enumeration uses `/me/mailFolders/{id}/messages` with `$top=50` and `@odata.nextLink` paging. The dispatcher enforces a hard 10,000-item ceiling per call (Graph's documented limit) and returns a pagination cursor for callers that need more.

## Search

`archive_search` accepts a KQL-like query and translates to Graph `$search` (which uses KQL under the hood for mail). `ConvertTo-KqlQuery.ps1` handles common shortcuts:

| Input | Output |
|---|---|
| `from:alice@x.com` | `from:alice@x.com` (passthrough) |
| `after:2024-01-01` | `received>=2024-01-01` |
| `has:attachment` | `hasAttachments:true` |
| free text | wrapped in quotes if multi-word |

Searches are scoped to the archive folder subtree by ID, not by name (folder rename safety).

## Write operations (restore / copy / move)

All three follow the **two-step confirm** pattern. They are registered as three tools (`archive_restore_item`, `archive_copy_to_primary`, `archive_move_to_primary`), each taking a `mode` argument:

1. `mode: 'preview'` resolves target item IDs, looks up the destination folder ID, returns a summary plus a `confirmation_token` (HMAC-signed JSON: `{tool, item_ids_hash, dest_folder, expires_at}`, 5-minute TTL).
2. `mode: 'execute'` validates the token's HMAC, expiry, tool name, destination folder ID, and item-set hash, then performs the Graph operation. The destination is bound by **resolved ID**, not by display path — closes a folder-rename TOCTOU between preview and execute.

The HMAC comparison MUST be constant-time: `[System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals` over the raw signature bytes, never a string `-eq`/`-ne` (which short-circuits on first mismatch and is case-insensitive). `New-ConfirmationToken.ps1` implements this — do not regress it if the token layer is ever rewritten. **Phase 3 prerequisite:** before any multi-user hosted transport ships, the caller's Entra `oid` must be added to the HMAC input so a token minted in one user's session cannot be replayed from another's (REMEDIATION-GUIDE finding 39).

The shared engine lives in `Lib/Invoke-WriteOp.ps1`. `Restore-ArchiveItem.ps1` defaults its destination to the primary `Inbox` (Graph does not expose pre-archive folder history, so an exact "original folder" restore is not possible — callers should pass `destination_folder` when they have a more specific target). `Copy-ArchiveToPrimary.ps1` retains the archive original; `Move-ArchiveToPrimary.ps1` removes it.

Dry-run mode (`-WhatIf` semantics) is exposed via a `dry_run: true` argument. **Default is `true`** — Claude must explicitly pass `dry_run: false` to mutate.

### Guardrails layered on top of the token

- **Single-use replay protection.** `Lib/Test-ReplayGuard.ps1` tracks consumed token IDs in process memory; a replay within the 5-minute TTL is rejected. (Phase 3 HTTPS will need a server-side store keyed by user.)
- **Bulk threshold.** When an operation targets more than 100 items, `preview` returns `requires_human_review: true` and `execute` refuses unless the caller also passes `acknowledged_bulk: true`.
- **No Graph passthrough.** Every Graph call is routed through `Invoke-McpGraph`. There is intentionally no `graph_raw_request` tool.

## Audit logging

`Write-AuditLog.ps1` writes JSONL to `%LOCALAPPDATA%\ExchangeArchiveMcp\audit\YYYY-MM-DD.jsonl` (local) or to an Azure Storage append blob + Log Analytics workspace (hosted).

Every write-tool call logs:

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

Read tools log to a separate debug sink (`audit\debug\YYYY-MM-DD.jsonl`), fact-of-call only — no search terms or other parameters. See [`SECURITY.md`](SECURITY.md) §Audit for the routing matrix.

## Throttling and retries

`Invoke-GraphRequest.ps1` wraps every Graph call:

- Honours `Retry-After` (seconds or HTTP-date).
- Exponential backoff on 429/503: 1s, 2s, 4s, 8s, 16s, then fail.
- Adds `client-request-id` header (GUID) for correlation; surfaced in audit log.
- Surfaces `x-ms-resource-unit` and `x-ms-throttle-limit-percentage` to the dispatcher for backpressure decisions.

## Testing

- Pester 5, `tests/Pester/`.
- Graph layer mocked via `Mock Invoke-GraphRequest`.
- Confirmation-token tests cover HMAC tampering, expiry, replay.
- One end-to-end smoke test (gated by `GI_E2E=1` env var) against a test mailbox.

## Logging vs audit

- **Logs** (operational, may rotate, may be lossy): `Microsoft.PowerShell.Utility/Write-Information` + a JSON formatter to stderr (so it doesn't corrupt stdio MCP frames).
- **Audit** (security, append-only, retained): see above. Never goes to stderr.

## Versioning

Semver. `version.md` lists every file with an embedded version; bump together. `.psd1` `ModuleVersion` is the public-facing version users see.
