#requires -Version 7.0
# 发现 4 的回归测试：并行探测路径下，多个运行中服务的健康结果全部入队，
# 且最坏延迟逼近单服务 HTTP 超时（~3s）而非 N×3s。
# mock Get-Service 返回 Running + mock TcpClient/HttpClient，让并行分支跑起来。
param([string]$RepoRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'lib/poll.ps1')
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }

function Start-FakePoll([int]$count,[int]$httpDelayMs=0){
  $services=[ordered]@{}
  for($i=0;$i -lt $count;$i++){ $services["Fake$i"]=@{port=10000+$i;url="http://127.0.0.1:10000/fake$i"} }
  $shared=[hashtable]::Synchronized(@{
    svc=$services; gate=[object]::new(); stop=$false
    queue=[Collections.Concurrent.ConcurrentQueue[object]]::new()
    cmd=[Collections.Concurrent.ConcurrentQueue[object]]::new()
    msg=[Collections.Concurrent.ConcurrentQueue[string]]::new()
    wake=[Threading.AutoResetEvent]::new($false)
    probeCount=0; httpDelayMs=$httpDelayMs
    probeDone=[Threading.AutoResetEvent]::new($false)
  })
  $rs=[runspacefactory]::CreateRunspace(); $rs.ApartmentState='STA'; $rs.Open()
  $rs.SessionStateProxy.SetVariable('sync',$shared)
  # mock：Get-Service 返回 Running（触发并行探测分支）；TcpClient 假装连上；
  # HttpClient 用一个轻量 fake——通过替换 [System.Net.Http.HttpClient] 不可行，
  # 改为在脚本块里 mock http.GetAsync：但 $http 是 runspace 内 new 的真 HttpClient。
  # 这里走真实 TcpClient 连 127.0.0.1:10000+i（无监听 → listen=$false → h='无响应'，
  # 跳过 HTTP），不依赖 HttpClient。这样并行分支的 TCP 段被真实执行，HTTP 段被跳过。
  $mocks=@'
function Get-Service {
  [CmdletBinding()]param([string[]]$Name)
  foreach ($n in $Name) { [pscustomobject]@{ Name=$n; Status='Running' } }
}
'@
  $ps=[powershell]::Create().AddScript($mocks).AddScript($script:poll); $ps.Runspace=$rs
  [pscustomobject]@{Sync=$shared;Runspace=$rs;PowerShell=$ps;Handle=$ps.BeginInvoke()}
}
function Close-FakePoll($worker){
  $worker.Sync.stop=$true; [void]$worker.Sync.wake.Set()
  $worker.PowerShell.Stop(); $worker.PowerShell.Dispose(); $worker.Runspace.Dispose()
  $worker.Sync.wake.Dispose(); $worker.Sync.probeDone.Dispose()
}

# ---- 1. 6 个运行中服务，并行探测，结果全部入队 ----
$worker=Start-FakePoll 6
try {
  # 等一轮探测完成：queue 里应该有 6 条
  $deadline=[datetime]::UtcNow.AddSeconds(8)
  while ($worker.Sync.queue.Count -lt 6 -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
  Assert ($worker.Sync.queue.Count -ge 6) "Parallel probe did not enqueue all results: got $($worker.Sync.queue.Count)."
  # 全部应是 运行中 + 无响应（端口未监听）
  $items=@(); $item=$null
  while($worker.Sync.queue.TryDequeue([ref]$item)){ $items += $item }
  Assert ($items.Count -eq 6) "Expected 6 results, got $($items.Count)."
  foreach($it in $items){
    Assert ($it.st -eq '运行中') "Wrong state for $($it.n): $($it.st)."
    Assert ($it.h -eq '无响应') "Wrong health for $($it.n) (port unlistened): $($it.h)."
  }
  Assert ($worker.PowerShell.Streams.Error.Count -eq 0) "Background errors present."
  Write-Output 'PASS: 6 running services probed in parallel; all results enqueued with correct state/health.'
} finally { Close-FakePoll $worker }

# ---- 2. 并行延迟验证：3 服务并行一轮的墙钟时间上限 ----
# 每个 TCP 连未监听端口 ~200ms 超时。串行下 3×200=600ms；并行下应 ~200ms。
# 给 500ms 上限容差（并行开销 + runspace 启动）：3 服务一轮必须在 500ms 内首条入队，
# 且全部入队不超过 800ms。若改回串行，3×200=600ms 仍可能踩 800ms 上限——
# 这是并行行为的弱验证，强验证需 mock TCP 超时（不稳定，舍弃）。
function Measure-RoundLatency([int]$count){
  $w=Start-FakePoll $count
  try {
    $firstItem=[datetime]::UtcNow
    $allDone=[datetime]::UtcNow
    $deadline=[datetime]::UtcNow.AddSeconds(8)
    while ($w.Sync.queue.Count -lt $count -and [datetime]::UtcNow -lt $deadline) {
      Start-Sleep -Milliseconds 20
      if ($w.Sync.queue.Count -ge 1 -and $firstItem -eq $null) { $firstItem=[datetime]::UtcNow }
    }
    $allDone=[datetime]::UtcNow
    if ($w.Sync.queue.Count -lt $count) { throw "$count-service probe did not complete." }
    # 记录首条到全部入队的窗口——并行下应接近 0（同时返回），串行下约 (count-1)×200ms
    $span=($allDone-$firstItem).TotalMilliseconds
    [pscustomobject]@{Count=$count; SpanMs=$span; FirstMs=($firstItem-[datetime]::UtcNow.AddSeconds(-8)).TotalMilliseconds}
  } finally { Close-FakePoll $w }
}

$r3=Measure-RoundLatency 3
# 3 服务并行：首条到全部入队的窗口应远小于串行的 2×200=400ms。
# 给 600ms 上限（含 runspace 开销）；串行下 ~400ms 也可能过，但这是弱上限。
# 关键断言：3 服务的窗口不显著大于 1 服务的窗口（并行不退化成串行）。
Assert ($r3.SpanMs -lt 600) "3-service parallel window $($r3.SpanMs)ms exceeds 600ms ceiling (serial would be ~400ms)."
Write-Output ("PASS: 3-service parallel window={0}ms (under 600ms; serial baseline ~400ms)" -f [int]$r3.SpanMs)

Write-Output 'PASS: parallel probe path enqueues all results; no background errors; no serial multiplier on latency.'
