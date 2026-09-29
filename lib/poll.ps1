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
function Invoke-Sc([string]$verb,[string]$n,[string]$fail){
  sc.exe $verb $n 2>&1 | Out-Null
  if($LASTEXITCODE -ne 0){ $sync.msg.Enqueue("$n $fail($LASTEXITCODE)"); return $false }
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

  foreach($n in $snap){
    Invoke-PendingCommands
    if ($sync.stop) { break }
    [Threading.Monitor]::Enter($sync.gate)
    try { $info = $sync.svc[$n] } finally { [Threading.Monitor]::Exit($sync.gate) }
    if (-not $info) { continue }

    try {
      $s = Get-Service -Name $n -EA Stop
      $st = switch([string]$s.Status){ 'Stopped'{'已停止'} 'StartPending'{'启动中'} 'StopPending'{'停止中'} 'Running'{'运行中'} default{'未知'} }
    } catch {
      if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { $st='未安装' } else { $st='未知' }
    }

    $h=''
    if($st -eq '运行中'){
      $p = [int]$info.port
      # 轻量端口探测：TcpClient 200ms 超时（不用 Get-NetTCPConnection）
      $listen = $false
      $tcp = [System.Net.Sockets.TcpClient]::new()
      try {
        $iar = $tcp.BeginConnect('127.0.0.1', $p, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(200, $false)) {
          try { $tcp.EndConnect($iar); $listen = $true } catch {}
        }
      } finally { try { $tcp.Close() } catch {} }

      if (-not $listen) {
        $h='无响应'
      } else {
        # HTTP 探测：共享 HttpClient，3s 超时（本地面板冷启动宽限）
        # 响应必须 Dispose，否则内容缓冲滞留——每轮探测泄漏一份。
        # 用 .GetAwaiter().GetResult() 而非 .Result：后者抛 AggregateException
        # （.Message = "One or more errors occurred." 无信息量），前者直接抛内层异常。
        # PowerShell 再包一层 MethodInvocationException，真实异常在 .InnerException。
        try {
          $r = $http.GetAsync($info.url).GetAwaiter().GetResult()
          try { $h = if($r.StatusCode -eq [System.Net.HttpStatusCode]::OK){'正常'}else{'HTTP ' + [int]$r.StatusCode} } finally { $r.Dispose() }
        } catch {
          $ex = $_.Exception.InnerException
          if (-not $ex) { $ex = $_.Exception }
          $msg = [string]$ex.Message
          if ($msg -match 'timed out|超时|Timeout|canceled|任务已取消') { $h='超时' }
          elseif ($msg -match 'refused|unable to connect|连接|connection|ConnectFailure') { $h='无响应' }
          else { $h='超时' }
        }
      }
    }
    $sync.queue.Enqueue([pscustomobject]@{n=$n;st=$st;h=$h})
  }

  Invoke-PendingCommands
  if (-not $sync.stop) { [void]$sync.wake.WaitOne(4000) }
}
} finally { $http.Dispose() }
'@
