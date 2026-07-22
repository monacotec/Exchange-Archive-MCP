#Requires -Version 7.0
# Version: 1.0.0
<#
.SYNOPSIS
    Completes the Key Vault rename cutover: kv-exmcp-m63g6qb2pp -> kv-exmcp-gi.

.DESCRIPTION
    The migration steps already applied (2026-07-21):
      - infra redeployed with keyVaultNameOverride=kv-exmcp-gi (vault created,
        RBAC grants in place, Function App app setting KEY_VAULT_NAME repointed)
      - all 5 mcp-* secrets copied to kv-exmcp-gi
      - Function App restarted

    This script runs from a normal (unfiltered) shell to:
      1. Verify kv-exmcp-gi holds the 5 expected secrets
      2. Verify the Function App KEY_VAULT_NAME app setting points at kv-exmcp-gi
      3. Run Verify-Deployment.ps1 (endpoint + Easy Auth gate checks)
      4. On success, soft-delete the old vault kv-exmcp-m63g6qb2pp
         (purge-protected: the name stays reserved ~90 days; purge is NOT attempted)

    Read-only except step 4, which is gated behind ShouldProcess (-Confirm / -WhatIf).
    Safe to re-run: if the old vault is already gone, step 4 is skipped.

.EXAMPLE
    .\Complete-KvCutover.ps1                  # verify, then prompt before deleting old vault
    .\Complete-KvCutover.ps1 -WhatIf          # verification only, show what would be deleted
    .\Complete-KvCutover.ps1 -Confirm:$false  # verify and delete without prompting
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$SubscriptionId  = 'db17a4a4-f677-498a-b4a2-eb401ba9cf29',
    [string]$ResourceGroup   = 'finresgroup',
    [string]$NewVaultName    = 'kv-exmcp-gi',
    [string]$OldVaultName    = 'kv-exmcp-m63g6qb2pp',
    [string]$FunctionAppName = 'func-exchange-mcp-archive-mailbox-mcp',

    # Restart the Function App before the endpoint checks (only needed if app
    # settings changed since the last restart).
    [switch]$RestartApp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$expectedSecrets = @(
    'mcp-entra-client-id'
    'mcp-exchange-client-secret'
    'mcp-jwks-uri'
    'mcp-jwt-audience'
    'mcp-jwt-issuer'
)

# ── Logging (mutating actions only; timestamp + UPN per convention) ───────────
$logDir  = Join-Path $PSScriptRoot '..\logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("kv-cutover-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
function Write-MutationLog ($action) {
    $upn = az account show --query user.name -o tsv
    "{0:o}  {1}  {2}" -f (Get-Date), $upn, $action | Add-Content -Path $logFile
}

function Ok  ($t) { Write-Host "  [PASS] $t" -ForegroundColor Green }
function No  ($t) { Write-Host "  [FAIL] $t" -ForegroundColor Red }
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

$failures = 0

# ── 1. New vault secrets ──────────────────────────────────────────────────────
Write-Host "`n=== 1. Secrets in $NewVaultName ===" -ForegroundColor Cyan
$present = @(az keyvault secret list --vault-name $NewVaultName --query '[].name' -o tsv)
foreach ($name in $expectedSecrets) {
    if ($present -contains $name) { Ok $name }
    else { No "$name MISSING"; $failures++ }
}

# ── 2. Function App points at the new vault ───────────────────────────────────
Write-Host "`n=== 2. Function App KEY_VAULT_NAME setting ===" -ForegroundColor Cyan
$kvSetting = az functionapp config appsettings list -g $ResourceGroup -n $FunctionAppName `
                 --query "[?name=='KEY_VAULT_NAME'].value | [0]" -o tsv
if ($kvSetting -ceq $NewVaultName) { Ok "KEY_VAULT_NAME = $kvSetting" }
else { No "KEY_VAULT_NAME = '$kvSetting' (expected '$NewVaultName')"; $failures++ }

if ($RestartApp) {
    Write-MutationLog "Restart Function App $FunctionAppName"
    az functionapp restart -g $ResourceGroup -n $FunctionAppName --output none
    Info 'Function App restarted; waiting 30s before endpoint checks.'
    Start-Sleep -Seconds 30
}

# ── 3. Endpoint checks (delegated to Verify-Deployment.ps1) ───────────────────
Write-Host "`n=== 3. Endpoint verification ===" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'Verify-Deployment.ps1') -FunctionAppName $FunctionAppName -ResourceGroup $ResourceGroup
if ($LASTEXITCODE -ne 0) { No 'Verify-Deployment.ps1 reported failures.'; $failures++ }
else { Ok 'Verify-Deployment.ps1 passed.' }

# ── 4. Retire the old vault ───────────────────────────────────────────────────
Write-Host "`n=== 4. Old vault: $OldVaultName ===" -ForegroundColor Cyan
if ($failures -gt 0) {
    No "$failures check(s) failed - NOT deleting the old vault. Fix and re-run."
    exit 1
}

$oldVault = az keyvault show -n $OldVaultName -o json 2>$null | ConvertFrom-Json
if (-not $oldVault) {
    Info 'Old vault not found - already deleted. Nothing to do.'
}
elseif ($PSCmdlet.ShouldProcess($OldVaultName, 'Soft-delete Key Vault (purge-protected; name reserved ~90 days)')) {
    Write-MutationLog "Soft-delete Key Vault $OldVaultName (rg $ResourceGroup)"
    az keyvault delete -n $OldVaultName -g $ResourceGroup --output none
    Ok "Deleted. It remains recoverable via 'az keyvault recover' during the retention window."
    Info "Purge protection is enabled - the name cannot be freed early; this is expected."
}

Write-Host "`nCutover complete. Mutation log: $logFile" -ForegroundColor Cyan
