# lib/poll.ps1 — 后台探测与命令执行；命令可唤醒空闲等待，在每次服务探测之间优先处理
# UI 线程绝不碰 I/O；结果经 ConcurrentQueue 回 UI 侧 DispatcherTimer 取
# 内存取舍：TcpClient + 共享 HttpClient（Get-NetTCPConnection 常驻 +10MB，IWR 每次新建整套 cmdlet）。

# 后台探测脚本块（字符串，在 runspace 里执行）。runspace 不能 dot-source，故把 svc-common.ps1
# 的文本前置进 $script:poll——UI 与后台引用同一份源码。实现细节：docs/IMPLEMENTATION-NOTES.md
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
  # 执行命令队列（启停与删除全在后台，避免 UI 线程同步等待冻结界面）。
  # 返回本轮执行条数——主循环据此判「有在途命令」，影响轮询间隔。
  $item=$null
  $ran=0
  while(-not $sync.stop -and $sync.cmd.TryDequeue([ref]$item)){
    $n=[string]$item.n; $act=[string]$item.act; $e=$item.e
    $ok=$true  # 每次迭代重置，防止上一条的失败码泄漏；未知 act 兜底判成功
    try {
    switch($act){
      'start'   { $ok=Invoke-ServiceStart $n }
      'stop'    { $ok=Invoke-Sc 'stop' $n '停止失败' }
      'restart' {
        if(-not (Invoke-Sc 'stop' $n '停止失败，重启中断')) { $ok=$false; break }
        [void](Wait-Stopped $n)
        Start-Sleep -Milliseconds 500  # 端口 TIME_WAIT 余量
        $ok=Invoke-ServiceStart $n '重启后启动失败'
      }
      'remove' {
        # 删除走后台：stop → Wait-Stopped ≤6s → nssm remove confirm → 实证复核。
        # 序列本体在 svc-common.ps1 的 Invoke-ServiceRemove（与 nssm.ps1 共用一份，免得漂移）。
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
    } catch {
      # 单条命令抛异常不许终结轮询循环：照常产出失败回执，否则卡片停在过渡态直到超时逃生。
      $sync.msg.Enqueue("$n $act 失败: $($_.Exception.Message)")
      $ok=$false
    }
    # 命令完成回执：带 epoch 与 ok 回 UI。
    # 失败时 UI 侧要回滚过渡态并解封按钮（T1：原实现失败即静默，卡片永久卡死）。
    $sync.queue.Enqueue([pscustomobject]@{n=$n;st=$null;h=$null;e=$e;done=$true;act=$act;ok=[bool]$ok})
    $ran++
  }
  $ran
}

try {
# 上一次全量健康探测的时刻（TickCount64，单调）：中间态快轮询只加快状态查询，不该提速探测。
$lastProbeAt = [long]0
# 每个服务最近一次健康值：探测被限流跳过时用它把状态送到 UI，不让圆点闪红
$lastHealth = @{}
while(-not $sync.stop){
  $executedCmd = (Invoke-PendingCommands) -gt 0  # 本轮是否执行过命令：影响轮询间隔，见循环尾
  # 拷快照（加锁，避免枚举期间 UI 侧增删）
  [Threading.Monitor]::Enter($sync.gate)
  try { $snap = @($sync.svc.Keys) } finally { [Threading.Monitor]::Exit($sync.gate) }

  # 批量查询（发现 7）：一次 Get-Service 拿全部。任一名字不存在会整批抛 ObjectNotFound，
  # 故 catch 退回逐个查询，在那里区分「未安装」与「未知」。
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

  # 并行探测运行中服务：每服务一块，TCP→HTTP 串行，服务间并行；$using:http 传 HttpClient。
  # 中间态期间按 ProbeIntervalMs 限流 TCP+HTTP，但状态不能跟着慢——被跳过的那轮仍按上次健康值入队。
  # 用 TickCount64 而非墙钟：NTP 校正/休眠恢复让墙钟回拨时，差值为负会让探测一直「还没到点」。
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
      # 轻量端口探测。$tcpMs 必须经 $using: 传入——Parallel 开新 runspace 不继承父变量，
      # 裸用取到 $null，WaitOne(0) 立刻返回 False，运行中服务被误判「无响应」变红。
      $listen=$false
      $tcp=[System.Net.Sockets.TcpClient]::new()
      try {
        $iar=$tcp.BeginConnect('127.0.0.1',$p,$null,$null)
        if($iar.AsyncWaitHandle.WaitOne($tcpMsLocal,$false)){ try{$tcp.EndConnect($iar);$listen=$true}catch{} }
      } finally { try{$tcp.Close()}catch{} }

      if(-not $listen){ return [pscustomobject]@{n=$n;h='无响应'} }
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
    foreach($r in $results){ $lastHealth[$r.n]=$r.h; $sync.queue.Enqueue([pscustomobject]@{n=$r.n;st='运行中';h=$r.h}) }
  }

  if ((Invoke-PendingCommands) -gt 0) { $executedCmd = $true }
  # 有运行中服务按 ProbeIntervalMs；全停止拉长到 ProbeIdleMs（省空转唤醒与整轮扫描）。
  # 「本轮执行过命令」也算活跃：刚下发启动命令时 $toProbe 为空，按空闲走 15s 会让卡片停在「启动中」。
  # 「有服务停在过渡态」同样用短间隔，让翻转 1 秒内可见。
  if (-not $sync.stop) {
    # 中间态用更短间隔；也照常探测运行中的服务（本地回环，代价可忽略）。
    $sleepMs = if ($pendingSeen) { $probePendingMs }
               elseif ($toProbe.Count -or $executedCmd) { $probeIntervalMs }
               else { $probeIdleMs }
    [void]$sync.wake.WaitOne($sleepMs)
  }
}
} finally { $http.Dispose() }
'@
