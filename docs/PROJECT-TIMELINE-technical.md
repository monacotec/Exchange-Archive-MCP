# Exchange Archive MCP — Engineering Timeline (Jul 21–24, 2026)

**Goal:** let Claude / Foundry agents read Exchange Online **In-Place (Online) Archive**
mailboxes (incl. executives' auto-expanding archives) under per-user auth.

## Timeline & milestones

**1. Security-addendum reconciliation (7-21).** Walked the 49-finding remediation
crosswalk against the progressed code; folded real gaps into the build plans.
✅ 45/45 Pester green; correlation-id error masking, case-sensitive tool dispatch,
KQL hardening, KV `AuditEvent` diagnostics deployed.

**2. Key Vault rename + resource cleanup (7-21).** Migrated `kv-exmcp-m63g6qb2pp`
→ `kv-exmcp-gi` (create → copy 5 secrets → repoint via bicep `keyVaultNameOverride`
→ verify → soft-delete old). Purged an unused spike Foundry account. ✅ zero downtime.

**3. Claude Desktop connector auth (7-21).** Chased a chain of Entra failures:
Dynamic Client Registration unsupported → set client ID manually; callback URIs on
the **Web** platform forced confidential-client → moved to **public-client** (PKCE);
admin consent + missing `Mail.Read` Graph scope granted. ✅ connector authenticates.

**4. PIVOT — Graph cannot read the archive (7-21→22).** Every archive well-known
folder (`archivemsgfolderroot`, `archiveroot`, `archiveinbox`) returns **404
ErrorInvalidMailboxItemId** — on v1.0 **and** beta, with **both** interactive and
OBO tokens. Microsoft Search API doesn't index the archive either. ⚠️ Confirmed an
**unshipped Graph capability**, not a defect (mailbox is Active/non-expanded).
EWS retires 2026-10-01, so it's not an option.

**5. eDiscovery data path — E0/E1/E2 (7-22).** Chose Purview eDiscovery Graph APIs
(the only GA, archive-capable, post-EWS surface; covers auto-expanding archives).
- E0 spike: eDiscovery search found the archive-only 2022 message (**15 hits, ~90s**). ✅
- Setback: app-only calls **401** on the human-created case → eDiscovery Manager only
  sees app-created cases → **app-owned case** model. ✅
- Setback: per-user source reuse **409** ("already exists") mis-handled → **one case
  per caller** (oid-named), which also hardened isolation. ✅
- E2: report-only export → parse → **full item list returned end-to-end**. ✅

**6. Desktop "open in Outlook" handler (7-22→24).** No supported URL scheme opens a
specific message in classic Outlook (Microsoft-confirmed). D0 spike proved Outlook
COM `AdvancedSearch` on **PR_INTERNET_MESSAGE_ID proptag 0x1035001F** opens an
online-archive message (the `mailheader:message-id` DASL fails). ✅ Built the signed
C# `giparchive:` handler + Azure Artifact Signing plan/runbook (identity validation
is the long pole).

**7. Git (7-24).** Secret-scanned, `.gitignore`/`.gitattributes`, refreshed README,
initial commit, pushed to a private remote. ✅

**8. Export bug (reported 7-23, fixed 7-24).** `archive_get_search_results` failing.
Diagnosis proved the service/permissions/format/parse all healthy; reproduced live:
the tool **blocked ~40s then returned `report_generating`** (export now ~50s) →
tripped the MCP client ("haults Claude") and needed a resume call. ✅ Fix: poll
budget 40→15s, session 90→35s, poll-based tool contract + self-describing errors.

## Recurring environmental setbacks
- **EDR egress filtering** blocks curl/pwsh TLS (only az's stack passes) → all endpoint
  checks via `az rest` / user shell.
- **az extension loads crash** (WinError 5 on dist-info) → used `az rest` over ARM.
- **EXO WAM broker crashes under PS7** → scripts self-relaunch to Windows PowerShell 5.1.
- **Conditional-access token expiry** (4-h) mid-session; **hard rule adopted:** no direct
  az/Graph from the agent — all Azure work ships as user-run `.ps1` (enforced by a
  PreToolUse deny hook).

## Status
Archive is readable for all mailbox types via eDiscovery (live). Pending: deploy the
export-timing fix (v3.4.0); Artifact Signing identity validation → sign/ship the
desktop handler; alert-tuning to suppress MCP-originated eDiscovery alerts; Phase-6
hardening → tag v1.0.0.
