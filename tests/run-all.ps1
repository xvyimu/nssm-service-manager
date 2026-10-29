#requires -Version 7.0
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'

# 收集失败继续跑下一项，避免一个环境性/偶发失败掩掉后续结果
# （如沙箱挡 [IO.File]::Replace 导致 config round-trip 挂掉，后面 4 项根本没跑）。
# 解析阶段若挂了，后面的测试也无从执行——解析失败仍按硬错误直接抛。
$script:failures = @()

function Invoke-Check([string]$label, [scriptblock]$action) {
  Write-Output "== $label =="
  try {
    & $action
  } catch {
    if ($label -eq 'PowerShell parser') { throw }
    $script:failures += @{ Label=$label; Error=$_.Exception.Message }
    Write-Output "FAIL: $label — $($_.Exception.Message)"
    return
  }
  if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    $script:failures += @{ Label=$label; Error="exit code $LASTEXITCODE" }
    Write-Output "FAIL: $label — exit code $LASTEXITCODE"
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
  @{ Name = 'dispatcher priority'; Args = @('-NoProfile', '-STA', '-File', (Join-Path $PSScriptRoot 'test-dispatcher-priority.ps1')) }
  @{ Name = 'card actions'; Args = @('-NoProfile', '-STA', '-File', (Join-Path $PSScriptRoot 'test-card-actions.ps1')) }
  @{ Name = 'card clock'; Args = @('-NoProfile', '-STA', '-File', (Join-Path $PSScriptRoot 'test-card-clock.ps1')) }
  @{ Name = 'transition failure'; Args = @('-NoProfile', '-STA', '-File', (Join-Path $PSScriptRoot 'test-transition-failure.ps1')) }
  @{ Name = 'poll commands'; Args = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'test-poll-commands.ps1')) }
  @{ Name = 'per-service timeout'; Args = @('-NoProfile', '-STA', '-File', (Join-Path $PSScriptRoot 'test-per-service-timeout.ps1')) }
  @{ Name = 'svc input'; Args = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'test-svc-input.ps1')) }
  @{ Name = 'external timeout'; Args = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'test-external-timeout.ps1')) }
  @{ Name = 'log rotation'; Args = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'test-log-rotation.ps1')) }
  @{ Name = 'service registration'; Args = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'test-add-svc.ps1')) }
  @{ Name = 'config params';     Args = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'test-config-params.ps1')) }
  @{ Name = 'remove e2e'; Args = @('-NoProfile', '-STA', '-File', (Join-Path $PSScriptRoot 'test-remove-e2e.ps1')) }
  @{ Name = 'dialogs submit'; Args = @('-NoProfile', '-STA', '-File', (Join-Path $PSScriptRoot 'test-dialogs-submit.ps1')) }
)

foreach ($test in $tests) {
  $arguments = $test.Args
  Invoke-Check $test.Name { & pwsh @arguments }
}

if ($script:failures.Count) {
  Write-Output ""
  Write-Output "== $($script:failures.Count) failure(s) =="
  foreach ($f in $script:failures) { Write-Output "  - $($f.Label): $($f.Error)" }
  exit 1
}
Write-Output "PASS: $($tests.Count) regression tests and parser check completed."
