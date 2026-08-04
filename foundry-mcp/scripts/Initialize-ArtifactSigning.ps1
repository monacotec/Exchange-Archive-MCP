# Version: 1.2.0
# Initialize-ArtifactSigning.ps1 — provisions the scriptable parts of Azure
# Artifact Signing (formerly Trusted Signing) for code-signing ArchiveOpen.exe
# and, as a bonus, this repo's PowerShell scripts.
#
# RUN THIS YOURSELF (Azure work; Claude does not run az). Sign in as an account
# with Owner/Contributor + User Access Administrator on the subscription.
#
# TWO PHASES around the portal-only identity validation:
#   -Phase Account  : register RP, create the Artifact Signing account, grant the
#                     "Artifact Signing Identity Verifier" role so you can do the
#                     identity validation in the portal. RUN FIRST.
#   (then complete Organization identity validation IN THE PORTAL — see
#    docs/artifact-signing-identity-validation-runbook.md; takes 1-20 business days)
#   -Phase Profile  : after validation shows Completed, create the PublicTrust
#                     certificate profile and grant the signer role. Pass the
#                     -IdentityValidationId copied from the portal.
#
# NOTE on the az extension: account/profile commands use the `az artifact-signing`
# extension. If it fails to LOAD on this machine (EDR has blocked other az
# extensions' dist-info reads this session), do those two steps in the Azure
# portal instead — the runbook covers the portal path. RP registration and role
# assignments below use core az and are unaffected.

[CmdletBinding()]
param(
    [ValidateSet('Account','Profile')]
    [string]$Phase = 'Account',

    [string]$SubscriptionId = 'db17a4a4-f677-498a-b4a2-eb401ba9cf29',
    [string]$TenantId       = '9c1b0b26-717a-4eda-9d7e-7eebc00066bf',
    [string]$ResourceGroup  = 'finresgroup',
    [string]$Location       = 'eastus',                 # Artifact Signing-supported region
    [string]$AccountName    = 'gipartifactsign',         # 3-24 alnum, globally unique, start letter, no 'one' prefix
    [string]$ProfileName    = 'gip-code-signing',        # 5-100 alnum
    [string]$Sku            = 'Basic',

    # Phase Account: who will perform identity validation in the portal.
    [string]$IdentityVerifierUpn = 'super-jmonaco@gipartners.com',

    # Phase Profile: from the portal after validation completes.
    [string]$IdentityValidationId,
    # Phase Profile: who/what will SIGN (object id). Default: the identity verifier.
    [string]$SignerPrincipalId
)

$ErrorActionPreference = 'Stop'
function Ok  ($t) { Write-Host "  [PASS] $t" -ForegroundColor Green }
function Info($t) { Write-Host "  [info] $t" -ForegroundColor DarkGray }
function Warn($t) { Write-Host "  [warn] $t" -ForegroundColor Yellow }

# Assign a role by trying the current "Artifact Signing ..." name first, then the
# pre-rename "Trusted Signing ..." name (the service was renamed 2025-26). Returns
# $true on success.
function Grant-SigningRole ($assignee, $newName, $oldName, $scope) {
    foreach ($role in @($newName, $oldName)) {
        az role assignment create --assignee $assignee --role $role --scope $scope --output none 2>$null
        if ($LASTEXITCODE -eq 0) { Ok "Granted '$role'."; return $true }
    }
    return $false
}

$logDir  = Join-Path $PSScriptRoot '..\logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ('artifact-signing-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
function LogMut ($m) { ('{0:o}  {1}' -f (Get-Date), $m) | Add-Content $logFile }

$acct = az account show -o json 2>$null | ConvertFrom-Json
if (-not $acct) { az login --tenant $TenantId --output none; $acct = az account show -o json | ConvertFrom-Json }
if ($acct.id -ne $SubscriptionId) { az account set --subscription $SubscriptionId }

# Live token probe. NEVER trust a cached CLI session: conditional access enforces a
# 4-hour sign-in frequency, so `az account show` can succeed from local cache while
# every real ARM call fails with AADSTS70043 ("refresh token has expired ... sign-in
# frequency checks"). Prove the token is live before mutating; force a clean re-login
# if it is stale, then retry once.
az account get-access-token --resource 'https://management.azure.com/' --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    Warn 'Cached token is stale (conditional-access 4h sign-in frequency). Re-authenticating interactively...'
    az logout 2>$null | Out-Null
    az login --tenant $TenantId --output none
    if ($LASTEXITCODE -ne 0) { throw "Interactive re-login failed. Run: az login --tenant $TenantId  then re-run this script." }
    az account set --subscription $SubscriptionId
    az account get-access-token --resource 'https://management.azure.com/' --output none 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Token still not live after re-login; resolve sign-in, then re-run.' }
    $acct = az account show -o json | ConvertFrom-Json
}
Ok "Signed in as $($acct.user.name) on $SubscriptionId (live token verified)."

$acctResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.CodeSigning/codeSigningAccounts/$AccountName"

if ($Phase -eq 'Account') {
    Write-Host "`n=== Phase Account ===" -ForegroundColor Cyan

    Info 'Registering resource provider Microsoft.CodeSigning...'
    LogMut 'az provider register --namespace Microsoft.CodeSigning'
    az provider register --namespace Microsoft.CodeSigning --output none
    Ok 'RP registration requested (can take a few minutes to reach Registered).'

    Info 'Ensuring the az artifact-signing extension is present...'
    az extension add --name artifact-signing --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0) {
        Warn 'Could not add/load the artifact-signing extension (possibly EDR-blocked).'
        Warn 'Create the account in the Azure portal instead (runbook §Create account), then re-run -Phase Profile.'
    }
    else {
        Info "Creating Artifact Signing account '$AccountName' ($Sku) in $Location..."
        LogMut "az artifact-signing create -n $AccountName -g $ResourceGroup -l $Location --sku $Sku"
        az artifact-signing create -n $AccountName -g $ResourceGroup -l $Location --sku $Sku --output none
        if ($LASTEXITCODE -eq 0) { Ok "Account created: $AccountName" }
        else { Warn 'Account create failed via CLI - use the portal (runbook §Create account).' }
    }

    # Identity Verifier role so the UPN can run identity validation in the portal.
    $verifierOid = az ad user show --id $IdentityVerifierUpn --query id -o tsv 2>$null
    if ($verifierOid) {
        Info "Granting the Identity Verifier role to $IdentityVerifierUpn..."
        LogMut "role assign Identity Verifier -> $IdentityVerifierUpn ($verifierOid) on $acctResourceId"
        if (-not (Grant-SigningRole $verifierOid 'Artifact Signing Identity Verifier' 'Trusted Signing Identity Verifier' $acctResourceId)) {
            Warn "Role assign failed (needs Owner/User Access Administrator, or the account resource is missing)."
            Warn "Assign 'Artifact Signing Identity Verifier' to $IdentityVerifierUpn in the portal: account -> Access control (IAM) -> Add role assignment."
        }
    }
    else { Warn "Could not resolve $IdentityVerifierUpn; assign the Identity Verifier role manually in the portal." }

    Write-Host "`nNEXT: complete Organization identity validation IN THE PORTAL." -ForegroundColor Cyan
    Write-Host '  See docs/artifact-signing-identity-validation-runbook.md.' -ForegroundColor Cyan
    Write-Host '  When it shows Completed, copy the Identity Validation Id and run:' -ForegroundColor Cyan
    Write-Host "  .\Initialize-ArtifactSigning.ps1 -Phase Profile -IdentityValidationId <id> -SignerPrincipalId <build-account-oid>" -ForegroundColor DarkGray
}
else {
    Write-Host "`n=== Phase Profile ===" -ForegroundColor Cyan
    if (-not $IdentityValidationId) { throw 'Pass -IdentityValidationId (copied from the portal after validation completes).' }

    az extension add --name artifact-signing --only-show-errors 2>$null
    Info "Creating PublicTrust certificate profile '$ProfileName'..."
    LogMut "az artifact-signing certificate-profile create -g $ResourceGroup --account-name $AccountName -n $ProfileName --profile-type PublicTrust --identity-validation-id $IdentityValidationId"
    az artifact-signing certificate-profile create -g $ResourceGroup --account-name $AccountName `
        -n $ProfileName --profile-type PublicTrust --identity-validation-id $IdentityValidationId --output none
    if ($LASTEXITCODE -eq 0) { Ok "Certificate profile created: $ProfileName" }
    else { Warn 'Profile create failed via CLI - create it in the portal (runbook §Create certificate profile).' }

    if (-not $SignerPrincipalId) { $SignerPrincipalId = az ad user show --id $IdentityVerifierUpn --query id -o tsv 2>$null }
    if ($SignerPrincipalId) {
        $profileScope = "$acctResourceId/certificateProfiles/$ProfileName"
        Info "Granting the Certificate Profile Signer role to $SignerPrincipalId..."
        LogMut "role assign Signer -> $SignerPrincipalId on $profileScope"
        if (-not (Grant-SigningRole $SignerPrincipalId 'Artifact Signing Certificate Profile Signer' 'Trusted Signing Certificate Profile Signer' $profileScope)) {
            Warn "Signer role assign failed - assign 'Artifact Signing Certificate Profile Signer' on the certificate profile in the portal (IAM)."
        }
    }
    else { Warn 'No SignerPrincipalId resolved; grant the Signer role manually.' }

    Write-Host "`nNEXT: build + sign the handler:" -ForegroundColor Cyan
    Write-Host '  ..\desktop-handler\build.ps1 -DlibPath <Azure.CodeSigning.Dlib.dll> -MetadataPath <metadata.json>' -ForegroundColor DarkGray
    Write-Host '  (metadata.json holds the CodeSigningAccountName, CertificateProfileName, and the region endpoint URI.)' -ForegroundColor DarkGray
}

Write-Host "`nMutation log: $logFile" -ForegroundColor Cyan
