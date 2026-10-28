#requires -Version 7.0
# 卡片时长显示：启动/停止过程中显示已用时长，运行中显示已运行多久。
# 起因：点「启动」后卡片只写「启动中」，没有任何时间感——分不出是真的在启动还是卡住了。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
foreach ($module in 'theme','util','card','xaml') { . (Join-Path $RepoRoot "lib/$module.ps1") }
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }

# ---- 1. Format-Elapsed ----
$now = [datetime]::Now
Assert ((Format-Elapsed $now.AddSeconds(-5)   $now) -eq '5s')          "5 秒应为 5s，got $(Format-Elapsed $now.AddSeconds(-5) $now)"
Assert ((Format-Elapsed $now.AddSeconds(-59)  $now) -eq '59s')         '59 秒仍走 s 档'
Assert ((Format-Elapsed $now.AddSeconds(-60)  $now) -eq '1分0秒')      '整分钟边界'
Assert ((Format-Elapsed $now.AddSeconds(-90)  $now) -eq '1分30秒')     '1 分 30 秒'
Assert ((Format-Elapsed $now.AddSeconds(-3600) $now) -eq '1小时0分')   '整小时边界'
Assert ((Format-Elapsed $now.AddSeconds(-3900) $now) -eq '1小时5分')   '1 小时 5 分'
Assert ((Format-Elapsed $now.AddSeconds(10)   $now) -eq '')            '负值（时钟回拨）应返回空串'
Write-Output 'PASS: Format-Elapsed 的秒/分/时边界与负值。'

# ---- 2. 卡片上的后缀 ----
$script:sync = @{ wake = [Threading.AutoResetEvent]::new($false) }
$script:svc = [ordered]@{ SvcClock = @{ port = 8080; url = 'http://127.0.0.1:8080' } }
$script:cmdQueue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
# 走**真实的每帧节拍**（Update-StatusTick），不是直接调 Update-CardClock：
# 断言时钟真被接进了 400ms 的 DispatcherTimer 回调，而不只是「函数单独调用时对」。
$script:queue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:msgQueue = [Collections.Concurrent.ConcurrentQueue[string]]::new()
function Stop-Background {}
$win = New-MainWindow
try {
  Render-Page
  $c = $script:cards['SvcClock']

  # 运行中：显示「已运行」
  Update-CardData 'SvcClock' '运行中' '正常'
  $c.StateSince = [datetime]::Now.AddSeconds(-90)
  Update-StatusTick
  Assert ($c.LblUp.Text -like '*已运行 1分30秒*') "运行中应显示已运行时长，got [$($c.LblUp.Text)]"
  # 精确比对而不是 -like '服务响应正常*'：后者抓不到「正文被重复拼接」
  Assert ($c.LblUp.Text -eq '服务响应正常 · 已运行 1分30秒') "健康正文应原样保留且只出现一次，got [$($c.LblUp.Text)]"

  # 启动中：显示已用时（用 TransitionAt 起算）。先落到「已停止」——运行中时点按钮是「停止」。
  Update-CardData 'SvcClock' '已停止' ''
  $c.LastToggle = [datetime]::MinValue
  Invoke-CardToggle $c
  Assert ($c.ST -eq '启动中') "应进入启动过渡态，got $($c.ST)"
  # 显示用的是 StateSince（不是 TransitionAt——后者会被探测刷新）
  $c.StateSince = [datetime]::Now.AddSeconds(-12)
  Update-CardClock $c ([datetime]::Now)
  Assert ($c.LblUp.Text -like '*已 12s*') "启动中应显示已用时长，got [$($c.LblUp.Text)]"

  # 已停止：显示已停多久。先把过渡态清掉——命令驱动的过渡态会按方向守卫丢弃反向探测值
  # （那是 H1 的保护，不是 bug），这里要的是「过渡结束后」的场景。
  $c.TransitionAt = [datetime]::MinValue
  Update-CardData 'SvcClock' '已停止' ''
  $c.StateSince = [datetime]::Now.AddSeconds(-30)
  Update-StatusTick
  Assert ($c.LblUp.Text -like '*已停 30s*') "已停止应显示已停时长，got [$($c.LblUp.Text)]"

  # 探测驱动的过渡态：**必须走 Update-CardData 的真实路径**。手工设 TransitionAt 的写法
  # 会绕开「探测刷新 TransitionAt」这一步，而慢启动正是每 4 秒被刷新一次的场景——
  # 拿 TransitionAt 当时长起算点的话，这里会永远显示「已 0s」。
  Update-CardData 'SvcClock' '启动中' ''
  Assert ($c.ST -eq '启动中') "应进入探测驱动的启动中，got $($c.ST)"
  $c.StateSince = [datetime]::Now.AddSeconds(-20)
  Update-CardData 'SvcClock' '启动中' ''      # 同一状态再来一轮（真实探测每 4 秒一次）
  Update-CardClock $c ([datetime]::Now)
  $m = [regex]::Match($c.LblUp.Text, '已 (\d+)s')
  Assert ($m.Success) "慢启动时该显示已用时长，got [$($c.LblUp.Text)]"
  Assert ([int]$m.Groups[1].Value -ge 19) "同态探测后时长不该被清零，got [$($c.LblUp.Text)]"

  # 时长只在状态**变化**时重记：同一状态连续到达不该把计时清零
  # （先真的落到「已停止」——上一步卡片还停在启动中，直接喂已停止属于状态变化，重记是对的）
  Update-CardData 'SvcClock' '已停止' ''
  Assert ($c.ST -eq '已停止') "应已落到已停止，got $($c.ST)"
  $c.StateSince = [datetime]::Now.AddSeconds(-45)
  Update-CardData 'SvcClock' '已停止' ''
  Assert ($c.StateSince -lt [datetime]::Now.AddSeconds(-40)) '同一状态重复到达时 StateSince 不该被重置'

  Write-Output 'PASS: 卡片显示启动/停止已用时长与运行时长；健康正文保留；计时不随探测重置。'
} finally { $win.Close(); $script:sync.wake.Dispose() }
