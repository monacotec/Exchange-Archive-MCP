#Requires -Version 7.0
# Version: 1.0.0
<#
.SYNOPSIS
    Removes the spike Foundry account super-m11489gu-eastus2 and its project.

.DESCRIPTION
    Cleanup of the auto-provisioned Foundry spike resources in finresgroup
    (identified during the 2026-07-21 resource review; not referenced by any
    plan, IaC, or deployment in this repo):

      1. Foundry project  super-m11489gu-eastus2/super-m11489gu-eastus2-project
      2. Foundry account  super-m11489gu-eastus2   (Microsoft.CognitiveServices/accounts, eastus2)
      3. Optional purge of the soft-deleted account (-Purge) so the name and
         any model-deployment quota are released immediately.

    Deletion order matters: the project must go before the account.
    Idempotent - already-deleted resources are skipped, and -Purge is a no-op
    if nothing is in the soft-deleted state.

    Does NOT touch: kv-Monaco, kv-exmcp-*, the exchange-mcp deployment, or
    gi-exchange-archive-mcp-resource.

.EXAMPLE
    .\Remove-FoundrySpike.ps1                  # prompts before each deletion
    .\Remove-FoundrySpike.ps1 -WhatIf          # show what would be deleted
    .\Remove-FoundrySpike.ps1 -Purge -Confirm:$false
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$SubscriptionId = 'db17a4a4-f677-498a-b4a2-eb401ba9cf29',
    [string]$ResourceGroup  = 'finresgroup',
    [string]$AccountName    = 'super-m11489gu-eastus2',
    [string]$ProjectName    = 'super-m11489gu-eastus2-project',
    [string]$Location       = 'eastus2',

    # Also purge the soft-deleted account after deletion (frees name + quota now).
    [switch]$Purge
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Logging (mutating actions only; timestamp + UPN per convention) ───────────
$logDir  = Join-Path $PSScriptRoot '..\logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("foundry-spike-removal-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
function Write-MutationLog ($action) {
    $upn = az account show --query user.name -o tsv
    "{0:o}  {1}  {2}" -f (Get-Date), $upn, $action | Add-Content -Path $logFile
}

function Ok  ($t) { Write-Host "  [PASS] $t" -ForegroundColor Green }
function Info($t) { Write-Host "  [info] $t" -ForegroundColor DarkGray }

# ── 0. Azure auth (interactive browser; never device code) ────────────────────
Write-Host "`n=== 0. Azure authentication ===" -ForegroundColor Cyan
$account = az account show -o json 2>$null | ConvertFrom-Json
if (-not $account) {
    Info 'No active az session - opening browser sign-in.'
    az login --output none
    $account = az account show -o json | ConvertFrom-Json
}
if ($account.id -ne $SubscriptionId) {
    az account set --subscription $SubscriptionId
    $account = az account show -o json | ConvertFrom-Json
}
Ok "Signed in as $($account.user.name) on subscription '$($account.name)'."

# ── 1. Project ────────────────────────────────────────────────────────────────
Write-Host "`n=== 1. Foundry project ===" -ForegroundColor Cyan
$projectId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup" +
             "/providers/Microsoft.CognitiveServices/accounts/$AccountName/projects/$ProjectName"
$project = az resource show --ids $projectId -o json 2>$null | ConvertFrom-Json
if (-not $project) {
    Info "Project '$ProjectName' not found - already deleted."
}
elseif ($PSCmdlet.ShouldProcess("$AccountName/$ProjectName", 'Delete Foundry project')) {
    Write-MutationLog "Delete Foundry project $AccountName/$ProjectName (rg $ResourceGroup)"
    az resource delete --ids $projectId --output none
    Ok 'Project deleted.'
}

# ── 2. Account ────────────────────────────────────────────────────────────────
Write-Host "`n=== 2. Foundry account ===" -ForegroundColor Cyan
$acct = az cognitiveservices account show -n $AccountName -g $ResourceGroup -o json 2>$null | ConvertFrom-Json
if (-not $acct) {
    Info "Account '$AccountName' not found - already deleted."
}
elseif ($PSCmdlet.ShouldProcess($AccountName, 'Delete Foundry (Cognitive Services) account')) {
    Write-MutationLog "Delete CognitiveServices account $AccountName (rg $ResourceGroup)"
    az cognitiveservices account delete -n $AccountName -g $ResourceGroup --output none
    Ok 'Account deleted (now in soft-deleted state).'
}

# ── 3. Purge (optional) ───────────────────────────────────────────────────────
Write-Host "`n=== 3. Purge ===" -ForegroundColor Cyan
if (-not $Purge) {
    Info 'Skipped (-Purge not set). The soft-deleted account auto-purges in 48h;'
    Info "purge manually with: az cognitiveservices account purge -l $Location -g $ResourceGroup -n $AccountName"
}
else {
    $deleted = az cognitiveservices account list-deleted --query "[?name=='$AccountName'] | [0].name" -o tsv 2>$null
    if (-not $deleted) {
        Info 'Nothing in soft-deleted state to purge.'
    }
    elseif ($PSCmdlet.ShouldProcess($AccountName, 'PURGE soft-deleted account (irreversible)')) {
        Write-MutationLog "Purge soft-deleted CognitiveServices account $AccountName ($Location)"
        az cognitiveservices account purge -l $Location -g $ResourceGroup -n $AccountName --output none
        Ok 'Purged.'
    }
}

Write-Host "`nDone. Mutation log: $logFile" -ForegroundColor Cyan
