#requires -Version 7.0
param(
  [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
  [int]$TestTimeoutSeconds = 120
)
$ErrorActionPreference='Stop'

# 收集失败继续跑下一项，避免一个环境性/偶发失败掩掉后续结果
# （如沙箱挡 [IO.File]::Replace 导致 config round-trip 挂掉，后面 4 项根本没跑）。
# 解析阶段若挂了，后面的测试也无从执行——解析失败仍按硬错误直接抛。
$script:failures = @()

function Invoke-RegressionTest([string]$path) {
  # 无控制台的子进程按系统 OEM 代码页写 stdout，父进程默认按控制台编码（常为 UTF-8）解码，
  # 中文 PASS 行会变成乱码。这里按子进程实际使用的 OEM 代码页解码。
  # 必须继续用 -File：-Command 下 & 调用让脚本落到子作用域，GetNewClosure 的脚本块
  # 看不到脚本级函数（WPF 事件处理器会报「术语 xxx 不会被识别」）。
  $childEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
  $start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
  foreach ($argument in @('-NoProfile','-NonInteractive','-STA','-File',$path)) {
    $start.ArgumentList.Add($argument)
  }
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $start.StandardOutputEncoding = $childEncoding
  $start.StandardErrorEncoding = $childEncoding
  $process = [Diagnostics.Process]::Start($start)
  try {
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TestTimeoutSeconds * 1000)) {
      $process.Kill($true)
      $process.WaitForExit()
      throw "Test exceeded ${TestTimeoutSeconds}s: $path"
    }
    $global:LASTEXITCODE = $process.ExitCode
    $stdout.GetAwaiter().GetResult() -split '\r?\n' | Where-Object { $_ }
    $stderr.GetAwaiter().GetResult() -split '\r?\n' | Where-Object { $_ }
  } finally { $process.Dispose() }
}

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
# NSSM_SM_HEADLESS=1 让子进程跳过确认框（Confirm-ExitBusy）：MessageBox 在非交互测试里
# 会真弹窗并永久阻塞，整个 run-all 就停在那儿等人工点「是」。
$env:NSSM_SM_HEADLESS = '1'
# 统一 -STA（WPF 用例必需，纯函数用例加了也无害）；test-helpers.ps1 是被 dot-source 的夹具。
$tests = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'test-*.ps1' -File |
  Where-Object { $_.Name -ne 'test-helpers.ps1' } |
  Sort-Object Name |
  ForEach-Object {
    @{ Name = [IO.Path]::GetFileNameWithoutExtension($_.Name)
       Path = $_.FullName }
  })

foreach ($test in $tests) {
  Invoke-Check $test.Name { Invoke-RegressionTest $test.Path }
}

if ($script:failures.Count) {
  Write-Output ""
  Write-Output "== $($script:failures.Count) failure(s) =="
  foreach ($f in $script:failures) { Write-Output "  - $($f.Label): $($f.Error)" }
  exit 1
}
Write-Output "PASS: $($tests.Count) regression tests and parser check completed."
