# Version: 0.1.0
# Resolve a primary-mailbox folder path (e.g. "Inbox/Restored") to a Graph folder ID.
#
# Walks /me/mailFolders top-level, then descends childFolders by displayName,
# matching case-insensitively. Returns the resolved folder object (id +
# displayName + childFolderCount). Throws if any segment fails to resolve --
# write tools must refuse to create folders implicitly.

Set-StrictMode -Version Latest

function Resolve-MailFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxDepth = 8
    )
    if (-not $Path) { throw 'Destination folder path is empty.' }

    $segments = $Path -split '[\\/]+' | Where-Object { $_ -ne '' }
    if ($segments.Count -lt 1) { throw "Destination folder path '$Path' is empty after normalisation." }
    if ($segments.Count -gt $MaxDepth) {
        throw "Destination folder path '$Path' exceeds maximum depth of $MaxDepth."
    }

    # Top-level folders (primary mailbox; no includeHiddenFolders so we cannot
    # accidentally target Archive or RecoverableItems).
    $topUri = 'https://graph.microsoft.com/v1.0/me/mailFolders?$top=100'
    $top    = (Invoke-McpGraph -Uri $topUri).Value.value
    $cursor = $top | Where-Object { $_.displayName -ieq $segments[0] } | Select-Object -First 1
    if (-not $cursor) {
        throw "Top-level mail folder '$($segments[0])' not found in primary mailbox."
    }

    for ($i = 1; $i -lt $segments.Count; $i++) {
        $seg = $segments[$i]
        $childUri = "https://graph.microsoft.com/v1.0/me/mailFolders/$($cursor.id)/childFolders?`$top=100"
        $children = (Invoke-McpGraph -Uri $childUri).Value.value
        $next = $children | Where-Object { $_.displayName -ieq $seg } | Select-Object -First 1
        if (-not $next) {
            throw "Child folder '$seg' not found under '$($cursor.displayName)' (full path: '$Path')."
        }
        $cursor = $next
    }

    return [PSCustomObject]@{
        Id            = $cursor.id
        DisplayName   = $cursor.displayName
        ResolvedPath  = ($segments -join '/')
    }
}
