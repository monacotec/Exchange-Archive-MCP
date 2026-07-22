# Plan — `giparchive:` Protocol Handler → Open Archive Message in Classic Outlook

**Created:** 2026-07-22
**Goal:** clicking an archive search result (in Claude Desktop, OWA, or anywhere)
opens that exact message in the user's **classic Outlook desktop**, which already
has the Online Archive mounted in-profile — closing the gap that no native URL
scheme can (Microsoft-confirmed: there is no supported link to open a specific
message in Outlook desktop; see docs/online-archive-graph-findings.md context).

**Decisions (2026-07-22):** handler is a **code-signed C# exe** (signing via
**Azure Artifact Signing**, formerly Trusted Signing — see §6); rollout is
**all archive-enabled users** via Intune.

**Why a custom handler is the only route:** the MCP returns each item's
`internet_message_id` (RFC 5322 Message-ID). Outlook desktop can locate a message
by that id via COM `AdvancedSearch`. A per-machine URL-protocol handler bridges a
clickable link to that COM lookup. This is real but is a small first-party app
with an attack surface — hence the security section is not optional.

---

## D0 SPIKE RESULT — PASSED 2026-07-22 (Test-OutlookArchiveOpen.ps1 v1.2.0)

Confirmed on jmonaco's workstation against the **online-mode** (cached=False)
`Online Archive - jmonaco@gipartners.com` store. The known archive-only message
was resolved and **opened in Outlook**. Findings that pin the handler design:

- **Lookup key = PR_INTERNET_MESSAGE_ID proptag equality.** Filter
  `"http://schemas.microsoft.com/mapi/proptag/0x1035001F" = '<message-id>'`
  returned exactly 1 and displayed it. Message-ID alone suffices — no subject/date
  needed. **Do NOT use `urn:schemas:mailheader:message-id`** — that returned 0
  (not indexed for equality in the online store).
- Online-mode archive **is** searchable server-side (subject `like` returned all
  15; proptag equality returned the exact 1). Caching the archive is NOT required.
- **AdvancedSearchComplete event is unreliable** under a scripted STA host — it did
  not fire in 40s. The handler must **poll `Search.Results` with a pumped message
  loop** (`Application.DoEvents()` / equivalent), not await the event.
- **Multiple archive stores are mounted** (jmonaco + delegated helpdesk). Since the
  Message-ID is globally unique, the handler should scope AdvancedSearch across
  **all** `Online Archive -*` store roots and take the single hit — no need to know
  which archive owns it.
- Fallback path also proven (Method C): subject search + client-side filter on each
  hit's real Message-ID. Keep as the documented backup if proptag equality ever
  regresses.

---

## 1. End-to-end flow

1. MCP result includes `open_desktop_url = "giparchive:<url-encoded Message-ID>"`
   (alongside the existing OWA `open_url` fallback).
2. User clicks it. Browser/Claude Desktop launches the registered `giparchive:`
   handler, passing the full URI as `%1`.
3. Handler parses + **strictly validates** the Message-ID, connects to the
   running Outlook via COM, runs an `AdvancedSearch` scoped to the archive store
   with a DASL filter on `urn:schemas:mailheader:message-id`, and `.Display()`s
   the found `MailItem`.
4. Not found / Outlook not running → handler opens the OWA fallback URL instead,
   so the click never dead-ends.

---

## 2. Components

### 2.1 The link (MCP change — small)
- Add `open_desktop_url` to each item in `archive_get_search_results`
  (`function_app.py`) and a helper `giparchive_url(message_id)` in `ediscovery.py`
  mirroring `owa_message_url`. Scheme + URL-encoded Message-ID only; no other data.
- Keep `open_url` (OWA) as the documented fallback.

### 2.2 The handler (the real work)
- **Language:** compiled .NET (C#) single-file exe preferred over a raw PS script
  — cleaner registration, no execution-policy friction, harder to tamper, and it
  can enforce input validation before touching COM. (A signed PS7 script wrapped
  by a small launcher is an acceptable v0 for the spike.)
- **Responsibilities:** parse URI → validate Message-ID → Outlook COM
  `GetActiveObject`/`Application` → resolve the archive store → `AdvancedSearch`
  (async; wait on `AdvancedSearchComplete`) → `.Display()` → fallback to OWA on
  miss/timeout → structured local log to `%LOCALAPPDATA%\GIP\ArchiveOpen\logs`.
- **Archive store resolution:** enumerate `Namespace.Stores`, pick the store whose
  `ExchangeStoreType` is the archive (or match display name "Online Archive -*").
  Scope AdvancedSearch to that store's root folder path.
- **DASL filter:** `@SQL="urn:schemas:mailheader:message-id" = '<ID>'`. The ID is
  attacker-influenced → **escape single quotes** (DASL injection) and reject IDs
  not matching a strict Message-ID regex.

### 2.3 Protocol registration
- Per-user (`HKCU\Software\Classes\giparchive`) so it installs without admin and
  runs in the user's session (needed for Outlook COM). Keys: `URL Protocol`
  (empty), `shell\open\command` = `"<installdir>\ArchiveOpen.exe" "%1"`.

### 2.4 Browser auto-launch (seamless, no prompt)
- Without policy, the first click shows "Open giparchive?" each session. To
  suppress: Edge/Chrome `AutoLaunchProtocolsFromOrigins` policy allowing
  `giparchive` from the OWA/Claude origins — deploy via the same Intune channel.

### 2.5 Intune packaging
- Win32 app (`.intunewin`): payload = the exe + an `install.ps1` that copies to
  `%LOCALAPPDATA%\GIP\ArchiveOpen` and writes the HKCU keys; `uninstall.ps1`
  reverses both. Install context: **user** (HKCU + user-profile path).
- Detection rule: presence of the exe + the registry key.
- Ship the browser `AutoLaunchProtocolsFromOrigins` policy as a Settings Catalog
  profile assigned to the same group.

---

## 3. Security (not optional — a URL handler is remote-triggerable input)

- **Strict input validation:** accept only `giparchive:` + a value matching a
  conservative Message-ID pattern (`<...@...>`, bounded length, no shell/DASL
  metacharacters beyond what a Message-ID allows). Reject everything else with a
  logged no-op. This is the primary control.
- **No shell, ever:** the handler calls Outlook COM directly; the input never
  reaches a command line, `Start-Process`, `Invoke-Expression`, or a DASL string
  without quote-escaping.
- **Least capability:** runs as the user, displays only items that user's own
  Outlook profile can already open. It grants no new access — it's a convenience
  shortcut over data the user already has.
- **Tamper resistance:** code-sign the exe; install to a user path but consider
  HKLM + Program Files (system-context Win32 app) if you want the binary
  non-user-writable — trade-off vs. the per-user COM-session requirement (a
  system-path exe still launches in the user session via the HKCU command, so
  this is achievable: binary in Program Files, command registered in HKCU).
- **Privacy:** logs record Message-IDs (not content); keep them local, short
  retention.

---

## 4. Phases

| Phase | Work | Exit |
|---|---|---|
| D0 spike | ✅ **DONE 2026-07-22** — message opened from a script; lookup key confirmed (proptag 0x1035001F equality). See D0 SPIKE RESULT above. | ✅ met |
| **D-Sign** | **START FIRST (long pole).** Stand up Azure Artifact Signing: account, **Organization identity validation** (days of MS review), certificate profile, signer RBAC. See §6. | A test exe signs and chains to a publicly-trusted root |
| D1 handler | ✅ **CODE DONE 2026-07-22** — `desktop-handler/` (ArchiveOpen.csproj, Program.cs, build.ps1, register-dev.ps1). Strict Message-ID validation, COM `AdvancedSearch` proptag 0x1035001F across all `Online Archive -*` stores (poll+pump), `.Display()`, validated OWA fallback, logging. **Awaiting:** build on a .NET 8 box + local register-dev test; signing waits on D-Sign. | Signed exe runs from a `giparchive:` URI |
| D2 MCP link | ✅ **CODE DONE 2026-07-22** — `giparchive_url()` in ediscovery.py; `open_desktop_url` (+ existing `open_url`) in the results tool. **Awaiting `azd deploy`.** | Results carry both links |
| D3 package | `.intunewin` + install/uninstall + detection; browser `AutoLaunchProtocolsFromOrigins` policy | Clean install/uninstall on a test machine, click-through works |
| D4 pilot | Assign to a small group (you + one exec with an auto-expanding archive) | End-to-end click-to-open verified on managed hardware |
| D5 rollout | **Broaden Intune assignment to all archive-enabled users**; document in the IT runbook | Tenant-wide |

**Sequencing:** D-Sign runs in parallel with D1 code (identity validation is
Microsoft-gated wall-clock, not effort) but must finish before D1's signed-exit and
before D3. Start the identity validation immediately.

**Gate on D0.** ✅ Cleared — proptag equality resolves online-mode archive items
without caching. D1 is unblocked.

---

## 5. Decisions (all resolved 2026-07-22)

- ~~Cached vs online-mode archive~~ → online-mode, works without caching.
- ~~Handler language~~ → **signed C# exe** (Azure Artifact Signing; §6).
- ~~Scope~~ → **all archive-enabled users** (D5 = tenant-wide Intune assignment).

---

## 6. Code signing — Azure Artifact Signing (formerly Trusted Signing)

Cloud-managed signing: short-lived (72h) certs auto-issued from an org-validated
profile, chaining to a **publicly-trusted** Microsoft root — no HSM, no long-lived
cert to protect. This is the current Microsoft-recommended path and the right one
for an exe deployed to every workstation.

**Setup (one-time; delivered as a user-run script + portal steps per the
az-restriction — Claude does not run az directly):**

1. **Artifact Signing account** — create the resource in a supported region under
   subscription `db17a4a4…` (finresgroup or a dedicated RG).
2. **Organization identity validation** — submit GI Partners legal-entity docs.
   **This is the long pole (hours→days of Microsoft review) — start day one.**
   ⚠️ Verify eligibility first: Microsoft requires a **verifiable organization
   history (commonly ~3 years)**; if the legal entity or its public records are
   newer/mismatched, validation stalls — confirm before committing the timeline.
3. **Certificate profile** — type *Public Trust*, once identity is validated.
4. **Signer RBAC** — assign the **Trusted Signing Certificate Profile Signer** role
   to whoever/whatever signs (Jeff's build box user, or a CI service principal).
5. **Build-box prereqs** — Windows 10 1809+/11, **.NET 8 runtime**, `signtool`
   (Windows SDK), and the Trusted Signing **dlib** package; sign with
   `signtool sign /v /debug /fd SHA256 /tr <timestamp> /td SHA256 /dlib <dlib> /dmdf <metadata.json> ArchiveOpen.exe`.

**Cost:** consumption/low fixed monthly (basic tier) — confirm current pricing at
setup; negligible for signing a handful of exe revisions.

**Reuse dividend:** once Artifact Signing is stood up, it also covers signing the
other PowerShell scripts in this repo (the auth/rotation/deploy `.ps1`s), which are
currently unsigned — a standing security win beyond this handler.
