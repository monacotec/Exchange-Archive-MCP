# Version: 1.1.0
# Get-EDiscoverySearchStatus.ps1 — reads the estimate result of an MCP-created
# eDiscovery search using the app's own identity (client_credentials via the
# Key Vault secret). Read-only. Works in PS 5.1 or PS 7.
#
# Use when the MCP returned {status: "running", search_id: ...} and the
# archive_get_search_status tool isn't available to the calling session yet
# (connector tool lists refresh on reconnect).

param(
    [Parameter(Mandatory)][string]$SearchId,
    [string]$TenantId  = '9c1b0b26-717a-4eda-9d7e-7eebc00066bf',
    [string]$AppId     = '9519ca68-dae2-4add-8309-4bdd1fa45e79',
    [string]$VaultName = 'kv-exmcp-gi',
    [string]$CaseName  = 'Exchange Archive MCP (app-owned)'
)

$ErrorActionPreference = 'Stop'

$secret = az keyvault secret show --vault-name $VaultName --name mcp-exchange-client-secret --query value -o tsv
$tokenResp = Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
    -Body @{
        grant_type    = 'client_credentials'
        client_id     = $AppId
        client_secret = $secret
        scope         = 'https://graph.microsoft.com/.default'
    }
$headers = @{ Authorization = "Bearer $($tokenResp.access_token)" }
$base = 'https://graph.microsoft.com/v1.0/security/cases/ediscoveryCases'

$cases = (Invoke-RestMethod -Uri ($base + '?$top=100') -Headers $headers).value
$case = $cases | Where-Object { $_.displayName -eq $CaseName } | Select-Object -First 1
if (-not $case) { throw "App-owned case '$CaseName' not found." }
Write-Host "case: $($case.id)  ('$($case.displayName)')"

$uri = "$base/$($case.id)/searches/$SearchId" + '?$expand=lastEstimateStatisticsOperation'
$search = Invoke-RestMethod -Uri $uri -Headers $headers
$op = $search.lastEstimateStatisticsOperation

Write-Host ("search : {0}  ('{1}')" -f $search.id, $search.displayName)
Write-Host ("query  : {0}" -f $search.contentQuery)
if ($op) {
    Write-Host ("status : {0}  ({1}%)" -f $op.status, $op.percentProgress)
    Write-Host '--- ALL estimate count fields ---'
    foreach ($p in $op.PSObject.Properties) {
        if ($p.Name -match 'Count|Size|mailbox|site|Item') {
            Write-Host ("  {0,-32}: {1}" -f $p.Name, $p.Value)
        }
    }
}
else {
    Write-Host 'status : no estimate operation recorded yet'
}

# What sources is the search actually bound to?
Write-Host "`n--- Search sources ---"
foreach ($rel in @('noncustodialSources', 'custodianSources', 'additionalSources')) {
    try {
        $src = (Invoke-RestMethod -Uri "$base/$($case.id)/searches/$SearchId/$rel" -Headers $headers).value
        if ($src) {
            foreach ($s in $src) {
                $email = $null
                if ($s.PSObject.Properties.Match('dataSource').Count) { $email = $s.dataSource.email }
                if (-not $email -and $s.PSObject.Properties.Match('email').Count) { $email = $s.email }
                Write-Host ("  {0,-20}: {1}  (id {2})" -f $rel, $email, $s.id)
            }
        }
        else { Write-Host ("  {0,-20}: (none)" -f $rel) }
    }
    catch { Write-Host ("  {0,-20}: not queryable ({1})" -f $rel, $_.Exception.Message) }
}

# Case-level noncustodial sources (what exists to bind).
Write-Host "`n--- Case noncustodial data sources ---"
$ncs = (Invoke-RestMethod -Uri "$base/$($case.id)/noncustodialDataSources" -Headers $headers).value
foreach ($n in $ncs) {
    $email = if ($n.PSObject.Properties.Match('dataSource').Count) { $n.dataSource.email } else { '?' }
    Write-Host ("  {0}  status={1}  id={2}" -f $email, $n.status, $n.id)
}

Write-Host "`nPaste the output back to Claude." -ForegroundColor Cyan
