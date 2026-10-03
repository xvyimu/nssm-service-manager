#requires -Version 7.0
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'lib/util.ps1')

# Load-Svc / Read-SvcFile 测试：services.json 是 SSOT，services.example.json 是兜底。
# util.ps1 在函数体里直接读 $cfg / $logDir（从 dot-source 的调用方作用域取；
# 完整约定与参数命名禁区见 util.ps1 顶部注释），因此测试必须在 dot-source 之后再
# 赋值 $cfg，否则函数看到的是 $null。
$tmpDir = Join-Path ([IO.Path]::GetTempPath()) "sm-cfg-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $tmpDir | Out-Null
$cfg = Join-Path $tmpDir 'services.json'
$logDir = $tmpDir
$exampleSrc = Join-Path $RepoRoot 'services.example.json'
$exampleCount = (Get-Content $exampleSrc -Raw | ConvertFrom-Json -AsHashtable).Count

try {
  # ---- 1. services.json 不存在、services.example.json 也不在 → 空清单 ----
  $loaded = Load-Svc
  if ($loaded.Count -ne 0) { throw 'Load-Svc should return empty when neither file exists.' }

  # ---- 2. services.json 缺失、放一份 example 在同目录 → 回落 example ----
  Copy-Item $exampleSrc (Join-Path $tmpDir 'services.example.json') -Force
  $loaded = Load-Svc
  if ($loaded.Count -ne $exampleCount) { throw "Load-Svc should fall back to example ($exampleCount entries), got $($loaded.Count)." }

  # ---- 3. Save → Load 往返保持数据 ----
  $test = [ordered]@{
    'SvcA' = @{ port = 8080; url = 'http://127.0.0.1:8080' }
    'SvcB' = @{ port = 9090; url = 'http://127.0.0.1:9090/panel' }
  }
  Save-Svc $test
  if (-not (Test-Path -LiteralPath $cfg)) { throw 'Save-Svc did not create the config file.' }
  $loaded = Load-Svc
  if ($loaded.Count -ne 2) { throw 'Round-trip lost entries.' }
  if ($loaded['SvcA'].port -ne 8080 -or $loaded['SvcB'].url -ne 'http://127.0.0.1:9090/panel') { throw 'Round-trip corrupted data.' }

  # ---- 4. 坏 JSON：Load-Svc 设 configWarning 并回落 example ----
  $script:configWarning = $null
  [IO.File]::WriteAllText($cfg, '{ broken json', [Text.UTF8Encoding]::new($false))
  $loaded = Load-Svc
  if (-not $script:configWarning) { throw 'Load-Svc did not set configWarning on invalid JSON.' }
  if ($loaded.Count -ne $exampleCount) { throw "Load-Svc should fall back to example on invalid JSON, got $($loaded.Count)." }

  # ---- 5. 端口越界：Load-Svc 设 configWarning 并回落 example ----
  $script:configWarning = $null
  [IO.File]::WriteAllText($cfg, '{"Bad":{"port":99999,"url":"http://x"}}', [Text.UTF8Encoding]::new($false))
  $loaded = Load-Svc
  if (-not $script:configWarning) { throw 'Load-Svc did not reject out-of-range port.' }
  if ($loaded.Count -ne $exampleCount) { throw "Load-Svc should fall back to example on invalid port, got $($loaded.Count)." }

  # ---- 6. Save-Svc 原子写不残留 tmp ----
  Save-Svc $test
  $tmpLeftover = Get-ChildItem -LiteralPath $tmpDir -Filter '*.tmp' -File
  if ($tmpLeftover.Count -ne 0) { throw "Save-Svc left $($tmpLeftover.Count) tmp file(s) behind." }

  Write-Output 'PASS: Load-Svc fallback chain (empty→example→cfg), round-trip, invalid JSON/port recovery, atomic write cleanup.'
} finally {
  Remove-Item -LiteralPath $tmpDir -Recurse -Force -EA SilentlyContinue
}
