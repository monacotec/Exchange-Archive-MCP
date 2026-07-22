# Exchange Archive MCP

MCP servers that give Claude and Foundry agents access to **Exchange Online
In-Place (Online) Archive** mailboxes at GI Partners, plus the security baseline
both must meet.

**Status (2026-07-22):** the cloud (Foundry) MCP is live and reads archives via a
**Purview eDiscovery data path** — because Microsoft Graph's mail API cannot read
In-Place Archives at all (see `docs/online-archive-graph-findings.md`). A
workstation "open in classic Outlook" handler is in progress.

## Repository map

| Path | What it is |
|---|---|
| [`foundry-mcp/`](foundry-mcp/) | **Cloud MCP** — Azure Functions (Python), per-user OAuth 2.1 + OBO, eDiscovery-backed archive read tools, RFC 9728 PRM. `function_app.py`, `ediscovery.py`, `infra/` (Bicep), `scripts/` (setup/rotation/diagnostics), `desktop-handler/` (the `giparchive:` C# handler). |
| [`local-mcp/`](local-mcp/) | **Local MCP** — PowerShell 7 / stdio, delegated `Connect-MgGraph`, read + write tools with two-step confirm. `src/`, `tests/` (Pester), `packaging/`, `spike/`, `config/`. |
| [`gi-foundry/`](gi-foundry/) | Supporting Azure infra source (Foundry IaC, Entra/rotation scripts, universal-print). |
| [`security-baseline/`](security-baseline/) | `mcp-security-considerations.md` checklist + a PS7 **reference implementation** (patterns only — not production code). |
| [`plans/`](plans/) | Build plans and architecture decisions (see below). |
| [`docs/`](docs/) | Operational docs — wiring, findings, runbooks, guardrails. |

### Key plans (`plans/`)
- `BUILD-ORDER.md` — cross-plan sequencing.
- `LOCAL-MCP-PLAN.md`, `FOUNDRY-MCP-PLAN.md` — the two build plans.
- `ARCHIVE-DATA-PATH-PLAN.md` — the eDiscovery data-path architecture (E0–E4).
- `OUTLOOK-DESKTOP-OPEN-PLAN.md` — the `giparchive:` desktop handler + code signing.

### Key docs (`docs/`)
- `online-archive-graph-findings.md` — why Graph can't read the archive (the pivot).
- `claude-desktop-wiring.md` — connecting each MCP to Claude Desktop.
- `artifact-signing-identity-validation-runbook.md` — code-signing setup (long pole).
- `microsoft-support-case-draft.md`, `claude-code-az-guardrail.md`, `audit-verification.md`, `protected-resource-metadata.md`.

### Top-level references
- `DAY-ZERO-HYGIENE.md` — IaC/CI secret-hygiene pass (code patches applied; manual + verify steps tracked).
- `REMEDIATION-GUIDE.md` — 49 adversarially-verified security findings in 11 lessons.
- `exchange-archive-mcp-online-archive-fix.md` — the original (Graph-based) archive-fix briefing, superseded by the eDiscovery data path but kept for the evidence chain.
- `CHANGES.md` — change history.

## The two servers

- **Local MCP** — principal is the *human at the keyboard*. Delegated identity,
  stdio, write tools gated by two-step confirm. For operations that mutate a mailbox.
- **Foundry MCP** — read-only, org-discoverable for Foundry agents and Claude
  Desktop. Per-user OAuth 2.1 with On-Behalf-Of; archive reads go through Purview
  eDiscovery (one app-owned case per caller, server-side scoped to the verified user).

## How archive access actually works (the important part)

Microsoft Graph's mail API returns 404 for every In-Place Archive well-known folder
— archive access is an unshipped Graph capability, and it affects auto-expanding
archives (execs) permanently. The Foundry MCP therefore tries Graph first (so it
self-upgrades if/when Microsoft ships parity) and falls back to **Purview
eDiscovery**: a per-caller app-owned case, async search + estimate, report-only
export for per-item metadata. Full evidence and decision record in
`docs/online-archive-graph-findings.md` and `plans/ARCHIVE-DATA-PATH-PLAN.md`.

## Conventions

- Versioning per `foundry-mcp/version.md` and `local-mcp/version.md` (every file
  carrying a version string is listed there; bump together).
- All Azure/Graph work ships as user-run PowerShell in `*/scripts/` — never run
  directly from tooling (see `docs/claude-code-az-guardrail.md`).
- Secrets live in Key Vault and `.env` (gitignored); nothing sensitive is committed.
