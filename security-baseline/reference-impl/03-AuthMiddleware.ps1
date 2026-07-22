#Requires -Version 7.0
<#
.SYNOPSIS
    MCP Server Security - Step 3: Authentication Middleware
    Translated from Microsoft Azure-Samples/mcp-container-ts (TypeScript)

.DESCRIPTION
    Provides Invoke-McpAuthMiddleware, a function that inspects every inbound
    HTTP request to the MCP endpoint, extracts and verifies the Bearer JWT,
    and attaches the verified AuthenticatedUser to a thread-safe request context.

    If the token is missing, malformed, or invalid, the middleware writes a
    401 response and signals the caller to stop processing — no handler runs.

    Design principles:
    - Auth applied at the transport layer, not inside individual tool handlers
    - "Bearer" scheme required explicitly (loose header parsing is a common bypass)
    - Authenticated user object passed forward via context — never trust re-parsed claims
    - All auth failures return identical HTTP 401 with a safe error message
      (no details that help an attacker distinguish valid vs invalid user IDs)

    Usage in a HttpListener-based MCP server loop:

        $context = $listener.GetContext()
        $user    = Invoke-McpAuthMiddleware -Context $context
        if ($null -eq $user) { continue }   # 401 already written; skip to next request
        Invoke-McpToolDispatcher -Context $context -User $user

.NOTES
    Source: §18 of mcp-security-considerations.md
    Reference: https://github.com/Azure-Samples/mcp-container-ts
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/01-Authorization.ps1"
. "$PSScriptRoot/02-JwtService.ps1"

# ---------------------------------------------------------------------------
# Helper: write a JSON error response and close the output stream
# ---------------------------------------------------------------------------

function Write-HttpError {
    param(
        [System.Net.HttpListenerResponse] $Response,
        [int]    $StatusCode,
        [string] $ErrorKey,
        [string] $Message
    )

    $body  = @{ error = $ErrorKey; message = $Message } | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)

    $Response.StatusCode        = $StatusCode
    $Response.ContentType       = 'application/json'
    $Response.ContentLength64   = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

# ---------------------------------------------------------------------------
# Middleware function
# ---------------------------------------------------------------------------

function Invoke-McpAuthMiddleware {
    <#
    .SYNOPSIS
        Validates the Bearer JWT on an inbound HttpListenerContext.
        Returns an AuthenticatedUser on success, or $null after writing 401.

    .PARAMETER Context
        The System.Net.HttpListenerContext from HttpListener.GetContext().

    .OUTPUTS
        AuthenticatedUser | $null
    #>
    [OutputType([AuthenticatedUser])]
    param(
        [Parameter(Mandatory)]
        [System.Net.HttpListenerContext] $Context
    )

    $request  = $Context.Request
    $response = $Context.Response

    # 1. Require Authorization header with Bearer scheme
    $authHeader = $request.Headers['Authorization']
    if (-not $authHeader -or -not $authHeader.StartsWith('Bearer ', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "[AUTH] 401 — missing or non-Bearer Authorization header  path=$($request.RawUrl)" -ForegroundColor Yellow
        Write-HttpError -Response $response -StatusCode 401 `
            -ErrorKey 'authentication_required' `
            -Message  "Authorization header with 'Bearer' scheme must be provided."
        return $null
    }

    # 2. Extract raw token (strip "Bearer " prefix)
    $rawToken = $authHeader.Substring(7).Trim()
    if ([string]::IsNullOrEmpty($rawToken)) {
        Write-HttpError -Response $response -StatusCode 401 `
            -ErrorKey 'authentication_required' `
            -Message  "Bearer token is empty."
        return $null
    }

    # 3. Verify the token — Test-JwtToken throws on any failure
    try {
        $user = Test-JwtToken -Token $rawToken
        Write-Host "[AUTH] OK  user=$($user.Id)  role=$($user.Role)  path=$($request.RawUrl)" -ForegroundColor Green
        return $user
    }
    catch [System.Security.SecurityException] {
        # Token structurally invalid, tampered, expired, wrong audience/issuer
        Write-Host "[AUTH] 401 — $($_.Exception.Message)  path=$($request.RawUrl)" -ForegroundColor Yellow
        Write-HttpError -Response $response -StatusCode 401 `
            -ErrorKey 'invalid_token' `
            -Message  $_.Exception.Message
        return $null
    }
    catch {
        # Unexpected error — log internally but return a generic message to the caller
        Write-Host "[AUTH] 500 — unexpected error: $($_.Exception.Message)" -ForegroundColor Red
        Write-HttpError -Response $response -StatusCode 500 `
            -ErrorKey 'internal_error' `
            -Message  "An internal error occurred during authentication."
        return $null
    }
}

# ---------------------------------------------------------------------------
# Skeleton MCP server loop showing middleware placement
# ---------------------------------------------------------------------------

function Start-McpServer {
    <#
    .SYNOPSIS
        Minimal HttpListener loop demonstrating where auth middleware is applied.
        Replace Invoke-McpToolDispatcher with your actual MCP tool dispatch logic.

    .PARAMETER Prefix
        The URL prefix to listen on. Default: http://127.0.0.1:8080/mcp/
        NEVER use http://+/ or http://0.0.0.0/ — bind to localhost only.
    #>
    param(
        [string] $Prefix = 'http://127.0.0.1:8080/mcp/'
    )

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($Prefix)
    $listener.Start()
    Write-Host "MCP server listening on $Prefix  (Ctrl-C to stop)" -ForegroundColor Cyan

    try {
        while ($listener.IsListening) {
            $context = $listener.GetContext()

            # Auth middleware runs FIRST — before any tool handler
            $user = Invoke-McpAuthMiddleware -Context $context

            # If $null, a 401 was already written; skip to the next request
            if ($null -eq $user) { continue }

            # Hand off to your MCP tool dispatcher with the verified user
            # Invoke-McpToolDispatcher -Context $context -User $user
            Write-Host "[DISPATCH] Would dispatch to tool handler for user=$($user.Id)" -ForegroundColor Cyan

            # Placeholder: echo back the authenticated user identity
            $body  = (@{ status = 'ok'; user = $user.Id; role = $user.Role.ToString() } | ConvertTo-Json -Compress)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
            $context.Response.ContentType     = 'application/json'
            $context.Response.ContentLength64 = $bytes.Length
            $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $context.Response.OutputStream.Close()
        }
    }
    finally {
        $listener.Stop()
        Write-Host "MCP server stopped." -ForegroundColor Cyan
    }
}

# ---------------------------------------------------------------------------
# Run the server if executed directly (not dot-sourced)
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    Write-Host "=== MCP Auth Middleware module ===" -ForegroundColor Cyan
    Write-Host "Call Start-McpServer to launch the skeleton listener."
    Write-Host "Ensure MCP_JWT_SECRET, MCP_JWT_AUDIENCE, MCP_JWT_ISSUER are set first."
}
