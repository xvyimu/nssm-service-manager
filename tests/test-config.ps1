#requires -Version 7.0
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'lib/util.ps1')

# Save-Svc / Load-Svc 往返与恢复路径测试。
# util.ps1 在函数体里直接读 $cfg / $logDir（从 dot-source 的调用方作用域取），
# 因此测试必须在 dot-source 之后再赋值 $cfg，否则函数看到的是 $null。
$tmpDir = Join-Path ([IO.Path]::GetTempPath()) "sm-cfg-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $tmpDir | Out-Null
$cfg = Join-Path $tmpDir 'services.json'
$logDir = $tmpDir

try {
  # ---- 1. 文件不存在时返回兜底配置 ----
  $loaded = Load-Svc
  if ($loaded.Count -ne $script:default.Count) { throw 'Load-Svc should return defaults when file is missing.' }

  # ---- 2. Save → Load 往返保持数据 ----
  $test = [ordered]@{
    'SvcA' = @{ port = 8080; url = 'http://127.0.0.1:8080' }
    'SvcB' = @{ port = 9090; url = 'http://127.0.0.1:9090/panel' }
  }
  Save-Svc $test
  if (-not (Test-Path -LiteralPath $cfg)) { throw 'Save-Svc did not create the config file.' }
  $loaded = Load-Svc
  if ($loaded.Count -ne 2) { throw 'Round-trip lost entries.' }
  if ($loaded['SvcA'].port -ne 8080 -or $loaded['SvcB'].url -ne 'http://127.0.0.1:9090/panel') { throw 'Round-trip corrupted data.' }

  # ---- 3. 坏 JSON：Load-Svc 设 configWarning 并返回兜底 ----
  $script:configWarning = $null
  [IO.File]::WriteAllText($cfg, '{ broken json', [Text.UTF8Encoding]::new($false))
  $loaded = Load-Svc
  if (-not $script:configWarning) { throw 'Load-Svc did not set configWarning on invalid JSON.' }
  if ($loaded.Count -ne $script:default.Count) { throw 'Load-Svc should fall back to defaults on invalid JSON.' }

  # ---- 4. 端口越界：Load-Svc 拒绝并返回兜底 ----
  $script:configWarning = $null
  [IO.File]::WriteAllText($cfg, '{"Bad":{"port":99999,"url":"http://x"}}', [Text.UTF8Encoding]::new($false))
  $loaded = Load-Svc
  if (-not $script:configWarning) { throw 'Load-Svc did not reject out-of-range port.' }
  if ($loaded.Count -ne $script:default.Count) { throw 'Load-Svc should fall back to defaults on invalid port.' }

  # ---- 5. Save-Svc 原子写不残留 tmp ----
  Save-Svc $test
  $tmpLeftover = Get-ChildItem -LiteralPath $tmpDir -Filter '*.tmp' -File
  if ($tmpLeftover.Count -ne 0) { throw "Save-Svc left $($tmpLeftover.Count) tmp file(s) behind." }

  Write-Output 'PASS: Save-Svc/Load-Svc round-trip, invalid JSON recovery, port validation, and atomic write cleanup.'
} finally {
  Remove-Item -LiteralPath $tmpDir -Recurse -Force -EA SilentlyContinue
}
