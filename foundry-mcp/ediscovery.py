"""
foundry-mcp/ediscovery.py
Purview eDiscovery data path for the Exchange Archive MCP.
Version: 1.5.0

Why this exists: Microsoft Graph's Mail API cannot read In-Place Archives (see
docs/online-archive-graph-findings.md), and the executive population includes
auto-expanding archives that even future Mail-API parity may exclude. eDiscovery
searches reach both. Design per plans/ARCHIVE-DATA-PATH-PLAN.md; API shapes
verified live by scripts/Invoke-EDiscoverySpike.ps1 (2026-07-22):

  - a mailbox is targeted by registering a noncustodialDataSource (userSource)
    in the standing case and binding it via noncustodialSources@odata.bind at
    search creation (inline additionalSources is rejected by v1.0);
  - estimateStatistics is async (~90s single mailbox); poll the search's
    lastEstimateStatisticsOperation;
  - item metadata comes from the report files of an exportResult operation,
    downloaded with a token for the MicrosoftPurviewEDiscovery resource.

SECURITY MODEL (approved 2026-07-22, ARCHIVE-DATA-PATH-PLAN §5): app-only
eDiscovery permissions with APP-ENFORCED per-caller scoping —
  - the data source for every search is derived from the VERIFIED caller
    (Easy Auth principal), never from tool arguments;
  - search display names embed the caller oid; every follow-up call re-verifies
    the search belongs to the caller before returning anything;
  - exports refuse to run above EXPORT_ITEM_LIMIT hits (cost + blast radius).

CASE MODEL (verified 2026-07-22): the app holds the eDiscovery MANAGER role,
which only reaches cases the app itself created — a human-created case 401s
app-only even with valid roles (Test-EDiscoveryAppAccess.ps1 §5). So every case
is APP-OWNED.

ONE CASE PER CALLER: each caller gets their own app-owned case named
"Exchange Archive MCP - {oid}", found-or-created at first use. This (a) makes
"find the caller's mailbox source" trivial and shape-independent — it is the
single noncustodialDataSource in that caller's own case, so no email/field
matching is needed (a shared case commingles sources and the listing does not
reliably expose the source email, which broke source reuse on the 409 "source
already exists" path); and (b) hardens isolation — one user's searches can never
touch another's, by case boundary, not just by code. EDISCOVERY_CASE_ID /
EDISCOVERY_CASE_NAME are ignored under this model.
"""

import asyncio
import csv
import io
import logging
import os
import re
import uuid
import zipfile

logger = logging.getLogger(__name__)

GRAPH = "https://graph.microsoft.com/v1.0"
CASES = f"{GRAPH}/security/cases/ediscoveryCases"

# First-party resource that authorizes export-package downloads.
PURVIEW_EDISCOVERY_APP_ID = "b26e684c-5068-4120-a679-64a5d2c909d9"

# Refuse to export result sets larger than this (PAYG cost guard; ~500 items
# stays comfortably inside the 50 GB/month free tier).
EXPORT_ITEM_LIMIT = int(os.environ.get("EDISCOVERY_EXPORT_ITEM_LIMIT", "500"))

# In-process caches (per worker), keyed by caller oid.
_case_cache: dict = {}   # oid -> case id
_nc_source_cache: dict = {}  # oid -> noncustodialDataSource id


class EDiscoveryClient:
    """Thin async client over the v1.0 eDiscovery API, scoped to one caller."""

    def __init__(self, session, graph_token: str, caller: dict):
        self._session = session
        self._token = graph_token
        self._caller = caller  # {"upn": ..., "oid": ...}

    def _case_name(self) -> str:
        oid = self._caller.get("oid") or self._caller["upn"].lower()
        return f"Exchange Archive MCP - {oid}"

    async def _case(self) -> str:
        """Find-or-create THIS caller's own app-owned case (see module docstring:
        one case per caller — no shared case, no cross-user commingling)."""
        oid = self._caller.get("oid") or self._caller["upn"].lower()
        if oid in _case_cache:
            return _case_cache[oid]
        name = self._case_name()
        listing = await self._req("GET", f"{CASES}?$top=100")
        for c in listing.get("value", []):
            if c.get("displayName") == name:
                _case_cache[oid] = c["id"]
                return c["id"]
        try:
            case = await self._req("POST", CASES, {
                "displayName": name,
                "description": (f"App-owned archive-read case for {self._caller['upn']}. "
                                "Searches created per tool call by the Exchange Archive MCP."),
            })
        except RuntimeError:
            # Lost a create race with another worker — re-list and take it.
            listing = await self._req("GET", f"{CASES}?$top=100")
            case = next((c for c in listing.get("value", []) if c.get("displayName") == name), None)
            if case is None:
                raise
        logger.info("Resolved per-user eDiscovery case %s for %s", case["id"], self._caller["upn"])
        _case_cache[oid] = case["id"]
        return case["id"]

    # ── HTTP plumbing ─────────────────────────────────────────────────────────

    async def _req(self, method: str, url: str, body: dict = None,
                   want_headers: bool = False):
        retries = 3
        for attempt in range(retries + 1):
            async with self._session.request(
                method, url,
                headers={"Authorization": f"Bearer {self._token}"},
                json=body,
            ) as resp:
                if resp.status in (429, 503) and attempt < retries:
                    try:
                        delay = float(resp.headers.get("Retry-After", "3") or 3)
                    except ValueError:
                        delay = 3.0
                    await asyncio.sleep(min(delay, 30))
                    continue
                if resp.status == 204:
                    return ({}, dict(resp.headers)) if want_headers else {}
                try:
                    data = await resp.json(content_type=None)
                except Exception:
                    data = {}
                if resp.status >= 400:
                    code = (data or {}).get("error", {}).get("code", str(resp.status))
                    msg = (data or {}).get("error", {}).get("message", "")
                    raise RuntimeError(f"eDiscovery {resp.status} {code}: {msg[:200]}")
                return (data or {}, dict(resp.headers)) if want_headers else (data or {})
        raise RuntimeError("eDiscovery throttled after retries")

    # ── Sources and searches ──────────────────────────────────────────────────

    async def ensure_source(self) -> str:
        """Get the caller's mailbox source in their own case.

        The case belongs solely to this caller, so ANY noncustodialDataSource in
        it is theirs — reuse the existing one (no email/field matching), else
        create it. This is what the per-user-case model buys us: reuse is
        shape-independent and the 409 'already exists' path can't misfire.
        """
        oid = self._caller.get("oid") or self._caller["upn"].lower()
        if oid in _nc_source_cache:
            return _nc_source_cache[oid]
        case = await self._case()
        listing = await self._req("GET", f"{CASES}/{case}/noncustodialDataSources")
        existing = listing.get("value", [])
        if existing:
            _nc_source_cache[oid] = existing[0]["id"]
            return existing[0]["id"]
        try:
            nc = await self._req("POST", f"{CASES}/{case}/noncustodialDataSources", {
                "dataSource": {"@odata.type": "microsoft.graph.security.userSource",
                               "email": self._caller["upn"].lower()}
            })
        except RuntimeError:
            # Create race — re-list and take the now-present source.
            listing = await self._req("GET", f"{CASES}/{case}/noncustodialDataSources")
            again = listing.get("value", [])
            if not again:
                raise
            nc = again[0]
        _nc_source_cache[oid] = nc["id"]
        return nc["id"]

    async def create_search(self, kql: str) -> str:
        """Create a search bound to the caller's source; returns search id.

        The display name embeds the caller oid — it is the ownership tag that
        every follow-up call verifies (see verify_ownership).
        """
        case = await self._case()
        source_id = await self.ensure_source()
        name = f"mcp-{self._caller.get('oid', 'unknown')}-{uuid.uuid4().hex[:8]}"
        search = await self._req("POST", f"{CASES}/{case}/searches", {
            "displayName": name,
            "description": f"MCP tool call for {self._caller['upn']} (auto-created; auto-deleted)",
            "contentQuery": kql,
            "noncustodialSources@odata.bind": [
                f"{CASES}/{case}/noncustodialDataSources/{source_id}"
            ],
        })
        return search["id"]

    async def verify_ownership(self, search_id: str) -> dict:
        """Fetch a search and require it to be tagged with the caller's oid."""
        case = await self._case()
        search = await self._req(
            "GET",
            f"{CASES}/{case}/searches/{search_id}"
            "?$expand=lastEstimateStatisticsOperation",
        )
        tag = f"mcp-{self._caller.get('oid', 'unknown')}-"
        if not str(search.get("displayName", "")).startswith(tag):
            raise PermissionError("search does not belong to the calling user")
        return search

    async def start_estimate(self, search_id: str) -> None:
        case = await self._case()
        await self._req("POST", f"{CASES}/{case}/searches/{search_id}/estimateStatistics")

    async def poll_estimate(self, search_id: str, budget_seconds: int = 45) -> dict:
        """Poll until the estimate finishes or the budget runs out.

        Returns {status, count, size} — status is 'succeeded', 'running', or
        'failed'.
        """
        interval = 5
        waited = 0
        while True:
            search = await self.verify_ownership(search_id)
            op = search.get("lastEstimateStatisticsOperation") or {}
            status = (op.get("status") or "notStarted").lower()
            if status == "succeeded":
                return {
                    "status": "succeeded",
                    "count": int(op.get("indexedItemCount") or 0),
                    "size": int(op.get("indexedItemsSize") or 0),
                }
            if status == "failed":
                return {"status": "failed", "count": 0, "size": 0}
            if waited >= budget_seconds:
                return {"status": "running", "count": 0, "size": 0}
            await asyncio.sleep(interval)
            waited += interval

    async def delete_search(self, search_id: str) -> None:
        try:
            case = await self._case()
            await self._req("DELETE", f"{CASES}/{case}/searches/{search_id}")
        except RuntimeError as ex:
            logger.warning("Could not delete eDiscovery search %s: %s", search_id, ex)

    # ── Export-report (metadata retrieval path — no content charges) ──────────

    async def start_export_report(self, search_id: str) -> str:
        """Kick a REPORT-ONLY export (item metadata, no content package) and
        return the operation id from the 202 Location header."""
        case = await self._case()
        _, headers = await self._req(
            "POST", f"{CASES}/{case}/searches/{search_id}/exportReport",
            {
                "displayName": f"mcp-report-{uuid.uuid4().hex[:8]}",
                "exportCriteria": "searchHits",
                "additionalOptions": "none",
            },
            want_headers=True,
        )
        location = headers.get("Location") or headers.get("location") or ""
        m = re.search(r"operations\(?'?([0-9a-fA-F-]{16,})'?\)?", location)
        if not m:
            m = re.search(r"/operations/([0-9a-fA-F-]{16,})", location)
        if not m:
            raise RuntimeError(f"exportReport accepted but no operation id in Location: {location[:120]}")
        return m.group(1)

    async def get_operation(self, operation_id: str) -> dict:
        case = await self._case()
        return await self._req("GET", f"{CASES}/{case}/operations/{operation_id}")

    async def download_report_items(self, operation: dict, download_token: str,
                                    max_bytes: int = 64 * 1024 * 1024) -> list:
        """Download and parse the item-report CSV from a finished export op.

        exportFileMetadata lists the report files; the download endpoint wants
        a token for the MicrosoftPurviewEDiscovery resource plus the
        X-AllowWithAADToken header. Handles bare .csv files and report .zips.
        """
        files = operation.get("exportFileMetadata") or []
        if not files:
            raise RuntimeError("export operation finished but exposed no files")
        # Prefer an items CSV, then any CSV, then the smallest zip.
        def rank(f):
            name = str(f.get("fileName", "")).lower()
            if name.endswith(".csv") and "item" in name:
                return (0, f.get("size") or 0)
            if name.endswith(".csv"):
                return (1, f.get("size") or 0)
            if name.endswith(".zip"):
                return (2, f.get("size") or 0)
            return (3, f.get("size") or 0)

        for f in sorted(files, key=rank):
            name = str(f.get("fileName", ""))
            size = int(f.get("size") or 0)
            if size > max_bytes:
                logger.warning("Skipping oversized export file %s (%d bytes)", name, size)
                continue
            async with self._session.get(
                f["downloadUrl"],
                headers={"Authorization": f"Bearer {download_token}",
                         "X-AllowWithAADToken": "true"},
            ) as resp:
                if resp.status >= 400:
                    logger.warning("Download of %s failed: HTTP %s", name, resp.status)
                    continue
                blob = await resp.read()
            parsed = None
            if name.lower().endswith(".zip"):
                try:
                    zf = zipfile.ZipFile(io.BytesIO(blob))
                except zipfile.BadZipFile:
                    continue
                member = next((m for m in zf.namelist()
                               if m.lower().endswith(".csv") and "item" in m.lower()), None)
                if not member:
                    member = next((m for m in zf.namelist() if m.lower().endswith(".csv")), None)
                if member:
                    parsed = _parse_items_csv(zf.read(member).decode("utf-8-sig", "replace"))
            else:
                parsed = _parse_items_csv(blob.decode("utf-8-sig", "replace"))
            if parsed and parsed[0]:
                return parsed  # (rows, columns)
        raise RuntimeError("no parsable item report found in export files")


# Tolerant column resolution: report CSV headers vary across export versions.
# Candidates are matched case-insensitively; first present header wins. The
# folder set is deliberately broad (eDiscovery reports name the folder path
# variously) and the parser also returns the raw header list so any unmapped
# field can be pinned down from real data rather than guessed.
_CSV_FIELD_CANDIDATES = {
    "subject": ("subject/title", "subject", "title"),
    "from": ("sender/author", "sender", "from", "author", "sender address"),
    "received": ("date received", "received date", "received time", "received",
                 "date", "date sent", "sent date"),
    "folder": ("compliance item path", "folder path", "original path", "parent folder path",
               "parent folder", "location path", "folder", "original folder path",
               "path", "location", "location name"),
    "size": ("size", "item size", "size (bytes)", "total size"),
    "item_id": ("item id", "immutable id", "immutableid", "document id", "id",
                "itemid", "unique id"),
    "internet_message_id": ("internet message id", "internetmessageid",
                            "message id", "internet messageid"),
}


def _parse_items_csv(text: str):
    """Return (rows, columns): mapped rows plus the raw CSV header list."""
    reader = csv.DictReader(io.StringIO(text))
    if not reader.fieldnames:
        return ([], [])
    columns = [str(h) for h in reader.fieldnames if h]
    norm = {str(h).strip().lower(): h for h in reader.fieldnames if h}
    mapping = {}
    for field, candidates in _CSV_FIELD_CANDIDATES.items():
        for cand in candidates:
            if cand in norm:
                mapping[field] = norm[cand]
                break
    rows = []
    for raw in reader:
        row = {field: (raw.get(src) or "").strip() for field, src in mapping.items()}
        rows.append(row)
    return (rows, columns)


def owa_message_url(item_id: str) -> str:
    """Best-effort deep link that opens ONE message.

    Uses the OWA ReadMessageItem viewmodel with the item's id. This resolves in
    OWA (browser); on machines where classic Outlook desktop is the registered
    handler, exvsurl=1 hands the open off to it. There is no supported URL
    scheme to open an arbitrary message directly in Outlook desktop by id, so
    this is the reliable cross-environment 'open this message' link. Returns ''
    if there is no id to link.
    """
    from urllib.parse import quote

    if not item_id:
        return ""
    return (
        "https://outlook.office365.com/owa/?"
        f"ItemID={quote(item_id, safe='')}&exvsurl=1&viewmodel=ReadMessageItem"
    )


def giparchive_url(message_id: str, owa_url: str = "") -> str:
    """Custom-scheme link the giparchive: workstation handler opens in classic
    Outlook desktop (desktop-handler/). Carries the Message-ID (the D0-proven
    lookup key) plus the OWA URL as a seamless fallback the handler uses if the
    message isn't found locally. Returns '' if there is no Message-ID.
    """
    from urllib.parse import quote

    if not message_id:
        return ""
    parts = ["mid=" + quote(message_id, safe="")]
    if owa_url:
        parts.append("owa=" + quote(owa_url, safe=""))
    return "giparchive:v1?" + "&".join(parts)


def build_kql(free_text: str = None, start_iso: str = None, end_iso: str = None) -> str:
    """Compose the tool query into eDiscovery KQL with the same hardening rules
    as the Graph path: length cap, control/bidi rejection (mirrors
    ConvertTo-KqlQuery in the local MCP)."""
    parts = []
    if free_text:
        if len(free_text) > 2000:
            raise ValueError("query exceeds maximum length of 2000 characters")
        for ch in free_text:
            cp = ord(ch)
            if cp < 0x20 or cp == 0x7F or 0x202A <= cp <= 0x202E or 0x2066 <= cp <= 0x2069:
                raise ValueError("query contains disallowed control or bidi-override characters")
        parts.append(free_text)
    if start_iso:
        parts.append(f"received>={start_iso}")
    if end_iso:
        parts.append(f"received<={end_iso}")
    return " AND ".join(parts) if parts else "size>=0"
