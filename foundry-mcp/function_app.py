"""
foundry-mcp/function_app.py
Exchange Online Archive MCP Server — Azure Functions Python v2 model
Version: 3.3.0

Rewritten 2026-07-13 on the Azure-Samples/remote-mcp-functions-python (GA extension)
pattern, replacing the rev-1 draft. Key changes:

  IDENTITY  Tools act on the VERIFIED CALLER's own archive mailbox. There is no
            user_email argument anywhere — the confused-deputy finding
            (REMEDIATION-GUIDE Lesson 1) is closed structurally, not by a guard.
  AUTH IN   Built-in MCP auth (Easy Auth) fronts the endpoint; the user's token
            and claims arrive via transport headers in MCPToolContext.
  AUTH OUT  On-Behalf-Of via azure.identity.OnBehalfOfCredential. Preferred path
            is a managed-identity FEDERATED credential (no client secret at all);
            falls back to the Key Vault-stored client secret when FIC env vars
            are absent.
  SPEC      RFC 9728 Protected Resource Metadata served at
            /.well-known/oauth-protected-resource (MCP spec 2025-06-18 §19.2).

Tools (all read-only, all scoped to the signed-in user):
  - search_archive_mail      : per-folder $search fan-out across the ONLINE ARCHIVE
  - get_mail_by_date_range   : per-folder receivedDateTime $filter fan-out
  - list_archive_folders     : Online Archive folder hierarchy

v3.0.0 (2026-07-22): TWO-LAYER DATA PATH (plans/ARCHIVE-DATA-PATH-PLAN.md).
Graph's Mail API cannot read In-Place Archives (unshipped EWS-parity gap —
docs/online-archive-graph-findings.md), so when the v2.3 archive resolver
reports the archive unaddressable, the message tools fall back to Purview
eDiscovery (ediscovery.py): caller-scoped search in the standing case
(EDISCOVERY_CASE_ID), async estimate, archive_get_search_status for polling.
The Graph path is still tried FIRST on every call — the day Microsoft ships
archive Mail-API parity, the tools self-upgrade with zero deploy.
v2.3.0 (2026-07-21): archivemsgfolderroot targeting + per-folder fan-out
(correct per docs; blocked upstream — kept as the path-B implementation).

Defense-in-depth:
  - MCP_ALLOWED_MAILBOXES app setting is checked against the VERIFIED caller UPN
    (from X-MS-CLIENT-PRINCIPAL), never against a caller-supplied argument.
  - Every tool call is audit-logged to App Insights with the caller identity.
"""

import asyncio
import base64
import json
import logging
import os
import uuid
from datetime import datetime
from urllib.parse import quote

import aiohttp
import azure.functions as func
from azure.functions.mcp import MCPToolContext

import ediscovery

logger = logging.getLogger(__name__)

app = func.FunctionApp(http_auth_level=func.AuthLevel.FUNCTION)

GRAPH = "https://graph.microsoft.com/v1.0"
GRAPH_SCOPE = "https://graph.microsoft.com/Mail.Read"

# ── Caller identity ───────────────────────────────────────────────────────────

def _get_headers(context) -> dict:
    """Transport headers from the MCP context (Easy Auth injects the identity ones)."""
    return context.get("transport", {}).get("properties", {}).get("headers", {})


def _get_caller(context) -> dict:
    """
    Decode X-MS-CLIENT-PRINCIPAL (set by built-in auth) into {upn, oid, tid}.
    Raises ValueError when the header is absent — i.e. built-in auth is not on.
    """
    encoded = _get_headers(context).get("X-MS-CLIENT-PRINCIPAL", "")
    if not encoded:
        raise ValueError(
            "No verified caller identity. Built-in MCP auth (Easy Auth) must be "
            "enabled in front of this endpoint — see FOUNDRY-MCP-PLAN Phase 2."
        )
    principal = json.loads(base64.b64decode(encoded))
    claims = {c.get("typ", ""): c.get("val") for c in principal.get("claims", [])}
    upn = (
        claims.get("preferred_username")
        or claims.get("upn")
        or claims.get("http://schemas.xmlsoap.org/ws/2005/05/identity/claims/upn")
        or claims.get("http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name")
    )
    tid = claims.get("tid") or claims.get(
        "http://schemas.microsoft.com/identity/claims/tenantid"
    )
    oid = claims.get("oid") or claims.get(
        "http://schemas.microsoft.com/identity/claims/objectidentifier"
    )
    if not upn or not tid:
        raise ValueError("Caller principal is missing upn/tid claims.")
    return {"upn": upn, "oid": oid, "tid": tid}


def _check_mailbox_allowed(upn: str) -> None:
    """
    Defense-in-depth allowlist (security baseline §5). Checked against the VERIFIED
    caller UPN. Empty/unset = allow (ApplicationAccessPolicy is the primary fence).
    """
    raw = os.environ.get("MCP_ALLOWED_MAILBOXES", "").strip()
    if not raw:
        return
    allowed = {m.strip().lower() for m in raw.split(",") if m.strip()}
    if upn.lower() not in allowed:
        raise PermissionError(f"Mailbox {upn} is not in the approved list.")


# ── OBO credential ────────────────────────────────────────────────────────────

_kv_secret_cache: dict = {}


def _kv_secret(name: str) -> str:
    """Fetch (and cache) a Key Vault secret via the Function App managed identity."""
    if name not in _kv_secret_cache:
        from azure.identity import DefaultAzureCredential
        from azure.keyvault.secrets import SecretClient

        kv_name = os.environ["KEY_VAULT_NAME"]
        client = SecretClient(
            vault_url=f"https://{kv_name}.vault.azure.net",
            credential=DefaultAzureCredential(),
        )
        _kv_secret_cache[name] = client.get_secret(name).value
    return _kv_secret_cache[name]


def _build_obo_credential(context, caller: dict):
    """
    Exchange the caller's inbound token for a downstream Graph token.

    Preferred: managed-identity federated credential (Workload Identity Federation —
    no client secret). Requires OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID and
    WEBSITE_AUTH_CLIENT_ID (both set by the Phase 2 infra).

    Fallback: the Key Vault-stored client secret (mcp-exchange-client-secret),
    rotated via Rotate-MCPClientSecret.ps1.
    """
    from azure.identity import ManagedIdentityCredential, OnBehalfOfCredential

    headers = _get_headers(context)
    user_token = headers.get("X-MS-TOKEN-AAD-ACCESS-TOKEN", "")
    if not user_token:
        auth_header = headers.get("Authorization", "")
        if auth_header.startswith("Bearer "):
            user_token = auth_header[len("Bearer "):]
    if not user_token:
        raise ValueError(
            "No user access token in transport headers. Ensure built-in MCP auth "
            "is enabled with the token store on."
        )

    fic_mi_client_id = os.environ.get("OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID")
    client_id = os.environ.get("WEBSITE_AUTH_CLIENT_ID") or os.environ.get("ENTRA_CLIENT_ID")

    if fic_mi_client_id and client_id:
        audience = os.environ.get("TokenExchangeAudience", "api://AzureADTokenExchange")
        mi = ManagedIdentityCredential(client_id=fic_mi_client_id)

        def client_assertion_func():
            return mi.get_token(f"{audience}/.default").token

        return OnBehalfOfCredential(
            tenant_id=caller["tid"],
            client_id=client_id,
            client_assertion_func=client_assertion_func,
            user_assertion=user_token,
        )

    # Fallback: client-secret OBO
    return OnBehalfOfCredential(
        tenant_id=caller["tid"],
        client_id=_kv_secret("mcp-entra-client-id"),
        client_secret=_kv_secret("mcp-exchange-client-secret"),
        user_assertion=user_token,
    )


async def _graph_token(context, caller: dict) -> str:
    credential = _build_obo_credential(context, caller)
    token = await asyncio.to_thread(credential.get_token, GRAPH_SCOPE)
    return token.token


# ── App-only credential (eDiscovery data path) ────────────────────────────────

def _build_app_credential():
    """App-only Graph credential for the eDiscovery data path.

    Same identity plumbing as the OBO flow — WIF via the user-assigned managed
    identity when configured, Key Vault client secret otherwise — but with the
    app's own identity (client_credentials), no user assertion. The app's
    eDiscovery.* application roles were granted by Initialize-EDiscoveryAccess.ps1.
    """
    from azure.identity import (
        ClientAssertionCredential,
        ClientSecretCredential,
        ManagedIdentityCredential,
    )

    tenant = os.environ.get("GRAPH_TENANT_ID", "9c1b0b26-717a-4eda-9d7e-7eebc00066bf")
    fic_mi_client_id = os.environ.get("OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID")
    client_id = os.environ.get("WEBSITE_AUTH_CLIENT_ID") or os.environ.get("ENTRA_CLIENT_ID")

    if fic_mi_client_id and client_id:
        audience = os.environ.get("TokenExchangeAudience", "api://AzureADTokenExchange")
        mi = ManagedIdentityCredential(client_id=fic_mi_client_id)

        def client_assertion_func():
            return mi.get_token(f"{audience}/.default").token

        return ClientAssertionCredential(tenant, client_id, client_assertion_func)

    return ClientSecretCredential(
        tenant, _kv_secret("mcp-entra-client-id"), _kv_secret("mcp-exchange-client-secret")
    )


async def _app_graph_token() -> str:
    credential = _build_app_credential()
    token = await asyncio.to_thread(credential.get_token, "https://graph.microsoft.com/.default")
    return token.token


async def _purview_download_token() -> str:
    """Token for the MicrosoftPurviewEDiscovery resource — export-package
    downloads use a separate audience from Graph (eDiscovery.Download.Read
    app role, granted by Initialize-EDiscoveryAccess.ps1)."""
    credential = _build_app_credential()
    token = await asyncio.to_thread(
        credential.get_token, f"{ediscovery.PURVIEW_EDISCOVERY_APP_ID}/.default"
    )
    return token.token


def _is_archive_unaddressable(ex: Exception) -> bool:
    """True when the Graph mail path reported the Online Archive unreachable —
    the trigger for the eDiscovery data path (ARCHIVE-DATA-PATH-PLAN §2)."""
    return "not addressable" in str(ex)


async def _ediscovery_estimate(session, caller: dict, kql: str) -> dict:
    """Create a caller-scoped eDiscovery search, start its estimate, poll briefly."""
    token = await _app_graph_token()
    client = ediscovery.EDiscoveryClient(session, token, caller)
    search_id = await client.create_search(kql)
    await client.start_estimate(search_id)
    est = await client.poll_estimate(search_id, budget_seconds=40)
    est["search_id"] = search_id
    return est


def _ediscovery_response(tool: str, caller: dict, params: dict, kql: str, est: dict) -> str:
    _audit(tool, caller, {**params, "data_path": "ediscovery"}, est["status"], est["count"])
    note = ("Archive reached via Purview eDiscovery (Graph mail API cannot address "
            "this archive). This is the match estimate; per-item metadata retrieval "
            "arrives with archive_get_search_results in the next update.")
    if est["status"] == "running":
        note += " The estimate is still running - call archive_get_search_status with this search_id."
    return json.dumps({
        "data_path": "ediscovery",
        "kql": kql,
        "status": est["status"],
        "matched_count": est["count"],
        "matched_size_bytes": est["size"],
        "search_id": est["search_id"],
        "note": note,
    })


# ── Graph helpers (delegated /me — the token itself scopes access) ────────────

# Well-known folder name for the ONLINE ARCHIVE root (Top of Information Store in
# the In-Place Archive). Do NOT use 'archive' — that is the Archive-button folder
# INSIDE the primary mailbox, and was the source of the 2026-07-21 defect where
# all three tools silently read the wrong mailbox (see
# exchange-archive-mcp-online-archive-fix.md).
ARCHIVE_ROOT_WKN = "archivemsgfolderroot"
_FOLDER_SELECT = "$select=id,displayName,totalItemCount,unreadItemCount,childFolderCount"

# Fan-out tuning: the archive has many folders; keep Graph happy.
_FANOUT_CONCURRENCY = 4
_MAX_FOLDERS = 500


async def _graph_get(session: aiohttp.ClientSession, token: str, url: str) -> dict:
    """GET with 429/503 retry honoring Retry-After (fan-out makes throttling likely)."""
    retries = 3
    for attempt in range(retries + 1):
        async with session.get(
            url, headers={"Authorization": f"Bearer {token}"}
        ) as resp:
            if resp.status in (429, 503) and attempt < retries:
                try:
                    delay = float(resp.headers.get("Retry-After", "2") or 2)
                except ValueError:
                    delay = 2.0
                await asyncio.sleep(min(delay, 30))
                continue
            try:
                body = await resp.json(content_type=None)
            except Exception:
                body = {}
            if resp.status >= 400:
                code = (body or {}).get("error", {}).get("code", str(resp.status))
                raise RuntimeError(f"Graph {resp.status} {code} for {url.split('?')[0]}")
            return body
    raise RuntimeError(f"Graph throttled after {retries} retries for {url.split('?')[0]}")


async def _graph_get_all(session, token, url: str, max_items: int = 1000) -> list:
    """Collect a paged collection by following @odata.nextLink."""
    items: list = []
    next_url = url
    while next_url and len(items) < max_items:
        data = await _graph_get(session, token, next_url)
        items.extend(data.get("value", []))
        next_url = data.get("@odata.nextLink")
    return items[:max_items]


async def _archive_root(session, token) -> dict:
    """Resolve the Online Archive root — never the primary mailbox's Archive folder.

    Graph's archive addressing is inconsistent across mailbox configurations:
    observed 2026-07-21 that /me/mailFolders/archivemsgfolderroot 404s with
    ErrorInvalidMailboxItemId (not the documented ErrorItemNotFound) on this
    mailbox. Cascade through every documented anchor: the msgfolderroot, the
    level above it (archiveroot), and finally archiveinbox — whose parent IS
    the msgfolderroot — before declaring the archive unaddressable.
    """
    last_ex = None
    for wkn in (ARCHIVE_ROOT_WKN, "archiveroot"):
        try:
            return await _graph_get(
                session, token, f"{GRAPH}/me/mailFolders/{wkn}?{_FOLDER_SELECT}"
            )
        except RuntimeError as ex:
            if "Graph 404" not in str(ex):
                raise
            logger.warning("Archive anchor '%s' not addressable: %s", wkn, ex)
            last_ex = ex
    try:
        inbox = await _graph_get(
            session, token, f"{GRAPH}/me/mailFolders/archiveinbox?$select=id,parentFolderId"
        )
        parent_id = inbox.get("parentFolderId")
        if parent_id:
            return await _graph_get(
                session, token, f"{GRAPH}/me/mailFolders/{parent_id}?{_FOLDER_SELECT}"
            )
    except RuntimeError as ex:
        if "Graph 404" not in str(ex):
            raise
        logger.warning("Archive anchor 'archiveinbox' not addressable: %s", ex)
        last_ex = ex
    raise RuntimeError(
        "Online Archive root not addressable via Graph — archivemsgfolderroot, "
        "archiveroot, and archiveinbox all returned 404. If the archive is "
        "auto-expanding, Graph REST cannot address it (EWS-only limitation). "
        f"Last error: {last_ex}"
    )


async def _archive_folder_list(session, token, include_empty: bool = False) -> list:
    """Flatten every folder under the Online Archive root (BFS), root included.

    Returns [{id, display_name, message_count}]. Folders with zero messages are
    skipped by default — they cannot contribute results to a message fan-out.
    """
    root = await _archive_root(session, token)
    folders: list = []
    queue = [root]
    while queue and len(folders) < _MAX_FOLDERS:
        f = queue.pop(0)
        folders.append({
            "id": f["id"],
            "display_name": f.get("displayName"),
            "message_count": f.get("totalItemCount", 0),
        })
        if f.get("childFolderCount", 0) > 0:
            url = (
                f"{GRAPH}/me/mailFolders/{f['id']}/childFolders"
                f"?includeHiddenFolders=true&$top=100&{_FOLDER_SELECT}"
            )
            queue.extend(await _graph_get_all(session, token, url))
    if include_empty:
        return folders
    non_empty = [f for f in folders if f["message_count"] > 0]
    return non_empty or folders


async def _fanout_messages(session, token, folders: list, url_for) -> list:
    """Run a per-folder message query across the archive, bounded concurrency.

    Folders that reject the query (some special folders refuse $search) are
    logged and skipped — one bad folder must not sink the whole tool call.
    Returns [(message, folder_display_name)].
    """
    sem = asyncio.Semaphore(_FANOUT_CONCURRENCY)

    async def one(folder):
        async with sem:
            try:
                data = await _graph_get(session, token, url_for(folder))
            except RuntimeError as ex:
                logger.warning("Archive folder '%s' skipped: %s", folder["display_name"], ex)
                return []
            return [(m, folder["display_name"]) for m in data.get("value", [])]

    chunks = await asyncio.gather(*(one(f) for f in folders))
    return [pair for chunk in chunks for pair in chunk]


def _summarise(msg: dict, folder: str = None) -> dict:
    frm = (msg.get("from") or {}).get("emailAddress", {})
    out = {
        "id": msg.get("id"),
        "subject": msg.get("subject"),
        "from": frm.get("address"),
        "from_name": frm.get("name"),
        "received": msg.get("receivedDateTime"),
        "preview": (msg.get("bodyPreview") or "")[:300],
        "attachments": msg.get("hasAttachments", False),
    }
    if folder is not None:
        out["folder"] = folder
    return out


def _audit(tool: str, caller: dict, params: dict, result: str, count: int = 0) -> None:
    """Per-call audit record → App Insights (primary audit sink per rev-2 plan)."""
    logger.info(
        "mcp_tool_call",
        extra={
            "custom_dimensions": {
                "tool_name": tool,
                "user_identity": caller.get("upn", "unknown"),
                "user_oid": caller.get("oid", ""),
                "input_summary": json.dumps(params),
                "output_summary": result,
                "result_count": count,
                "ts": datetime.utcnow().isoformat() + "Z",
            }
        },
    )


def _error(tool: str, caller: dict, ex: Exception) -> str:
    # Generic client-facing message only (REMEDIATION-GUIDE finding 16): exception
    # text can embed UPNs, mailbox GUIDs, and request URLs. The correlation id links
    # the caller's report to the full server-side trace in App Insights.
    correlation_id = str(uuid.uuid4())
    _audit(tool, caller, {}, f"error: {type(ex).__name__} [{correlation_id}]")
    logger.error("Tool %s failed [%s]: %s", tool, correlation_id, ex, exc_info=True)
    return json.dumps({"error": True, "message": "Request failed.", "correlation_id": correlation_id})


# ── Tools ─────────────────────────────────────────────────────────────────────

@app.mcp_tool()
@app.mcp_tool_property(arg_name="query", description="KQL-style search query (e.g. from:alice@x.com, subject terms, free text).", is_required=True)
@app.mcp_tool_property(arg_name="top", description="Maximum results to return (1-50, default 20).", is_required=False)
async def search_archive_mail(context: MCPToolContext, query: str, top: str = "20") -> str:
    """Search the signed-in user's Exchange Online archive mailbox for messages matching a query. Acts only on the caller's own mailbox via delegated On-Behalf-Of auth."""
    caller = {}
    try:
        caller = _get_caller(context)
        _check_mailbox_allowed(caller["upn"])
        n = max(1, min(int(top or 20), 50))
        token = await _graph_token(context, caller)

        async with aiohttp.ClientSession(
            timeout=aiohttp.ClientTimeout(total=90)
        ) as session:
            try:
                folders = await _archive_folder_list(session, token)
            except RuntimeError as ex:
                if not _is_archive_unaddressable(ex):
                    raise
                # Graph mail API cannot reach this archive — eDiscovery data path.
                kql = ediscovery.build_kql(free_text=query)
                est = await _ediscovery_estimate(session, caller, kql)
                return _ediscovery_response("search_archive_mail", caller, {"query": query, "top": n}, kql, est)
            # $search cannot combine with $orderby/$filter — sort client-side below.
            pairs = await _fanout_messages(session, token, folders, lambda f: (
                f"{GRAPH}/me/mailFolders/{f['id']}/messages"
                f"?$search={quote(json.dumps(query))}"
                f"&$top={n}"
                "&$select=id,subject,from,receivedDateTime,bodyPreview,hasAttachments"
            ))

        seen: set = set()
        merged = []
        for msg, folder in pairs:
            if msg.get("id") in seen:
                continue
            seen.add(msg.get("id"))
            merged.append(_summarise(msg, folder))
        merged.sort(key=lambda m: m["received"] or "", reverse=True)
        results = merged[:n]
        _audit("search_archive_mail", caller, {"query": query, "top": n}, "success", len(results))
        return json.dumps({
            "query": query,
            "count": len(results),
            "truncated": len(merged) > n,
            "folders_searched": len(folders),
            "messages": results,
        })
    except Exception as ex:
        return _error("search_archive_mail", caller, ex)


@app.mcp_tool()
@app.mcp_tool_property(arg_name="start_date", description="Range start, ISO 8601 (YYYY-MM-DD).", is_required=True)
@app.mcp_tool_property(arg_name="end_date", description="Range end, ISO 8601 (YYYY-MM-DD).", is_required=True)
@app.mcp_tool_property(arg_name="top", description="Maximum results to return (1-100, default 50).", is_required=False)
async def get_mail_by_date_range(context: MCPToolContext, start_date: str, end_date: str, top: str = "50") -> str:
    """Retrieve messages from the signed-in user's archive mailbox received within a date range. Dates must be ISO 8601 (YYYY-MM-DD)."""
    caller = {}
    try:
        caller = _get_caller(context)
        _check_mailbox_allowed(caller["upn"])
        start = datetime.fromisoformat(start_date)
        end = datetime.fromisoformat(end_date)
        if start > end:
            raise ValueError("start_date must be on or before end_date.")
        n = max(1, min(int(top or 50), 100))
        token = await _graph_token(context, caller)

        flt = (
            f"receivedDateTime ge {start.date()}T00:00:00Z and "
            f"receivedDateTime le {end.date()}T23:59:59Z"
        )
        async with aiohttp.ClientSession(
            timeout=aiohttp.ClientTimeout(total=90)
        ) as session:
            try:
                folders = await _archive_folder_list(session, token)
            except RuntimeError as ex:
                if not _is_archive_unaddressable(ex):
                    raise
                kql = ediscovery.build_kql(
                    start_iso=str(start.date()), end_iso=str(end.date())
                )
                est = await _ediscovery_estimate(session, caller, kql)
                return _ediscovery_response(
                    "get_mail_by_date_range", caller,
                    {"start": start_date, "end": end_date, "top": n}, kql, est,
                )
            pairs = await _fanout_messages(session, token, folders, lambda f: (
                f"{GRAPH}/me/mailFolders/{f['id']}/messages"
                f"?$filter={quote(flt)}"
                "&$orderby=receivedDateTime desc"
                f"&$top={n}"
                "&$select=id,subject,from,receivedDateTime,bodyPreview,hasAttachments,importance"
            ))

        merged = [_summarise(msg, folder) for msg, folder in pairs]
        merged.sort(key=lambda m: m["received"] or "", reverse=True)
        results = merged[:n]
        _audit("get_mail_by_date_range", caller, {"start": start_date, "end": end_date, "top": n}, "success", len(results))
        return json.dumps({
            "filter": flt,
            "count": len(results),
            "truncated": len(merged) > n,
            "folders_searched": len(folders),
            "messages": results,
        })
    except Exception as ex:
        return _error("get_mail_by_date_range", caller, ex)


@app.mcp_tool()
@app.mcp_tool_property(arg_name="max_depth", description="Folder recursion depth (1-5, default 3).", is_required=False)
async def list_archive_folders(context: MCPToolContext, max_depth: str = "3") -> str:
    """List the folder hierarchy of the signed-in user's Exchange Online archive mailbox."""
    caller = {}
    try:
        caller = _get_caller(context)
        _check_mailbox_allowed(caller["upn"])
        depth_limit = max(1, min(int(max_depth or 3), 5))
        token = await _graph_token(context, caller)

        async with aiohttp.ClientSession(
            timeout=aiohttp.ClientTimeout(total=45)
        ) as session:
            try:
                archive = await _archive_root(session, token)
            except RuntimeError as ex:
                if not _is_archive_unaddressable(ex):
                    raise
                # No folder-hierarchy analogue exists in eDiscovery. Interim
                # behavior per ARCHIVE-DATA-PATH-PLAN §3: say so honestly and
                # point at the search tools. The Graph attempt above self-heals
                # the day Microsoft ships archive Mail-API parity.
                _audit("list_archive_folders", caller, {"max_depth": depth_limit, "data_path": "ediscovery-interim"}, "unavailable")
                return json.dumps({
                    "data_path": "ediscovery-interim",
                    "hierarchy": None,
                    "note": (
                        "The Graph mail API cannot enumerate this Online Archive's folders "
                        "(Microsoft has not shipped archive support yet), and the eDiscovery "
                        "data path has no folder-tree equivalent. Use search_archive_mail or "
                        "get_mail_by_date_range - both reach the archive via Purview eDiscovery. "
                        "This tool will return the real folder tree automatically once Microsoft "
                        "ships Graph archive parity."
                    ),
                })

            async def walk(folder: dict, depth: int) -> dict:
                node = {
                    "id": folder.get("id"),
                    "display_name": folder.get("displayName"),
                    "message_count": folder.get("totalItemCount", 0),
                    "unread_count": folder.get("unreadItemCount", 0),
                    "child_folders": [],
                }
                if depth < depth_limit and folder.get("childFolderCount", 0) > 0:
                    url = (
                        f"{GRAPH}/me/mailFolders/{folder['id']}/childFolders"
                        f"?includeHiddenFolders=true&$top=100&{_FOLDER_SELECT}"
                    )
                    for child in await _graph_get_all(session, token, url):
                        node["child_folders"].append(await walk(child, depth + 1))
                return node

            hierarchy = await walk(archive, 0)

        # The archive ROOT's own totalItemCount only covers items sitting directly
        # at Top of Information Store (~0) — sum the walked tree instead.
        def tree_total(node: dict) -> int:
            return node["message_count"] + sum(tree_total(c) for c in node["child_folders"])

        _audit("list_archive_folders", caller, {"max_depth": depth_limit}, "success", 1)
        return json.dumps({
            "hierarchy": hierarchy,
            "total_messages": tree_total(hierarchy),
            "max_depth_traversed": depth_limit,
        })
    except Exception as ex:
        return _error("list_archive_folders", caller, ex)


@app.mcp_tool()
@app.mcp_tool_property(arg_name="search_id", description="The search_id returned by search_archive_mail or get_mail_by_date_range when the archive query was routed via eDiscovery.", is_required=True)
async def archive_get_search_status(context: MCPToolContext, search_id: str) -> str:
    """Poll a pending Purview eDiscovery archive search for the signed-in user. Returns the match count and size once the estimate completes. Only searches created by the same user can be polled."""
    caller = {}
    try:
        caller = _get_caller(context)
        _check_mailbox_allowed(caller["upn"])
        async with aiohttp.ClientSession(
            timeout=aiohttp.ClientTimeout(total=60)
        ) as session:
            token = await _app_graph_token()
            client = ediscovery.EDiscoveryClient(session, token, caller)
            est = await client.poll_estimate(search_id, budget_seconds=30)
        _audit("archive_get_search_status", caller, {"search_id": search_id, "data_path": "ediscovery"}, est["status"], est["count"])
        note = ""
        if est["status"] == "running":
            note = "Still running - poll again in ~30 seconds."
        return json.dumps({
            "data_path": "ediscovery",
            "search_id": search_id,
            "status": est["status"],
            "matched_count": est["count"],
            "matched_size_bytes": est["size"],
            "note": note,
        })
    except Exception as ex:
        return _error("archive_get_search_status", caller, ex)


@app.mcp_tool()
@app.mcp_tool_property(arg_name="search_id", description="The search_id returned by search_archive_mail or get_mail_by_date_range.", is_required=True)
@app.mcp_tool_property(arg_name="export_operation_id", description="Operation id returned by a previous archive_get_search_results call whose report was still generating. Omit on the first call.", is_required=False)
@app.mcp_tool_property(arg_name="top", description="Maximum items to return (1-100, default 20).", is_required=False)
async def archive_get_search_results(context: MCPToolContext, search_id: str, export_operation_id: str = "", top: str = "20") -> str:
    """Retrieve per-item metadata (subject, sender, date, archive folder) for a completed eDiscovery archive search. Generates a report-only export (no message content). If the report is still generating, returns an export_operation_id to pass on the next call."""
    caller = {}
    try:
        caller = _get_caller(context)
        _check_mailbox_allowed(caller["upn"])
        n = max(1, min(int(top or 20), 100))
        async with aiohttp.ClientSession(
            timeout=aiohttp.ClientTimeout(total=90)
        ) as session:
            token = await _app_graph_token()
            client = ediscovery.EDiscoveryClient(session, token, caller)

            # Ownership + estimate gate.
            search = await client.verify_ownership(search_id)
            est_op = search.get("lastEstimateStatisticsOperation") or {}
            est_status = (est_op.get("status") or "notStarted").lower()
            if est_status != "succeeded":
                return json.dumps({
                    "data_path": "ediscovery",
                    "search_id": search_id,
                    "status": f"estimate_{est_status}",
                    "note": "The search estimate has not completed - poll archive_get_search_status first.",
                })
            count = int(est_op.get("indexedItemCount") or 0)
            if count > ediscovery.EXPORT_ITEM_LIMIT:
                return json.dumps({
                    "data_path": "ediscovery",
                    "search_id": search_id,
                    "status": "too_many_results",
                    "matched_count": count,
                    "note": (f"{count} matches exceeds the export limit of "
                             f"{ediscovery.EXPORT_ITEM_LIMIT}. Narrow the query "
                             "(add sender, subject terms, or a tighter date range) and search again."),
                })

            # Start or resume the report export.
            op_id = export_operation_id or await client.start_export_report(search_id)
            waited = 0
            while True:
                op = await client.get_operation(op_id)
                op_status = (op.get("status") or "notStarted").lower()
                if op_status in ("succeeded", "partiallySucceeded".lower()):
                    break
                if op_status == "failed":
                    raise RuntimeError(f"export report operation {op_id} failed")
                if waited >= 40:
                    return json.dumps({
                        "data_path": "ediscovery",
                        "search_id": search_id,
                        "export_operation_id": op_id,
                        "status": "report_generating",
                        "note": ("The item report is still generating - call archive_get_search_results "
                                 "again with both search_id and export_operation_id in ~30 seconds."),
                    })
                await asyncio.sleep(5)
                waited += 5

            download_token = await _purview_download_token()
            rows, columns = await client.download_report_items(op, download_token)

        rows.sort(key=lambda r: r.get("received") or "", reverse=True)
        items = []
        for r in rows[:n]:
            item = dict(r)
            owa = ediscovery.owa_message_url(r.get("item_id", ""))
            item["open_url"] = owa                                    # webmail (OWA)
            item["open_desktop_url"] = ediscovery.giparchive_url(     # classic Outlook via handler
                r.get("internet_message_id", ""), owa)
            items.append(item)
        _audit("archive_get_search_results", caller, {"search_id": search_id, "top": n, "data_path": "ediscovery"}, "success", len(items))
        resp = {
            "data_path": "ediscovery",
            "search_id": search_id,
            "status": "complete",
            "matched_count": count,
            "returned": len(items),
            "truncated": count > len(items),
            "items": items,
        }
        # Surface the report's real column headers so any unmapped field (e.g.
        # folder path) can be pinned to its actual name rather than guessed.
        if items and not items[0].get("folder"):
            resp["report_columns"] = columns
        return json.dumps(resp)
    except Exception as ex:
        return _error("archive_get_search_results", caller, ex)


# ── RFC 9728 Protected Resource Metadata (MCP spec 2025-06-18 §19.2) ──────────
# Anonymous by design: clients need it BEFORE they have a token.
# See docs/protected-resource-metadata.md.

@app.route(route=".well-known/oauth-protected-resource", auth_level=func.AuthLevel.ANONYMOUS, methods=["GET"])
def protected_resource_metadata(req: func.HttpRequest) -> func.HttpResponse:
    # The resource identifier, the scope's URI prefix, and the Easy Auth audience
    # must all be the SAME string, and it must be the URL the client connects to —
    # RFC 8707 clients send resource=<connector URL>, and Entra rejects the request
    # with AADSTS9010010 if the requested scope belongs to a different resource URI.
    # The URI below must therefore also be (a) an identifierUri on the app reg
    # (Set-ClaudeConnectorAuth.ps1 §identifier-uri) and (b) in the Easy Auth
    # allowedAudiences list (functionapp.bicep).
    hostname = os.environ.get("WEBSITE_HOSTNAME", "localhost")
    server_url = os.environ.get("MCP_SERVER_URL", f"https://{hostname}/runtime/webhooks/mcp")
    tenant_id = os.environ.get("GRAPH_TENANT_ID", "")
    body = {
        "resource": server_url,
        "authorization_servers": [f"https://login.microsoftonline.com/{tenant_id}/v2.0"],
        "scopes_supported": [f"{server_url}/Archive.Read"],
        "bearer_methods_supported": ["header"],
        "resource_documentation": f"{server_url}/docs",
        "mcp_protocol_version": "2025-06-18",
        "resource_type": "mcp-server",
    }
    return func.HttpResponse(
        json.dumps(body),
        status_code=200,
        mimetype="application/json",
        headers={"Cache-Control": "public, max-age=300"},
    )
