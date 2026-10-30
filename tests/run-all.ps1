#requires -Version 7.0
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'

# 收集失败继续跑下一项，避免一个环境性/偶发失败掩掉后续结果
# （如沙箱挡 [IO.File]::Replace 导致 config round-trip 挂掉，后面 4 项根本没跑）。
# 解析阶段若挂了，后面的测试也无从执行——解析失败仍按硬错误直接抛。
$script:failures = @()

function Invoke-Check([string]$label, [scriptblock]$action) {
  Write-Output "== $label =="
  $out = @()
  try {
    $out = @(& $action)
  } catch {
    if ($label -eq 'PowerShell parser') { throw }
    $script:failures += @{ Label=$label; Error=$_.Exception.Message }
    Write-Output "FAIL: $label — $($_.Exception.Message)"
    return
  }
  foreach ($line in $out) { Write-Output $line }
  if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    $script:failures += @{ Label=$label; Error="exit code $LASTEXITCODE" }
    Write-Output "FAIL: $label — exit code $LASTEXITCODE"
    return
  }
  # 零 PASS 行 = 这个脚本没断言任何东西（被跳过/被注释掉）。只看退出码会把它当绿。
  if (-not @($out | Where-Object { ("$_").StartsWith('PASS') }).Count) {
    $script:failures += @{ Label=$label; Error='没有任何 PASS 行（零断言/静默跳过）' }
    Write-Output "FAIL: $label — 没有任何 PASS 行（零断言/静默跳过）"
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

# 自动收集 tests/test-*.ps1：手写清单漏登记 = 新用例静默不进 CI。
# 统一 -STA（WPF 用例必需，纯函数用例加了也无害）；test-helpers.ps1 是被 dot-source 的夹具。
$tests = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'test-*.ps1' -File |
  Where-Object { $_.Name -ne 'test-helpers.ps1' } |
  Sort-Object Name |
  ForEach-Object {
    @{ Name = [IO.Path]::GetFileNameWithoutExtension($_.Name)
       Args = @('-NoProfile', '-STA', '-File', $_.FullName) }
  })

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
