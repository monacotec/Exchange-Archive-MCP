# Version: 0.2.1
# Recursive walk of the Online Archive subtree, rooted at archivemsgfolderroot
# via Get-ArchiveRoot (Lib/). 0.2.1: root fixed from the primary-mailbox Archive
# folder to the In-Place Archive; traversal itself is unchanged.

Set-StrictMode -Version Latest

function Get-ChildFoldersRecursive {
    param(
        [Parameter(Mandatory)]$Folder,
        [int]$Depth,
        [int]$MaxDepth
    )
    $node = [ordered]@{
        id                = $Folder.id
        displayName       = $Folder.displayName
        totalItemCount    = $Folder.totalItemCount
        childFolderCount  = $Folder.childFolderCount
        children          = @()
    }
    if ($Depth -ge $MaxDepth -or $Folder.childFolderCount -eq 0) { return $node }
    $childUri = "https://graph.microsoft.com/v1.0/me/mailFolders/$($Folder.id)/childFolders?`$top=100&includeHiddenFolders=true"
    $resp = Invoke-McpGraph -Uri $childUri
    foreach ($c in $resp.Value.value) {
        $node.children += (Get-ChildFoldersRecursive -Folder $c -Depth ($Depth+1) -MaxDepth $MaxDepth)
    }
    return $node
}

function Invoke-ListArchiveFolders {
    param(
        [Parameter(Mandatory)]$Ctx,
        [int]$MaxDepth = 4
    )
    $archive = Get-ArchiveRoot
    return (Get-ChildFoldersRecursive -Folder $archive -Depth 0 -MaxDepth $MaxDepth)
}
