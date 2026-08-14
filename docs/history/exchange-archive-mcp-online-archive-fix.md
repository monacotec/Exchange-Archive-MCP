# Exchange Archive MCP - Online Archive Fix Briefing

**Date:** 2026-07-21
**Author:** Claude session with Jeff Monaco (handoff doc for code session)
**Target:** Azure Functions MCP app `func-exchange-mcp-archive-mailbox-mcp.azurewebsites.net`
**Severity:** Functional defect - the MCP is not reading the Online Archive at all
**Companion file:** `ArchiveMailbox.Graph.ps1` v1.0.0 (corrected Graph query functions)

---

## 1. Executive Summary

The Exchange Archive MCP was built to query Jeff's Exchange Online **In-Place (Online) Archive** mailbox via delegated OBO Graph calls. Verification testing on 2026-07-21 proved it is instead reading the **primary mailbox's well-known `archive` folder** (the one-click "Archive" button folder). All three MCP tools are affected:

| Tool | Current behavior | Required behavior |
|---|---|---|
| `list_archive_folders` | Returns one flat folder "Archive" (28,273 msgs, 0 children) | Return the Online Archive tree: Deleted Items, Archive (623), Inbox (759) with many subfolders (!Closed items, !GIP IT, AGM, Apple, Backups, Card Access, Construction, ...) |
| `get_mail_by_date_range` | Queries only the primary Archive folder; nothing before ~2023-07-24 | Query all folders under the Online Archive root |
| `search_archive_mail` | Searches only the primary Archive folder | Search all folders under the Online Archive root |

**Root cause:** In Microsoft Graph, the well-known folder name `archive` = the Archive folder INSIDE the primary mailbox. The Online Archive mailbox root is a DIFFERENT well-known name: **`archivemsgfolderroot`**. The Function is calling the former.

---

## 2. Evidence Chain (how this was proven)

1. **`list_archive_folders`** returned a single folder:
   - `display_name: "Archive"`, `message_count: 28273`, `unread_count: 2613`, `child_folders: []`
   - Folder id: `AAMkAGI1NjNkMTUzLTkyMmMtNDliMC1iNjZjLTU0Njc1ZTk2MTcxOAAuAAAAAAB9FPlyDXUwQInaeF1jLtb3AQBiwv40ZdttQaPCXtEU8YCCAAAAAA03AAA=`

2. **Date-range bisection** via `get_mail_by_date_range` found the folder's coverage is ~2023-07-24 through 2026-05-07. Nothing from 2022 exists in it. A known-good Online Archive message (Alyssa Arwood, payroll@gipartners.com, 2022-04-20) returned zero results from both date-range and search tools.

3. **Outlook screenshot** of the real Online Archive (jmonaco@gipartners.com) shows a full tree: Deleted Items, Archive (623), Inbox (759), !Closed items (132), AllCovered Nightlys, !GIP IT, !Templates, AGM, Apple, Backups, Card Access, Construction, and more. The MCP's flat single-folder result does not reconcile with this. Note the Online Archive's own "Archive" subfolder shows 623 items vs the MCP's 28,273 - different folders entirely.

4. **Definitive cross-check:** The exact folder id from step 1 was resolved through the Microsoft 365 connector's Graph resource reader (`mail:///folders/{id}`). It returned displayName "Archive", 28,273 items, zero children, and its message contents were **current primary-mailbox traffic** (451 Research digests, HELPDESK tickets, the 2026-05-05 "Security Incident" thread with pwelch/ekuan/bkrant/cguidry, meeting invites). That is the primary mailbox Archive button folder, conclusively.

**Every symptom fits the diagnosis:** flat structure, "Archive" display name, July-2023 start date (when the Archive button habit started), missing 2022 mail (which lives in the true Online Archive), and count mismatch (28,273 vs 623).

---

## 3. Graph API Facts Needed for the Fix

- **Correct root well-known name:** `archivemsgfolderroot` (Top of Information Store in the In-Place Archive). Companion well-known names if needed: `archiveinbox`, `archivedeleteditems`, `archiverecoverableitemsdeletions`, `archiverecoverableitemspurges`, `archiveroot` (the level above msgfolderroot).
- **Wrong name (current bug):** `archive` = primary mailbox Archive folder. Grep the source for this string.
- **Folder listing:** `GET /me/mailFolders/archivemsgfolderroot/childFolders?$select=id,displayName,totalItemCount,unreadItemCount,childFolderCount&$top=100` and recurse where `childFolderCount > 0`. Page via `@odata.nextLink`.
- **Messages by date:** `$search` and `/me/messages`-level `$filter` do NOT reach the archive. Enumerate all folder ids under `archivemsgfolderroot`, then per folder: `GET /me/mailFolders/{id}/messages?$filter=receivedDateTime ge {startIso} and receivedDateTime le {endIso}&$orderby=receivedDateTime desc`.
- **Search:** `$search` on `/me/messages` only covers the primary mailbox. Fan out folder-scoped `$search="..."` calls per archive folder id. Constraints: `$search` cannot combine with `$orderby` or `$filter`; merge and sort results client-side; dedupe by message id. Some special folders reject `$search` - catch, log, continue.
- **Auth:** delegated `Mail.Read` via the existing OAuth 2.1 OBO flow is sufficient; no new permissions needed.
- **Verify at deploy:** if `GET /me/mailFolders/archivemsgfolderroot` returns `ErrorItemNotFound`, the archive is not provisioned as Graph expects; fall back to resolving via `archiveroot` and walking down. (Not expected here - the archive demonstrably exists.)
- **Throttling:** fan-out across many folders will hit 429s more than the old single-folder call. Honor `Retry-After`; also retry 503.

---

## 4. The Fix - Companion PowerShell Module

`ArchiveMailbox.Graph.ps1` v1.0.0 (PS7, PS5.1-portable syntax, ASCII-only) provides drop-in replacements:

| Function | Replaces | Notes |
|---|---|---|
| `Invoke-GraphRequest` | ad-hoc Invoke-RestMethod calls | `@odata.nextLink` paging, 429/503 Retry-After retry, `MaxItems` cap |
| `Get-ArchiveFolderHierarchy` | `list_archive_folders` Graph logic | Recursive (depth 1-5, matches existing `max_depth` contract). Output shape matches current MCP JSON: `hierarchy` / `total_messages` / `max_depth_traversed`, nodes have `id`, `display_name`, `message_count`, `unread_count`, `child_folders` |
| `Get-ArchiveFolderIdList` | (new helper) | BFS flattener of all folder ids under the root; skips empty folders by default (`-IncludeEmpty` to override) |
| `Get-ArchiveMailByDateRange` | `get_mail_by_date_range` Graph logic | Per-folder `$filter` fan-out, merge, sort newest-first, truncate to `Top` (1-100, default 50). Adds a `folder` field per message showing which archive subfolder it came from |
| `Search-ArchiveMail` | `search_archive_mail` Graph logic | Per-folder `$search` fan-out with message-id dedupe, `Top` 1-50 default 20, tolerant of folders that reject `$search`. Adds `folder` field |

All functions take `-AccessToken` (the OBO token string) so they slot into the existing auth flow without touching it.

Root constant in the module - the one-line essence of the fix:

```powershell
# Well-known folder name for the Online Archive root. Do NOT use 'archive' --
# that is the primary mailbox Archive folder and was the source of the bug.
$script:ArchiveRoot = 'archivemsgfolderroot'
```

---

## 5. Integration Plan for the Code Session

**Preferred approach: targeted diff against real source (Option 2).** The bug is probably 1-5 lines. The surrounding code (OBO exchange, MSAL cache handling, session disconnect guarantees, response envelopes) already went through the rev2 security review and should not be rewritten on a guess.

**Steps:**

1. **Locate the folder resolution.** Grep the Function source for `mailFolders/archive` (or the string `'archive'` near a Graph URI). Determine whether URI construction is centralized in one helper (fix once) or duplicated per tool handler (fix three places).
2. **Decide integration depth:**
   - **Minimal:** swap `archive` -> `archivemsgfolderroot` and add recursion/fan-out inline, preserving all existing structure. Smallest blast radius, easiest change-control record.
   - **Module adoption:** dot-source `ArchiveMailbox.Graph.ps1` (from `profile.ps1` or a `Modules/` folder) and have each handler's `run.ps1` call the corresponding function, keeping only param parsing, token acquisition, and `Push-OutputBinding` in the handler. Cleaner long-term; bigger diff.
3. **Do not touch:** OAuth 2.1 OBO token exchange, OIDC WIF / keyless AAD auth, session disconnect guarantees, existing error envelope format, existing logging. (rev2-reviewed code.)
4. **Preserve tool schemas:** the MCP tool contracts (`max_depth` 1-5 default 3; `top` 1-50 default 20 for search, 1-100 default 50 for date range; ISO 8601 dates) must not change. The module functions already conform.
5. **Version bumps:** per gi-foundry convention, bump each modified `run.ps1`, the module, and the app version tag; record in `version.md` (starter provided in this bundle).
6. **Consider a throttling ceiling:** the archive has many folders; if fan-out latency or 429s become an issue, options are (a) restrict date-range/search fan-out to folders where `totalItemCount > 0` (already done), (b) parallelize with `ForEach-Object -Parallel` and a throttle limit, (c) cache the folder id list with a short TTL since archive folder structure changes rarely.

---

## 6. Acceptance Tests (post-deploy)

| # | Test | Expected result |
|---|---|---|
| 1 | `list_archive_folders` (max_depth 3) | Tree containing Deleted Items, Archive (~623), Inbox (~759) with subfolders !Closed items (~132), AllCovered Nightlys, !GIP IT, !Templates, AGM, Apple, Backups, Card Access, Construction, etc. NOT a single flat "Archive" folder |
| 2 | `search_archive_mail` query: `Alyssa Arwood payroll` | Hits the 2022-04-20 message ("...I additionally have the payroll@gipartners.com but everything else should be the same. Thank you as always! Alyssa") |
| 3 | `get_mail_by_date_range` 2022-04-20 to 2022-04-20 | Returns messages from that day (previously returned zero) |
| 4 | Oldest-date probe (wide range, e.g. 1990-01-01 start) | Coverage extends well before 2023-07-24 |
| 5 | Regression: primary-mailbox-only content | Recent primary Inbox mail (e.g. the 2026-05 451 Research digests that currently dominate results) should NOT appear unless it also exists in the Online Archive |
| 6 | Folder attribution | Each returned message includes a `folder` field naming its archive subfolder |

---

## 7. Reference Data from This Session

- **Buggy folder id (primary mailbox Archive folder)** - useful as a negative test; results should never come from this folder id after the fix:
  `AAMkAGI1NjNkMTUzLTkyMmMtNDliMC1iNjZjLTU0Njc1ZTk2MTcxOAAuAAAAAAB9FPlyDXUwQInaeF1jLtb3AQBiwv40ZdttQaPCXtEU8YCCAAAAAA03AAA=`
- **Primary Archive folder observed stats:** 28,273 total / 2,613 unread; date span ~2023-07-24 to 2026-05-07.
- **Known-good archive content for test #2:** Alyssa Arwood email, 2022-04-20, mentions payroll@gipartners.com.
- **Online Archive observed structure (from Outlook):** Deleted Items; Archive 623; Inbox 759; !Closed items 132; AllCovered Nightlys; !GIP IT; !Templates; AGM; Apple; Backups; Card Access; Construction (list truncated by screenshot).
