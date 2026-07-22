# Version: 0.1.0
# archive_copy_to_primary -- copy N archive messages to a primary-mailbox folder.
# Archive originals are retained. Otherwise identical shape to move.

Set-StrictMode -Version Latest

function Invoke-CopyArchiveToPrimary {
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
    return Invoke-WriteOp -ToolName 'archive_copy_to_primary' -GraphAction 'copy' `
        -Mode $Mode -ItemIds $ItemIds -DestinationFolder $DestinationFolder `
        -DryRun $DryRun -ConfirmationToken $ConfirmationToken -AcknowledgedBulk $AcknowledgedBulk
}
