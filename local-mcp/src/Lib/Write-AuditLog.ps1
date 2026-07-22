# Version: 0.2.0
# JSONL audit logger. Append-only; one file per UTC day.
#
# Sink routing (security baseline §11; SECURITY.md §Audit):
#   mode in {preview, execute, error} -> $AuditDir\YYYY-MM-DD.jsonl       (durable audit)
#   mode = read                       -> $AuditDir\debug\YYYY-MM-DD.jsonl (debug-level)
# Read-tool params are NEVER written here even at debug level — only the
# fact-of-call shape (tool, caller, duration). Search terms stay out of the log.

Set-StrictMode -Version Latest

function Write-AuditLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][ValidateSet('preview','execute','read','error')] [string]$Mode,
        [Parameter(Mandatory)][string]$CallerUpn,
        [hashtable]$ParamsRedacted,
        [string]$ConfirmationTokenId,
        [string]$GraphRequestId,
        [string]$Result = 'success',
        [int]$DurationMs = 0,
        [string]$AuditDir = "$env:LOCALAPPDATA\ExchangeArchiveMcp\audit"
    )
    $targetDir = if ($Mode -eq 'read') { Join-Path $AuditDir 'debug' } else { $AuditDir }
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
    # Read entries record fact-of-call only; force params empty regardless of caller intent.
    if ($Mode -eq 'read') { $ParamsRedacted = @{} }
    $day = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    $file = Join-Path $targetDir "$day.jsonl"
    $entry = [ordered]@{
        ts                    = (Get-Date).ToUniversalTime().ToString('o')
        caller_upn            = $CallerUpn
        tool                  = $Tool
        mode                  = $Mode
        params_redacted       = $ParamsRedacted
        confirmation_token_id = $ConfirmationTokenId
        graph_request_id      = $GraphRequestId
        result                = $Result
        duration_ms           = $DurationMs
    }
    $json = ($entry | ConvertTo-Json -Depth 8 -Compress)
    Add-Content -LiteralPath $file -Value $json -Encoding utf8
}
