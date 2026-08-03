# Bug-Fix Plan — `archive_get_search_results` export failure

**Bug:** `BUG-archive-export-failure.md` (2026-07-23). Estimate succeeds every
time; the report-only export leg returns generic `Request failed.` every time,
independent of query / size / `top`.
**Owner:** Jeff | **Created:** 2026-07-23 | **ROOT CAUSE CONFIRMED + FIX BUILT 2026-07-24**

## RESOLUTION (2026-07-24)

Reproduced live via the connector tools: `search_archive_mail` → succeeded
instantly; `archive_get_search_results` **blocked ~40s then returned
`report_generating`** (no items); a **resume call with `export_operation_id`
returned the full, correct item list**. So the export pipeline is CORRECT — the
bug is **latency/UX**: the tool blocked ~40s (tripping the MCP client → "haults
Claude / excessive time") and required a resume call the agent often didn't make
("no results"). The eDiscovery report export now takes ~50s (new-eDiscovery
backend), so the first call essentially always hit the old 40s budget.

**Fix shipped (function_app v3.4.0, ediscovery v1.6.0):**
- Poll budget 40→**15s**, session timeout 90→**35s** — the tool returns FAST and
  never blocks the client; it's explicitly poll-based.
- Tool description + estimate/status notes rewritten to tell the agent this is a
  poll-until-`complete` loop (call again with `export_operation_id`), not an error.
- Observability (Phase 3): failed export ops log their error object; a no-rows
  outcome raises a specific message (file names, HTTP status/body, download errors)
  instead of the generic `Request failed.`
- **Deferred (offer):** prewarm the export when the estimate succeeds so results
  returns in one poll — latency polish, only if the poll loop still feels chatty
  after this deploys.

## Key evidence the report didn't have

**This exact export path succeeded on 2026-07-22.** During the E2 build session,
`archive_get_search_results` returned `status: complete` with a full 15-item array
for the "Access for Melissa" search (jmonaco's per-user case). There is no
non-export code path that returns items — so the export leg (exportReport → poll →
download → parse) **demonstrably works**. That rules out the report's hypothesis #1
("not implemented / stubbed") and points at an **environmental change** between
7-22 and 7-23:

- Purview **PAYG billing** state (exports meter; estimates do not — this is the
  single best fit for "estimate always works, export always fails, size-independent").
- A **permission / token** change (export vs. estimate, or the download-resource token).
- A **deploy** that landed after 7-22 (the D2 `open_desktop_url` change,
  function_app v3.3.0) — additive and post-download, so unlikely, but verify the
  live version.

Because the generic `Request failed.` hides the real exception, **the plan is
diagnosis-first. Do not build a fix before Phase 1 names the cause** — this repo's
whole history says guessing API/permission causes wastes days.

## Phase 1 — Diagnose (two independent probes; do both)

1. **Trace the correlation IDs.** The bug lists five. Run the existing
   `foundry-mcp/scripts/Get-McpErrorTrace.ps1` on each (start with one 45-hit and
   one CY2023 id):
   ```
   .\Get-McpErrorTrace.ps1 -CorrelationId 7b17a717-0e56-4cce-9af9-eb9b24776048
   .\Get-McpErrorTrace.ps1 -CorrelationId f47cec6d-a6ad-40d8-a88d-8dfdad54dad9
   ```
   Captures the real exception + stack behind `Request failed.`

2. **Reproduce in isolation.** New `foundry-mcp/scripts/Test-EDiscoveryExport.ps1`
   (built alongside this plan) runs the export leg app-only from your shell against
   a provided `search_id`, printing the **raw HTTP status/body at each step**
   (exportReport POST → Location → operation poll → op status/error →
   exportFileMetadata → download GET). This shows *which* step fails and with what
   code, without waiting on App Insights ingestion.

The two probes converge on one of the root-cause branches below.

### Phase 1 finding UPDATE (2026-07-24, Test-EDiscoveryExport.ps1 v1.2.0 — full pipeline)

The **complete pipeline works app-only from the shell today**, including the leg
the tool does that v1.1 didn't test: download → unzip → parse → column-map. The
report is the **new-eDiscovery format** (`Items_0_*.csv`, 130+ cols, + Locations/
Settings/Summary); the ranker picks `Items_0`, it has 9 data rows, and **all six
tool mappings hit** (Subject/Title, Sender/Author, Received, Internet message ID,
Immutable ID, Original path). So billing/permission/token/format/parser are ALL
disproven. Two takeaways:

1. **Likely transient (new-eDiscovery migration window).** Same 7-22 code that
   worked for Melissa; shell pipeline 100% green today; download host is the new
   `*.proxyservice.ediscovery.svc.cloud.microsoft`. The 7-23 failures may already
   be gone. **Decisive check: reproduce via the connector today.**
2. **Real latent timing cliff.** The export operation took ~48-54s to reach
   `succeeded`; the tool's in-call poll budget is **40s**. For these HR searches
   the tool hits the budget → returns `report_generating` (needs a resume call);
   the tiny Melissa export finished inside 40s. Fix regardless (Phase 2/3 below).

**Fixes to ship regardless of transient-vs-persistent (safe, address the cliff +
make any future failure self-describing):**
- Raise the export poll budget (40s → ~90s; the tool session timeout is already 90s
  — align or extend) so typical exports complete in one call.
- `download_report_items`: on download HTTP≥400 or no-CSV-with-rows, raise a
  SPECIFIC error (which file, which status, member list) and log the response body
  server-side — so the generic `Request failed.` never hides an export/parse cause
  again (Phase 3 observability).
- Confirm the async `report_generating` → resume path returns cleanly and the agent
  is guided to call back with `export_operation_id` (tool description wording).

### Phase 1 finding (2026-07-24, Test-EDiscoveryExport.ps1 v1.1.0)

The **entire eDiscovery service side is healthy, app-only**: `exportReport` → 202
with a valid operation Location; operation → `succeeded`; report **downloaded
HTTP 200** (7,964-byte zip) using the MicrosoftPurviewEDiscovery token +
`X-AllowWithAADToken`. This **disproves** the billing (402), export-permission
(403), download-token (401), and Location-parse branches. The failure is therefore
**inside the Function App**, after the point the shell reproduced — the remaining
suspects are (a) the zip-open + CSV-parse in `download_report_items` /
`_parse_items_csv` returning empty→`RuntimeError("no parsable item report")`, (b) the
Function runtime's outbound reach to the `*.ediscovery.svc.cloud.microsoft` proxy
host (aiohttp vs. the shell), or (c) a deployed-version mismatch. The correlation-ID
trace names which. NOTE: the same code returned 15 parsed rows on 7-22, so (a)/(b)
represent an environmental/format change, not never-worked code.

## Phase 2 — Fix (branch on the Phase 1 finding)

| Phase-1 signal | Root cause | Fix |
|---|---|---|
| HTTP 402 / `Quota`/`Billing`/`Subscription` in the exportReport or operation error | **Purview PAYG billing not attached** (exports meter; estimates don't) | Enable Purview pay-as-you-go billing in the Purview portal (Settings → Billing); attach the subscription. Portal step; **no code change**. Document in the eDiscovery runbook. |
| HTTP 403 on `exportReport` | App/role lacks the **export** capability distinct from search | Grant the missing eDiscovery permission/role; extend `Initialize-EDiscoveryAccess.ps1`. Re-verify with `Test-EDiscoveryAppAccess.ps1`. |
| `exportReport accepted but no operation id in Location` | Response shape differs (id in body, not the Location format my regex expects) | Fix `start_export_report`: read the operation id from the response body / `Operation-Location` header / `azureAsyncOperation` as well as `Location`. |
| HTTP 401/403 on the `downloadUrl` GET | Wrong download-resource token or header | Fix `_purview_download_token` audience / `X-AllowWithAADToken`; confirm `eDiscovery.Download.Read` on the MicrosoftPurviewEDiscovery SP. |
| Operation `status: failed` (server-side) with an error object | Export genuinely failing server-side | Surface the operation's error detail (see Phase 3) to see *why*, then address (often billing again). |

## Phase 3 — Harden error observability (do regardless of branch)

The failure was opaque because the code raises a generic `RuntimeError`. Improve so
the next failure names itself in App Insights (client still gets the safe generic
message + correlation id):

- `start_export_report` and the poll loop in `archive_get_search_results`: on a
  failed operation, read `operation.error` / status-detail and include it in the
  server-side `logger`/`_audit` line (not the client response).
- `EDiscoveryClient._req`: on 4xx for the export/operation calls, log the response
  **body** server-side (it carries the billing/permission reason), not just the
  code.
- Keep the generic client envelope unchanged (finding #16 posture).

## Phase 4 — Regression coverage (do regardless of branch)

- Keep `Test-EDiscoveryExport.ps1` as the standing **end-to-end export check**
  (estimate → status → export → download → parse) runnable after any eDiscovery
  change. Honest constraint: true CI is out of scope under the az-restricted,
  user-run model — a documented, repeatable script is the pragmatic equivalent.
- Add a note to `foundry-mcp/version.md` release process: run it after touching
  `ediscovery.py` or the eDiscovery permissions.

## Non-goals / notes

- The `too_many_results` gate (500) is not implicated — both failing searches (45,
  9) are well under it.
- The async `report_generating` branch is not the failure (it returns cleanly, not
  an error) — but Phase 1's trace will confirm the throw is pre-return.
- Workaround for triage only (in the bug): primary-mailbox `outlook_email_search`;
  does not reach archive-only items.
