#Requires -Version 5.1
<#
.SYNOPSIS
    Opens a mail item in classic Outlook by Internet Message-ID, searching every
    folder across every mail store (primary mailbox AND Online Archive) - not
    just the online archive database that archiveopen.exe is limited to.

.DESCRIPTION
    Intended to be the target of the giparchive: protocol handler:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\GI\Open-ArchiveMessage.ps1" "%1"

    Accepts either a full giparchive:v1?mid=<url-encoded-message-id> URI (what
    Windows passes in as %1) or a bare Internet Message-ID, resolves the
    Message-ID, then uses Outlook.Namespace.AdvancedSearch (DASL filter on
    urn:schemas:httpmail:messageid) scoped to the root folder of every store
    with SearchSubFolders = True. This reaches Inbox, Sent Items, Deleted
    Items, Calendar, custom subfolders, AND the separate Online Archive data
    file, so it finds the message no matter which folder it is actually in
    -- unlike archiveopen.exe, which only searches the Online Archive.

    On a match, calls .Display() so the item opens in classic Outlook. On no
    match or a COM/search failure, shows a message box (there is no console
    when launched from a URI handler) and logs details to C:\GI\Logs.

.PARAMETER InputValue
    Either a full giparchive:... URI, or a bare Internet Message-ID (with or
    without surrounding angle brackets).

.PARAMETER TimeoutSeconds
    How long to wait for AdvancedSearch to complete before giving up. Default 20.

.EXAMPLE
    .\Open-ArchiveMessage.ps1 "giparchive:v1?mid=%3Cabc123%40example.com%3E"

.EXAMPLE
    .\Open-ArchiveMessage.ps1 "<abc123@example.com>"

.NOTES
    Version:    1.0.0
    Log path:   C:\GI\Logs\Open-ArchiveMessage_<timestamp>.log
    Compatible: PowerShell 5.1 and 7.x. Windows only; requires classic Outlook
                (COM-automatable) to be installed. Not PDQ Deploy-relevant on
                its own (it is invoked per-click, not run as a deployment
                step) - see Register-GIArchiveProtocol.ps1 for the deployable
                registration piece.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InputValue,

    [int]$TimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'

# --- Logging ---
$logDir = 'C:\GI\Logs'
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$logPath = Join-Path $logDir "Open-ArchiveMessage_$timestamp.log"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding ASCII
}

function Show-Message {
    param([string]$Text, [string]$Title = 'GIP Archive Open')
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    [System.Windows.Forms.MessageBox]::Show($Text, $Title, 'OK', 'Information') | Out-Null
}

Write-Log "Invoked with InputValue=$InputValue"

# --- Resolve the Internet Message-ID out of a giparchive: URI or a bare id ---
$messageId = $InputValue
if ($InputValue -match '^giparchive:') {
    if ($InputValue -match '[?&]mid=([^&]+)') {
        $messageId = [System.Uri]::UnescapeDataString($Matches[1])
    }
    else {
        Write-Log "No mid= parameter found in URI: $InputValue" 'ERROR'
        Show-Message "Could not parse a Message-ID from:`n$InputValue"
        exit 1
    }
}
$messageId = $messageId.Trim().Trim('<', '>')
Write-Log "Resolved Message-ID: $messageId"

# --- Connect to Outlook (classic, via COM) ---
try {
    $outlook = New-Object -ComObject Outlook.Application
    $namespace = $outlook.GetNamespace('MAPI')
}
catch {
    Write-Log "ERROR: Could not connect to Outlook via COM: $($_.Exception.Message)" 'ERROR'
    Show-Message "Could not connect to classic Outlook. Confirm it is installed correctly and try opening it manually first."
    exit 1
}

# --- Build search scope: root folder of EVERY store (mailbox + Online Archive) ---
$scopeParts = @()
foreach ($store in $namespace.Stores) {
    try {
        $root = $store.GetRootFolder()
        $scopeParts += ('"' + $root.FolderPath + '"')
        Write-Log "Including store in search scope: $($store.DisplayName) -> $($root.FolderPath)"
    }
    catch {
        Write-Log "WARNING: Could not get root folder for store $($store.DisplayName): $($_.Exception.Message)" 'WARN'
    }
}
if ($scopeParts.Count -eq 0) {
    Write-Log "ERROR: No searchable stores found." 'ERROR'
    Show-Message "No Outlook mail stores were found to search."
    exit 1
}
$scope = $scopeParts -join ','
$filter = "`"urn:schemas:httpmail:messageid`" = '$messageId'"
Write-Log "Filter: $filter"
Write-Log "Scope: $scope"

# --- Run AdvancedSearch across all stores, all subfolders ---
try {
    $search = $namespace.AdvancedSearch($scope, $filter, $true, 'GIArchiveOpenSearch')
}
catch {
    Write-Log "ERROR: AdvancedSearch failed to start: $($_.Exception.Message)" 'ERROR'
    Show-Message "Search could not be started in Outlook: $($_.Exception.Message)"
    exit 1
}

$elapsedMs = 0
while (-not $search.IsSearchComplete -and $elapsedMs -lt ($TimeoutSeconds * 1000)) {
    Start-Sleep -Milliseconds 500
    $elapsedMs += 500
}

if (-not $search.IsSearchComplete) {
    Write-Log "Search timed out after $TimeoutSeconds seconds." 'WARN'
    Show-Message "The search timed out after $TimeoutSeconds seconds. Outlook may still be indexing; try again shortly."
    exit 1
}

if ($search.Results.Count -eq 0) {
    Write-Log "No matching item found for Message-ID $messageId in any searched folder/store." 'WARN'
    Show-Message "That message was not found in any folder across your mailbox or Online Archive.`n`nMessage-ID: $messageId"
    exit 0
}

try {
    $item = $search.Results.Item(1)
    $item.Display()
    Write-Log "Displayed item found in folder: $($item.Parent.FolderPath)"
}
catch {
    Write-Log "ERROR: Found a match but could not display it: $($_.Exception.Message)" 'ERROR'
    Show-Message "Found the message but could not open it: $($_.Exception.Message)"
    exit 1
}
