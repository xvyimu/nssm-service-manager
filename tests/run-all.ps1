#requires -Version 7.0
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'

function Invoke-Check([string]$label, [scriptblock]$action) {
  Write-Output "== $label =="
  & $action
  if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    throw "$label failed with exit code $LASTEXITCODE."
  }
}

$powershellFiles = @(Get-ChildItem -LiteralPath $RepoRoot -Filter '*.ps1' -File -Recurse |
  Where-Object { $_.FullName -notmatch '\\logs\\' })

Invoke-Check 'PowerShell parser' {
  foreach ($file in $powershellFiles) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
      $file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) {
      throw "$($file.FullName): $($errors[0].Message)"
    }
  }
  Write-Output "PASS: parsed $($powershellFiles.Count) PowerShell files."
}

$tests = @(
  @{ Name = 'launcher'; Args = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'test-launcher.ps1')) }
  @{ Name = 'GUI smoke'; Args = @('-NoProfile', '-STA', '-File', (Join-Path $PSScriptRoot 'test-gui-smoke.ps1')) }
  @{ Name = 'card actions'; Args = @('-NoProfile', '-STA', '-File', (Join-Path $PSScriptRoot 'test-card-actions.ps1')) }
  @{ Name = 'card cache'; Args = @('-NoProfile', '-STA', '-File', (Join-Path $PSScriptRoot 'test-card-cache.ps1')) }
  @{ Name = 'transition race'; Args = @('-NoProfile', '-STA', '-File', (Join-Path $PSScriptRoot 'test-transition-race.ps1')) }
  @{ Name = 'poll commands'; Args = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'test-poll-commands.ps1')) }
  @{ Name = 'parallel probe'; Args = @('-NoProfile', '-STA', '-File', (Join-Path $PSScriptRoot 'test-parallel-probe.ps1')) }
  @{ Name = 'security parse'; Args = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'test-security-parse.ps1')) }
  @{ Name = 'svc input'; Args = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'test-svc-input.ps1')) }
  @{ Name = 'service registration'; Args = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'test-add-svc.ps1')) }
  @{ Name = 'config round-trip'; Args = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'test-config.ps1')) }
  @{ Name = 'config params';     Args = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'test-config-params.ps1')) }
  @{ Name = 'single instance'; Args = @('-NoProfile', '-STA', '-File', (Join-Path $PSScriptRoot 'test-single-instance.ps1')) }
  @{ Name = 'remove async'; Args = @('-NoProfile', '-STA', '-File', (Join-Path $PSScriptRoot 'test-remove-async.ps1')) }
)

foreach ($test in $tests) {
  $arguments = $test.Args
  Invoke-Check $test.Name { & pwsh @arguments }
}

Write-Output "PASS: $($tests.Count) regression tests and parser check completed."
