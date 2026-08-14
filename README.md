# Exchange Archive MCP

MCP servers that give Claude and Foundry agents access to **Exchange Online
In-Place (Online) Archive** mailboxes at GI Partners, the shared data store behind
them, and the security baseline they must meet.

**Status (2026-08-14):** in production use. The cloud (Foundry) MCP reads archives
via a **Purview eDiscovery data path** — Microsoft Graph's mail API cannot read
In-Place Archives at all. Access is assignment-gated with self-service requests, an
always-on **archive index** in Azure SQL answers repeat queries without re-querying
Microsoft, and the `giparchive:` desktop handler is code-signed and ready to
distribute.

## Repository map

| Path | What it is |
|---|---|
| [`foundry-mcp/`](foundry-mcp/) | **Cloud MCP** — Azure Functions (Python), per-user OAuth 2.1 + OBO, eDiscovery-backed archive tools, RFC 9728 PRM. `function_app.py`, `ediscovery.py`, `infra/` (Bicep incl. the shared SQL host), `sql/` (archive-index schema), `scripts/` (setup, rotation, diagnostics, SQL loader), `desktop-handler/` (the signed `giparchive:` handler). |
| [`local-mcp/`](local-mcp/) | **Local MCP** — PowerShell 7 / stdio, delegated `Connect-MgGraph`, read + write tools with two-step confirm. `src/`, `tests/` (Pester), `packaging/`, `spike/`, `config/`. |
| [`scripts/`](scripts/) | Suite-level tooling — `Test-VersionManifest.ps1` verifies `version.md` against every file's own version anchor. |
| [`security-baseline/`](security-baseline/) | `mcp-security-considerations.md` checklist + a PS7 reference implementation (patterns only — not production code). |
| [`plans/`](plans/) | Build plans and architecture decisions. |
| [`docs/`](docs/) | Operational docs, briefs, runbooks, findings. |
| [`archive/`](archive/) | Superseded material kept for the record — including `gi-foundry/`, the origin project (see `docs/gi-foundry-lessons.md`). |

### Key plans (`plans/`)
- `BUILD-ORDER.md` — cross-plan sequencing.
- `LOCAL-MCP-PLAN.md`, `FOUNDRY-MCP-PLAN.md` — the two build plans.
- `ARCHIVE-DATA-PATH-PLAN.md` — the eDiscovery data-path architecture (E0–E4).
- `OUTLOOK-DESKTOP-OPEN-PLAN.md` — the `giparchive:` desktop handler + code signing.

### Key docs (`docs/`)
- `online-archive-graph-findings.md` — why Graph can't read the archive (the pivot).
- `REMEDIATION-GUIDE.md` — 49 adversarially-verified security findings in 11 lessons.
- `DAY-ZERO-HYGIENE.md` — IaC/CI secret-hygiene pass.
- `gi-foundry-lessons.md` — what to keep (and deliberately not inherit) from the origin project.
- `claude-desktop-wiring.md` — connecting each MCP to Claude Desktop.
- `azure-architecture.html`, `azure-footprint.html`, `leadership-brief.html` — the briefs (dark-mode toggle included).
- `history/` — superseded briefings kept for their evidence chains.

## The two servers

- **Local MCP** — principal is the *human at the keyboard*. Delegated identity,
  stdio, write tools gated by two-step confirm. For operations that mutate a mailbox.
- **Foundry MCP** — read-only, org-discoverable for Foundry agents and Claude
  Desktop. Per-user OAuth 2.1 with On-Behalf-Of; archive reads go through Purview
  eDiscovery (one app-owned case per caller, scoped server-side to the verified user).

## How archive access actually works (the important part)

Microsoft Graph's mail API returns 404 for every In-Place Archive well-known folder —
archive access is an unshipped Graph capability, and it affects auto-expanding archives
(execs) permanently. The Foundry MCP therefore tries Graph first (so it self-upgrades
if/when Microsoft ships parity) and falls back to **Purview eDiscovery**: a per-caller
app-owned case, async search + estimate, report-only export for per-item metadata. Full
evidence in `docs/online-archive-graph-findings.md` and `plans/ARCHIVE-DATA-PATH-PLAN.md`.

## The archive index

`gip-mcp-hub-sql.database.windows.net` is a shared Azure SQL host — **one database per
MCP**, `ArchiveIndex` first. It stores message **metadata only** (subject, sender, date,
folder, message id); never bodies or attachments. Entra-only auth, always-on tier so
nothing waits on a resume.

```powershell
foundry-mcp\scripts\Initialize-McpSqlHost.ps1            # provision / verify; -AddDatabase for the next MCP
foundry-mcp\scripts\Import-ArchiveSearchToSql.ps1 ...    # load a query; -VerifyOnly to audit
foundry-mcp\scripts\New-WelcomeToGipReport.ps1           # example report off the index
```

## Access

Sign-in requires assignment to `SG-Exchange-Archive-MCP-Users`. Anyone else requests
access at [myaccess.microsoft.com](https://myaccess.microsoft.com) ("Exchange Archive MCP
access"); approval adds them to the group. See `foundry-mcp/scripts/Enable-McpAccessRequests.ps1`.

## Conventions

- **One manifest:** [`version.md`](version.md) at the repo root lists every versioned
  file; per-component `version.md` files are redirect stubs. Verify with
  `scripts/Test-VersionManifest.ps1` (exits 1 on drift).
- **All Azure/Graph work ships as user-run PowerShell** in `*/scripts/` — never invoked
  directly from tooling (`docs/claude-code-az-guardrail.md`). Scripts double as verifiers:
  every one has a `-VerifyOnly` or equivalent, prints `[OK]`/`[!!]` lines, and logs to
  `logs/`.
- **Never float a preview extension bundle.** `host.json` pins an exact version; a
  floating range caused the 11 Aug 2026 outage.
- Secrets live in Key Vault and `.env` (gitignored); nothing sensitive is committed.
