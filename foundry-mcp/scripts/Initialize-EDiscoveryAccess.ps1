# Version: 1.0.2
# Initialize-EDiscoveryAccess.ps1 — one-time setup for the eDiscovery data path
# (ARCHIVE-DATA-PATH-PLAN.md §6, items 1-2 and 4).
#
# RUN IN WINDOWS POWERSHELL 5.1 ("powershell.exe") — Connect-IPPSSession uses the
# ExchangeOnlineManagement module, whose WAM broker crashes under PowerShell 7 on
# this machine. Sign in as super-jmonaco@gipartners.com at every prompt.
# Required roles: Cloud Application Administrator (Entra) + Role Management (Purview).
#
# What it does (idempotent — re-running converges):
#   1. Graph app-role assignments on the MCP app's service principal:
#        - Microsoft Graph: eDiscovery.Read.All + eDiscovery.ReadWrite.All (application)
#        - MicrosoftPurviewEDiscovery: eDiscovery.Download.Read (application)
#      (creating an appRoleAssignment IS the admin consent for app roles)
#   2. Ensures the first-party MicrosoftPurviewEDiscovery service principal exists
#      (appId b26e684c-5068-4120-a679-64a5d2c909d9 — required for export downloads)
#   3. Purview service principal + eDiscovery Manager role-group membership
#      (Security & Compliance PowerShell: New-ServicePrincipal / Add-RoleGroupMember)
#   4. Creates the standing eDiscovery case "Exchange Archive MCP - delegated reads"
#      (skipped if one with that name exists) and prints its id.
#
# MANUAL STEPS it cannot do:
#   - Enable Purview pay-as-you-go billing for eDiscovery APIs (Purview portal →
#     Settings → Billing). 50 GB/month free tier; searches/estimates are the hot path.
#   - Put the printed case id into the Function App setting EDISCOVERY_CASE_ID
#     (the script prints the az command to run).
#
# PS 5.1-compatible syntax throughout.

param(
    [string]$TenantId  = '9c1b0b26-717a-4eda-9d7e-7eebc00066bf',
    [string]$McpAppId  = '9519ca68-dae2-4add-8309-4bdd1fa45e79',
    [string]$CaseName  = 'Exchange Archive MCP - delegated reads'
)

# Self-enforce Windows PowerShell 5.1: Connect-IPPSSession's WAM broker throws
# NullReferenceException under PowerShell 7 on this machine. Relaunch instead of
# relying on the operator remembering which shell to use.
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    Write-Host 'PowerShell 7 detected - relaunching under Windows PowerShell 5.1 (EXO WAM broker crashes on PS7)...' -ForegroundColor Yellow
    $ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    foreach ($k in $PSBoundParameters.Keys) { $argList += @("-$k", [string]$PSBoundParameters[$k]) }
    & $ps51 @argList
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Stop'
$PurviewEDiscoveryAppId = 'b26e684c-5068-4120-a679-64a5d2c909d9'

foreach ($m in @('Microsoft.Graph.Authentication', 'ExchangeOnlineManagement')) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        throw "Required module '$m' is not installed. Install-Module $m -Scope CurrentUser"
    }
}

function Ok  ($t) { Write-Host "  [PASS] $t" -ForegroundColor Green }
function Info($t) { Write-Host "  [info] $t" -ForegroundColor DarkGray }

$logDir  = Join-Path $PSScriptRoot '..\logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ('ediscovery-init-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
function Write-MutationLog ($action) {
    ('{0:o}  {1}' -f (Get-Date), $action) | Add-Content -Path $logFile
}

function Get-GraphHash ($Uri) { Invoke-MgGraphRequest -Method GET -Uri $Uri }

try {
    # ── 1. Graph connection (admin, interactive browser) ──────────────────────
    Write-Host "`n=== 1. Graph sign-in (super-jmonaco) ===" -ForegroundColor Cyan
    # eDiscovery.ReadWrite.All is needed in THIS delegated token too — the
    # standing-case calls in section 5 hit /security/cases with it.
    Connect-MgGraph -TenantId $TenantId -Scopes 'Application.ReadWrite.All,AppRoleAssignment.ReadWrite.All,eDiscovery.ReadWrite.All' -NoWelcome

    # Resolve the three service principals we need.
    function Get-SpByAppId ($AppId) {
        $r = Get-GraphHash ("https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$AppId'")
        if ($r['value'].Count -gt 0) { return $r['value'][0] }
        return $null
    }

    $mcpSp   = Get-SpByAppId $McpAppId
    if (-not $mcpSp) { throw "No service principal for MCP app $McpAppId" }
    $graphSp = Get-SpByAppId '00000003-0000-0000-c000-000000000000'

    # ── 2. MicrosoftPurviewEDiscovery first-party SP ──────────────────────────
    Write-Host "`n=== 2. MicrosoftPurviewEDiscovery service principal ===" -ForegroundColor Cyan
    $pvSp = Get-SpByAppId $PurviewEDiscoveryAppId
    if ($pvSp) { Ok 'Already registered.' }
    else {
        Write-MutationLog "Create service principal for MicrosoftPurviewEDiscovery ($PurviewEDiscoveryAppId)"
        $pvSp = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals' `
                    -Body (@{ appId = $PurviewEDiscoveryAppId } | ConvertTo-Json) -ContentType 'application/json'
        Ok 'Registered.'
    }

    # ── 3. App-role assignments (this IS the admin consent) ───────────────────
    Write-Host "`n=== 3. Application permissions on the MCP service principal ===" -ForegroundColor Cyan
    $existing = (Get-GraphHash "https://graph.microsoft.com/v1.0/servicePrincipals/$($mcpSp['id'])/appRoleAssignments")['value']

    function Grant-AppRole ($ResourceSp, $RoleValue) {
        $role = $ResourceSp['appRoles'] | Where-Object { $_['value'] -eq $RoleValue -and $_['isEnabled'] }
        if (-not $role) { throw "Role '$RoleValue' not found on $($ResourceSp['displayName'])" }
        $already = $existing | Where-Object { $_['resourceId'] -eq $ResourceSp['id'] -and $_['appRoleId'] -eq $role['id'] }
        if ($already) { Ok "$($ResourceSp['displayName']) / $RoleValue already granted."; return }
        Write-MutationLog "Grant app role $RoleValue on $($ResourceSp['displayName']) to MCP SP"
        $body = @{ principalId = $mcpSp['id']; resourceId = $ResourceSp['id']; appRoleId = $role['id'] } | ConvertTo-Json
        Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($mcpSp['id'])/appRoleAssignments" `
            -Body $body -ContentType 'application/json' | Out-Null
        Ok "$($ResourceSp['displayName']) / $RoleValue granted."
    }

    Grant-AppRole $graphSp 'eDiscovery.Read.All'
    Grant-AppRole $graphSp 'eDiscovery.ReadWrite.All'
    Grant-AppRole $pvSp    'eDiscovery.Download.Read'

    # ── 4. Purview service principal + eDiscovery Manager membership ──────────
    Write-Host "`n=== 4. Purview role assignment (Security & Compliance PowerShell) ===" -ForegroundColor Cyan
    Connect-IPPSSession -ShowBanner:$false
    try {
        $pvPrincipal = Get-ServicePrincipal | Where-Object { $_.AppId -eq $McpAppId } | Select-Object -First 1
        if ($pvPrincipal) { Ok 'Purview service principal already exists.' }
        else {
            Write-MutationLog "New-ServicePrincipal AppId=$McpAppId ObjectId=$($mcpSp['id'])"
            $pvPrincipal = New-ServicePrincipal -AppId $McpAppId -ObjectId $mcpSp['id'] -DisplayName 'Exchange Archive MCP'
            Ok 'Purview service principal created.'
        }

        # The NAME 'eDiscoveryManager' resolves ambiguously in this tenant
        # (ManagementObjectAmbiguousException, observed 2026-07-22) — always
        # address the role group by its GUID. Also: EXO cmdlet errors are
        # non-terminating even under EAP Stop, so verify membership by
        # re-reading AFTER the add instead of trusting the cmdlet.
        $rgs = @(Get-RoleGroup -ErrorAction Stop | Where-Object { ($_.Name -replace '\s','') -ieq 'eDiscoveryManager' })
        if ($rgs.Count -eq 0) { throw 'Could not find the eDiscovery Manager role group (Get-RoleGroup).' }
        if ($rgs.Count -gt 1) {
            Info ("Multiple role groups match: {0} - using the first by GUID." -f (($rgs | ForEach-Object { "$($_.Name) [$($_.Guid)]" }) -join '; '))
        }
        $rg = $rgs[0]
        $rgGuid = $rg.Guid.ToString()

        function Test-RgMembership {
            $mm = @(Get-RoleGroupMember -Identity $rgGuid -ErrorAction Stop)
            foreach ($m in $mm) {
                if ($m.DisplayName -eq 'Exchange Archive MCP') { return $true }
                if ($m.Name -eq $pvPrincipal.Name) { return $true }
            }
            return $false
        }

        if (Test-RgMembership) { Ok "Already a member of '$($rg.Name)' [$rgGuid]." }
        else {
            Write-MutationLog "Add-RoleGroupMember $rgGuid member=$($pvPrincipal.ObjectId)"
            Add-RoleGroupMember -Identity $rgGuid -Member $pvPrincipal.ObjectId -ErrorAction Stop
            if (Test-RgMembership) { Ok "Added to '$($rg.Name)' [$rgGuid] - membership VERIFIED by re-read." }
            else { throw "Add-RoleGroupMember reported no error but membership does not show on re-read - inspect role group '$($rg.Name)' [$rgGuid] in the Purview portal." }
        }
    }
    finally {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }

    # ── 5. Standing eDiscovery case ───────────────────────────────────────────
    Write-Host "`n=== 5. Standing case ===" -ForegroundColor Cyan
    $cases = (Get-GraphHash "https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases?`$top=100")['value']
    $case = $cases | Where-Object { $_['displayName'] -eq $CaseName } | Select-Object -First 1
    if ($case) { Ok "Case exists: $($case['id'])" }
    else {
        Write-MutationLog "Create eDiscovery case '$CaseName'"
        $body = @{ displayName = $CaseName; description = 'Standing case for per-user archive reads by the Exchange Archive MCP. Searches are created per tool call, scoped server-side to the verified caller.' } | ConvertTo-Json
        $case = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases' `
                    -Body $body -ContentType 'application/json'
        Ok "Case created: $($case['id'])"
    }

    Write-Host "`n=== Done. Finish with these manual steps ===" -ForegroundColor Cyan
    Write-Host "  1. Enable Purview PAYG billing (Purview portal -> Settings -> Billing) if not already on."
    Write-Host "  2. Set the case id on the Function App:"
    Write-Host ("     az functionapp config appsettings set -g finresgroup -n func-exchange-mcp-archive-mailbox-mcp --settings EDISCOVERY_CASE_ID={0}" -f $case['id'])
    Write-Host "  Mutation log: $logFile"
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}
