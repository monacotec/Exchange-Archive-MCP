# MCP Server Security — PowerShell 7 Reference Implementation

PowerShell 7 translation of the JWT + RBAC security patterns from
[Microsoft Azure-Samples/mcp-container-ts](https://github.com/Azure-Samples/mcp-container-ts),
as documented in `mcp-security-considerations.md` §18.

---

## Files

| File | Purpose |
|---|---|
| `01-Authorization.ps1` | `UserRole` / `Permission` enums, `AuthenticatedUser` class, role-permission map |
| `02-JwtService.ps1` | JWT generation (`New-JwtToken`) and verification (`Test-JwtToken`) via HMAC-SHA256 |
| `03-AuthMiddleware.ps1` | `Invoke-McpAuthMiddleware` — transport-layer Bearer token validation for `HttpListener` |
| `04-ToolPermissions.ps1` | Tool registry, `Get-AllowedTools`, `Invoke-McpTool`, `Invoke-McpToolDispatcher` |
| `Start-McpServer.ps1` | Entry point — loads all modules, validates env vars, starts the secured listener |
| `version.md` | Version tracking for all files |

---

## Quick Start

### 1. Set required environment variables

```powershell
# Development only — use a secrets manager (Key Vault, AWS Secrets Manager, etc.) in production
$env:MCP_JWT_SECRET   = (New-Guid).Guid + (New-Guid).Guid   # 72-char random string
$env:MCP_JWT_AUDIENCE = 'https://mcp.example.com'
$env:MCP_JWT_ISSUER   = 'https://auth.example.com'
$env:MCP_JWT_EXPIRY   = '1800'   # 30 minutes; use 900 (15 min) for enterprise
```

### 2. Generate a test token

```powershell
. .\01-Authorization.ps1
. .\02-JwtService.ps1

# Admin token
$adminToken = New-JwtToken -UserId 'testuser' -Role ([UserRole]::Admin)
Write-Host $adminToken

# Read-only token
$roToken = New-JwtToken -UserId 'readonly' -Role ([UserRole]::ReadOnly)
```

### 3. Start the server

```powershell
pwsh -File .\Start-McpServer.ps1
```

### 4. Test with Invoke-RestMethod

```powershell
# List tools (read-only token — will see list_todos only)
Invoke-RestMethod -Uri 'http://127.0.0.1:8080/mcp/' `
    -Method Post `
    -Headers @{ Authorization = "Bearer $roToken" } `
    -ContentType 'application/json' `
    -Body '{"jsonrpc":"2.0","id":"1","method":"tools/list","params":{}}'

# Attempt delete as read-only (expect insufficient_permissions)
Invoke-RestMethod -Uri 'http://127.0.0.1:8080/mcp/' `
    -Method Post `
    -Headers @{ Authorization = "Bearer $roToken" } `
    -ContentType 'application/json' `
    -Body '{"jsonrpc":"2.0","id":"2","method":"tools/call","params":{"name":"delete_todo","arguments":{"id":"42"}}}'
```

---

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `MCP_JWT_SECRET` | Yes | — | HMAC-SHA256 signing secret. Use 32+ random bytes. |
| `MCP_JWT_AUDIENCE` | Yes | — | Expected `aud` claim. Your MCP server's identifier. |
| `MCP_JWT_ISSUER` | Yes | — | Expected `iss` claim. Your identity provider's URL. |
| `MCP_JWT_EXPIRY` | No | `1800` | Token lifetime in seconds. Use `900` (15 min) for enterprise. |
| `MCP_LISTEN_PREFIX` | No | `http://127.0.0.1:8080/mcp/` | HTTP listener prefix. **Never change to `0.0.0.0`**. |

---

## Security Notes

- **Algorithm is locked to HS256.** The "none" algorithm bypass is explicitly rejected in `Test-JwtToken`.
- **Audience and issuer are validated on every request** — tokens cannot be reused across services.
- **Secrets are never hardcoded.** The JWT service throws at startup if any required env var is missing.
- **Auth runs at the transport layer** before any tool handler. No handler is reachable without a valid token.
- **Tool discovery is permission-filtered.** A read-only caller cannot see tools they cannot call.
- **The listener binds to `127.0.0.1` only.** Never change the prefix to `0.0.0.0` or `+`.

---

## Adapting to Your MCP Server

1. Replace the tool stubs in `04-ToolPermissions.ps1` (`$script:ToolRegistry`) with your actual tools and handlers.
2. Add any new `Permission` values to `01-Authorization.ps1` and update `$script:RolePermissions` accordingly.
3. In production, tokens should be issued by your identity provider (Azure AD, Okta, etc.) — use `New-JwtToken` for dev/testing only.
4. For full MCP Authorization Specification compliance, extend `02-JwtService.ps1` with PKCE and the additional OAuth 2.1 flows described in the official spec.

---

## References

- Microsoft. *It's time to secure your MCP servers. Here's how.* https://techcommunity.microsoft.com/blog/azuredevcommunityblog/its-time-to-secure-your-mcp-servers-heres-how-/4434308
- Microsoft. *Azure-Samples/mcp-container-ts*. https://github.com/Azure-Samples/mcp-container-ts
- Anthropic. *MCP Authorization Specification*. https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization
- `mcp-security-considerations.md` — full security reference (included in this package)
