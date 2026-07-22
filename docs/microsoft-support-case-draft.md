# Microsoft Support Case — Draft

**Product:** Exchange Online / Microsoft Graph API
**Severity suggestion:** B (business function impaired — programmatic archive access blocked)
**Prepared:** 2026-07-22. Before filing, capture ONE fresh repro in Graph Explorer
(https://developer.microsoft.com/graph/graph-explorer, signed in as the affected
user) and note the `client-request-id` + UTC timestamp from the response headers —
support will ask for these to trace server-side.

---

## Title

Graph API returns 404 ErrorInvalidMailboxItemId for all In-Place Archive
well-known folder names on a provisioned, non-auto-expanded archive mailbox

## Description

For mailbox `jmonaco@gipartners.com` (tenant `9c1b0b26-717a-4eda-9d7e-7eebc00066bf`),
every Microsoft Graph request addressing the In-Place Archive via its documented
well-known folder names fails with **HTTP 404, code `ErrorInvalidMailboxItemId`**:

```
GET https://graph.microsoft.com/v1.0/me/mailFolders/archivemsgfolderroot
GET https://graph.microsoft.com/v1.0/me/mailFolders/archiveroot
GET https://graph.microsoft.com/v1.0/me/mailFolders/archiveinbox
GET https://graph.microsoft.com/v1.0/me/mailFolders/archivedeleteditems
```

All four fail identically on **both `v1.0` and `beta`**, with **both** an
interactive delegated token (`Mail.Read`, Graph PowerShell SDK / Graph Explorer)
and an OAuth 2.1 on-behalf-of token from our application. The error code differs
from the documented not-provisioned case (`ErrorItemNotFound`).

The archive itself is healthy and in daily use:

- Outlook and OWA access it normally (full folder tree, content back to 2022).
- `Get-Mailbox`: `ArchiveStatus: Active`, `ArchiveState: Local`,
  `ArchiveGuid: 77e7a137-5168-4d2b-9c18-2ab52e5a3f90`,
  **`AutoExpandingArchiveEnabled: False`** (org-level flag is True, but this
  mailbox has not expanded).
- `Get-MailboxLocation`: exactly `Primary` + `MainArchive` — **no AuxArchive
  locations**, so the documented auto-expanded-archive Graph limitation does not
  apply.
- Archive database: `namprd04.prod.outlook.com/d2ba9c06-4d4c-443d-a5c6-c011abe4ae65`
  (primary on `.../e8d643c0-2394-4ad3-b965-5753f2b6469b`).

Additional data points:

- `GET /me/mailFolders?includeHiddenFolders=true` returns only primary-mailbox
  folders; no archive root is enumerable from the primary hierarchy.
- The Microsoft Search API (`POST /search/query`, entityType `message`) does not
  return archive-resident messages either — a subject-exact query for a message
  verified to exist only in the archive (received 2022-04-20) returns total=0,
  while primary-mailbox content matches normally.
- Id-based addressing works fine for primary-mailbox folders and messages; the
  failure is specific to resolving any entry point into the archive mailbox.

## Expected behavior

`GET /me/mailFolders/archivemsgfolderroot` returns the archive's Top of
Information Store folder (id, displayName, counts), as documented in the
mailFolder well-known-names list, for a provisioned non-auto-expanded archive.

## Business impact

An internal line-of-business application (Azure Functions MCP server using
delegated OBO with `Mail.Read`) must read the user's Online Archive. All
programmatic access paths are blocked. EWS is not a viable workaround given its
announced Exchange Online retirement on 2026-10-01.

## Repro for support

1. Sign in to Graph Explorer as `jmonaco@gipartners.com` (consent `Mail.Read`).
2. Run `GET https://graph.microsoft.com/v1.0/me/mailFolders/archivemsgfolderroot`.
3. Observe 404 `ErrorInvalidMailboxItemId`.
4. Fresh repro request-id: `________________`  UTC time: `________________`
   (fill in from Graph Explorer response headers when filing).

## Questions for support

1. Why do archive well-known folder names resolve to `ErrorInvalidMailboxItemId`
   on this mailbox when the archive is Active, Local, and not auto-expanded?
2. Is there a provisioning/repair action (e.g., archive mailbox move, flag
   resync) that restores Graph addressability?
3. If this mailbox state is expected, what is the supported Graph-based method
   to enumerate and read In-Place Archive content, given EWS retirement?
