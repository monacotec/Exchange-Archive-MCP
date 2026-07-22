# Version: 0.2.0
# HMAC-SHA256 signed confirmation tokens for two-step write tools.
# HMAC key: DPAPI-protected per-user secret at %LOCALAPPDATA%\ExchangeArchiveMcp\hmac.key.bin.
# 0.2.0: fix UTC handling in TTL check (ConvertFrom-Json yields Kind=Unspecified;
#        .ToUniversalTime() on that double-converted the offset and let tokens live
#        well past their declared expiry).

Set-StrictMode -Version Latest

function Get-HmacKey {
    param(
        [string]$KeyPath = "$env:LOCALAPPDATA\ExchangeArchiveMcp\hmac.key.bin"
    )
    $dir = Split-Path $KeyPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (-not (Test-Path $KeyPath)) {
        $bytes = New-Object byte[] 32
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $protected = [System.Security.Cryptography.ProtectedData]::Protect(
            $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
        [System.IO.File]::WriteAllBytes($KeyPath, $protected)
        return $bytes
    }
    $protected = [System.IO.File]::ReadAllBytes($KeyPath)
    return [System.Security.Cryptography.ProtectedData]::Unprotect(
        $protected, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
}

function Get-ItemIdsHash {
    param([Parameter(Mandatory)][string[]]$ItemIds)
    $sorted = $ItemIds | Sort-Object
    $joined = ($sorted -join '|')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($joined))
    return ([System.BitConverter]::ToString($hash) -replace '-','').ToLowerInvariant()
}

function New-ConfirmationToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tool,
        [Parameter(Mandatory)][string[]]$ItemIds,
        [Parameter(Mandatory)][string]$DestinationFolder,
        [int]$TtlSeconds = 300
    )
    $payload = [ordered]@{
        tool         = $Tool
        item_ids_hash = Get-ItemIdsHash -ItemIds $ItemIds
        dest_folder  = $DestinationFolder
        expires_at   = (Get-Date).ToUniversalTime().AddSeconds($TtlSeconds).ToString('o')
        nonce        = [guid]::NewGuid().ToString('N')
    }
    $payloadJson = ($payload | ConvertTo-Json -Compress)
    $payloadB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payloadJson))
    $key = Get-HmacKey
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($key)
    $sig = [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($payloadB64)))
    $token = "$payloadB64.$sig"
    return [PSCustomObject]@{
        Token   = $token
        TokenId = 'ct_' + $payload.nonce.Substring(0,12)
        Payload = $payload
    }
}

function Test-ConfirmationToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$ExpectedTool,
        [Parameter(Mandatory)][string[]]$ItemIds,
        [Parameter(Mandatory)][string]$ExpectedDestination
    )
    $parts = $Token -split '\.'
    if ($parts.Count -ne 2) { throw 'Malformed confirmation token.' }
    $key = Get-HmacKey
    $hmac = [System.Security.Cryptography.HMACSHA256]::new($key)
    $expectedSig = [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($parts[0])))
    if (-not [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
        [Text.Encoding]::UTF8.GetBytes($expectedSig),
        [Text.Encoding]::UTF8.GetBytes($parts[1]))) {
        throw 'Confirmation token signature invalid.'
    }
    $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[0])) | ConvertFrom-Json
    if ($payload.tool -ne $ExpectedTool) { throw "Token tool mismatch (expected $ExpectedTool, got $($payload.tool))." }
    if ($payload.dest_folder -ne $ExpectedDestination) { throw 'Token destination mismatch.' }
    if ((Get-ItemIdsHash -ItemIds $ItemIds) -ne $payload.item_ids_hash) { throw 'Token item-set mismatch.' }
    # The payload's expires_at was minted via .ToString('o') in UTC. ConvertFrom-Json
    # deserialises it to a DateTime with Kind=Unspecified, so .ToUniversalTime() would
    # treat it as local and double-convert. Pin Kind=Utc before comparing.
    $expiresUtc = [DateTime]::SpecifyKind([datetime]$payload.expires_at, [DateTimeKind]::Utc)
    if ($expiresUtc -lt [datetime]::UtcNow) { throw 'Confirmation token expired.' }
    return [PSCustomObject]@{
        Valid   = $true
        TokenId = 'ct_' + $payload.nonce.Substring(0,12)
        Payload = $payload
    }
}
