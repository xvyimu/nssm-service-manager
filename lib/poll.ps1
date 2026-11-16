# lib/poll.ps1 — 后台探测与命令执行；命令可唤醒空闲等待，在每次服务探测之间优先处理
# UI 线程绝不碰 I/O；结果经 ConcurrentQueue 回 UI 侧 DispatcherTimer 取
# 内存取舍：TcpClient + 共享 HttpClient（Get-NetTCPConnection 常驻 +10MB，IWR 每次新建整套 cmdlet）。

# 后台探测脚本块（字符串，在 runspace 里执行）。runspace 不能 dot-source，故把 svc-common.ps1
# 与 health.ps1 的文本前置进 $script:poll——UI 与后台引用同一份源码。实现细节：docs/IMPLEMENTATION-NOTES.md
$script:poll = (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'svc-common.ps1')) +
               (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'health.ps1')) + @'
# runspace 内构造一次、复用到退出——HttpClient 本身线程安全
$http = [System.Net.Http.HttpClient]::new()
# 超时从 $sync 读（UI 线程从 config 注入），未设时回落默认；生效值写回同一键供测试断言。
$tcpMs  = if ($sync.tcpTimeoutMs)        { [int]$sync.tcpTimeoutMs }        else { 200 }
$httpMs = if ($sync.httpTimeoutMs)       { [int]$sync.httpTimeoutMs }       else { 3000 }
$waitMs = if ($sync.waitStoppedTimeoutMs){ [int]$sync.waitStoppedTimeoutMs } else { 12000 }
# per-service 停止预算：services.json 的 waitStoppedTimeoutMs；无该键 → 全局注入值（默认 12000）。
# 显式传进 Wait-Stopped，改一个服务的预算不波及别的服务。
function Get-WaitStoppedMs([string]$svcName){
  $v = 0
  if ($sync.svc) { try { $v = [int]$sync.svc[$svcName].waitStoppedTimeoutMs } catch { $v = 0 } }
  if ($v -gt 0) { $v } else { $waitMs }
}
# 服务状态探测查询的硬超时：UI 侧注入 config.SvcStateTimeoutMs，未注入传 0 让 Get-SvcStateQuiet
# 自己回落（runspace 里没有 config，注入是唯一通路）。
$svcStateMs = if ($sync.svcStateTimeoutMs) { [int]$sync.svcStateTimeoutMs } else { 0 }
# 节奏与并行度也从 $sync 读（UI 线程从 config 注入），测试夹具未设时回落原硬编码值。
$probeIntervalMs = if ($sync.probeIntervalMs) { [int]$sync.probeIntervalMs } else { 4000 }
$probeIdleMs     = if ($sync.probeIdleMs)     { [int]$sync.probeIdleMs }     else { 15000 }
$probePendingMs  = if ($sync.probePendingMs)  { [int]$sync.probePendingMs }  else { 1000 }
$probeThrottle   = if ($sync.probeThrottleLimit) { [int]$sync.probeThrottleLimit } else { 8 }
# 中间态集合同样从 $sync 读。**这里的字面量是 runspace 缺注入时的兜底**（夹具只塞部分键、
# 或有人直接跑这段文本块时）；正常路径由入口 service-manager-gui.ps1 从 config.ps1 的
# $script:SCM_PENDING_STATES 注入，唯一真实来源仍是 config.ps1（改集合要两边同步）。
$scmPending = if ($sync.scmPendingStates) { @($sync.scmPendingStates) } else { @('启动中','停止中','暂停中','继续中') }
# 超时按**每次请求**用 CTS 控制（per-service 可能比全局长，HttpClient.Timeout 是实例级）。
# 必须是 System.Threading.Timeout.InfiniteTimeSpan；TimeSpan.InfiniteTimeSpan 旧运行时取到 $null。
$http.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
$sync.tcpTimeoutMs = $tcpMs; $sync.httpTimeoutMs = $httpMs; $sync.waitStoppedTimeoutMs = $waitMs
$sync.probeIntervalMs = $probeIntervalMs; $sync.probeIdleMs = $probeIdleMs
$sync.probePendingMs = $probePendingMs
$sync.probeThrottleLimit = $probeThrottle

# sc.exe 不抛异常，只靠 $LASTEXITCODE；经 Invoke-ScQuiet 避免弹控制台窗。
# 退出码/状态映射在 svc-common.ps1（here-string 里的函数不进 UI 作用域，故移出去共享）。
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

# Start() 对慢启动服务会等满 ServicesPipeTimeout（实测 30032ms）再抛——catch 里先看真实状态。
# 两个坑（HANDOFF P0-2）：① Status 对不存在的服务返回空串不抛，需判空回落 sc.exe；
# ② 已运行/无权限抛英文包壳异常，回落 sc.exe 出中文。ServiceController 持 SCM 句柄，用 try/finally 释放。
function Invoke-ServiceStart([string]$n,[string]$fail='启动失败'){
  $svc = $null
  try {
    # 构造点可注入：$sync.newSc 给出替身函数名时用它（runspace 里无法替身化 .NET 构造函数）。
    $svc = if ($sync.newSc) { & $sync.newSc $n } else { [System.ServiceProcess.ServiceController]::new($n) }
    $status = [string]$svc.Status
    if ([string]::IsNullOrEmpty($status)) { return (Invoke-Sc 'start' $n $fail) }
    # Running/StartPending 同组：Start() 对两者都抛，回落 sc.exe 会得到 1056「已在运行」的矛盾文案。
    # 右键菜单直接 Send-ServiceCommand 不经 ST 门闩，故 StartPending 能落到这里。
    if ($status -in @('Running','StartPending')) { return $true }
    $svc.Start()                                  # 立即返回，不等 RUNNING
    return $true
  } catch {
    # 慢启动：Start() 等满 30s 才抛，此时服务其实已在起——先看真实状态，别回落 sc.exe（会弹黑框）。
    # 不再用 Get-Service：它没有超时参数，SCM 挂起时这里会第二次永久阻塞（Start() 已经等满 30s），
    # 整个命令队列和探测一起停摆。Get-SvcStateQuiet 走 sc.exe query + 硬超时，查不到返回 $null。
    $real = Get-SvcStateQuiet $n $svcStateMs
    if ($real -in @('StartPending','Running')) { return $true }
    return (Invoke-Sc 'start' $n $fail)           # 取退出码文案，比内层英文异常友好
  } finally {
    if ($svc) { try { $svc.Dispose() } catch { Write-Verbose "lib/poll.ps1: 启动失败后释放服务对象失败，忽略：$($_.Exception.Message)" } }
  }
}

function Invoke-PendingCommands {
  # 执行命令队列（启停与删除全在后台，避免 UI 线程同步等待冻结界面）。
  # 返回本轮执行条数——主循环据此判「有在途命令」，影响轮询间隔。
  $item=$null
  $ran=0
  while(-not $sync.stop -and $sync.cmd.TryDequeue([ref]$item)){
    $n=[string]$item.n; $act=[string]$item.act; $e=$item.e
    $ok=$true  # 每次迭代重置，防止上一条的失败码泄漏；未知 act 兜底判成功
    # why 同样必须重置：上一轮的失败原因会跟着下一轮成功回执一起回传，UI 会拿到假原因是「刚才失败」。
    $why=''
    try {
    switch($act){
      'start'   { $ok=Invoke-ServiceStart $n }
      'stop'    {
        # 先发 stop，再等 Stopped（≤该服务预算），最后回执：等待期进度条由 Wait-Stopped 发布。
        if(Invoke-Sc 'stop' $n '停止失败'){
          if(-not (Wait-Stopped $n -TimeoutMs (Get-WaitStoppedMs $n))) { $ok=$false; $why='停止未在超时内完成' }
        } else { $ok=$false }
      }
      'restart' {
        if(-not (Invoke-Sc 'stop' $n '停止失败，重启中断')) { $ok=$false; break }
        # 等不到 Stopped 就不能往下 start：此时 SCM 多半回 1056（已在运行/正在停止），
        # 旧代码丢弃返回值直接 start，失败文案会写成「已在运行」，与事实（仍在停止）相反。
        if(-not (Wait-Stopped $n -TimeoutMs (Get-WaitStoppedMs $n))) { $ok=$false; $why='停止未在超时内完成，已中止重启'; break }
        # 中间回执：停止阶段结束、开始启动。UI 收到后把过渡态从「停止中」换成「启动中」，
        # 否则整个重启期间卡片都写着「停止中」，看不出它已经开始起来了。
        $sync.queue.Enqueue([pscustomobject]@{n=$n;st=$null;h=$null;e=$e;phase='start'})
        Start-Sleep -Milliseconds 500  # 端口 TIME_WAIT 余量
        $ok=Invoke-ServiceStart $n '重启后启动失败'
      }
      'remove' {
        # 删除走后台：stop → Wait-Stopped ≤该服务预算（缺省 12s）→ nssm remove confirm → 实证复核。
        # 序列本体在 svc-common.ps1 的 Invoke-ServiceRemove（与 nssm.ps1 共用一份，免得漂移）。
        $ok=$true
        try {
          $r = Invoke-ServiceRemove $n $sync.nssm -TimeoutMs (Get-WaitStoppedMs $n)
          if(-not $r.ok){
            $msg = if($r.exitCode -ne 0){ "$n 删除失败($($r.exitCode))" } else { "$n 删除失败：$($r.why)" }
            $sync.msg.Enqueue($msg); $ok=$false
          }
        } catch { $sync.msg.Enqueue("$n 删除失败: $($_.Exception.Message)"); $ok=$false }
      }
    }
    } catch {
      # 单条命令抛异常不许终结轮询循环：照常产出失败回执，否则卡片停在过渡态直到超时逃生。
      $why = "$n $act 失败: $($_.Exception.Message)"
      $sync.msg.Enqueue($why)
      $ok=$false
    }
    # 命令完成回执：带 epoch 与 ok 回 UI。
    # 失败时 UI 侧要回滚过渡态并解封按钮（T1：原实现失败即静默，卡片永久卡死）。
    # why 随回执回传：失败原因要落到卡片上，不能只靠 5 秒租约的状态栏。
    $sync.queue.Enqueue([pscustomobject]@{n=$n;st=$null;h=$null;e=$e;done=$true;act=$act;ok=[bool]$ok;why=$why;at=[datetime]::Now})
    $ran++
  }
  $ran
}

try {
# 上一次全量健康探测的时刻（TickCount64，单调）：中间态快轮询只加快状态查询，不该提速探测。
$lastProbeAt = [long]0
# 每个服务最近一次健康值：探测被限流跳过时用它把状态送到 UI，不让圆点闪红
$lastHealth = @{}
# 每个服务最近一次「真正探测完成」的时刻：限流跳过时沿用旧值，但必须沿用旧的采样时刻，
# 否则 UI 会把几轮都没探测的旧值当成刚刚更新（新鲜度造假）。
$lastHealthAt = @{}
while(-not $sync.stop){
  $executedCmd = (Invoke-PendingCommands) -gt 0  # 本轮是否执行过命令：影响轮询间隔，见循环尾
  # 健康历史落盘：UI 线程只把「状态/健康变了」的事件塞进队列，写盘在这里（UI 线程不碰 I/O）。
  # Add-HealthEvent 自己吞异常——历史写不进去不该影响探测，更不该让后台循环停摆。
  if ($sync.healthQ) {
    $hev = $null
    while ($sync.healthQ.TryDequeue([ref]$hev)) { $null = Add-HealthEvent $sync.healthDir $hev }
  }
  # 拷快照（加锁，避免枚举期间 UI 侧增删）
  [Threading.Monitor]::Enter($sync.gate)
  try { $snap = @($sync.svc.Keys) } finally { [Threading.Monitor]::Exit($sync.gate) }

  # 状态查询（发现 7）：一次 sc query 枚举拿全部。为什么不再用 Get-Service：
  # 它没有超时参数——SCM 挂起（句柄等不到、被安全软件挂起）时整批调用永久阻塞，后台 runspace
  # 就此停摆，且不抛异常、crash log 留不下线索。这正是本条要消除的已知限制。
  # sc.exe 没有「多服务名查询」，全量枚举是它唯一的一次性口径；枚举失败/超时 → $null，
  # 由收集阶段逐个回落 Get-SvcStateQuiet，在那里区分「未安装」与「未知」。
  $svcStatus = @{}
  if ($snap.Count) {
    $allStatus = Get-SvcStateMapQuiet $svcStateMs
    foreach ($n in $snap) { $svcStatus[$n] = if ($allStatus) { [string]$allStatus[$n] } else { '' } }
  }

  # 收集阶段：运行中的留待并行探测，其余直接入队。并行化（发现 4）：6 服务串行最坏 ~19s，
  # 并行后 ~3.2s；命令在收集间隙仍优先处理，但并行探测期间不插入。
  $toProbe = [System.Collections.Generic.List[pscustomobject]]::new()
  # 服务停在中间态也算「活跃」，否则轮询退到 15s，「启动中」十几秒才更新一次。
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
      # 批量枚举未返回此服务：单独查一次。Get-SvcStateQuiet 的 $null 同时覆盖「服务不存在」
      # 与「查询超时/失败」——再用一次 query 退出码把两者分开（只有这条异常路径才付这次调用）：
      # 1060/1072 = SCM 里没有这个服务 → 未安装；其余（含 -1 超时）= 未知。
      $one = Get-SvcStateQuiet $n $svcStateMs
      if ($one) {
        $st = Convert-ServiceStatus $one
      } else {
        $code = -1
        try { $code = Get-ServiceQueryCode $n $svcStateMs } catch { $code = -1 }
        $st = if ($code -in @(1060,1072)) { '未安装' } else { '未知' }
      }
    }

    if ($st -eq '运行中') {
      # probe=none：无端口服务，服务状态即健康状态，不做连通性探测
      if ([string]$info.probe -eq 'none') {
        $sync.queue.Enqueue([pscustomobject]@{n=$n;st=$st;h='正常';at=[datetime]::Now})
      } else {
        # per-service 探测超时随探测项带给并行块；缺省是 0，并行块回落到全局值
        $toProbe.Add([pscustomobject]@{
          n=$n; port=[int]$info.port; url=[string]$info.url
          probe=[string]$info.probe
          tcpMs=[int]$info.tcpTimeoutMs; httpMs=[int]$info.httpTimeoutMs
          stopped=$false
        })
      }
    } else {
      # 中间态判定走 $scmPending：正常路径由入口注入 $sync.scmPendingStates（唯一真实来源 = config.ps1），
      # 脚本开头那一处 else 字面量只是 runspace 缺注入时的兜底。
      if ($st -in $scmPending) { $pendingSeen = $true }
      # 已停止但端口仍被占用：说明有非服务进程在听（孤儿进程）。给一个可见信号，
      # 否则「服务已停止」和「网页还能打开」会同时成立，用户无从判断。
      $orphanPort = ($st -eq '已停止' -and [int]$info.port -gt 0 -and [string]$info.probe -ne 'none')
      if ($orphanPort) {
        $toProbe.Add([pscustomobject]@{
          n=$n; port=[int]$info.port; url=''
          probe='tcp'
          tcpMs=[int]$info.tcpTimeoutMs; httpMs=0
          stopped=$true
        })
      } else {
        $sync.queue.Enqueue([pscustomobject]@{n=$n;st=$st;h='';at=[datetime]::Now})
      }
    }
  }

  # 并行探测运行中服务：每服务一块，TCP→HTTP 串行，服务间并行；$using:http 传 HttpClient。
  # 中间态期间按 ProbeIntervalMs 限流 TCP+HTTP，但状态不能跟着慢——被跳过的那轮仍按上次健康值入队。
  # 用 TickCount64 而非墙钟：NTP 校正/休眠恢复让墙钟回拨时，差值为负会让探测一直「还没到点」。
  $probeDue = -not $pendingSeen -or
              ([Environment]::TickCount64 - $lastProbeAt -ge $probeIntervalMs)
  if ($toProbe.Count -and -not $sync.stop -and -not $probeDue) {
    foreach($p in $toProbe){
      # 已停止服务的条目只回答「端口是否被占用」：跳过轮直接不入队，
      # 否则会沿用历史健康值把卡片刷回「运行中 + 绿点」。
      if ($p.stopped) { continue }
      # 还没有过任何探测结果时不入队：h='' 会让运行中的圆点闪红
      if ($lastHealth.ContainsKey($p.n)) {
        # 沿用旧健康值时一并沿用旧采样时刻：这一轮并没有真的探测，不能标成「刚刚更新」。
        $at = if ($lastHealthAt[$p.n]) { $lastHealthAt[$p.n] } else { [datetime]::Now }
        $sync.queue.Enqueue([pscustomobject]@{n=$p.n;st='运行中';h=$lastHealth[$p.n];at=$at})
      }
    }
  }
  # 到点（或不在中间态）：真探一轮 TCP+HTTP，结果同时刷新 $lastHealth
  if ($toProbe.Count -and -not $sync.stop -and $probeDue) {
    $lastProbeAt = [Environment]::TickCount64
    $results = $toProbe | ForEach-Object -Parallel {
      $n=$_.n; $p=$_.port; $url=$_.url; $probeLocal=[string]$_.probe
      # 每项的生效超时：per-service 覆盖优先，缺省回落经 $using: 传入的全局值
      $tcpMsLocal  = if ($_.tcpMs)  { [int]$_.tcpMs }  else { $using:tcpMs }
      $httpMsLocal = if ($_.httpMs) { [int]$_.httpMs } else { $using:httpMs }
      $httpClient=$using:http
      # 轻量端口探测。$tcpMs 必须经 $using: 传入——Parallel 开新 runspace 不继承父变量，
      # 裸用取到 $null，WaitOne(0) 立刻返回 False，运行中服务被误判「无响应」变红。
      $listen=$false
      $tcp=[System.Net.Sockets.TcpClient]::new()
      try {
        $iar=$tcp.BeginConnect('127.0.0.1',$p,$null,$null)
        if($iar.AsyncWaitHandle.WaitOne($tcpMsLocal,$false)){
          # 空 catch 有意：端口没人听时 EndConnect 必然抛，这是常态不是异常（每轮探测都走，加日志会刷屏）
          try{$tcp.EndConnect($iar);$listen=$true}catch{}
        }
      } finally {
        # 空 catch 有意：Close 失败只影响本次探测的 socket 回收，不影响判定（每轮探测都走，加日志会刷屏）
        try{$tcp.Close()}catch{}
      }

      # 已停止服务的探测只回答「端口是否被别的进程占着」，不参与健康判定
      if($_.stopped){ return [pscustomobject]@{n=$n;h=($(if($listen){'端口被占用'}else{''}));stopped=$true} }
      if(-not $listen){ return [pscustomobject]@{n=$n;h='无响应'} }
      # probe=tcp 或没填 url：TCP 通即正常。非 HTTP 服务（数据库/gRPC/纯 socket 守护）走 HTTP
      # 探测必然失败，旧实现让这类卡永远不是绿点，还会把「关闭」按钮一起锁死。§probe
      if ($probeLocal -eq 'tcp' -or [string]::IsNullOrWhiteSpace($url)) {
        return [pscustomobject]@{n=$n;h='正常'}
      }
      # HTTP 探测。响应和 CTS 都必须 Dispose——每轮每服务各泄漏一份缓冲与 WaitHandle。
      $cts = [System.Threading.CancellationTokenSource]::new($httpMsLocal)
      try {
        $r=$httpClient.GetAsync($url,$cts.Token).GetAwaiter().GetResult()
        try { $h=if($r.StatusCode -eq [System.Net.HttpStatusCode]::OK){'正常'}else{'HTTP '+[int]$r.StatusCode} } finally { $r.Dispose() }
      } catch {
        # 异常归类：refused/connection → 无响应，其余（超时/DNS）→ 超时。
        $ex=$_.Exception.InnerException; if(-not $ex){$ex=$_.Exception}
        $msg=[string]$ex.Message
        $h=if($msg -match 'refused|unable to connect|连接|connection|ConnectFailure'){'无响应'}else{'超时'}
      } finally { $cts.Dispose() }
      [pscustomobject]@{n=$n;h=$h}
    } -ThrottleLimit $probeThrottle
    foreach($r in $results){
      if ($r.stopped) {
        # 已停止服务的「端口占用」只用于提示，不进健康缓存
        $sync.queue.Enqueue([pscustomobject]@{n=$r.n;st='已停止';h=$r.h;at=[datetime]::Now})
      } else {
        $lastHealth[$r.n]=$r.h; $lastHealthAt[$r.n]=[datetime]::Now
        $sync.queue.Enqueue([pscustomobject]@{n=$r.n;st='运行中';h=$r.h;at=$lastHealthAt[$r.n]})
      }
    }
  }

  if ((Invoke-PendingCommands) -gt 0) { $executedCmd = $true }
  # 有运行中服务按 ProbeIntervalMs；全停止拉长到 ProbeIdleMs（省空转唤醒与整轮扫描）。
  # 「本轮执行过命令」也算活跃：刚下发启动命令时 $toProbe 为空，按空闲走 15s 会让卡片停在「启动中」。
  # 「有服务停在过渡态」同样用短间隔，让翻转 1 秒内可见。
  if (-not $sync.stop) {
    # 中间态用更短间隔；也照常探测运行中的服务（本地回环，代价可忽略）。
    # 只数「运行中」的探测项：已停止服务的端口占用检查不该把整轮节奏从 15s 拉到 4s。
    $activeProbe = @($toProbe | Where-Object { -not $_.stopped }).Count
    $sleepMs = if ($pendingSeen) { $probePendingMs }
               elseif ($activeProbe -or $executedCmd) { $probeIntervalMs }
               else { $probeIdleMs }
    [void]$sync.wake.WaitOne($sleepMs)
  }
}
} finally { $http.Dispose() }
'@
