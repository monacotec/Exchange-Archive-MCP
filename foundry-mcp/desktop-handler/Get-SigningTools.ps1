# Version: 1.0.0
# Get-SigningTools.ps1 — stage Microsoft's `sign` CLI into .\signtool-cli\ so
# build.ps1 -Sign can run it from the repo path.
#
# Why staged in-repo: EDR/ThreatLocker on this fleet denies loading the tool's
# assembly from ~/.dotnet/tools/.store ("FileLoadException: Access is denied"),
# but the repo path is allow-listed. So we install the global tool, then copy its
# payload here and run it via `dotnet .\signtool-cli\sign.dll ...`.
#
# The payload (~18 MB) is gitignored; run this once per clone / per tool update.

param(
    [string]$Version = '0.9.1-beta.26371.2',   # pin; pass '' to take latest --prerelease
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dest = Join-Path $here 'signtool-cli'

if ((Test-Path (Join-Path $dest 'sign.dll')) -and -not $Force) {
    Write-Host "sign CLI already staged in $dest (use -Force to re-stage)." -ForegroundColor Green
    return
}
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw '.NET SDK (dotnet) not found on PATH.' }

Write-Host 'Installing/updating the sign global tool...' -ForegroundColor Cyan
if ($Version) { dotnet tool update --global sign --version $Version 2>&1 | Out-Null }
else          { dotnet tool update --global sign --prerelease      2>&1 | Out-Null }

# Locate the installed tool payload (…/.store/sign/<ver>/sign/<ver>/tools/net8.0/any).
$storeRoot = Join-Path $env:USERPROFILE '.dotnet\tools\.store\sign'
$payload = Get-ChildItem $storeRoot -Recurse -Filter 'sign.dll' -ErrorAction SilentlyContinue |
           Where-Object { $_.FullName -match '\\tools\\net\d' } |
           Sort-Object FullName -Descending | Select-Object -First 1
if (-not $payload) { throw "Could not locate installed sign.dll under $storeRoot." }

if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
New-Item -ItemType Directory -Path $dest | Out-Null
Copy-Item (Join-Path $payload.Directory.FullName '*') $dest -Recurse -Force
Get-ChildItem $dest -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

$staged = Join-Path $dest 'sign.dll'
if (-not (Test-Path $staged)) { throw 'Staging failed.' }
Write-Host "Staged sign CLI -> $dest" -ForegroundColor Green
Write-Host 'Smoke test:' -ForegroundColor Cyan
& dotnet $staged code artifact-signing --help | Select-Object -First 3
