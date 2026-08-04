# Version: 1.1.0
# build.ps1 — publish ArchiveOpen.exe (self-contained single file) and, with -Sign,
# code-sign it with Azure Artifact Signing (formerly Trusted Signing).
#
# Signing uses Microsoft's `sign` CLI (dotnet tool) in its "artifact-signing" mode
# with the azure-cli credential, i.e. it signs as whoever is logged in via `az`
# (must hold the "Artifact Signing Certificate Profile Signer" role on the profile).
# This replaced the earlier signtool.exe /dlib path, which fell back to a local
# self-signed cert and failed with SignerSign() 0x80070032.
#
# Prereqs:
#   - .NET 8+ SDK (build).
#   - For signing: the `sign` CLI staged in .\signtool-cli\ (run Get-SigningTools.ps1
#     once), a completed Artifact Signing cert profile (scripts/Initialize-
#     ArtifactSigning.ps1 -Phase Profile + the identity-validation runbook), and a
#     live `az login` as a signer-role holder (super-jmonaco@gipartners.com).
#   - Windows SDK signtool.exe is used only to VERIFY the result.

param(
    [string]$Configuration = 'Release',
    [switch]$Sign,
    # Artifact Signing coordinates (match scripts/Initialize-ArtifactSigning.ps1):
    [string]$SigningEndpoint = 'https://eus.codesigning.azure.net/',
    [string]$SigningAccount  = 'gipartifactsign',
    [string]$SigningProfile  = 'gip-code-signing',
    [ValidateSet('azure-cli','azure-powershell','managed-identity','workload-identity')]
    [string]$CredentialType  = 'azure-cli',
    [string]$Description    = 'GIP Archive Open',
    [string]$DescriptionUrl = 'https://gipartners.com',
    [string]$TimestampUrl   = 'http://timestamp.acs.microsoft.com/'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $here
try {
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw '.NET SDK (dotnet) not found on PATH. Install it before building.'
    }

    $dist = Join-Path $here 'dist'
    Write-Host "Publishing ArchiveOpen.exe ($Configuration, self-contained win-x64)..." -ForegroundColor Cyan
    dotnet publish .\ArchiveOpen.csproj -c $Configuration -o $dist
    if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed.' }

    $exe = Join-Path $dist 'ArchiveOpen.exe'
    if (-not (Test-Path $exe)) { throw "Expected output not found: $exe" }
    Write-Host "Built: $exe" -ForegroundColor Green

    if ($Sign) {
        # The `sign` CLI is staged in-repo (EDR/ThreatLocker blocks loading it from
        # ~/.dotnet/tools/.store; running from the repo path is allow-listed).
        $signDll = Join-Path $here 'signtool-cli\sign.dll'
        if (-not (Test-Path $signDll)) {
            throw "sign CLI not staged. Run .\Get-SigningTools.ps1 first (stages it into .\signtool-cli\)."
        }
        Write-Host "Signing with Azure Artifact Signing (account $SigningAccount / profile $SigningProfile, cred $CredentialType)..." -ForegroundColor Cyan
        & dotnet $signDll code artifact-signing $exe `
            -ase $SigningEndpoint -asa $SigningAccount -ascp $SigningProfile `
            -act $CredentialType `
            -d $Description -u $DescriptionUrl `
            -t $TimestampUrl -td SHA256 -fd SHA256 `
            -v Information
        if ($LASTEXITCODE -ne 0) { throw "sign failed (exit $LASTEXITCODE). Confirm `az login` is live and holds the signer role." }

        # Verify the result chains to a trusted root (signtool from the Windows SDK).
        $signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin\*\x64\signtool.exe' -ErrorAction SilentlyContinue |
                    Sort-Object FullName -Descending | Select-Object -First 1
        if ($signtool) {
            Write-Host 'Verifying signature...' -ForegroundColor Cyan
            & $signtool.FullName verify /pa /v $exe
            if ($LASTEXITCODE -ne 0) { throw 'Signature verification failed.' }
        }
        else {
            $sig = Get-AuthenticodeSignature $exe
            if ($sig.Status -ne 'Valid') { throw "Signature status: $($sig.Status)" }
            Write-Host ("Signed by: {0}" -f $sig.SignerCertificate.Subject) -ForegroundColor Green
        }
        Write-Host 'Signed and verified.' -ForegroundColor Green
    }
    else {
        Write-Host 'No -Sign flag - produced an UNSIGNED build (fine for local D0/D1 testing).' -ForegroundColor Yellow
    }

    Write-Host "`nOutput: $exe" -ForegroundColor Cyan
}
finally { Pop-Location }
