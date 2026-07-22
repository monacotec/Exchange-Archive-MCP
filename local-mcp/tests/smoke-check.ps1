Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\src\Lib\ConvertTo-KqlQuery.ps1')
. (Join-Path $PSScriptRoot '..\src\Lib\Write-AuditLog.ps1')

$pass = 0; $fail = 0
function Check($name, [scriptblock]$cond) {
  $ok = & $cond
  if ($ok) { $script:pass++; Write-Host "  PASS  $name" }
  else     { $script:fail++; Write-Host "  FAIL  $name" }
}
function CheckThrows($name, [scriptblock]$action, [string]$match) {
  $threw = $false; $msg = ''
  try { & $action | Out-Null } catch { $threw = $true; $msg = $_.Exception.Message }
  if ($threw -and $msg -like "*$match*") { $script:pass++; Write-Host "  PASS  $name" }
  else { $script:fail++; Write-Host "  FAIL  $name (threw=$threw msg='$msg')" }
}

Write-Host '=== ConvertTo-KqlQuery hardening ==='
CheckThrows 'rejects oversize input' { ConvertTo-KqlQuery -Query ('a' * 2001) } 'maximum length'
Check       'accepts at-limit input' { (ConvertTo-KqlQuery -Query ('a' * 2000)).Length -ge 2000 }
CheckThrows 'rejects LF'      { ConvertTo-KqlQuery -Query ("from:a@x" + [char]0x0A + "from:b@x") } 'control or bidi'
CheckThrows 'rejects CR'      { ConvertTo-KqlQuery -Query ("subj" + [char]0x0D + "more") } 'control or bidi'
CheckThrows 'rejects NUL'     { ConvertTo-KqlQuery -Query ("ok" + [char]0x00 + "bad") } 'control or bidi'
CheckThrows 'rejects TAB'     { ConvertTo-KqlQuery -Query ("a" + [char]0x09 + "b") } 'control or bidi'
CheckThrows 'rejects DEL'     { ConvertTo-KqlQuery -Query ("a" + [char]0x7F + "b") } 'control or bidi'
CheckThrows 'rejects U+202E'  { ConvertTo-KqlQuery -Query ("a" + [char]0x202E + "b") } 'control or bidi'
CheckThrows 'rejects U+2066'  { ConvertTo-KqlQuery -Query ("a" + [char]0x2066 + "b") } 'control or bidi'

Write-Host '=== ConvertTo-KqlQuery regression ==='
Check 'pass field operator'         { (ConvertTo-KqlQuery -Query 'from:alice@x.com') -eq 'from:alice@x.com' }
Check 'after: -> received>='        { (ConvertTo-KqlQuery -Query 'after:2024-01-01') -eq 'received>=2024-01-01' }
Check 'before: -> received<='       { (ConvertTo-KqlQuery -Query 'before:2024-12-31') -eq 'received<=2024-12-31' }
Check 'has:attachment -> hasAttachments:true' { (ConvertTo-KqlQuery -Query 'has:attachment') -eq 'hasAttachments:true' }
Check 'multi-word free text quoted' { (ConvertTo-KqlQuery -Query 'quarterly board meeting') -eq '"quarterly board meeting"' }
Check 'single-word free text raw'   { (ConvertTo-KqlQuery -Query 'invoice') -eq 'invoice' }
Check 'mixed query not phrase-quoted' { -not (ConvertTo-KqlQuery -Query 'from:bob@x.com invoice').StartsWith('"') }
Check 'embedded quote escaped'      { (ConvertTo-KqlQuery -Query 'they said "go"') -eq '"they said \"go\""' }
Check 'whitespace only -> ""'       { (ConvertTo-KqlQuery -Query '   ') -eq '""' }
Check 'case-insensitive FROM:'      { (ConvertTo-KqlQuery -Query 'FROM:alice@x.com') -eq 'FROM:alice@x.com' }
Check 'case-insensitive After:'     { (ConvertTo-KqlQuery -Query 'After:2026-01-01') -eq 'received>=2026-01-01' }

Write-Host '=== Write-AuditLog routing ==='
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("audit-test-" + [guid]::NewGuid().ToString('N'))
try {
  Write-AuditLog -Tool 'archive_search' -Mode 'read' -CallerUpn 'jeff@x' -ParamsRedacted @{} -AuditDir $tmp
  Write-AuditLog -Tool 'archive_move'   -Mode 'execute' -CallerUpn 'jeff@x' -ParamsRedacted @{} -AuditDir $tmp
  Write-AuditLog -Tool 'archive_search' -Mode 'error' -CallerUpn 'jeff@x' -ParamsRedacted @{} -AuditDir $tmp
  $day = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
  $writePath = Join-Path $tmp "$day.jsonl"
  $debugPath = Join-Path $tmp "debug\$day.jsonl"
  Check 'durable audit file exists' { Test-Path $writePath }
  Check 'debug audit file exists'   { Test-Path $debugPath }
  Check 'durable file has execute' { (Get-Content $writePath -Raw) -match '"mode":"execute"' }
  Check 'durable file has error'   { (Get-Content $writePath -Raw) -match '"mode":"error"' }
  Check 'durable file has NO read' { -not ((Get-Content $writePath -Raw) -match '"mode":"read"') }
  Check 'debug file has read'      { (Get-Content $debugPath -Raw) -match '"mode":"read"' }

  # Verify read mode forcibly empties params even if caller passes data.
  Write-AuditLog -Tool 'archive_search' -Mode 'read' -CallerUpn 'jeff@x' `
    -ParamsRedacted @{ query = 'CONFIDENTIAL board minutes Q3' } -AuditDir $tmp
  $debugContent = Get-Content $debugPath -Raw
  Check 'read mode strips params'  { -not ($debugContent -match 'CONFIDENTIAL') }
} finally {
  if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
}

Write-Host ""
Write-Host "RESULT: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
