# Local MCP — Exchange Archive

PowerShell 7 MCP server for Claude Desktop. Delegated Graph access to the signed-in user's Exchange Online archive mailbox over stdio.

This directory is self-contained — it ships as the PDQ payload for end-user installs. The Foundry-hosted MCP lives separately under [`../foundry-mcp/`](../foundry-mcp/).

## Layout

```
local-mcp/
├── ExchangeArchiveMcp.psd1       Module manifest (ModuleVersion = source of truth)
├── DESIGN.md                     Design conventions
├── SECURITY.md                   Threat model, mitigations
├── version.md                    Version table for this MCP
├── spike/
│   └── Spike-ArchiveAccess.ps1   Phase 0 spike — Microsoft.Graph.Authentication
├── src/
│   ├── Server.ps1                stdio JSON-RPC dispatcher
│   ├── Auth/
│   │   ├── Connect-McpGraph.ps1
│   │   └── Resolve-UserContext.ps1
│   ├── Lib/
│   │   ├── Invoke-McpGraph.ps1   Wrapper over Invoke-MgGraphRequest (retry, correlation)
│   │   ├── Get-ArchiveRoot.ps1   Hidden-folder traversal to the archive root
│   │   ├── ConvertTo-KqlQuery.ps1
│   │   ├── Write-AuditLog.ps1
│   │   └── New-ConfirmationToken.ps1
│   ├── Tools/                    archive_* tool implementations
│   └── Transport/StdioTransport.ps1
├── tests/Pester/                 Pester 5 suite (HMAC + KQL)
├── config/appsettings.example.json
└── packaging/
    ├── deploy-local.ps1          Local dev → registered runtime (gates on Pester, mirrors src\)
    ├── install.ps1               Org-wide PDQ install (→ %LOCALAPPDATA%\ExchangeArchiveMcp)
    ├── build-pdq-package.ps1     Builds the PDQ-deployable zip
    └── uninstall.ps1
```

## Quick start

```powershell
# One-time
Install-Module Microsoft.Graph.Authentication -Scope CurrentUser

# Run the spike to confirm archive access
pwsh ./spike/Spike-ArchiveAccess.ps1 -ClientId <APP_REG_GUID> -TenantId <TENANT_GUID>

# Run the MCP standalone (for diagnostics; Claude Desktop launches it automatically)
pwsh ./src/Server.ps1 -ConfigPath ./config/appsettings.example.json
```

Claude Desktop wiring is documented in [`../docs/claude-desktop-wiring.md`](../docs/claude-desktop-wiring.md).

## Deploying changes

This repo is the **single source of truth**. There are two distinct deploy targets — do not confuse them:

| Path | Target | Server name | When |
|---|---|---|---|
| `packaging/deploy-local.ps1` | a fixed runtime dir (default `C:\GI\MCP-Archive`) | `exchange-archive-local` | This machine's dev → runtime loop |
| `packaging/install.ps1` (via `build-pdq-package.ps1`) | `%LOCALAPPDATA%\ExchangeArchiveMcp\app` | `exchange-archive-local` | Org-wide PDQ rollout |

**The registered MCP server on this machine launches from the runtime dir, not from this repo** (see `%APPDATA%\Claude\claude_desktop_config.json`). Editing files here has **no effect** until you redeploy and restart the server.

### Local dev loop

```powershell
# 1. Make your change in src\ and add/adjust tests in tests\Pester\
# 2. Deploy: runs the full Pester suite as a gate, mirrors src\ + the manifest
#    into the runtime, and verifies the runtime payload is byte-identical to repo.
pwsh -NoProfile -File packaging\deploy-local.ps1
#    (override the target with -RuntimeRoot <path>; -SkipTests is discouraged)
# 3. Restart the "exchange-archive-local" MCP server in Claude Desktop — Server.ps1
#    dot-sources src\ once at startup, so changes apply only after a restart.
```

The Pester gate is a hard stop: if any test fails, nothing is copied. `deploy-local.ps1` never touches the live `config\appsettings.json` in the runtime (only `appsettings.example.json` is refreshed). Tests are intentionally **not** deployed — they run from the repo as the gate, matching the PDQ payload set in `build-pdq-package.ps1`.

> Note: the runtime is a hand-placed copy outside this OneDrive-synced tree on purpose (no path spaces, no sync churn). If you ever stand up a fresh runtime dir, create it and its `config\appsettings.json` first, then run `deploy-local.ps1 -RuntimeRoot <newpath>` and point `claude_desktop_config.json` at `<newpath>\src\Server.ps1`.

## Phase status

| Phase | Status |
|---|---|
| 0 — Spike | Code in `spike/`; run against a GI mailbox to validate |
| 1 — Read-only stdio MCP | Code in `src/`; 5 tools wired; Pester for KQL + HMAC |
| 2 — Write tools + confirm | Token helper landed in `Lib/New-ConfirmationToken.ps1`; tools not yet wired into Server.ps1 |
| 3 — HTTPS transport | Not started |
| 4 — Security hardening | Not started |

See [`../plans/LOCAL-MCP-PLAN.md`](../plans/LOCAL-MCP-PLAN.md) for full phase definitions.
