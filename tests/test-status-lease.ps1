#requires -Version 7.0
# T4：状态栏消息被同一 tick 的自动刷新吞掉。
#
# 原实现顺序：先排空 msgQueue 写状态栏，紧接着 if (距上次操作 ≥4 秒) 写「状态自动刷新」。
# 用户没在操作时（距上次操作早已超过 4 秒），后台失败消息写入后立刻被覆盖，等于永远看不到；
# 而 remove 路径本身 stop + Wait-Stopped 最长 6 秒，失败消息必然过 4 秒门槛。
#
# 修法：消息带显示租约（$script:msgUntil），自动刷新在此之后才允许覆盖。
# 本测试直接调真实实现 Update-StatusTick（T4 把它从 Add_Tick 里抽出来才可测——
# 内联时只能「复刻」这段逻辑，改一处漏一处即静默漂移）。
param([string]$RepoRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
foreach ($module in 'theme','util','card','xaml') { . (Join-Path $RepoRoot "lib/$module.ps1") }
$script:sync=@{wake=[Threading.AutoResetEvent]::new($false); gate=[object]::new()}
$script:svc=[ordered]@{TestService=@{port=8080;url='http://127.0.0.1:8080'}}
$script:cmdQueue=[Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:cmdEpoch=0
function Stop-Background {}
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }

$win=New-MainWindow
try {
  Render-Page
  $card=$script:cards['TestService']

  # 夹具：坐标队列/消息队列/卡片缓存（New-MainWindow 已建 $script:cards）
  $script:queue=[Collections.Concurrent.ConcurrentQueue[object]]::new()
  $script:msgQueue=[Collections.Concurrent.ConcurrentQueue[string]]::new()
  $script:msgUntil=$null

  # ---- 1. 失败消息不被自动刷新吞掉 ----
  # 用户没在操作：lastActionAt 置为 10 秒前（> 4 秒门槛，自动刷新本来会命中）
  $script:lastActionAt=[datetime]::Now.AddSeconds(-10)
  $script:msgQueue.Enqueue('TestService 启动失败(1053 服务进程无法启动)')
  Update-StatusTick
  Assert ($script:statusBar.Text -eq 'TestService 启动失败(1053 服务进程无法启动)') "Failure message was swallowed by auto-refresh: '$($script:statusBar.Text)'."
  Assert ($script:msgUntil -gt [datetime]::Now) 'Message lease not set on status message.'

  # ---- 2. 租约期内再跑若干 tick，仍不得被自动刷新覆盖 ----
  foreach ($i in 1..5) { Update-StatusTick }
  Assert ($script:statusBar.Text -eq 'TestService 启动失败(1053 服务进程无法启动)') "Auto-refresh overwrote the message inside its lease: '$($script:statusBar.Text)'."

  # ---- 3. 租约到期后，自动刷新恢复正常（消息不该永久钉住状态栏）----
  $script:msgUntil=[datetime]::Now.AddSeconds(-1)   # 模拟租约已过
  Update-StatusTick
  Assert ($script:statusBar.Text -match '状态自动刷新') "Auto-refresh did not resume after the lease expired: '$($script:statusBar.Text)'."

  # ---- 4. 探测结果仍照常更新卡片（抽函数没碰这条路径）----
  $script:queue.Enqueue([pscustomobject]@{n='TestService';st='运行中';h='正常'})
  Update-StatusTick
  Assert ($card.ST -eq '运行中' -and $card.Btn.IsEnabled) "Probe result path broken: ST=$($card.ST)."

  Write-Output 'PASS: status messages hold a display lease; auto-refresh neither swallows them nor is permanently blocked.'
} finally { $win.Close(); $script:sync.wake.Dispose() }
