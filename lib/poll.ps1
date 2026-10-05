# lib/poll.ps1 — 后台探测与命令执行；命令可唤醒空闲等待，在每次服务探测之间优先处理
# UI 线程绝不碰 I/O；结果经 ConcurrentQueue 回 UI 侧 DispatcherTimer 取
#
# 内存优化（vs 初版）：
# - 端口探测用 System.Net.Sockets.TcpClient（200ms 超时），不用 Get-NetTCPConnection
#   （后者拉 NetTCPIP CIM provider，常驻 +10MB）
# - HTTP 探测用单个共享 HttpClient，不用 Invoke-WebRequest（IWR 每次 new+dispose 一个
#   HttpClient，且加载整个 Microsoft.PowerShell.Commands.Utility HTTP cmdlet 机器）
# - 结果仍是字符串，runsapce 不持有 UI 对象

# 后台探测脚本块（字符串，在 runspace 里执行）
# Wait-Stopped 抽到 lib/svc-common.ps1，与 add-svc.ps1（UI 线程）引用同一份实现。
# runspace 不能 dot-source 外部文件（脚本块字符串里没有 $PSScriptRoot），构造时把 svc-common.ps1
# 的文本前置进 $script:poll——UI 线程与后台引用的是同一份源码，原「SYNC: 两处同改」注释消除。
$script:poll = (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'svc-common.ps1')) + @'
# runspace 内构造一次、复用到退出——HttpClient 本身线程安全
$http = [System.Net.Http.HttpClient]::new()
# 超时从 $sync 读（由 UI 线程从 config.ps1 注入）；测试夹具未设时回落默认（200/3000/6000）。
# 生效值写回 $sync 同一键：UI 侧/测试可见 runspace 实际用的是什么（写回即覆盖原注入值）。
$tcpMs  = if ($sync.tcpTimeoutMs)        { [int]$sync.tcpTimeoutMs }        else { 200 }
$httpMs = if ($sync.httpTimeoutMs)       { [int]$sync.httpTimeoutMs }       else { 3000 }
$waitMs = if ($sync.waitStoppedTimeoutMs){ [int]$sync.waitStoppedTimeoutMs } else { 6000 }
# 节奏与并行度也从 $sync 读（UI 线程从 config 注入），测试夹具未设时回落原硬编码值。
$probeIntervalMs = if ($sync.probeIntervalMs) { [int]$sync.probeIntervalMs } else { 4000 }
$probeIdleMs     = if ($sync.probeIdleMs)     { [int]$sync.probeIdleMs }     else { 15000 }
$probeThrottle   = if ($sync.probeThrottleLimit) { [int]$sync.probeThrottleLimit } else { 8 }
$http.Timeout = [TimeSpan]::FromMilliseconds($httpMs)
$sync.tcpTimeoutMs = $tcpMs; $sync.httpTimeoutMs = $httpMs; $sync.waitStoppedTimeoutMs = $waitMs
$sync.probeIntervalMs = $probeIntervalMs; $sync.probeIdleMs = $probeIdleMs
$sync.probeThrottleLimit = $probeThrottle

# sc.exe 不抛异常，只靠 $LASTEXITCODE；包装成 helper，失败时反馈到 UI 状态栏
# 常见退出码映射（发现 9）：1056=已在运行 / 1062=未启动 / 1060=未安装 / 1051=禁止启动
# 5=拒绝访问：非管理员调 sc.exe start <已运行服务> 实测返回 5（不是 1056）——
# 管理员下才返回 1056；两条路径都给中文文案，避免非管理员看到「错误码 5」。
function Convert-ScExitCode([int]$code){
  switch ($code) {
    0      { '' }
    1056   { '已在运行' }
    1062   { '未启动' }
    1060   { '服务未安装' }
    1051   { '禁止启动（禁用或只读）' }
    1053   { '服务进程无法启动' }
    1058   { '服务被禁用' }
    1067   { '进程意外退出' }
    1072   { '服务已被标记为删除' }
    5      { '拒绝访问（可能非管理员）' }
    default { "错误码 $code" }
  }
}
# ServiceController.Status → 中文状态（单一映射源，避免兜底分支缩水版漂移）
function Convert-ServiceStatus([string]$s){
  switch ($s) {
    'Stopped'      { '已停止' }
    'StartPending'  { '启动中' }
    'StopPending'   { '停止中' }
    'Running'       { '运行中' }
    default         { '未知' }
  }
}
function Invoke-Sc([string]$verb,[string]$n,[string]$fail){
  sc.exe $verb $n 2>&1 | Out-Null
  if($LASTEXITCODE -ne 0){
    $reason = Convert-ScExitCode $LASTEXITCODE
    $sync.msg.Enqueue("$n $fail($LASTEXITCODE $reason)")
    return $false
  }
  $true
}

# ServiceController.Start() 是异步的（不等 RUNNING）；sc.exe start 走 SCM 同步管道（默认 30s 超时），
# 慢启动服务会占死后台命令队列与卡片按钮（按钮要等 ack 才解封）。改用 ServiceController 让启动
# 立即返回，状态由下一轮探测自然落到运行中。
# 两个不能照搬报告原片的坑（已验，见 docs/HANDOFF.md P0-2）：
# 1. ServiceController.Status 对不存在的服务返回空串（不抛异常）——先判空走 sc.exe 取「未安装」错码，
#    否则空串会落到 Start() 抛 'Cannot open ... service'，文案退化。
# 2. Start() 对已运行/无权限抛 MethodInvocationException，内层是英文包壳——直接吐不如落回 sc.exe
#    取退出码经 Convert-ScExitCode 出中文文案友好。
# 失败路径仍付一次 sc.exe（~90ms），但只在异常时触发；正常慢启动走 Start() 立即返回。
# ServiceController 是 IDisposable（持有 SCM 句柄）；用 try/finally 保证释放，不靠 GC。
function Invoke-ServiceStart([string]$n,[string]$fail='启动失败'){
  $svc = $null
  try {
    $svc = [System.ServiceProcess.ServiceController]::new($n)
    $status = [string]$svc.Status
    if ([string]::IsNullOrEmpty($status)) { return (Invoke-Sc 'start' $n $fail) }
    if ($status -eq 'Running') { return $true }   # 等价 sc.exe 1056
    $svc.Start()                                  # 立即返回，不等 RUNNING
    return $true
  } catch {
    return (Invoke-Sc 'start' $n $fail)           # 取退出码文案，比内层英文异常友好
  } finally {
    if ($svc) { try { $svc.Dispose() } catch {} }
  }
}

function Invoke-PendingCommands {
  # 执行命令队列（启停与删除全在后台线程，避免 UI 线程同步等待 stop/remove 冻结界面）
  $item=$null
  while(-not $sync.stop -and $sync.cmd.TryDequeue([ref]$item)){
    $n=[string]$item.n; $act=[string]$item.act; $e=$item.e
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
        # 删除走后台：stop → Wait-Stopped ≤6s → nssm remove confirm → 回执带 done=remove
        # UI 侧（Show-Remove 的 del_Click）入队后立即关弹窗，结果由 ack 回执处理。
        # $nssm 在 runspace 里不可见——NSSM 路径经 $sync.nssm 从 UI 传入。
        $ok=$true
        try {
          sc.exe stop $n 2>&1 | Out-Null
          [void](Wait-Stopped $n)
          $o=& $sync.nssm remove $n confirm 2>&1
          if($LASTEXITCODE -ne 0){ $sync.msg.Enqueue("$n 删除失败($LASTEXITCODE)"); $ok=$false }
        } catch { $sync.msg.Enqueue("$n 删除失败: $($_.Exception.Message)"); $ok=$false }
      }
    }
    if ($null -eq $ok) { $ok=$true }  # 兜底：未知 act 不该出现，出现也当成功收尾
    if ($ok) {
      # 命令完成回执：把同一命令纪元带回 UI。ack 分支据此解封按钮/冷却或处理删除收尾。
      $sync.queue.Enqueue([pscustomobject]@{n=$n;st=$null;h=$null;e=$e;done=$true;act=$act})
    }
  }
}

try {
while(-not $sync.stop){
  Invoke-PendingCommands
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
  foreach($n in $snap){
    Invoke-PendingCommands
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
      $toProbe.Add([pscustomobject]@{n=$n;port=[int]$info.port;url=[string]$info.url})
    } else {
      $sync.queue.Enqueue([pscustomobject]@{n=$n;st=$st;h=''})
    }
  }

  # 并行探测运行中服务：每个服务一个并行块，内部 TCP→HTTP 串行，服务间并行。
  # $using:http 传 HttpClient 引用（线程安全）；结果按输入顺序返回，统一入队。
  if ($toProbe.Count -and -not $sync.stop) {
    $results = $toProbe | ForEach-Object -Parallel {
      $n=$_.n; $p=$_.port; $url=$_.url
      $httpClient=$using:http
      # 轻量端口探测：TcpClient $tcpMs 超时（不用 Get-NetTCPConnection）
      # $tcpMs 必须经 $using: 传入——ForEach-Object -Parallel 开新 runspace，
      # 不继承父作用域变量；裸用 $tcpMs 在此取到 $null，WaitOne(0) 立刻返回 False，
      # 运行中服务被误判「无响应」变红（启停时 runspace 更忙，0ms 扑空概率上升）。
      $listen=$false
      $tcp=[System.Net.Sockets.TcpClient]::new()
      try {
        $iar=$tcp.BeginConnect('127.0.0.1',$p,$null,$null)
        if($iar.AsyncWaitHandle.WaitOne($using:tcpMs,$false)){ try{$tcp.EndConnect($iar);$listen=$true}catch{} }
      } finally { try{$tcp.Close()}catch{} }

      if(-not $listen){ return [pscustomobject]@{n=$n;h='无响应'} }
      # HTTP 探测：共享 HttpClient，3s 超时（本地面板冷启动宽限）
      # 响应必须 Dispose，否则内容缓冲滞留——每轮探测泄漏一份。
      try {
        $r=$httpClient.GetAsync($url).GetAwaiter().GetResult()
        try { $h=if($r.StatusCode -eq [System.Net.HttpStatusCode]::OK){'正常'}else{'HTTP '+[int]$r.StatusCode} } finally { $r.Dispose() }
      } catch {
        # 异常归类：refused/connection 类 → 无响应，其余（含超时、DNS 失败等）→ 超时。
        # 原 timeout 正则与 else 同归 '超时'，是死分支——此处折叠。
        $ex=$_.Exception.InnerException; if(-not $ex){$ex=$_.Exception}
        $msg=[string]$ex.Message
        $h=if($msg -match 'refused|unable to connect|连接|connection|ConnectFailure'){'无响应'}else{'超时'}
      }
      [pscustomobject]@{n=$n;h=$h}
    } -ThrottleLimit $probeThrottle
    foreach($r in $results){ $sync.queue.Enqueue([pscustomobject]@{n=$r.n;st='运行中';h=$r.h}) }
  }

  Invoke-PendingCommands
  # 有运行中服务按 ProbeIntervalMs 轮询；全停止时拉长到 ProbeIdleMs——省下空转的
  # 唤醒与整轮 Get-Service/TCP 扫描（服务数为 0 时 $toProbe 为空，整轮只做一次快照）。
  if (-not $sync.stop) {
    $sleepMs = if ($toProbe.Count) { $probeIntervalMs } else { $probeIdleMs }
    [void]$sync.wake.WaitOne($sleepMs)
  }
}
} finally { $http.Dispose() }
'@
