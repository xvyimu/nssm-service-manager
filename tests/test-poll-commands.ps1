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
  # 等回执（done=$true）——过滤掉普通探测结果，见 Wait-FakePollAck 说明
  $ack = Wait-FakePollAck $worker
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

# ---- 慢启动：Start() 抛异常但服务其实在 StartPending → 按成功处理，不回落 sc.exe ----
# 起因（实测）：ComfyUI 冷启动 90s，ServiceController.Start() 会等满 ServicesPipeTimeout(30s)
# 再抛异常，工具回落到 `sc.exe start` —— GUI 进程拉控制台子进程会弹一个黑框，
# 用户看到的就是「点启动约 30 秒后冒出一个黑窗口」。
$worker=Start-FakePoll 1 'StartPending' 0 $null 0 'Stopped'   # 状态报 StartPending，控制器会抛
try {
  Assert ($worker.Sync.probeStarted.WaitOne(3000)) 'Worker did not start.'
  $worker.Sync.cmd.Enqueue([pscustomobject]@{n='Fake0';act='start';e=21})
  [void]$worker.Sync.wake.Set()
  $ack = Wait-FakePollAck $worker
  Assert ($null -ne $ack) '慢启动的 start 命令没有回执。'
  Assert ($ack.ok -eq $true) "服务在 StartPending 时应按启动成功处理，got ok=$($ack.ok)"
  $calls=@($worker.Sync.executed | ForEach-Object { $_.action })
  Assert ($calls -notcontains 'start') "慢启动不该回落 sc.exe start（那会弹控制台窗口）：$($calls -join ',')"
  Write-Output 'PASS: slow start (StartPending after Start() throws) treated as started, no sc.exe fallback.'
} finally { Close-FakePoll $worker }

# ---- 单条命令抛异常：不得终结轮询循环，且必须产出失败回执 ----
# 修前：Invoke-PendingCommands 的 switch 体没有 try/catch（remove 分支有），任何终止性异常
# 都会穿透到主循环，runspace 直接结束——之后探测与命令全部停摆，卡片冻结在最后一帧，
# 而状态栏仍每 4 秒打「状态自动刷新」，看起来是活的。
$worker=Start-FakePoll 1 'Stopped' 0 @{ scExe = 'Invoke-ThrowingSc' }
try {
  Assert ($worker.Sync.probeStarted.WaitOne(3000)) 'Worker did not start.'
  $worker.Sync.cmd.Enqueue([pscustomobject]@{n='Fake0';act='stop';e=31})
  [void]$worker.Sync.wake.Set()
  $ack1 = Wait-FakePollAck $worker
  Assert ($null -ne $ack1) '抛异常的 stop 命令没有产出回执。'
  Assert ($ack1.ok -eq $false) "抛异常应按失败回执，got ok=$($ack1.ok)"
  Assert (-not $worker.Handle.IsCompleted) '单条命令抛异常后后台循环结束了。'
  # 第二条命令仍能执行，证明循环存活
  $worker.Sync.cmd.Enqueue([pscustomobject]@{n='Fake0';act='stop';e=32})
  [void]$worker.Sync.wake.Set()
  $ack2 = Wait-FakePollAck $worker
  Assert ($null -ne $ack2) '异常之后后台不再处理命令（轮询循环已死）。'
  Write-Output 'PASS: 命令抛异常时产出失败回执，轮询循环继续存活。'
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

# ---- 中间态快轮询：有服务停在 StartPending/StopPending 时睡眠换成 ProbePendingMs ----
# 没有这条，卡片上的「启动中」最多 4 秒才翻成「运行中」（用户要的是实时）。
# probePendingMs=300 / 其余间隔 60s：量相邻两个探测周期的间隔，走错分支就要等 60s，5s 即红。
$worker=Start-FakePoll 1 'StartPending' 0 @{ probePendingMs = 300; probeIntervalMs = 60000; probeIdleMs = 60000 }
try {
  Assert ($worker.Sync.probeStarted.WaitOne(3000)) 'Worker did not start.'
  $p0=$worker.Sync.probeCount; $t0=[datetime]::UtcNow
  $deadline=[datetime]::UtcNow.AddSeconds(5)
  while ($worker.Sync.probeCount -le $p0 -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
  $elapsed=([datetime]::UtcNow-$t0).TotalMilliseconds
  Assert ($worker.Sync.probeCount -gt $p0) 'No second cycle within 5s — pending state slept ProbeIntervalMs/ProbeIdleMs.'
  Assert ($elapsed -lt 2500) "Pending-state sleep was ${elapsed}ms; expected ~ProbePendingMs=300ms."
  Write-Output "PASS: StartPending keeps the next cycle at ProbePendingMs (${elapsed}ms)."
} finally { Close-FakePoll $worker }

# ---- 兄弟服务卡在中间态时，运行中服务的状态仍按 ProbePendingMs 送达 ----
# 限流只该推迟 TCP+HTTP，不该推迟「运行中」这件事本身：批量 Get-Service 便宜得很，
# 卡片若跟着探测一起慢 4 秒，就会停在旧状态、两个按钮都不可用。
$worker=Start-FakePoll 2 'Stopped' 0 @{ probePendingMs = 200; probeIntervalMs = 60000; probeIdleMs = 60000 } 0 '' @{ Fake0 = 'Running'; Fake1 = 'StartPending' }
try {
  Assert ($worker.Sync.probeStarted.WaitOne(3000)) 'Worker did not start.'
  Start-Sleep -Milliseconds 1500
  $hits=0; $item=$null
  while ($worker.Sync.queue.TryDequeue([ref]$item)) { if ($item.n -eq 'Fake0' -and $item.st -eq '运行中') { $hits++ } }
  Assert ($hits -ge 3) "运行中状态 1.5s 内只送达 $hits 次——被健康探测限流连累了（应为 ProbePendingMs 级）。"
  Write-Output "PASS: running state still delivered ${hits}x/1.5s while a sibling sits in transition (health probe throttled)."
} finally { Close-FakePoll $worker }

# ---- SCM 状态映射：全取值都有中文，未知值才回落「未知」----
. (Join-Path $RepoRoot 'lib/svc-common.ps1')
$statusMap=@{
  Stopped='已停止'; StartPending='启动中'; Running='运行中'; StopPending='停止中'
  Paused='已暂停'; PausePending='暂停中'; ContinuePending='继续中'
}
foreach ($k in $statusMap.Keys) {
  $got=Convert-ServiceStatus $k
  Assert ($got -eq $statusMap[$k]) "Convert-ServiceStatus '$k' -> '$got', expected '$($statusMap[$k])'."
}
Assert ((Convert-ServiceStatus 'Bogus') -eq '未知') 'Unknown SCM status must fall back to 未知.'

# 退出码映射是用户可见文案（sc.exe 失败时状态栏就显示这个），单列一张真值表守住
$codeMap=@{ 0=''; 1056='已在运行'; 1062='未启动'; 1060='服务未安装'; 1051='禁止启动（禁用或只读）'
            1053='服务进程无法启动'; 1058='服务被禁用'; 1067='进程意外退出'; 1072='服务已被标记为删除'
            5='拒绝访问（可能非管理员）' }
foreach ($k in $codeMap.Keys) {
  $got=Convert-ScExitCode $k
  Assert ($got -eq $codeMap[$k]) "Convert-ScExitCode $k -> '$got', expected '$($codeMap[$k])'."
}
Assert ((Convert-ScExitCode 9999) -eq '错误码 9999') 'Unknown exit code must echo the number.'
Write-Output 'PASS: Convert-ServiceStatus + Convert-ScExitCode full mapping tables; unknown values fall back.'

Write-Output 'PASS: wakeup, priority between probes, FIFO, and idle shutdown; no real services or network used.'
