# Version: 1.1.0
# Get-EDiscoveryAuditActor.ps1 — READ-ONLY. Shows how the MCP's eDiscovery
# searches are recorded in the unified audit log, so we can decide whether a
# Defender alert-tuning rule can scope suppression to the MCP app (and on which
# field) vs. having to filter downstream.
#
# RUN IN WINDOWS POWERSHELL 5.1 — self-relaunches (Connect-ExchangeOnline WAM
# broker crashes under PS7 on this machine). Sign in as super-jmonaco.
# Uses Search-UnifiedAuditLog (an Exchange Online cmdlet, NOT the compliance
# session — that is why the earlier inventory script couldn't see it).

param(
    [int]$DaysBack = 2
)

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    Write-Host 'Relaunching under Windows PowerShell 5.1...' -ForegroundColor Yellow
    $ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $ps51 -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -DaysBack $DaysBack
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    throw 'ExchangeOnlineManagement module required.'
}
Import-Module ExchangeOnlineManagement

$McpAppId   = '9519ca68-dae2-4add-8309-4bdd1fa45e79'
$caseMarker = 'Exchange Archive MCP'

try {
    Connect-ExchangeOnline -ShowBanner:$false

    $end   = Get-Date
    $start = $end.AddDays(-1 * $DaysBack)
    Write-Host ("`n=== eDiscovery audit records {0:yyyy-MM-dd} .. {1:yyyy-MM-dd} ===" -f $start, $end) -ForegroundColor Cyan

    # FreeText, NOT RecordType: the record type for eDiscovery estimate/export
    # varies and a wrong enum value silently returns nothing. Match on the case
    # marker and the app id directly — errors surfaced (no SilentlyContinue).
    $records = @()
    foreach ($needle in @($caseMarker, $McpAppId)) {
        Write-Host ("  querying FreeText '{0}' ..." -f $needle) -ForegroundColor DarkGray
        $hit = Search-UnifiedAuditLog -StartDate $start -EndDate $end `
                 -FreeText $needle -ResultSize 200
        if ($hit) { $records += $hit }
    }
    # De-dup by audit record Identity.
    $records = $records | Sort-Object Identity -Unique

    if (-not $records) {
        Write-Host '  No matching audit records (ingestion can lag ~30-60 min; widen -DaysBack, or the actor/marker is not in the audited payload).'
    }

    $mcpSeen = $false
    foreach ($r in $records) {
        $d = $null
        try { $d = $r.AuditData | ConvertFrom-Json } catch { continue }
        $blob = ($d | ConvertTo-Json -Depth 6)
        $isMcp = ($blob -match [regex]::Escape($McpAppId)) -or ($blob -match [regex]::Escape($caseMarker))
        if (-not $isMcp) { continue }
        $mcpSeen = $true
        Write-Host "`n  --- MCP-attributable eDiscovery event ---" -ForegroundColor Green
        Write-Host ("  CreationTime : {0}" -f $d.CreationTime)
        Write-Host ("  Operation    : {0}" -f $d.Operation)
        Write-Host ("  RecordType   : {0}" -f $d.RecordType)
        Write-Host ("  UserId       : {0}" -f $d.UserId)          # <- candidate suppression key
        Write-Host ("  UserType     : {0}" -f $d.UserType)        # 3/4 = application/service
        if ($d.PSObject.Properties.Match('AppId').Count)       { Write-Host ("  AppId        : {0}" -f $d.AppId) }
        if ($d.PSObject.Properties.Match('AppAccessContext').Count) { Write-Host ("  AppAccessCtx : {0}" -f ($d.AppAccessContext | ConvertTo-Json -Compress)) }
        if ($d.PSObject.Properties.Match('ObjectId').Count)    { Write-Host ("  ObjectId     : {0}" -f $d.ObjectId) }
        if ($d.PSObject.Properties.Match('CaseName').Count)    { Write-Host ("  CaseName     : {0}" -f $d.CaseName) }
    }

    if ($records -and -not $mcpSeen) {
        Write-Host "`n  Discovery records exist but none matched the MCP app id / case marker." -ForegroundColor Yellow
        Write-Host '  Showing the newest 3 raw so we can see the actor shape:' -ForegroundColor Yellow
        foreach ($r in ($records | Select-Object -First 3)) {
            $d = $r.AuditData | ConvertFrom-Json
            Write-Host ("  {0}  op={1}  user={2}  type={3}" -f $d.CreationTime, $d.Operation, $d.UserId, $d.UserType)
        }
    }
}
finally {
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
}

Write-Host "`nPaste the output back to Claude - the UserId/AppId/UserType fields decide the suppression approach." -ForegroundColor Cyan
