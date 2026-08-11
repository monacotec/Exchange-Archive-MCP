# Version: 0.4.0
# 0.4.0: -Scope archive|primary|both -- fan the same per-folder $search across
#        the primary mailbox tree (msgfolderroot) as well as the Online
#        Archive; every result now carries a 'store' field next to 'folder'.
#        Default stays 'archive' (tool contract unchanged unless asked).
# 0.3.0: Online Archive fix -- a single $search against the archive root only
#        sees root-level items (~none at Top of Information Store). Enumerate
#        every folder under archivemsgfolderroot (Get-ArchiveFolderList) and fan
#        out a per-folder $search, then merge/sort/dedupe client-side ($search
#        cannot combine with $filter/$orderby). Folders that reject $search are
#        skipped, not fatal. Each result gains a 'folder' field.
# 0.2.2: Graph $search URL encoding -- EscapeDataString percent-encodes the KQL
#        operator characters (':', '>=', '<=') which Graph then refuses with 400.
#        Restore those four chars raw after encoding. Quotes (%22) stay encoded.
# 0.2.1: defensive against zero-hit queries (StrictMode-safe @() wrap) and
#        against messages missing the from.emailAddress chain (system mail).

Set-StrictMode -Version Latest

function ConvertTo-GraphSearchValue {
    # Encode a KQL string for use as the value of Graph's $search query parameter.
    # EscapeDataString is too aggressive: it percent-encodes the KQL operator chars
    # (':', '>', '<', '=') that Graph requires raw to parse field operators and
    # date comparisons. Restore those after encoding, while leaving genuinely
    # URL-unsafe chars (quotes, &, #, ?, space, non-ASCII) properly escaped.
    param([Parameter(Mandatory)][string]$Kql)
    $encoded = [System.Uri]::EscapeDataString($Kql)
    return $encoded.
        Replace('%3A', ':').
        Replace('%3E', '>').
        Replace('%3C', '<').
        Replace('%3D', '=')
}

function Invoke-SearchArchive {
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][string]$Query,
        [int]$MaxResults = 50,
        [ValidateSet('archive', 'primary', 'both')][string]$Scope = 'archive'
    )
    $kql     = ConvertTo-KqlQuery -Query $Query
    $encoded = ConvertTo-GraphSearchValue -Kql $kql
    $selectClause = '$select=id,subject,from,toRecipients,receivedDateTime,hasAttachments,parentFolderId,bodyPreview'
    $perFolderTop = [Math]::Min($MaxResults, 100)

    $folders = @()
    if ($Scope -in @('archive', 'both')) {
        $folders += @(Get-ArchiveFolderList | ForEach-Object {
            [PSCustomObject]@{ Id = $_.Id; DisplayName = $_.DisplayName; Store = 'archive' }
        })
    }
    if ($Scope -in @('primary', 'both')) {
        $folders += @(Get-PrimaryFolderList | ForEach-Object {
            [PSCustomObject]@{ Id = $_.Id; DisplayName = $_.DisplayName; Store = 'primary' }
        })
    }
    $merged  = [System.Collections.Generic.List[object]]::new()
    $seen    = [System.Collections.Generic.HashSet[string]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()
    foreach ($folder in $folders) {
        $base = "https://graph.microsoft.com/v1.0/me/mailFolders/$($folder.Id)/messages"
        $uri  = "$base`?`$search=$encoded&$selectClause&`$top=$perFolderTop"
        try {
            $paged = Invoke-McpGraphPaged -Uri $uri -MaxItems $perFolderTop
        } catch {
            # Some special folders reject $search; one bad folder must not sink
            # the whole call.
            [void]$skipped.Add("$($folder.Store)/$($folder.DisplayName)")
            continue
        }
        foreach ($m in $paged.Items) {
            if (-not $seen.Add([string]$m.id)) { continue }
            $fromAddress = $null
            if ($m.PSObject.Properties.Match('from').Count -gt 0 -and $m.from) {
                if ($m.from.PSObject.Properties.Match('emailAddress').Count -gt 0 -and $m.from.emailAddress) {
                    $fromAddress = $m.from.emailAddress.address
                }
            }
            [void]$merged.Add([PSCustomObject]@{
                id              = $m.id
                subject         = $m.subject
                from            = $fromAddress
                received        = $m.receivedDateTime
                hasAttachments  = $m.hasAttachments
                parentFolderId  = $m.parentFolderId
                store           = $folder.Store
                folder          = $folder.DisplayName
                preview         = $m.bodyPreview
            })
        }
    }
    # $search results arrive unordered across folders; sort newest-first here.
    $sorted  = @($merged | Sort-Object -Property received -Descending)
    $results = @($sorted | Select-Object -First $MaxResults)
    return [PSCustomObject]@{
        query            = $Query
        kql              = $kql
        scope            = $Scope
        count            = $results.Count
        truncated        = ($sorted.Count -gt $MaxResults)
        folders_searched = $folders.Count
        folders_skipped  = $skipped.ToArray()
        results          = $results
    }
}
