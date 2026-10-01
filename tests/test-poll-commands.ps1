#requires -Version 7.0
param([string]$RepoRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'lib/poll.ps1')
. (Join-Path $RepoRoot 'tests/test-helpers.ps1')
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }

$worker=Start-FakePoll 1
try {
  Assert ($worker.Sync.probeStarted.WaitOne(3000)) 'Worker did not start.'
  Start-Sleep -Milliseconds 150
  $watch=[Diagnostics.Stopwatch]::StartNew()
  $worker.Sync.cmd.Enqueue([pscustomobject]@{n='Fake0';act='start'})
  [void]$worker.Sync.wake.Set()
  Assert ($worker.Sync.executedReady.WaitOne(5500)) 'Command never executed.'
  $latency=$watch.ElapsedMilliseconds
  Write-Output "Idle command dispatch: ${latency}ms"
  Assert ($latency -lt 1500) 'Idle command waited for the fixed poll sleep.'
} finally { Close-FakePoll $worker }

$worker=Start-FakePoll 6 'Stopped' 250
try {
  Assert ($worker.Sync.probeStarted.WaitOne(3000)) 'Slow probe did not start.'
  $watch=[Diagnostics.Stopwatch]::StartNew()
  foreach ($action in 'start','stop') { $worker.Sync.cmd.Enqueue([pscustomobject]@{n='Fake0';act=$action}) }
  [void]$worker.Sync.wake.Set()
  Assert ($worker.Sync.executedReady.WaitOne(4000)) 'Command blocked behind probes.'
  $first=$null; [void]$worker.Sync.executed.TryDequeue([ref]$first)
  Assert ($first.probes -lt 6) 'Command waited for all six probes.'
  Assert ($first.action -eq 'start') 'Command FIFO order changed.'
  Write-Output "Dispatch during probes: $($watch.ElapsedMilliseconds)ms; completed/entered probes=$($first.probes)"
  $deadline=[datetime]::UtcNow.AddSeconds(2)
  while ($worker.Sync.executed.IsEmpty -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 10 }
  $second=$null; [void]$worker.Sync.executed.TryDequeue([ref]$second)
  Assert ($second.action -eq 'stop') 'Second FIFO command missing.'
  Assert ($worker.PowerShell.Streams.Error.Count -eq 0) 'Background errors present.'
  # 并行化行为覆盖（Spec-c3）：并行探测期间不插 Invoke-PendingCommands，
  # 第二条 stop 的 probes 不应小于第一条 start——说明 stop 没在并行段抢跑。
  Assert ($second.probes -ge $first.probes) "FIFO second command probes ($($second.probes)) < first ($($first.probes)); parallel round boundary not respected."
  Write-Output "FIFO across parallel round: first.probes=$($first.probes) second.probes=$($second.probes)"
} finally { Close-FakePoll $worker }

$worker=Start-FakePoll 0
try {
  Start-Sleep -Milliseconds 150
  $worker.Sync.stop=$true; [void]$worker.Sync.wake.Set()
  Assert ($worker.Handle.AsyncWaitHandle.WaitOne(1500)) 'Shutdown did not wake idle poll.'
  [void]$worker.PowerShell.EndInvoke($worker.Handle)
} finally { Close-FakePoll $worker }
Write-Output 'PASS: wakeup, priority between probes, FIFO, and idle shutdown; no real services or network used.'
