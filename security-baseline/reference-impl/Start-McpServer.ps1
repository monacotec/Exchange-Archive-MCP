#Requires -Version 7.0
<#
.SYNOPSIS
    MCP Server Security - Main Entry Point
    Wires all four security modules together and starts the secured MCP server.

.DESCRIPTION
    Load order:
        01-Authorization.ps1   — Roles, permissions, AuthenticatedUser type
        02-JwtService.ps1      — JWT generation and verification
        03-AuthMiddleware.ps1  — Transport-layer Bearer token validation
        04-ToolPermissions.ps1 — Per-tool RBAC enforcement and dispatcher

    Required environment variables (set before running; use a secrets manager
    in production — never hardcode these values):

        MCP_JWT_SECRET    — HMAC-SHA256 signing secret (32+ random bytes)
        MCP_JWT_AUDIENCE  — Expected 'aud' claim  e.g. https://mcp.yourcompany.com
        MCP_JWT_ISSUER    — Expected 'iss' claim  e.g. https://auth.yourcompany.com
        MCP_JWT_EXPIRY    — Token lifetime in seconds (default 1800 = 30 min)
        MCP_LISTEN_PREFIX — HTTP listener prefix   (default http://127.0.0.1:8080/mcp/)

    Quick start (development only — use your identity provider in production):

        $env:MCP_JWT_SECRET   = (New-Guid).Guid + (New-Guid).Guid   # 72 chars
        $env:MCP_JWT_AUDIENCE = 'https://mcp.example.com'
        $env:MCP_JWT_ISSUER   = 'https://auth.example.com'
        $env:MCP_JWT_EXPIRY   = '1800'

        pwsh -File .\Start-McpServer.ps1

    To generate a test token for curl/Invoke-RestMethod:
        . .\02-JwtService.ps1
        $token = New-JwtToken -UserId 'testuser' -Role ([UserRole]::Admin)
        Write-Host $token

.NOTES
    Source: §18 of mcp-security-considerations.md
    Reference: https://github.com/Azure-Samples/mcp-container-ts
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Load all modules in dependency order
# ---------------------------------------------------------------------------

. "$PSScriptRoot/01-Authorization.ps1"
. "$PSScriptRoot/02-JwtService.ps1"
. "$PSScriptRoot/03-AuthMiddleware.ps1"
. "$PSScriptRoot/04-ToolPermissions.ps1"

# ---------------------------------------------------------------------------
# Validate required environment variables before starting
# ---------------------------------------------------------------------------

$requiredVars = @('MCP_JWT_SECRET', 'MCP_JWT_AUDIENCE', 'MCP_JWT_ISSUER')
$missing = $requiredVars | Where-Object { -not (Get-Item "env:$_" -ErrorAction SilentlyContinue) }

if ($missing.Count -gt 0) {
    Write-Error @"
Cannot start MCP server — missing required environment variables:
  $($missing -join ', ')

Set them via your secrets manager before running this script.
See the .DESCRIPTION block for quick-start dev instructions.
"@
    exit 1
}

# ---------------------------------------------------------------------------
# Start the secured MCP server
# ---------------------------------------------------------------------------

$prefix = $env:MCP_LISTEN_PREFIX ?? 'http://127.0.0.1:8080/mcp/'

Write-Host @"

  MCP Security Reference Server
  ==============================
  Listener : $prefix
  Auth     : JWT / HS256 (audience + issuer validated)
  RBAC     : 3-role (Admin / User / ReadOnly), 5 permissions
  Modules  : 01-Authorization, 02-JwtService, 03-AuthMiddleware, 04-ToolPermissions

"@ -ForegroundColor Cyan

# Override the dispatcher in Start-McpServer to use the full tool dispatcher
function Start-SecuredMcpServer {
    param([string] $Prefix = 'http://127.0.0.1:8080/mcp/')

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($Prefix)
    $listener.Start()
    Write-Host "Listening on $Prefix  —  Ctrl-C to stop" -ForegroundColor Green

    try {
        while ($listener.IsListening) {
            $context = $listener.GetContext()

            # Auth middleware — 401 and return $null if invalid
            $user = Invoke-McpAuthMiddleware -Context $context
            if ($null -eq $user) { continue }

            # Tool dispatcher with per-tool RBAC
            Invoke-McpToolDispatcher -Context $context -User $user
        }
    }
    catch [System.Net.HttpListenerException] {
        # Normal on Ctrl-C
        Write-Host "Listener stopped." -ForegroundColor Cyan
    }
    finally {
        if ($listener.IsListening) { $listener.Stop() }
    }
}

Start-SecuredMcpServer -Prefix $prefix
