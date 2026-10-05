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

# ---- 启动命令遇 StartPending：应视作已在启动，不调 sc.exe、不产生失败消息 ----
# 修前：StartPending 落到 $svc.Start() 抛 MethodInvocationException，回落 sc.exe 取回
# 1056 → 状态栏出现「启动失败(1056 已在运行)」这种自相矛盾的文案。
# 触发路径真实：card.ps1 右键菜单的「启动」直接 Send-ServiceCommand，不经 ST 门闩。
# 替身 ServiceController 经 $sync.newSc 注入（runspace 里无法替身化 .NET 构造函数）。
$worker=Start-FakePoll 1 'Stopped' 0 $null 0 'StartPending'
try {
  Assert ($worker.Sync.probeStarted.WaitOne(3000)) 'Worker did not start.'
  $worker.Sync.cmd.Enqueue([pscustomobject]@{n='Fake0';act='start';e=11})
  [void]$worker.Sync.wake.Set()
  # 等回执（done=$true）
  $ack=$null
  $deadline=[datetime]::UtcNow.AddSeconds(4)
  while (-not $ack -and [datetime]::UtcNow -lt $deadline) {
    $x=$null
    while ($worker.Sync.queue.TryDequeue([ref]$x)) { if ($x.done) { $ack=$x; break } }
    if (-not $ack) { Start-Sleep -Milliseconds 20 }
  }
  Assert ($null -ne $ack) 'Start command against StartPending produced no ack.'
  Assert ($ack.ok -eq $true) "StartPending should be treated as already starting (ok=true), got ok=$($ack.ok)."
  # 不得调用 sc.exe：$sync.executed 里不该有 start 记录
  $calls=@($worker.Sync.executed | ForEach-Object { $_.action })
  Assert ($calls -notcontains 'start') "StartPending fell through to sc.exe start: $($calls -join ',')."
  # 不得产生失败消息
  $msgs=@($worker.Sync.msg.ToArray())
  Assert ($msgs.Count -eq 0) "StartPending produced failure message(s): $($msgs -join ' | ')."
  Write-Output 'PASS: StartPending treated as already-starting (no sc.exe, no failure message, ok=true).'
} finally { Close-FakePoll $worker }

# ---- 全停止但刚下发命令：那一轮之后的睡眠必须用短间隔，不能走空闲长睡眠 ----
# 修前：$sleepMs 只按「本轮有无运行中服务」判，1 个 Stopped 服务时 $toProbe 为空，
# 走 ProbeIdleMs——卡片停在「启动中」最长约 15 秒才收到第一份探测结果。
# 这里直接量行为（不依赖任何新字段）：probeIntervalMs=300 / probeIdleMs=60000，
# 下发命令后量「下一个探测周期」到达的耗时。修前要等满 60s，5s 超时即红。
$worker=Start-FakePoll 1 'Stopped' 0 @{ probeIntervalMs = 300; probeIdleMs = 60000 }
try {
  Assert ($worker.Sync.probeStarted.WaitOne(3000)) 'Worker did not start.'
  Start-Sleep -Milliseconds 300   # 让后台进入空闲长睡眠（首轮无命令、无可探测服务）
  $base=$worker.Sync.probeCount
  # 下发 stop（sc.exe 替身必然返回 0，不碰真实 ServiceController），唤醒后台
  $worker.Sync.cmd.Enqueue([pscustomobject]@{n='Fake0';act='stop';e=21})
  [void]$worker.Sync.wake.Set()
  # 等命令所在周期结束（该周期末尾会做一次批量 Get-Service → 计数 +1）
  $deadline=[datetime]::UtcNow.AddSeconds(5)
  while ($worker.Sync.probeCount -le $base -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
  Assert ($worker.Sync.probeCount -gt $base) 'Worker did not run the command cycle.'
  # 量「下一个周期」的到达耗时——中间隔着那次睡眠，是 $sleepMs 的直接观测量
  $t0=[datetime]::UtcNow; $p1=$worker.Sync.probeCount
  while ($worker.Sync.probeCount -le $p1 -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
  $elapsed=([datetime]::UtcNow-$t0).TotalMilliseconds
  Assert ($worker.Sync.probeCount -gt $p1) 'Next probe cycle never arrived within 5s — slept ProbeIdleMs instead of ProbeIntervalMs.'
  Assert ($elapsed -lt 3000) "Sleep after an in-flight command was ${elapsed}ms; expected ~ProbeIntervalMs=300ms."
  Write-Output "PASS: an executed command keeps the next sleep at ProbeIntervalMs (next cycle after ${elapsed}ms)."
} finally { Close-FakePoll $worker }

Write-Output 'PASS: wakeup, priority between probes, FIFO, and idle shutdown; no real services or network used.'
