# version.md — Local MCP

Version table for the Local MCP only. The Foundry MCP tracks its own files in [`../foundry-mcp/version.md`](../foundry-mcp/version.md) (TBD).

**Current release:** `0.3.1` (Online Archive fix — read tools resolve `archivemsgfolderroot`, search fans out per-folder; see `../exchange-archive-mcp-online-archive-fix.md`)

The `.psd1` `ModuleVersion` is the public-facing version. Bump these together.

## Tracked files

| Path | Current | Version anchor | Bumped when |
|---|---|---|---|
| `ExchangeArchiveMcp.psd1` | `0.3.1` | `ModuleVersion` | Source of truth |
| `src/Server.ps1` | `0.3.2` | `# Version:` header | Each merged change |
| `src/Auth/Connect-McpGraph.ps1` | `0.2.0` | `# Version:` header | Each merged change |
| `src/Auth/Resolve-UserContext.ps1` | `0.2.0` | `# Version:` header | Each merged change |
| `src/Lib/Invoke-McpGraph.ps1` | `0.2.0` | `# Version:` header | Each merged change |
| `src/Lib/Get-ArchiveRoot.ps1` | `0.3.0` | `# Version:` header | Each merged change |
| `src/Lib/ConvertTo-KqlQuery.ps1` | `0.3.0` | `# Version:` header | Each merged change |
| `src/Lib/Write-AuditLog.ps1` | `0.2.0` | `# Version:` header | Each merged change |
| `src/Lib/New-ConfirmationToken.ps1` | `0.2.0` | `# Version:` header | Each merged change |
| `src/Lib/Test-ReplayGuard.ps1` | `0.1.0` | `# Version:` header | Each merged change |
| `src/Lib/Resolve-MailFolder.ps1` | `0.1.0` | `# Version:` header | Each merged change |
| `src/Lib/Invoke-WriteOp.ps1` | `0.1.0` | `# Version:` header | Each merged change |
| `src/Tools/Search-Archive.ps1` | `0.3.0` | `# Version:` header | Each merged change |
| `src/Tools/Get-ArchiveMessage.ps1` | `0.2.0` | `# Version:` header | Each merged change |
| `src/Tools/Get-ArchiveAttachment.ps1` | `0.2.0` | `# Version:` header | Each merged change |
| `src/Tools/List-ArchiveFolders.ps1` | `0.2.1` | `# Version:` header | Each merged change |
| `src/Tools/Get-ArchiveStats.ps1` | `0.2.1` | `# Version:` header | Each merged change |
| `src/Tools/Restore-ArchiveItem.ps1` | `0.1.0` | `# Version:` header | Each merged change |
| `src/Tools/Copy-ArchiveToPrimary.ps1` | `0.1.0` | `# Version:` header | Each merged change |
| `src/Tools/Move-ArchiveToPrimary.ps1` | `0.1.0` | `# Version:` header | Each merged change |
| `src/Transport/StdioTransport.ps1` | `0.1.0` | `# Version:` header | Each merged change |
| `spike/Spike-ArchiveAccess.ps1` | `0.2.0` | `.NOTES Version:` block | Each spike iteration |
| `config/appsettings.example.json` | `0.3.0` | `"schemaVersion"` | Bump when shape changes |
| `DESIGN.md` | rev 2 | header date | Material design change |
| `SECURITY.md` | rev 2 | header date | Material threat-model change |
| `README.md` | rev 2 | — | When layout changes |

## Phase markers

| Phase | Target version |
|---|---|
| Phase 0 spike | `0.0.x` |
| Phase 1 read-only stdio | `0.2.0` |
| Phase 2 write tools | `0.3.0` ← current |
| Phase 3 HTTPS hosted | `0.4.0` |
| First stable | `1.0.0` |

## Release process

1. Bump `ExchangeArchiveMcp.psd1` `ModuleVersion`.
2. Walk this table top to bottom; bump each file's anchor.
3. Run Pester suite (`Invoke-Pester ./tests/Pester`) — must be green.
4. Tag: `local-mcp-vX.Y.Z`.
