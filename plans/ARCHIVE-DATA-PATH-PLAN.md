# Archive Data Path — End-Solution Plan

**Created:** 2026-07-22, from the findings in `docs/online-archive-graph-findings.md`
**Decision owner:** Jeff
**Status:** E0 + E1 + E2 SHIPPED and verified end-to-end in production 2026-07-22. Live connector run as jmonaco returned the full 15-message "Access for Melissa" thread — incl. the 2022-04-20 archive-only original — via search → estimate → report-only export → parsed items. Per-caller case isolation confirmed (super-jmonaco correctly saw 0; jmonaco saw 15). Remaining: folder attribution (report CSV lacks/renames the folder column — see below), single-message body read, SECURITY.md delta, Phase 6.

**Known gap from the E2 run:** returned items carry subject/from/received/size/item_id/internet_message_id but NOT `folder` — the report-only export CSV either omits a folder-path column or names it outside the current candidate list in `ediscovery.py:_CSV_FIELD_CANDIDATES`. Capture a real report's headers to extend the mapping; not blocking (core retrieval works).

**Build-out corrections learned in E0/E1** (deltas from the original proposal):
- Sources bind via case **noncustodialDataSources** + `noncustodialSources@odata.bind` at search creation (inline sources rejected by v1.0).
- The standing case is **APP-OWNED** (found-or-created by display name): the eDiscovery Manager role cannot access human-created cases app-only — verified empirically. `EDISCOVERY_CASE_ID` is an optional override only.
- Org-level eDiscovery Premium features toggle enabled 2026-07-22.
- Governance: the app-owned case is invisible to human eDiscovery Managers; grant the admin account eDiscovery **Administrator** if portal-level audit of the app's searches is wanted (E3 item).

## 1. The situation, in four facts

1. **Microsoft Graph's Mail API cannot read In-Place Archives — for anyone.** Confirmed empirically on a healthy non-expanded archive (all well-known names 404 `ErrorInvalidMailboxItemId`, both token types, v1.0+beta) and confirmed by Microsoft: archive access is their most-reported EWS-parity gap, "working on delivering access… updated timeline in the coming months" (still unshipped as of the May 2026 import/export GA, which covers primary + shared only).
2. **The target population includes auto-expanding archives** (executives, e.g. jeff@gipartners.com). Any solution must handle them; auto-expanded archives are EWS/Purview-only even in Microsoft's own guidance.
3. **EWS is blocked 2026-10-01** for non-Microsoft apps and removed 2027-04-01. Building the archive data path on EWS buys ten weeks and a cliff.
4. **The Purview eDiscovery Graph APIs are GA** (Standard tier GA Nov 2025; E3 availability GA Feb 2026): cases, searches, holds, exports — app-only supported, searches cover primary + archive including auto-expanded, exports run on PAYG billing (50 GB/month free, then $10/GB).

## 2. Decision

**Two-layer architecture: a stable MCP tool contract over a swappable data path.**

- **Data path A — Purview eDiscovery (build now).** The only supported, GA, archive-capable, post-EWS API surface that exists today.
- **Data path B — native Graph archive Mail API (swap in when Microsoft ships it).** The Mail-API parity work will restore synchronous folder/message access and pure per-user OBO. The MCP's tool schemas are designed so this swap changes no client-facing contract.
- The existing v2.3.1 Graph resolver stays in the code and is tried first — the day Microsoft lights up `archivemsgfolderroot`, the MCP upgrades itself to path B behavior with zero deploy.

The Microsoft support case (`docs/microsoft-support-case-draft.md`) is now **optional**: Microsoft's public position already answers it ("not supported yet"). File only if we want to register pressure/get roadmap specifics.

## 3. How eDiscovery maps to the MCP tools

| Tool | Data path A implementation |
|---|---|
| `search_archive_mail` | eDiscovery search: KQL `{query}` scoped to the caller's archive (see §5); run **statistics/estimate + report-only export** for hit metadata (subject, from, received, size, location). No content export on the search path. |
| `get_mail_by_date_range` | Same, KQL `received>={start} AND received<={end}`. |
| `list_archive_folders` | No eDiscovery analogue. Interim behavior: return the item-location distribution from search statistics (folder paths of hits) with an explicit `"data_path": "ediscovery-interim"` note. Full tree returns with path B. |
| `get_archive_message` (new) | Narrow search on `internetMessageId`/item id → single-item export → parse and return body. Slow path (~minutes); documented as such. |
| `get_search_status` (new) | Poll handle for the async pattern (§4). |

## 4. Async pattern (the UX change)

eDiscovery searches are asynchronous — single-mailbox estimates typically complete in one to a few minutes, not sub-second. Tool behavior:

1. Tool call starts the search and polls up to ~45 s.
2. If complete → results returned inline (same JSON shape as today, plus `folder`/location fields).
3. If not → returns `{status: "running", search_id, retry_with: "get_search_status"}` and the MCP client (Claude) polls. Tool descriptions teach this so the model handles it naturally.
4. Server-side caching: per-caller results cached (KV of search_id → caller oid) so polls are cheap and cross-user access is impossible.

## 5. Security model delta — the big tradeoff (approval gate)

Today: the OBO token *is* the authorization — the server physically cannot read anyone but the caller.

With eDiscovery: the app holds **application-level eDiscovery permissions** (its service principal added to the Purview eDiscovery Manager role). The per-user boundary becomes an **application-enforced control**:

- Verified caller identity (Easy Auth → `oid`/`upn`) — unchanged.
- Search sources are constructed **server-side only** from the caller's identity; no caller-supplied mailbox parameters (same structural defense as the confused-deputy fix).
- Archive-only scoping via the org's existing convention: `MBX:{ArchiveGuid}@{TenantId}` — each user's `ArchiveGuid` resolved from an admin-maintained mapping (KV secret or app config; refreshed by an admin script), since Graph does not expose `ArchiveGuid`.
- One long-lived eDiscovery **case per MCP** (e.g. "Exchange Archive MCP — delegated reads"), searches created/deleted within it, fully audit-logged (App Insights + Purview's own audit of every search/export).
- `MCP_ALLOWED_MAILBOXES` remains as the outer allowlist.

This must be explicitly accepted (it's the same class of trust as the org's existing Purview automation, but it is a real change from token-scoped access).

## 6. Prerequisites (admin, one-time — shipped as user-run scripts per convention)

1. Grant the app reg the eDiscovery Graph **application** permissions + admin consent (extend `Set-ClaudeConnectorAuth.ps1` pattern).
2. Add the app's service principal to the Purview eDiscovery Manager role group.
3. Enable Purview PAYG billing for eDiscovery APIs (50 GB/month free tier likely covers this workload — searches/estimates are the hot path; content export is the rare path).
4. Create the standing eDiscovery case; store its id in app settings.
5. Admin script to build/refresh the UPN → ArchiveGuid map (`Get-Mailbox | select UserPrincipalName, ArchiveGuid` — runs in PS 5.1 per the WAM issue).

## 7. Build order

| Phase | Work | Est |
|---|---|---|
| E0 | Prereq scripts (§6) + spike: one manual eDiscovery search against jmonaco's archive via Graph, confirm the 2022 Alyssa message is findable and export-report metadata is usable | 1 d |
| E1 | `ediscovery_client.py` (case/search/poll/report) + rewire `search_archive_mail` and `get_mail_by_date_range` with the async pattern; keep Graph resolver as first-try | 2 d |
| E2 | `get_archive_message` single-item export path + `get_search_status`; folder-distribution interim for `list_archive_folders` | 1.5 d |
| E3 | Security hardening walk (SECURITY.md delta for §5, audit verification incl. Purview audit log), acceptance tests from the fix briefing §6 rerun | 1 d |
| E4 | Local MCP: same adapter in PowerShell, or (simpler) point the local stdio server at path-A logic only for archive tools | 1–2 d |
| — | **Path B swap** when Microsoft ships archive Mail API support: delete/bypass adapter, keep contract | 0.5 d when it lands |

## 8. Approval gates (answer before E1)

1. **Security model** (§5) — accept application-level eDiscovery access with app-enforced per-user scoping?
2. **Billing** — enable Purview PAYG on the subscription? (Estimates/report-only keep costs near zero; content export is metered.)
3. **Latency** — accept minutes-scale first-result latency for archive queries until path B lands?

## Sources

- EWS retirement + archive parity status: Microsoft 365 Developer Blog "Retirement of EWS in Exchange Online"; Exchange Team "EWS, Your Time is Almost Up" (Oct 2026 block / Apr 2027 removal)
- Import/export Graph APIs GA May 2026 — primary+shared only, archive "ongoing": M365 Dev Blog GA announcement
- eDiscovery Graph APIs GA + E3 + PAYG pricing: MC1148532; Microsoft Learn "Use Microsoft Purview APIs for eDiscovery"; Azure Feeds Feb 2026 GA note
