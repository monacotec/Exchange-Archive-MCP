# Version: 0.1.0
# archive_move_to_primary -- move N archive messages to a primary-mailbox folder.
# Two-step confirm: mode=preview returns a confirmation_token; mode=execute
# validates it and performs the Graph /move calls. dry_run defaults to true.

Set-StrictMode -Version Latest

function Invoke-MoveArchiveToPrimary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][ValidateSet('preview','execute')] [string]$Mode,
        [Parameter(Mandatory)][string[]]$ItemIds,
        [Parameter(Mandatory)][string]$DestinationFolder,
        [bool]$DryRun = $true,
        [string]$ConfirmationToken,
        [bool]$AcknowledgedBulk = $false
    )
    return Invoke-WriteOp -ToolName 'archive_move_to_primary' -GraphAction 'move' `
        -Mode $Mode -ItemIds $ItemIds -DestinationFolder $DestinationFolder `
        -DryRun $DryRun -ConfirmationToken $ConfirmationToken -AcknowledgedBulk $AcknowledgedBulk
}
