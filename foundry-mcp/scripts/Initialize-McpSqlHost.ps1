#Requires -Version 7.0
<#
.SYNOPSIS
    Provision (and verify) the shared Azure SQL host for MCP data stores.

.DESCRIPTION
    One logical server, one database per MCP. Deployed independently of any
    single MCP's azd pipeline because its lifecycle is shared.

    What it does, idempotently:
      1. Preflight: az + sqlcmd present, Azure session LIVE (not just cached).
      2. Resolve the Entra admin principal (group preferred, signed-in user
         otherwise) and the operator's public IP for the firewall allowlist.
      3. Deploy infra/modules/sqlhost.bicep — Entra-only auth, always-on tier.
      4. Verify server + databases server-side via ARM.
      5. Grant database access as CONTAINED USERS: the Function App's managed
         identity and the human access group. Uses SID-based CREATE USER, which
         does NOT require the server identity to hold Directory Readers.
      6. Prove connectivity by running an actual query as the caller.

    Re-running after success prints all [OK] and changes nothing.
    -VerifyOnly checks everything and mutates nothing (exit 1 on problems).
    -AddDatabase adds another database to the existing server for the next MCP.

    RUNNING THIS AGAINST A HAND-CREATED SERVER: the deployment is declarative,
    so it CONVERGES the server to this template -- it will turn Entra-only auth
    ON, set the Entra admin to the resolved principal, and align each listed
    database to -Sku/-Tier/-Capacity. If the server was set up by hand with
    different settings, run -VerifyOnly FIRST and read the inventory before
    letting the deployment reshape it.

    COST: the default Standard S0 tier bills continuously (it is always-on by
    design -- serverless auto-pause would reintroduce the resume delay this
    host exists to avoid). Confirm current pricing in the portal before the
    first run; change with -Sku/-Tier/-Capacity.

.EXAMPLE
    # Inventory an existing server without touching it (do this first)
    .\Initialize-McpSqlHost.ps1 -VerifyOnly

.EXAMPLE
    # First run (admin defaults to the signed-in user)
    .\Initialize-McpSqlHost.ps1

.EXAMPLE
    # Preferred: an Entra GROUP owns the server, so ownership outlives any person
    .\Initialize-McpSqlHost.ps1 -ServerName sql-gipartners-mcp -AdminGroup 'SG-SQL-Admins'

.EXAMPLE
    # Add the next MCP's database to the existing server
    .\Initialize-McpSqlHost.ps1 -ServerName sql-gipartners-mcp -AddDatabase 'TeamsIndex'

.EXAMPLE
    .\Initialize-McpSqlHost.ps1 -ServerName sql-gipartners-mcp -VerifyOnly
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]   $ServerName     = 'gip-mcp-hub-sql',
    [string]   $ResourceGroup  = 'finresgroup',
    [string]   $SubscriptionId = 'db17a4a4-f677-498a-b4a2-eb401ba9cf29',
    [string]   $TenantId       = '9c1b0b26-717a-4eda-9d7e-7eebc00066bf',
    [string]   $Location       = 'eastus',

    [string[]] $Databases      = @('ArchiveIndex'),
    [string]   $AddDatabase,
    [string]   $Sku            = 'S0',
    [string]   $Tier           = 'Standard',
    [int]      $Capacity       = 10,

    # Server admin. A GROUP is preferred; omit to use the signed-in user.
    [string]   $AdminGroup,
    # Humans who may READ the databases (the MCP access group by default).
    [string]   $ReaderGroup    = 'SG-Exchange-Archive-MCP-Users',
    # The Function App's user-assigned identity -- future MCPs read/write as this.
    # Client id observed in production traces (ManagedIdentityCredential lines in
    # App Insights); resolved to its real name at run time, name is only a label.
    [string]   $FunctionIdentityClientId = 'e408783c-42f9-4ac9-979f-038d8d35dbca',
    [string]   $FunctionIdentityName,

    [string]   $ClientIp,
    [switch]   $VerifyOnly
)

$version = '1.3.0'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogDir = Join-Path $PSScriptRoot '..\logs'
if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
$script:LogPath = Join-Path (Resolve-Path $script:LogDir).Path ("mcp-sql-host-{0}.log" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
Start-Transcript -Path $script:LogPath | Out-Null

$script:Issues = [System.Collections.Generic.List[string]]::new()
function Step ([string]$m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Ok   ([string]$m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Bad  ([string]$m) { Write-Host "  [!!] $m" -ForegroundColor Red; [void]$script:Issues.Add($m) }
function Info ([string]$m) { Write-Host "  $m" -ForegroundColor Yellow }
function Mutate ([string]$m) {
    Write-Host ("  {0}  MUTATE  {1}" -f (Get-Date).ToUniversalTime().ToString('o'), $m) -ForegroundColor DarkGray
}

Write-Host "Initialize-McpSqlHost $version" -ForegroundColor Cyan
Write-Host "Log: $script:LogPath" -ForegroundColor DarkGray

try {
    # ── 1. Preflight ──────────────────────────────────────────────────────────
    Step '1. Preflight'
    foreach ($tool in 'az', 'sqlcmd') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool not found on PATH." }
    }
    Ok 'az and sqlcmd present'

    $acct = az account show -o json 2>$null | ConvertFrom-Json
    if (-not $acct) { az login --tenant $TenantId --output none; $acct = az account show -o json | ConvertFrom-Json }
    if ($acct.id -ne $SubscriptionId) { az account set --subscription $SubscriptionId }
    # Cached CLI sessions pass `account show` while every real call fails under
    # the 4h Conditional Access sign-in frequency -- probe with a real token.
    # sweep:auth-probe -- a token for management.azure.com does NOT prove the
    # CLI's other ARM audience is still valid: on 2026-08-14 this probe passed
    # and the next call failed AADSTS70043. Probe with a real read instead.
    $null = az group show -n $ResourceGroup -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        Info 'cached session stale (CA sign-in frequency) - re-authenticating'
        az logout 2>$null; az login --tenant $TenantId --output none; az account set --subscription $SubscriptionId
    }
    $me = az ad signed-in-user show -o json 2>$null | ConvertFrom-Json
    if (-not $me) {
        # ARM and Graph tokens go stale independently: one clean re-login, then fail loudly.
        Info 'Graph token stale - one clean re-login'
        az logout 2>$null; az login --tenant $TenantId --output none; az account set --subscription $SubscriptionId
        $me = az ad signed-in-user show -o json 2>$null | ConvertFrom-Json
        if (-not $me) { throw 'Could not resolve the signed-in user from Graph; cannot proceed with an unresolved identity.' }
    }
    Ok "signed in as $($me.userPrincipalName)"

    # ── 2. Resolve admin principal + client IP ────────────────────────────────
    Step '2. Admin principal and firewall source'
    if ($AdminGroup) {
        $grp = az ad group show --group $AdminGroup -o json 2>$null | ConvertFrom-Json
        if (-not $grp) { throw "Entra group '$AdminGroup' not found." }
        $adminLogin = $grp.displayName; $adminObjectId = $grp.id; $adminType = 'Group'
        Ok "server admin: GROUP $adminLogin ($adminObjectId)"
    } else {
        $adminLogin = $me.userPrincipalName; $adminObjectId = $me.id; $adminType = 'User'
        Ok "server admin: USER $adminLogin"
        Info 'A group admin is more durable than a person - consider -AdminGroup on the next run (it is idempotent).'
    }

    if (-not $ClientIp) {
        # Direct HTTPS from pwsh is blocked by egress filtering on this network,
        # but az is allowed -- borrow it to reach the echo service.
        $ipRaw = az rest --method get --skip-authorization-header --url 'https://api.ipify.org?format=json' -o json 2>$null
        if ($LASTEXITCODE -eq 0 -and $ipRaw) { $ClientIp = ($ipRaw | ConvertFrom-Json).ip }
    }
    if ($ClientIp) { Ok "client IP for firewall allowlist: $ClientIp" }
    else { Info 'could not determine the public IP - pass -ClientIp to add a workstation firewall rule' }

    # ── 3. Deploy ─────────────────────────────────────────────────────────────
    Step '3. Deploy sqlhost.bicep'
    $template = (Resolve-Path (Join-Path $PSScriptRoot '..\infra\modules\sqlhost.bicep')).Path
    $dbList = @($Databases)
    if ($AddDatabase -and $dbList -notcontains $AddDatabase) { $dbList += $AddDatabase }

    $dbObjects = @($dbList | ForEach-Object {
        @{ name = $_; sku = $Sku; tier = $Tier; capacity = $Capacity; maxSizeBytes = 268435456000 }
    })
    $fwRules = @()
    if ($ClientIp) { $fwRules += @{ name = "operator-$($ClientIp -replace '\.', '-')"; startIp = $ClientIp; endIp = $ClientIp } }

    if ($VerifyOnly) {
        Info 'VerifyOnly: skipping deployment'
    } elseif ($PSCmdlet.ShouldProcess("$ResourceGroup/$ServerName", "deploy Azure SQL host ($($dbList -join ', '))")) {
        $paramFile = Join-Path $env:TEMP ("sqlhost-params-{0}.json" -f (New-Guid).Guid.Substring(0, 8))
        $paramBody = @{
            '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
            contentVersion = '1.0.0.0'
            parameters     = @{
                serverName          = @{ value = $ServerName }
                location            = @{ value = $Location }
                databases           = @{ value = $dbObjects }
                adminLogin          = @{ value = $adminLogin }
                adminObjectId       = @{ value = $adminObjectId }
                adminPrincipalType  = @{ value = $adminType }
                clientFirewallRules = @{ value = $fwRules }
                allowAzureServices  = @{ value = $true }
            }
        }
        try {
            $paramBody | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $paramFile -Encoding utf8
            Mutate "az deployment group create -g $ResourceGroup --template-file sqlhost.bicep (databases: $($dbList -join ', '))"
            az deployment group create -g $ResourceGroup --template-file $template --parameters "@$paramFile" `
                --name ("mcp-sqlhost-{0}" -f (Get-Date).ToString('yyyyMMddHHmmss')) -o none
            if ($LASTEXITCODE -ne 0) { throw 'ARM deployment failed - see the error above.' }
            Ok 'deployment completed'
        } finally { Remove-Item $paramFile -Force -ErrorAction SilentlyContinue }
    }

    # ── 4. Verify server + databases via ARM ─────────────────────────────────
    Step '4. Verify server and databases'
    $srv = az sql server show -g $ResourceGroup -n $ServerName -o json 2>$null | ConvertFrom-Json
    if (-not $srv) { Bad "server $ServerName not found in $ResourceGroup"; throw 'Cannot verify further without the server.' }
    $fqdn = $srv.fullyQualifiedDomainName
    Ok "server: $fqdn (state $($srv.state))"

    $adOnly = az sql server ad-only-auth get -g $ResourceGroup -n $ServerName -o json 2>$null | ConvertFrom-Json
    if ($adOnly -and $adOnly.azureAdOnlyAuthentication) { Ok 'Entra-only authentication: enabled (no SQL logins)' }
    else { Bad 'Entra-only authentication is NOT enabled - SQL password logins are possible' }

    $existing = @(az sql db list -g $ResourceGroup -s $ServerName --query "[?name!='master'].{name:name,sku:sku.name,status:status}" -o json 2>$null | ConvertFrom-Json)
    foreach ($want in $dbList) {
        $found = $existing | Where-Object { $_.name -eq $want } | Select-Object -First 1
        if ($found) { Ok "database: $($found.name) ($($found.sku), $($found.status))" } else { Bad "database MISSING: $want" }
    }

    # ── 5. Database access as contained users ────────────────────────────────
    Step '5. Database access (contained users)'
    # SID-based CREATE USER: deterministic and does NOT require the SQL server's
    # identity to hold the Directory Readers role, which FROM EXTERNAL PROVIDER
    # would. TYPE = E for users/apps/managed identities, X for groups.
    function ConvertTo-SqlSid([string]$ObjectId) {
        $bytes = ([guid]$ObjectId).ToByteArray()
        return '0x' + (($bytes | ForEach-Object { $_.ToString('X2') }) -join '')
    }

    $grants = @()
    # Resolve the identity by CLIENT ID across the subscription -- it need not
    # live in this resource group, and guessing its name does not work (the
    # 2026-08-14 inventory run missed it that way). The name is only a label:
    # Azure SQL maps an incoming token to a database principal by SID, and for a
    # managed identity / app that SID derives from the CLIENT id, not the object
    # id (groups are the opposite -- object id, TYPE = X).
    $uai = $null
    if ($FunctionIdentityClientId) {
        $uai = az identity list --query "[?clientId=='$FunctionIdentityClientId'] | [0]" -o json 2>$null | ConvertFrom-Json
    }
    if (-not $uai -and $FunctionIdentityName) {
        $uai = az identity list --query "[?name=='$FunctionIdentityName'] | [0]" -o json 2>$null | ConvertFrom-Json
    }
    if ($uai) {
        $FunctionIdentityClientId = $uai.clientId
        if (-not $FunctionIdentityName) { $FunctionIdentityName = $uai.name }
        Ok "managed identity resolved: $FunctionIdentityName (client $FunctionIdentityClientId, rg $($uai.resourceGroup))"
    } elseif ($FunctionIdentityClientId) {
        if (-not $FunctionIdentityName) { $FunctionIdentityName = "mi-$($FunctionIdentityClientId.Substring(0,8))" }
        Info "identity object not found via az, but the client id was supplied - granting by SID as '$FunctionIdentityName'"
    }
    if ($FunctionIdentityClientId) {
        $grants += @{ Name = $FunctionIdentityName; Sid = (ConvertTo-SqlSid $FunctionIdentityClientId); Type = 'E'
                      Roles = @('db_datareader', 'db_datawriter'); What = 'Function App managed identity (MCP read/write)' }
    } else {
        Info 'no managed identity resolved - pass -FunctionIdentityClientId to grant one'
        Info ('identities in the subscription: ' + ((az identity list --query '[].name' -o tsv 2>$null) -join ', '))
    }
    if ($ReaderGroup) {
        $rg = az ad group show --group $ReaderGroup -o json 2>$null | ConvertFrom-Json
        if ($rg) {
            $grants += @{ Name = $rg.displayName; Sid = (ConvertTo-SqlSid $rg.id); Type = 'X'
                          Roles = @('db_datareader'); What = 'human access group (read-only)' }
        } else { Info "reader group '$ReaderGroup' not found - skipping" }
    }

    # Connect with an ACCESS TOKEN from the az session, not sqlcmd -G.
    # sqlcmd 15 / ODBC 17 with -G alone means ActiveDirectoryIntegrated, which
    # requires a federated or Entra-joined machine; on this AD-domain-joined
    # workstation it fails with 0xCAA9001F "Integrated Windows authentication
    # supported only in federation flow" (seen 2026-08-14). -G -U would prompt
    # a browser per invocation. System.Data.SqlClient accepts a bearer token
    # directly, so the az session already validated in step 1 carries through
    # with no prompts and no extra modules. Bonus: parameter-free SQL never
    # touches a shell, so the quoting and codepage hazards vanish outright.
    $script:SqlAccessToken = $null
    function Get-SqlAccessToken {
        if (-not $script:SqlAccessToken) {
            $script:SqlAccessToken = az account get-access-token --resource 'https://database.windows.net/' --query accessToken -o tsv 2>$null
            if ($LASTEXITCODE -ne 0 -or -not $script:SqlAccessToken) {
                throw 'Could not obtain an Azure SQL access token from the az session.'
            }
        }
        return $script:SqlAccessToken
    }

    function Invoke-DbSql([string]$Database, [string]$Sql) {
        $conn = [System.Data.SqlClient.SqlConnection]::new(
            "Server=tcp:$fqdn,1433;Initial Catalog=$Database;Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;")
        $conn.AccessToken = Get-SqlAccessToken
        try {
            $conn.Open()
            $results = [System.Collections.Generic.List[string]]::new()
            # GO is a sqlcmd batch separator, not T-SQL -- split on it ourselves.
            foreach ($batch in ($Sql -split '(?im)^\s*GO\s*$')) {
                if (-not $batch.Trim()) { continue }
                $cmd = $conn.CreateCommand()
                $cmd.CommandText = $batch
                $cmd.CommandTimeout = 120
                $r = $cmd.ExecuteScalar()
                if ($null -ne $r) { [void]$results.Add([string]$r) }
                $cmd.Dispose()
            }
            return ($results -join "`n").Trim()
        } finally { $conn.Dispose() }
    }

    foreach ($db in $dbList) {
        if (-not ($existing | Where-Object { $_.name -eq $db })) { continue }
        foreach ($g in $grants) {
            $sql = @"
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$($g.Name)')
    CREATE USER [$($g.Name)] WITH SID = $($g.Sid), TYPE = $($g.Type);
$( ($g.Roles | ForEach-Object { "IF IS_ROLEMEMBER('$_', N'$($g.Name)') = 0 ALTER ROLE [$_] ADD MEMBER [$($g.Name)];" }) -join "`n" )
SELECT N'ok';
"@
            if ($VerifyOnly) {
                try {
                    $has = Invoke-DbSql $db "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.database_principals WHERE name = N'$($g.Name)';"
                    if ($has.Trim() -eq '1') { Ok "$db : $($g.Name) present - $($g.What)" } else { Bad "$db : $($g.Name) MISSING - $($g.What)" }
                } catch { Bad "$db : could not check $($g.Name) - $($_.Exception.Message)" }
            } elseif ($PSCmdlet.ShouldProcess("$db", "grant $($g.Roles -join '+') to $($g.Name)")) {
                try {
                    Mutate "CREATE USER/ALTER ROLE $($g.Name) on $db ($($g.Roles -join ', '))"
                    [void](Invoke-DbSql $db $sql)
                    Ok "$db : $($g.Name) -> $($g.Roles -join ', ')  [$($g.What)]"
                } catch { Bad "$db : granting $($g.Name) failed - $($_.Exception.Message)" }
            }
        }
    }

    # ── 6. Prove connectivity ────────────────────────────────────────────────
    Step '6. Connectivity (real query as the caller)'
    foreach ($db in $dbList) {
        if (-not ($existing | Where-Object { $_.name -eq $db })) { continue }
        try {
            $who = Invoke-DbSql $db 'SET NOCOUNT ON; SELECT SUSER_SNAME() + N'' @ '' + DB_NAME();'
            Ok "$db reachable as $who"
        } catch {
            Bad "$db unreachable: $($_.Exception.Message)"
            Info 'If this is a firewall error, re-run with -ClientIp <your public IP>.'
        }
    }

    Write-Host ''
    if ($script:Issues.Count -eq 0) {
        Write-Host 'ALL CHECKS GREEN' -ForegroundColor Green
        Write-Host ''
        Write-Host 'Point the archive loader at it by putting this in the repo-root .env:' -ForegroundColor Yellow
        Write-Host "  ARCHIVE_SQL_SERVER=$fqdn"                                             -ForegroundColor Yellow
        Write-Host '  ARCHIVE_SQL_DATABASE=ArchiveIndex'                                    -ForegroundColor Yellow
        Write-Host 'then run the loader with -SqlAuth Entra.'                               -ForegroundColor Yellow
    } else {
        Write-Host "PROBLEMS ($($script:Issues.Count)):" -ForegroundColor Red
        for ($i = 0; $i -lt $script:Issues.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $script:Issues[$i]) -ForegroundColor Red }
    }
}
catch {
    # sweep:error-logging -- a terminating error propagates PAST finally, so without this
    # it prints to the console only after Stop-Transcript has run and the log
    # ends with no reason recorded. Log it, then rethrow.
    Write-Host "  [!!] unhandled error: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo) { Write-Host "       at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" -ForegroundColor DarkGray }
    throw
}
finally {
    Write-Host "`nLog saved to: $script:LogPath" -ForegroundColor Cyan
    Stop-Transcript | Out-Null
}
if ($script:Issues.Count -gt 0) { exit 1 }
