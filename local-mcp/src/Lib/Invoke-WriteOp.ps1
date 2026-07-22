# Version: 0.1.0
# Shared engine for archive_restore_item / archive_copy_to_primary / archive_move_to_primary.
#
# Behaviour:
#   mode=preview
#     - Validate item_ids and resolve destination folder (Graph lookup).
#     - Return a summary plus a confirmation_token bound to (tool, item-id set, dest folder ID).
#     - requires_human_review=true when item count exceeds the bulk threshold.
#     - No mutation; safe to call repeatedly.
#   mode=execute
#     - Validate the confirmation_token's HMAC, expiry, tool, item set, dest folder ID.
#     - Reject replays via the in-memory used-token guard.
#     - If count exceeds bulk threshold, require acknowledged_bulk=true.
#     - If dry_run=true (the default), report intent and stop without calling Graph.
#     - Otherwise POST /me/messages/{id}/move or /copy per item and report results.
#
# The HMAC binding to the resolved folder ID (not the display string) closes a
# rename TOCTOU between preview and execute.

Set-StrictMode -Version Latest

# Constants -- mirrored from appsettings.writeTools but kept here so the engine
# stays runnable without a config in unit tests.
$script:WriteOpBulkThreshold      = 100
$script:WriteOpTokenTtlSeconds    = 300
$script:WriteOpMaxItemsPerCall    = 1000

function Invoke-WriteOp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolName,
        [Parameter(Mandatory)][ValidateSet('move','copy')] [string]$GraphAction,
        [Parameter(Mandatory)][ValidateSet('preview','execute')] [string]$Mode,
        [Parameter(Mandatory)][string[]]$ItemIds,
        [Parameter(Mandatory)][string]$DestinationFolder,
        [bool]$DryRun = $true,
        [string]$ConfirmationToken,
        [bool]$AcknowledgedBulk = $false
    )

    if (-not $ItemIds -or $ItemIds.Count -lt 1) {
        throw 'item_ids must contain at least one message ID.'
    }
    if ($ItemIds.Count -gt $script:WriteOpMaxItemsPerCall) {
        throw "item_ids exceeds the maximum of $script:WriteOpMaxItemsPerCall per call."
    }

    $itemCount        = $ItemIds.Count
    $requiresReview   = ($itemCount -gt $script:WriteOpBulkThreshold)

    if ($Mode -eq 'preview') {
        $dest = Resolve-MailFolder -Path $DestinationFolder
        $token = New-ConfirmationToken `
            -Tool $ToolName `
            -ItemIds $ItemIds `
            -DestinationFolder $dest.Id `
            -TtlSeconds $script:WriteOpTokenTtlSeconds
        return [PSCustomObject]@{
            tool                   = $ToolName
            mode                   = 'preview'
            item_count             = $itemCount
            destination_folder     = $dest.ResolvedPath
            destination_folder_id  = $dest.Id
            requires_human_review  = $requiresReview
            confirmation_token     = $token.Token
            confirmation_token_id  = $token.TokenId
            expires_at             = $token.Payload.expires_at
            dry_run_default        = $true
            note                   = if ($requiresReview) {
                "Bulk threshold ($script:WriteOpBulkThreshold) exceeded. Execute call must pass acknowledged_bulk=true."
            } else {
                "Call mode='execute' with this confirmation_token and dry_run=false to perform the operation."
            }
        }
    }

    # mode = execute
    if (-not $ConfirmationToken) {
        throw 'confirmation_token is required when mode=execute.'
    }
    $dest = Resolve-MailFolder -Path $DestinationFolder
    $verified = Test-ConfirmationToken `
        -Token $ConfirmationToken `
        -ExpectedTool $ToolName `
        -ItemIds $ItemIds `
        -ExpectedDestination $dest.Id
    Assert-NotReplayed -TokenId $verified.TokenId

    if ($requiresReview -and -not $AcknowledgedBulk) {
        throw "Item count $itemCount exceeds bulk threshold $script:WriteOpBulkThreshold; pass acknowledged_bulk=true to proceed."
    }

    if ($DryRun) {
        return [PSCustomObject]@{
            tool                  = $ToolName
            mode                  = 'execute'
            dry_run               = $true
            item_count            = $itemCount
            destination_folder    = $dest.ResolvedPath
            destination_folder_id = $dest.Id
            confirmation_token_id = $verified.TokenId
            performed             = $false
            note                  = 'dry_run=true. No Graph mutation performed. Re-call with dry_run=false to apply.'
        }
    }

    # Live execution path. Register the token BEFORE any mutation so a partial
    # failure still consumes the token; the caller must mint a new one to retry.
    Register-ConsumedToken -TokenId $verified.TokenId

    $succeeded = [System.Collections.Generic.List[string]]::new()
    $failed    = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $ItemIds) {
        $uri = "https://graph.microsoft.com/v1.0/me/messages/$id/$GraphAction"
        try {
            [void](Invoke-McpGraph -Uri $uri -Method POST -Body @{ destinationId = $dest.Id })
            [void]$succeeded.Add($id)
        } catch {
            [void]$failed.Add([PSCustomObject]@{ id = $id; error = $_.Exception.Message })
        }
    }

    return [PSCustomObject]@{
        tool                  = $ToolName
        mode                  = 'execute'
        dry_run               = $false
        item_count            = $itemCount
        destination_folder    = $dest.ResolvedPath
        destination_folder_id = $dest.Id
        confirmation_token_id = $verified.TokenId
        performed             = $true
        succeeded_count       = $succeeded.Count
        failed_count          = $failed.Count
        failures              = $failed.ToArray()
    }
}
