# Version: 1.0.0
# Export-AzureInventory.ps1 — READ-ONLY snapshot of every Azure/Entra
# configuration and resource for the Exchange Archive MCP project. Produces
# per-area JSON + a human-readable SUMMARY.md for documentation / DR / review.
#
# RUN YOURSELF (Azure work; Claude does not run az). Interactive browser sign-in
# as an admin (super-jmonaco). Read-only: only `list`/`show`/`get` + `az rest` GET.
#
# SECRET SAFETY: never writes secret VALUES. Key Vault secrets are listed by NAME
# only; app-setting values whose key or value looks secret are ***REDACTED***;
# App Insights keys/connection strings are redacted. Identifiers (subscription,
# tenant, app/principal IDs, resource names) ARE written — they are not secrets
# and already live in the repo.
#
# Uses core `az` + `az rest` (avoids the flaky `az monitor`/extension loads seen
# on this machine). Every section is guarded so one failure doesn't abort the run.

[CmdletBinding()]
param(
    [string]$SubscriptionId = 'db17a4a4-f677-498a-b4a2-eb401ba9cf29',
    [string]$TenantId       = '9c1b0b26-717a-4eda-9d7e-7eebc00066bf',
    [string]$ResourceGroup  = 'finresgroup',
    [string]$EntraAppId     = '9519ca68-dae2-4add-8309-4bdd1fa45e79',
    [string]$FunctionApp    = 'func-exchange-mcp-archive-mailbox-mcp',
    [string]$KeyVault       = 'kv-exmcp-gi',
    # Name substrings that identify THIS project's resources in the shared RG.
    [string[]]$NamePatterns = @('exchange-mcp','exmcp','saexmcp','gi-exchange-archive'),
    [string]$OutRoot        = (Join-Path $PSScriptRoot '..\inventory')
)

$ErrorActionPreference = 'Stop'
function Ok  ($t) { Write-Host "  [ok]   $t" -ForegroundColor Green }
function Info($t) { Write-Host "  [..]   $t" -ForegroundColor DarkGray }
function Warn($t) { Write-Host "  [warn] $t" -ForegroundColor Yellow }

$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $OutRoot "azure-config-$stamp"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

# Section runner: capture JSON to a file, tolerate failure.
function Save ($name, [scriptblock]$cmd) {
    Info "collecting: $name"
    try {
        $json = & $cmd
        if ($LASTEXITCODE -ne 0) { throw "az exited $LASTEXITCODE" }
        if ($null -eq $json -or "$json".Trim() -eq '') { $json = '[]' }
        $json | Out-File (Join-Path $outDir "$name.json") -Encoding utf8
        Ok "$name.json"
        return $json
    }
    catch { Warn "$name failed: $($_.Exception.Message)"; "// FAILED: $($_.Exception.Message)" | Out-File (Join-Path $outDir "$name.json") -Encoding utf8; return $null }
}

# Redact secret-ish app settings before writing.
function Redact-AppSettings ($jsonText) {
    if (-not $jsonText) { return $jsonText }
    try { $arr = $jsonText | ConvertFrom-Json } catch { return $jsonText }
    $pat = '(?i)secret|password|connectionstring|accountkey|instrumentationkey|sas|apikey|clientsecret'
    foreach ($s in $arr) {
        $v = [string]$s.value
        $isKvRef = $v -like '@Microsoft.KeyVault(*'   # references are safe to keep
        if (-not $isKvRef -and ($s.name -match $pat -or $v -match 'AccountKey=|InstrumentationKey=|;SharedAccessKey=')) {
            $s.value = '***REDACTED***'
        }
    }
    return ($arr | ConvertTo-Json -Depth 8)
}

# ── 0. Sign-in ────────────────────────────────────────────────────────────────
Write-Host "`n=== 0. Azure sign-in ===" -ForegroundColor Cyan
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) not found on PATH.' }
$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) { az login --tenant $TenantId --output none; $acct = az account show -o json | ConvertFrom-Json }
if ($acct.id -ne $SubscriptionId) { az account set --subscription $SubscriptionId; $acct = az account show -o json | ConvertFrom-Json }
Ok "Signed in as $($acct.user.name); output -> $outDir"

# ── 1. Resource inventory (project-scoped) ───────────────────────────────────
Write-Host "`n=== 1. Resources ===" -ForegroundColor Cyan
$filter = ($NamePatterns | ForEach-Object { "contains(name,'$_')" }) -join ' || '
$resJson = Save 'resources' { az resource list -g $ResourceGroup --query "[?$filter].{name:name,type:type,location:location,id:id}" -o json }

# ── 2. Function App ───────────────────────────────────────────────────────────
Write-Host "`n=== 2. Function App ===" -ForegroundColor Cyan
Save 'functionapp_show'      { az functionapp show -g $ResourceGroup -n $FunctionApp -o json }
$appSettings = Save 'functionapp_appsettings_RAW' { az functionapp config appsettings list -g $ResourceGroup -n $FunctionApp -o json }
if ($appSettings) { (Redact-AppSettings $appSettings) | Out-File (Join-Path $outDir 'functionapp_appsettings.json') -Encoding utf8; Remove-Item (Join-Path $outDir 'functionapp_appsettings_RAW.json') -Force; Ok 'functionapp_appsettings.json (redacted)' }
Save 'functionapp_functions'  { az functionapp function list -g $ResourceGroup -n $FunctionApp --query "[].{name:name}" -o json }
$faId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$FunctionApp"
Save 'functionapp_authsettingsV2' { az rest --method get --url "https://management.azure.com$faId/config/authsettingsV2?api-version=2023-12-01" -o json }

# ── 3. Key Vault ──────────────────────────────────────────────────────────────
Write-Host "`n=== 3. Key Vault ===" -ForegroundColor Cyan
$kvShow = Save 'keyvault_show' { az keyvault show -n $KeyVault -o json }
Save 'keyvault_secret_NAMES' { az keyvault secret list --vault-name $KeyVault --query "[].{name:name,enabled:attributes.enabled,updated:attributes.updated}" -o json }
$kvId = if ($kvShow) { ($kvShow | ConvertFrom-Json).id } else { "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$KeyVault" }
Save 'keyvault_role_assignments' { az role assignment list --scope $kvId --query "[].{principalId:principalId,principalType:principalType,role:roleDefinitionName}" -o json }
Save 'keyvault_diagnostics' { az rest --method get --url "https://management.azure.com$kvId/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview" -o json }

# ── 4. Storage account ────────────────────────────────────────────────────────
Write-Host "`n=== 4. Storage ===" -ForegroundColor Cyan
$sa = if ($resJson) { ($resJson | ConvertFrom-Json | Where-Object { $_.type -eq 'Microsoft.Storage/storageAccounts' } | Select-Object -First 1).name }
if ($sa) { Save 'storage_show' { az storage account show -g $ResourceGroup -n $sa --query "{name:name,allowSharedKeyAccess:allowSharedKeyAccess,publicNetworkAccess:publicNetworkAccess,minimumTlsVersion:minimumTlsVersion,networkAcls:networkAcls,identity:identity}" -o json } }
else { Warn 'No project storage account found in resources.' }

# ── 5. Managed identity (UAI) ────────────────────────────────────────────────
Write-Host "`n=== 5. Managed identity ===" -ForegroundColor Cyan
$uai = if ($resJson) { ($resJson | ConvertFrom-Json | Where-Object { $_.type -eq 'Microsoft.ManagedIdentity/userAssignedIdentities' } | Select-Object -First 1).name }
if ($uai) { Save 'managed_identity' { az identity show -g $ResourceGroup -n $uai --query "{name:name,clientId:clientId,principalId:principalId}" -o json } }

# ── 6. Foundry / Cognitive Services ──────────────────────────────────────────
Write-Host "`n=== 6. Foundry account ===" -ForegroundColor Cyan
Save 'foundry_accounts' { az resource list -g $ResourceGroup --query "[?type=='Microsoft.CognitiveServices/accounts' && contains(name,'exchange-archive')].{name:name,id:id,location:location}" -o json }

# ── 7. Entra app registration + SP + permissions ─────────────────────────────
Write-Host "`n=== 7. Entra app registration ===" -ForegroundColor Cyan
Save 'entra_app' { az ad app show --id $EntraAppId --query "{displayName:displayName,appId:appId,identifierUris:identifierUris,signInAudience:signInAudience,web:web.redirectUris,spa:spa.redirectUris,publicClient:publicClient.redirectUris,exposedScopes:api.oauth2PermissionScopes[].value,appRoles:appRoles[].value,requiredResourceAccess:requiredResourceAccess}" -o json }
Save 'entra_app_federated_credentials' { az ad app federated-credential list --id $EntraAppId --query "[].{name:name,subject:subject,issuer:issuer,audiences:audiences}" -o json }
$spId = az ad sp show --id $EntraAppId --query id -o tsv 2>$null
if ($spId) {
    Save 'entra_sp_approle_assignments' { az rest --method get --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignments" --query "value[].{resource:resourceDisplayName,appRoleId:appRoleId}" -o json }
    Save 'entra_sp_oauth2_grants' { az rest --method get --url ("https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$spId'") --query "value[].{resourceId:resourceId,scope:scope,consentType:consentType}" -o json }
}
else { Warn 'Could not resolve the app service principal id.' }

# ── 8. eDiscovery cases (NAMES/ids only) ─────────────────────────────────────
Write-Host "`n=== 8. eDiscovery cases ===" -ForegroundColor Cyan
Save 'ediscovery_cases' { az rest --method get --url 'https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases?$top=100' --query "value[?contains(displayName,'Exchange Archive MCP')].{displayName:displayName,id:id,status:status,createdDateTime:createdDateTime}" -o json }

# ── 9. RG-scope role assignments for project identities ──────────────────────
Write-Host "`n=== 9. Role assignments (project identities) ===" -ForegroundColor Cyan
Save 'rg_role_assignments' { az role assignment list -g $ResourceGroup --query "[?contains(principalName,'exchange-mcp') || contains(principalName,'exmcp')].{principal:principalName,type:principalType,role:roleDefinitionName,scope:scope}" -o json }

# ── SUMMARY.md ────────────────────────────────────────────────────────────────
Write-Host "`n=== Writing SUMMARY.md ===" -ForegroundColor Cyan
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine("# Azure Inventory — Exchange Archive MCP")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("Snapshot: $stamp | Subscription: $SubscriptionId | RG: $ResourceGroup | By: $($acct.user.name)")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## Resources")
[void]$sb.AppendLine("")
if ($resJson) {
    [void]$sb.AppendLine("| Name | Type | Location |")
    [void]$sb.AppendLine("|---|---|---|")
    foreach ($r in ($resJson | ConvertFrom-Json | Sort-Object type,name)) {
        [void]$sb.AppendLine("| $($r.name) | $($r.type) | $($r.location) |")
    }
}
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## Key identifiers")
[void]$sb.AppendLine("- Entra app (MCP): ``$EntraAppId``")
[void]$sb.AppendLine("- Function App: ``$FunctionApp``")
[void]$sb.AppendLine("- Key Vault: ``$KeyVault``")
if ($uai) { [void]$sb.AppendLine("- User-assigned identity: ``$uai``") }
if ($sa)  { [void]$sb.AppendLine("- Storage account: ``$sa``") }
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## Files in this snapshot")
[void]$sb.AppendLine("Per-area JSON (secret values redacted; KV secrets listed by name only):")
[void]$sb.AppendLine("")
foreach ($f in (Get-ChildItem $outDir -Filter *.json | Sort-Object Name)) { [void]$sb.AppendLine("- ``$($f.Name)``") }
[void]$sb.AppendLine("")
[void]$sb.AppendLine("## Notes")
[void]$sb.AppendLine("- No secret values are captured. `functionapp_appsettings.json` masks secret-like values; Key Vault holds the real secrets (names only here).")
[void]$sb.AppendLine("- Regenerate anytime: ``.\Export-AzureInventory.ps1``")
$sb.ToString() | Out-File (Join-Path $outDir 'SUMMARY.md') -Encoding utf8
Ok 'SUMMARY.md'

Write-Host "`nInventory complete -> $outDir" -ForegroundColor Cyan
Write-Host "Review SUMMARY.md first. Safe to keep; contains no secret values." -ForegroundColor Cyan
