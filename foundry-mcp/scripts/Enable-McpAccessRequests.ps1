#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication
# Version: 1.1.2
# 1.1.2: section 4e called Resolve-UserId, a helper that only exists in
#        Tighten-AppRegistration.ps1 — approver lookup now inlined.
# 1.1.1: retry the catalog resourceRequests adminAdd on
#        ResourceNotFoundInOriginSystem — entitlement management runs on a
#        separate backend that lags directory replication, so a group created
#        seconds earlier 400s until it propagates (observed live 2026-08-11).
# 1.1.0: the enterprise-app "Self-service" blade does NOT exist for custom OIDC
#        app registrations (gallery/SSO apps only) — replaced the portal step
#        with a fully scripted Identity Governance ACCESS PACKAGE: catalog +
#        group resource + package + request policy (any member may request,
#        jmonaco approves). Users request at https://myaccess.microsoft.com.
#        Requires Entra ID Governance / P2 licensing; license errors are
#        surfaced with a fallback path.
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
      4. Create the self-service request flow as an Identity Governance access
         package (catalog + group resource + package + policy): any tenant
         member can REQUEST access at https://myaccess.microsoft.com, the
         approver okays it, and approval adds them to the group. (The
         enterprise-app "Self-service" blade does not exist for custom OIDC
         apps; entitlement management is the supported equivalent and is
         fully Graph-scriptable.)

    Idempotent; supports -WhatIf; mutations logged with timestamp + actor UPN.
    Transcript saved to foundry-mcp\logs\.

    Graph scopes (delegated, interactive browser - never device code):
    Group.ReadWrite.All, AppRoleAssignment.ReadWrite.All, User.Read.All,
    EntitlementManagement.ReadWrite.All

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
Connect-MgGraph -TenantId $TenantId -Scopes 'Group.ReadWrite.All','AppRoleAssignment.ReadWrite.All','User.Read.All','EntitlementManagement.ReadWrite.All' -NoWelcome

try {
    $appFilter = [Uri]::EscapeDataString("appId eq '$AppId'")
    $sp = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$appFilter" -OutputType PSObject).value | Select-Object -First 1
    if (-not $sp) { throw "Service principal for $AppId not found." }
    Ok "$($sp.displayName) (SP $($sp.id))"

    # ── 1. Ensure the group ───────────────────────────────────────────────────
    Write-Host "`n=== 1. Security group '$GroupName' ===" -ForegroundColor Cyan
    $gFilter = [Uri]::EscapeDataString("displayName eq '$GroupName'")
    # NOTE: Select-Object -First 1, NOT @(...)[0] — under StrictMode, indexing an
    # empty result throws 'Index was outside the bounds of the array' (v1.0.0 bug).
    $group = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$gFilter" -OutputType PSObject).value | Select-Object -First 1
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
            $u = (Invoke-MgGraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/users?`$filter=" + [Uri]::EscapeDataString("userPrincipalName eq '$upn'") + '&$select=id') -OutputType PSObject).value | Select-Object -First 1
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

    # ── 4. Access package: self-service requests via My Access ────────────────
    # The enterprise-app "Self-service" blade does not exist for custom OIDC app
    # registrations; the supported (and fully Graph-scriptable) equivalent is an
    # Identity Governance access package over the group.
    Write-Host "`n=== 4. Access package (self-service requests via My Access) ===" -ForegroundColor Cyan
    $emBase      = 'https://graph.microsoft.com/v1.0/identityGovernance/entitlementManagement'
    $catalogName = 'Exchange Archive MCP'
    $packageName = 'Exchange Archive MCP access'
    try {
        # 4a. Catalog
        $catalog = (Invoke-MgGraphRequest -Method GET -Uri "$emBase/catalogs?`$filter=$([Uri]::EscapeDataString("displayName eq '$catalogName'"))" -OutputType PSObject).value | Select-Object -First 1
        if ($catalog) { Ok "catalog exists: $catalogName" }
        elseif ($PSCmdlet.ShouldProcess('entitlement management', "create catalog $catalogName")) {
            Write-MutationLog "POST catalogs create '$catalogName'"
            $catalog = Invoke-MgGraphRequest -Method POST -Uri "$emBase/catalogs" -Body (@{
                displayName = $catalogName
                description = 'Access governance for the Exchange Archive MCP connector.'
                externallyVisible = $false
            } | ConvertTo-Json) -ContentType 'application/json' -OutputType PSObject
            Ok "catalog created: $catalogName"
        }

        # 4b. Group as a catalog resource (admin-add; provisioning is async — poll briefly)
        $resFilter = [Uri]::EscapeDataString("originId eq '$($group.id)'")
        $resource = (Invoke-MgGraphRequest -Method GET -Uri "$emBase/catalogs/$($catalog.id)/resources?`$filter=$resFilter" -OutputType PSObject).value | Select-Object -First 1
        if ($resource) { Ok "group is a catalog resource" }
        elseif ($PSCmdlet.ShouldProcess('entitlement management', "add group $GroupName to catalog")) {
            Write-MutationLog "POST resourceRequests adminAdd group $GroupName -> catalog '$catalogName'"
            # The entitlement-management backend lags directory replication: a
            # just-created group 400s with ResourceNotFoundInOriginSystem until
            # it propagates. Retry with backoff before treating it as fatal.
            $added = $false
            foreach ($attempt in 1..6) {
                try {
                    Invoke-MgGraphRequest -Method POST -Uri "$emBase/resourceRequests" -Body (@{
                        requestType = 'adminAdd'
                        resource    = @{ originId = $group.id; originSystem = 'AadGroup' }
                        catalog     = @{ id = $catalog.id }
                    } | ConvertTo-Json -Depth 5) -ContentType 'application/json' | Out-Null
                    $added = $true
                    break
                } catch {
                    $isReplicationLag = ($_.ErrorDetails -and $_.ErrorDetails.Message -match 'ResourceNotFoundInOriginSystem') -or
                                        ($_.Exception.Message -match 'ResourceNotFoundInOriginSystem')
                    if (-not $isReplicationLag -or $attempt -eq 6) { throw }
                    Info "group not yet visible to entitlement management (replication lag) - retry $attempt/5 in 20s..."
                    Start-Sleep -Seconds 20
                }
            }
            if (-not $added) { throw 'group never became visible to entitlement management.' }
            foreach ($try in 1..10) {
                Start-Sleep -Seconds 3
                $resource = (Invoke-MgGraphRequest -Method GET -Uri "$emBase/catalogs/$($catalog.id)/resources?`$filter=$resFilter" -OutputType PSObject).value | Select-Object -First 1
                if ($resource) { break }
            }
            if (-not $resource) { throw 'group resource did not appear in the catalog after 30s - re-run the script.' }
            Ok 'group added to catalog'
        }

        # 4c. Access package
        $package = (Invoke-MgGraphRequest -Method GET -Uri "$emBase/accessPackages?`$filter=$([Uri]::EscapeDataString("displayName eq '$packageName'"))" -OutputType PSObject).value | Select-Object -First 1
        if ($package) { Ok "access package exists: $packageName" }
        elseif ($PSCmdlet.ShouldProcess('entitlement management', "create access package $packageName")) {
            Write-MutationLog "POST accessPackages create '$packageName'"
            $package = Invoke-MgGraphRequest -Method POST -Uri "$emBase/accessPackages" -Body (@{
                displayName = $packageName
                description = 'Grants sign-in access to the Exchange Archive MCP connector (adds you to the approved-users group). Approval required.'
                catalog     = @{ id = $catalog.id }
            } | ConvertTo-Json -Depth 5) -ContentType 'application/json' -OutputType PSObject
            Ok "access package created: $packageName"
        }

        # 4d. Package delivers group Membership
        $pkgFull = Invoke-MgGraphRequest -Method GET -Uri "$emBase/accessPackages/$($package.id)?`$expand=resourceRoleScopes" -OutputType PSObject
        $hasScope = $false
        if ($pkgFull.PSObject.Properties.Match('resourceRoleScopes').Count -gt 0 -and $pkgFull.resourceRoleScopes) {
            $hasScope = (@($pkgFull.resourceRoleScopes).Count -gt 0)
        }
        if ($hasScope) { Ok 'package already delivers group membership' }
        elseif ($PSCmdlet.ShouldProcess('entitlement management', 'add group Member role to package')) {
            Write-MutationLog "POST accessPackages/$($package.id)/resourceRoleScopes (Member of $GroupName)"
            Invoke-MgGraphRequest -Method POST -Uri "$emBase/accessPackages/$($package.id)/resourceRoleScopes" -Body (@{
                role  = @{ originId = "Member_$($group.id)"; displayName = 'Member'; originSystem = 'AadGroup'; resource = @{ id = $resource.id } }
                scope = @{ originId = $group.id; originSystem = 'AadGroup' }
            } | ConvertTo-Json -Depth 6) -ContentType 'application/json' | Out-Null
            Ok 'package now delivers Member of the group'
        }

        # 4e. Request policy: any tenant member may request; approver = jmonaco
        $approverUpn = 'jmonaco@gipartners.com'
        $approver = (Invoke-MgGraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/users?`$filter=" + [Uri]::EscapeDataString("userPrincipalName eq '$approverUpn'") + '&$select=id') -OutputType PSObject).value | Select-Object -First 1
        if (-not $approver) { throw "approver $approverUpn not found in the tenant." }
        $approverId = $approver.id
        $policyName = 'Request with approval'
        $policies = @((Invoke-MgGraphRequest -Method GET -Uri "$emBase/assignmentPolicies?`$filter=$([Uri]::EscapeDataString("accessPackage/id eq '$($package.id)'"))" -OutputType PSObject).value)
        if (@($policies | Where-Object { $_.displayName -eq $policyName }).Count -gt 0) {
            Ok "request policy exists: $policyName"
        } elseif ($PSCmdlet.ShouldProcess('entitlement management', "create request policy on $packageName")) {
            Write-MutationLog "POST assignmentPolicies '$policyName' (allMemberUsers, approval: jmonaco)"
            Invoke-MgGraphRequest -Method POST -Uri "$emBase/assignmentPolicies" -Body (@{
                displayName        = $policyName
                description        = 'Any member of the directory may request; jmonaco approves; no expiration.'
                allowedTargetScope = 'allMemberUsers'
                expiration         = @{ type = 'noExpiration' }
                requestorSettings  = @{
                    enableTargetsToSelfAddAccess    = $true
                    enableTargetsToSelfUpdateAccess = $false
                    enableTargetsToSelfRemoveAccess = $true
                }
                requestApprovalSettings = @{
                    isApprovalRequiredForAdd    = $true
                    isApprovalRequiredForUpdate = $false
                    stages = @(@{
                        durationBeforeAutomaticDenial   = 'P14D'
                        isApproverJustificationRequired = $false
                        isEscalationEnabled             = $false
                        primaryApprovers = @(@{ '@odata.type' = '#microsoft.graph.singleUser'; userId = $approverId })
                    })
                }
                accessPackage = @{ id = $package.id }
            } | ConvertTo-Json -Depth 10) -ContentType 'application/json' | Out-Null
            Ok "request policy created: $policyName"
        }

        Info 'Self-service flow live: users not in the group request access at'
        Info "https://myaccess.microsoft.com  ->  '$packageName'  (approval goes to jmonaco)."
        Info 'Point anyone hitting the "not assigned" sign-in error (AADSTS50105) there.'
    } catch {
        Bad "access-package setup failed: $($_.Exception.Message)"
        Info 'If the error mentions licensing: entitlement management needs Entra ID Governance'
        Info '(or P2) for the tenant. Fallback: approve manually by adding requestors to'
        Info "$GroupName (Groups > $GroupName > Members)."
    }

    Write-Host ''
    if ($issues.Count -eq 0) { Write-Host 'ALL STEPS APPLIED / VERIFIED.' -ForegroundColor Green }
    else {
        Write-Host "PROBLEMS ($($issues.Count)):" -ForegroundColor Red
        for ($i = 0; $i -lt $issues.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $issues[$i]) -ForegroundColor Red }
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
    if (Get-MgContext) { Disconnect-MgGraph | Out-Null; Write-Host 'Disconnected from Microsoft Graph.' -ForegroundColor DarkGray }
    Write-Host "`nLog saved to: $script:LogPath" -ForegroundColor Cyan
    Stop-Transcript | Out-Null
}
