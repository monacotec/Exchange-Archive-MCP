# Version: 0.1.0
# Online Archive root resolution + search fan-out contract tests.
# Covers (see exchange-archive-mcp-online-archive-fix.md):
#   - Get-ArchiveRoot resolves archivemsgfolderroot, never displayName 'Archive'
#   - archiveroot fallback on ErrorItemNotFound; other Graph errors rethrown
#   - session cache (+ -Refresh)
#   - Get-ArchiveFolderList BFS flatten, empty-folder skip, -IncludeEmpty
#   - Invoke-SearchArchive per-folder fan-out: merge, dedupe by id, newest-first
#     sort, per-message 'folder' field, tolerance of folders rejecting $search,
#     MaxResults truncation
#   - negative: the primary-mailbox Archive folder id never queried

#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    # Stub the Graph transport before dot-sourcing so no live session is needed.
    # Each test points $script:GraphHandler / $script:GraphPagedHandler at a
    # scriptblock that fabricates responses keyed on the request URI.
    function Invoke-McpGraph {
        param([string]$Uri, [string]$Method = 'GET', $Body, $ExtraHeaders, [int]$MaxAttempts = 5, [int]$InitialDelayMs = 1000)
        $script:GraphCalls += $Uri
        return (& $script:GraphHandler $Uri)
    }
    function Invoke-McpGraphPaged {
        param([string]$Uri, [int]$MaxItems = 10000)
        $script:GraphCalls += $Uri
        return (& $script:GraphPagedHandler $Uri)
    }

    . (Join-Path $PSScriptRoot '..\..\src\Lib\ConvertTo-KqlQuery.ps1')
    . (Join-Path $PSScriptRoot '..\..\src\Lib\Get-ArchiveRoot.ps1')
    . (Join-Path $PSScriptRoot '..\..\src\Tools\Search-Archive.ps1')

    function New-StubFolder {
        param([string]$Id, [string]$Name, [int]$Items, [int]$Children)
        [PSCustomObject]@{
            id = $Id; displayName = $Name
            totalItemCount = $Items; unreadItemCount = 0; childFolderCount = $Children
        }
    }
    function New-StubMessage {
        param([string]$Id, [string]$Received, [string]$Subject = 'subj')
        [PSCustomObject]@{
            id = $Id; subject = $Subject
            from = [PSCustomObject]@{ emailAddress = [PSCustomObject]@{ address = 'sender@x.com'; name = 'Sender' } }
            receivedDateTime = $Received
            hasAttachments = $false; parentFolderId = 'pf-' + $Id; bodyPreview = 'preview'
        }
    }
    function New-GraphValue { param($Obj) [PSCustomObject]@{ Value = $Obj; RequestId = 'stub' } }
    function New-GraphPage  { param($Items) [PSCustomObject]@{ Items = @($Items); Truncated = $false; NextLink = $null } }

    # Briefing §7: the primary-mailbox Archive-button folder id. Must never appear.
    $script:PrimaryArchiveFolderId = 'AAMkAGI1NjNkMTUzLTkyMmMtNDliMC1iNjZjLTU0Njc1ZTk2MTcxOAAuAAAAAAB9FPlyDXUwQInaeF1jLtb3AQBiwv40ZdttQaPCXtEU8YCCAAAAAA03AAA='
}

Describe 'Get-ArchiveRoot - Online Archive root resolution' {

    BeforeEach {
        $script:GraphCalls        = @()
        $script:ArchiveRootCache  = $null
        $script:GraphHandler      = { param($Uri) throw "Unexpected Graph call: $Uri" }
        $script:GraphPagedHandler = { param($Uri) throw "Unexpected paged Graph call: $Uri" }
    }

    It 'resolves via the archivemsgfolderroot well-known name (not displayName matching)' {
        $script:GraphHandler = { param($Uri)
            if ($Uri -match 'mailFolders/archivemsgfolderroot\?') {
                return (New-GraphValue (New-StubFolder -Id 'oa-root' -Name 'Top of Information Store' -Items 0 -Children 3))
            }
            throw "Unexpected Graph call: $Uri"
        }
        $root = Get-ArchiveRoot
        $root.id | Should -Be 'oa-root'
        $script:GraphCalls.Count | Should -Be 1
        $script:GraphCalls[0] | Should -Match 'archivemsgfolderroot'
        # The old hidden-folder displayName traversal must be gone.
        @($script:GraphCalls | Where-Object { $_ -match 'includeHiddenFolders' }).Count | Should -Be 0
    }

    It 'falls back to archiveroot when archivemsgfolderroot returns ErrorItemNotFound' {
        $script:GraphHandler = { param($Uri)
            if ($Uri -match 'archivemsgfolderroot') {
                throw [System.Exception]::new("Graph GET $Uri failed (status=404): ErrorItemNotFound - The specified object was not found in the store.")
            }
            if ($Uri -match 'mailFolders/archiveroot\?') {
                return (New-GraphValue (New-StubFolder -Id 'oa-archiveroot' -Name 'Archive Root' -Items 0 -Children 1))
            }
            throw "Unexpected Graph call: $Uri"
        }
        $root = Get-ArchiveRoot
        $root.id | Should -Be 'oa-archiveroot'
        $script:GraphCalls.Count | Should -Be 2
        $script:GraphCalls[1] | Should -Match 'mailFolders/archiveroot\?'
    }

    It 'rethrows Graph errors other than ErrorItemNotFound without trying the fallback' {
        $script:GraphHandler = { param($Uri)
            throw [System.Exception]::new("Graph GET $Uri failed (status=403): ErrorAccessDenied.")
        }
        { Get-ArchiveRoot } | Should -Throw '*ErrorAccessDenied*'
        $script:GraphCalls.Count | Should -Be 1
    }

    It 'caches the root for the session and re-queries only with -Refresh' {
        $script:GraphHandler = { param($Uri)
            return (New-GraphValue (New-StubFolder -Id 'oa-root' -Name 'TOIS' -Items 0 -Children 0))
        }
        [void](Get-ArchiveRoot)
        [void](Get-ArchiveRoot)
        $script:GraphCalls.Count | Should -Be 1
        [void](Get-ArchiveRoot -Refresh)
        $script:GraphCalls.Count | Should -Be 2
    }
}

Describe 'Get-ArchiveFolderList - BFS flatten of the archive subtree' {

    BeforeEach {
        $script:GraphCalls       = @()
        $script:ArchiveRootCache = $null
        # Tree: root(0) -> Inbox(759, 1 child), Empty(0) ; Inbox -> Sub(5)
        $script:GraphHandler = { param($Uri)
            if ($Uri -match 'archivemsgfolderroot') {
                return (New-GraphValue (New-StubFolder -Id 'oa-root' -Name 'TOIS' -Items 0 -Children 2))
            }
            throw "Unexpected Graph call: $Uri"
        }
        $script:GraphPagedHandler = { param($Uri)
            if ($Uri -match 'mailFolders/oa-root/childFolders') {
                return (New-GraphPage @(
                    (New-StubFolder -Id 'f-inbox' -Name 'Inbox' -Items 759 -Children 1),
                    (New-StubFolder -Id 'f-empty' -Name 'Empty' -Items 0 -Children 0)
                ))
            }
            if ($Uri -match 'mailFolders/f-inbox/childFolders') {
                return (New-GraphPage @((New-StubFolder -Id 'f-sub' -Name 'Sub' -Items 5 -Children 0)))
            }
            throw "Unexpected paged Graph call: $Uri"
        }
    }

    It 'flattens all folders and skips empty ones by default' {
        $list = @(Get-ArchiveFolderList)
        @($list).DisplayName | Should -Be @('Inbox', 'Sub')
        @($list).Id          | Should -Be @('f-inbox', 'f-sub')
    }

    It 'includes the root and empty folders with -IncludeEmpty' {
        $list = @(Get-ArchiveFolderList -IncludeEmpty)
        $list.Count | Should -Be 4
        @($list).Id | Should -Contain 'oa-root'
        @($list).Id | Should -Contain 'f-empty'
    }

    It 'falls back to the full list when every folder reports zero messages' {
        $script:GraphHandler = { param($Uri)
            return (New-GraphValue (New-StubFolder -Id 'oa-root' -Name 'TOIS' -Items 0 -Children 0))
        }
        $list = @(Get-ArchiveFolderList)
        $list.Count  | Should -Be 1
        $list[0].Id  | Should -Be 'oa-root'
    }
}

Describe 'Invoke-SearchArchive - per-folder $search fan-out' {

    BeforeEach {
        $script:GraphCalls       = @()
        $script:ArchiveRootCache = $null
        $script:Ctx = [PSCustomObject]@{}
        # Archive: FolderA(2), FolderB(2, shares one message id with A), FolderC(1, rejects $search)
        $script:GraphHandler = { param($Uri)
            if ($Uri -match 'archivemsgfolderroot') {
                return (New-GraphValue (New-StubFolder -Id 'oa-root' -Name 'TOIS' -Items 0 -Children 3))
            }
            throw "Unexpected Graph call: $Uri"
        }
        $script:GraphPagedHandler = { param($Uri)
            if ($Uri -match 'mailFolders/oa-root/childFolders') {
                return (New-GraphPage @(
                    (New-StubFolder -Id 'f-a' -Name 'FolderA' -Items 2 -Children 0),
                    (New-StubFolder -Id 'f-b' -Name 'FolderB' -Items 2 -Children 0),
                    (New-StubFolder -Id 'f-c' -Name 'FolderC' -Items 1 -Children 0)
                ))
            }
            if ($Uri -match 'mailFolders/f-a/messages') {
                return (New-GraphPage @(
                    (New-StubMessage -Id 'm-old'  -Received '2022-04-20T10:00:00Z' -Subject 'payroll'),
                    (New-StubMessage -Id 'm-dupe' -Received '2023-01-01T00:00:00Z')
                ))
            }
            if ($Uri -match 'mailFolders/f-b/messages') {
                return (New-GraphPage @(
                    (New-StubMessage -Id 'm-dupe'  -Received '2023-01-01T00:00:00Z'),
                    (New-StubMessage -Id 'm-older' -Received '2021-06-06T00:00:00Z')
                ))
            }
            if ($Uri -match 'mailFolders/f-c/messages') {
                throw [System.Exception]::new('Graph GET failed (status=400): SearchNotAllowed for this folder.')
            }
            throw "Unexpected paged Graph call: $Uri"
        }
    }

    It 'fans out across all folders, dedupes by id, sorts newest-first, and tags each hit with its folder' {
        $r = Invoke-SearchArchive -Ctx $script:Ctx -Query 'payroll'
        $r.count            | Should -Be 3
        $r.folders_searched | Should -Be 3
        @($r.results).id     | Should -Be @('m-dupe', 'm-old', 'm-older')
        @($r.results).folder | Should -Be @('FolderA', 'FolderA', 'FolderB')
        $r.truncated | Should -BeFalse
    }

    It 'skips folders that reject $search instead of failing the whole call' {
        $r = Invoke-SearchArchive -Ctx $script:Ctx -Query 'payroll'
        @($r.folders_skipped) | Should -Be @('FolderC')
        $r.count | Should -Be 3
    }

    It 'truncates to MaxResults and flags truncation' {
        $r = Invoke-SearchArchive -Ctx $script:Ctx -Query 'payroll' -MaxResults 2
        $r.count     | Should -Be 2
        $r.truncated | Should -BeTrue
        @($r.results).id | Should -Be @('m-dupe', 'm-old')
    }

    It 'never issues a query against the primary-mailbox Archive folder id' {
        [void](Invoke-SearchArchive -Ctx $script:Ctx -Query 'payroll')
        @($script:GraphCalls | Where-Object { $_ -like "*$script:PrimaryArchiveFolderId*" }).Count | Should -Be 0
        # Every message query must target a folder id that came from the archive enumeration.
        $msgCalls = @($script:GraphCalls | Where-Object { $_ -match '/messages\?' })
        $msgCalls.Count | Should -Be 3
        foreach ($c in $msgCalls) { $c | Should -Match 'mailFolders/f-[abc]/messages' }
    }
}
