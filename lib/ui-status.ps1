# lib/ui-status.ps1 — 命令队列、状态栏文案、每帧 tick、单实例检测
#
# UI 线程只做入队，实际 sc.exe/nssm.exe 调用由 lib/poll.ps1 的 runspace 执行。
# 由 lib/util.ps1 聚合加载；$script:sync / $script:statusBar 由 GUI 入口创建。
# 自加载 config：单独点源本文件时也要有 TRANSITION_STATES（与 card.ps1 同一写法，别再写第二份字面量）。
if (-not $script:config) { . (Join-Path $PSScriptRoot 'config.ps1') }

# 退出确认要问的「在途卡片」：只算清单里还存在的服务。服务被删/被重载后残留的卡片
# 永远等不到回执，拿它去问只会每次退出都弹一次「X 还在切换中」。§Get-ExitBusy
function Get-ExitBusy($cards,$svc){
  # 只认过渡态三种：暂停中/继续中由 SCM 或外部操作引起，没有回执可丢，不拦退出（见 config.ps1）。
  $states = $script:TRANSITION_STATES
  @($cards.Values | Where-Object {
    $_.ST -in $states -and ($null -eq $svc -or $svc.Contains($_.SvcName))
  })
}

# 命令纪元：随命令入队并随结果回 UI；Update-CardData 只认 epoch ≥ PendingEpoch 的回执。§Send-ServiceCommand
$script:cmdEpoch = 0

# 所有 GUI 命令统一入队并唤醒后台；队列保留 FIFO，事件只负责结束空闲等待。
function Send-ServiceCommand([string]$name,[string]$action) {
  $script:cmdEpoch++
  $e = $script:cmdEpoch
  $script:cmdQueue.Enqueue([pscustomobject]@{n=$name;act=$action;e=$e})
  [void]$script:sync.wake.Set()
  $e
}

# 打开面板 URL 的统一入口：包住 Start-Process，失败只提示不崩 GUI。§Open-PanelUrl
function Open-PanelUrl([string]$url){
  if ([string]::IsNullOrWhiteSpace($url)) { return }
  # 只放行 http/https：提权进程里 Start-Process 一个 file:/// 或自定义协议，等于管理员执行任意程序。
  if ($url -notmatch '^(?i)https?://') { Set-StatusMessage "只支持 http/https 面板地址：$url"; return }
  try { Start-Process $url -EA Stop }
  catch {
    # 先提示再记日志，各自包住；走 Set-StatusMessage 带租约，否则会被下一帧自动刷新吞掉。§Open-PanelUrl
    try { Set-StatusMessage "打开面板失败：$($_.Exception.Message)" } catch {}
    try { Write-CrashLog "Open-PanelUrl 失败: $($_.Exception.GetType().FullName): $($_.Exception.Message)" } catch {}
  }
}

# ---- 状态栏消息与每帧队列处理（DispatcherTimer 的回调体）----
# 消息带显示租约（$script:msgUntil）：否则后台失败消息会被同一 tick 的自动刷新盖掉。§状态栏消息
$script:MSG_LEASE = [TimeSpan]::FromSeconds(30)

# 状态栏文案唯一写入口：加时间戳前缀＝动作日志语义，租约到期后由每次 tick 自动清掉。
function Set-StatusMessage([string]$text){
  if (-not $script:statusBar) { return }   # 模块可能被 CLI/测试加载，此时无状态栏
  # 带时间戳＝动作日志的语义：同一行能回答「什么时候发生的」。30 秒租约够看完。
  $script:statusBar.Text = "$(Get-Date -Format 'HH:mm:ss')  $text"
  $script:msgUntil = [datetime]::Now + $script:MSG_LEASE
}

# UI 回调异常时的状态栏提示。抽成函数才测得了「截断 + 租约」这段。§Set-UiErrorStatus
function Set-UiErrorStatus([string]$message){
  if (-not $script:statusBar) { return }
  $m = [string]$message
  if ($m.Length -gt 80) { $m = $m.Substring(0,80) + '…' }
  Set-StatusMessage "操作出错：$m"
}

# Dispatcher 未处理异常的兜底体。每步各自包住；必须置 Handled，否则单次异常=整窗消失。§Invoke-DispatcherErrorFallback
function Invoke-DispatcherErrorFallback($e){
  try { Set-UiErrorStatus ([string]$e.Exception.Message) } catch {}
  try { Write-CrashLog "DispatcherUnhandled: $($e.Exception.GetType().FullName): $($e.Exception.Message)" } catch {}
  $e.Handled = $true
}

# 每帧：排空结果队列 → 排空消息队列 → 空闲 4 秒自动刷新。抽成函数才可单测，内联会导致测试复刻逻辑而漂移。§Update-StatusTick
function Update-StatusTick {
  $item = $null
  while ($script:queue.TryDequeue([ref]$item)) {
    if ($item.done) {
      if ($item.act -eq 'remove') {
        if (-not $item.ok) {
          # 删除失败：服务仍在、配置未动，不能走清理路径（那会把活着的服务从 UI 抹掉）。§Update-StatusTick
          Set-CardRollback $script:cards[$item.n]
          continue
        }
        # 先写盘成功、再改内存：原来先 Remove 再 Save，保存失败时界面已经宣称删掉，
        # 磁盘仍留着条目，下次启动又冒出来（探针 CardRemoved=true 复现过）。
        $next = [ordered]@{}
        foreach ($k in $script:svc.Keys) { if ($k -ne $item.n) { $next[$k] = $script:svc[$k] } }
        try { Save-Svc $next }
        catch {
          # 服务已从系统删除，只是清单没写成：卡片保留并标「待保存」，给重试入口。
          # 不回滚删除、不自动改 .bak、不替用户删资产。
          if (Get-Command Set-CardPendingSave -EA SilentlyContinue) { Set-CardPendingSave $script:cards[$item.n] $item.n }
          Set-StatusMessage "$($item.n) 已从系统删除，但清单保存失败：$($_.Exception.Message)。用右键「重试保存清单」。"
          continue
        }
        [Threading.Monitor]::Enter($script:sync.gate)
        try { [void]$script:svc.Remove($item.n) } finally { [Threading.Monitor]::Exit($script:sync.gate) }
        $script:cards.Remove($item.n)
        if ($script:healthSeen) { $script:healthSeen.Remove($item.n) }   # 同名重建时重记「首次观测」
        if ($script:svcState) { $script:svcState.Remove($item.n) }
        Set-StatusMessage "$($item.n) 已删除"
        Render-Page
      } else {
        # 启停回执：ok=$false 时 Update-CardData 回滚过渡态（T1），否则解封按钮与冷却。
        Update-CardData $item.n $null $null -e $item.e -ack -ok ([bool]$item.ok) -why ([string]$item.why)
      }
    } else {
      # restart 的中间回执（phase='start'）：停止阶段结束、开始启动。不是探测值，
      # 不能落 svcState / 健康历史，只把卡片过渡态换成「启动中」。§Update-CardRestartPhase
      if ($item.phase -eq 'start') {
        if (Get-Command Update-CardRestartPhase -EA SilentlyContinue) { Update-CardRestartPhase $item.n $item.e }
        continue
      }
      # 健康历史：只有「状态或健康值变了」才记一条（4 秒一拍的重复值不落盘，否则一天几万行）。
      # 写盘交给后台 runspace（UI 线程不碰 I/O），这里只入队。
      if ($null -eq $script:healthSeen) { $script:healthSeen = @{} }   # 单测/CLI 直接调 tick 时没有初始化
      # 惰性建也必须是 Synchronized：裸 @{} 会让 Web runspace 继续读旧实例，造成静默分叉。
      if ($null -eq $script:svcState) {
        $script:svcState = [hashtable]::Synchronized(@{})
        if ($script:sync -and -not $script:sync.svcState) { $script:sync.svcState = $script:svcState }
      }
      # 全量记「最近一次探测值」：批量启停按它筛目标，翻页外（没有卡片）的服务也要能全启/全停。
      # at = 落库时刻，批量据此跳过过期状态（后台 runspace 死掉/探测被限流时 svcState 会停在旧值）。
      # at 用 worker 的采样时刻（$item.at），不是 UI 消费时刻：排队/主线程卡顿不能把旧结果标成「刚更新」。
      # 缺 at 时回落 Now 只为兼容旧夹具/旧路径；生产路径（poll.ps1）每个结果都带 at。§Update-StatusTick
      $script:svcState[$item.n] = @{ st = $item.st; h = $item.h; at = $(if ($item.at) { [datetime]$item.at } else { [datetime]::Now }) }
      $prev = $script:healthSeen[$item.n]
      $prevSt = if ($prev) { $prev.st } else { $null }
      $prevH = if ($prev) { $prev.h } else { $null }
      if (Test-HealthChanged $prevSt $prevH $item.st $item.h) {
        $script:healthSeen[$item.n] = @{ st = $item.st; h = $item.h }
        if ($script:healthQueue) { $script:healthQueue.Enqueue((New-HealthEvent $item.n $item.st $item.h)) }
      }
      Update-CardData $item.n $item.st $item.h
    }
  }
  $msg = $null
  while ($script:msgQueue.TryDequeue([ref]$msg)) { Set-StatusMessage $msg }
  # 过渡态超时逃生：不依赖队列（后台 runspace 死了也要能逃），每帧独立判一次。§Update-StatusTick
  if ($script:cards -and (Get-Command Invoke-TransitionTimeoutEscape -EA SilentlyContinue)) {
    $now = [datetime]::Now
    # Get-Command 守卫：card.ps1 未加载（CLI/部分单测）时该函数不存在，不能带崩整个 tick。§Update-StatusTick
    foreach ($card in @($script:cards.Values)) {
      [void](Invoke-TransitionTimeoutEscape $card $now)
      # 同帧刷新时长：与逃生口一样不依赖队列。§Update-StatusTick
      Update-CardClock $card $now
      # 陈旧样本同样不依赖队列：后台还活着但探测被限流/卡住时，卡片不能继续假装实时。
      # 后台已确认死亡后不再扫：那时 Set-CardOffline 的「未知」才是权威，别让新鲜度判定再改一遍。
      if (-not $script:bgDeathReported -and (Get-Command Update-CardFreshness -EA SilentlyContinue)) { Update-CardFreshness $card $now }
    }
  }
  # 后台 runspace 结束 = 探测与命令都没人处理了。不提示的话按钮全灰、卡片停在最后一帧，
  # 而状态栏还在每 4 秒打「状态自动刷新」，看起来是活的——用户只能杀进程重开。
  if ($script:bgHandle -and $script:bgHandle.IsCompleted -and -not $script:bgDeathReported) {
    $script:bgDeathReported = $true
    try { Write-CrashLog 'Background runspace completed unexpectedly' } catch {}
    Set-StatusMessage '后台已停止响应，状态不可用；请关闭重开'
    foreach ($card in @($script:cards.Values)) {
      # 所有卡片都必须承认「不知道」：只把「查询中」改成未知，其余卡会继续显示上一次的
      # 「运行中/正常」，等于整屏在说谎（探针 CardStillSaysRunning=true 复现过）。
      if (Get-Command Set-CardOffline -EA SilentlyContinue) { Set-CardOffline $card }
      elseif ($card.ST -eq '查询中') { Set-CardRollback $card '未知' '' }
    }
  }
  # 空闲 4 秒后自动刷新状态文字；消息租约未到期时不覆盖（T4）。
  # 后台已死时不再自动刷新——那会把「后台已停止响应」那条提示盖掉，又变成「看起来是活的」。
  if (-not $script:bgDeathReported -and $script:statusBar -and (-not $script:lastActionAt -or ([datetime]::Now - $script:lastActionAt).TotalSeconds -ge 4)) {
    if (-not $script:msgUntil -or [datetime]::Now -ge $script:msgUntil) {
      $script:statusBar.Text = "$(Get-Date -Format 'HH:mm:ss')  状态自动刷新"
    }
  }
  # 标题栏新鲜度胶囊（含托盘 tooltip 刷新）；函数在 xaml.ps1，CLI/部分单测不加载，带守卫。
  # 单独包 try：胶囊是「数据还可不可信」的唯一常驻指示，不能让上游一条坏数据把它连累停更——
  # 停更的表现是数字冻结在最后一帧，看起来比「离线」更可信。
  try { if (Get-Command Update-FreshnessPill -EA SilentlyContinue) { Update-FreshnessPill } }
  catch { try { Write-CrashLog "Freshness pill failed: $($_.Exception.Message)" } catch {} }
}

# 探测单实例 mutex 是否被 GUI 持有。OpenExisting 抛 = 无 GUI（正常）；抢到要立即释放。§Test-GuiInstanceRunning
function Test-GuiInstanceRunning([string]$mutexName){
  try {
    $m = [Threading.Mutex]::OpenExisting($mutexName)
  } catch [System.Threading.WaitHandleCannotBeOpenedException] {
    return $false   # 互斥体不存在 = 没有 GUI 常驻
  } catch {
    # 存在但打不开（别的账户/SYSTEM 服务创建的 Global 互斥体 DACL 不允许）：保守判「运行中」，
    # 宁可让 CLI 让路，也不要覆盖别人的清单。
    return $true
  }
  try {
    $held = -not $m.WaitOne(0)
    if (-not $held) { $m.ReleaseMutex() }
    $held
  } catch {
    # AbandonedMutexException 等：保守判为运行中，宁可让 CLI 让路
    $true
  } finally { $m.Dispose() }
}
