#requires -Version 7.0
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'lib/config.ps1')
. (Join-Path $RepoRoot 'lib/poll.ps1')
. (Join-Path $RepoRoot 'tests/test-helpers.ps1')

# 任务 C 配置参数化回归：超时/冷却/轮转阈值从 config.json 读，
# 同时确认 runspace 脚本块对未注入的键回落默认值（向后兼容测试夹具）。
$testsPath = New-TestTempDir 'sm-config-param-test'
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

  # 键集合必须与示例文件一致：config.ps1 加了键却忘了同步 config.example.json 时，
  # 新用户从示例起步根本看不到这个可调项（默认值照样生效，所以不会报错——纯静默漂移）。
  $exampleKeys = @((Get-Content (Join-Path $RepoRoot 'config.example.json') -Raw -Encoding UTF8 |
      ConvertFrom-Json -AsHashtable).Keys | Sort-Object)
  $defaultKeys = @($script:config.Keys | Sort-Object)
  $keyDiff = @(Compare-Object $exampleKeys $defaultKeys |
      ForEach-Object { "$($_.InputObject)($($_.SideIndicator))" })
  Assert (-not $keyDiff.Count) "config.example.json 与 config.ps1 的键集合不一致（<= 只在示例 / => 只在默认）：$($keyDiff -join ', ')"

  Assert ($script:config.PerPage -eq 4) 'PerPage not overridden.'
  Assert ($script:config.WaitStoppedTimeoutMs -eq 800) 'WaitStoppedTimeoutMs not overridden.'
  Assert ($script:config.CrashLogMaxBytes -eq 1024) 'CrashLogMaxBytes not overridden.'
  Assert ($script:config.LogKeepCount -eq 3) 'LogKeepCount not overridden.'
  Assert ($script:config.LogKeepDays -eq 2) 'LogKeepDays not overridden.'
  Assert ($script:config.LogDir -eq 'C:\sm-test-logs') 'LogDir not overridden.'
  # 轮询/探测节奏与 NSSM 参数收口键
  Assert ($script:config.ProbeThrottleLimit -eq 4) 'ProbeThrottleLimit not overridden.'
  Assert ($script:config.ProbeIntervalMs -eq 1111) 'ProbeIntervalMs not overridden.'
  Assert ($script:config.ProbeIdleMs -eq 2222) 'ProbeIdleMs not overridden.'
  Assert ($script:config.WaitStoppedPollMs -eq 77) 'WaitStoppedPollMs not overridden.'
  Assert ($script:config.AppRotateBytes -eq 1048576) 'AppRotateBytes not overridden.'
  Assert ($script:config.AppStopMethodConsole -eq 1234) 'AppStopMethodConsole not overridden.'
  Assert ($script:config.AckPollIntervalMs -eq 250) 'AckPollIntervalMs not overridden.'

  # runspace 从 $sync 读三个超时 + 节奏与并行度，生效值写回 $sync 同键——测试读共享表即可
  $worker = Start-FakePoll 1 'Stopped' 0 @{ waitStoppedTimeoutMs = 800; tcpTimeoutMs = 50; httpTimeoutMs = 500
                                              probeIntervalMs = 1234; probeIdleMs = 5678; probeThrottleLimit = 3 }
  try {
    Start-Sleep -Milliseconds 400   # 等脚本块过初始化
    Assert ($worker.Sync.tcpTimeoutMs -eq 50) 'poll tcpMs not read from sync'
    Assert ($worker.Sync.httpTimeoutMs -eq 500) 'poll httpMs not read from sync'
    Assert ($worker.Sync.waitStoppedTimeoutMs -eq 800) 'poll waitMs not read from sync'
    Assert ($worker.Sync.probeIntervalMs -eq 1234) 'poll probeIntervalMs not read from sync'
    Assert ($worker.Sync.probeIdleMs -eq 5678) 'poll probeIdleMs not read from sync'
    Assert ($worker.Sync.probeThrottleLimit -eq 3) 'poll probeThrottleLimit not read from sync'
  } finally { Close-FakePoll $worker }

  # 未注入键的回落：起一个不带 extraSyncKeys 的 worker，生效值应为默认 200/3000/12000 + 4000/15000/8
  $workerFallback = Start-FakePoll 1 'Stopped' 0
  try {
    Start-Sleep -Milliseconds 400
    Assert ($workerFallback.Sync.tcpTimeoutMs -eq 200 -and $workerFallback.Sync.httpTimeoutMs -eq 3000 -and $workerFallback.Sync.waitStoppedTimeoutMs -eq 12000) 'poll did not fall back to defaults when sync keys absent.'
    Assert ($workerFallback.Sync.probeIntervalMs -eq 4000 -and $workerFallback.Sync.probeIdleMs -eq 15000 -and $workerFallback.Sync.probeThrottleLimit -eq 8) 'poll probe cadence defaults not restored when sync keys absent.'
  } finally { Close-FakePoll $workerFallback }

  # 合法零值必须从配置贯通到最终 NSSM 参数；只测 Get-NssmSetSpec 不会发现包装层丢零。
  [IO.File]::WriteAllText($originalRepoConfig,
    '{"AppRotateBytes":0,"AppRotateSeconds":0,"AppStopMethodConsole":0}', [Text.UTF8Encoding]::new($false))
  . (Join-Path $RepoRoot 'lib/config.ps1')
  . (Join-Path $RepoRoot 'lib/nssm.ps1')
  $script:nssmParameters = @{}
  function nssm-set([string]$n,[string]$k,[Parameter(ValueFromRemainingArguments=$true)][object[]]$v) {
    $script:nssmParameters[$k] = $v
  }
  Set-NssmServiceParams 'ZeroFixture' 'fixture.exe' '' '' @() -SkipApplication
  foreach ($key in 'AppRotateBytes','AppRotateSeconds','AppStopMethodConsole') {
    Assert ($script:nssmParameters[$key][0] -eq 0) "$key=0 must reach NSSM unchanged"
  }
  Write-Output 'PASS: valid zero configuration reaches NSSM unchanged'

  # ---- 2. 坏 config.json：回落默认值 + 留一条提示（可选文件坏了不拦启动）----
  $script:config = $null; $script:configWarning = $null; $script:configNotices = $null
  [IO.File]::WriteAllText((Join-Path $RepoRoot 'config.json'), '{ broken', [Text.UTF8Encoding]::new($false))
  . (Join-Path $RepoRoot 'lib/config.ps1')
  Assert (@($script:configNotices | Where-Object { $_ -match 'config\.json 无效' }).Count -eq 1) 'config.json broken should add a notice.'
  Assert (-not $script:configWarning) 'configWarning 只给「清单解析失败」，config.json 坏了不该拦启动'
  # 提示收口：连续调用必须累积成数组（裸 `$null += "x"` 会退化成字符串）
  Assert (Get-Command Add-ConfigNotice -ErrorAction SilentlyContinue) 'Add-ConfigNotice 应已定义'
  $script:configNotices = $null
  Add-ConfigNotice 'a'; Add-ConfigNotice 'b'
  Assert ($script:configNotices -is [array] -and $script:configNotices.Count -eq 2) 'Add-ConfigNotice 应累积成数组'
  Assert ($script:config.PerPage -eq 6 -and $script:config.WaitStoppedTimeoutMs -eq 12000) 'Defaults not restored on broken config.'
  # LogDir 默认空串 = 用仓内 logs/（主脚本据此回落，见 service-manager-gui.ps1 顶部）
  Assert ($script:config.LogKeepCount -eq 10 -and $script:config.LogKeepDays -eq 14 -and $script:config.LogDir -eq '') 'Log retention defaults not restored on broken config.'

  # ---- 2b. 类型不合法的覆盖值：保留默认 + 提示，不抛 ----
  # 修前：config.ps1 原样赋值，主脚本的 [int] 强转在 $ErrorActionPreference='Stop' 下抛
  # RuntimeException，窗口根本不出现——用户只看到「启动失败，见 crash log」，看不到是哪个字段。
  $script:config = $null; $script:configWarning = $null; $script:configNotices = $null
  [IO.File]::WriteAllText((Join-Path $RepoRoot 'config.json'), '{"TcpTimeoutMs":"200ms","TrayEnabled":"maybe"}', [Text.UTF8Encoding]::new($false))
  . (Join-Path $RepoRoot 'lib/config.ps1')
  Assert ($script:config.TcpTimeoutMs -eq 200) "坏值应保留默认 200，got $($script:config.TcpTimeoutMs)"
  Assert ($script:config.TrayEnabled -eq $false) "坏 bool 应保留默认 false，got $($script:config.TrayEnabled)"
  Assert (@($script:configNotices).Count -eq 2) "两个坏值应给两条提示，got $(@($script:configNotices) -join ' | ')"
  [int]$script:config.TcpTimeoutMs | Out-Null   # 主脚本这步强转不该抛
  Assert (-not $script:configWarning) '类型问题是提示，不是「config.json 无效」'

  # ---- 2c. 数值越界：-1 会让 WaitOne/CTS 无限等待，0 会让分页除零 → 回落默认 + 提示 ----
  $script:config = $null; $script:configWarning = $null; $script:configNotices = $null
  [IO.File]::WriteAllText((Join-Path $RepoRoot 'config.json'),
    '{"TcpTimeoutMs":-1,"PerPage":0,"HttpTimeoutMs":9999999,"BogusKey":1}', [Text.UTF8Encoding]::new($false))
  . (Join-Path $RepoRoot 'lib/config.ps1')
  Assert ($script:config.TcpTimeoutMs -eq 200) "负超时应回落 200，got $($script:config.TcpTimeoutMs)"
  Assert ($script:config.PerPage -eq 6) "PerPage=0 应回落 6，got $($script:config.PerPage)"
  Assert ($script:config.HttpTimeoutMs -eq 3000) "超过上限应回落 3000，got $($script:config.HttpTimeoutMs)"
  $notices = @($script:configNotices)
  Assert ($notices.Count -eq 4) "3 个越界 + 1 个未知键应给 4 条提示，got $($notices -join ' | ')"
  Assert (@($notices | Where-Object { $_ -match 'TcpTimeoutMs=-1' }).Count -eq 1) '越界提示应带实际值'
  Assert (@($notices | Where-Object { $_ -match '未知键 BogusKey' }).Count -eq 1) '未知键应提示'
  $null = [math]::Sqrt($script:config.PerPage)   # 分页这步不该因除零抛出

  # ---- 3. mock restart：Wait-Stopped 用 $sync 注入的 waitMs=50——
  # 服务一直不进 Stopped（fake 状态 Running），注入生效时 ~50ms 就放弃重启并回一条失败回执；
  # 若误用默认 12000，2s 内根本收不到回执——这是「注入值确实生效」的判别。
  $worker2 = Start-FakePoll 1 'Running' 0 @{ waitStoppedTimeoutMs = 50; waitStoppedPollMs = 10; tcpTimeoutMs = 50; httpTimeoutMs = 500 }
  try {
    $worker2.Sync.cmd.Enqueue([pscustomobject]@{n='Fake0';act='restart';e=1})
    [void]$worker2.Sync.wake.Set()
    $ack=$null; $deadline=[datetime]::UtcNow.AddSeconds(2)
    while ([datetime]::UtcNow -lt $deadline) {
      $it=$null
      while ($worker2.Sync.queue.TryDequeue([ref]$it)) { if ($it.done) { $ack=$it } }
      if ($ack) { break }
      Start-Sleep -Milliseconds 20
    }
    Assert ($null -ne $ack) 'Injected waitMs=50 should surface a restart ack long before the 12s default.'
    Assert (-not $ack.ok -and [string]$ack.why -match '中止重启') "未停止的重启必须判失败并写明中止：ok=$($ack.ok) why=$($ack.why)"
    Assert (@($worker2.Sync.executed | Where-Object { "$_" -match '^start' }).Count -eq 0) 'Stopping did not finish, yet start was issued.'
  } finally { Close-FakePoll $worker2 }

  Write-Output 'PASS: config.json overrides timeouts/cooldown/rotation; poll reads injected sync values; broken config falls back; restart aborts on injected waitMs.'
} finally {
  Remove-Item -LiteralPath (Join-Path $RepoRoot 'config.json') -Force -EA SilentlyContinue
  if ($backupRepoConfig -and (Test-Path -LiteralPath $backupRepoConfig)) {
    Move-Item -LiteralPath $backupRepoConfig $originalRepoConfig -Force
  }
  Remove-Item -LiteralPath $testsPath -Recurse -Force -EA SilentlyContinue
}
