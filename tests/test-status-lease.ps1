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

  # ---- 5. UI 回调异常的状态栏提示（T5）：截断到 80 字符 + 带租约 ----
  # 修前：Dispatcher handler 只 Write-CrashLog 后设 Handled=$true，用户看到「点了没反应」。
  # 这里测 handler 真正会调的那段（Set-UiErrorStatus）；handler 本身是进程级注册，无法单测。
  Set-UiErrorStatus '短消息'
  Assert ($script:statusBar.Text -eq '操作出错：短消息') "Short UI error text wrong: '$($script:statusBar.Text)'."
  Assert ($script:msgUntil -gt [datetime]::Now) 'UI error message did not take a display lease.'
  $long='超长异常消息' * 30
  Set-UiErrorStatus $long
  $shown=[string]$script:statusBar.Text
  Assert ($shown.StartsWith('操作出错：')) "Long UI error missing prefix: '$shown'."
  # 前缀 5 字 + 截断后 80 字 + 省略号 1 字
  Assert ($shown.Length -le 90) "Long UI error not truncated: length=$($shown.Length)."
  Assert ($shown.EndsWith('…')) 'Truncated UI error should end with an ellipsis.'

  # ---- 6. Open-PanelUrl 失败也带租约，且不被日志写入的失败连累 ----
  # 该路径原为直接赋 Text，与 T4 修的同类问题；且 catch 体里 Write-CrashLog 在
  # 早期/异常场景下自身可能抛——故提示必须先于日志写入，各自包住。
  function Write-CrashLog([string]$m) { throw 'log path broken' }   # 逼出日志失败
  function Start-Process([string]$f) { throw 'no browser' }
  $script:msgUntil=$null
  Open-PanelUrl 'http://example.invalid/'
  Assert ($script:statusBar.Text -eq '打开面板失败：no browser') "Panel failure text wrong: '$($script:statusBar.Text)'."
  Assert ($script:msgUntil -gt [datetime]::Now) 'Panel failure message did not take a display lease.'

  # ---- 7. DispatcherUnhandledException 兜底：真触发一次，验「窗口不消失 + 状态栏有提示」----
  # 提示词把 T5 这条列为「人工确认」；这里改成自动验证。
  # DispatcherUnhandledExceptionEventArgs 是私有构造，没法直接 new，只能注册到真 dispatcher
  # 上真抛真接。函数体（Invoke-DispatcherErrorFallback）在生产代码里，注册行同主脚本。
  # 上一步已把 Write-CrashLog 换成抛异常版本，顺带覆盖「日志失败不连累提示」。
  $script:statusBar.Text='BEFORE-EXCEPTION'
  $script:msgUntil=$null
  $disp=[System.Windows.Threading.Dispatcher]::CurrentDispatcher
  $script:seen=$null
  $disp.add_UnhandledException({
    param($s,$e)
    $script:seen=$e.Exception.Message
    Invoke-DispatcherErrorFallback $e
  })
  [void]$disp.BeginInvoke([Action]{ throw 'ui-callback-boom' })
  # 跑一小段帧循环，让排队的 BeginInvoke 执行（异常在这里被 handler 接住）
  $frame=[System.Windows.Threading.DispatcherFrame]::new()
  $timer=[System.Windows.Threading.DispatcherTimer]::new()
  $timer.Interval=[TimeSpan]::FromMilliseconds(600)
  $timer.Add_Tick({ $timer.Stop(); $frame.Continue=$false })
  $timer.Start()
  [System.Windows.Threading.Dispatcher]::PushFrame($frame)

  Assert ($script:seen -eq 'ui-callback-boom') "DispatcherUnhandledException did not fire: seen='$($script:seen)'."
  Assert ($script:statusBar.Text -eq '操作出错：ui-callback-boom') "UI exception notice wrong: '$($script:statusBar.Text)'."
  Assert ($script:msgUntil -gt [datetime]::Now) 'UI exception notice did not take a display lease.'
  # 能走到这行即证明 Handled=$true 生效、进程没被异常带走

  Write-Output 'PASS: status messages hold a display lease; auto-refresh neither swallows them nor is permanently blocked; UI/panel errors surface truncated and leased; dispatcher exception fallback keeps the window alive.'
} finally { $win.Close(); $script:sync.wake.Dispose() }
