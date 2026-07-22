# Version: 1.0.0
# build.ps1 — publish ArchiveOpen.exe (self-contained single file) and, if an
# Azure Artifact Signing profile is available, code-sign it.
#
# Prereqs: .NET 8 SDK. For signing: .NET 8 runtime + Windows SDK signtool +
# the Trusted/Artifact Signing dlib, and a completed cert profile (see
# ../../docs/artifact-signing-identity-validation-runbook.md and
# scripts/Initialize-ArtifactSigning.ps1). Signing params are optional so the
# handler can be built + tested UNSIGNED before the signing account exists.

param(
    [string]$Configuration = 'Release',
    # Signing (all optional; provide together once the cert profile exists):
    [string]$DlibPath,          # path to Azure.CodeSigning.Dlib.dll
    [string]$MetadataPath,      # signing metadata json (endpoint, account, profile)
    [string]$TimestampUrl = 'http://timestamp.acs.microsoft.com'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $here
try {
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        throw '.NET 8 SDK (dotnet) not found on PATH. Install it before building.'
    }

    $dist = Join-Path $here 'dist'
    Write-Host "Publishing ArchiveOpen.exe ($Configuration, self-contained win-x64)..." -ForegroundColor Cyan
    dotnet publish .\ArchiveOpen.csproj -c $Configuration -o $dist
    if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed.' }

    $exe = Join-Path $dist 'ArchiveOpen.exe'
    if (-not (Test-Path $exe)) { throw "Expected output not found: $exe" }
    Write-Host "Built: $exe" -ForegroundColor Green

    if ($DlibPath -and $MetadataPath) {
        $signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin\*\x64\signtool.exe' -ErrorAction SilentlyContinue |
                    Sort-Object FullName -Descending | Select-Object -First 1
        if (-not $signtool) { throw 'signtool.exe not found (install the Windows SDK).' }
        Write-Host "Signing with Azure Artifact Signing..." -ForegroundColor Cyan
        & $signtool.FullName sign /v /debug /fd SHA256 `
            /tr $TimestampUrl /td SHA256 `
            /dlib $DlibPath /dmdf $MetadataPath `
            $exe
        if ($LASTEXITCODE -ne 0) { throw 'signtool sign failed.' }
        Write-Host 'Verifying signature...' -ForegroundColor Cyan
        & $signtool.FullName verify /pa /v $exe
        if ($LASTEXITCODE -ne 0) { throw 'Signature verification failed.' }
        Write-Host 'Signed and verified.' -ForegroundColor Green
    }
    else {
        Write-Host 'No signing params supplied - produced an UNSIGNED build (fine for local D0/D1 testing).' -ForegroundColor Yellow
    }

    Write-Host "`nOutput: $exe" -ForegroundColor Cyan
}
finally { Pop-Location }
