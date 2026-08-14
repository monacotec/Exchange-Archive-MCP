# Online Archive × Microsoft Graph — Findings (2026-07-21/22)

**Status:** CLOSED — Graph's Mail API cannot read In-Place Archives **for anyone**: Microsoft publicly lists archive access as an unshipped EWS-parity gap ("updated timeline in the coming months"; still absent from the May 2026 import/export GA, which covers primary + shared only). Our per-mailbox evidence below is consistent with that — the well-known archive names are enum placeholders, not wired up in Exchange Online. The support-case draft (`microsoft-support-case-draft.md`) is now **optional** (expected answer: "not supported yet"). **End solution:** `plans/ARCHIVE-DATA-PATH-PLAN.md` — Purview eDiscovery data path now, native Graph swap when parity ships. Note the target population includes auto-expanding archives (executives), which even future Mail-API parity may exclude — eDiscovery covers them today.
**Supersedes:** the integration plan in `history/exchange-archive-mcp-online-archive-fix.md` §5 (its `archivemsgfolderroot` fix was implemented and is correct per docs, but does not work on this mailbox).

## Archive configuration (2026-07-22, `Get-ArchiveConfig.ps1`, PS 5.1)

| Property | Value |
|---|---|
| ArchiveStatus / ArchiveState | Active / Local |
| ArchiveGuid | `77e7a137-5168-4d2b-9c18-2ab52e5a3f90` |
| **AutoExpandingArchiveEnabled (mailbox)** | **False** |
| AutoExpandingArchiveEnabled (org) | True (capability only; this mailbox has not expanded) |
| Mailbox locations | `Primary` + `MainArchive` only — **no AuxArchive shards** |
| ArchiveQuota | 100 GB (warning 90 GB) |
| Archive database | `namprd04.prod.outlook.com/d2ba9c06-4d4c-443d-a5c6-c011abe4ae65` |

The auto-expanded-archive limitation applies to archives with auxiliary shards. This archive has none — Graph's well-known-name addressing **should work** here, which is what makes the 404s defect-grade.

## Evidence chain

All probes 2026-07-21, mailbox `jmonaco@gipartners.com`, tenant GI Partners. Probe tooling: `foundry-mcp/scripts/Test-ArchiveGraphAccess.ps1` (interactive delegated token) and the deployed MCP v2.3.1 (OBO token), traces via `Get-McpErrorTrace.ps1`.

1. **Well-known-name folder addressing fails.** `GET /me/mailFolders/{name}` for `archivemsgfolderroot`, `archiveroot`, `archiveinbox`, `archivedeleteditems` → **404 `ErrorInvalidMailboxItemId`** on **v1.0 and beta**, with **both** an interactive `Mail.Read` token and the function's OBO token. Note the error code differs from the documented `ErrorItemNotFound`.
2. **Hidden-folder traversal shows no archive.** `GET /me/mailFolders?includeHiddenFolders=true` lists only primary-mailbox folders. The "Archive" it shows (28,273 items, 0 children, id `AAMkAGI1...AA03AAA=`) is the primary mailbox's Archive-button folder — confirmed by content inspection (2026-05 primary traffic) and by the parent chain (`Archive` → `Top of Information Store` → primary root).
3. **Microsoft Search API does not index the archive.** `POST /search/query` (entityType `message`) for a message physically exported from the Online Archive that day — subject `[HELPDESK] Access for Melissa`, from Alyssa Arwood, 2022-04-20 — returns **total=0** for `subject:"Access for Melissa" received<2023-01-01`, `subject:"Access for Melissa"`, and `"Access for Melissa"`. Broader queries return only primary-mailbox hits (verified via parent-chain walk to the known primary folder id).
4. **Id-based addressing works** (messages and folders resolve by id, parent chains walk cleanly) — but no Graph surface ever yields an archive-resident id to start from.

## What this rules out

- The v2.3.x MCP implementation (well-known root + per-folder fan-out) — correct per Graph docs, dead on this mailbox. Kept in code; it fails with a clear "Online Archive root not addressable" error.
- Any "fix the OBO token" theory — the interactive token fails identically.
- Search-API bootstrap (find archive item → walk parents to archive root) — Search never surfaces archive items.

## Options analysis

| Option | Verdict |
|---|---|
| **EWS** | Functional today (Outlook proves MAPI/EWS reach the archive) but **retired for Exchange Online 2026-10-01** (~10 weeks) and new EWS app access is already restricted. Do not build on it. |
| **Purview / eDiscovery Graph APIs** | The realistic path. Compliance search reaches Online Archives (incl. auto-expanded); org already uses the `MBX:{ArchiveGuid}@{TenantId}` scoping convention (global CLAUDE.md). Costs: async search model (minutes, not seconds), application-level eDiscovery permissions (changes the delegated-OBO security story), no folder-hierarchy equivalent (`list_archive_folders` has no analogue), result retrieval via preview/export. |
| **Microsoft support case** | Worth filing ONLY if `AutoExpandingArchiveEnabled` is false — then well-known-name addressing *should* work and the 404s are a defect. If true, the behavior is documented and a case is a dead end. |
| **Substrate/OWA internal APIs** | Unsupported, undocumented, no. |

## Impact on in-flight work

- **foundry-mcp** `function_app.py` v2.3.1: archive resolver cascade fails cleanly with an explanatory error. No further code changes until the data-path decision is made.
- **local-mcp** (background task "Fix Local MCP Online Archive root resolution"): the port replicates the same `archivemsgfolderroot` approach and will hit the same wall — its Graph-level acceptance tests cannot pass against this mailbox. The mechanical port may still be worth merging (correct per docs; another user's non-auto-expanded archive would work), but treat its acceptance criteria as blocked pending the same decision.

## Reference data

- Known-bad primary Archive-button folder id: `AAMkAGI1NjNkMTUzLTkyMmMtNDliMC1iNjZjLTU0Njc1ZTk2MTcxOAAuAAAAAAB9FPlyDXUwQInaeF1jLtb3AQBiwv40ZdttQaPCXtEU8YCCAAAAAA03AAA=`
- Known archive-resident test message: `[HELPDESK] Access for Melissa`, Alyssa Arwood, 2022-04-20 (exported copy exists as .msg).
- Primary Archive-button folder span: ~2023-07-24 → present; anything older lives only in the Online Archive.
