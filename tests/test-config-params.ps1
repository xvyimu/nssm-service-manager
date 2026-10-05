#requires -Version 7.0
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'lib/config.ps1')
. (Join-Path $RepoRoot 'lib/poll.ps1')
. (Join-Path $RepoRoot 'tests/test-helpers.ps1')
function Assert($condition, [string]$message) {
  if (-not $condition) { throw $message }
}

# 任务 C 配置参数化回归：超时/冷却/轮转阈值从 config.json 读，
# 同时确认 runspace 脚本块对未注入的键回落默认值（向后兼容测试夹具）。
$testsPath = Join-Path ([IO.Path]::GetTempPath()) "sm-config-param-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $testsPath | Out-Null
$originalRepoConfig = Join-Path $RepoRoot 'config.json'
$backupRepoConfig = $null
try {
  # 流程 1/2 需要一个临时 config.json；不覆盖仓内真配置，现场移走再还原
  if (Test-Path -LiteralPath $originalRepoConfig) {
    $backupRepoConfig = Join-Path $testsPath 'config.json.bak'
    Move-Item -LiteralPath $originalRepoConfig $backupRepoConfig -Force
  }

  # ---- 1. 覆盖值生效：全部键换成非默认值后再加载 ----
  [IO.File]::WriteAllText((Join-Path $RepoRoot 'config.json'),
    '{"PerPage":4,"TcpTimeoutMs":50,"HttpTimeoutMs":500,"ToggleCooldownMs":1200,"CrashLogMaxBytes":1024,"WaitStoppedTimeoutMs":800,"LogKeepCount":3,"LogKeepDays":2,"LogDir":"C:\\sm-test-logs","ProbeThrottleLimit":4,"ProbeIntervalMs":1111,"ProbeIdleMs":2222,"WaitStoppedPollMs":77,"AppRotateBytes":1048576,"AppStopMethodConsole":1234,"AckPollIntervalMs":250}',
    [Text.UTF8Encoding]::new($false))
  $script:config = $null   # 强制重新加载以验证 config.json 覆盖
  . (Join-Path $RepoRoot 'lib/config.ps1')
  Assert ($script:config.PerPage -eq 4) 'PerPage not overridden.'
  Assert ($script:config.WaitStoppedTimeoutMs -eq 800) 'WaitStoppedTimeoutMs not overridden.'
  Assert ($script:config.CrashLogMaxBytes -eq 1024) 'CrashLogMaxBytes not overridden.'
  Assert ($script:config.LogKeepCount -eq 3) 'LogKeepCount not overridden.'
  Assert ($script:config.LogKeepDays -eq 2) 'LogKeepDays not overridden.'
  Assert ($script:config.LogDir -eq 'C:\sm-test-logs') 'LogDir not overridden.'
  # 轮询/探测节奏与 NSSM 参数收口键（原硬编码在 poll.ps1 / svc-common.ps1 / Get-NssmSetSpec）
  Assert ($script:config.ProbeThrottleLimit -eq 4) 'ProbeThrottleLimit not overridden.'
  Assert ($script:config.ProbeIntervalMs -eq 1111) 'ProbeIntervalMs not overridden.'
  Assert ($script:config.ProbeIdleMs -eq 2222) 'ProbeIdleMs not overridden.'
  Assert ($script:config.WaitStoppedPollMs -eq 77) 'WaitStoppedPollMs not overridden.'
  Assert ($script:config.AppRotateBytes -eq 1048576) 'AppRotateBytes not overridden.'
  Assert ($script:config.AppStopMethodConsole -eq 1234) 'AppStopMethodConsole not overridden.'
  Assert ($script:config.AckPollIntervalMs -eq 250) 'AckPollIntervalMs not overridden.'

  # runspace 从 $sync 读三个超时，生效值写回 $sync 同键——测试读共享表即可
  $worker = Start-FakePoll 1 'Stopped' 0 @{ waitStoppedTimeoutMs = 800; tcpTimeoutMs = 50; httpTimeoutMs = 500 }
  try {
    Start-Sleep -Milliseconds 400   # 等脚本块过初始化
    Assert ($worker.Sync.tcpTimeoutMs -eq 50) 'poll tcpMs not read from sync'
    Assert ($worker.Sync.httpTimeoutMs -eq 500) 'poll httpMs not read from sync'
    Assert ($worker.Sync.waitStoppedTimeoutMs -eq 800) 'poll waitMs not read from sync'
  } finally { Close-FakePoll $worker }

  # 未注入键的回落：起一个不带 extraSyncKeys 的 worker，生效值应为默认 200/3000/6000
  $workerFallback = Start-FakePoll 1 'Stopped' 0
  try {
    Start-Sleep -Milliseconds 400
    Assert ($workerFallback.Sync.tcpTimeoutMs -eq 200 -and $workerFallback.Sync.httpTimeoutMs -eq 3000 -and $workerFallback.Sync.waitStoppedTimeoutMs -eq 6000) 'poll did not fall back to defaults when sync keys absent.'
  } finally { Close-FakePoll $workerFallback }

  # ---- 2. 坏 config.json：回落默认值且设置 configWarning ----
  $script:config = $null; $script:configWarning = $null
  [IO.File]::WriteAllText((Join-Path $RepoRoot 'config.json'), '{ broken', [Text.UTF8Encoding]::new($false))
  . (Join-Path $RepoRoot 'lib/config.ps1')
  Assert ($script:configWarning -match 'config\.json 无效') 'config.json broken should set configWarning.'
  Assert ($script:config.PerPage -eq 6 -and $script:config.WaitStoppedTimeoutMs -eq 6000) 'Defaults not restored on broken config.'
  # LogDir 默认空串 = 用仓内 logs/（主脚本据此回落，见 service-manager-gui.ps1 顶部）
  Assert ($script:config.LogKeepCount -eq 10 -and $script:config.LogKeepDays -eq 14 -and $script:config.LogDir -eq '') 'Log retention defaults not restored on broken config.'

  # ---- 3. mock restart：Wait-Stopped 用 $sync 注入的 waitMs=50——
  # 若误用默认 6000，restart 会卡在轮询直到 6s，executed 里只有 stop；
  # 用 50 则 ~550ms 内 stop+start 都到，是「注入值确实生效」的判别。
  $worker2 = Start-FakePoll 1 'Running' 0 @{ waitStoppedTimeoutMs = 50; tcpTimeoutMs = 50; httpTimeoutMs = 500 }
  try {
    $worker2.Sync.cmd.Enqueue([pscustomobject]@{n='Fake0';act='restart';e=1})
    [void]$worker2.Sync.wake.Set()
    Start-Sleep -Milliseconds 1200
    $cmdCount = $worker2.Sync.executed.Count
    Assert ($cmdCount -ge 2) "restart should issue stop+start within 1.2s (waitMs=50 injected), got $cmdCount entries."
  } finally { Close-FakePoll $worker2 }

  Write-Output 'PASS: config.json overrides timeouts/cooldown/rotation; poll reads injected sync values; broken config falls back; restart honors waitMs.'
} finally {
  Remove-Item -LiteralPath (Join-Path $RepoRoot 'config.json') -Force -EA SilentlyContinue
  if ($backupRepoConfig -and (Test-Path -LiteralPath $backupRepoConfig)) {
    Move-Item -LiteralPath $backupRepoConfig $originalRepoConfig -Force
  }
  Remove-Item -LiteralPath $testsPath -Recurse -Force -EA SilentlyContinue
}