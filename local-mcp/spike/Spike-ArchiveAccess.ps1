<#
.SYNOPSIS
    Phase 0 spike for exchange-archive-local (rev 2).

.DESCRIPTION
    Acquires a delegated Microsoft Graph token via the supported
    Microsoft.Graph.Authentication module, enumerates the signed-in
    user's archive mailbox folder tree, and prints a summary.

    No MCP plumbing, no writes — pure validation that the auth model and
    hidden-folder traversal work on a real GI Partners mailbox.

    Success criteria:
      1. Interactive sign-in completes on first run.
      2. SECOND RUN is silent (no browser) — confirms the token cache.
      3. /me/mailFolders returns at least one folder where
         wellKnownName eq 'archive' OR displayName eq 'Archive'
         when ?includeHiddenFolders=true is passed.
      4. Recursive walk returns >= 1 child folder OR an item count.

.NOTES
    File:    Spike-ArchiveAccess.ps1
    Version: 0.2.0
    Phase:   0
    Requires: PowerShell 7+, Microsoft.Graph.Authentication module
#>

#Requires -Version 7.0

[CmdletBinding()]
param(
    # The GI Partners app registration for the Exchange Archive MCP.
    # Default is the Microsoft Graph Command Line Tools well-known client ID,
    # which is fine for the spike but MUST be replaced before Phase 1.
    [Parameter()]
    [string]$ClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e',

    [Parameter()]
    [string]$TenantId = 'common',

    [Parameter()]
    [string[]]$Scopes = @('Mail.Read', 'User.Read', 'offline_access'),

    [Parameter()]
    [int]$MaxDepth = 4,

    # Force a fresh interactive sign-in. Useful for testing the first-run path
    # after deleting the cache. Without this, the second run should be silent.
    [Parameter()]
    [switch]$ForceInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Prereqs
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Host '[setup] Installing Microsoft.Graph.Authentication for current user...' -ForegroundColor Yellow
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force
}
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

Write-Host "[setup] Module version: $((Get-Module Microsoft.Graph.Authentication).Version)" -ForegroundColor DarkGray
#endregion

#region Auth
$connectParams = @{
    ClientId  = $ClientId
    TenantId  = $TenantId
    Scopes    = $Scopes
    NoWelcome = $true
}

if ($ForceInteractive) {
    Write-Host '[auth] -ForceInteractive set; clearing existing session before sign-in.' -ForegroundColor Yellow
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}

Write-Host '[auth] Connecting to Microsoft Graph...' -ForegroundColor Cyan
$connectStart = Get-Date
Connect-MgGraph @connectParams | Out-Null
$connectMs = [int]((Get-Date) - $connectStart).TotalMilliseconds

$ctx = Get-MgContext
Write-Host "[auth] Signed in as: $($ctx.Account)" -ForegroundColor Green
Write-Host "[auth] Tenant:       $($ctx.TenantId)"
Write-Host "[auth] Scopes:       $($ctx.Scopes -join ', ')"
Write-Host "[auth] Auth type:    $($ctx.AuthType)"
Write-Host "[auth] Connect time: ${connectMs}ms  $(if ($connectMs -lt 1000) {'(silent — cache hit)'} else {'(interactive — first run or expired)'})"
Write-Host ''
#endregion

#region Graph helper
function Invoke-McpGraphGet {
    param([Parameter(Mandatory)][string]$Uri)
    $headers = @{
        'client-request-id' = [Guid]::NewGuid().ToString()
        'Prefer'            = 'IdType="ImmutableId"'
    }
    Invoke-MgGraphRequest -Method GET -Uri $Uri -Headers $headers -ErrorAction Stop
}
#endregion

#region Locate the archive root
Write-Host '[discover] Querying mail folders (includeHiddenFolders=true)...' -ForegroundColor Cyan
$foldersUri = 'v1.0/me/mailFolders?$top=100&includeHiddenFolders=true'
$root = Invoke-McpGraphGet -Uri $foldersUri

$archive = $root.value | Where-Object {
    $_.displayName -eq 'Archive' -or
    ($_.PSObject.Properties.Match('wellKnownName').Count -gt 0 -and $_.wellKnownName -eq 'archive')
} | Select-Object -First 1

if (-not $archive) {
    Write-Host '[discover] No top-level Archive folder found in primary mailbox.' -ForegroundColor Yellow
    Write-Host '[discover] Note: online archive may surface as a separate mailbox endpoint.' -ForegroundColor Yellow
    Write-Host '[discover] Folders seen:'
    $root.value | Select-Object displayName, totalItemCount, childFolderCount | Format-Table
    return
}

Write-Host "[discover] Found archive root: $($archive.displayName) (id: $($archive.id))" -ForegroundColor Green
Write-Host "[discover] Item count: $($archive.totalItemCount), child folders: $($archive.childFolderCount)"
Write-Host ''
#endregion

#region Recursive walk
function Walk-Folder {
    param(
        [Parameter(Mandatory)]$Folder,
        [int]$Depth = 0,
        [int]$MaxDepth
    )

    $indent = '  ' * $Depth
    Write-Host ("{0}- {1}  [items: {2}, subfolders: {3}]" -f `
        $indent, $Folder.displayName, $Folder.totalItemCount, $Folder.childFolderCount)

    if ($Depth -ge $MaxDepth) {
        if ($Folder.childFolderCount -gt 0) {
            Write-Host ("{0}  ... (max depth reached)" -f $indent) -ForegroundColor DarkGray
        }
        return
    }

    if ($Folder.childFolderCount -gt 0) {
        $childUri = "v1.0/me/mailFolders/$($Folder.id)/childFolders?`$top=100&includeHiddenFolders=true"
        $children = Invoke-McpGraphGet -Uri $childUri
        foreach ($child in $children.value) {
            Walk-Folder -Folder $child -Depth ($Depth + 1) -MaxDepth $MaxDepth
        }
    }
}

Write-Host '[walk] Archive folder tree:' -ForegroundColor Cyan
Walk-Folder -Folder $archive -Depth 0 -MaxDepth $MaxDepth
#endregion

#region Sample item read
Write-Host ''
Write-Host '[sample] Fetching 3 most recent items from archive root...' -ForegroundColor Cyan
$msgUri = "v1.0/me/mailFolders/$($archive.id)/messages?`$top=3&`$select=subject,from,receivedDateTime,hasAttachments&`$orderby=receivedDateTime desc"
$messages = Invoke-McpGraphGet -Uri $msgUri

if ($messages.value.Count -eq 0) {
    Write-Host '[sample] Archive root has no items at top level (children may have them).' -ForegroundColor Yellow
} else {
    $messages.value | ForEach-Object {
        [PSCustomObject]@{
            Received    = $_.receivedDateTime
            From        = $_.from.emailAddress.address
            Subject     = ($_.subject.Substring(0, [Math]::Min(60, $_.subject.Length)))
            Attachments = $_.hasAttachments
        }
    } | Format-Table -AutoSize
}
#endregion

#region Spike acceptance check
Write-Host ''
Write-Host '[spike-check] Phase 0 exit criteria:' -ForegroundColor Cyan
Write-Host '  [x] Sign-in completed (interactive or silent)'
Write-Host "  [$(if ($connectMs -lt 1000) {'x'} else {' '})] Second run is silent  (this run: ${connectMs}ms; run again to verify cache works)"
Write-Host '  [x] Archive folder found and walked'
Write-Host '  [x] Sample item read'
Write-Host ''
Write-Host '[done] Spike complete.' -ForegroundColor Green
Write-Host '       If you saw the archive tree and the second-run check passes, Phase 1 is unblocked.' -ForegroundColor Green
Write-Host ''
Write-Host '[next] (1) Run again to confirm cache (should show "silent — cache hit").' -ForegroundColor DarkGray
Write-Host '       (2) Replace -ClientId default with the GI Partners app reg before Phase 1.' -ForegroundColor DarkGray
Write-Host '       (3) Run docs/audit-verification.md check against this mailbox.' -ForegroundColor DarkGray
#endregion
