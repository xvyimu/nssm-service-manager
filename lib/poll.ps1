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
$script:poll = @'
# runspace 内构造一次、复用到退出——HttpClient 本身线程安全
$http = [System.Net.Http.HttpClient]::new()
$http.Timeout = [TimeSpan]::FromMilliseconds(3000)

# sc.exe 不抛异常，只靠 $LASTEXITCODE；包装成 helper，失败时反馈到 UI 状态栏
# 常见退出码映射（发现 9）：1056=已在运行 / 1062=未启动 / 1060=未安装 / 1051=禁止启动
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

# 轮询服务到 Stopped（最多 6s）避免端口未释放；与 add-svc.ps1 的 Wait-Stopped 同构
function Wait-Stopped([string]$n,[int]$timeoutMs=6000){
  $w=0
  while($w -lt $timeoutMs){
    try { $s=Get-Service -Name $n -EA Stop; if([string]$s.Status -eq 'Stopped'){return $true} } catch { return $true }
    Start-Sleep -Milliseconds 300; $w+=300
  }
  $false
}

function Invoke-PendingCommands {
  # 执行命令队列（启停全在后台线程）
  $item=$null
  while(-not $sync.stop -and $sync.cmd.TryDequeue([ref]$item)){
    $n=[string]$item.n; $act=[string]$item.act
    switch($act){
      'start'   { Invoke-Sc 'start' $n '启动失败' }
      'stop'    { Invoke-Sc 'stop' $n '停止失败' }
      'restart' {
        if(-not (Invoke-Sc 'stop' $n '停止失败，重启中断')) { break }
        [void](Wait-Stopped $n)
        Start-Sleep -Milliseconds 500  # 端口 TIME_WAIT 余量
        Invoke-Sc 'start' $n '重启后启动失败'
      }
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
  # 缺失的服务（未安装）会被 Get-Service 抛 ObjectNotFound，下面逐个兜底。
  $svcStatus = @{}
  if ($snap.Count) {
    try {
      $found = Get-Service -Name $snap -EA Stop
      # Get-Service 可能返回单个对象或数组；统一成数组再按 Name 索引
      $foundList = @($found)
      foreach ($s in $foundList) { $svcStatus[$s.Name] = [string]$s.Status }
      # 批量查询漏掉的服务（未安装）单独兜底
      foreach ($n in $snap) {
        if (-not $svcStatus.ContainsKey($n)) { $svcStatus[$n] = $null }
      }
    } catch {
      # 整批失败（极少见）：退回逐个查询
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
      # 轻量端口探测：TcpClient 200ms 超时（不用 Get-NetTCPConnection）
      $listen=$false
      $tcp=[System.Net.Sockets.TcpClient]::new()
      try {
        $iar=$tcp.BeginConnect('127.0.0.1',$p,$null,$null)
        if($iar.AsyncWaitHandle.WaitOne(200,$false)){ try{$tcp.EndConnect($iar);$listen=$true}catch{} }
      } finally { try{$tcp.Close()}catch{} }

      if(-not $listen){ return [pscustomobject]@{n=$n;h='无响应'} }
      # HTTP 探测：共享 HttpClient，3s 超时（本地面板冷启动宽限）
      # 响应必须 Dispose，否则内容缓冲滞留——每轮探测泄漏一份。
      try {
        $r=$httpClient.GetAsync($url).GetAwaiter().GetResult()
        try { $h=if($r.StatusCode -eq [System.Net.HttpStatusCode]::OK){'正常'}else{'HTTP '+[int]$r.StatusCode} } finally { $r.Dispose() }
      } catch {
        $ex=$_.Exception.InnerException; if(-not $ex){$ex=$_.Exception}
        $msg=[string]$ex.Message
        if($msg -match 'timed out|超时|Timeout|canceled|任务已取消'){$h='超时'}
        elseif($msg -match 'refused|unable to connect|连接|connection|ConnectFailure'){$h='无响应'}
        else{$h='超时'}
      }
      [pscustomobject]@{n=$n;h=$h}
    } -ThrottleLimit 8
    foreach($r in $results){ $sync.queue.Enqueue([pscustomobject]@{n=$r.n;st='运行中';h=$r.h}) }
  }

  Invoke-PendingCommands
  if (-not $sync.stop) { [void]$sync.wake.WaitOne(4000) }
}
} finally { $http.Dispose() }
'@
