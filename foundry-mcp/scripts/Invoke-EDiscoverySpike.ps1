# Version: 1.1.0
# Invoke-EDiscoverySpike.ps1 — E0 proof: can an eDiscovery search find the known
# archive-only message, and is the report path usable? (ARCHIVE-DATA-PATH-PLAN §7 E0)
#
# Runs DELEGATED as the signed-in admin (core eDiscovery ops support delegated
# auth), so no app secret is needed for the spike. Sign in as super-jmonaco.
# Works in PS 5.1 or PS 7 (Graph SDK only; 5.1-compatible syntax).
#
# Flow:
#   1. Find the standing case (created by Initialize-EDiscoveryAccess.ps1)
#   2. Create a spike search: subject:"Access for Melissa" scoped to
#      jmonaco@gipartners.com (a mailbox source covers primary AND archive;
#      the target message exists ONLY in the archive, so any hit proves
#      archive coverage)
#   3. Run estimateStatistics; poll the operation; print counts
#   4. PASS = hit count >= 1  -> the data path works; proceed to E1
#   5. Cleanup: delete the spike search (keep -KeepSearch to inspect in portal)
#
# Expected duration: 1-5 minutes (estimate operations are async).

param(
    [string]$TenantId = '9c1b0b26-717a-4eda-9d7e-7eebc00066bf',
    [string]$CaseName = 'Exchange Archive MCP - delegated reads',
    [string]$TargetUpn = 'jmonaco@gipartners.com',
    [string]$ContentQuery = 'subject:"Access for Melissa"',
    [int]$PollSeconds = 15,
    [int]$MaxPolls = 40,
    [switch]$KeepSearch
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication')) {
    throw 'Microsoft.Graph.Authentication module required. Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
}

function Ok  ($t) { Write-Host "  [PASS] $t" -ForegroundColor Green }
function No  ($t) { Write-Host "  [FAIL] $t" -ForegroundColor Red }
function Info($t) { Write-Host "  [info] $t" -ForegroundColor DarkGray }

$base = 'https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases'

try {
    Write-Host "`n=== 1. Sign in (super-jmonaco; delegated eDiscovery) ===" -ForegroundColor Cyan
    Connect-MgGraph -TenantId $TenantId -Scopes 'eDiscovery.ReadWrite.All' -NoWelcome

    $cases = (Invoke-MgGraphRequest -Method GET -Uri ($base + '?$top=100'))['value']
    $case = $cases | Where-Object { $_['displayName'] -eq $CaseName } | Select-Object -First 1
    if (-not $case) { throw "Case '$CaseName' not found - run Initialize-EDiscoveryAccess.ps1 first." }
    $caseId = $case['id']
    Ok "Case: $caseId"

    Write-Host "`n=== 2. Create spike search ===" -ForegroundColor Cyan
    # v1.0 requires a data source AT creation, expressed either as an inline
    # additionalSources deep-insert (plan A) or as an @odata.bind to a source
    # already registered in the case (plan B: noncustodialDataSource). A mailbox
    # userSource covers the primary AND the In-Place Archive.
    $searchName = ('spike-{0:yyyyMMdd-HHmmss}' -f (Get-Date))
    $search = $null

    # Plan A: inline additionalSources
    $bodyA = @{
        displayName       = $searchName
        description       = 'E0 spike - archive coverage proof. Safe to delete.'
        contentQuery      = $ContentQuery
        additionalSources = @(@{ '@odata.type' = 'microsoft.graph.security.userSource'; email = $TargetUpn })
    } | ConvertTo-Json -Depth 5
    try {
        $search = Invoke-MgGraphRequest -Method POST -Uri "$base/$caseId/searches" -Body $bodyA -ContentType 'application/json'
        Ok "Search created via inline additionalSources: $($search['id'])"
    }
    catch {
        Info "Plan A (inline additionalSources) rejected - falling back to noncustodialDataSource binding."
    }

    # Plan B: register a noncustodial data source in the case, bind it
    if (-not $search) {
        $ncBody = @{
            dataSource = @{ '@odata.type' = 'microsoft.graph.security.userSource'; email = $TargetUpn }
        } | ConvertTo-Json -Depth 5
        $nc = $null
        try {
            $nc = Invoke-MgGraphRequest -Method POST -Uri "$base/$caseId/noncustodialDataSources" -Body $ncBody -ContentType 'application/json'
            Ok "noncustodialDataSource registered: $($nc['id'])"
        }
        catch {
            # Already registered from a prior run? Find it.
            $existingNc = (Invoke-MgGraphRequest -Method GET -Uri "$base/$caseId/noncustodialDataSources")['value']
            foreach ($e in $existingNc) {
                $ds = $e['dataSource']
                if ($ds -and $ds['email'] -eq $TargetUpn) { $nc = $e }
            }
            if ($nc) { Ok "noncustodialDataSource already registered: $($nc['id'])" }
            else { throw }
        }
        $bodyB = @{
            displayName  = $searchName
            description  = 'E0 spike - archive coverage proof. Safe to delete.'
            contentQuery = $ContentQuery
            'noncustodialSources@odata.bind' = @("$base/$caseId/noncustodialDataSources/$($nc['id'])")
        } | ConvertTo-Json -Depth 5
        $search = Invoke-MgGraphRequest -Method POST -Uri "$base/$caseId/searches" -Body $bodyB -ContentType 'application/json'
        Ok "Search created via noncustodialSources bind: $($search['id'])"
    }

    $searchId = $search['id']
    Info "source: $TargetUpn"

    Write-Host "`n=== 3. Estimate statistics (async; polling every $PollSeconds s) ===" -ForegroundColor Cyan
    Invoke-MgGraphRequest -Method POST -Uri "$base/$caseId/searches/$searchId/estimateStatistics" | Out-Null
    $done = $false
    for ($i = 0; $i -lt $MaxPolls; $i++) {
        Start-Sleep -Seconds $PollSeconds
        $ops = (Invoke-MgGraphRequest -Method GET -Uri "$base/$caseId/operations")['value']
        $est = $ops | Where-Object { $_['action'] -eq 'estimateStatistics' } |
               Sort-Object { $_['createdDateTime'] } -Descending | Select-Object -First 1
        if (-not $est) { Info 'operation not visible yet...'; continue }
        Info ("poll {0}: {1} ({2}%)" -f ($i + 1), $est['status'], $est['percentProgress'])
        if ($est['status'] -eq 'succeeded') { $done = $true; break }
        if ($est['status'] -eq 'failed') { No 'Estimate operation FAILED.'; break }
    }
    if (-not $done) { No 'Estimate did not complete in time - check the case in the Purview portal.' }
    else {
        $stats = Invoke-MgGraphRequest -Method GET -Uri ("$base/$caseId/searches/$searchId" + '?$select=id,displayName,lastEstimateStatisticsOperation&$expand=lastEstimateStatisticsOperation')
        $op = $stats['lastEstimateStatisticsOperation']
        $count = $null
        if ($op) { $count = $op['indexedItemCount'] }
        Write-Host ''
        if ($null -ne $count -and [int]$count -ge 1) {
            Ok ("VERDICT: {0} item(s) found for {1} - the archive-only message is reachable. eDiscovery data path CONFIRMED; proceed to E1." -f $count, $ContentQuery)
            if ($op['indexedItemsSize']) { Info ("indexed size: {0} bytes" -f $op['indexedItemsSize']) }
        }
        elseif ($null -ne $count) {
            No 'VERDICT: 0 items - archive not reached by this search shape. Paste output back to Claude before building E1.'
        }
        else {
            Info 'Could not read indexedItemCount from lastEstimateStatisticsOperation - raw operation follows:'
            $op | ConvertTo-Json -Depth 5 | Write-Host
        }
    }

    if ($KeepSearch) { Info "Search kept for portal inspection: $searchId" }
    else {
        Invoke-MgGraphRequest -Method DELETE -Uri "$base/$caseId/searches/$searchId" | Out-Null
        Info 'Spike search deleted.'
    }
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}

Write-Host "`nPaste the output back to Claude." -ForegroundColor Cyan
