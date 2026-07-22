#Requires -Version 7.0
<#
.SYNOPSIS
    MCP Server Security - Step 4: Per-Tool Permission Enforcement
    Translated from Microsoft Azure-Samples/mcp-container-ts (TypeScript)

.DESCRIPTION
    Demonstrates the three-check pattern that every MCP tool handler should
    implement, and a central dispatcher that applies it consistently.

    The three checks (per handler, after middleware passes):
        1. Is there an authenticated user on the request? (should always be true
           if middleware ran, but defensive coding requires explicit check)
        2. Does the user hold the specific Permission required for this tool?
        3. Filter the visible tool list to only tools the caller can reach —
           never return tools the caller cannot call.

    Why tool-level filtering matters:
        Returning the full tool list to a read-only caller and then rejecting
        calls at execution time leaks the server's capability surface and
        gives an attacker a free enumeration of available tools.

    Tool registry pattern:
        Each registered tool declares its required Permission. The dispatcher
        enforces both discovery-time and execution-time permission checks
        from the same declaration, so there is no drift between the two.

.NOTES
    Source: §18 of mcp-security-considerations.md
    Reference: https://github.com/Azure-Samples/mcp-container-ts
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/01-Authorization.ps1"

# ---------------------------------------------------------------------------
# Tool registry
# Each entry declares:
#   Name        - the MCP tool name clients invoke
#   Description - shown in tool listing to authorised callers
#   Permission  - the single Permission a caller must hold to discover AND call
#   Handler     - scriptblock that executes the tool; receives ($User, $Params)
# ---------------------------------------------------------------------------

$script:ToolRegistry = @(
    @{
        Name        = 'list_todos'
        Description = 'Returns all todo items visible to the caller.'
        Permission  = [Permission]::ReadTodos
        Handler     = {
            param($User, $Params)
            # Replace with real data access
            return @{ todos = @('Buy milk', 'Write tests') }
        }
    },
    @{
        Name        = 'create_todo'
        Description = 'Creates a new todo item.'
        Permission  = [Permission]::CreateTodos
        Handler     = {
            param($User, $Params)
            $text = $Params.text ?? 'Untitled'
            return @{ created = $true; text = $text; createdBy = $User.Id }
        }
    },
    @{
        Name        = 'update_todo'
        Description = 'Updates an existing todo item.'
        Permission  = [Permission]::UpdateTodos
        Handler     = {
            param($User, $Params)
            return @{ updated = $true; id = $Params.id; updatedBy = $User.Id }
        }
    },
    @{
        Name        = 'delete_todo'
        Description = 'Deletes a todo item. Requires admin or user role.'
        Permission  = [Permission]::DeleteTodos
        Handler     = {
            param($User, $Params)
            return @{ deleted = $true; id = $Params.id; deletedBy = $User.Id }
        }
    }
)

# ---------------------------------------------------------------------------
# Core enforcement functions
# ---------------------------------------------------------------------------

function Get-AllowedTools {
    <#
    .SYNOPSIS
        Returns only the tools the authenticated user is permitted to discover.
        Never returns tools the caller cannot call.

    .PARAMETER User
        The verified AuthenticatedUser from the auth middleware.
    .OUTPUTS
        hashtable[] — filtered subset of $script:ToolRegistry
    #>
    [OutputType([hashtable[]])]
    param(
        [Parameter(Mandatory)]
        [AuthenticatedUser] $User
    )

    # Check 1: authenticated
    if ($null -eq $User) {
        throw [System.UnauthorizedAccessException]"Authentication required."
    }

    # Check 2: must hold LIST_TOOLS to get any listing at all
    if (-not (Test-UserHasPermission -User $User -Required ([Permission]::ListTools))) {
        return @()   # empty list — not an error, just no visibility
    }

    # Check 3: filter to tools the caller can actually call
    return @($script:ToolRegistry | Where-Object {
        Test-UserHasPermission -User $User -Required $_.Permission
    })
}

function Invoke-McpTool {
    <#
    .SYNOPSIS
        Executes a named MCP tool after verifying the caller holds the required permission.

    .DESCRIPTION
        Three-check pattern:
          1. Authenticated user present
          2. Tool exists in registry
          3. Caller holds the tool's declared Permission

    .PARAMETER User
        The verified AuthenticatedUser from the auth middleware.
    .PARAMETER ToolName
        The name of the tool to invoke.
    .PARAMETER Params
        Hashtable of tool parameters from the MCP request.
    .OUTPUTS
        hashtable — the tool's result payload
    #>
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [AuthenticatedUser] $User,

        [Parameter(Mandatory)]
        [string] $ToolName,

        [hashtable] $Params = @{}
    )

    # Check 1: authenticated
    if ($null -eq $User) {
        return @{ error = 'authentication_required'; message = 'Authentication required.' }
    }

    # Check 2: tool exists
    $tool = $script:ToolRegistry | Where-Object { $_.Name -eq $ToolName } | Select-Object -First 1
    if ($null -eq $tool) {
        return @{ error = 'tool_not_found'; message = "Tool '$ToolName' does not exist." }
    }

    # Check 3: permission
    if (-not (Test-UserHasPermission -User $User -Required $tool.Permission)) {
        Write-Host "[AUTHZ] DENIED  user=$($User.Id)  role=$($User.Role)  tool=$ToolName  required=$($tool.Permission)" -ForegroundColor Yellow
        return @{ error = 'insufficient_permissions'; message = "Insufficient permissions to call '$ToolName'." }
    }

    Write-Host "[AUTHZ] ALLOWED  user=$($User.Id)  role=$($User.Role)  tool=$ToolName" -ForegroundColor Green

    # Execute
    try {
        $result = & $tool.Handler $User $Params
        return $result
    }
    catch {
        Write-Host "[TOOL ERROR] $ToolName : $($_.Exception.Message)" -ForegroundColor Red
        return @{ error = 'tool_execution_error'; message = 'An error occurred executing the tool.' }
    }
}

# ---------------------------------------------------------------------------
# MCP request dispatcher
# Parses the JSON-RPC-style MCP request body and routes to the right handler
# ---------------------------------------------------------------------------

function Invoke-McpToolDispatcher {
    <#
    .SYNOPSIS
        Parses an MCP JSON-RPC request and dispatches to the correct tool.

    .PARAMETER Context
        The System.Net.HttpListenerContext for the inbound request.
    .PARAMETER User
        The verified AuthenticatedUser attached by the auth middleware.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Net.HttpListenerContext] $Context,

        [Parameter(Mandatory)]
        [AuthenticatedUser] $User
    )

    $request  = $Context.Request
    $response = $Context.Response

    # Read and parse request body
    $reader  = [System.IO.StreamReader]::new($request.InputStream)
    $bodyRaw = $reader.ReadToEnd()
    $body    = $bodyRaw | ConvertFrom-Json -AsHashtable

    $method = $body.method ?? ''
    $params = $body.params ?? @{}
    $id     = $body.id     ?? [System.Guid]::NewGuid().ToString()

    $result = switch ($method) {
        'tools/list' {
            $allowed = Get-AllowedTools -User $User
            @{
                jsonrpc = '2.0'
                id      = $id
                result  = @{
                    tools = @($allowed | ForEach-Object {
                        @{ name = $_.Name; description = $_.Description }
                    })
                }
            }
        }
        'tools/call' {
            $toolName  = $params.name ?? ''
            $toolInput = $params.arguments ?? @{}
            $toolResult = Invoke-McpTool -User $User -ToolName $toolName -Params $toolInput
            @{
                jsonrpc = '2.0'
                id      = $id
                result  = $toolResult
            }
        }
        default {
            @{
                jsonrpc = '2.0'
                id      = $id
                error   = @{ code = -32601; message = "Method '$method' not found." }
            }
        }
    }

    $responseBytes = ($result | ConvertTo-Json -Depth 10 -Compress)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($responseBytes)
    $response.ContentType       = 'application/json'
    $response.ContentLength64   = $bytes.Length
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
    $response.OutputStream.Close()
}

# ---------------------------------------------------------------------------
# Smoke test
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    Write-Host "=== Per-Tool Permission Enforcement smoke test ===" -ForegroundColor Cyan

    # Admin user — should reach all tools
    $admin = New-AuthenticatedUser -Id 'u-admin' -Role ([UserRole]::Admin)
    $adminTools = Get-AllowedTools -User $admin
    Write-Host "Admin visible tools   : $($adminTools.Name -join ', ')"

    # Read-only user — should only see list_todos
    $readonly = New-AuthenticatedUser -Id 'u-readonly' -Role ([UserRole]::ReadOnly)
    $roTools  = Get-AllowedTools -User $readonly
    Write-Host "ReadOnly visible tools: $($roTools.Name -join ', ')"

    # Attempt delete as read-only
    $deleteResult = Invoke-McpTool -User $readonly -ToolName 'delete_todo' -Params @{ id = '42' }
    Write-Host "ReadOnly delete attempt: $($deleteResult.error)  (expected: insufficient_permissions)"

    # Admin delete — should succeed
    $adminDeleteResult = Invoke-McpTool -User $admin -ToolName 'delete_todo' -Params @{ id = '42' }
    Write-Host "Admin delete result   : deleted=$($adminDeleteResult.deleted)  (expected: True)"
}
