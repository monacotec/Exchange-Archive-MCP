# Version: 1.2.0
# Test-OutlookArchiveOpen.ps1 — D0 spike for OUTLOOK-DESKTOP-OPEN-PLAN.md.
#
# Validates whether classic Outlook desktop can locate an ONLINE-MODE Online
# Archive message and open it, via COM. v1.1 improvements after the v1.0 run
# returned 0 with the completion event not firing:
#   - scope to ONE archive (faster), default jmonaco's;
#   - pump the message loop (DoEvents) and poll Results up to a long timeout
#     instead of relying on the async AdvancedSearchComplete event;
#   - add a SUBJECT-search CONTROL: distinguishes "online archive not searchable
#     at all" (both fail) from "message-id specifically not indexed" (subject
#     works, message-id doesn't) -> which decides the handler's lookup key or
#     kills the approach.
#
# RUN ON JEFF'S WORKSTATION with classic Outlook OPEN as jmonaco. LOCAL ONLY —
# no Azure/Graph/admin. Read-only except the final .Display(). Self-relaunches
# under Windows PowerShell 5.1.

param(
    [string]$MessageId = '<BY5PR04MB7076EC79A15D313B9EBA12D2C7F59@BY5PR04MB7076.namprd04.prod.outlook.com>',
    [string]$SubjectProbe = 'Access for Melissa',
    [string]$ArchiveMatch = 'jmonaco',   # substring picking which archive store to scope to
    [int]$TimeoutSec = 120,
    [switch]$NoDisplay,
    [switch]$ListStoresOnly
)

if ($PSVersionTable.PSEdition -ne 'Desktop') {
    Write-Host 'Relaunching under Windows PowerShell 5.1...' -ForegroundColor Yellow
    $ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $a = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$PSCommandPath,
           '-MessageId',$MessageId,'-SubjectProbe',$SubjectProbe,'-ArchiveMatch',$ArchiveMatch,'-TimeoutSec',$TimeoutSec)
    if ($NoDisplay)      { $a += '-NoDisplay' }
    if ($ListStoresOnly) { $a += '-ListStoresOnly' }
    & $ps51 @a
    exit $LASTEXITCODE
}

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

function Ok  ($t) { Write-Host "  [PASS] $t" -ForegroundColor Green }
function No  ($t) { Write-Host "  [FAIL] $t" -ForegroundColor Red }
function Info($t) { Write-Host "  [info] $t" -ForegroundColor DarkGray }

# ── 1. Attach ─────────────────────────────────────────────────────────────────
Write-Host "`n=== 1. Outlook COM ===" -ForegroundColor Cyan
try {
    $ol = New-Object -ComObject Outlook.Application
    $ns = $ol.GetNamespace('MAPI')
    Ok "Attached to Outlook ($($ol.Version))."
}
catch { No "Could not attach to Outlook COM: $($_.Exception.Message)"; exit 1 }

# ── 2. Pick the target archive store ──────────────────────────────────────────
Write-Host "`n=== 2. Target archive store ===" -ForegroundColor Cyan
$target = $null
foreach ($store in $ns.Stores) {
    $name = $null; try { $name = $store.DisplayName } catch {}
    if ($name -match '(?i)online archive' -and $name -match [regex]::Escape($ArchiveMatch)) {
        try { $target = [pscustomobject]@{ Name = $name; Root = $store.GetRootFolder().FolderPath; Cached = $store.IsCachedExchange } } catch {}
        break
    }
}
if (-not $target) { No "No 'Online Archive' store matching '$ArchiveMatch'."; exit 1 }
Ok "Target: '$($target.Name)'  cached=$($target.Cached)"
if ($ListStoresOnly) { exit 0 }
$scope = "'" + $target.Root + "'"

# ── AdvancedSearch helper: poll Results with a pumped message loop ────────────
function Invoke-AdvSearch ($filter, $label) {
    Info "$label filter: $filter"
    $search = $ol.AdvancedSearch($scope, $filter, $true, 'giparchive-spike')
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $count = 0
    while ((Get-Date) -lt $deadline) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 750
        try { $count = $search.Results.Count } catch { $count = 0 }
        if ($count -gt 0) { break }
    }
    return @{ Search = $search; Count = $count }
}

$PROPTAG_MSGID = 'http://schemas.microsoft.com/mapi/proptag/0x1035001F'
function Normalize-MsgId ($s) { if (-not $s) { return '' } return $s.Trim().Trim('<','>').ToLower() }
$targetIdNorm = Normalize-MsgId $MessageId

# ── 3. Method A1 — mailheader:message-id (v1.0 approach, expected to fail) ─────
Write-Host "`n=== 3. Method A1: AdvancedSearch mailheader:message-id ===" -ForegroundColor Cyan
$idEsc = $MessageId.Replace("'", "''")
$a1 = Invoke-AdvSearch "`"urn:schemas:mailheader:message-id`" = '$idEsc'" 'mailheader:message-id'
if ($a1.Count -gt 0) { Ok "A1: $($a1.Count) match(es)." } else { No "A1: 0 matches." }

# ── 3b. Method A2 — PR_INTERNET_MESSAGE_ID proptag equality ───────────────────
Write-Host "`n=== 3b. Method A2: AdvancedSearch PR_INTERNET_MESSAGE_ID proptag ===" -ForegroundColor Cyan
$a2 = Invoke-AdvSearch "`"$PROPTAG_MSGID`" = '$idEsc'" 'proptag 0x1035001F'
if ($a2.Count -gt 0) { Ok "A2: $($a2.Count) match(es)." } else { No "A2: 0 matches." }

# ── 4. Method B — Subject (known-good), then Method C client-side id filter ───
Write-Host "`n=== 4. Method B: AdvancedSearch by Subject ===" -ForegroundColor Cyan
$subjEsc = $SubjectProbe.Replace("'", "''")
$b = Invoke-AdvSearch "`"urn:schemas:httpmail:subject`" like '%$subjEsc%'" 'Subject'
if ($b.Count -gt 0) { Ok "B: $($b.Count) match(es) on subject." } else { No "B: 0 matches." }

Write-Host "`n=== 4b. Method C: subject results filtered client-side by true Message-ID ===" -ForegroundColor Cyan
$cMatch = $null
if ($b.Count -gt 0) {
    for ($i = 1; $i -le $b.Search.Results.Count; $i++) {
        $it = $b.Search.Results.Item($i)
        $mid = ''
        try { $mid = $it.PropertyAccessor.GetProperty($PROPTAG_MSGID) } catch {}
        if ((Normalize-MsgId $mid) -eq $targetIdNorm) { $cMatch = $it; break }
    }
    if ($cMatch) { Ok "C: exact Message-ID match found within the subject results." }
    else { No "C: none of the subject results' Message-IDs matched (target may be an older thread item outside this subject probe)." }
}

# ── 5. Verdict — pick the best working lookup key ─────────────────────────────
Write-Host "`n=== 5. Verdict ===" -ForegroundColor Cyan
$winnerItem = $null
if ($a2.Count -gt 0) {
    Ok 'BEST: proptag 0x1035001F equality resolves the message directly. Handler keys on Message-ID alone (simplest).'
    $winnerItem = $a2.Search.Results.Item(1)
}
elseif ($cMatch) {
    Ok 'VIABLE: subject-search + client-side Message-ID filter. Handler keys on subject + Message-ID (robust).'
    $winnerItem = $cMatch
}
elseif ($a1.Count -gt 0) {
    Ok 'mailheader:message-id worked after all. Handler keys on Message-ID.'
    $winnerItem = $a1.Search.Results.Item(1)
}
elseif ($b.Count -gt 0) {
    Write-Host '  PARTIAL: subject searchable but no Message-ID path resolved the exact item.' -ForegroundColor Yellow
    Write-Host '  -> Handler would need subject + received + sender disambiguation. Workable but fragile.' -ForegroundColor Yellow
}
else {
    No 'NOT VIABLE: online-mode archive not searchable by any tested key.'
    exit 2
}

if ($winnerItem -and -not $NoDisplay) {
    Write-Host "`n  Opening the resolved message in Outlook..." -ForegroundColor Cyan
    Info ("  {0}  |  from={1}  received={2}" -f $winnerItem.Subject, $winnerItem.SenderName, $winnerItem.ReceivedTime)
    $winnerItem.Display()
    Ok 'Displayed. The winning lookup key above is what the giparchive: handler will use.'
}

Write-Host "`nPaste the output back to Claude." -ForegroundColor Cyan
