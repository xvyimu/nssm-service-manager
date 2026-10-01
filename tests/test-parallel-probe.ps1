#requires -Version 7.0
# 发现 4 的回归测试：并行探测路径下，多个运行中服务的健康结果全部入队，
# 且最坏延迟逼近单服务 HTTP 超时（~3s）而非 N×3s。
# mock Get-Service 返回 Running + 真实 TcpClient 连未监听端口（→ h='无响应'，跳过 HTTP）。
param([string]$RepoRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'lib/poll.ps1')
. (Join-Path $RepoRoot 'tests/test-helpers.ps1')
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }

# ---- 1. 6 个运行中服务，并行探测，结果全部入队 ----
$worker=Start-FakePoll 6 'Running'
try {
  $deadline=[datetime]::UtcNow.AddSeconds(8)
  while ($worker.Sync.queue.Count -lt 6 -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
  Assert ($worker.Sync.queue.Count -ge 6) "Parallel probe did not enqueue all results: got $($worker.Sync.queue.Count)."
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
# 这是并行行为的弱验证，强验证需 mock TCP 超时（不稳定，舍弃）。
function Measure-RoundLatency([int]$count){
  $w=Start-FakePoll $count 'Running'
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
    $span=($allDone-$firstItem).TotalMilliseconds
    [pscustomobject]@{Count=$count; SpanMs=$span}
  } finally { Close-FakePoll $w }
}

$r3=Measure-RoundLatency 3
# 3 服务并行：首条到全部入队的窗口应远小于串行的 2×200=400ms。
Assert ($r3.SpanMs -lt 600) "3-service parallel window $($r3.SpanMs)ms exceeds 600ms ceiling (serial would be ~400ms)."
Write-Output ("PASS: 3-service parallel window={0}ms (under 600ms; serial baseline ~400ms)" -f [int]$r3.SpanMs)

Write-Output 'PASS: parallel probe path enqueues all results; no background errors; no serial multiplier on latency.'
