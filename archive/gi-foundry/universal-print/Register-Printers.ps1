#Requires -Version 7.0
<#
.SYNOPSIS
    Registers printers visible to the Universal Print Connector with Microsoft Universal Print.

.DESCRIPTION
    Must be run ON the Universal Print Connector host machine (domain-joined Windows
    10/11 or Server 2016+). Idempotent — already-registered printers are skipped.

    Prerequisites:
      - Universal Print Connector installed and signed in
      - Printer Administrator M365 role
      - Microsoft.Graph module: Install-Module Microsoft.Graph -Scope CurrentUser

.PARAMETER PrinterName
    Optional. If provided, registers only the printer with this display name.
    If omitted, attempts to register all printers visible to the connector.

.EXAMPLE
    .\Register-Printers.ps1
    .\Register-Printers.ps1 -PrinterName 'HP LaserJet 4200 (SF3)'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $PrinterName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Helper: verify connector service is running ────────────────────────────────
function Test-ConnectorInstalled {
    $svc = Get-Service -Name 'UniversalPrintConnector' -ErrorAction SilentlyContinue
    if (-not $svc) {
        throw @"
Universal Print Connector service not found on this machine.
Install it from https://aka.ms/UPConnector, sign in, and re-run this script.
This script must be executed on the connector host machine.
"@
    }
    if ($svc.Status -ne 'Running') {
        throw "Universal Print Connector service is installed but not running. Start it first: Start-Service UniversalPrintConnector"
    }
    Write-Host "Universal Print Connector service is running." -ForegroundColor Green
}

# ── Helper: log with timestamp ─────────────────────────────────────────────────
function Write-Log {
    param([string] $Msg, [string] $Color = 'White')
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Msg" -ForegroundColor $Color
}

# ── Main ──────────────────────────────────────────────────────────────────────
Test-ConnectorInstalled

Write-Log "Connecting to Microsoft Graph (Printer.ReadWrite.All)..." Cyan
Connect-MgGraph -Scopes 'Printer.ReadWrite.All' -NoWelcome

# Get already-registered printers to skip duplicates
$existing = Get-MgPrint -ErrorAction SilentlyContinue
$existingNames = $existing | Select-Object -ExpandProperty DisplayName

Write-Log "Currently registered printers: $($existingNames.Count)"

# Get printers visible to the connector (WMI — connector exposes them as Windows printers)
$localPrinters = Get-Printer | Where-Object { $_.Type -eq 'Local' }

if ($PrinterName) {
    $localPrinters = $localPrinters | Where-Object Name -eq $PrinterName
    if (-not $localPrinters) {
        throw "Printer '$PrinterName' not found on this machine."
    }
}

$registered = 0; $skipped = 0; $failed = 0

foreach ($printer in $localPrinters) {
    if ($existingNames -contains $printer.Name) {
        Write-Log "  SKIP  : $($printer.Name) (already registered)" Yellow
        $skipped++
        continue
    }

    if ($PSCmdlet.ShouldProcess($printer.Name, 'Register with Universal Print')) {
        try {
            # Note: New-MgPrint is the Graph SDK cmdlet for creating a printer share registration
            # The connector handles the actual registration; this confirms it in the cloud
            New-MgPrint -BodyParameter @{ displayName = $printer.Name } | Out-Null
            Write-Log "  OK    : $($printer.Name)" Green
            $registered++
        } catch {
            Write-Log "  FAIL  : $($printer.Name) — $($_.Exception.Message)" Red
            $failed++
        }
    }
}

Write-Log ""
Write-Log "Registration summary: $registered registered, $skipped skipped, $failed failed."
if ($failed -gt 0) {
    Write-Warning "Some printers failed to register. Check the Universal Print portal for details."
}
