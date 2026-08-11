#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication
# Version: 1.0.0
<#
.SYNOPSIS
    Group-based access for the Exchange Archive MCP + self-service request flow.

.DESCRIPTION
    Follow-on to Tighten-AppRegistration.ps1 (which required user assignment and
    seeded individual users). This script moves access to a GROUP so people who
    are not on the list can REQUEST access instead of just hitting AADSTS50105:

      1. Ensure the security group exists (default: SG-Exchange-Archive-MCP-Users).
      2. Ensure the approved roster are members.
      3. Assign the GROUP to the enterprise app (keeps individual user
         assignments in place unless -RemoveIndividualAssignments).
      4. Print the one portal-only step Graph does not expose: enabling
         self-service app access (Enterprise app > Self-service), which lets
         non-members request access from https://myapps.microsoft.com with
         approval routed to the designated approver(s).

    Idempotent; supports -WhatIf; mutations logged with timestamp + actor UPN.
    Transcript saved to foundry-mcp\logs\.

    Graph scopes (delegated, interactive browser - never device code):
    Group.ReadWrite.All, AppRoleAssignment.ReadWrite.All, User.Read.All

.EXAMPLE
    .\Enable-McpAccessRequests.ps1
.EXAMPLE
    # After verifying group-based sign-in works, drop the per-user entries:
    .\Enable-McpAccessRequests.ps1 -RemoveIndividualAssignments
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$AppId     = '9519ca68-dae2-4add-8309-4bdd1fa45e79',
    [string]$TenantId  = '9c1b0b26-717a-4eda-9d7e-7eebc00066bf',
    [string]$GroupName = 'SG-Exchange-Archive-MCP-Users',
    [string[]]$Members = @(
        'jmonaco@gipartners.com'
        'super-jmonaco@gipartners.com'
        'xtsai@gipartners.com'
        'egordon@gipartners.com'
        'dfishbaum@gipartners.com'
        'dave@gipartners.com'
        'jeff@gipartners.com'
        'sandesh@gipartners.com'
    ),
    # Once group sign-in is verified, re-run with this to remove the interim
    # per-user assignments created by Tighten-AppRegistration.ps1.
    [switch]$RemoveIndividualAssignments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogDir = Join-Path $PSScriptRoot '..\logs'
if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
$script:LogPath = Join-Path (Resolve-Path $script:LogDir).Path ("mcp-access-requests-{0}.log" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
Start-Transcript -Path $script:LogPath | Out-Null
Write-Host "Logging this run to: $script:LogPath" -ForegroundColor DarkGray

$defaultRoleId = '00000000-0000-0000-0000-000000000000'
$issues = [System.Collections.Generic.List[string]]::new()
function Ok   ([string]$m) { Write-Host "[OK] $m" -ForegroundColor Green }
function Bad  ([string]$m) { Write-Host "[!!] $m" -ForegroundColor Red; [void]$issues.Add($m) }
function Info ([string]$m) { Write-Host "     $m" -ForegroundColor Yellow }
function Write-MutationLog ([string]$Action) {
    $actor = (Get-MgContext).Account
    Write-Host ("     {0}  MUTATE  actor={1}  {2}" -f (Get-Date).ToUniversalTime().ToString('o'), $actor, $Action) -ForegroundColor DarkGray
}

Write-Host 'Connecting to Microsoft Graph...' -ForegroundColor Cyan
Connect-MgGraph -TenantId $TenantId -Scopes 'Group.ReadWrite.All','AppRoleAssignment.ReadWrite.All','User.Read.All' -NoWelcome

try {
    $appFilter = [Uri]::EscapeDataString("appId eq '$AppId'")
    $sp = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$appFilter" -OutputType PSObject).value)[0]
    if (-not $sp) { throw "Service principal for $AppId not found." }
    Ok "$($sp.displayName) (SP $($sp.id))"

    # ── 1. Ensure the group ───────────────────────────────────────────────────
    Write-Host "`n=== 1. Security group '$GroupName' ===" -ForegroundColor Cyan
    $gFilter = [Uri]::EscapeDataString("displayName eq '$GroupName'")
    $group = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$gFilter" -OutputType PSObject).value)[0]
    if ($group) {
        Ok "group exists (id $($group.id))"
    } elseif ($PSCmdlet.ShouldProcess('directory', "create security group $GroupName")) {
        Write-MutationLog "POST /groups create $GroupName"
        $group = (Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/groups' -Body (@{
            displayName     = $GroupName
            description     = 'Approved users of the Exchange Archive MCP connector. Membership grants sign-in (enterprise app requires assignment). Self-service requests route through this group.'
            mailEnabled     = $false
            mailNickname    = ($GroupName.ToLower() -replace '[^a-z0-9-]', '')
            securityEnabled = $true
        } | ConvertTo-Json) -ContentType 'application/json' -OutputType PSObject)
        Ok "group created (id $($group.id))"
    }

    # ── 2. Ensure members ─────────────────────────────────────────────────────
    Write-Host "`n=== 2. Group membership ===" -ForegroundColor Cyan
    $memberIds = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)/members?`$select=id,userPrincipalName&`$top=999" -OutputType PSObject).value)
    foreach ($upn in $Members) {
        $u = $null
        try {
            $u = @((Invoke-MgGraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/users?`$filter=" + [Uri]::EscapeDataString("userPrincipalName eq '$upn'") + '&$select=id') -OutputType PSObject).value)[0]
            if (-not $u) { throw 'not found in tenant' }
        } catch { Bad "member ${upn}: $($_.Exception.Message)"; continue }
        if (@($memberIds | Where-Object { $_.id -eq $u.id }).Count -gt 0) {
            Ok "member: $upn (already)"
        } elseif ($PSCmdlet.ShouldProcess($GroupName, "add member $upn")) {
            Write-MutationLog "POST groups/$($group.id)/members/`$ref add $upn"
            Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/groups/$($group.id)/members/`$ref" `
                -Body (@{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($u.id)" } | ConvertTo-Json) -ContentType 'application/json' | Out-Null
            Ok "member added: $upn"
        }
    }

    # ── 3. Assign the group to the enterprise app ─────────────────────────────
    Write-Host "`n=== 3. Group assignment to the app ===" -ForegroundColor Cyan
    $assigned = @((Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignedTo?`$top=999" -OutputType PSObject).value)
    if (@($assigned | Where-Object { $_.principalId -eq $group.id }).Count -gt 0) {
        Ok 'group already assigned to the app'
    } elseif ($PSCmdlet.ShouldProcess('enterprise app', "assign group $GroupName")) {
        Write-MutationLog "POST appRoleAssignedTo: group $GroupName (default role)"
        Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignedTo" `
            -Body (@{ principalId = $group.id; resourceId = $sp.id; appRoleId = $defaultRoleId } | ConvertTo-Json) -ContentType 'application/json' | Out-Null
        Ok 'group assigned to the app'
    }

    if ($RemoveIndividualAssignments) {
        Write-Host "`n=== 3b. Remove interim per-user assignments ===" -ForegroundColor Cyan
        $userAssignments = @($assigned | Where-Object { $_.principalType -eq 'User' })
        if (-not $userAssignments.Count) { Ok 'no individual user assignments present' }
        foreach ($a in $userAssignments) {
            if ($PSCmdlet.ShouldProcess('enterprise app', "remove user assignment $($a.principalDisplayName)")) {
                Write-MutationLog "DELETE appRoleAssignedTo $($a.id) (user $($a.principalDisplayName))"
                Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignedTo/$($a.id)" | Out-Null
                Ok "removed individual assignment: $($a.principalDisplayName)"
            }
        }
    } else {
        Info 'Individual user assignments left in place. After verifying a group member can sign in,'
        Info 're-run with -RemoveIndividualAssignments to finish the migration to group-based access.'
    }

    # ── 4. Portal-only step: self-service app access ──────────────────────────
    Write-Host "`n=== 4. Self-service access requests (portal-only — Graph has no public API) ===" -ForegroundColor Cyan
    Info 'Entra portal > Enterprise applications > Exchange Archive MCP > Self-service:'
    Info '  - Allow users to request access to this application?  Yes'
    Info "  - To which group should assigned users be added?      $GroupName"
    Info '  - Who is allowed to approve access requests?          jmonaco (add others as desired)'
    Info '  - Require approval before granting access?            Yes'
    Info 'After enabling: users NOT in the group who need access request it at'
    Info 'https://myapps.microsoft.com  (+ Request new apps) — approvals add them to the group.'
    Info 'Point anyone who hits the "not assigned" sign-in error (AADSTS50105) there.'

    Write-Host ''
    if ($issues.Count -eq 0) { Write-Host 'ALL STEPS APPLIED / VERIFIED (one portal step above remains manual).' -ForegroundColor Green }
    else {
        Write-Host "PROBLEMS ($($issues.Count)):" -ForegroundColor Red
        for ($i = 0; $i -lt $issues.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $issues[$i]) -ForegroundColor Red }
    }
}
finally {
    if (Get-MgContext) { Disconnect-MgGraph | Out-Null; Write-Host 'Disconnected from Microsoft Graph.' -ForegroundColor DarkGray }
    Write-Host "`nLog saved to: $script:LogPath" -ForegroundColor Cyan
    Stop-Transcript | Out-Null
}
