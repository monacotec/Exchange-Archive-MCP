<#
.SYNOPSIS
    Exchange Online Archive (In-Place Archive) Graph query functions for the
    Exchange Archive MCP Azure Function.

.DESCRIPTION
    Replaces the folder-resolution logic that was incorrectly targeting the
    primary mailbox well-known folder 'archive' (the one-click Archive button
    folder). All queries here are rooted at 'archivemsgfolderroot', which is
    the top of the Online Archive mailbox.

    Functions:
      - Invoke-GraphRequest            (paging + 429 retry helper)
      - Get-ArchiveFolderHierarchy     (recursive folder tree)
      - Get-ArchiveFolderIdList        (flat list of all archive folder ids)
      - Get-ArchiveMailByDateRange     (per-folder $filter fan-out, aggregated)
      - Search-ArchiveMail             (per-folder $search fan-out, aggregated)

.NOTES
    Version : 1.0.0
    Runtime : PowerShell 7.x (Azure Functions). No PS5.1-only syntax used,
              but avoids ternaries/null-coalescing so it remains 5.1-portable
              for local stdio testing.
    Auth    : Caller supplies a delegated OBO access token (Mail.Read).
    ASCII   : All output and source is ASCII-only.
#>

Set-StrictMode -Version Latest

$script:GraphBase = 'https://graph.microsoft.com/v1.0'

# Well-known folder name for the Online Archive root. Do NOT use 'archive' --
# that is the primary mailbox Archive folder and was the source of the bug.
$script:ArchiveRoot = 'archivemsgfolderroot'

function Invoke-GraphRequest {
    <#
    .SYNOPSIS
        Calls Graph with paging (@odata.nextLink) and 429/503 retry support.
    .OUTPUTS
        Array of items from the 'value' property across all pages, or the raw
        object for non-collection responses.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$AccessToken,
        [int]$MaxItems = 0,          # 0 = no cap
        [int]$MaxRetries = 4
    )

    $headers = @{
        Authorization = "Bearer $AccessToken"
        Accept        = 'application/json'
    }

    $items   = New-Object System.Collections.Generic.List[object]
    $nextUri = $Uri

    while ($nextUri) {
        $attempt = 0
        $response = $null
        while ($true) {
            try {
                $response = Invoke-RestMethod -Method Get -Uri $nextUri -Headers $headers -ErrorAction Stop
                break
            }
            catch {
                $statusCode = 0
                if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                }
                $attempt++
                if (($statusCode -eq 429 -or $statusCode -eq 503) -and $attempt -le $MaxRetries) {
                    $retryAfter = 5
                    try {
                        $ra = $_.Exception.Response.Headers.GetValues('Retry-After')
                        if ($ra) { $retryAfter = [int]($ra | Select-Object -First 1) }
                    } catch { }
                    Write-Information ("Graph throttled ({0}); retry {1}/{2} in {3}s" -f $statusCode, $attempt, $MaxRetries, $retryAfter)
                    Start-Sleep -Seconds $retryAfter
                    continue
                }
                throw
            }
        }

        # Non-collection response (single entity) - return as-is
        if ($null -eq ($response.PSObject.Properties['value'])) {
            return $response
        }

        foreach ($item in $response.value) {
            $items.Add($item)
            if ($MaxItems -gt 0 -and $items.Count -ge $MaxItems) {
                return $items.ToArray()
            }
        }

        $nextUri = $null
        if ($response.PSObject.Properties['@odata.nextLink']) {
            $nextUri = $response.'@odata.nextLink'
        }
    }

    return $items.ToArray()
}

function Get-ArchiveFolderHierarchy {
    <#
    .SYNOPSIS
        Returns the Online Archive folder tree rooted at archivemsgfolderroot.
    .PARAMETER MaxDepth
        Recursion depth (1-5). Depth 1 = immediate children of the root.
    .OUTPUTS
        PSCustomObject hierarchy matching the MCP list_archive_folders shape.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [ValidateRange(1, 5)][int]$MaxDepth = 3
    )

    $select = '$select=id,displayName,totalItemCount,unreadItemCount,childFolderCount'

    # Root metadata
    $rootUri = "{0}/me/mailFolders/{1}?{2}" -f $script:GraphBase, $script:ArchiveRoot, $select
    $root    = Invoke-GraphRequest -Uri $rootUri -AccessToken $AccessToken

    function Get-ChildTree {
        param([string]$FolderId, [int]$Depth)

        if ($Depth -gt $MaxDepth) { return @() }

        $uri = "{0}/me/mailFolders/{1}/childFolders?{2}&`$top=100" -f $script:GraphBase, $FolderId, $select
        $children = @(Invoke-GraphRequest -Uri $uri -AccessToken $AccessToken)

        $result = @()
        foreach ($child in $children) {
            $node = [PSCustomObject]@{
                id            = $child.id
                display_name  = $child.displayName
                message_count = $child.totalItemCount
                unread_count  = $child.unreadItemCount
                child_folders = @()
            }
            if ($child.childFolderCount -gt 0) {
                $node.child_folders = @(Get-ChildTree -FolderId $child.id -Depth ($Depth + 1))
            }
            $result += $node
        }
        return $result
    }

    $tree = [PSCustomObject]@{
        id            = $root.id
        display_name  = 'Online Archive'
        message_count = $root.totalItemCount
        unread_count  = $root.unreadItemCount
        child_folders = @(Get-ChildTree -FolderId $script:ArchiveRoot -Depth 1)
    }

    # Total = root loose items + all descendant counts
    $total = [int]$root.totalItemCount
    $stack = New-Object System.Collections.Stack
    foreach ($c in $tree.child_folders) { $stack.Push($c) }
    while ($stack.Count -gt 0) {
        $n = $stack.Pop()
        $total += [int]$n.message_count
        foreach ($c in $n.child_folders) { $stack.Push($c) }
    }

    return [PSCustomObject]@{
        hierarchy          = $tree
        total_messages     = $total
        max_depth_traversed = $MaxDepth
    }
}

function Get-ArchiveFolderIdList {
    <#
    .SYNOPSIS
        Flat list of every folder id under the Online Archive root (plus the
        root itself), used for query fan-out. Skips empty folders.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [switch]$IncludeEmpty
    )

    $select  = '$select=id,displayName,totalItemCount,childFolderCount'
    $folders = New-Object System.Collections.Generic.List[object]

    $rootUri = "{0}/me/mailFolders/{1}?{2}" -f $script:GraphBase, $script:ArchiveRoot, $select
    $root    = Invoke-GraphRequest -Uri $rootUri -AccessToken $AccessToken
    $folders.Add([PSCustomObject]@{ id = $root.id; displayName = 'Online Archive (root)'; totalItemCount = $root.totalItemCount })

    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($root.id)

    while ($queue.Count -gt 0) {
        $parentId = $queue.Dequeue()
        $uri = "{0}/me/mailFolders/{1}/childFolders?{2}&`$top=100" -f $script:GraphBase, $parentId, $select
        $children = @(Invoke-GraphRequest -Uri $uri -AccessToken $AccessToken)
        foreach ($child in $children) {
            $folders.Add([PSCustomObject]@{ id = $child.id; displayName = $child.displayName; totalItemCount = $child.totalItemCount })
            if ($child.childFolderCount -gt 0) { $queue.Enqueue($child.id) }
        }
    }

    if ($IncludeEmpty) { return $folders.ToArray() }
    return @($folders | Where-Object { $_.totalItemCount -gt 0 })
}

function Get-ArchiveMailByDateRange {
    <#
    .SYNOPSIS
        Retrieves messages across ALL Online Archive folders within a date range.
    .DESCRIPTION
        Fans out a $filter query to every non-empty folder under
        archivemsgfolderroot, aggregates, sorts newest-first, and truncates to Top.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][datetime]$StartDate,
        [Parameter(Mandatory)][datetime]$EndDate,
        [ValidateRange(1, 100)][int]$Top = 50
    )

    $startIso = $StartDate.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $endIso   = $EndDate.Date.AddDays(1).AddSeconds(-1).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $filter   = "receivedDateTime ge $startIso and receivedDateTime le $endIso"
    $select   = 'id,subject,from,receivedDateTime,bodyPreview,hasAttachments,parentFolderId'

    $folders  = Get-ArchiveFolderIdList -AccessToken $AccessToken
    $all      = New-Object System.Collections.Generic.List[object]

    foreach ($folder in $folders) {
        $uri = "{0}/me/mailFolders/{1}/messages?`$filter={2}&`$select={3}&`$orderby=receivedDateTime desc&`$top=50" -f `
            $script:GraphBase, $folder.id, [uri]::EscapeDataString($filter), $select

        # Per-folder cap of Top: no single folder needs more than the final cap
        $messages = @(Invoke-GraphRequest -Uri $uri -AccessToken $AccessToken -MaxItems $Top)
        foreach ($m in $messages) {
            $fromAddr = ''
            $fromName = ''
            if ($m.from -and $m.from.emailAddress) {
                $fromAddr = $m.from.emailAddress.address
                $fromName = $m.from.emailAddress.name
            }
            $all.Add([PSCustomObject]@{
                id          = $m.id
                subject     = $m.subject
                from        = $fromAddr
                from_name   = $fromName
                received    = $m.receivedDateTime
                preview     = $m.bodyPreview
                attachments = [bool]$m.hasAttachments
                folder      = $folder.displayName
            })
        }
    }

    $sorted    = @($all | Sort-Object -Property received -Descending)
    $truncated = ($sorted.Count -gt $Top)
    $result    = @($sorted | Select-Object -First $Top)

    return [PSCustomObject]@{
        filter    = $filter
        count     = $result.Count
        truncated = $truncated
        messages  = $result
    }
}

function Search-ArchiveMail {
    <#
    .SYNOPSIS
        KQL-style $search across ALL Online Archive folders.
    .DESCRIPTION
        Graph $search against /me/messages only covers the primary mailbox, so
        this fans out folder-scoped $search calls under archivemsgfolderroot.
        Note: $search does not support $orderby or $filter in the same call;
        results are relevance-ranked per folder, then merged newest-first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)][string]$Query,
        [ValidateRange(1, 50)][int]$Top = 20
    )

    # Escape embedded double quotes for the $search parameter
    $safeQuery = $Query.Replace('"', '\"')
    $select    = 'id,subject,from,receivedDateTime,bodyPreview,hasAttachments,parentFolderId'

    $folders = Get-ArchiveFolderIdList -AccessToken $AccessToken
    $all     = New-Object System.Collections.Generic.List[object]
    $seen    = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($folder in $folders) {
        $uri = '{0}/me/mailFolders/{1}/messages?$search="{2}"&$select={3}&$top=25' -f `
            $script:GraphBase, $folder.id, [uri]::EscapeDataString($safeQuery), $select

        $messages = @()
        try {
            $messages = @(Invoke-GraphRequest -Uri $uri -AccessToken $AccessToken -MaxItems $Top)
        }
        catch {
            # Some special folders reject $search; log and continue
            Write-Information ("Search skipped folder '{0}': {1}" -f $folder.displayName, $_.Exception.Message)
            continue
        }

        foreach ($m in $messages) {
            if (-not $seen.Add($m.id)) { continue }
            $fromAddr = ''
            $fromName = ''
            if ($m.from -and $m.from.emailAddress) {
                $fromAddr = $m.from.emailAddress.address
                $fromName = $m.from.emailAddress.name
            }
            $all.Add([PSCustomObject]@{
                id          = $m.id
                subject     = $m.subject
                from        = $fromAddr
                from_name   = $fromName
                received    = $m.receivedDateTime
                preview     = $m.bodyPreview
                attachments = [bool]$m.hasAttachments
                folder      = $folder.displayName
            })
        }
    }

    $result = @($all | Sort-Object -Property received -Descending | Select-Object -First $Top)

    return [PSCustomObject]@{
        query    = $Query
        count    = $result.Count
        messages = $result
    }
}
