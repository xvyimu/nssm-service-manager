# lib/poll.ps1 — 后台探测与命令执行；命令可唤醒空闲等待，在每次服务探测之间优先处理
# UI 线程绝不碰 I/O；结果经 ConcurrentQueue 回 UI 侧 DispatcherTimer 取
#
# 内存取舍：端口探测用 TcpClient（Get-NetTCPConnection 会常驻 +10MB CIM provider）；
# HTTP 用共享 HttpClient（IWR 每次新建并加载整套 cmdlet）。结果仍是字符串，不持有 UI 对象。

# 后台探测脚本块（字符串，在 runspace 里执行）
# Wait-Stopped 在 lib/svc-common.ps1，与里面的 Invoke-ServiceRemove 引用同一份实现。
# runspace 不能 dot-source 外部文件（脚本块字符串里没有 $PSScriptRoot），构造时把 svc-common.ps1
# 的文本前置进 $script:poll——UI 线程与后台引用的是同一份源码，原「SYNC: 两处同改」注释消除。
$script:poll = (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'svc-common.ps1')) + @'
# runspace 内构造一次、复用到退出——HttpClient 本身线程安全
$http = [System.Net.Http.HttpClient]::new()
# 超时从 $sync 读（UI 线程从 config 注入），未设时回落默认；生效值写回同一键供测试断言。
$tcpMs  = if ($sync.tcpTimeoutMs)        { [int]$sync.tcpTimeoutMs }        else { 200 }
$httpMs = if ($sync.httpTimeoutMs)       { [int]$sync.httpTimeoutMs }       else { 3000 }
$waitMs = if ($sync.waitStoppedTimeoutMs){ [int]$sync.waitStoppedTimeoutMs } else { 6000 }
# 节奏与并行度也从 $sync 读（UI 线程从 config 注入），测试夹具未设时回落原硬编码值。
$probeIntervalMs = if ($sync.probeIntervalMs) { [int]$sync.probeIntervalMs } else { 4000 }
$probeIdleMs     = if ($sync.probeIdleMs)     { [int]$sync.probeIdleMs }     else { 15000 }
$probePendingMs  = if ($sync.probePendingMs)  { [int]$sync.probePendingMs }  else { 1000 }
$probeThrottle   = if ($sync.probeThrottleLimit) { [int]$sync.probeThrottleLimit } else { 8 }
# 超时改由**每次请求**的 CancellationTokenSource 控制（services.json 里 per-service 的
# httpTimeoutMs 可能比全局值更长，而 HttpClient.Timeout 是实例级上限，单次请求改不动）。
# 实例级放开到无限，全局 $httpMs 变成「没有 per-service 覆盖时」的默认值。
# 注意是 System.Threading.Timeout.InfiniteTimeSpan；TimeSpan.InfiniteTimeSpan 在旧运行时上不存在
# （PowerShell 里取到 $null → 赋值抛 "Cannot convert null to type System.TimeSpan"）。
$http.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
$sync.tcpTimeoutMs = $tcpMs; $sync.httpTimeoutMs = $httpMs; $sync.waitStoppedTimeoutMs = $waitMs
$sync.probeIntervalMs = $probeIntervalMs; $sync.probeIdleMs = $probeIdleMs
$sync.probePendingMs = $probePendingMs
$sync.probeThrottleLimit = $probeThrottle

# sc.exe 不抛异常，只靠 $LASTEXITCODE；包装成 helper，失败时反馈到 UI 状态栏
# 退出码映射与状态映射已移到 lib/svc-common.ps1（本文件头部把它的文本前置进 runspace，
# 故此处仍可用）；移出去是因为 UI 线程与 CLI 也要同一份映射，而 here-string 里的函数
# 不进 UI 作用域。
function Invoke-Sc([string]$verb,[string]$n,[string]$fail){
  # 经 Invoke-ScQuiet：GUI 进程里直接 `& sc.exe` 会给子进程开一个控制台窗口
  $code = Invoke-ScQuiet @($verb, $n)
  if($code -ne 0){
    $reason = Convert-ScExitCode $code
    $sync.msg.Enqueue("$n $fail($code $reason)")
    return $false
  }
  $true
}

# Start() 对慢启动服务会等满 ServicesPipeTimeout（30s）再抛异常（实测 30032ms）——
# 所以 catch 里先看真实状态：StartPending/Running 就算启动成功，别回落 sc.exe（会弹控制台窗）。
# 两个坑（见 docs/HANDOFF.md P0-2）：① Status 对不存在的服务返回空串而非抛异常，
# 需先判空回落 sc.exe 取「未安装」错码；② 已运行/无权限时抛英文包壳异常，
# 回落到 sc.exe 取退出码经 Convert-ScExitCode 出中文更友好。
# ServiceController 持有 SCM 句柄，用 try/finally 释放，不靠 GC。
function Invoke-ServiceStart([string]$n,[string]$fail='启动失败'){
  $svc = $null
  try {
    # 构造点可注入：$sync.newSc 给出 runspace 内一个函数名时用它（同 $sync.nssm 的约定）。
    # runspace 里无法替身化 .NET 构造函数，测试要构造 StartPending 状态的替身只能从这里进；
    # 未设时走真实 ServiceController，生产路径零开销。
    $svc = if ($sync.newSc) { & $sync.newSc $n } else { [System.ServiceProcess.ServiceController]::new($n) }
    $status = [string]$svc.Status
    if ([string]::IsNullOrEmpty($status)) { return (Invoke-Sc 'start' $n $fail) }
    # Running 与 StartPending 同组：服务已在（或正在）启动，Start() 对这两种状态都会抛
    # MethodInvocationException，回落 sc.exe 取回 1056 → 状态栏出现「启动失败(1056 已在运行)」
    # 这种自相矛盾的文案。触发路径真实：card.ps1 右键菜单的「启动」直接 Send-ServiceCommand，
    # 不经 Invoke-CardToggle 的 ST 门闩，故 StartPending 能落到这里。
    # 视作「已在启动」直接成功返回：不产生失败消息，也不白付一次 sc.exe 往返。
    if ($status -in @('Running','StartPending')) { return $true }
    $svc.Start()                                  # 立即返回，不等 RUNNING
    return $true
  } catch {
    # Start() 对**慢启动**服务会等满 ServicesPipeTimeout（实测 30s）再抛异常，而服务
    # 其实已经在起。先看真实状态：StartPending/Running 就按启动成功返回，别回落 sc.exe。
    # 回落那条路既会误报「启动失败」，又会给 GUI 进程弹出一个控制台窗口（实测：点启动约
    # 30 秒后冒黑框，正是这一刻）。
    try {
      $real = [string](Get-Service -Name $n -EA Stop).Status
      if ($real -in @('StartPending','Running')) { return $true }
    } catch {}
    return (Invoke-Sc 'start' $n $fail)           # 取退出码文案，比内层英文异常友好
  } finally {
    if ($svc) { try { $svc.Dispose() } catch {} }
  }
}

function Invoke-PendingCommands {
  # 执行命令队列（启停与删除全在后台线程，避免 UI 线程同步等待 stop/remove 冻结界面）
  # 返回本轮出队执行的命令条数——主循环据此判「有在途命令」，见下方面轮询间隔的取舍。
  $item=$null
  $ran=0
  while(-not $sync.stop -and $sync.cmd.TryDequeue([ref]$item)){
    $n=[string]$item.n; $act=[string]$item.act; $e=$item.e
    $ok=$null  # 每次迭代重置：前一条命令的失败码不得泄漏给下一条（act 不在 switch 表里时兜底判成功）
    switch($act){
      'start'   { $ok=Invoke-ServiceStart $n }
      'stop'    { $ok=Invoke-Sc 'stop' $n '停止失败' }
      'restart' {
        $ok=$true
        if(-not (Invoke-Sc 'stop' $n '停止失败，重启中断')) { $ok=$false; break }
        [void](Wait-Stopped $n)
        Start-Sleep -Milliseconds 500  # 端口 TIME_WAIT 余量
        $ok=Invoke-ServiceStart $n '重启后启动失败'
      }
      'remove' {
        # 删除走后台：stop → Wait-Stopped ≤6s → nssm remove confirm → 实证复核 → 回执带 done=remove
        # UI 侧（Show-Remove 的 del_Click）入队后立即关弹窗，结果由 ack 回执处理。
        # 序列本体在 svc-common.ps1 的 Invoke-ServiceRemove（本文件头部前置其文本），
        # 与 nssm.ps1 的 Remove-NssmService 共用同一份——原先两处各写一份，
        # 复核逻辑只改一侧就会漂移（例如有人简化这里，以为 nssm.ps1 有 canonical 实现）。
        # $nssm 在 runspace 里不可见——NSSM 路径经 $sync.nssm 从 UI 传入。
        $ok=$true
        try {
          $r = Invoke-ServiceRemove $n $sync.nssm
          if(-not $r.ok){
            $msg = if($r.exitCode -ne 0){ "$n 删除失败($($r.exitCode))" } else { "$n 删除失败：$($r.why)" }
            $sync.msg.Enqueue($msg); $ok=$false
          }
        } catch { $sync.msg.Enqueue("$n 删除失败: $($_.Exception.Message)"); $ok=$false }
      }
    }
    if ($null -eq $ok) { $ok=$true }  # 兜底：未知 act 不该出现，出现也当成功收尾
    # 命令完成回执：把同一命令纪元与执行结果带回 UI。ack 分支据此解封按钮/冷却或处理删除收尾。
    # ok 必须带回来——失败时（启动/停止/删除抛异常或 sc.exe 返回非零）UI 侧要回滚卡片过渡态
    # 并解封按钮，否则卡片永久卡在「启动中/停止中/删除中」（T1：原实现只在 $ok 时 Enqueue，
    # 失败即静默，配合 card.ps1 的单一期望终态守卫，按钮再也不会亮）。
    $sync.queue.Enqueue([pscustomobject]@{n=$n;st=$null;h=$null;e=$e;done=$true;act=$act;ok=[bool]$ok})
    $ran++
  }
  $ran
}

try {
# 上一次全量健康探测（TCP+HTTP）的时刻（TickCount64，毫秒、单调）：
# 中间态快轮询只加快状态查询，不该把探测也提速。0 = 启动后还没探测过。
$lastProbeAt = [long]0
# 每个服务最近一次健康值：探测被限流跳过时用它把状态送到 UI，不让圆点闪红
$lastHealth = @{}
while(-not $sync.stop){
  $executedCmd = (Invoke-PendingCommands) -gt 0  # 本轮是否执行过命令：影响轮询间隔，见循环尾
  # 拷快照（加锁，避免枚举期间 UI 侧增删）
  [Threading.Monitor]::Enter($sync.gate)
  try { $snap = @($sync.svc.Keys) } finally { [Threading.Monitor]::Exit($sync.gate) }

  # 批量查询服务状态（发现 7）：一次 Get-Service 拿回全部，避免每服务一次 SCM 往返。
  # 只要有任一名字不存在，Get-Service 就整批抛 ObjectNotFound（实测：不是部分返回，
  # 赋值都完不成）——故 catch 退回逐个查询，在那里区分「未安装」与「未知」。
  $svcStatus = @{}
  if ($snap.Count) {
    try {
      # Get-Service 可能返回单个对象或数组；统一成数组再按 Name 索引
      foreach ($s in @(Get-Service -Name $snap -EA Stop)) { $svcStatus[$s.Name] = [string]$s.Status }
    } catch {
      # 整批失败（任一服务未安装即触发）：退回逐个查询
      foreach ($n in $snap) {
        try { $svcStatus[$n] = [string](Get-Service -Name $n -EA Stop).Status } catch { $svcStatus[$n] = $null }
      }
    }
  }

  # 收集阶段：算状态，运行中的留待并行探测，其余直接入队。
  # 并行化（发现 4）：原 foreach 串行 TCP+HTTP，6 服务最坏 ~19s；
  # 改并行后最坏 ~3.2s（HTTP 超时上限）。命令在收集间隙仍优先处理，
  # 但并行探测期间不插 Invoke-PendingCommands——最长等一次并行轮。
  $toProbe = [System.Collections.Generic.List[pscustomobject]]::new()
  # 有服务停在 StartPending/StopPending/暂停中/继续中时也算「活跃」：否则过渡期间整轮没有可探测项，
  # 轮询退到 ProbeIdleMs(15s)，卡片上的「启动中」十几秒才收到一次状态，过渡计时也迟迟不刷新。
  $pendingSeen = $false
  foreach($n in $snap){
    # 收集间隙也优先处理命令；此处执行过的命令同样算「有在途命令」，影响循环尾间隔。
    if ((Invoke-PendingCommands) -gt 0) { $executedCmd = $true }
    if ($sync.stop) { break }
    [Threading.Monitor]::Enter($sync.gate)
    try { $info = $sync.svc[$n] } finally { [Threading.Monitor]::Exit($sync.gate) }
    if (-not $info) { continue }

    $st = Convert-ServiceStatus ([string]$svcStatus[$n])
    if (-not $svcStatus[$n]) {
      # 批量查询未返回此服务：单独查一次，区分未安装与未知
      try { $st = Convert-ServiceStatus ([string](Get-Service -Name $n -EA Stop).Status) }
      catch { if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { $st='未安装' } else { $st='未知' } }
    }

    if ($st -eq '运行中') {
      # per-service 探测超时随探测项带给并行块；缺省是 0，并行块回落到全局值
      $toProbe.Add([pscustomobject]@{
        n=$n; port=[int]$info.port; url=[string]$info.url
        tcpMs=[int]$info.tcpTimeoutMs; httpMs=[int]$info.httpTimeoutMs
      })
    } else {
      if ($st -in @('启动中','停止中','暂停中','继续中')) { $pendingSeen = $true }
      $sync.queue.Enqueue([pscustomobject]@{n=$n;st=$st;h=''})
    }
  }

  # 并行探测运行中服务：每个服务一个并行块，内部 TCP→HTTP 串行，服务间并行。
  # $using:http 传 HttpClient 引用（线程安全）；结果按输入顺序返回，统一入队。
  # 中间态快轮询期间（$pendingSeen）按 ProbeIntervalMs 限流 TCP+HTTP：1s 一轮会把
  # 运行中服务的探测负载放大 4 倍，而服务卡在 StopPending 可能持续很久。
  # **但状态不能跟着慢**：被限流跳过的那一轮，仍把 $toProbe 各服务按「运行中 + 上次
  # 健康值」入队——批量 Get-Service 已经拿到新状态，这里只是把它送到 UI。
  # 用 TickCount64 而不是墙钟：NTP 校正/休眠恢复让时钟回拨时，墙钟差为负会让探测
  # 一直被判定「还没到点」。
  $probeDue = -not $pendingSeen -or
              ([Environment]::TickCount64 - $lastProbeAt -ge $probeIntervalMs)
  if ($toProbe.Count -and -not $sync.stop -and -not $probeDue) {
    foreach($p in $toProbe){
      # 还没有过任何探测结果时不入队：h='' 会让运行中的圆点闪红
      if ($lastHealth.ContainsKey($p.n)) {
        $sync.queue.Enqueue([pscustomobject]@{n=$p.n;st='运行中';h=$lastHealth[$p.n]})
      }
    }
  }
  # 到点（或不在中间态）：真探一轮 TCP+HTTP，结果同时刷新 $lastHealth
  if ($toProbe.Count -and -not $sync.stop -and $probeDue) {
    $lastProbeAt = [Environment]::TickCount64
    $results = $toProbe | ForEach-Object -Parallel {
      $n=$_.n; $p=$_.port; $url=$_.url
      # 每项的生效超时：per-service 覆盖优先，缺省回落经 $using: 传入的全局值
      $tcpMsLocal  = if ($_.tcpMs)  { [int]$_.tcpMs }  else { $using:tcpMs }
      $httpMsLocal = if ($_.httpMs) { [int]$_.httpMs } else { $using:httpMs }
      $httpClient=$using:http
      # 轻量端口探测：TcpClient $tcpMsLocal 超时（不用 Get-NetTCPConnection）
      # $tcpMs 必须经 $using: 传入——ForEach-Object -Parallel 开新 runspace，
      # 不继承父作用域变量；裸用 $tcpMs 在此取到 $null，WaitOne(0) 立刻返回 False，
      # 运行中服务被误判「无响应」变红（启停时 runspace 更忙，0ms 扑空概率上升）。
      $listen=$false
      $tcp=[System.Net.Sockets.TcpClient]::new()
      try {
        $iar=$tcp.BeginConnect('127.0.0.1',$p,$null,$null)
        if($iar.AsyncWaitHandle.WaitOne($tcpMsLocal,$false)){ try{$tcp.EndConnect($iar);$listen=$true}catch{} }
      } finally { try{$tcp.Close()}catch{} }

      if(-not $listen){ return [pscustomobject]@{n=$n;h='无响应'} }
      # HTTP 探测：共享 HttpClient，超时按请求给（默认 3s，per-service 可覆盖）。
      # 响应必须 Dispose，否则内容缓冲滞留——每轮探测泄漏一份。
      # CTS 也必须 Dispose：它是 WaitHandle 持有者，每轮每服务泄漏一份。
      $cts = [System.Threading.CancellationTokenSource]::new($httpMsLocal)
      try {
        $r=$httpClient.GetAsync($url,$cts.Token).GetAwaiter().GetResult()
        try { $h=if($r.StatusCode -eq [System.Net.HttpStatusCode]::OK){'正常'}else{'HTTP '+[int]$r.StatusCode} } finally { $r.Dispose() }
      } catch {
        # 异常归类：refused/connection 类 → 无响应，其余（含超时、DNS 失败等）→ 超时。
        # 原 timeout 正则与 else 同归 '超时'，是死分支——此处折叠。
        $ex=$_.Exception.InnerException; if(-not $ex){$ex=$_.Exception}
        $msg=[string]$ex.Message
        $h=if($msg -match 'refused|unable to connect|连接|connection|ConnectFailure'){'无响应'}else{'超时'}
      } finally { $cts.Dispose() }
      [pscustomobject]@{n=$n;h=$h}
    } -ThrottleLimit $probeThrottle
    foreach($r in $results){ $lastHealth[$r.n]=$r.h; $sync.queue.Enqueue([pscustomobject]@{n=$r.n;st='运行中';h=$r.h}) }
  }

  if ((Invoke-PendingCommands) -gt 0) { $executedCmd = $true }
  # 有运行中服务按 ProbeIntervalMs 轮询；全停止时拉长到 ProbeIdleMs——省下空转的
  # 唤醒与整轮 Get-Service/TCP 扫描（服务数为 0 时 $toProbe 为空，整轮只做一次快照）。
  # 除「有运行中服务」外，「本轮执行过命令」也算活跃：刚下发的启动命令那一轮里服务通常还
  # 是 Stopped/StartPending（$toProbe 为空），若按空闲走 15s 长睡眠，卡片会停在「启动中」
  # 最长约 15 秒才收到第一份探测结果。有在途命令时用短间隔，让回执与状态尽快收敛。
  # 第三种活跃情形：有服务停在过渡态（$pendingSeen）——慢启动期间整轮
  # 没有可探测项，若不特殊处理，卡片上的「启动中」要 15 秒才更新一次，过渡计时也迟迟不刷新。
  if (-not $sync.stop) {
    # 有服务停在中间态 → 用更短的间隔，让「启动中 → 运行中」这类翻转在 1 秒内可见；
    # 否则退到常规节奏。中间态时也照常探测运行中的服务（代价是本地回环 TCP/HTTP，可忽略）。
    $sleepMs = if ($pendingSeen) { $probePendingMs }
               elseif ($toProbe.Count -or $executedCmd) { $probeIntervalMs }
               else { $probeIdleMs }
    [void]$sync.wake.WaitOne($sleepMs)
  }
}
} finally { $http.Dispose() }
'@
