#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources
<#
.SYNOPSIS
    Deploys the GI Partners Azure AI Foundry stack via Bicep.

.DESCRIPTION
    Performs pre-flight checks (login, resource group, provider registration),
    then runs a Bicep deployment against the target environment.
    Supports -WhatIf for dry-run validation without making changes.

.PARAMETER Environment
    Target environment: prod | dev | test. Defaults to prod.

.EXAMPLE
    .\Deploy-Foundry.ps1 -Environment dev -WhatIf
    .\Deploy-Foundry.ps1 -Environment prod
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('prod', 'dev', 'test')]
    [string] $Environment = 'prod'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Constants ─────────────────────────────────────────────────────────────────
$RG        = "rg-ai-foundry-$Environment"
$Location  = 'eastus2'
$ParamFile = "$PSScriptRoot\..\foundry-iac\parameters\$Environment.bicepparam"
$MainBicep = "$PSScriptRoot\..\foundry-iac\main.bicep"
$LogDir    = "$PSScriptRoot\logs"
$LogFile   = "$LogDir\deploy-$Environment-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

$RequiredProviders = @(
    'Microsoft.CognitiveServices'
    'Microsoft.MachineLearningServices'
    'Microsoft.Authorization'
    'Microsoft.Network'
    'Microsoft.Storage'
    'Microsoft.KeyVault'
)

# ── Helpers ───────────────────────────────────────────────────────────────────
function Write-Log {
    param([string] $Msg, [string] $Color = 'White')
    $ts = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$ts] $Msg" -ForegroundColor $Color
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
    "[$ts] $Msg" | Add-Content -Path $LogFile
}

# ── Pre-flight: verify Azure login ───────────────────────────────────────────
Write-Log 'Pre-flight: checking Azure login...' Cyan
$ctx = Get-AzContext
if (-not $ctx) {
    throw 'Not logged in to Azure. Run Connect-AzAccount before deploying.'
}
Write-Log "Subscription : $($ctx.Subscription.Name) ($($ctx.Subscription.Id))"
Write-Log "Account      : $($ctx.Account.Id)"

# ── Pre-flight: resource group ───────────────────────────────────────────────
Write-Log "Pre-flight: ensuring resource group '$RG' exists..." Cyan
$rg = Get-AzResourceGroup -Name $RG -ErrorAction SilentlyContinue
if (-not $rg) {
    if ($PSCmdlet.ShouldProcess($RG, 'Create resource group')) {
        Write-Log "Creating resource group '$RG' in $Location..." Yellow
        New-AzResourceGroup -Name $RG -Location $Location -Tag @{
            Environment = $Environment
            ManagedBy   = 'Bicep-IaC'
            Owner       = 'IT-Infrastructure'
        } | Out-Null
        Write-Log "Resource group created." Green
    }
} else {
    Write-Log "Resource group '$RG' already exists." Green
}

# ── Pre-flight: resource provider registration ────────────────────────────────
Write-Log 'Pre-flight: checking resource provider registrations...' Cyan
foreach ($provider in $RequiredProviders) {
    $state = (Get-AzResourceProvider -ProviderNamespace $provider).RegistrationState
    if ($state -ne 'Registered') {
        Write-Log "  Registering provider: $provider" Yellow
        if ($PSCmdlet.ShouldProcess($provider, 'Register resource provider')) {
            Register-AzResourceProvider -ProviderNamespace $provider | Out-Null
        }
    } else {
        Write-Log "  $provider — already registered." Green
    }
}

# ── Deploy ────────────────────────────────────────────────────────────────────
$deployName = "foundry-$Environment-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

if ($WhatIfPreference) {
    Write-Log "Running Bicep what-if for '$Environment' (no changes will be made)..." Yellow
    New-AzResourceGroupDeployment `
        -ResourceGroupName $RG `
        -TemplateFile $MainBicep `
        -TemplateParameterFile $ParamFile `
        -WhatIf
} else {
    Write-Log "Starting deployment '$deployName'..." Green
    if ($PSCmdlet.ShouldProcess($RG, "Deploy Bicep stack ($Environment)")) {
        $result = New-AzResourceGroupDeployment `
            -ResourceGroupName $RG `
            -TemplateFile $MainBicep `
            -TemplateParameterFile $ParamFile `
            -Name $deployName `
            -Verbose

        Write-Log '' White
        Write-Log '=== Deployment Outputs ===' Green
        foreach ($key in $result.Outputs.Keys) {
            # Only log non-secret outputs
            Write-Log "  $key : $($result.Outputs[$key].Value)" Green
        }
        Write-Log "Deployment complete. Log: $LogFile" Green
    }
}
