# Version: 0.2.1
# 0.2.1: Get-ArchiveRoot now resolves the In-Place (Online) Archive root; totals
# here therefore reflect the real archive, not the primary Archive folder. The
# root's own totalItemCount covers only items sitting directly at Top of
# Information Store (~0); the child traversal below supplies the real totals.

Set-StrictMode -Version Latest

function Invoke-GetArchiveStats {
    param([Parameter(Mandatory)]$Ctx)
    $archive = Get-ArchiveRoot
    $totalItems   = [int]$archive.totalItemCount
    $totalFolders = 1
    $stack = New-Object System.Collections.Stack
    $stack.Push($archive)
    while ($stack.Count -gt 0) {
        $f = $stack.Pop()
        if ($f.childFolderCount -gt 0) {
            $resp = Invoke-McpGraph -Uri "https://graph.microsoft.com/v1.0/me/mailFolders/$($f.id)/childFolders?`$top=100&includeHiddenFolders=true"
            foreach ($c in $resp.Value.value) {
                $totalItems   += [int]$c.totalItemCount
                $totalFolders += 1
                $stack.Push($c)
            }
        }
    }

    $usage = $null
    try {
        $resp = Invoke-McpGraph -Uri 'https://graph.microsoft.com/v1.0/me/mailboxSettings'
        $usage = $resp.Value
    } catch { }

    return [PSCustomObject]@{
        archiveFolderId    = $archive.id
        archiveItemCount   = $totalItems
        archiveFolderCount = $totalFolders
        mailboxSettings    = $usage
    }
}
