#requires -Version 7.0
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'lib/poll.ps1')
. (Join-Path $PSScriptRoot 'test-helpers.ps1')

# 接住真实 TCP/HTTP 探测：第一条 TCP 连通性连接没有请求，第二条才有 HTTP 请求。
function Wait-ProbeRequest($listener) {
  $deadline = [datetime]::UtcNow.AddSeconds(4)
  while ([datetime]::UtcNow -lt $deadline) {
    if (-not $listener.Pending()) { Start-Sleep -Milliseconds 10; continue }
    $client = $listener.AcceptTcpClient()
    $buffer = [byte[]]::new(4096)
    $read = $client.GetStream().ReadAsync($buffer, 0, $buffer.Length)
    if ($read.Wait(500) -and $read.Result -gt 0) { return $client }
    $client.Dispose()
  }
  throw 'HTTP probe did not reach the isolated listener.'
}

foreach ($scenario in 'command','headers','shutdown') {
  Write-Output "DIAG: begin $scenario"
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  $listener.Start()
  $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
  $client = $null; $worker = $null
  try {
    $worker = Start-FakePoll 1 'Running' 0 @{
      svc = @{ Fake0 = @{ port=$port; url="http://127.0.0.1:$port/health" } }
      httpTimeoutMs=5000; probeIntervalMs=4000
    } 0 'StartPending'
    $client = Wait-ProbeRequest $listener
    $watch = [Diagnostics.Stopwatch]::StartNew()
    switch ($scenario) {
      'command' {
        $worker.Sync.cmd.Enqueue([pscustomobject]@{n='Fake0';act='start';e=101})
        [void]$worker.Sync.wake.Set()
        $ack = Wait-FakePollAck $worker 1
        Assert ($null -ne $ack -and $ack.ok) 'Slow HTTP probe blocked the start command.'
        Assert ($watch.ElapsedMilliseconds -lt 1000) "Command waited $($watch.ElapsedMilliseconds)ms behind HTTP."
        Write-Output "PASS: command interrupts a 5000ms HTTP probe ($($watch.ElapsedMilliseconds)ms)."
      }
      'headers' {
        $head = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 10`r`nConnection: close`r`n`r`n")
        $client.GetStream().Write($head,0,$head.Length)
        $healthy = $null
        while ($watch.ElapsedMilliseconds -lt 1000 -and -not $healthy) {
          $item = $null
          while ($worker.Sync.queue.TryDequeue([ref]$item)) {
            if ($item.n -eq 'Fake0' -and $item.h -eq '正常') { $healthy = $item }
          }
          if (-not $healthy) { Start-Sleep -Milliseconds 10 }
        }
        Assert ($null -ne $healthy) 'A 200 response waited for an unused, delayed body.'
        Write-Output "PASS: HTTP 200 headers determine health without waiting for body ($($watch.ElapsedMilliseconds)ms)."
      }
      'shutdown' {
        $worker.Sync.stop = $true; [void]$worker.Sync.wake.Set()
        Assert ($worker.Handle.AsyncWaitHandle.WaitOne(1000)) 'Shutdown waited for the 5000ms HTTP timeout.'
        [void]$worker.PowerShell.EndInvoke($worker.Handle)
        $inspection = [powershell]::Create().AddScript('@(Get-Job).Count')
        $inspection.Runspace = $worker.Runspace
        try { Assert ($inspection.Invoke()[0] -eq 0) 'Probe job remained after shutdown.' }
        finally { $inspection.Dispose() }
        Write-Output "PASS: shutdown cancels HTTP and removes the probe job ($($watch.ElapsedMilliseconds)ms)."
      }
    }
    # 只读 Count：枚举 Streams.Error 会阻塞到管线完成（PSDataCollection 的枚举器等 Complete），
    # worker 还在跑时 -join 会挂住整个测试。
    Assert ($worker.PowerShell.Streams.Error.Count -eq 0) 'Worker reported errors.'
  } finally {
    Write-Output "DIAG: close worker $scenario"
    if ($worker) { Close-FakePoll $worker }
    Write-Output "DIAG: close listener $scenario"
    if ($client) { $client.Dispose() }
    $listener.Stop()
  }
}

foreach ($state in 'Stopped','Running') {
  $worker = Start-FakePoll 1 $state 0 @{
    svc = @{ Fake0 = @{ port=0;url='';probe='none' } }
    probeIntervalMs=1111;probeIdleMs=8000
  }
  try {
    $deadline = [datetime]::UtcNow.AddSeconds(2)
    while (-not $worker.Sync.sampleIntervalMs -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 10 }
    $expected = if ($state -eq 'Running') { 1111 } else { 8000 }
    Assert ($worker.Sync.sampleIntervalMs -eq $expected) "$state sample interval should be ${expected}ms, got $($worker.Sync.sampleIntervalMs)."
    Write-Output "PASS: $state probe=none publishes the actual ${expected}ms sample interval."
  } finally { Close-FakePoll $worker }
}

# 中间态 + 运行中并存：陈旧基准必须跟随健康探测节奏（ProbeIntervalMs），不能取 1s 的中间态轮询间隔。
# 否则每 4s 周期里有 1–2s 其它运行中卡片会被判「状态未知」，批量命令也会把目标当过期跳过。
$worker = Start-FakePoll 2 'Stopped' 0 @{
  svc = @{ Fake0 = @{ port=0;url='';probe='none' }; Fake1 = @{ port=0;url='';probe='none' } }
  probeIntervalMs=4000;probeIdleMs=8000;probePendingMs=1000
} 0 -statusMap @{ Fake0='Running'; Fake1='StartPending' }
try {
  $deadline = [datetime]::UtcNow.AddSeconds(2)
  while (-not $worker.Sync.sampleIntervalMs -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 10 }
  Assert ($worker.Sync.sampleIntervalMs -eq 4000) "Pending + running must publish the 4000ms health cadence, got $($worker.Sync.sampleIntervalMs)."
  Write-Output 'PASS: pending round keeps the health-probe interval instead of the 1000ms pending cadence.'
} finally { Close-FakePoll $worker }
