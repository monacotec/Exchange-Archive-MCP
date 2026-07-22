# Version: 0.1.0
# Single-use confirmation-token tracker.
#
# Confirmation tokens are HMAC-signed and TTL-bound, but those checks alone do
# not prevent a captured-and-replayed token from being used twice within its
# 5-minute window. This module keeps an in-memory set of consumed token IDs and
# rejects repeats. The set is scoped to the server process lifetime, which is
# sufficient for stdio (one process per session). For HTTPS (Phase 3) this
# should migrate to a server-side store keyed by user.

Set-StrictMode -Version Latest

$script:UsedTokenIds = [System.Collections.Generic.HashSet[string]]::new()

function Assert-NotReplayed {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TokenId)

    if ($script:UsedTokenIds.Contains($TokenId)) {
        throw "Confirmation token $TokenId has already been consumed."
    }
}

function Register-ConsumedToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TokenId)

    [void]$script:UsedTokenIds.Add($TokenId)
}

function Reset-ReplayGuard {
    # Test-only seam.
    $script:UsedTokenIds.Clear()
}
