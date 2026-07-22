# Version: 0.2.0
# Thin wrapper over Invoke-MgGraphRequest.
# Adds:
#   - consistent client-request-id header for correlation
#   - exponential backoff + Retry-After honouring on 429/503/504
#   - paged collection helper that respects a maxItems ceiling
#
# Does NOT take an AccessToken. Auth is handled by the Microsoft.Graph.Authentication
# session established via Connect-McpGraph.

Set-StrictMode -Version Latest

function Invoke-McpGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('GET','POST','PATCH','DELETE')][string]$Method = 'GET',
        [object]$Body,
        [hashtable]$ExtraHeaders,
        [int]$MaxAttempts = 5,
        [int]$InitialDelayMs = 1000
    )

    $requestId = [guid]::NewGuid().ToString()
    $headers = @{
        'client-request-id' = $requestId
        'Prefer'            = 'IdType="ImmutableId"'
    }
    if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $headers[$k] = $ExtraHeaders[$k] } }

    $attempt = 0
    $delay   = $InitialDelayMs
    while ($true) {
        $attempt++
        try {
            $params = @{
                Method      = $Method
                Uri         = $Uri
                Headers     = $headers
                OutputType  = 'PSObject'
                ErrorAction = 'Stop'
            }
            if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
                $params.Body        = ($Body | ConvertTo-Json -Depth 20 -Compress)
                $params.ContentType = 'application/json'
            }
            $result = Invoke-MgGraphRequest @params
            return [PSCustomObject]@{
                Value     = $result
                RequestId = $requestId
            }
        }
        catch {
            $status = 0
            $retryAfterMs = $null
            $resp = $null
            try { $resp = $_.Exception.Response } catch { }
            if ($resp) {
                try { $status = [int]$resp.StatusCode } catch { }
                if ($resp.Headers -and $resp.Headers.Contains('Retry-After')) {
                    $raw = ($resp.Headers.GetValues('Retry-After'))[0]
                    if ($raw -match '^\d+$') { $retryAfterMs = [int]$raw * 1000 }
                    else {
                        try { $retryAfterMs = [Math]::Max(0, ([datetime]$raw - [datetime]::UtcNow).TotalMilliseconds) } catch { }
                    }
                }
            }
            if ($status -eq 0 -and $_.Exception.Message -match '\b(429|503|504)\b') {
                $status = [int]$matches[1]
            }
            $isRetryable = ($status -eq 429 -or $status -eq 503 -or $status -eq 504)
            if (-not $isRetryable -or $attempt -ge $MaxAttempts) {
                throw [System.Exception]::new(
                    "Graph $Method $Uri failed (status=$status, attempt=$attempt, requestId=$requestId): $($_.Exception.Message)",
                    $_.Exception)
            }
            $sleep = if ($retryAfterMs) { [int]$retryAfterMs } else { $delay }
            Start-Sleep -Milliseconds $sleep
            $delay = [Math]::Min($delay * 2, 16000)
        }
    }
}

function Invoke-McpGraphPaged {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$MaxItems = 10000
    )
    $collected = [System.Collections.Generic.List[object]]::new()
    $next = $Uri
    while ($next -and $collected.Count -lt $MaxItems) {
        $resp = Invoke-McpGraph -Uri $next -Method GET
        $page = $resp.Value
        if ($page.value) {
            foreach ($v in $page.value) {
                if ($collected.Count -ge $MaxItems) { break }
                [void]$collected.Add($v)
            }
        }
        # Graph omits @odata.nextLink on single-page responses; under StrictMode a
        # bare property read on the absent key throws, so guard with Match().
        $next = if ($page.PSObject.Properties.Match('@odata.nextLink').Count -gt 0) {
            $page.'@odata.nextLink'
        } else { $null }
    }
    return [PSCustomObject]@{
        Items     = $collected.ToArray()
        Truncated = ($collected.Count -ge $MaxItems -and $next)
        NextLink  = $next
    }
}
