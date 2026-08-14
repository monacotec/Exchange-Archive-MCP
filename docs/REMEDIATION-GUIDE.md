# Security Remediation Guide — MCP Exchange Archive Bundle

**Format:** learning-oriented. Each section teaches a *principle*, shows the *findings that prove it*, gives the *fix*, and — where the reviewers' own proposed fix was wrong — a **Gotcha** so you learn the trap, not just the patch.

> **Reading the file paths (updated 2026-08-14).** This audit was run against the original
> layout, when the MCP lived inside the Foundry project as `gi-foundry/exchange-mcp/`.
> Since then that code was promoted to top-level [`foundry-mcp/`](../foundry-mcp/) and
> rewritten (rev 2), and the Foundry project itself was archived to
> [`archive/gi-foundry/`](../archive/gi-foundry/) — see
> [`gi-foundry-lessons.md`](gi-foundry-lessons.md).
> References that still resolve are linked. References to the **pre-promotion** MCP
> sources (`exchange-mcp/*`, and the three `scripts/*` that moved with it) are shown as
> plain text on purpose: those files no longer exist at those paths, and the cited line
> numbers refer to the audited revision, so linking them to today's `foundry-mcp/` files
> would point at different code. Findings 1 and 3 in particular describe the design this
> suite deliberately moved away from.

**How this was produced:** nine parallel reviewers audited every component against [`mcp-security-ps1/mcp-security-considerations.md`](mcp-security-ps1/mcp-security-considerations.md); every finding was then handed to an independent adversarial verifier told to *refute* it by reading the real code. Only findings that survived refutation are here. **49 findings survived** (23 confirmed, 26 plausible); severity peaks at **high** (no individual finding rose to critical once exploitability was checked, though two *themes* are critical in aggregate). One finding was rejected outright as a false positive — see Appendix B, because knowing what *isn't* a bug is part of the training.

---

## Overall assessment

> This bundle is not safe to expose beyond a trusted single-user loopback context in its current state. The most serious weaknesses are architectural, not incidental: the system trusts client-supplied authorization claims instead of re-deriving authority from a verified role; a tenant-wide app-only Graph credential lets any caller read any (approved) mailbox — a textbook confused deputy; and the cloud deployment gates a publicly reachable endpoint behind a single static key with no OAuth/JWT/RBAC. High-value secrets (OpenAI keys, storage keys) get materialized into ARM deployment history, CI logs, and plaintext temp files, so exposure outlives the code that ran. Cross-cutting hygiene gaps — case-insensitive/non-constant-time crypto comparisons, verbose error/log leakage, missing resource limits, absent Origin/Host validation — recur across nearly every component, which tells you the security *requirements were understood in the docs but not consistently enforced in the code.*

**Read that last sentence twice.** The bundle *documents* excellent security intentions. The findings are almost all places where the code, IaC, or spec quietly diverged from its own stated intent. That gap — between what the README promises and what the code enforces — is the single most important theme in this review.

---

## Severity snapshot

| Severity | Count | Where the weight is |
|---|---:|---|
| High | 9 | Authorization model, secret handling in IaC, one crypto comparison, one DoS |
| Medium | 16 | Injection, error/log leakage, missing rate limits, spec contradictions |
| Low | 24 | Lifecycle hygiene, doc/enforcement drift, latent fragilities |

By component: `jwt-service` 7 · `foundry-python` 7 · `local-mcp-design` 7 · `server-entry` 6 · `foundry-iac-core` 6 · `ps-scripts` 6 · `authz-tools` 4 · `auth-middleware` 3 · `foundry-infra` 3.

---

## How to use this guide

1. Work the lessons **top-down** — they are ordered by aggregate severity. Lessons 1–5 are the ones that change the architecture; 6–11 are hardening.
2. Each finding shows `file:line`. Fixes are drop-in *after* you read the **Gotcha**, because in several cases the first-draft fix was itself buggy.
3. "Verify" steps tell you how to *prove* the fix — a fix you can't demonstrate isn't done.
4. A meta-lesson runs through the whole guide: **verify your fixes the way we verified the findings.** Nearly a third of the proposed remediations had a bug the adversarial pass caught. Fixing security code without testing the fix just moves the vulnerability.

---

# Lesson 1 — Never trust client-supplied authority *(aggregate: critical)*

**Principle.** Re-derive permissions from a *verified role* on the server; never let the caller hand you their own permission list. Bind access to a resource to the *authenticated principal's* identity, not to an argument the caller chose.

**Why it matters.** Authorization is only as strong as the thing it trusts. If the server trusts a `permissions` array that travelled in the token, the "role" is decorative and the RBAC map — the thing you *think* is the source of truth — is bypassed. In the cloud tier the same disease appears as a confused deputy: the server holds a powerful credential and lends it to whoever calls, because it cannot tell *who is asking*.

### Findings

- **[HIGH · confirmed] Dispatcher trusts the token's `permissions` claim, not the role** — [`mcp-security-ps1/04-ToolPermissions.ps1:168`](mcp-security-ps1/04-ToolPermissions.ps1) reads `$User.Permissions`, which `Test-JwtToken` ([`02-JwtService.ps1:224`](mcp-security-ps1/02-JwtService.ps1)) fills straight from `payload.permissions`; the role-derived set is used *only* as a fallback. A token with `role=readonly` but `permissions=["DeleteTodos"]` passes every per-tool check.
  **Fix — make the role authoritative and cap the claim to it:**
  ```powershell
  $rolePerms = Get-PermissionsForRole -Role $role
  if ($payload.permissions) {
      $claimed = @($payload.permissions | ForEach-Object { <# parse, see Lesson 4 #> })
      $permissions = @($claimed | Where-Object { $rolePerms -contains $_ })  # never exceed the role ceiling
  } else {
      $permissions = $rolePerms
  }
  ```

- **[HIGH · confirmed] App-only credential + caller-chosen mailbox = confused deputy** — `gi-foundry/exchange-mcp/function_app.py:67` builds a `ClientSecretCredential` with tenant-wide `Mail.Read`, then every tool reads whatever `user_email` the caller passed (lines 136, 216, 283). The server uses *its own* high-privilege identity to satisfy a mailbox the *caller* named.
  **Fix:** require an OAuth2 On-Behalf-Of flow so the caller presents a *user* token; derive `user_email` from the verified token claims, never from a free-form argument.
  **Gotcha:** the reachable set is bounded by the Exchange `ApplicationAccessPolicy` (the `MCP-ArchiveAccess` group) — so it's cross-user disclosure *within the approved group*, not the whole tenant. Still a real confused deputy. And note: the "just compare `user_email` to the caller's UPN" shortcut only works *after* you have a verified caller identity, which the shared-key model does not give you. The fix implies introducing per-user auth (Lesson 2), not adding a string compare.

- **[LOW · plausible] `MCP_ALLOWED_MAILBOXES` fails open** — `function_app.py:93` returns "allow" when the env var is unset. It's a per-deployment global list, never tied to the caller.
  **Gotcha:** this is *defense-in-depth*, not the primary gate (the `ApplicationAccessPolicy` is). "Deny-all when unset" would break local dev and contradicts the documented design. The genuinely correct fix is the identity-bound check above — which again requires Lesson 2.

- **[LOW · plausible] Confirmation token isn't bound to caller identity** — [`files/DESIGN.md:70`](files/DESIGN.md): the HMAC payload `{tool, item_ids_hash, dest_folder, expires_at}` carries no UPN/session. In hosted mode a token minted for user A carries nothing preventing reuse under user B's session.

**Verify.** Mint a `readonly` token with an inflated `permissions` array → the delete tool must still be denied. Call a Foundry tool with someone else's UPN → must be refused because the UPN doesn't match the verified caller.

---

# Lesson 2 — A shared static key is not authentication *(aggregate: critical)*

**Principle.** Authentication means *per-caller identity you can validate* (`aud`/`iss`/`exp`), rotate, and revoke. A single long-lived secret shared by everyone is an access *password*, not identity — and it must never be the *only* thing between the public internet and mailbox data.

**Why it matters.** If the key *is* the identity, you cannot say who acted, cannot scope one user differently from another, and cannot revoke one caller without breaking all of them. Put that on a public endpoint and one leaked string is total, unattributable access. CVE-2025-49596 (MCP Inspector RCE) and Trend Micro's 492 exposed servers are exactly this failure.

### Findings

- **[HIGH · confirmed] `x-functions-key` is the only transport auth** — `function_app.py:83` uses `AuthLevel.FUNCTION`: one static shared key, no OAuth/JWT, no `aud`/`iss`/`exp`, no per-client identity, no rotation, no RBAC. The key lives in Claude Desktop config, `.vscode/mcp.json`, API Center, and CI — many copies, one blast radius.
- **[HIGH · confirmed] That endpoint is public** — `infra/modules/functionapp.bicep:73` sets `publicNetworkAccess: 'Enabled'` with no `ipSecurityRestrictions`, no VNet integration, no Private Endpoint.
  **Fix (both):** front the endpoint with real identity — App Service Authentication (Easy Auth) bound to Entra validating `aud`/`iss`, *or* API Management / a JWT middleware (the pattern in [`mcp-security-ps1`](mcp-security-ps1/)). Add `ipSecurityRestrictions` (default `Deny`, allow only known egress) and prefer `publicNetworkAccess: 'Disabled'` + Private Endpoint. Keep the function key as a *secondary* network gate, never as identity.
- **[MEDIUM · plausible] Listener prefix from env with no validation** — [`Start-McpServer.ps1:76`](mcp-security-ps1/Start-McpServer.ps1) passes `MCP_LISTEN_PREFIX` straight to `HttpListener` even though the sibling module *documents* "NEVER use `http://+/` or `0.0.0.0`."
  **Fix + Gotcha:** check the raw string for the `+` wildcard **before** the `[Uri]` cast (`http://+:8080/` is not a valid URI authority and the cast can throw), and allowlist loopback hosts using `'::1'` (not `'[::1]'` — `Uri.Host` returns the IPv6 literal *without* brackets):
  ```powershell
  if ($prefix -match '://\+') { Write-Error 'Wildcard (+) prefix not permitted.'; exit 1 }
  $uri = [Uri]$prefix
  if ($uri.Host -notin @('127.0.0.1','localhost','::1')) { Write-Error "Refusing non-loopback bind '$($uri.Host)'."; exit 1 }
  ```
- **[MEDIUM · plausible] JWT secret checked for presence, not strength** — [`Start-McpServer.ps1:58`](mcp-security-ps1/Start-McpServer.ps1) only checks the var is non-empty.
  **Gotcha:** the documented `(New-Guid).Guid + (New-Guid).Guid` example is *fine* (~244 bits) — don't "fix" that. The real gap is nothing stops a *weak* secret. Add a length floor (`-lt 32` → refuse), but call it a floor, not an entropy check (32 identical chars would pass).
- **[LOW · plausible] Rotation keeps the previous secret valid** — `Rotate-MCPClientSecret.ps1:69` prunes by count (keep newest 2), so the prior secret stays live. Acceptable for zero-downtime overlap, but shorten the overlap window and give the retiring secret a near-term `EndDateTime` instead of the default +1 year.
- **[LOW · plausible] Runtime storage account is publicly reachable** — `functionapp.bicep:39` sets no `networkAcls`/Private Endpoint.
  **Gotcha:** on the **Consumption (Y1)** plan there is *no* VNet integration, so the Function must reach `AzureWebJobsStorage` over the public data plane — locking storage networking would break the runtime. Either accept the key-gated public plane and fix the *key* handling (Lesson 3), or move to Elastic Premium/Dedicated + VNet integration first.

**Verify.** Present an expired token, a wrong-`aud` token, and an `alg:none` token → all rejected. Hit the Function endpoint with no bearer (only the function key) → rejected once Easy Auth/JWT is in front. Confirm each caller's identity appears in logs (Lesson 6).

---

# Lesson 3 — Secrets must never be materialized into durable records *(aggregate: high)*

**Principle.** Prefer *keyless* identity (managed identity / Entra). When a secret is unavoidable, keep its lifetime and exposure minimal — and never let it land in deployment history, CI logs, plaintext files, or committed source, because those outlive the operation and are readable by a far broader audience than the vault.

**Why it matters.** Putting a key in Key Vault buys you nothing if the same key value is *also* written into the resource-group deployment record (readable with Reader), printed into a CI log (readable with repo access), or dropped in `%TEMP%`. The vault is RBAC-gated and private; those other sinks are not.

### Findings

- **[HIGH · confirmed] `listKeys()` written into a Key Vault secret's `value`** — [`foundry-iac/modules/openai.bicep:89`](../archive/gi-foundry/foundry-iac/modules/openai.bicep). ARM captures fully-resolved property values in the deployment operation record, retrievable by anyone with resource-group Reader.
  **Gotcha:** the *identical* anti-pattern is in [`foundry.bicep:43`](../archive/gi-foundry/foundry-iac/modules/foundry.bicep) (`credentials.key = listKeys(...)`). Fixing only `openai.bicep` leaves the leak. Fix *both*.
- **[HIGH · confirmed] `what-if --result-format FullResourcePayloads` prints resolved secrets to CI logs** — [`bicep-validate.yml:35`](../archive/gi-foundry/foundry-iac/.github/workflows/bicep-validate.yml). Once the OpenAI resource exists, `listKeys()` resolves and the key renders into the retained GitHub Actions log.
  **Fix:** drop `FullResourcePayloads` (default `ResourceIdOnly` is enough for PR validation) **and** remove the `listKeys`-into-property patterns so no secret can appear in any dump.
- **[HIGH · confirmed] Storage account key embedded as a plaintext connection string** — `functionapp.bicep:80`. `AzureWebJobsStorage` inlines `storage.listKeys().keys[0].value`; `allowSharedKeyAccess` is left default-`true`. That key can read/overwrite the *host keys* (including the `mcp_extension` key), i.e. take over the function.
  **Fix (works on Consumption):** `allowSharedKeyAccess: false`, grant the Function's managed identity `Storage Blob Data Owner` on the account, and switch to the identity form — set `AzureWebJobsStorage__accountName` (no key) and drop the connection string. This removes the secret *without* needing a plan upgrade.
- **[MEDIUM · confirmed] CI exposes `AZURE_CREDENTIALS` to PR-triggered runs** — [`bicep-validate.yml:11`](../archive/gi-foundry/foundry-iac/.github/workflows/bicep-validate.yml).
  **Gotcha:** fork PRs do *not* receive repo secrets — the exposure is same-repo branch PRs from collaborators (or a compromised collaborator account). Fix with OIDC federated credentials (`permissions: id-token: write`, `azure/login` with `client-id`/`tenant-id`/`subscription-id`, no stored secret). If you reach for `pull_request_target`, only with a required-reviewers `environment:` gate — naive `pull_request_target` that checks out PR head *re-introduces* the exact exfiltration.
- **[MEDIUM · confirmed] Live OpenAI key written to a plaintext temp file** — [`Rotate-OAIKey.ps1:79`](../archive/gi-foundry/scripts/Rotate-OAIKey.ps1) serializes the key into `%TEMP%\*.json` for `az ml connection update`.
  **Gotcha:** the tempting fix `az ml connection update --set credentials.key=<val>` is *worse* — it puts the key on the process command line (visible to process listings and ETW). Use the REST/PATCH-in-memory path, or if a file is unavoidable, ACL-restrict it to the current user and overwrite-then-delete in a `finally`.
- **[MEDIUM · plausible] OpenAI key stored inline as `authType: 'ApiKey'`** — [`foundry.bicep:43`](../archive/gi-foundry/foundry-iac/modules/foundry.bicep). A static, non-rotating, full-data-plane credential.
  **Fix + Gotcha:** switch to `authType: 'AAD'` (keyless) and grant the *consuming* identity the `Cognitive Services OpenAI User` role. **Keep `isSharedToAll: true`** — the reviewers' first draft flipped it to `false`, which breaks the intended inheritance to all Projects. And the role must go to the identity that actually issues inference (Project/agent), not only the Hub MI.
- **[LOW · plausible] `isSharedToAll: true` widens the key's blast radius** — [`foundry.bicep:41`](../archive/gi-foundry/foundry-iac/modules/foundry.bicep). Moot once you go keyless (nothing to share). If you must keep a key, pair `isSharedToAll: false` with explicit per-project grants.
- **[LOW · plausible] Committed dev secret + env mutation in a smoke test** — [`02-JwtService.ps1:239`](mcp-security-ps1/02-JwtService.ps1) hardcodes `'super-secret-dev-key-...'` and writes it to real `$env:` vars when run (not dot-sourced).
  **Gotcha:** the scary "swaps a live server's secret" story is *false* — `$env:` is process-scoped and the server dot-sources the module. Real issue is source hygiene: don't commit a secret; guard test blocks with `if ($MyInvocation.MyCommand.Path -eq $PSCommandPath)` and use an ephemeral local secret.

**Verify.** After deploy, run `az deployment operation group list` and grep for the key → must not appear. Open the latest CI log → no key. `az functionapp config appsettings list` → no `AccountKey=`. Confirm `allowSharedKeyAccess` is `false`.

---

# Lesson 4 — Cryptographic and identifier comparisons must be exact *(aggregate: high)*

**Principle.** MAC/signature checks use **case-sensitive, constant-time, byte-wise** comparison. Security-relevant identifiers (claims, tool names) match against an explicit allowlist, exactly as advertised — no lenient coercion.

**Why it matters.** PowerShell's `-eq`/`-ne`/`-contains` on strings are **case-insensitive by default**, and enum casts silently accept numeric strings and any casing. Each shortcut turns strict equality into loose equality — which is precisely what an attacker probes for.

### Findings

- **[HIGH · confirmed] Signature compared with case-insensitive `-ne`** — [`02-JwtService.ps1:189`](mcp-security-ps1/02-JwtService.ps1). Base64url is case-*sensitive*, so `$expectedSigB64 -ne $parts[2]` verifies only a case-folded projection of the signature *and* short-circuits (not constant-time). Verified: `'aB3d-_x' -ne 'Ab3D-_X'` → `False` (treated equal).
  **Fix — compare raw bytes in constant time:**
  ```powershell
  $expectedSigBytes = Get-HmacSha256Signature -Data $signingInput -Secret $script:JwtSecret
  try   { $actualSigBytes = ConvertFrom-Base64Url $parts[2] }
  catch { throw [System.Security.SecurityException]'Invalid token: signature verification failed.' }  # decode failure = clean reject
  if (-not [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($expectedSigBytes, $actualSigBytes)) {
      throw [System.Security.SecurityException]'Invalid token: signature verification failed.'
  }
  ```
  **Gotcha:** this is *not* a "forge any token" bypass — without the secret the attacker still can't compute a valid HMAC. It's a genuine *weakening* (case-folding shrinks comparison strength; timing leak), which is why it's high, not critical. Still fix it: crypto comparisons have no excuse.
- **[MEDIUM · confirmed] Numeric-string claims coerced to enums** — [`02-JwtService.ps1:221,226`](mcp-security-ps1/02-JwtService.ps1). `[UserRole]'0'` → `Admin`, `[Permission]'3'` → `DeleteTodos`.
  **Gotcha — the reviewers' first fix was broken:** `New-JwtToken` issues the role *lowercased* (`'admin'`), so a *case-sensitive* `-cnotin [UserRole].GetEnumNames()` (which are `Admin`/`User`/`ReadOnly`) rejects **every legitimate token**. Correct approach: validate the raw role case-insensitively against the issuance format, validate permissions against the Pascal-case names, and in both cases **reject purely-numeric strings** (`if ($claim -match '^\d+$') { throw }`) before casting.
- **[LOW · confirmed] Tool-name dispatch is case-insensitive** — [`04-ToolPermissions.ps1:162`](mcp-security-ps1/04-ToolPermissions.ps1) uses `-eq`, so `DELETE_TODO` resolves to `delete_todo`. Not an authz bypass (the permission still applies) but the server honors names it never advertised and logs the caller's casing. Use `-ceq`, and log `$tool.Name` (canonical) not `$ToolName`.
- **[LOW · plausible] `:`-stripping collapses distinct permission strings** — [`02-JwtService.ps1:226`](mcp-security-ps1/02-JwtService.ps1). `.Replace(':','')` maps `delete:todos` → `DeleteTodos` and any `x:y` → `xy`.
  **Fix + Gotcha:** replace substring surgery with an explicit `wire-string → enum` map that rejects unknowns — but change **both** `New-JwtToken` (emit) and `Test-JwtToken` (parse) to the same canonical form, or the module's own tokens throw.

**Verify.** Unit-test: flip one letter's case in a valid signature → rejected. Token with `role='0'` → rejected. Token with `role='Admin'` (wrong case vs issuance) → handled per your chosen canonical form, consistently. `alg:none` → rejected.

---

# Lesson 5 — Availability is a security property *(aggregate: high)*

**Principle.** Validate and bound all untrusted input; isolate per-request failures so one bad request can't kill the server; rate-limit and cap expensive downstream work.

**Why it matters.** A crash or memory-exhaustion triggered by one request is a denial of service. An uncapped recursive fan-out is a self-inflicted (or attacker-triggered) outage and cost event.

### Findings

- **[HIGH · confirmed] One malformed request crashes the whole server** — [`Start-McpServer.ps1:110`](mcp-security-ps1/Start-McpServer.ps1). The loop's `catch` only handles `HttpListenerException`; `ConvertFrom-Json` on a bad body ([`04-ToolPermissions.ps1:215`](mcp-security-ps1/04-ToolPermissions.ps1)) throws a *terminating* error under `$ErrorActionPreference='Stop'`, skips the catch, hits `finally`, and `$listener.Stop()` exits the process.
  **Fix — per-request error boundary:**
  ```powershell
  while ($listener.IsListening) {
      try { $context = $listener.GetContext() } catch [System.Net.HttpListenerException] { break }
      try {
          $user = Invoke-McpAuthMiddleware -Context $context
          if ($null -eq $user) { continue }
          Invoke-McpToolDispatcher -Context $context -User $user
      } catch {
          Write-Host "[REQUEST ERROR] $($_.Exception.Message)" -ForegroundColor Red
          try { $context.Response.StatusCode = 400; $context.Response.Close() } catch { }
      }
  }
  ```
  Also guard `ConvertFrom-Json` and return JSON-RPC `-32700`. **Gotcha:** it's an *authenticated* DoS (auth runs first), not an open one — still trivial for any valid low-priv token.
- **[MEDIUM · confirmed] Unbounded `ReadToEnd` on the request body** — [`04-ToolPermissions.ps1:214`](mcp-security-ps1/04-ToolPermissions.ps1). A multi-GB body is loaded into a string, then copied again by `ConvertFrom-Json`.
  **Gotcha — the naive fix truncates valid input:** a single `Stream.Read(buffer,0,max)` is *not* guaranteed to fill the buffer, and `ContentLength64` is `-1` for chunked transfers (bypassing a `-gt max` guard). Use a **bounded read loop** that aborts once total bytes exceed the ceiling, plus a read timeout:
  ```powershell
  $maxBytes = 1MB; $ms = [System.IO.MemoryStream]::new(); $buf = [byte[]]::new(8192); $total = 0
  while (($n = $request.InputStream.Read($buf,0,$buf.Length)) -gt 0) {
      $total += $n; if ($total -gt $maxBytes) { Write-HttpError -Response $response -StatusCode 413 -ErrorKey 'payload_too_large' -Message 'Body too large.'; return }
      $ms.Write($buf,0,$n)
  }
  $bodyRaw = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
  ```
- **[MEDIUM · plausible] No rate limiting / circuit breaker on tools** — `function_app.py:112`.
  **Gotcha:** the folder recursion *is* bounded (`max_depth` clamped 1–5, `top=50`). The higher-confidence gaps are (a) **no retry/backoff/circuit-breaker on Graph 429/503** (the tool fails hard under throttling) and (b) no per-caller rate limit / per-invocation Graph-call budget. If you add APIM rate limiting, also restrict direct network access or the limit is bypassable.

**Verify.** POST body `{` → server responds 400 and *stays up*. POST a 50 MB body → 413, memory flat. Simulate Graph 429 → tool retries with backoff, doesn't crash.

---

# Lesson 6 — Fail closed with uniform, non-revealing responses *(aggregate: medium)*

**Principle.** Client-facing errors are generic; the detail goes to a structured audit log server-side. Never let an error body or log line become a reconnaissance oracle or leak PII.

### Findings

- **[MEDIUM · confirmed] 401 body echoes the exact validation reason** — [`03-AuthMiddleware.ps1:117`](mcp-security-ps1/03-AuthMiddleware.ps1) returns `$_.Exception.Message` ("audience mismatch" vs "signature verification failed" vs "Token has expired"), contradicting the file's *own* stated design ("identical safe message"). Return `'Authentication failed.'` to the client; log the real reason.
  **Gotcha:** this doesn't enable *forging* a token (the signature stage still needs the secret) — it's information disclosure / config confirmation. Fix anyway; it violates the module's own invariant.
- **[MEDIUM · confirmed] Raw `str(exc)` returned to the caller** — `function_app.py:157` (also 244, 328). Graph/Kiota exceptions embed UPNs, mailbox GUIDs, request URLs, tenant IDs. Return `{"error": True, "message": "Request failed", "correlation_id": <uuid>}`; keep the full trace in `logger.exception`.
- **[MEDIUM · confirmed] No per-call audit fields** — `function_app.py:156`. §11 requires `timestamp, tool_name, user_identity, input_summary, output_summary` per call.
  **Gotcha / quick win:** only `user_identity` needs the auth redesign. `tool_name`, requested mailbox, input summary, result count, and timestamp can be logged **today** with a `logger.info` at start/end of each handler — do that now, add identity when Lesson 2 lands.
- **[LOW · plausible] Auth events go to `Write-Host`, not a rotating log** — [`03-AuthMiddleware.ps1:109`](mcp-security-ps1/03-AuthMiddleware.ps1). CLAUDE.md requires a rotating file under `logs/`. Emit `{ ts = [DateTimeOffset]::UtcNow.ToString('o'); event; user; role; path = $request.Url.AbsolutePath }` as JSON to that file (`AbsolutePath` drops the query string).
- **[MEDIUM · plausible] Key Vault has no diagnostic/audit logging** — [`foundry-iac/modules/keyvault.bicep:14`](../archive/gi-foundry/foundry-iac/modules/keyvault.bicep). Add a `diagnosticSettings` forwarding the **`AuditEvent`** log category (not `categoryGroup: 'audit'`) to Log Analytics; thread a `logAnalyticsWorkspaceId` param from `main.bicep`.

**Verify.** Send a wrong-`aud` token → body says only "Authentication failed"; the log says "audience mismatch." Trigger a Graph error → caller sees a correlation id, log has the detail. Confirm a Log Analytics query returns Key Vault `SecretGet` events.

---

# Lesson 7 — Treat all caller text as untrusted before it enters a query language *(aggregate: medium)*

**Principle.** Escape or (better) parameterize/allowlist caller input so it cannot break out into query operators.

### Findings

- **[MEDIUM · confirmed] `$search` value only wrapped in quotes** — `function_app.py:132` builds `f'"{query}"'`. A `"` in `query` closes the phrase and injected KQL (`from:`, `subject:`, `AND/OR/NOT`) is interpreted.
  **Gotcha:** backslash-escaping is *unreliable* for Graph KQL `$search`. Use the allowlist approach — cap length, restrict to a literal-phrase character set, and strip leading operator tokens. Severity is medium: injection is confined to the single already-authorized mailbox (a caller could pass operators as a legitimate query anyway).
- **[LOW · plausible] Same gap in the local KQL translator design** — [`files/DESIGN.md:62`](files/DESIGN.md) specifies "wrapped in quotes if multi-word" with no escaping/operator allowlisting for `ConvertTo-KqlQuery.ps1`. Specify the escaping now, before it's coded.

**Verify.** Search `" OR from:ceo@gipartners.com OR "` → returns only literal matches, not the injected broadening.

---

# Lesson 8 — Validate every dimension of a token/approval artifact and enforce single-use *(aggregate: medium)*

**Principle.** Check `nbf`/`iat`/`sub`/`exp`, bind approval tokens to a nonce and a caller, and never leave a security-relevant default ambiguous.

### Findings

- **[LOW · plausible] Only `exp` is validated** — [`02-JwtService.ps1`](mcp-security-ps1/02-JwtService.ps1) ignores `nbf` (not-before), `iat` sanity, and never validates `sub`. Add `nbf`/`iat` checks and validate `sub` matches `id`.
- **[LOW · plausible] Confirmation token is replayable within its TTL** — [`files/SECURITY.md:54`](files/SECURITY.md): stateless HMAC, no `jti`/nonce, no consumed-token store. Add a single-use nonce + server-side consumed-token set bound to the caller.
- **[MEDIUM · confirmed] `dry_run` default is documented as *both* locked-on and an open decision** — [`files/DESIGN.md:75`](files/DESIGN.md)/[`SECURITY.md:53`](files/SECURITY.md) say default `true`; [`PLAN.md:124`](files/PLAN.md) lists it under "Decisions still open." A load-bearing prompt-injection control must not be ambiguous. Delete the open-decision line and add a Pester test asserting each write tool defaults `dry_run` to `$true`.

**Verify.** A future-dated (`nbf` ahead) token → rejected. Replay a used confirmation token → rejected. Pester run proves the `dry_run` default.

---

# Lesson 9 — Enforce transport confidentiality and request-origin controls *(aggregate: medium)*

**Principle.** TLS for anything carrying credentials; validate `Origin`/`Host` on every request to block CSRF and DNS-rebinding — even on a loopback listener.

### Findings

- **[MEDIUM · confirmed] No `Origin`/`Host` validation** — [`03-AuthMiddleware.ps1:88`](mcp-security-ps1/03-AuthMiddleware.ps1) reads only `Authorization`. A bearer token is not a CSRF defense; without `Host` validation the loopback listener is DNS-rebinding-reachable from a browser.
  **Gotcha:** don't hardcode `127.0.0.1:8080` — `Start-McpServer` takes a configurable `-Prefix`. Derive the allowlist from the parsed prefix and compare case-insensitively.
- **[LOW · plausible] Bearer JWTs travel over plaintext HTTP** — [`Start-McpServer.ps1`](mcp-security-ps1/Start-McpServer.ps1) uses an `http://` prefix. Fine for pure loopback, but require TLS 1.2+ before this pattern is used off-box.

**Verify.** Request with a foreign `Host`/`Origin` → 403. Legitimate configured host → allowed.

---

# Lesson 10 — Keep the documented contract, the enforced model, and the code in agreement *(aggregate: low)*

**Principle.** Declaration drift is a security bug, because operators grant trust based on the *documentation*.

- **[LOW · confirmed] `delete_todo` says "admin or user role"; the map denies User** — [`04-ToolPermissions.ps1:79`](mcp-security-ps1/04-ToolPermissions.ps1) vs [`01-Authorization.ps1:68`](mcp-security-ps1/01-Authorization.ps1) (User lacks `DeleteTodos`). Someone "fixing" the perceived bug might over-grant delete to every User. Make the description match enforcement (or change the map *deliberately*, not to match a stale comment). Best: generate docs from the permission map, or assert equality in a test.

**Verify.** A test that reads each tool's declared permission and asserts the description matches the enforced role set.

---

# Lesson 11 — Manage secret and session lifecycles deterministically *(aggregate: low)*

**Principle.** Dispose crypto material, don't alias defense-critical state, always tear down privileged sessions, clean up artifacts, and pin/verify third-party dependencies. Individually minor; together they erode the guarantees of the stronger controls.

- **[LOW · plausible] `HMACSHA256` never disposed; secret held as an immutable `String`** — [`02-JwtService.ps1:77`](mcp-security-ps1/02-JwtService.ps1). Wrap in `try/finally { $hmac.Dispose() }`; a `String` can't be zeroed, so key material lingers in memory/dumps.
- **[LOW · plausible] Role-permission arrays shared by reference** — [`01-Authorization.ps1:99`](mcp-security-ps1/01-Authorization.ps1). Return `@($script:RolePermissions[$Role])` to hand out an independent copy. **Gotcha:** only the `Admin` value is actually aliased today (the `@(...)`-built User/ReadOnly arrays get copied on the typed assignment); latent, not live — but fix it before anyone adds per-request permission mutation.
- **[LOW · plausible] Graph/Exchange sessions not disconnected on failure** — `Register-EntraApp.ps1:34`, `Rotate-MCPClientSecret.ps1:38`, `Set-ApplicationAccessPolicy.ps1:47`. Under `$ErrorActionPreference='Stop'`, an exception skips the trailing `Disconnect-*`. Wrap the body in `try/finally` with a guaranteed disconnect (per your global CLAUDE.md rule).
- **[LOW · confirmed] `GetTempFileName()` orphans a zero-byte file** — [`Rotate-OAIKey.ps1:77`](../archive/gi-foundry/scripts/Rotate-OAIKey.ps1). `GetTempFileName()` *creates* a `.tmp`, then `+ '.json'` points elsewhere, leaking one file per run. Build the path with `[guid]::NewGuid()` instead and clean up in `finally`.
- **[LOW · plausible] Spike installs MSAL.PS with `-Force`, no version pin/signature check** — [`Spike-ArchiveAccess.ps1:46`](files/Spike-ArchiveAccess.ps1). Pin `-RequiredVersion`, verify the publisher, and don't suppress the untrusted-repo prompt in anything beyond a throwaway spike.
- **[MEDIUM · confirmed] "Append-only" local audit log isn't tamper-resistant** — [`files/SECURITY.md:60`](files/SECURITY.md). "No edit tool" is not an OS guarantee; the same user the server runs as can rewrite the JSONL, and the IR plan depends on it. Either **downgrade the wording** (don't claim tamper-resistance) or ship each record to an external append-only sink (Log Analytics/Sentinel) in near-real-time. **Gotcha:** local hash-chaining is weak here because the HMAC key is itself stored locally (DPAPI) and a same-user attacker can recompute the chain — the external sink is the robust remedy.

**Verify.** Force each script to throw mid-run → confirm the session is disconnected. Run the rotation twice → no orphaned temp files. Confirm audit records appear in the external sink within seconds.

---

# Prioritized remediation roadmap

Do them in this order — earlier items unblock later ones.

1. **Identity before everything (Lessons 1 + 2).** Put OAuth/JWT (`aud`/`iss`/`exp`) in front of the Foundry endpoint and move to On-Behalf-Of so `user_email` comes from a verified token. This is the keystone: per-user audit (Lesson 6), fail-closed mailbox authz (Lesson 1), and rate-limiting-by-caller (Lesson 5) all depend on having a real identity.
2. **Stop leaking secrets in IaC/CI (Lesson 3).** Go keyless (Entra) for the OpenAI connection in *both* bicep files; identity-based `AzureWebJobsStorage`; drop `FullResourcePayloads`; move CI to OIDC.
3. **Fix the crypto comparison and enum validation (Lesson 4)** — small, self-contained, high value. Ship with unit tests.
4. **Add the per-request error boundary and body cap (Lesson 5)** so the reference server can't be crashed by one request.
5. **Generic errors + structured audit (Lesson 6)** — the mailbox/tool/timestamp audit is a same-day quick win even before identity lands.
6. **Injection escaping, token-claim completeness, Origin/Host, and the lifecycle sweep (Lessons 7–11).**
7. **Resolve the `dry_run` doc contradiction and add its regression test (Lesson 8)** before the write tools are implemented.

**And the meta-lesson:** in this very review, roughly one proposed fix in three had a bug the adversarial pass caught (a case-sensitive check that rejects all valid tokens; a single `Read()` that truncates; an `az --set` that leaks to the command line; a `[Uri]` cast that throws on the wildcard it's meant to reject). Treat every fix as new code: test it, and have someone try to break it.

---

## Appendix A — Full findings index

Legend: **C**=confirmed, **P**=plausible (likely real, exploitability or severity tempered by the verifier).

| # | Sev | V | Component | Finding | Location |
|--:|---|---|---|---|---|
| 1 | High | C | authz-tools | Dispatcher trusts token `permissions` claim, not role | [04-ToolPermissions.ps1:168](mcp-security-ps1/04-ToolPermissions.ps1) |
| 2 | High | C | foundry-python | App-only credential + caller-chosen mailbox (confused deputy) | function_app.py:67 |
| 3 | High | C | foundry-python | Shared `x-functions-key` is the only transport auth | function_app.py:83 |
| 4 | High | C | foundry-infra | MCP endpoint public, static key only | functionapp.bicep:73 |
| 5 | High | C | foundry-infra | Storage key inline plaintext connection string | functionapp.bicep:80 |
| 6 | High | C | foundry-iac-core | `listKeys()` into KV secret `value` → deployment history | [openai.bicep:89](../archive/gi-foundry/foundry-iac/modules/openai.bicep) |
| 7 | High | C | foundry-iac-core | `what-if FullResourcePayloads` prints key to CI log | [bicep-validate.yml:35](../archive/gi-foundry/foundry-iac/.github/workflows/bicep-validate.yml) |
| 8 | High | C | jwt-service | Signature compared case-insensitively (`-ne`) | [02-JwtService.ps1:189](mcp-security-ps1/02-JwtService.ps1) |
| 9 | High | C | server-entry | Malformed request crashes the server | [Start-McpServer.ps1:110](mcp-security-ps1/Start-McpServer.ps1) |
| 10 | Med | C | auth-middleware | No `Origin`/`Host` validation | [03-AuthMiddleware.ps1:88](mcp-security-ps1/03-AuthMiddleware.ps1) |
| 11 | Med | C | auth-middleware | 401 body leaks exact validation reason | [03-AuthMiddleware.ps1:117](mcp-security-ps1/03-AuthMiddleware.ps1) |
| 12 | Med | C | foundry-iac-core | CI exposes `AZURE_CREDENTIALS` to PR runs | [bicep-validate.yml:11](../archive/gi-foundry/foundry-iac/.github/workflows/bicep-validate.yml) |
| 13 | Med | P | foundry-iac-core | OpenAI key inline `authType: ApiKey` | [foundry.bicep:43](../archive/gi-foundry/foundry-iac/modules/foundry.bicep) |
| 14 | Med | P | foundry-iac-core | Key Vault has no diagnostic logging | [keyvault.bicep:14](../archive/gi-foundry/foundry-iac/modules/keyvault.bicep) |
| 15 | Med | C | foundry-python | `$search` value not escaped (KQL injection) | function_app.py:132 |
| 16 | Med | C | foundry-python | Raw `str(exc)` returned to caller | function_app.py:157 |
| 17 | Med | C | foundry-python | No user identity in any log line | function_app.py:156 |
| 18 | Med | P | foundry-python | No rate limit / Graph circuit breaker | function_app.py:112 |
| 19 | Med | C | jwt-service | Numeric-string claims coerced to enums | [02-JwtService.ps1:226](mcp-security-ps1/02-JwtService.ps1) |
| 20 | Med | C | local-mcp-design | Local audit log not tamper-resistant | [SECURITY.md:60](files/SECURITY.md) |
| 21 | Med | C | local-mcp-design | `dry_run` default: locked-on *and* open decision | [PLAN.md:124](files/PLAN.md) |
| 22 | Med | C | ps-scripts | Plaintext OpenAI key to temp file | [Rotate-OAIKey.ps1:79](../archive/gi-foundry/scripts/Rotate-OAIKey.ps1) |
| 23 | Med | P | server-entry | `MCP_LISTEN_PREFIX` unvalidated (0.0.0.0/+) | [Start-McpServer.ps1:76](mcp-security-ps1/Start-McpServer.ps1) |
| 24 | Med | C | server-entry | Unbounded `ReadToEnd` (memory DoS) | [04-ToolPermissions.ps1:214](mcp-security-ps1/04-ToolPermissions.ps1) |
| 25 | Med | P | server-entry | JWT secret presence-only, no strength floor | [Start-McpServer.ps1:58](mcp-security-ps1/Start-McpServer.ps1) |
| 26 | Low | P | auth-middleware | Auth events to `Write-Host`, not rotating log | [03-AuthMiddleware.ps1:109](mcp-security-ps1/03-AuthMiddleware.ps1) |
| 27 | Low | C | authz-tools | `delete_todo` doc/role drift | [04-ToolPermissions.ps1:79](mcp-security-ps1/04-ToolPermissions.ps1) |
| 28 | Low | C | authz-tools | Tool-name dispatch case-insensitive | [04-ToolPermissions.ps1:162](mcp-security-ps1/04-ToolPermissions.ps1) |
| 29 | Low | P | authz-tools | Role-permission arrays shared by reference | [01-Authorization.ps1:99](mcp-security-ps1/01-Authorization.ps1) |
| 30 | Low | P | foundry-iac-core | `isSharedToAll: true` widens key blast radius | [foundry.bicep:41](../archive/gi-foundry/foundry-iac/modules/foundry.bicep) |
| 31 | Low | P | foundry-infra | Runtime storage publicly reachable | functionapp.bicep:39 |
| 32 | Low | P | foundry-python | `MCP_ALLOWED_MAILBOXES` fails open | function_app.py:93 |
| 33 | Low | P | jwt-service | `:`-stripping collapses permission strings | [02-JwtService.ps1:226](mcp-security-ps1/02-JwtService.ps1) |
| 34 | Low | P | jwt-service | Smoke test hardcodes secret, mutates env | [02-JwtService.ps1:239](mcp-security-ps1/02-JwtService.ps1) |
| 35 | Low | P | jwt-service | No `nbf`/`iat` validation | [02-JwtService.ps1](mcp-security-ps1/02-JwtService.ps1) |
| 36 | Low | P | jwt-service | HMAC object not disposed; secret as `String` | [02-JwtService.ps1:77](mcp-security-ps1/02-JwtService.ps1) |
| 37 | Low | P | jwt-service | `sub` claim issued but never validated | [02-JwtService.ps1](mcp-security-ps1/02-JwtService.ps1) |
| 38 | Low | P | local-mcp-design | Confirmation token replayable within TTL | [SECURITY.md:54](files/SECURITY.md) |
| 39 | Low | P | local-mcp-design | Confirmation token not bound to caller | [DESIGN.md:70](files/DESIGN.md) |
| 40 | Low | P | local-mcp-design | KQL free-text not escaped (design) | [DESIGN.md:62](files/DESIGN.md) |
| 41 | Low | P | local-mcp-design | HMAC compare semantics unspecified | [DESIGN.md:71](files/DESIGN.md) |
| 42 | Low | P | local-mcp-design | Spike installs MSAL.PS `-Force`, no pin | [Spike-ArchiveAccess.ps1:46](files/Spike-ArchiveAccess.ps1) |
| 43 | Low | C | ps-scripts | `GetTempFileName()` orphans a temp file | [Rotate-OAIKey.ps1:77](../archive/gi-foundry/scripts/Rotate-OAIKey.ps1) |
| 44 | Low | P | ps-scripts | Exchange session not disconnected on failure | Set-ApplicationAccessPolicy.ps1:47 |
| 45 | Low | P | ps-scripts | Graph session not disconnected (Register) | Register-EntraApp.ps1:34 |
| 46 | Low | P | ps-scripts | Graph session not disconnected (Rotate secret) | Rotate-MCPClientSecret.ps1:38 |
| 47 | Low | P | ps-scripts | Old client secret stays valid after rotation | Rotate-MCPClientSecret.ps1:69 |
| 48 | Low | P | server-entry | Bearer JWTs over plaintext HTTP | [Start-McpServer.ps1](mcp-security-ps1/Start-McpServer.ps1) |
| 49 | Low | P | server-entry | No Origin/Host validation (entry) | [Start-McpServer.ps1](mcp-security-ps1/Start-McpServer.ps1) |

---

## Appendix B — What the review *rejected* (learning to spot a false positive)

One finding was raised and then **rejected** by the adversarial pass:

- **"OData `$filter` echoed back verbatim to the caller"** (`function_app.py:238` returns the built `odata_filter` string). *Rejected because:* the value reflected is the caller's **own input** echoed back **to that same caller** — that is not information disclosure, and the single-quote doubling for the `from_address` filter is adequate OData escaping. The lesson: "user input appears in the response" is only a finding if it crosses a trust boundary (reaches a *different* principal) or breaks out of its context. Reflecting your own input to yourself does neither.

Several confirmed findings were also **de-escalated** during verification — worth internalizing, because over-claiming severity erodes trust in a report:

- The JWT signature bug is a *weakening*, not a forge-anything bypass (you still need the secret).
- The confused-deputy blast radius is bounded by the Exchange `ApplicationAccessPolicy` to the approved group, not the whole tenant.
- The malformed-request crash and the memory-DoS are *authenticated* denials of service (auth runs first), not open ones.
- The documented `(New-Guid).Guid + (New-Guid).Guid` secret is *not* weak (~244 bits) — the gap is the missing strength floor, not the example.

Calibrated severity is a security skill in its own right: it's what lets a reader trust the "high" items enough to act on them first.
