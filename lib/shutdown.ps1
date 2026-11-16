# lib/shutdown.ps1 — 关窗收尾：停后台 runspace、等回执、清日志档
#
# GUI 关闭路径唯一入口，重复调用要幂等（Closed 事件可能触发一次以上）。
# 由 lib/util.ps1 聚合加载。

# ---- 关闭收尾（GUI 与托盘退出共用；放这里是为了能被单测直接点源）----
# 参数默认值从调用方作用域读：GUI 里是脚本级变量，单测可注入伪对象。
function Stop-Background {
  param(
    $Handle = $script:bgHandle,
    $Pipeline = $bgPS,
    $Runspace = $bgRS
  )
  # 幂等：Closed 与托盘退出可能各触发一次，重复拆 runspace 只会抛噪声异常。
  # 用 -eq $true：首次读在 GUI 赋值之前，未初始化变量在 StrictMode 下会抛，且位置在置位之前、try 之外。
  if ($script:bgStopped -eq $true) { return }
  $script:bgStopped = $true
  if (-not $script:sync) { return }
  $script:sync.stop = $true
  try { [void]$script:sync.wake.Set() } catch { Write-Verbose "shutdown.ps1: 唤醒后台失败（停止标志已置位，后续有界等待兜底），忽略：$($_.Exception.Message)" }
  # Web 视图用自己的 runspace：先置停止标志（循环 200ms 内自己退出），再兜底停管道。
  # 包 try：web runspace 已崩时 Stop-WebView 会抛，而 bgStopped 已置位——
  # 抛出去会让后续的排空、有界等待、资源拆解全部短路，进程退出后 mutex 仍被占。
  if ($script:web) {
    $script:sync.webStop = $true
    $webToStop = $script:web
    try { if (Get-Command Stop-WebView -EA SilentlyContinue) { Stop-WebView $webToStop } }
    catch { Write-CrashLog "Web stop failed: $($_.Exception.Message)" }
    # 只有确认停了才丢引用：停不掉时保留，至少句柄不丢、日志里能查。
    # 默认必须是「未确认」——读 Handle 抛异常、Handle 为空、Stop-WebView 不存在这三条都算没确认。
    $webStopped = $false
    try { $webStopped = [bool]($webToStop.Handle -and $webToStop.Handle.IsCompleted) } catch { $webStopped = $false }
    if ($webStopped) { $script:web = $null }
    else { Write-CrashLog 'Web view runspace did not stop within 2000ms; keeping reference' }
  }
  # 关闭瞬间的最后几条健康变化：后台可能来不及 drain，这里兜底写一次（只有几条，不阻塞）。
  if ($script:healthQueue -and $script:healthHistoryDir) {
    $hev = $null
    while ($script:healthQueue.TryDequeue([ref]$hev)) {
      try { $null = Add-HealthEvent $script:healthHistoryDir $hev } catch { Write-Verbose "shutdown.ps1: 关闭时补写健康事件失败，忽略：$($_.Exception.Message)" }
    }
  }
  # 有界等待：后台卡在 $svc.Start()（等满 ServicesPipeTimeout ≈ 30s）或外部命令里时，
  # UI 线程不能跟着等——窗口关了进程还在，mutex 仍被占，用户再双击就是「没反应」。
  $ended = $false
  if ($Handle) {
    try { $ended = $Handle.AsyncWaitHandle.WaitOne(1500) } catch { Write-Verbose "shutdown.ps1: 读后台句柄的等待状态失败（按未结束处理）：$($_.Exception.Message)" }
  }
  # 等待期间后台可能又写了几条健康事件（它还在跑最后几拍）：再排一次，
  # 否则「兜底写一次」只覆盖到等待开始那一刻。
  if ($script:healthQueue -and $script:healthHistoryDir) {
    $hev2 = $null
    while ($script:healthQueue.TryDequeue([ref]$hev2)) {
      try { $null = Add-HealthEvent $script:healthHistoryDir $hev2 } catch { Write-Verbose "shutdown.ps1: 等待期间补写健康事件失败，忽略：$($_.Exception.Message)" }
    }
  }
  if ($ended) {
    if ($Pipeline) {
      try { $Pipeline.EndInvoke($Handle) } catch { Write-CrashLog "Background end failed: $($_.Exception.Message)" }
    }
    # 只有确认管道结束才拆资源：在仍在跑的 runspace 上 Close/Dispose，异常会被吞掉，语义不确定。
    if ($Runspace) { try { $Runspace.Close() } catch { Write-Verbose "shutdown.ps1: 关闭后台 runspace 失败，忽略：$($_.Exception.Message)" }; try { $Runspace.Dispose() } catch { Write-Verbose "shutdown.ps1: 释放后台 runspace 失败，忽略：$($_.Exception.Message)" } }
    if ($Pipeline) { try { $Pipeline.Dispose() } catch { Write-Verbose "shutdown.ps1: 释放后台管道失败，忽略：$($_.Exception.Message)" } }
    try { $script:sync.wake.Dispose() } catch { Write-Verbose "shutdown.ps1: 释放唤醒事件失败，忽略：$($_.Exception.Message)" }
  } elseif ($Pipeline) {
    # 管道没结束：只发停止请求，把清理交给进程退出。这里不 Dispose，后台可能仍在用它。
    try { [void]$Pipeline.BeginStop($null, $null) } catch { Write-CrashLog "Background stop failed: $($_.Exception.Message)" }
    Write-CrashLog 'Background did not end within 1500ms; leaving runspace for process exit'
  }
  # 停收尾时也跑一次日志清理——窗口关闭是自然的维护点，避免常驻时占 UI 线程。
  if (Get-Command Invoke-LogCleanup -EA SilentlyContinue) { Invoke-LogCleanup 'Log cleanup on close failed' }
}
