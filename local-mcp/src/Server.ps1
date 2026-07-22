# Version: 0.3.2
# Exchange Archive MCP — stdio entry point.
# Auth: Microsoft.Graph.Authentication (Connect-MgGraph). See CHANGES.md §1.

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\appsettings.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# STDOUT is reserved for protocol frames. Logging goes to STDERR.
$InformationPreference = 'Continue'
$VerbosePreference     = 'SilentlyContinue'
$WarningPreference     = 'Continue'

# --- Dot-source modules.
$root = $PSScriptRoot
. (Join-Path $root 'Transport\StdioTransport.ps1')
. (Join-Path $root 'Lib\Invoke-McpGraph.ps1')
. (Join-Path $root 'Lib\Get-ArchiveRoot.ps1')
. (Join-Path $root 'Lib\Write-AuditLog.ps1')
. (Join-Path $root 'Lib\ConvertTo-KqlQuery.ps1')
. (Join-Path $root 'Lib\New-ConfirmationToken.ps1')
. (Join-Path $root 'Lib\Test-ReplayGuard.ps1')
. (Join-Path $root 'Lib\Resolve-MailFolder.ps1')
. (Join-Path $root 'Lib\Invoke-WriteOp.ps1')
. (Join-Path $root 'Auth\Connect-McpGraph.ps1')
. (Join-Path $root 'Auth\Resolve-UserContext.ps1')
. (Join-Path $root 'Tools\List-ArchiveFolders.ps1')
. (Join-Path $root 'Tools\Get-ArchiveStats.ps1')
. (Join-Path $root 'Tools\Search-Archive.ps1')
. (Join-Path $root 'Tools\Get-ArchiveMessage.ps1')
. (Join-Path $root 'Tools\Get-ArchiveAttachment.ps1')
. (Join-Path $root 'Tools\Restore-ArchiveItem.ps1')
. (Join-Path $root 'Tools\Copy-ArchiveToPrimary.ps1')
. (Join-Path $root 'Tools\Move-ArchiveToPrimary.ps1')

# --- Config.
if (-not (Test-Path $ConfigPath)) {
    $example = Join-Path $root '..\config\appsettings.example.json'
    if (Test-Path $example) { $ConfigPath = $example }
    else { throw "Config not found: $ConfigPath" }
}
$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

# Expand env vars in path strings.
$Config.paths.auditDir   = [Environment]::ExpandEnvironmentVariables($Config.paths.auditDir)
$Config.paths.outputsDir = [Environment]::ExpandEnvironmentVariables($Config.paths.outputsDir)

# Cached state.
$script:UserContext = $null
$script:GraphReady  = $false

function Get-AuthContext {
    if (-not $script:GraphReady) {
        Ensure-McpGraphConnection `
            -ClientId $Config.auth.clientId `
            -TenantId $Config.auth.tenantId `
            -Scopes   $Config.auth.scopes | Out-Null
        $script:GraphReady = $true
    }
    if ($null -eq $script:UserContext) {
        $script:UserContext = Resolve-UserContext
    }
    return [PSCustomObject]@{
        Upn         = $script:UserContext.Upn
        AuditDir    = $Config.paths.auditDir
        OutputsDir  = $Config.paths.outputsDir
        MaxResults  = $Config.limits.maxResultsPerCall
        PageSize    = $Config.limits.pageSize
    }
}

# --- Tool registry.
$ToolDefs = @(
    @{
        name = 'archive_list_folders'
        description = 'List the In-Place (Online) Archive folder tree, rooted at archivemsgfolderroot. Returns name, id, totalItemCount, childFolderCount per folder.'
        inputSchema = [ordered]@{ type='object'; properties = [ordered]@{
            max_depth = [ordered]@{ type='integer'; minimum=0; maximum=10; default=4; description='Recursion depth.' }
        }; additionalProperties = $false }
        invoke = { param($a,$ctx) Invoke-ListArchiveFolders -Ctx $ctx -MaxDepth ([int]($a.max_depth ?? 4)) }
    },
    @{
        name = 'archive_get_stats'
        description = 'Return archive mailbox totals: item count, folder count, mailbox settings if available.'
        inputSchema = [ordered]@{ type='object'; properties = [ordered]@{}; additionalProperties = $false }
        invoke = { param($a,$ctx) Invoke-GetArchiveStats -Ctx $ctx }
    },
    @{
        name = 'archive_search'
        description = 'Search every folder of the In-Place (Online) Archive with a KQL-like query (supports from:, to:, subject:, after:YYYY-MM-DD, before:YYYY-MM-DD, has:attachment). Per-folder fan-out, merged newest-first; each result names its archive folder. Returns up to max_results message summaries.'
        inputSchema = [ordered]@{ type='object'; properties = [ordered]@{
            query       = [ordered]@{ type='string'; minLength=1 }
            max_results = [ordered]@{ type='integer'; minimum=1; maximum=1000; default=50 }
        }; required=@('query'); additionalProperties = $false }
        invoke = { param($a,$ctx) Invoke-SearchArchive -Ctx $ctx -Query $a.query -MaxResults ([int]($a.max_results ?? 50)) }
    },
    @{
        name = 'archive_get_message'
        description = 'Fetch a single archive message by id, including full body and headers.'
        inputSchema = [ordered]@{ type='object'; properties = [ordered]@{
            message_id  = [ordered]@{ type='string'; minLength=1 }
            body_format = [ordered]@{ type='string'; enum=@('text','html'); default='text' }
        }; required=@('message_id'); additionalProperties = $false }
        invoke = { param($a,$ctx) Invoke-GetArchiveMessage -Ctx $ctx -MessageId $a.message_id -BodyFormat ($a.body_format ?? 'text') }
    },
    @{
        name = 'archive_download_attachment'
        description = 'Download a named attachment from an archive message to the local outputs directory. Returns the file path.'
        inputSchema = [ordered]@{ type='object'; properties = [ordered]@{
            message_id    = [ordered]@{ type='string'; minLength=1 }
            attachment_id = [ordered]@{ type='string'; minLength=1 }
        }; required=@('message_id','attachment_id'); additionalProperties = $false }
        invoke = { param($a,$ctx) Invoke-GetArchiveAttachment -Ctx $ctx -MessageId $a.message_id -AttachmentId $a.attachment_id }
    },
    @{
        name = 'archive_restore_item'
        description = "Move archive messages back to the primary mailbox. Default destination is Inbox; pass destination_folder to override. Two-step: call once with mode='preview' to obtain a confirmation_token, then with mode='execute' to apply. dry_run defaults to true. Mutation requires dry_run=false."
        write = $true
        inputSchema = [ordered]@{ type='object'; properties = [ordered]@{
            mode               = [ordered]@{ type='string'; enum=@('preview','execute') }
            item_ids           = [ordered]@{ type='array'; minItems=1; maxItems=1000; items=[ordered]@{ type='string'; minLength=1 } }
            destination_folder = [ordered]@{ type='string'; default='Inbox' }
            dry_run            = [ordered]@{ type='boolean'; default=$true }
            confirmation_token = [ordered]@{ type='string' }
            acknowledged_bulk  = [ordered]@{ type='boolean'; default=$false }
        }; required=@('mode','item_ids'); additionalProperties = $false }
        invoke = { param($a,$ctx)
            Invoke-RestoreArchiveItem -Ctx $ctx -Mode $a.mode -ItemIds @($a.item_ids) `
                -DestinationFolder ($a.destination_folder ?? 'Inbox') `
                -DryRun ([bool]($a.dry_run ?? $true)) `
                -ConfirmationToken ($a.confirmation_token ?? '') `
                -AcknowledgedBulk ([bool]($a.acknowledged_bulk ?? $false))
        }
    },
    @{
        name = 'archive_copy_to_primary'
        description = "Copy archive messages to a primary-mailbox folder. Archive originals are retained. Two-step: mode='preview' returns a confirmation_token; mode='execute' applies. dry_run defaults to true."
        write = $true
        inputSchema = [ordered]@{ type='object'; properties = [ordered]@{
            mode               = [ordered]@{ type='string'; enum=@('preview','execute') }
            item_ids           = [ordered]@{ type='array'; minItems=1; maxItems=1000; items=[ordered]@{ type='string'; minLength=1 } }
            destination_folder = [ordered]@{ type='string'; minLength=1 }
            dry_run            = [ordered]@{ type='boolean'; default=$true }
            confirmation_token = [ordered]@{ type='string' }
            acknowledged_bulk  = [ordered]@{ type='boolean'; default=$false }
        }; required=@('mode','item_ids','destination_folder'); additionalProperties = $false }
        invoke = { param($a,$ctx)
            Invoke-CopyArchiveToPrimary -Ctx $ctx -Mode $a.mode -ItemIds @($a.item_ids) `
                -DestinationFolder $a.destination_folder `
                -DryRun ([bool]($a.dry_run ?? $true)) `
                -ConfirmationToken ($a.confirmation_token ?? '') `
                -AcknowledgedBulk ([bool]($a.acknowledged_bulk ?? $false))
        }
    },
    @{
        name = 'archive_move_to_primary'
        description = "Move archive messages to a primary-mailbox folder. Archive originals are REMOVED. Two-step: mode='preview' returns a confirmation_token; mode='execute' applies. dry_run defaults to true. Prefer archive_copy_to_primary unless removal from archive is explicitly intended."
        write = $true
        inputSchema = [ordered]@{ type='object'; properties = [ordered]@{
            mode               = [ordered]@{ type='string'; enum=@('preview','execute') }
            item_ids           = [ordered]@{ type='array'; minItems=1; maxItems=1000; items=[ordered]@{ type='string'; minLength=1 } }
            destination_folder = [ordered]@{ type='string'; minLength=1 }
            dry_run            = [ordered]@{ type='boolean'; default=$true }
            confirmation_token = [ordered]@{ type='string' }
            acknowledged_bulk  = [ordered]@{ type='boolean'; default=$false }
        }; required=@('mode','item_ids','destination_folder'); additionalProperties = $false }
        invoke = { param($a,$ctx)
            Invoke-MoveArchiveToPrimary -Ctx $ctx -Mode $a.mode -ItemIds @($a.item_ids) `
                -DestinationFolder $a.destination_folder `
                -DryRun ([bool]($a.dry_run ?? $true)) `
                -ConfirmationToken ($a.confirmation_token ?? '') `
                -AcknowledgedBulk ([bool]($a.acknowledged_bulk ?? $false))
        }
    }
)

# --- Dispatcher.
function Invoke-Method {
    param($Request)
    $method = $Request.method
    # Notifications (e.g. notifications/initialized) and pings may omit the params
    # field entirely. Under Set-StrictMode -Version Latest, accessing a missing
    # property throws -- so probe before reading.
    $params = if ($Request.PSObject.Properties.Match('params').Count -gt 0) { $Request.params } else { $null }
    switch ($method) {
        'initialize' {
            return @{
                protocolVersion = '2025-06-18'
                capabilities    = @{ tools = @{} }
                serverInfo      = @{ name = 'exchange-archive-local'; version = '0.3.1' }
            }
        }
        'ping' { return @{} }
        'tools/list' {
            $tools = $ToolDefs | ForEach-Object {
                @{ name = $_.name; description = $_.description; inputSchema = $_.inputSchema }
            }
            return @{ tools = $tools }
        }
        'tools/call' {
            $name      = $params.name
            $arguments = $params.arguments
            # Case-sensitive match (-ceq): tool names are exact identifiers, and the
            # audit log must record the canonical name, never caller-supplied casing.
            $def = $ToolDefs | Where-Object { $_.name -ceq $name } | Select-Object -First 1
            if (-not $def) { throw "Unknown tool: $name" }
            $ctx = Get-AuthContext
            $started = Get-Date
            $isWrite = [bool]($def.ContainsKey('write') -and $def.write)
            try {
                $result = & $def.invoke $arguments $ctx
                $text = if ($result -is [string]) { $result } else { ($result | ConvertTo-Json -Depth 20) }

                # Audit: read tools route to debug sink with empty params; write tools route
                # to the durable sink with a redacted summary lifted from the tool result.
                if ($isWrite) {
                    $auditMode  = if ($arguments.PSObject.Properties.Match('mode').Count -gt 0) { [string]$arguments.mode } else { 'execute' }
                    $tokenIdVal = $null
                    if ($result -is [System.Management.Automation.PSCustomObject]) {
                        $props = $result.PSObject.Properties
                        if ($props.Match('confirmation_token_id').Count -gt 0) { $tokenIdVal = $result.confirmation_token_id }
                    }
                    $paramsRedacted = @{
                        item_count          = ($arguments.item_ids | Measure-Object).Count
                        destination_folder  = if ($arguments.PSObject.Properties.Match('destination_folder').Count -gt 0) { $arguments.destination_folder } else { $null }
                        dry_run             = if ($arguments.PSObject.Properties.Match('dry_run').Count -gt 0) { [bool]$arguments.dry_run } else { $true }
                        acknowledged_bulk   = if ($arguments.PSObject.Properties.Match('acknowledged_bulk').Count -gt 0) { [bool]$arguments.acknowledged_bulk } else { $false }
                    }
                    Write-AuditLog -Tool $name -Mode $auditMode -CallerUpn $ctx.Upn `
                        -ParamsRedacted $paramsRedacted -ConfirmationTokenId $tokenIdVal `
                        -Result 'success' -DurationMs ([int]((Get-Date) - $started).TotalMilliseconds) `
                        -AuditDir $ctx.AuditDir
                } else {
                    Write-AuditLog -Tool $name -Mode 'read' -CallerUpn $ctx.Upn -ParamsRedacted @{} -Result 'success' `
                        -DurationMs ([int]((Get-Date) - $started).TotalMilliseconds) -AuditDir $ctx.AuditDir
                }
                return @{
                    content = @( @{ type='text'; text = $text } )
                    isError = $false
                }
            } catch {
                Write-AuditLog -Tool $name -Mode 'error' -CallerUpn $ctx.Upn -ParamsRedacted @{} -Result 'error' `
                    -DurationMs ([int]((Get-Date) - $started).TotalMilliseconds) -AuditDir $ctx.AuditDir
                return @{
                    content = @( @{ type='text'; text = "Tool $name failed: $($_.Exception.Message)" } )
                    isError = $true
                }
            }
        }
        'notifications/initialized' { return $null }
        'notifications/cancelled'   { return $null }
        default { throw "Method not found: $method" }
    }
}

Write-StderrLog "exchange-archive-local 0.3.1 starting (pid=$PID)"

while ($true) {
    $msg = Read-StdioMessage
    if ($null -eq $msg) { Write-StderrLog 'EOF on stdin; exiting.'; break }
    # Skip blank-line sentinels emitted by Read-StdioMessage.
    if ($msg -is [hashtable] -and $msg.Count -eq 0) { continue }
    $hasParseError = $false
    if ($msg.PSObject -and $msg.PSObject.Properties.Match('__parseError').Count -gt 0) {
        $hasParseError = [bool]$msg.__parseError
    }
    if ($hasParseError) {
        Write-StdioMessage (New-JsonRpcError -Id $null -Code -32700 -Message 'Parse error')
        continue
    }
    $id = if ($msg.PSObject.Properties.Match('id').Count -gt 0) { $msg.id } else { $null }
    $isNotification = ($null -eq $id)

    try {
        $result = Invoke-Method -Request $msg
        if (-not $isNotification) {
            Write-StdioMessage (New-JsonRpcResult -Id $id -Result $result)
        }
    } catch {
        Write-StderrLog -Level 'error' "Dispatcher error: $($_.Exception.Message)"
        if (-not $isNotification) {
            $code = -32603
            if ($_.Exception.Message -like 'Method not found*') { $code = -32601 }
            Write-StdioMessage (New-JsonRpcError -Id $id -Code $code -Message $_.Exception.Message)
        }
    }
}
