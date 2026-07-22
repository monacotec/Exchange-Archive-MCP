# gi-foundry — patched copy pending port-back

This directory is a **copy of the separate `gi-foundry` repo**, carried in this bundle so the
Day-Zero Hygiene security patches (2026-07-02, findings from [`../REMEDIATION-GUIDE.md`](../REMEDIATION-GUIDE.md))
could be applied in one place. See [`../DAY-ZERO-HYGIENE.md`](../DAY-ZERO-HYGIENE.md) for the patch list
and `version.md` here for the 1.1.0 changelog.

**Do not treat this as the gi-foundry repo of record.** Port the patched files back to that repo,
then this copy can be deleted.

## What moved out of here

Per the rev-2 file map ([`../CHANGES.md`](../CHANGES.md)), the Exchange MCP pieces now live in
[`../foundry-mcp/`](../foundry-mcp/) and are developed there:

- `exchange-mcp/` (entire directory) → `../foundry-mcp/`
- `scripts/Register-EntraApp.ps1` → `../foundry-mcp/scripts/`
- `scripts/Set-ApplicationAccessPolicy.ps1` → `../foundry-mcp/scripts/`
- `scripts/Rotate-MCPClientSecret.ps1` → `../foundry-mcp/scripts/`

## What remains (all destined for the gi-foundry repo)

- `foundry-iac/` — Foundry Hub Bicep stack (day-zero patches applied: keyless OAI connection, OIDC CI)
- `scripts/Deploy-Foundry.ps1` — deployment driver
- `scripts/Rotate-OAIKey.ps1` — ⚠️ deferred fix; superseded by keyless connection (day-zero task 8)
- `universal-print/` — unrelated to MCP; belongs to the gi-foundry repo's Phase 5
- `CLAUDE.md`, `version.md` — that repo's plan and version table
