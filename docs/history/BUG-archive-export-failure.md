# BUG: `archive_get_search_results` export consistently fails while search estimate succeeds

- **Component:** Exchange Archive MCP (Azure Functions, OAuth 2.1 OBO)
- **Server URL:** `https://func-exchange-mcp-archive-mailbox-mcp.azurewebsites.net/runtime/webhooks/mcp`
- **Affected tool:** `archive_get_search_results`
- **Unaffected tools:** `search_archive_mail`, `archive_get_search_status`, `get_mail_by_date_range`, `list_archive_folders`
- **Severity:** High — the connector can size a result set but cannot return any per-item metadata, making search results unusable end to end.
- **Status:** Open
- **Date observed:** 2026-07-23
- **Reported by:** Jeff Monaco

## Summary

The eDiscovery-backed archive search pipeline estimates matches correctly on every call, but the report-only export step (`archive_get_search_results`) returns a generic `{"error": true, "message": "Request failed."}` on every attempt, with a fresh correlation ID each time. The failure is independent of query, result-set size, and the optional `top` parameter.

## Environment

- **Data path:** `ediscovery` (Graph mail API cannot address this archive; search is routed through Purview eDiscovery)
- **Auth:** delegated On-Behalf-Of (OBO), caller's own archive mailbox
- **HR sender under test:** `hr@gipartners.com`

## Observed behavior

The diagnostic pattern is consistent and one-directional: **the search estimate always succeeds; the metadata export never does.**

| Step | Tool | Result |
|---|---|---|
| Search estimate | `search_archive_mail` | Succeeds — returns `search_id`, `status: running` |
| Poll estimate | `archive_get_search_status` | Succeeds — returns `status: succeeded` with `matched_count` |
| Metadata export | `archive_get_search_results` | **Fails — `Request failed.`** |

### Reproductions

| Search | Query scope | `matched_count` | Size (bytes) | `search_id` | Export result |
|---|---|---|---|---|---|
| 1 | HR + new-hire terms, all dates | 45 | 65,122,020 | `2e2886a0-452b-4869-805b-9ff32e0be2b6` | Failed x3 |
| 2 | HR + new-hire terms, CY2023 | 9 | 9,423,657 | `961affb6-d37b-4950-b772-51042a2b431d` | Failed x2 |

Note: search #2 is small (9 items / ~9.4 MB), so a payload-size or timeout ceiling is not a sufficient explanation on its own.

### Correlation IDs (for App Insights trace)

| Correlation ID | Search | Call params |
|---|---|---|
| `7b17a717-0e56-4cce-9af9-eb9b24776048` | 45-hit | `top=50` |
| `b9cd8e50-8e02-40eb-9e62-f80b6a9b3d7c` | 45-hit | `top=50` |
| `ef9b43e3-0022-41f8-8862-f3e9f919342a` | 45-hit | `top=25` |
| `f47cec6d-a6ad-40d8-a88d-8dfdad54dad9` | CY2023 | `top=25` |
| `7e95f8b0-c077-48a2-be99-2926d9d906c4` | CY2023 | default `top` |

## Steps to reproduce

1. Call `search_archive_mail` with any valid KQL query (e.g., `from:hr@gipartners.com AND (new employee OR new hire OR onboarding) AND received>=2023-01-01 AND received<=2023-12-31`). Note the returned `search_id`.
2. Call `archive_get_search_status` with that `search_id`. Confirm `status: succeeded` and a non-zero `matched_count`.
3. Call `archive_get_search_results` with the same `search_id` (with or without `top`, with or without `export_operation_id`).
4. Observe `{"error": true, "message": "Request failed.", "correlation_id": "<new id each call>"}`.

## Analysis / working hypotheses

The evidence rules out several common causes and points at the export step specifically:

- **Not the query** — the same query estimates fine; only the export leg fails.
- **Not result-set size / timeout** — a 9-item / ~9.4 MB export fails the same way as a 45-item / ~65 MB one.
- **Not `top` handling** — fails at `top=50`, `top=25`, and default.
- **Not the estimate-side auth** — search and status both work under the same OBO token, so the caller is authenticated to eDiscovery.

Candidate root causes, in rough priority order:

1. **Export operation not implemented / not wired.** `archive_get_search_results` is documented as delivering "in the next update"; the underlying eDiscovery **export-report** operation may be stubbed, missing, or pointing at a report sink that doesn't exist yet.
2. **Missing permission for the export/report action.** The estimate (search create + status) and the report export are distinct Graph/Purview operations. The app or OBO scope may lack the eDiscovery **export** permission even though it holds the search permission.
3. **Missing storage/report sink.** eDiscovery report-only exports still require a destination/operation context; a missing or misconfigured Azure Storage target or export operation record would surface as a generic failure.
4. **Unhandled async report-generation path.** The tool contract says it returns an `export_operation_id` when the report is still generating; if that async branch throws before returning the id, the caller can never resume it.

## Recommended next steps

- **Trace the correlation IDs** above in Application Insights for the `func-exchange-mcp-archive-mailbox-mcp` Function App to capture the real exception behind the generic `Request failed.`
- **Verify eDiscovery export permissions** on the app registration / OBO scope (search vs. export are separate).
- **Confirm the report/export sink** (storage account, container, operation record) is provisioned and reachable by the Function App's managed identity (keyless AAD per the rev2 architecture).
- **Confirm the async branch** returns a usable `export_operation_id` on "still generating" instead of throwing.
- **Add a regression test** that runs estimate → status → export end to end against a known small mailbox, so this leg is exercised in CI rather than only at query time.

## Workaround

For mailbox items still reachable by Graph, the same query can be run against the primary mailbox via the Microsoft 365 `outlook_email_search` tool (a separate code path). This does **not** reach archive-only items, so it is a partial workaround for triage only, not a substitute for the archive export.

## Changelog

- 2026-07-23 — Initial report. Five failed exports across two search IDs documented.
