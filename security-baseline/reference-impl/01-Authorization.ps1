#Requires -Version 7.0
<#
.SYNOPSIS
    MCP Server Security - Step 1: Role and Permission Definitions
    Translated from Microsoft Azure-Samples/mcp-container-ts (TypeScript)

.DESCRIPTION
    Defines UserRole and Permission enumerations and a role-to-permission map
    that forms the foundation of RBAC for a secured MCP server.

    Design principles:
    - Roles and permissions are enums (not magic strings) — typos become errors
    - Admin inherits all permissions automatically via the map
    - AuthenticatedUser is the single source of truth for caller identity
    - Adding a new Permission value automatically grants it to Admin

.NOTES
    Source: §18 of mcp-security-considerations.md
    Reference: https://github.com/Azure-Samples/mcp-container-ts
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Enumerations
# ---------------------------------------------------------------------------

enum UserRole {
    Admin    = 0
    User     = 1
    ReadOnly = 2
}

enum Permission {
    CreateTodos = 0
    ReadTodos   = 1
    UpdateTodos = 2
    DeleteTodos = 3
    ListTools   = 4
}

# ---------------------------------------------------------------------------
# Authenticated user type
# Represents the verified identity attached to every inbound request.
# ---------------------------------------------------------------------------

class AuthenticatedUser {
    [string]     $Id
    [UserRole]   $Role
    [Permission[]] $Permissions

    AuthenticatedUser([string]$id, [UserRole]$role, [Permission[]]$permissions) {
        $this.Id          = $id
        $this.Role        = $role
        $this.Permissions = $permissions
    }
}

# ---------------------------------------------------------------------------
# Role-to-permission map
# Admin gets all permissions. Adding a new Permission value here automatically
# grants it to Admin without any other changes required.
# ---------------------------------------------------------------------------

$script:RolePermissions = @{
    [UserRole]::Admin    = [Permission].GetEnumValues()    # all permissions
    [UserRole]::User     = @(
        [Permission]::CreateTodos,
        [Permission]::ReadTodos,
        [Permission]::UpdateTodos,
        [Permission]::ListTools
    )
    [UserRole]::ReadOnly = @(
        [Permission]::ReadTodos,
        [Permission]::ListTools
    )
}

# ---------------------------------------------------------------------------
# Public helpers
# ---------------------------------------------------------------------------

function Get-PermissionsForRole {
    <#
    .SYNOPSIS
        Returns the default permission set for a given role.
    .PARAMETER Role
        A UserRole enum value.
    .OUTPUTS
        Permission[]
    #>
    [OutputType([Permission[]])]
    param(
        [Parameter(Mandatory)]
        [UserRole] $Role
    )

    return $script:RolePermissions[$Role]
}

function Test-UserHasPermission {
    <#
    .SYNOPSIS
        Returns $true if the authenticated user holds the specified permission.
    .PARAMETER User
        An AuthenticatedUser object (attached to the request by the auth middleware).
    .PARAMETER Required
        The Permission the caller must hold.
    .OUTPUTS
        bool
    #>
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AuthenticatedUser] $User,

        [Parameter(Mandatory)]
        [Permission] $Required
    )

    return $User.Permissions -contains $Required
}

function New-AuthenticatedUser {
    <#
    .SYNOPSIS
        Constructs an AuthenticatedUser with the default permissions for the role.
    .PARAMETER Id
        The user's unique identifier (from the verified token payload).
    .PARAMETER Role
        The user's role.
    .OUTPUTS
        AuthenticatedUser
    #>
    [OutputType([AuthenticatedUser])]
    param(
        [Parameter(Mandatory)]
        [string] $Id,

        [Parameter(Mandatory)]
        [UserRole] $Role
    )

    $permissions = Get-PermissionsForRole -Role $Role
    return [AuthenticatedUser]::new($Id, $Role, $permissions)
}

# ---------------------------------------------------------------------------
# Quick smoke test — run directly to verify enums load correctly
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    Write-Host "=== Authorization module loaded ===" -ForegroundColor Cyan
    Write-Host "Roles    : $([UserRole].GetEnumNames() -join ', ')"
    Write-Host "Permissions: $([Permission].GetEnumNames() -join ', ')"

    $adminUser    = New-AuthenticatedUser -Id 'u001' -Role ([UserRole]::Admin)
    $readonlyUser = New-AuthenticatedUser -Id 'u002' -Role ([UserRole]::ReadOnly)

    Write-Host "`nAdmin permissions   : $($adminUser.Permissions -join ', ')"
    Write-Host "ReadOnly permissions: $($readonlyUser.Permissions -join ', ')"

    $canDelete = Test-UserHasPermission -User $readonlyUser -Required ([Permission]::DeleteTodos)
    Write-Host "`nReadOnly can DeleteTodos: $canDelete  (expected: False)"
}
