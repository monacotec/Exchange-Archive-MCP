#Requires -Version 7.0
<#
.SYNOPSIS
    Tag every Azure resource belonging to this project (default: report only).

.DESCRIPTION
    Applies Project = 'Exchange Archive MCP' (plus any -AdditionalTags) to the
    resources this suite owns, so cost and ownership can be answered from the
    portal rather than guessed. Pattern lifted from the archived Foundry
    project's uniform tagging -- see docs/gi-foundry-lessons.md section 2.4.

    TWO THINGS THIS DELIBERATELY GETS RIGHT:

      1. MERGE, NEVER REPLACE. 'az resource tag --tags' REPLACES the whole tag
         set, silently dropping anything already there. This uses
         'az tag update --operation Merge', which adds/updates only the keys
         given and leaves every other tag intact.

      2. THIS PROJECT'S RESOURCES ONLY. finresgroup is a shared resource group,
         so tagging everything in it would mislabel other people's resources.
         Selection is by name pattern (-Pattern) and shown for review before
         anything is written. -All overrides that, and says so loudly.

    Default run reports what WOULD change and mutates nothing. -Apply writes.
    Re-running after success is a no-op: already-correct resources report [OK].

.EXAMPLE
    .\Set-ResourceTags.ps1                 # show the plan
.EXAMPLE
    .\Set-ResourceTags.ps1 -Apply          # apply it
.EXAMPLE
    .\Set-ResourceTags.ps1 -Apply -AdditionalTags @{ Owner='IT-Infrastructure'; CostCenter='IT-AI' }
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]    $ProjectTagValue = 'Exchange Archive MCP',
    [string]    $TagName         = 'Project',
    # Defaults, not opt-in: these are the standing convention, and they must match
    # what the templates declare (main.bicep tags var, sqlhost.bicep tags default)
    # or every deployment would strip whichever side is missing them.
    [hashtable] $AdditionalTags  = @{ Owner = 'IT-Infrastructure'; CostCenter = 'IT-AI' },
    [string]    $ResourceGroup   = 'finresgroup',
    [string]    $SubscriptionId  = 'db17a4a4-f677-498a-b4a2-eb401ba9cf29',
    [string]    $TenantId        = '9c1b0b26-717a-4eda-9d7e-7eebc00066bf',
    # Name fragments that identify this project's resources in a shared group.
    [string[]]  $Pattern         = @('exchange-mcp', 'exmcp', 'gip-mcp-hub-sql',
                                     'gi-exchange-archive-mcp', 'archive-mailbox-mcp'),
    [switch]    $All,
    [switch]    $Apply
)

$version = '1.1.0'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:LogDir = Join-Path $PSScriptRoot '..\logs'
if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
$script:LogPath = Join-Path (Resolve-Path $script:LogDir).Path ("resource-tags-{0}.log" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
Start-Transcript -Path $script:LogPath | Out-Null

$issues = [System.Collections.Generic.List[string]]::new()
function Step ([string]$m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Ok   ([string]$m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Bad  ([string]$m) { Write-Host "  [!!] $m" -ForegroundColor Red; [void]$issues.Add($m) }
function Info ([string]$m) { Write-Host "  $m" -ForegroundColor Yellow }
function Note ([string]$m) { Write-Host "  $m" }
function Mutate ([string]$m) { Write-Host ("  {0}  MUTATE  {1}" -f (Get-Date).ToUniversalTime().ToString('o'), $m) -ForegroundColor DarkGray }

Write-Host "Set-ResourceTags $version" -ForegroundColor Cyan
Write-Host "Log: $script:LogPath" -ForegroundColor DarkGray

try {
    # ── 1. Auth ───────────────────────────────────────────────────────────────
    Step '1. Azure sign-in'
    $acct = az account show -o json 2>$null | ConvertFrom-Json
    if (-not $acct) { az login --tenant $TenantId --output none; $acct = az account show -o json | ConvertFrom-Json }
    if ($acct.id -ne $SubscriptionId) { az account set --subscription $SubscriptionId }
    $null = az account get-access-token --resource 'https://management.azure.com/' -o json 2>$null
    if ($LASTEXITCODE -ne 0) {
        Info 'cached session stale (CA sign-in frequency) - re-authenticating'
        az logout 2>$null; az login --tenant $TenantId --output none; az account set --subscription $SubscriptionId
    }
    Ok "signed in as $((az account show -o json | ConvertFrom-Json).user.name)"

    # ── 2. Select resources ───────────────────────────────────────────────────
    Step "2. Resources in $ResourceGroup"
    $all = @(az resource list -g $ResourceGroup -o json | ConvertFrom-Json)
    if (-not $all.Count) { throw "No resources found in $ResourceGroup." }
    Ok "$($all.Count) resource(s) in the group"

    if ($All) {
        $selected = $all
        Info 'ALL selected: every resource in this group will be tagged, including any'
        Info 'that belong to other workloads. Review the list below carefully.'
    } else {
        $selected = @($all | Where-Object {
            $n = $_.name.ToLower()
            $hit = $false
            foreach ($p in $Pattern) { if ($n -like "*$($p.ToLower())*") { $hit = $true; break } }
            $hit
        })
        $skipped = @($all | Where-Object { $_.id -notin $selected.id })
        Ok "$($selected.Count) match this project"
        if ($skipped.Count) {
            Info "$($skipped.Count) resource(s) NOT matched and left alone:"
            $skipped | ForEach-Object { Note "    - $($_.name)  [$($_.type)]" }
            Info 'If any of those belong to this project, add a fragment via -Pattern (or use -All).'
        }
    }
    if (-not $selected.Count) { throw 'Nothing selected -- adjust -Pattern or pass -All.' }

    # Child resources (e.g. SQL databases) are not returned by 'az resource list'
    # at the group level in every API version -- pull databases explicitly so the
    # archive index gets tagged too.
    $sqlServers = @($selected | Where-Object { $_.type -eq 'Microsoft.Sql/servers' })
    foreach ($srv in $sqlServers) {
        $dbs = @(az sql db list -g $ResourceGroup -s $srv.name -o json 2>$null | ConvertFrom-Json |
                 Where-Object { $_.name -ne 'master' })
        foreach ($db in $dbs) {
            if ($selected.id -notcontains $db.id) {
                $selected += [PSCustomObject]@{ id = $db.id; name = "$($srv.name)/$($db.name)"; type = 'Microsoft.Sql/servers/databases'; tags = $db.tags }
            }
        }
    }

    # ── 3. Plan ───────────────────────────────────────────────────────────────
    Step '3. Tag plan'
    $desired = @{ $TagName = $ProjectTagValue }
    foreach ($k in $AdditionalTags.Keys) { $desired[$k] = [string]$AdditionalTags[$k] }
    Info ("tags: " + (($desired.GetEnumerator() | ForEach-Object { "$($_.Key)='$($_.Value)'" }) -join '  '))

    $toChange = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $selected) {
        $current = @{}
        if ($r.PSObject.Properties.Match('tags').Count -gt 0 -and $r.tags) {
            foreach ($p in $r.tags.PSObject.Properties) { $current[$p.Name] = [string]$p.Value }
        }
        $needs = @($desired.Keys | Where-Object { -not $current.ContainsKey($_) -or $current[$_] -ne $desired[$_] })
        if ($needs.Count -eq 0) {
            Ok "$($r.name) - already tagged"
        } else {
            $existingNote = if ($current.Count) { " (keeps $($current.Count) existing tag(s))" } else { '' }
            Note "  will set $($needs -join ', ') on $($r.name)  [$($r.type)]$existingNote"
            [void]$toChange.Add($r)
        }
    }
    Ok "$($toChange.Count) resource(s) need tagging"

    # ── 4. Apply ──────────────────────────────────────────────────────────────
    if (-not $Apply) {
        Write-Host ''
        Write-Host 'DRY RUN - nothing was changed. Re-run with -Apply to write these tags.' -ForegroundColor Yellow
    } elseif ($toChange.Count -eq 0) {
        Write-Host ''
        Write-Host 'ALL RESOURCES ALREADY TAGGED' -ForegroundColor Green
    } else {
        Step '4. Apply tags (merge)'
        $tagArgs = @($desired.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
        foreach ($r in $toChange) {
            if (-not $PSCmdlet.ShouldProcess($r.name, "merge tags")) { continue }
            Mutate "az tag update --operation Merge on $($r.name)"
            # Merge preserves tags this script does not manage.
            az tag update --resource-id $r.id --operation Merge --tags @tagArgs -o none 2>$null
            if ($LASTEXITCODE -eq 0) { Ok "tagged: $($r.name)" }
            else { Bad "could not tag $($r.name) [$($r.type)] - the type may not support tags" }
        }

        Step '5. Verify'
        foreach ($r in $selected) {
            $live = az tag list --resource-id $r.id -o json 2>$null | ConvertFrom-Json
            $val = $null
            if ($live -and $live.properties -and $live.properties.tags) {
                $prop = $live.properties.tags.PSObject.Properties | Where-Object { $_.Name -eq $TagName }
                if ($prop) { $val = [string]$prop.Value }
            }
            if ($val -eq $ProjectTagValue) { Ok "$($r.name) -> $TagName='$val'" }
            else { Bad "$($r.name) - $TagName is '$val', expected '$ProjectTagValue'" }
        }
    }

    Write-Host ''
    if ($issues.Count -eq 0) {
        if ($Apply) { Write-Host 'ALL CHECKS GREEN' -ForegroundColor Green }
    } else {
        Write-Host "PROBLEMS ($($issues.Count)):" -ForegroundColor Red
        for ($i = 0; $i -lt $issues.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $issues[$i]) -ForegroundColor Red }
    }
}
finally {
    Write-Host "`nLog saved to: $script:LogPath" -ForegroundColor Cyan
    Stop-Transcript | Out-Null
}
if ($issues.Count -gt 0) { exit 1 }
