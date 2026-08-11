# Version: 0.4.0
# 0.4.0: primary-mailbox counterpart added (Get-PrimaryRoot /
#        Get-PrimaryFolderList via the msgfolderroot well-known name) so
#        archive_search can span both stores; BFS flattener factored into a
#        shared Get-MailFolderList helper. Archive behavior unchanged.
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
$script:PrimaryRootCache    = $null
$script:ArchiveFolderSelect = '$select=id,displayName,totalItemCount,unreadItemCount,childFolderCount'
# Safety ceiling on the fan-out folder enumeration (per store).
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

function Get-PrimaryRoot {
    # Top of Information Store of the PRIMARY mailbox (msgfolderroot), for
    # searches that span both stores. Session-cached like the archive root.
    [CmdletBinding()]
    param([switch]$Refresh)

    if (-not $Refresh -and $null -ne $script:PrimaryRootCache) {
        return $script:PrimaryRootCache
    }
    $resp = Invoke-McpGraph -Uri "https://graph.microsoft.com/v1.0/me/mailFolders/msgfolderroot?$script:ArchiveFolderSelect"
    if (-not $resp.Value) {
        throw 'Primary mailbox root (msgfolderroot) could not be resolved via Graph.'
    }
    $script:PrimaryRootCache = $resp.Value
    return $resp.Value
}

function Get-MailFolderList {
    # Flatten every folder under a given root (BFS), root included. Message
    # queries ($search / $filter) only see the single folder they target, so
    # fan-out tools need this full id list. Folders with zero messages are
    # skipped by default -- they cannot contribute results; -IncludeEmpty overrides.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Root,
        [switch]$IncludeEmpty
    )

    $folders = [System.Collections.Generic.List[object]]::new()
    $queue   = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue($Root)
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

function Get-ArchiveFolderList {
    [CmdletBinding()]
    param([switch]$IncludeEmpty)
    return Get-MailFolderList -Root (Get-ArchiveRoot) -IncludeEmpty:$IncludeEmpty
}

function Get-PrimaryFolderList {
    [CmdletBinding()]
    param([switch]$IncludeEmpty)
    return Get-MailFolderList -Root (Get-PrimaryRoot) -IncludeEmpty:$IncludeEmpty
}
