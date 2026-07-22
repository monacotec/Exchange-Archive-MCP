#Requires -Version 7.0
# Version: 1.2.1
<#
.SYNOPSIS
    Determines WHY the Online Archive is not addressable via Graph.

.DESCRIPTION
    The deployed MCP gets 404 ErrorInvalidMailboxItemId for every archive
    well-known name (archivemsgfolderroot / archiveroot / archiveinbox) under
    its OBO token. Two competing explanations:

      A. The archive is AUTO-EXPANDING -> Graph REST cannot address it at all
         (documented limitation). No token will ever work.
      B. An OBO-context quirk -> the same well-known names resolve fine with an
         interactive delegated token; the function's OBO token is the problem.

    This script settles it (read-only; Graph permissions: Mail.Read delegated;
    Exchange Online: mailbox read as admin):

      PART 1 (sign in as jmonaco@gipartners.com - the mailbox owner):
        Probes v1.0 and beta Graph for each archive well-known name with YOUR
        interactive token, and lists top-level mailFolders w/ hidden folders.

      PART 2 (sign in as super-jmonaco@gipartners.com when prompted):
        Reads the mailbox archive config: ArchiveStatus, ArchiveState,
        AutoExpandingArchiveEnabled, ArchiveGuid + org-level auto-expand flag.

    Interpretation:
      - PART 1 all 404 + AutoExpandingArchiveEnabled True  -> hypothesis A.
      - PART 1 succeeds -> hypothesis B (fix the OBO side; archive is fine).

.EXAMPLE
    .\Test-ArchiveGraphAccess.ps1
    .\Test-ArchiveGraphAccess.ps1 -SkipExchangePart
#>
[CmdletBinding()]
param(
    [string]$Upn = 'jmonaco@gipartners.com',
    [string]$TenantId = '9c1b0b26-717a-4eda-9d7e-7eebc00066bf',
    [switch]$SkipExchangePart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($m in 'Microsoft.Graph.Authentication') {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        throw "Required module '$m' is not installed. Install-Module $m -Scope CurrentUser"
    }
}

function Ok  ($t) { Write-Host "  [PASS] $t" -ForegroundColor Green }
function No  ($t) { Write-Host "  [FAIL] $t" -ForegroundColor Red }
function Info($t) { Write-Host "  [info] $t" -ForegroundColor DarkGray }

# ── PART 1: Graph probes with YOUR interactive delegated token ────────────────
Write-Host "`n=== PART 1: Graph archive probes (sign in as $Upn) ===" -ForegroundColor Cyan
try {
    Connect-MgGraph -TenantId $TenantId -Scopes 'Mail.Read' -NoWelcome
    $me = (Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/me?$select=userPrincipalName').userPrincipalName
    if ($me -ne $Upn) { Write-Host "  [warn] Signed in as $me, expected $Upn - probes hit $me's mailbox." -ForegroundColor Yellow }

    $anchors = @('archivemsgfolderroot', 'archiveroot', 'archiveinbox', 'archivedeleteditems')
    foreach ($ver in @('v1.0', 'beta')) {
        foreach ($a in $anchors) {
            $uri = "https://graph.microsoft.com/$ver/me/mailFolders/$a" + '?$select=id,displayName,totalItemCount,childFolderCount'
            try {
                $r = Invoke-MgGraphRequest -Method GET -Uri $uri
                Ok ("{0,-6} {1,-28} -> '{2}'  items={3}  children={4}" -f $ver, $a, $r.displayName, $r.totalItemCount, $r.childFolderCount)
                if (-not (Get-Variable -Name foundRootId -Scope Script -ErrorAction SilentlyContinue)) {
                    $script:foundRootId = $r.id
                }
            }
            catch {
                $msg = $_.ErrorDetails.Message ?? $_.Exception.Message
                No ("{0,-6} {1,-28} -> {2}" -f $ver, $a, ($msg -replace '\s+', ' ').Substring(0, [Math]::Min(140, $msg.Length)))
            }
        }
    }

    Write-Host "`n  Top-level mailFolders (includeHiddenFolders=true) - looking for archive-related entries:" -ForegroundColor Cyan
    $uri = 'https://graph.microsoft.com/v1.0/me/mailFolders?includeHiddenFolders=true&$top=100&$select=id,displayName,totalItemCount,childFolderCount'
    (Invoke-MgGraphRequest -Method GET -Uri $uri).value |
        ForEach-Object { Info ("{0,-40} items={1,-7} children={2}" -f $_.displayName, $_.totalItemCount, $_.childFolderCount) }

    # ── PART 1b: Microsoft Search API — the door Graph MAY have left open ─────
    # OWA's search covers Online Archives (auto-expanded included). If
    # /search/query surfaces the known 2022 archive-only message, and its id /
    # parentFolderId resolve via /me/messages and /me/mailFolders, we can walk
    # UP the parent chain to the archive root by ID — bypassing the broken
    # well-known names entirely and keeping the whole Graph-based MCP design.
    Write-Host "`n  PART 1b: /search/query probes for the known 2022 archive message" -ForegroundColor Cyan
    # The primary Archive folder's span starts ~2023-07-24 (fix briefing §7), so
    # any hit received before this cutoff can only live in the Online Archive.
    $archiveCutoff = [datetime]'2023-07-01'
    # The known-bad primary-mailbox Archive folder id (briefing §7 negative test).
    $primaryArchiveFolderId = 'AAMkAGI1NjNkMTUzLTkyMmMtNDliMC1iNjZjLTU0Njc1ZTk2MTcxOAAuAAAAAAB9FPlyDXUwQInaeF1jLtb3AQBiwv40ZdttQaPCXtEU8YCCAAAAAA03AAA='
    $hits = @()
    try {
        # The known archive-resident message (confirmed from the .msg export):
        # From: Alyssa Arwood  Subject: [HELPDESK] Access for Melissa  2022-04-20
        $queries = @(
            'subject:"Access for Melissa" received<2023-01-01'
            'subject:"Access for Melissa"'
            '"Access for Melissa"'
            'HELPDESK Melissa Arwood'
            '"payroll@gipartners.com"'
        )
        $firstRaw = $null
        $hitVer = $null; $hitQuery = $null; $hitTotal = 0
        foreach ($ver in @('v1.0', 'beta')) {
            foreach ($q in $queries) {
                $searchBody = @{
                    requests = @(@{
                        entityTypes = @('message')
                        query       = @{ queryString = $q }
                        from        = 0
                        size        = 25
                    })
                } | ConvertTo-Json -Depth 6
                $sr = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/$ver/search/query" `
                          -Body $searchBody -ContentType 'application/json'
                if (-not $firstRaw) { $firstRaw = $sr | ConvertTo-Json -Depth 10 }
                # Zero-result responses omit the 'hits' key entirely — index as
                # hashtable keys (StrictMode-safe) and filter nulls: @($null)
                # is a ONE-element array, which faked a hit on an earlier run.
                $container = $sr['value'][0]['hitsContainers'][0]
                $total = [int]$container['total']
                $hits = @($container['hits'] | Where-Object { $null -ne $_ })
                Info ("{0,-6} query [{1}] -> total={2}" -f $ver, $q, $total)
                if ($hits.Count) { $hitVer = $ver; $hitQuery = $q; $hitTotal = $total; break }
            }
            if ($hits.Count) { break }
        }
        # Relevance ranking buries old items — page through EVERYTHING the
        # productive query matched (cap 200) so the global oldest is real.
        if ($hits.Count -and $hitTotal -gt $hits.Count) {
            $from = $hits.Count
            while ($from -lt $hitTotal -and $from -lt 200) {
                $searchBody = @{
                    requests = @(@{
                        entityTypes = @('message')
                        query       = @{ queryString = $hitQuery }
                        from        = $from
                        size        = 25
                    })
                } | ConvertTo-Json -Depth 6
                $sr = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/$hitVer/search/query" `
                          -Body $searchBody -ContentType 'application/json'
                $page = @($sr['value'][0]['hitsContainers'][0]['hits'] | Where-Object { $null -ne $_ })
                if (-not $page.Count) { break }
                $hits += $page
                $from += $page.Count
            }
            Info ("paged through {0} of {1} total hits" -f $hits.Count, $hitTotal)
        }
        if (-not $hits.Count -and $firstRaw) {
            Info 'Raw first response (truncated):'
            Info $firstRaw.Substring(0, [Math]::Min(1500, $firstRaw.Length))
        }
    }
    catch {
        No "search/query probe failed: $((($_.ErrorDetails.Message ?? $_.Exception.Message) -replace '\s+',' ').Substring(0,200))"
    }
    if (-not $hits.Count) {
        No 'No query surfaced the archive message - Search API likely does not cover the Online Archive.'
    }
    else {
        # DATETIME sort/compare — a string compare here produced a false verdict
        # on an earlier run ('12/02/2024' -lt '2023' is lexicographically true).
        $sorted = $hits | Sort-Object { [datetime]$_['resource']['receivedDateTime'] }
        Ok "collected $($sorted.Count) hit(s); oldest 20:"
        foreach ($h in ($sorted | Select-Object -First 20)) {
            $res = $h['resource']
            Info ("  {0:yyyy-MM-dd}  {1}" -f [datetime]$res['receivedDateTime'], ($res['subject'] ?? '(no subject)'))
        }
        $oldest = $sorted | Select-Object -First 1
        $oldestDt = [datetime]$oldest['resource']['receivedDateTime']
        if ($oldestDt -lt $archiveCutoff) {
            Ok "VERDICT: oldest hit ($($oldestDt.ToString('yyyy-MM-dd'))) predates the primary Archive folder's span -> Search API DOES reach Online Archive content."
        }
        else {
            Write-Host "  [warn] VERDICT: nothing before $($archiveCutoff.ToString('yyyy-MM-dd')) in $($sorted.Count) hits - Search API is likely NOT covering the archive." -ForegroundColor Yellow
        }
        # Message ids can contain '+' and '/' - escape before using in a URL path.
        $mid = [uri]::EscapeDataString([string]($oldest['hitId'] ?? $oldest['resource']['id']))
        Write-Host "`n  Chasing oldest hit ($($oldestDt.ToString('yyyy-MM-dd'))) by id..." -ForegroundColor Cyan
        try {
            $msg = Invoke-MgGraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/me/messages/$mid" + '?$select=id,subject,receivedDateTime,parentFolderId')
            Ok "GET /me/messages/{id} works: '$($msg['subject'])' ($($msg['receivedDateTime']))"
            # Walk the parentFolderId chain upward - if these resolve, id-based
            # folder addressing works and the archive root is reachable.
            $fid = $msg['parentFolderId']
            $hops = 0
            while ($fid -and $hops -lt 10) {
                $fidEsc = [uri]::EscapeDataString([string]$fid)
                try {
                    $f = Invoke-MgGraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/me/mailFolders/$fidEsc" + '?$select=id,displayName,parentFolderId,totalItemCount,childFolderCount')
                }
                catch {
                    No "  parent-chain hop $hops failed: $((($_.ErrorDetails.Message ?? $_.Exception.Message) -replace '\s+',' ').Substring(0,120))"
                    break
                }
                Ok ("  hop {0}: '{1}'  items={2}  children={3}" -f $hops, $f['displayName'], $f['totalItemCount'], $f['childFolderCount'])
                Info ("         id: {0}" -f $f['id'])
                if ($f['id'] -ceq $primaryArchiveFolderId) {
                    Write-Host '         ^^ this is the PRIMARY mailbox Archive-button folder (known-bad id) - hit is NOT archive-resident.' -ForegroundColor Yellow
                }
                $parentId = $f['parentFolderId']
                if (-not $parentId -or $parentId -eq $f['id']) { Info '         (top of chain)'; break }
                $fid = $parentId
                $hops++
            }
        }
        catch {
            No "GET /me/messages/{id} failed: $((($_.ErrorDetails.Message ?? $_.Exception.Message) -replace '\s+',' ').Substring(0,160))"
        }
    }
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}

# ── PART 2: Exchange Online archive configuration ─────────────────────────────
if ($SkipExchangePart) {
    Info 'PART 2 skipped (-SkipExchangePart).'
}
else {
    Write-Host "`n=== PART 2: Exchange archive config (sign in as super-jmonaco when prompted) ===" -ForegroundColor Cyan
    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
        Write-Host '  [warn] ExchangeOnlineManagement module not installed - skipping. Install-Module ExchangeOnlineManagement' -ForegroundColor Yellow
    }
    else {
        try {
            Import-Module ExchangeOnlineManagement
            # The WAM runtime broker crashes with NullReferenceException on this
            # machine (observed twice, 2026-07-21). Only proceed if the module
            # can bypass WAM entirely - attempting the default path just crashes.
            if (-not (Get-Command Connect-ExchangeOnline).Parameters.ContainsKey('DisableWAM')) {
                Write-Host '  [warn] This ExchangeOnlineManagement version lacks -DisableWAM and the WAM broker crashes on this machine.' -ForegroundColor Yellow
                Write-Host '         Run:  Update-Module ExchangeOnlineManagement -Force   (needs v3.5+), then re-run this script.' -ForegroundColor Yellow
            }
            else {
                Connect-ExchangeOnline -ShowBanner:$false -DisableWAM
                $mbx = Get-Mailbox -Identity $Upn |
                       Select-Object DisplayName, ArchiveStatus, ArchiveState, ArchiveGuid,
                                     AutoExpandingArchiveEnabled, ArchiveQuota, ArchiveWarningQuota
                $mbx | Format-List | Out-String | Write-Host
                $org = Get-OrganizationConfig | Select-Object AutoExpandingArchiveEnabled
                Write-Host ("  Org-level AutoExpandingArchiveEnabled: {0}" -f $org.AutoExpandingArchiveEnabled)
                try {
                    Get-MailboxLocation -User $Upn -ErrorAction Stop |
                        Select-Object MailboxLocationType, MailboxGuid |
                        Format-Table | Out-String | Write-Host
                } catch { Info "Get-MailboxLocation unavailable: $($_.Exception.Message)" }
            }
        }
        finally {
            Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

Write-Host "`nPaste the full output back to Claude." -ForegroundColor Cyan
