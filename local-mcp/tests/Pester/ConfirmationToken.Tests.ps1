# Version: 0.2.0
# Pester 5 tests for the confirmation-token HMAC helper.
# Covers tamper, expiry, and item-set rebinding. Replay defence is not yet implemented
# in code (Phase 2 work) — see [[plan-phase-2-replay-store]].

#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    $script:LibPath = Join-Path $PSScriptRoot '..\..\src\Lib\New-ConfirmationToken.ps1'
    . $script:LibPath

    # Redirect HMAC key file to a temp path so the suite never touches the user's real key.
    $script:TempKey = Join-Path ([System.IO.Path]::GetTempPath()) ("mcp-test-hmac-{0}.bin" -f ([Guid]::NewGuid().ToString('N')))

    # Override Get-HmacKey to use the temp path.
    function Get-HmacKey {
        param([string]$KeyPath = $script:TempKey)
        if (-not (Test-Path $KeyPath)) {
            $bytes = New-Object byte[] 32
            [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
            [System.IO.File]::WriteAllBytes($KeyPath, $bytes)
            return $bytes
        }
        return [System.IO.File]::ReadAllBytes($KeyPath)
    }
}

AfterAll {
    if (Test-Path $script:TempKey) { Remove-Item -Force $script:TempKey }
}

Describe 'New-ConfirmationToken / Test-ConfirmationToken' {

    It 'round-trips a valid token' {
        $ids = @('AAAA','BBBB','CCCC')
        $t = New-ConfirmationToken -Tool 'archive_move_to_primary' -ItemIds $ids -DestinationFolder 'folder-1'
        $r = Test-ConfirmationToken -Token $t.Token -ExpectedTool 'archive_move_to_primary' -ItemIds $ids -ExpectedDestination 'folder-1'
        $r.Valid | Should -BeTrue
    }

    It 'rejects a tampered signature' {
        $t = New-ConfirmationToken -Tool 'archive_move_to_primary' -ItemIds @('A','B') -DestinationFolder 'f'
        $parts = $t.Token -split '\.'
        $sigBytes = [Convert]::FromBase64String($parts[1])
        $sigBytes[0] = $sigBytes[0] -bxor 0xFF
        $tampered = ('{0}.{1}' -f $parts[0], [Convert]::ToBase64String($sigBytes))
        { Test-ConfirmationToken -Token $tampered -ExpectedTool 'archive_move_to_primary' -ItemIds @('A','B') -ExpectedDestination 'f' } | Should -Throw '*signature invalid*'
    }

    It 'rejects an expired token' {
        $t = New-ConfirmationToken -Tool 'archive_copy_to_primary' -ItemIds @('X') -DestinationFolder 'f' -TtlSeconds 1
        Start-Sleep -Seconds 2
        { Test-ConfirmationToken -Token $t.Token -ExpectedTool 'archive_copy_to_primary' -ItemIds @('X') -ExpectedDestination 'f' } | Should -Throw '*expired*'
    }

    It 'rejects a different item set than the one signed' {
        $t = New-ConfirmationToken -Tool 'archive_restore_item' -ItemIds @('A','B','C') -DestinationFolder 'f'
        { Test-ConfirmationToken -Token $t.Token -ExpectedTool 'archive_restore_item' -ItemIds @('A','B','D') -ExpectedDestination 'f' } | Should -Throw '*item-set mismatch*'
    }

    It 'rejects a tool-name mismatch' {
        $t = New-ConfirmationToken -Tool 'archive_copy_to_primary' -ItemIds @('A') -DestinationFolder 'f'
        { Test-ConfirmationToken -Token $t.Token -ExpectedTool 'archive_move_to_primary' -ItemIds @('A') -ExpectedDestination 'f' } | Should -Throw '*tool mismatch*'
    }

    It 'rejects a destination mismatch' {
        $t = New-ConfirmationToken -Tool 'archive_restore_item' -ItemIds @('A') -DestinationFolder 'inbox'
        { Test-ConfirmationToken -Token $t.Token -ExpectedTool 'archive_restore_item' -ItemIds @('A') -ExpectedDestination 'other' } | Should -Throw '*destination mismatch*'
    }
}
