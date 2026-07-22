# Version: 0.1.0
# JSON-RPC 2.0 over stdio. Each message is a single line of JSON (newline-delimited).
# All operational logging must go to STDERR; STDOUT is reserved for protocol frames.

Set-StrictMode -Version Latest

function Write-StderrLog {
    param([Parameter(Mandatory)][string]$Message, [string]$Level='info')
    $line = ([ordered]@{
        ts    = (Get-Date).ToUniversalTime().ToString('o')
        level = $Level
        msg   = $Message
    } | ConvertTo-Json -Compress)
    [Console]::Error.WriteLine($line)
}

function Read-StdioMessage {
    # Blocking read of a single newline-delimited JSON message from STDIN.
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { return $null }  # EOF
    if ([string]::IsNullOrWhiteSpace($line)) { return ,@{} }  # skip blanks
    try {
        return ($line | ConvertFrom-Json -Depth 50)
    } catch {
        Write-StderrLog -Level 'error' -Message "Failed to parse stdin: $($_.Exception.Message)"
        return ,@{ __parseError = $true; raw = $line }
    }
}

function Write-StdioMessage {
    param([Parameter(Mandatory)]$Object)
    $json = ($Object | ConvertTo-Json -Depth 50 -Compress)
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}

function New-JsonRpcResult {
    param([Parameter(Mandatory)]$Id, [Parameter(Mandatory)]$Result)
    return [ordered]@{
        jsonrpc = '2.0'
        id      = $Id
        result  = $Result
    }
}

function New-JsonRpcError {
    param(
        [Parameter(Mandatory)]$Id,
        [Parameter(Mandatory)][int]$Code,
        [Parameter(Mandatory)][string]$Message,
        $Data
    )
    $err = [ordered]@{ code = $Code; message = $Message }
    if ($PSBoundParameters.ContainsKey('Data')) { $err.data = $Data }
    return [ordered]@{
        jsonrpc = '2.0'
        id      = $Id
        error   = $err
    }
}
