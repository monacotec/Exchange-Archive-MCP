# SECURITY.md — Exchange Archive MCP

## Threat model summary

**Assets**
1. Mail content in archive mailboxes (potentially privileged, regulated, MNPI for a PE firm).
2. Delegated access tokens for the signed-in user.
3. The MCP server process itself (anything it can do, an attacker controlling it can do).

**Adversaries**
1. Malicious prompt injection into Claude attempting to coerce destructive operations.
2. Local malware on the workstation reading the token cache.
3. (Hosted) network attacker against the HTTP transport.
4. (Hosted) tenant insider misusing shared infrastructure.

**Trust boundaries**
- User ↔ Claude client (Anthropic-controlled).
- Claude client ↔ MCP server (this codebase).
- MCP server ↔ Microsoft Graph (Microsoft-controlled).

## Permissions

Delegated Graph scopes, requested at sign-in:

| Scope | Used by | Justification |
|---|---|---|
| `Mail.Read` | All read tools | Minimum for archive search/read. |
| `Mail.ReadWrite` | Restore/copy/move | Required for any move-back operation. |
| `User.Read` | `Resolve-UserContext.ps1` | Identifies the caller for audit. |
| `offline_access` | Token refresh | Avoids re-prompting. |

No `Mail.Send`, no `Mail.ReadWrite.Shared`, no application-permission equivalents.

## Token cache protection

### Local
- File: `%LOCALAPPDATA%\ExchangeArchiveMcp\msal.cache.bin`.
- DPAPI-encrypted with `CurrentUser` scope.
- ACL: user-only (inherited from `%LOCALAPPDATA%`).
- Deleted on `Disconnect-ExchangeArchiveMcp`.

### Hosted
- Per-user encrypted blob in Azure Storage.
- DEK wrapped by Azure Key Vault key; KEK access via managed identity of the Container App.
- Storage account is private endpoint–only; no public blob access.
- Soft-delete + versioning enabled.

## Mitigations against prompt injection

The MCP layer is the last line of defence — Claude can be tricked. Therefore:

1. **All write tools require two-step confirm.** Claude must obtain a token from a `preview` call and then pass it back. A prompt-injected attacker cannot skip step 1 because the token is HMAC-signed by the server.
2. **`dry_run` defaults to `true`** on every write tool. Mutation requires explicit `dry_run: false`.
3. **Confirmation tokens have a 5-minute TTL** and are bound to the exact item ID set (via hash) and destination. Token cannot be reused for a different operation.
4. **Item-count guardrails.** Any write op affecting > 100 items returns a `requires_human_review` flag in the preview; execute will refuse unless `acknowledged_bulk: true` is also passed. The intent is to force a deliberate "yes I mean it" for bulk destructive operations.
5. **No free-form Graph passthrough tool.** Every Graph call is funnelled through a typed tool. There is intentionally no `graph_raw_request` tool.

## Audit

Every write-tool call is logged. See `DESIGN.md §Audit logging`. The local JSONL log is append-only **by convention, not enforcement** — the server exposes no edit tool, but the account the server runs as retains NTFS write access to the files, so this is not a tamper-resistance guarantee (REMEDIATION-GUIDE finding 20). If an incident-response scenario ever depends on tamper-proof audit, ship each record to an external append-only sink (Log Analytics) in near-real-time; in hosted mode (Phase 3) the sink is an Azure append blob, which does enforce append-only at the API level.

**Sink routing.** To keep search terms out of the durable audit stream:

- `preview`, `execute`, `error` modes → `%LOCALAPPDATA%\ExchangeArchiveMcp\audit\YYYY-MM-DD.jsonl` (durable audit).
- `read` mode → `%LOCALAPPDATA%\ExchangeArchiveMcp\audit\debug\YYYY-MM-DD.jsonl` (debug-level).

Read entries record fact-of-call only — tool, caller UPN, duration, result. The `params_redacted` field is forcibly emptied on the `read` path inside `Write-AuditLog` so a future caller cannot regress this by passing a populated hashtable. Errors raised from any tool (read or write) go to the durable sink.

## Network

### Local
- Outbound only: `graph.microsoft.com:443`, `login.microsoftonline.com:443`.
- No inbound listener.

### Hosted
- TLS 1.2+ only.
- HTTP transport authenticates clients with OAuth bearer tokens issued by Entra ID against the same app registration.
- Per-request user context derived from the bearer token; never trusted from request body.
- Rate limit: 60 req/min per user at the transport layer, independent of Graph throttling.

## Secrets

- **No client secret.** Public client + PKCE.
- **No PATs in code.** Confirmation-token HMAC key is generated at first run, stored DPAPI-encrypted locally or in Key Vault hosted.
- **No secrets in audit logs.** Token IDs are logged, raw tokens are not.

## Failure modes and their security implications

| Failure | Implication | Mitigation |
|---|---|---|
| Stale confirmation token replayed | Attacker tries to reuse a captured token | TTL + HMAC binding to item-ID hash |
| User account compromised | Attacker has same access as the user | Out of scope for MCP; relies on Entra Conditional Access + MFA |
| Token cache exfiltrated locally | Attacker can act as user from another machine | DPAPI ties decryption to the user/machine pair |
| MCP process compromised | Attacker can call any tool | Reduce blast radius via the guardrails above; rely on audit for detection |
| Graph throttles aggressively | DoS risk | Backoff + caller-visible error; no silent retries beyond 5 attempts |

## Incident response

If a destructive operation is run in error:
1. Pull the audit JSONL entry (caller, time, items, destination).
2. Items are in the destination folder, not deleted — `move` is a folder change, not a hard delete. Reverse with another `move` from destination back to archive.
3. If the destination was Deleted Items and retention has elapsed, recovery requires admin retention tools — outside MCP scope.

## What this MCP intentionally does NOT do

- Send mail.
- Delete items.
- Modify mailbox-level settings, retention policies, or holds.
- Access other users' mailboxes (delegated = only the signed-in user's mailbox).
- Bypass any Entra Conditional Access policy applied to the user.
