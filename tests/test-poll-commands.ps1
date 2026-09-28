#requires -Version 7.0
param([string]$RepoRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'lib/poll.ps1')
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }
function Start-FakePoll([int]$count,[int]$delayMs=0) {
  $services=[ordered]@{}
  for ($i=0;$i -lt $count;$i++) { $services["Fake$i"]=@{port=1;url='http://127.0.0.1:1'} }
  $shared=[hashtable]::Synchronized(@{
    svc=$services; gate=[object]::new(); stop=$false
    queue=[Collections.Concurrent.ConcurrentQueue[object]]::new()
    cmd=[Collections.Concurrent.ConcurrentQueue[object]]::new()
    msg=[Collections.Concurrent.ConcurrentQueue[string]]::new()
    wake=[Threading.AutoResetEvent]::new($false)
    executed=[Collections.Concurrent.ConcurrentQueue[object]]::new()
    executedReady=[Threading.AutoResetEvent]::new($false)
    probeStarted=[Threading.AutoResetEvent]::new($false)
    probeCount=0; delayMs=$delayMs
  })
  $rs=[runspacefactory]::CreateRunspace(); $rs.Open(); $rs.SessionStateProxy.SetVariable('sync',$shared)
  # Only service query/command boundaries are mocked. Stopped services skip all network I/O.
  $mocks=@'
function Get-Service {
  [CmdletBinding()]param([string]$Name)
  $sync.probeCount++
  [void]$sync.probeStarted.Set()
  if ($sync.delayMs) { Start-Sleep -Milliseconds $sync.delayMs }
  [pscustomobject]@{Status='Stopped'}
}
function sc.exe {
  $sync.executed.Enqueue([pscustomobject]@{action=$args[0];name=$args[1];probes=$sync.probeCount})
  [void]$sync.executedReady.Set()
  $global:LASTEXITCODE=0
}
'@
  $ps=[powershell]::Create().AddScript($mocks).AddScript($script:poll); $ps.Runspace=$rs
  [pscustomobject]@{Sync=$shared;Runspace=$rs;PowerShell=$ps;Handle=$ps.BeginInvoke()}
}
function Close-FakePoll($worker) {
  $worker.Sync.stop=$true; [void]$worker.Sync.wake.Set()
  $worker.PowerShell.Stop(); $worker.PowerShell.Dispose(); $worker.Runspace.Dispose()
  foreach ($name in 'wake','executedReady','probeStarted') { $worker.Sync[$name].Dispose() }
}

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

$worker=Start-FakePoll 6 250
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
} finally { Close-FakePoll $worker }

$worker=Start-FakePoll 0
try {
  Start-Sleep -Milliseconds 150
  $worker.Sync.stop=$true; [void]$worker.Sync.wake.Set()
  Assert ($worker.Handle.AsyncWaitHandle.WaitOne(1500)) 'Shutdown did not wake idle poll.'
  [void]$worker.PowerShell.EndInvoke($worker.Handle)
} finally { Close-FakePoll $worker }
Write-Output 'PASS: wakeup, priority between probes, FIFO, and idle shutdown; no real services or network used.'
