# Version: 0.3.0
# Resolve the In-Place (Online) Archive root via the archivemsgfolderroot
# well-known folder name. Do NOT match displayName 'Archive' or wellKnownName
# 'archive' -- both identify the Archive-button folder INSIDE the primary
# mailbox, which was the 2026-07-21 defect (all read tools silently read the
# wrong mailbox; see exchange-archive-mcp-online-archive-fix.md).
# Falls back to 'archiveroot' (one level above Top of Information Store) when
# archivemsgfolderroot is not addressable (ErrorItemNotFound).
# Used by every read tool to resolve the archive subtree once per session.

Set-StrictMode -Version Latest

$script:ArchiveRootCache    = $null
$script:ArchiveFolderSelect = '$select=id,displayName,totalItemCount,unreadItemCount,childFolderCount'
# Safety ceiling on the fan-out folder enumeration.
$script:ArchiveMaxFolders   = 500

function Get-ArchiveRoot {
    [CmdletBinding()]
    param([switch]$Refresh)

    if (-not $Refresh -and $null -ne $script:ArchiveRootCache) {
        return $script:ArchiveRootCache
    }
    $base = 'https://graph.microsoft.com/v1.0/me/mailFolders'
    try {
        $resp = Invoke-McpGraph -Uri "$base/archivemsgfolderroot?$script:ArchiveFolderSelect"
    } catch {
        if ($_.Exception.Message -notmatch 'ErrorItemNotFound') { throw }
        # Archive not addressable as msgfolderroot; resolve one level up instead.
        $resp = Invoke-McpGraph -Uri "$base/archiveroot?$script:ArchiveFolderSelect"
    }
    if (-not $resp.Value) {
        throw 'Online Archive root could not be resolved via Graph (in-place archive may not be provisioned for this mailbox).'
    }
    $script:ArchiveRootCache = $resp.Value
    return $resp.Value
}

function Get-ArchiveFolderList {
    # Flatten every folder under the Online Archive root (BFS), root included.
    # Message queries ($search / $filter) only see the single folder they target,
    # so fan-out tools need this full id list. Folders with zero messages are
    # skipped by default -- they cannot contribute results; -IncludeEmpty overrides.
    [CmdletBinding()]
    param([switch]$IncludeEmpty)

    $root    = Get-ArchiveRoot
    $folders = [System.Collections.Generic.List[object]]::new()
    $queue   = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue($root)
    while ($queue.Count -gt 0 -and $folders.Count -lt $script:ArchiveMaxFolders) {
        $f = $queue.Dequeue()
        [void]$folders.Add([PSCustomObject]@{
            Id           = $f.id
            DisplayName  = $f.displayName
            MessageCount = [int]$f.totalItemCount
        })
        if ([int]$f.childFolderCount -gt 0) {
            $uri = "https://graph.microsoft.com/v1.0/me/mailFolders/$($f.id)/childFolders?includeHiddenFolders=true&`$top=100&$script:ArchiveFolderSelect"
            $page = Invoke-McpGraphPaged -Uri $uri -MaxItems $script:ArchiveMaxFolders
            foreach ($c in $page.Items) { $queue.Enqueue($c) }
        }
    }
    if ($IncludeEmpty) { return $folders.ToArray() }
    $nonEmpty = @($folders | Where-Object { $_.MessageCount -gt 0 })
    if ($nonEmpty.Count -gt 0) { return $nonEmpty }
    return $folders.ToArray()
}
