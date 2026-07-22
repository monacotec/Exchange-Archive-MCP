# Version: 1.0.0
# Get-EDiscoveryAlertConfig.ps1 — READ-ONLY inventory of what alerts on
# eDiscovery activity, so we can suppress ONLY the MCP's own searches without
# blinding the tenant to genuine eDiscovery abuse.
#
# RUN IN WINDOWS POWERSHELL 5.1 — self-relaunches (Connect-IPPSSession's WAM
# broker crashes under PS7 on this machine). Sign in as super-jmonaco.
# Read-only: only Get-* cmdlets; changes nothing.
#
# The MCP tags its activity three ways an alert/suppression rule can key on:
#   - actor  : app service principal, appId 9519ca68-dae2-4add-8309-4bdd1fa45e79
#   - case   : displayName "Exchange Archive MCP - {oid}"
#   - search : displayName "mcp-{oid}-{hex}"
# This script surfaces which alert policies watch eDiscovery search/export and
# what match fields they expose, so the follow-up suppression targets exactly
# the MCP and nothing else.

param()

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    Write-Host 'Relaunching under Windows PowerShell 5.1...' -ForegroundColor Yellow
    $ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    throw 'ExchangeOnlineManagement module required. Install-Module ExchangeOnlineManagement -Scope CurrentUser'
}
Import-Module ExchangeOnlineManagement

$eDiscTerms = 'ediscovery|discovery|search|export|content search'

try {
    Connect-IPPSSession -ShowBanner:$false

    # ── Alert policies (Get-ProtectionAlert) ──────────────────────────────────
    Write-Host "`n=== Alert policies watching eDiscovery/search/export ===" -ForegroundColor Cyan
    $alerts = Get-ProtectionAlert
    $relevant = $alerts | Where-Object {
        ("$($_.Name) $($_.Category) $($_.ThreatType) $($_.Operation) $($_.Description)" -imatch $eDiscTerms)
    }
    if (-not $relevant) {
        Write-Host '  (none matched by name/operation - the alert may be a Defender analytics rule or Sentinel rule, not a Purview alert policy)'
    }
    foreach ($a in $relevant) {
        Write-Host ("`n  Name        : {0}" -f $a.Name)
        Write-Host ("  Category    : {0}" -f $a.Category)
        Write-Host ("  Operation   : {0}" -f ($a.Operation -join ', '))
        Write-Host ("  Disabled    : {0}" -f $a.Disabled)
        Write-Host ("  IsSystem    : {0}" -f $a.IsSystemRule)
        Write-Host ("  NotifyUsers : {0}" -f ($a.NotifyUser -join ', '))
        if ($a.Filter)      { Write-Host ("  Filter      : {0}" -f $a.Filter) }
        if ($a.NotificationCulture) { }  # noop, keep output tidy
    }

    # ── Custom activity alerts (Get-ActivityAlert) ────────────────────────────
    Write-Host "`n=== Custom activity alerts (Get-ActivityAlert) ===" -ForegroundColor Cyan
    $acts = @()
    try { $acts = Get-ActivityAlert } catch { Write-Host "  Get-ActivityAlert unavailable: $($_.Exception.Message)" }
    $actRel = $acts | Where-Object { "$($_.Name) $($_.Operation) $($_.Description)" -imatch $eDiscTerms }
    if (-not $actRel) { Write-Host '  (none watching eDiscovery operations)' }
    foreach ($a in $actRel) {
        Write-Host ("`n  Name      : {0}" -f $a.Name)
        Write-Host ("  Operation : {0}" -f ($a.Operation -join ', '))
        Write-Host ("  UserId    : {0}" -f ($a.UserId -join ', '))
        Write-Host ("  Disabled  : {0}" -f $a.Disabled)
        Write-Host ("  NotifyTo  : {0}" -f ($a.NotifyTo -join ', '))
    }

    # ── Whether the actor even shows in the audit log yet ──────────────────────
    Write-Host "`n=== Recent eDiscovery audit events by the MCP app (last 24h) ===" -ForegroundColor Cyan
    try {
        $end = Get-Date
        $start = $end.AddDays(-1)
        $rec = Search-UnifiedAuditLog -StartDate $start -EndDate $end `
                 -Operations 'SearchStarted','SearchExported','SearchCreated','eDiscoverySearchStartedOrExported' `
                 -ResultSize 20 -ErrorAction Stop
        if (-not $rec) { Write-Host '  (no matching audit events in the window - ingestion can lag)' }
        foreach ($r in $rec) {
            $d = $r.AuditData | ConvertFrom-Json
            Write-Host ("  {0}  op={1}  user={2}" -f $r.CreationDate, $r.Operations, $d.UserId)
        }
    }
    catch { Write-Host "  Audit query unavailable: $($_.Exception.Message)" }
}
finally {
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}

Write-Host "`nPaste the output back to Claude - it identifies the exact alert to tune and the field to key the suppression on." -ForegroundColor Cyan
