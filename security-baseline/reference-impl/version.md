# Version Tracking — MCP Security PS1 Package

All files that carry a version number are listed here.
Update this file with every commit that touches any of them.

| File | Version | Last Updated | Notes |
|---|---|---|---|
| `01-Authorization.ps1` | 1.0.0 | 2026-05-23 | Initial release |
| `02-JwtService.ps1` | 1.0.0 | 2026-05-23 | Initial release |
| `03-AuthMiddleware.ps1` | 1.0.0 | 2026-05-23 | Initial release |
| `04-ToolPermissions.ps1` | 1.0.0 | 2026-05-23 | Initial release |
| `Start-McpServer.ps1` | 1.0.0 | 2026-05-23 | Initial release |
| `mcp-security-considerations.md` | 1.0.0 | 2026-05-23 | Three-source reference doc |

## Changelog

### (date correction) — 2026-07-02
- Corrected Last Updated / changelog dates: 2025-05-23 → 2026-05-23 (year typo)
- No code changes in this revision. A dedicated fix pass (remediation findings 1, 8, 9, 19, 24, 33 + Lesson 11 hygiene) is gated BEFORE Local MCP Phase 3 — do not copy patterns from this package until it lands.

### 1.0.0 — 2026-05-23
- Initial release of all five PS1 modules
- Authorization, JWT service, auth middleware, tool permissions, and main entry point
- Translated from Microsoft Azure-Samples/mcp-container-ts (TypeScript)
- Security reference document compiled from three sources (TDS, DBASolved, Microsoft)
