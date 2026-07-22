# Version: 0.1.0
# archive_restore_item -- move archive messages back into the primary mailbox.
#
# Restore differs from move only in its default destination: when the caller
# omits DestinationFolder, restore drops items into the primary mailbox Inbox.
# Graph does not expose pre-archive folder history, so we cannot reconstruct
# the original location. Document the fallback in the tool description; the
# caller should pass an explicit DestinationFolder when they know better.

Set-StrictMode -Version Latest

function Invoke-RestoreArchiveItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Ctx,
        [Parameter(Mandatory)][ValidateSet('preview','execute')] [string]$Mode,
        [Parameter(Mandatory)][string[]]$ItemIds,
        [string]$DestinationFolder = 'Inbox',
        [bool]$DryRun = $true,
        [string]$ConfirmationToken,
        [bool]$AcknowledgedBulk = $false
    )
    if (-not $DestinationFolder) { $DestinationFolder = 'Inbox' }
    return Invoke-WriteOp -ToolName 'archive_restore_item' -GraphAction 'move' `
        -Mode $Mode -ItemIds $ItemIds -DestinationFolder $DestinationFolder `
        -DryRun $DryRun -ConfirmationToken $ConfirmationToken -AcknowledgedBulk $AcknowledgedBulk
}
