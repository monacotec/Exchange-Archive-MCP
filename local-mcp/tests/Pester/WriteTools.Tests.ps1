# Version: 0.1.0
# Phase 2 write-tool contract tests.
# Covers:
#   - HMAC tamper (flip a byte in payload -> rejected)
#   - HMAC tamper (flip a byte in signature -> rejected)
#   - TTL expiry (advance clock past expiry -> rejected)
#   - Replay (same token consumed twice -> second rejected)
#   - Bulk acknowledgement (count > threshold without ack -> refused)
#   - Item-set binding (different item set -> rejected)
#   - Destination binding (different folder ID -> rejected)
#   - dry_run default (mode=execute dry_run=true -> no Graph call)

#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\src\Lib\New-ConfirmationToken.ps1')
    . (Join-Path $PSScriptRoot '..\..\src\Lib\Test-ReplayGuard.ps1')

    # Stub the Graph and folder-resolution helpers so we can exercise Invoke-WriteOp
    # without a live Connect-MgGraph session.
    function Invoke-McpGraph {
        param($Uri, $Method = 'GET', $Body, $ExtraHeaders, $MaxAttempts = 5, $InitialDelayMs = 1000)
        $script:GraphCalls += [PSCustomObject]@{ Uri = $Uri; Method = $Method; Body = $Body }
        return [PSCustomObject]@{ Value = [PSCustomObject]@{ value = @() }; RequestId = 'stub' }
    }
    function Resolve-MailFolder {
        param([string]$Path, [int]$MaxDepth = 8)
        return [PSCustomObject]@{
            Id           = 'folder-id-' + ($Path -replace '[\\/]', '-')
            DisplayName  = ($Path -split '[\\/]')[-1]
            ResolvedPath = $Path
        }
    }
    . (Join-Path $PSScriptRoot '..\..\src\Lib\Invoke-WriteOp.ps1')
}

Describe 'Write tools - two-step confirm contract' {

    BeforeEach {
        $script:GraphCalls = @()
        Reset-ReplayGuard
    }

    Context 'Preview shape' {
        It 'returns a confirmation token and surfaces resolved destination ID' {
            $r = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
                -Mode 'preview' -ItemIds @('AAA','BBB') -DestinationFolder 'Inbox/Restored'
            $r.mode                  | Should -Be 'preview'
            $r.item_count            | Should -Be 2
            $r.destination_folder    | Should -Be 'Inbox/Restored'
            $r.destination_folder_id | Should -Be 'folder-id-Inbox-Restored'
            $r.confirmation_token    | Should -Not -BeNullOrEmpty
            $r.confirmation_token_id | Should -Match '^ct_'
            $r.requires_human_review | Should -BeFalse
        }

        It 'flags requires_human_review when item count exceeds bulk threshold' {
            $ids = 1..120 | ForEach-Object { "ID-$_" }
            $r = Invoke-WriteOp -ToolName 'archive_copy_to_primary' -GraphAction 'copy' `
                -Mode 'preview' -ItemIds $ids -DestinationFolder 'Inbox/Bulk'
            $r.requires_human_review | Should -BeTrue
            $r.note                  | Should -Match 'acknowledged_bulk'
        }
    }

    Context 'Execute - HMAC integrity' {
        It 'rejects a token whose payload was tampered (single byte flip)' {
            $preview = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
                -Mode 'preview' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored'
            $parts = $preview.confirmation_token -split '\.'
            $payloadBytes = [Convert]::FromBase64String($parts[0])
            $payloadBytes[0] = $payloadBytes[0] -bxor 0x01
            $tampered = [Convert]::ToBase64String($payloadBytes) + '.' + $parts[1]

            { Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
                -Mode 'execute' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored' `
                -ConfirmationToken $tampered -DryRun:$false
            } | Should -Throw -ExpectedMessage '*signature invalid*'
        }

        It 'rejects a token whose signature segment was tampered' {
            $preview = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
                -Mode 'preview' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored'
            $parts = $preview.confirmation_token -split '\.'
            $sigBytes = [Convert]::FromBase64String($parts[1])
            $sigBytes[0] = $sigBytes[0] -bxor 0x01
            $tampered = $parts[0] + '.' + [Convert]::ToBase64String($sigBytes)

            { Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
                -Mode 'execute' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored' `
                -ConfirmationToken $tampered -DryRun:$false
            } | Should -Throw -ExpectedMessage '*signature invalid*'
        }
    }

    Context 'Execute - cross-binding integrity' {
        It 'rejects a token minted for a different tool name' {
            $tok = New-ConfirmationToken -Tool 'archive_copy_to_primary' `
                -ItemIds @('A','B') -DestinationFolder 'folder-id-Inbox-Restored'
            { Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
                -Mode 'execute' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored' `
                -ConfirmationToken $tok.Token -DryRun:$false
            } | Should -Throw -ExpectedMessage '*tool mismatch*'
        }

        It 'rejects a token minted for a different destination folder' {
            $tok = New-ConfirmationToken -Tool 'archive_move_to_primary' `
                -ItemIds @('A','B') -DestinationFolder 'folder-id-Inbox-Other'
            { Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
                -Mode 'execute' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored' `
                -ConfirmationToken $tok.Token -DryRun:$false
            } | Should -Throw -ExpectedMessage '*destination mismatch*'
        }

        It 'rejects a token minted for a different item set' {
            $preview = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
                -Mode 'preview' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored'
            { Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
                -Mode 'execute' -ItemIds @('A','C') -DestinationFolder 'Inbox/Restored' `
                -ConfirmationToken $preview.confirmation_token -DryRun:$false
            } | Should -Throw -ExpectedMessage '*item-set mismatch*'
        }
    }

    Context 'Execute - TTL expiry' {
        It 'rejects a token whose expires_at is in the past' {
            $tok = New-ConfirmationToken -Tool 'archive_move_to_primary' `
                -ItemIds @('A','B') -DestinationFolder 'folder-id-Inbox-Restored' `
                -TtlSeconds -10
            { Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
                -Mode 'execute' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored' `
                -ConfirmationToken $tok.Token -DryRun:$false
            } | Should -Throw -ExpectedMessage '*expired*'
        }
    }

    Context 'Execute - replay protection' {
        It 'consumes a token on first execute and rejects the second use' {
            $preview = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
                -Mode 'preview' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored'

            $first = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
                -Mode 'execute' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored' `
                -ConfirmationToken $preview.confirmation_token -DryRun:$false
            $first.performed | Should -BeTrue

            { Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
                -Mode 'execute' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored' `
                -ConfirmationToken $preview.confirmation_token -DryRun:$false
            } | Should -Throw -ExpectedMessage '*already been consumed*'
        }
    }

    Context 'Execute - bulk acknowledgement' {
        It 'refuses execute when count > threshold and acknowledged_bulk is false' {
            $ids = 1..150 | ForEach-Object { "ID-$_" }
            $preview = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
                -Mode 'preview' -ItemIds $ids -DestinationFolder 'Inbox/Bulk'
            { Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
                -Mode 'execute' -ItemIds $ids -DestinationFolder 'Inbox/Bulk' `
                -ConfirmationToken $preview.confirmation_token -DryRun:$false
            } | Should -Throw -ExpectedMessage '*acknowledged_bulk*'
        }

        It 'proceeds when count > threshold and acknowledged_bulk is true' {
            $ids = 1..150 | ForEach-Object { "ID-$_" }
            $preview = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
                -Mode 'preview' -ItemIds $ids -DestinationFolder 'Inbox/Bulk'
            $r = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
                -Mode 'execute' -ItemIds $ids -DestinationFolder 'Inbox/Bulk' `
                -ConfirmationToken $preview.confirmation_token -DryRun:$false `
                -AcknowledgedBulk:$true
            $r.performed       | Should -BeTrue
            $r.succeeded_count | Should -Be 150
        }
    }

    Context 'Execute - dry_run default' {
        It "does not call Graph when dry_run is true (the default)" {
            $preview = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
                -Mode 'preview' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored'
            $r = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
                -Mode 'execute' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored' `
                -ConfirmationToken $preview.confirmation_token -DryRun:$true
            $r.performed       | Should -BeFalse
            $r.dry_run         | Should -BeTrue
            $script:GraphCalls.Count | Should -Be 0
        }

        It 'calls Graph once per item when dry_run is false' {
            $preview = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
                -Mode 'preview' -ItemIds @('A','B','C') -DestinationFolder 'Inbox/Restored'
            $r = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
                -Mode 'execute' -ItemIds @('A','B','C') -DestinationFolder 'Inbox/Restored' `
                -ConfirmationToken $preview.confirmation_token -DryRun:$false
            $r.performed             | Should -BeTrue
            $r.succeeded_count       | Should -Be 3
            $script:GraphCalls.Count | Should -Be 3
            $script:GraphCalls[0].Method | Should -Be 'POST'
            $script:GraphCalls[0].Uri    | Should -Match '/me/messages/[ABC]/move$'
        }
    }
}
