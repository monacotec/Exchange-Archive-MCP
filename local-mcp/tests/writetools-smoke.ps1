Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\src\Lib\New-ConfirmationToken.ps1')
. (Join-Path $PSScriptRoot '..\src\Lib\Test-ReplayGuard.ps1')

# Stubs in place of Graph + folder resolver.
$script:GraphCalls = @()
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
. (Join-Path $PSScriptRoot '..\src\Lib\Invoke-WriteOp.ps1')

$pass = 0; $fail = 0
function Ok($name)   { $script:pass++; Write-Host "  PASS  $name" }
function Bad($name,$why) { $script:fail++; Write-Host "  FAIL  $name -- $why" }
function Check($name, [scriptblock]$cond) {
    try { if (& $cond) { Ok $name } else { Bad $name 'condition false' } }
    catch { Bad $name "threw: $($_.Exception.Message)" }
}
function CheckThrows($name, [scriptblock]$action, [string]$match) {
    $threw = $false; $msg = ''
    try { & $action | Out-Null } catch { $threw = $true; $msg = $_.Exception.Message }
    if ($threw -and $msg -like "*$match*") { Ok $name }
    else { Bad $name "threw=$threw msg='$msg'" }
}
function Reset { $script:GraphCalls = @(); Reset-ReplayGuard }

Write-Host '=== Preview shape ==='
Reset
$p = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
    -Mode 'preview' -ItemIds @('AAA','BBB') -DestinationFolder 'Inbox/Restored'
Check 'preview mode tag'         { $p.mode -eq 'preview' }
Check 'preview item_count'       { $p.item_count -eq 2 }
Check 'preview dest path'        { $p.destination_folder -eq 'Inbox/Restored' }
Check 'preview dest id resolved' { $p.destination_folder_id -eq 'folder-id-Inbox-Restored' }
Check 'preview token id format'  { $p.confirmation_token_id -match '^ct_' }
Check 'preview not bulk'         { -not $p.requires_human_review }

Reset
$bulkIds = 1..120 | ForEach-Object { "ID-$_" }
$pb = Invoke-WriteOp -ToolName 'archive_copy_to_primary' -GraphAction 'copy' `
    -Mode 'preview' -ItemIds $bulkIds -DestinationFolder 'Inbox/Bulk'
Check 'bulk preview flags review'    { $pb.requires_human_review }
Check 'bulk preview note mentions ack' { $pb.note -match 'acknowledged_bulk' }

Write-Host '=== HMAC integrity ==='
Reset
$p = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
    -Mode 'preview' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored'
$parts = $p.confirmation_token -split '\.'
$pb = [Convert]::FromBase64String($parts[0])
$pb[0] = $pb[0] -bxor 0x01
$tamperedPayload = [Convert]::ToBase64String($pb) + '.' + $parts[1]
CheckThrows 'tampered payload rejected' {
    Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
        -Mode 'execute' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored' `
        -ConfirmationToken $tamperedPayload -DryRun:$false
} 'signature invalid'

$sb = [Convert]::FromBase64String($parts[1])
$sb[0] = $sb[0] -bxor 0x01
$tamperedSig = $parts[0] + '.' + [Convert]::ToBase64String($sb)
CheckThrows 'tampered signature rejected' {
    Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
        -Mode 'execute' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored' `
        -ConfirmationToken $tamperedSig -DryRun:$false
} 'signature invalid'

Write-Host '=== Cross-binding integrity ==='
Reset
$tok = New-ConfirmationToken -Tool 'archive_copy_to_primary' `
    -ItemIds @('A','B') -DestinationFolder 'folder-id-Inbox-Restored'
CheckThrows 'tool mismatch rejected' {
    Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
        -Mode 'execute' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored' `
        -ConfirmationToken $tok.Token -DryRun:$false
} 'tool mismatch'

Reset
$tok = New-ConfirmationToken -Tool 'archive_move_to_primary' `
    -ItemIds @('A','B') -DestinationFolder 'folder-id-Inbox-Other'
CheckThrows 'destination mismatch rejected' {
    Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
        -Mode 'execute' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored' `
        -ConfirmationToken $tok.Token -DryRun:$false
} 'destination mismatch'

Reset
$p = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
    -Mode 'preview' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored'
CheckThrows 'item-set mismatch rejected' {
    Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
        -Mode 'execute' -ItemIds @('A','C') -DestinationFolder 'Inbox/Restored' `
        -ConfirmationToken $p.confirmation_token -DryRun:$false
} 'item-set mismatch'

Write-Host '=== TTL expiry ==='
Reset
$tok = New-ConfirmationToken -Tool 'archive_move_to_primary' `
    -ItemIds @('A','B') -DestinationFolder 'folder-id-Inbox-Restored' -TtlSeconds -10
CheckThrows 'expired token rejected' {
    Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
        -Mode 'execute' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored' `
        -ConfirmationToken $tok.Token -DryRun:$false
} 'expired'

Write-Host '=== Replay protection ==='
Reset
$p = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
    -Mode 'preview' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored'
$first = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
    -Mode 'execute' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored' `
    -ConfirmationToken $p.confirmation_token -DryRun:$false
Check 'first execute performed' { $first.performed }
CheckThrows 'replay rejected' {
    Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
        -Mode 'execute' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored' `
        -ConfirmationToken $p.confirmation_token -DryRun:$false
} 'already been consumed'

Write-Host '=== Bulk acknowledgement ==='
Reset
$ids = 1..150 | ForEach-Object { "ID-$_" }
$p = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
    -Mode 'preview' -ItemIds $ids -DestinationFolder 'Inbox/Bulk'
CheckThrows 'bulk without ack refused' {
    Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
        -Mode 'execute' -ItemIds $ids -DestinationFolder 'Inbox/Bulk' `
        -ConfirmationToken $p.confirmation_token -DryRun:$false
} 'acknowledged_bulk'

Reset
$p = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
    -Mode 'preview' -ItemIds $ids -DestinationFolder 'Inbox/Bulk'
$rb = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
    -Mode 'execute' -ItemIds $ids -DestinationFolder 'Inbox/Bulk' `
    -ConfirmationToken $p.confirmation_token -DryRun:$false -AcknowledgedBulk:$true
Check 'bulk with ack performed' { $rb.performed -and $rb.succeeded_count -eq 150 }

Write-Host '=== dry_run default ==='
Reset
$p = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
    -Mode 'preview' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored'
$rdry = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
    -Mode 'execute' -ItemIds @('A','B') -DestinationFolder 'Inbox/Restored' `
    -ConfirmationToken $p.confirmation_token -DryRun:$true
Check 'dry_run yields no Graph calls' { $script:GraphCalls.Count -eq 0 }
Check 'dry_run result performed=false' { -not $rdry.performed -and $rdry.dry_run }

Reset
$p = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
    -Mode 'preview' -ItemIds @('A','B','C') -DestinationFolder 'Inbox/Restored'
$rlive = Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
    -Mode 'execute' -ItemIds @('A','B','C') -DestinationFolder 'Inbox/Restored' `
    -ConfirmationToken $p.confirmation_token -DryRun:$false
Check 'live execute Graph call count' { $script:GraphCalls.Count -eq 3 }
Check 'live execute POST method' { $script:GraphCalls[0].Method -eq 'POST' }
Check 'live execute URI shape' { $script:GraphCalls[0].Uri -match '/me/messages/[ABC]/move$' }

Write-Host ''
Write-Host "RESULT: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
