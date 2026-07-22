# Version: 0.2.0
# Delegated Graph connection via Microsoft.Graph.Authentication (Connect-MgGraph).
# Replaces the rev-1 MSAL.PS-based Get-DelegatedToken.ps1. See CHANGES.md §1.
#
# The SDK manages its own MSAL.NET token cache at
#   %LOCALAPPDATA%\Microsoft\Graph\TokenCache\
# DPAPI-protected under CurrentUser scope. We do not handle raw tokens here —
# Invoke-MgGraphRequest in Lib/Invoke-McpGraph.ps1 picks them up automatically.

Set-StrictMode -Version Latest

function Ensure-McpGraphConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$TenantId,
        [string[]]$Scopes = @('Mail.Read','User.Read','offline_access'),
        [switch]$ForceInteractive
    )

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw 'Microsoft.Graph.Authentication module is not installed. Run: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    $ctx = $null
    try { $ctx = Get-MgContext } catch { $ctx = $null }

    # If we have a context with the right tenant and a superset of required scopes, reuse it.
    if (-not $ForceInteractive -and $ctx -and $ctx.TenantId -eq $TenantId) {
        $missing = $Scopes | Where-Object { $ctx.Scopes -notcontains $_ }
        if (-not $missing) { return $ctx }
    }

    if ($ForceInteractive) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }

    $connectParams = @{
        ClientId  = $ClientId
        TenantId  = $TenantId
        Scopes    = $Scopes
        NoWelcome = $true
    }

    # Connect-MgGraph attempts silent (cache hit) first under the hood; falls back to
    # interactive only when no TTY is unavailable it errors — caller handles that.
    Connect-MgGraph @connectParams -ErrorAction Stop | Out-Null
    return (Get-MgContext)
}

function Disconnect-McpGraph {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}
