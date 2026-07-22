#Requires -Version 7.0
<#
.SYNOPSIS
    MCP Server Security - Step 2: JWT Service (Token Generation and Verification)
    Translated from Microsoft Azure-Samples/mcp-container-ts (TypeScript)

.DESCRIPTION
    Centralised JWT logic for MCP server authentication.
    All token creation and verification lives here so security-critical
    code is auditable in one place.

    Critical security rules enforced:
    - Algorithm locked to HS256 — "none" algorithm bypass is a real attack vector
    - Audience and Issuer validated on every verification (prevents cross-service reuse)
    - All config from environment variables — nothing hardcoded
    - Fail-fast at load time if required env vars are missing
    - Token expiry validated; expired tokens return a clear, distinct error

    Required environment variables (store in a secrets manager, not .env files):
        MCP_JWT_SECRET    — HMAC signing secret (32+ random bytes recommended)
        MCP_JWT_AUDIENCE  — Expected 'aud' claim, e.g. https://mcp.yourcompany.com
        MCP_JWT_ISSUER    — Expected 'iss' claim, e.g. https://auth.yourcompany.com
        MCP_JWT_EXPIRY    — Token lifetime in seconds (default: 1800 = 30 minutes)

.NOTES
    Requires: Microsoft.PowerShell.SecretManagement or equivalent for secret storage.
    JWT HMAC-SHA256 implemented with System.Security.Cryptography — no external modules.
    Source: §18 of mcp-security-considerations.md
    Reference: https://github.com/Azure-Samples/mcp-container-ts
#>

#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Dot-source the authorization module so we have access to AuthenticatedUser, UserRole, Permission
. "$PSScriptRoot/01-Authorization.ps1"

# ---------------------------------------------------------------------------
# Load and validate required environment variables at module load time.
# Fail fast — never let a misconfigured server run silently.
# ---------------------------------------------------------------------------

$script:JwtSecret   = $env:MCP_JWT_SECRET
$script:JwtAudience = $env:MCP_JWT_AUDIENCE
$script:JwtIssuer   = $env:MCP_JWT_ISSUER
$script:JwtExpiry   = [int]($env:MCP_JWT_EXPIRY ?? 1800)   # default 30 minutes

if (-not $script:JwtSecret -or -not $script:JwtAudience -or -not $script:JwtIssuer) {
    throw "JWT environment variables are not set. " +
          "MCP_JWT_SECRET, MCP_JWT_AUDIENCE, and MCP_JWT_ISSUER are all required."
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

function ConvertTo-Base64Url {
    param([byte[]] $Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-Base64Url {
    param([string] $Input)
    $padded = $Input.Replace('-', '+').Replace('_', '/')
    switch ($padded.Length % 4) {
        2 { $padded += '==' }
        3 { $padded += '='  }
    }
    return [Convert]::FromBase64String($padded)
}

function Get-HmacSha256Signature {
    param([string] $Data, [string] $Secret)
    $keyBytes  = [System.Text.Encoding]::UTF8.GetBytes($Secret)
    $dataBytes = [System.Text.Encoding]::UTF8.GetBytes($Data)
    $hmac      = [System.Security.Cryptography.HMACSHA256]::new($keyBytes)
    return $hmac.ComputeHash($dataBytes)
}

# ---------------------------------------------------------------------------
# Public functions
# ---------------------------------------------------------------------------

function New-JwtToken {
    <#
    .SYNOPSIS
        Generates a signed HS256 JWT for the given user.
        Primarily used for testing and token issuance in dev environments.
        In production, tokens should be issued by your identity provider.
    .PARAMETER UserId
        The user's unique identifier.
    .PARAMETER Role
        The user's UserRole.
    .PARAMETER Permissions
        Optional explicit permission list. Defaults to role permissions.
    .OUTPUTS
        string — the signed JWT
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $UserId,

        [Parameter(Mandatory)]
        [UserRole] $Role,

        [Permission[]] $Permissions = $null
    )

    if ($null -eq $Permissions) {
        $Permissions = Get-PermissionsForRole -Role $Role
    }

    $now = [DateTimeOffset]::UtcNow
    $exp = $now.AddSeconds($script:JwtExpiry).ToUnixTimeSeconds()
    $iat = $now.ToUnixTimeSeconds()

    # Header
    $header  = @{ alg = 'HS256'; typ = 'JWT' } | ConvertTo-Json -Compress
    $headerB64 = ConvertTo-Base64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes($header))

    # Payload
    $payload = @{
        sub         = $UserId
        id          = $UserId
        role        = $Role.ToString().ToLower()
        permissions = @($Permissions | ForEach-Object { $_.ToString() })
        aud         = $script:JwtAudience
        iss         = $script:JwtIssuer
        iat         = $iat
        exp         = $exp
    } | ConvertTo-Json -Compress
    $payloadB64 = ConvertTo-Base64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes($payload))

    # Signature — HS256 only; never accept "none"
    $signingInput = "$headerB64.$payloadB64"
    $sigBytes     = Get-HmacSha256Signature -Data $signingInput -Secret $script:JwtSecret
    $sigB64       = ConvertTo-Base64Url -Bytes $sigBytes

    return "$signingInput.$sigB64"
}

function Test-JwtToken {
    <#
    .SYNOPSIS
        Verifies an incoming JWT and returns an AuthenticatedUser if valid.
        Throws a descriptive exception on any failure.

    .DESCRIPTION
        Validates:
          1. Three-part structure (header.payload.signature)
          2. Algorithm is exactly HS256 — rejects "none" and all other algorithms
          3. HMAC-SHA256 signature matches
          4. 'aud' claim matches MCP_JWT_AUDIENCE
          5. 'iss' claim matches MCP_JWT_ISSUER
          6. Token has not expired ('exp' claim)
          7. Payload contains required 'id' and 'role' fields

    .PARAMETER Token
        The raw JWT string (without "Bearer " prefix — strip that in the middleware).
    .OUTPUTS
        AuthenticatedUser
    #>
    [OutputType([AuthenticatedUser])]
    param(
        [Parameter(Mandatory)]
        [string] $Token
    )

    # 1. Structure check
    $parts = $Token.Split('.')
    if ($parts.Count -ne 3) {
        throw [System.Security.SecurityException]"Invalid token: malformed structure."
    }

    # 2. Decode header and verify algorithm
    $headerJson = [System.Text.Encoding]::UTF8.GetString((ConvertFrom-Base64Url $parts[0]))
    $header     = $headerJson | ConvertFrom-Json
    if ($header.alg -ne 'HS256') {
        # Never accept "none" or unexpected algorithms
        throw [System.Security.SecurityException]"Invalid token: unsupported algorithm '$($header.alg)'."
    }

    # 3. Verify signature
    $signingInput    = "$($parts[0]).$($parts[1])"
    $expectedSigBytes = Get-HmacSha256Signature -Data $signingInput -Secret $script:JwtSecret
    $expectedSigB64  = ConvertTo-Base64Url -Bytes $expectedSigBytes
    if ($expectedSigB64 -ne $parts[2]) {
        throw [System.Security.SecurityException]"Invalid token: signature verification failed."
    }

    # 4. Decode payload
    $payloadJson = [System.Text.Encoding]::UTF8.GetString((ConvertFrom-Base64Url $parts[1]))
    $payload     = $payloadJson | ConvertFrom-Json

    # 5. Validate audience
    $audMatch = ($payload.aud -is [array] -and $payload.aud -contains $script:JwtAudience) `
             -or ($payload.aud -eq $script:JwtAudience)
    if (-not $audMatch) {
        throw [System.Security.SecurityException]"Invalid token: audience mismatch."
    }

    # 6. Validate issuer
    if ($payload.iss -ne $script:JwtIssuer) {
        throw [System.Security.SecurityException]"Invalid token: issuer mismatch."
    }

    # 7. Validate expiry
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($payload.exp -le $now) {
        throw [System.Security.SecurityException]"Token has expired."
    }

    # 8. Validate required payload fields
    if (-not $payload.id -or -not $payload.role) {
        throw [System.Security.SecurityException]"Invalid token: payload is missing required fields."
    }

    # 9. Parse role
    $role = [UserRole]($payload.role.Substring(0,1).ToUpper() + $payload.role.Substring(1))

    # 10. Parse permissions (fall back to role defaults if absent)
    $permissions = if ($payload.permissions) {
        @($payload.permissions | ForEach-Object {
            [Permission]($_.Substring(0,1).ToUpper() + $_.Substring(1).Replace(':',''))
        })
    } else {
        Get-PermissionsForRole -Role $role
    }

    return [AuthenticatedUser]::new($payload.id, $role, $permissions)
}

# ---------------------------------------------------------------------------
# Quick smoke test
# ---------------------------------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    Write-Host "=== JWT Service smoke test ===" -ForegroundColor Cyan

    # Set required env vars for the test run
    $env:MCP_JWT_SECRET   = 'super-secret-dev-key-change-in-production-32bytes!'
    $env:MCP_JWT_AUDIENCE = 'https://mcp.example.com'
    $env:MCP_JWT_ISSUER   = 'https://auth.example.com'
    $env:MCP_JWT_EXPIRY   = '300'

    # Re-load config for this test session
    $script:JwtSecret   = $env:MCP_JWT_SECRET
    $script:JwtAudience = $env:MCP_JWT_AUDIENCE
    $script:JwtIssuer   = $env:MCP_JWT_ISSUER
    $script:JwtExpiry   = 300

    $token = New-JwtToken -UserId 'u001' -Role ([UserRole]::Admin)
    Write-Host "Generated token (truncated): $($token.Substring(0,40))..."

    $user = Test-JwtToken -Token $token
    Write-Host "Verified user: id=$($user.Id), role=$($user.Role)"
    Write-Host "Permissions: $($user.Permissions -join ', ')"

    # Test tamper detection
    $tampered = $token.Substring(0, $token.Length - 4) + 'XXXX'
    try {
        Test-JwtToken -Token $tampered
        Write-Host "ERROR: Tampered token was accepted!" -ForegroundColor Red
    } catch {
        Write-Host "Tamper detection: PASS ($($_.Exception.Message))" -ForegroundColor Green
    }
}
