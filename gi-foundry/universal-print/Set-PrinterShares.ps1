#Requires -Version 7.0
<#
.SYNOPSIS
    Creates Universal Print shares and assigns security groups from a CSV manifest.

.DESCRIPTION
    Idempotent — if a share with the specified name already exists and is already
    assigned to the correct group, the row is skipped with no changes.

    CSV columns: PrinterDisplayName, ShareName, GroupName, Office, Floor

    Prerequisites:
      - Printers already registered (run Register-Printers.ps1 first)
      - Printer Administrator M365 role
      - Microsoft.Graph module: Install-Module Microsoft.Graph -Scope CurrentUser

.PARAMETER CsvPath
    Path to the printers CSV. Defaults to .\printers.csv

.EXAMPLE
    .\Set-PrinterShares.ps1
    .\Set-PrinterShares.ps1 -CsvPath 'C:\IT\printers.csv'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $CsvPath = "$PSScriptRoot\printers.csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string] $Msg, [string] $Color = 'White')
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Msg" -ForegroundColor $Color
}

# ── Connect ───────────────────────────────────────────────────────────────────
Write-Log "Connecting to Microsoft Graph..." Cyan
Connect-MgGraph -Scopes 'Printer.ReadWrite.All', 'PrinterShare.ReadWrite.All', 'Group.Read.All' -NoWelcome

# ── Load CSV ──────────────────────────────────────────────────────────────────
if (-not (Test-Path $CsvPath)) { throw "CSV not found: $CsvPath" }
$rows = Import-Csv -Path $CsvPath
Write-Log "Loaded $($rows.Count) rows from $CsvPath"

$created = 0; $skipped = 0; $errors = 0

foreach ($row in $rows) {
    Write-Log "Processing: $($row.ShareName) ($($row.Office) F$($row.Floor))"

    # ── 1. Look up registered printer ─────────────────────────────────────────
    $printer = Get-MgPrint -ErrorAction SilentlyContinue |
        Where-Object DisplayName -eq $row.PrinterDisplayName

    if (-not $printer) {
        Write-Log "  WARN : Printer '$($row.PrinterDisplayName)' not found — skipping." Red
        $errors++
        continue
    }

    # ── 2. Look up or create share ────────────────────────────────────────────
    $share = Get-MgPrintShare -ErrorAction SilentlyContinue |
        Where-Object DisplayName -eq $row.ShareName

    if (-not $share) {
        if ($PSCmdlet.ShouldProcess($row.ShareName, 'Create printer share')) {
            $share = New-MgPrintShare -BodyParameter @{
                displayName   = $row.ShareName
                printerId     = $printer.Id
                allowAllUsers = $false
            }
            Write-Log "  CREATED share: $($row.ShareName)" Green
        }
    } else {
        Write-Log "  EXISTS share : $($row.ShareName)" Yellow
    }

    # ── 3. Look up security group ─────────────────────────────────────────────
    $group = Get-MgGroup -Filter "DisplayName eq '$($row.GroupName)'" -ErrorAction SilentlyContinue
    if (-not $group) {
        Write-Log "  WARN : Group '$($row.GroupName)' not found — share created but not assigned." Red
        $errors++
        continue
    }

    # ── 4. Assign group to share (idempotent — skip if already assigned) ──────
    $existing = Get-MgPrintShareAllowedGroup -PrinterShareId $share.Id -ErrorAction SilentlyContinue |
        Where-Object Id -eq $group.Id

    if ($existing) {
        Write-Log "  SKIP : Group '$($row.GroupName)' already assigned to '$($row.ShareName)'." Yellow
        $skipped++
    } else {
        if ($PSCmdlet.ShouldProcess($row.GroupName, "Assign to share '$($row.ShareName)'")) {
            New-MgPrintShareAllowedGroup -PrinterShareId $share.Id -GroupId $group.Id | Out-Null
            Write-Log "  ASSIGNED: $($row.GroupName) -> $($row.ShareName)" Green
            $created++
        }
    }
}

Write-Log ""
Write-Log "Summary: $created assignments created, $skipped skipped, $errors errors."
if ($errors -gt 0) {
    Write-Warning "Some rows had errors. Review output above and re-run after fixing."
}
