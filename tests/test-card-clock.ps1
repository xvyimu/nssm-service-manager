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
function Stop-Background {}
$win = New-MainWindow
try {
  Render-Page
  $c = $script:cards['SvcClock']

  # 运行中：显示「已运行」
  Update-CardData 'SvcClock' '运行中' '正常'
  $c.StateSince = [datetime]::Now.AddSeconds(-90)
  Update-CardClock $c ([datetime]::Now)
  Assert ($c.LblUp.Text -like '*已运行 1分30秒*') "运行中应显示已运行时长，got [$($c.LblUp.Text)]"
  Assert ($c.LblUp.Text -like '服务响应正常*') '健康正文不能被时钟吃掉'

  # 启动中：显示已用时（用 TransitionAt 起算）。先落到「已停止」——运行中时点按钮是「停止」。
  Update-CardData 'SvcClock' '已停止' ''
  $c.LastToggle = [datetime]::MinValue
  Invoke-CardToggle $c
  Assert ($c.ST -eq '启动中') "应进入启动过渡态，got $($c.ST)"
  $c.TransitionAt = [datetime]::Now.AddSeconds(-12)
  Update-CardClock $c ([datetime]::Now)
  Assert ($c.LblUp.Text -like '*已 12s*') "启动中应显示已用时长，got [$($c.LblUp.Text)]"

  # 已停止：显示已停多久。先把过渡态清掉——命令驱动的过渡态会按方向守卫丢弃反向探测值
  # （那是 H1 的保护，不是 bug），这里要的是「过渡结束后」的场景。
  $c.TransitionAt = [datetime]::MinValue
  Update-CardData 'SvcClock' '已停止' ''
  $c.StateSince = [datetime]::Now.AddSeconds(-30)
  Update-CardClock $c ([datetime]::Now)
  Assert ($c.LblUp.Text -like '*已停 30s*') "已停止应显示已停时长，got [$($c.LblUp.Text)]"

  # 时长只在状态**变化**时重记：同一状态连续到达不该把计时清零
  $c.StateSince = [datetime]::Now.AddSeconds(-45)
  Update-CardData 'SvcClock' '已停止' ''
  Assert ($c.StateSince -lt [datetime]::Now.AddSeconds(-40)) '同一状态重复到达时 StateSince 不该被重置'

  Write-Output 'PASS: 卡片显示启动/停止已用时长与运行时长；健康正文保留；计时不随探测重置。'
} finally { $win.Close(); $script:sync.wake.Dispose() }
