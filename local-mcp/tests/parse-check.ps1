$files = @(
  '..\src\Lib\ConvertTo-KqlQuery.ps1',
  '..\src\Lib\Write-AuditLog.ps1',
  '.\Pester\ConvertTo-KqlQuery.Injection.Tests.ps1'
)
foreach ($f in $files) {
  $tokens = $errors = $null
  $abs = (Resolve-Path (Join-Path $PSScriptRoot $f)).Path
  [System.Management.Automation.Language.Parser]::ParseFile($abs, [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors.Count -gt 0) {
    Write-Host "FAIL: $f"
    $errors | ForEach-Object { Write-Host "  $($_.Message) @ line $($_.Extent.StartLineNumber)" }
  } else {
    Write-Host "OK:   $f"
  }
}
