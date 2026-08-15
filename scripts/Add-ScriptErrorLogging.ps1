#Requires -Version 7.0
<#
.SYNOPSIS
    Sweep two reliability fixes across the repo's operator scripts.

.DESCRIPTION
    FIX 1 - ERRORS THAT NEVER REACH THE LOG.
    A terminating error propagates PAST the finally block, so it prints to the
    console only AFTER Stop-Transcript has run: the transcript ends mid-section
    with no reason recorded and the operator has to copy the error out of the
    terminal by hand. This cost three round trips before it was worth fixing
    everywhere. Inserts a catch that logs the message and the failing line
    before rethrowing, into any script that has a transcript and a top-level
    try/finally but no catch between them.

    FIX 2 - THE AUTH PROBE CHECKED THE WRONG AUDIENCE.
    The probe requested a token for https://management.azure.com/ and treated
    success as "the session is live". On 2026-08-14 that probe PASSED and the
    very next ARM call failed with AADSTS70043 token_expired, because the CLI
    used a different audience (management.core.windows.net) whose cached token
    had separately expired. A token request for one audience proves nothing
    about another. Replaced with a real, cheap ARM read (resource-group show)
    against the group the script is about to use -- the same code path, so a
    pass actually means the next call will work.

    Idempotent: both edits are marked, and marked files are skipped. Every
    modified file is re-parsed; a parse failure restores the original and
    reports it.

.EXAMPLE
    .\Add-ScriptErrorLogging.ps1            # report what would change
.EXAMPLE
    .\Add-ScriptErrorLogging.ps1 -Apply
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]] $Path,
    [string]   $RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]   $Apply
)

$version = '1.0.0'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ok   ([string]$m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Bad  ([string]$m) { Write-Host "  [!!] $m" -ForegroundColor Red }
function Info ([string]$m) { Write-Host "  $m" -ForegroundColor Yellow }
function Step ([string]$m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

$MARK_CATCH = '# sweep:error-logging'
$MARK_PROBE = '# sweep:auth-probe'

$catchBlock = @"
catch {
    $MARK_CATCH -- a terminating error propagates PAST finally, so without this
    # it prints to the console only after Stop-Transcript has run and the log
    # ends with no reason recorded. Log it, then rethrow.
    Write-Host "  [!!] unhandled error: `$(`$_.Exception.Message)" -ForegroundColor Red
    if (`$_.InvocationInfo) { Write-Host "       at line `$(`$_.InvocationInfo.ScriptLineNumber): `$(`$_.InvocationInfo.Line.Trim())" -ForegroundColor DarkGray }
    throw
}
"@

if (-not $Path) {
    $Path = @(Get-ChildItem (Join-Path $RepoRoot 'foundry-mcp\scripts') -Filter *.ps1 | Select-Object -ExpandProperty FullName)
}

$changedCatch = 0; $changedProbe = 0; $skipped = 0
foreach ($file in $Path) {
    $name = Split-Path $file -Leaf
    $original = Get-Content -LiteralPath $file -Raw
    $text = $original
    $did = @()

    # ── Fix 1: catch before the transcript's finally ──────────────────────────
    # Detected via the AST, not text: "is there already a catch on this try?" is
    # exactly what TryStatementAst.CatchClauses answers, and a text match on
    # "catch {" cannot tell an inner retry-catch (or a preceding closing brace)
    # from the top-level one -- which is how a first attempt at this tried to
    # give Set-ResourceTags.ps1 a second catch block.
    if ($text -match 'Start-Transcript' -and $text -notmatch [regex]::Escape($MARK_CATCH)) {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
        $tryWithTranscript = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.TryStatementAst] -and
            $n.Finally -and $n.Finally.Extent.Text -match 'Stop-Transcript'
        }, $true) | Select-Object -First 1

        if (-not $tryWithTranscript) {
            # LINEAR script: Start-Transcript ... Stop-Transcript with no
            # try/finally to hang a catch on. A trap does the same job -- it runs
            # on a terminating error, so the reason reaches the log before the
            # script dies, and it closes the transcript on the way out.
            $st = [regex]::Match($text, '(?m)^Start-Transcript[^\r\n]*\r?\n')
            if ($st.Success) {
                $trapBlock = @"

trap {
    $MARK_CATCH (linear script) -- no try/finally here, so without this a
    # terminating error kills the run and the transcript ends with no reason
    # recorded. Log it, close the transcript, then rethrow.
    Write-Host "  [!!] unhandled error: `$(`$_.Exception.Message)" -ForegroundColor Red
    if (`$_.InvocationInfo) { Write-Host "       at line `$(`$_.InvocationInfo.ScriptLineNumber): `$(`$_.InvocationInfo.Line.Trim())" -ForegroundColor DarkGray }
    try { Stop-Transcript | Out-Null } catch { }
    break
}

"@
                $text = $text.Insert($st.Index + $st.Length, $trapBlock)
                $did += 'trap'
            }
        }
        elseif ($tryWithTranscript.CatchClauses.Count -eq 0) {
            # NOTE: TryStatementAst.Finally is the statement BLOCK, so its extent
            # starts at the '{' -- not at the 'finally' keyword. Inserting there
            # splices into the middle of the statement and yields "The Try
            # statement is missing its Catch or Finally block". Step back to the
            # keyword itself.
            $blockStart = $tryWithTranscript.Finally.Extent.StartOffset
            $kw = $text.LastIndexOf('finally', $blockStart, [StringComparison]::OrdinalIgnoreCase)
            if ($kw -lt 0) { Bad "$name - could not locate the finally keyword; skipped"; $skipped++; continue }
            $text = $text.Insert($kw, "$catchBlock`n")
            $did += 'catch'
        }
    }

    # ── Fix 2: probe with a real ARM call, not a token request ────────────────
    # Both spellings seen in the repo: '-o json' and '--output none'.
    $probePattern = "(?m)^(\s*)(?:\`$null = )?az account get-access-token --resource 'https://management\.azure\.com/' (?:-o json|--output none) 2>\`$null\r?\n"
    if ($text -notmatch [regex]::Escape($MARK_PROBE) -and [regex]::IsMatch($text, $probePattern)) {
        $replacement = {
            param($mm)
            $indent = $mm.Groups[1].Value
            @(
                "$indent$MARK_PROBE -- a token for management.azure.com does NOT prove the"
                "$indent# CLI's other ARM audience is still valid: on 2026-08-14 this probe passed"
                "$indent# and the next call failed AADSTS70043. Probe with a real read instead."
                "$indent`$null = az group show -n `$ResourceGroup -o none 2>`$null"
                ''
            ) -join "`n"
        }
        $text = [regex]::Replace($text, $probePattern, $replacement)
        $did += 'probe'
    }

    if (-not $did.Count) { $skipped++; continue }

    Write-Host "  $name -> $($did -join ' + ')" -ForegroundColor Cyan
    if (-not $Apply) { continue }
    if (-not $PSCmdlet.ShouldProcess($name, "apply $($did -join ' + ')")) { continue }

    Set-Content -LiteralPath $file -Value $text -NoNewline
    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]([ref]$errs).Value) | Out-Null
    $parse = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$parse) | Out-Null
    if ($parse -and $parse.Count) {
        Set-Content -LiteralPath $file -Value $original -NoNewline
        Bad "$name - parse error after edit, reverted: $($parse[0].Message)"
        continue
    }
    if ($did -contains 'catch') { $changedCatch++ }
    if ($did -contains 'probe') { $changedProbe++ }
    Ok "$name updated"
}

Write-Host ''
Write-Host ("catch added: {0}   probe fixed: {1}   already current: {2}" -f $changedCatch, $changedProbe, $skipped) -ForegroundColor Cyan
if (-not $Apply) { Write-Host 'DRY RUN - re-run with -Apply to write.' -ForegroundColor Yellow }
