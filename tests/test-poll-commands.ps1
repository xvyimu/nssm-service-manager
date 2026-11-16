#requires -Version 7.0
param([string]$RepoRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'lib/poll.ps1')
. (Join-Path $RepoRoot 'tests/test-helpers.ps1')

$worker=Start-FakePoll 1 'Stopped' 0 @{ probeIdleMs = 8000 }
try {
  Assert ($worker.Sync.probeStarted.WaitOne(3000)) 'Worker did not start.'
  Start-Sleep -Milliseconds 150
  $watch=[Diagnostics.Stopwatch]::StartNew()
  $worker.Sync.cmd.Enqueue([pscustomobject]@{n='Fake0';act='start'})
  [void]$worker.Sync.wake.Set()
  Assert ($worker.Sync.executedReady.WaitOne(5500)) 'Command never executed.'
  $latency=$watch.ElapsedMilliseconds
  Write-Output "Idle command dispatch: ${latency}ms"
  # 判据是「不等到空闲间隔」，不是某个绝对毫秒数：worker 要先跑完一轮探测才会 drain 命令队列，
  # 慢 runner 上光一轮探测就能吃掉 1.5s（CI 实测 1507ms），绝对阈值会误红。
  # 空闲间隔在这里显式注入 8000ms，断言取它的一半——阈值与默认值解耦，改 config 默认不会让这里漂移。
  Assert ($latency -lt 4000) 'Idle command waited for the fixed poll sleep.'
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
  # 并行化行为覆盖（Spec-c3）：并行探测期间不插 Invoke-PendingCommands。
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

# ---- stop 遇到 1062（服务本就已停止）：按成功回执，不把已达成当失败 ----
# 修前：Invoke-Sc 返回非零就 $ok=$false，卡片停在「停止中」直到过渡态超时逃生。
$worker=Start-FakePoll 1 'Stopped' 0 $null 1062
try {
  Assert ($worker.Sync.probeStarted.WaitOne(3000)) 'Worker did not start.'
  $worker.Sync.cmd.Enqueue([pscustomobject]@{n='Fake0';act='stop';e=41})
  [void]$worker.Sync.wake.Set()
  $ack1062 = Wait-FakePollAck $worker
  Assert ($null -ne $ack1062) '1062 的 stop 没有产出回执。'
  Assert ($ack1062.ok) "服务已 Stopped 时 stop 应按成功回执，got ok=$($ack1062.ok) why=$($ack1062.why)"
  Write-Output 'PASS: stop 返回 1062 且状态已是 Stopped 时按成功回执。'
} finally { Close-FakePoll $worker }

# ---- stop 等停超时：回执必须 ok=false 且 why 点明原因 ----
# 卡片靠回执的 why 显示失败原因（状态栏那条只有 5 秒租约）；why 为空时用户只看到「停止中」被回滚。
# 同一段用例顺带守 busy：阻塞期间 UI 侧不能把别的卡片判陈旧。
$worker=Start-FakePoll 1 'Running' 0 @{ waitStoppedTimeoutMs = 1200; waitStoppedPollMs = 20; busy = $false }
try {
  Assert ($worker.Sync.probeStarted.WaitOne(3000)) 'Stop-timeout worker did not start.'
  $worker.Sync.cmd.Enqueue([pscustomobject]@{n='Fake0';act='stop';e=51})
  [void]$worker.Sync.wake.Set()
  $deadline=[datetime]::UtcNow.AddSeconds(5)
  while (-not $worker.Sync.busy -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 10 }
  Assert ($worker.Sync.busy -eq $true) '等停阻塞期间 $sync.busy 必须为 $true（否则别的卡片会被误判陈旧）。'
  $ackStop = Wait-FakePollAck $worker
  Assert ($null -ne $ackStop) '停止超时的 stop 没有产出回执。'
  Assert ($ackStop.ok -eq $false) "停止超时应按失败回执，got ok=$($ackStop.ok)"
  Assert ([string]$ackStop.why -match '停止未在超时内完成') "失败原因应点明等停超时，实际：$($ackStop.why)"
  Assert ($worker.Sync.busy -eq $false) '等停结束后 $sync.busy 必须复位（否则陈旧判据永久失效）。'
  Write-Output 'PASS: stop 等停超时回执 ok=false + why 说明超时；阻塞期间 busy=true，结束后复位。'
} finally { Close-FakePoll $worker }

# ---- busy 运行时用例的注入器 ----
# runspace 里的命令处理跑的是 $script:poll 这段字符串（lib/poll.ps1 的 here-string + 前置的
# svc-common/health），函数也在里面定义——测试作用域里重定义同名函数盖不到它，只能改字符串本身。
# 注入点选在 Invoke-PendingCommands 定义之前：此时原实现已定义完、循环还没开始跑。
# 调用方必须自己保存 $script:poll 原值并在 finally 里还原，不许依赖用例正常返回。
function New-PollWithOverride([string]$code){
  $marker = 'function Invoke-PendingCommands {'
  if (-not $script:poll.Contains($marker)) { throw "poll 脚本块里找不到「$marker」，busy 用例的注入点已漂移。" }
  $script:poll.Replace($marker, $code + "`n" + $marker)
}

# ---- start 的 busy 窗口：慢启动期间 $sync.busy 必须为 $true，回执后复位 ----
# 上面那条守的是 stop 的等停；start 的 $svc.Start()（对慢启动服务实测等满 30032ms）是另一处阻塞点，
# 同属「整段命令处理 busy」的不变式。光有源码门禁不够——本用例给运行时的证据。
# 「真的走了 start 分支」的回执走 $sync.startRan：跨 runspace 只能经同步表传，$script: 传不出来。
$pollSaved = $script:poll
try {
  $script:poll = New-PollWithOverride @'
# 测试注入：让 start 分支变慢，并把「确实执行了 start」写进 $sync（仅作用于本用例的 runspace）
function Invoke-ServiceStart([string]$n,[string]$fail='启动失败'){
  Start-Sleep -Milliseconds 300
  $sync.startRan = $true
  $true
}
'@
  $worker=Start-FakePoll 1 'Stopped' 0 @{ busy = $false }
  try {
    Assert ($worker.Sync.probeStarted.WaitOne(3000)) 'Start-busy worker did not start.'
    $worker.Sync.cmd.Enqueue([pscustomobject]@{n='Fake0';act='start';e=61})
    [void]$worker.Sync.wake.Set()
    $sawBusy=$false
    $deadline=[datetime]::UtcNow.AddSeconds(5)
    while (-not $sawBusy -and [datetime]::UtcNow -lt $deadline) {
      $sawBusy = ($worker.Sync.busy -eq $true)
      if (-not $sawBusy) { Start-Sleep -Milliseconds 5 }
    }
    Assert ($sawBusy) 'start 阻塞期间 $sync.busy 必须为 $true（否则别的卡片会被误判陈旧）。'
    $ackStart = Wait-FakePollAck $worker
    Assert ($null -ne $ackStart) 'start 命令没有产出回执。'
    Assert ($ackStart.act -eq 'start' -and $ackStart.ok -eq $true) "start 应成功回执，got act=$($ackStart.act) ok=$($ackStart.ok) why=$($ackStart.why)"
    Assert ($worker.Sync.startRan -eq $true) 'start 分支根本没执行（用例空转）：别让 busy 置位掩盖未执行。'
    Assert ($worker.Sync.busy -eq $false) 'start 结束后 $sync.busy 必须复位（否则陈旧判据永久失效）。'
    Write-Output 'PASS: start 阻塞期间 busy=true，回执后复位，且确实走了 start 分支（$sync.startRan）。'
  } finally { Close-FakePoll $worker }
} finally { $script:poll = $pollSaved }

# ---- restart 的启动阶段也必须在 busy 窗口内 ----
# 对应 1.0.24 那个 P2 的原形：把 restart 分支里的 Invoke-ServiceStart 挪到 finally 之后，
# 停止阶段还标着 busy、启动阶段已经复位，卡片在这段时间又被判陈旧。
# 判据取「进入调用那一刻」的 $sync.busy：挪出窗口必然读到 $false，外部采样看不出这个区别。
$pollSaved = $script:poll
try {
  $script:poll = New-PollWithOverride @'
# 测试注入：等停直接成功（跳过 12s 预算），启动阶段变慢并记录进入调用时的 busy
function Wait-Stopped([string]$n,[int]$TimeoutMs = 0){ $true }
function Invoke-ServiceStart([string]$n,[string]$fail='重启后启动失败'){
  $sync.startBusyAtEntry = [bool]$sync.busy
  Start-Sleep -Milliseconds 300
  $sync.startRan = $true
  $true
}
'@
  $worker=Start-FakePoll 1 'Running' 0 @{ busy = $false }
  try {
    Assert ($worker.Sync.probeStarted.WaitOne(3000)) 'Restart-busy worker did not start.'
    $worker.Sync.cmd.Enqueue([pscustomobject]@{n='Fake0';act='restart';e=62})
    [void]$worker.Sync.wake.Set()
    $ackRestart = Wait-FakePollAck $worker
    Assert ($null -ne $ackRestart) 'restart 命令没有产出回执。'
    Assert ($ackRestart.act -eq 'restart' -and $ackRestart.ok -eq $true) "restart 应成功回执，got act=$($ackRestart.act) ok=$($ackRestart.ok) why=$($ackRestart.why)"
    Assert ($worker.Sync.startRan -eq $true) 'restart 的启动阶段没执行（用例空转）。'
    Assert ($worker.Sync.startBusyAtEntry -eq $true) 'restart 启动阶段进入调用时 $sync.busy 为 $false —— 启动调用已经跑到 busy 窗口之外。'
    Assert ($worker.Sync.busy -eq $false) 'restart 结束后 $sync.busy 必须复位。'
    Write-Output 'PASS: restart 的启动阶段在 busy 窗口内（进入调用时 busy=true），结束后复位。'
  } finally { Close-FakePoll $worker }
} finally { $script:poll = $pollSaved }

# ---- start 抛异常：回执判失败，finally 仍要复位 busy ----
$pollSaved = $script:poll
try {
  $script:poll = New-PollWithOverride @'
# 测试注入：start 直接抛异常（异常路径必须照样走 finally 复位）
function Invoke-ServiceStart([string]$n,[string]$fail='启动失败'){ throw 'boom' }
'@
  $worker=Start-FakePoll 1 'Stopped' 0 @{ busy = $false }
  try {
    Assert ($worker.Sync.probeStarted.WaitOne(3000)) 'Throw-busy worker did not start.'
    $worker.Sync.cmd.Enqueue([pscustomobject]@{n='Fake0';act='start';e=63})
    [void]$worker.Sync.wake.Set()
    $ackBoom = Wait-FakePollAck $worker
    Assert ($null -ne $ackBoom) 'start 抛异常时没有产出回执（轮询循环死了？）。'
    Assert ($ackBoom.ok -eq $false) "start 抛异常必须按失败回执，got ok=$($ackBoom.ok)"
    Assert ([string]$ackBoom.why -match 'boom') "失败原因应带上异常消息，实际：$($ackBoom.why)"
    Assert ($worker.Sync.busy -eq $false) 'start 抛异常后 $sync.busy 必须复位（finally 未生效 = 陈旧判据永久失效）。'
    Write-Output 'PASS: start 抛异常时回执 ok=false，且 finally 把 busy 复位。'
  } finally { Close-FakePoll $worker }
} finally { $script:poll = $pollSaved }

# ---- stop 的 sc 失败（非 1062）：why 必须写进回执，不能只进状态栏 ----
$worker=Start-FakePoll 1 'Running' 0 $null 5
try {
  Assert ($worker.Sync.probeStarted.WaitOne(3000)) 'sc-fail worker did not start.'
  $worker.Sync.cmd.Enqueue([pscustomobject]@{n='Fake0';act='stop';e=52})
  [void]$worker.Sync.wake.Set()
  $ackSc = Wait-FakePollAck $worker
  Assert ($null -ne $ackSc) 'sc 失败的 stop 没有产出回执。'
  Assert ($ackSc.ok -eq $false) "sc 返回 5 时应按失败回执，got ok=$($ackSc.ok)"
  Assert ([string]$ackSc.why -match '停止失败') "回执 why 应含「停止失败」，实际：$($ackSc.why)"
  Assert ([string]$ackSc.why -match '5') "回执 why 应带退出码，实际：$($ackSc.why)"
  Write-Output 'PASS: stop 的 sc 失败（退出码 5）回执 ok=false 且 why 含原因与退出码。'
} finally { Close-FakePoll $worker }

# ---- restart 的中间回执（B2）：停止阶段结束后必须补一条 phase='start' ----
# 修前只有一条最终回执：整个重启期间卡片写着「停止中」，看不出服务已经开始起来了。
$worker=Start-FakePoll 1 'Stopped' 0 @{ waitStoppedTimeoutMs = 200; waitStoppedPollMs = 10 }
try {
  Assert ($worker.Sync.probeStarted.WaitOne(3000)) 'Restart worker did not start.'
  $worker.Sync.cmd.Enqueue([pscustomobject]@{n='Fake0';act='restart';e=7})
  [void]$worker.Sync.wake.Set()
  $items=@(); $deadline=[datetime]::UtcNow.AddSeconds(15)
  while ([datetime]::UtcNow -lt $deadline) {
    $it=$null
    while ($worker.Sync.queue.TryDequeue([ref]$it)) { $items += $it }
    if (@($items | Where-Object { $_.phase -eq 'start' }).Count -ge 1 -and @($items | Where-Object { $_.done }).Count -ge 1) { break }
    Start-Sleep -Milliseconds 20
  }
  $phase=@($items | Where-Object { $_.phase -eq 'start' })
  $final=@($items | Where-Object { $_.done })
  Assert ($phase.Count -eq 1 -and $phase[0].e -eq 7 -and $phase[0].n -eq 'Fake0') "restart 应产出一条 phase=start 中间回执，got $($phase.Count)"
  Assert ($final.Count -eq 1 -and $final[0].act -eq 'restart' -and $final[0].ok) "最终回执照旧收尾，got $($final.Count)"
  $pi=-1; $fi=-1
  for ($i=0; $i -lt $items.Count; $i++) {
    if ($pi -lt 0 -and $items[$i].phase -eq 'start') { $pi=$i }
    if ($fi -lt 0 -and $items[$i].done) { $fi=$i }
  }
  Assert ($pi -ge 0 -and $fi -gt $pi) "中间回执必须先于最终回执（phase@$pi final@$fi）"
  Write-Output 'PASS: restart emits a phase=start receipt after the stop phase, then the usual final ack.'
} finally { Close-FakePoll $worker }

# ---- restart 等不到 Stopped 时必须中止，不能拿 1056 当「已在运行」继续 start ----
$worker=Start-FakePoll 1 'Running' 0 @{ waitStoppedTimeoutMs = 100; waitStoppedPollMs = 10 }
try {
  Assert ($worker.Sync.probeStarted.WaitOne(3000)) 'Restart worker did not start.'
  $worker.Sync.cmd.Enqueue([pscustomobject]@{n='Fake0';act='restart';e=8})
  [void]$worker.Sync.wake.Set()
  $items=@(); $deadline=[datetime]::UtcNow.AddSeconds(15)
  while ([datetime]::UtcNow -lt $deadline) {
    $it=$null
    while ($worker.Sync.queue.TryDequeue([ref]$it)) { $items += $it }
    if (@($items | Where-Object { $_.done }).Count -ge 1) { break }
    Start-Sleep -Milliseconds 20
  }
  $final=@($items | Where-Object { $_.done })
  $phase=@($items | Where-Object { $_.phase -eq 'start' })
  Assert ($final.Count -eq 1) "重启应有一条最终回执，got $($final.Count)"
  Assert (-not $final[0].ok) '停止超时时重启必须判失败，不能当作成功'
  Assert ([string]$final[0].why -match '中止重启') "失败原因应点明已中止重启，实际：$($final[0].why)"
  Assert ($phase.Count -eq 0) '停止未完成时不得下发 phase=start（会误导成已经在启动）'
  Write-Output 'PASS: restart aborts with a clear reason when the service never reaches Stopped.'
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

# ---- 缺注入兜底（P1）：$sync 不带 scmPendingStates 时，中间态仍必须走 ProbePendingMs ----
# 修前 poll 直接 `$st -in @($sync.scmPendingStates)`：缺键 → @($null) → 恒 False → $pendingSeen 永远为假，
# 卡片停在「启动中」最长 ProbeIdleMs（15s）。`-omitPendingStates` 刻意不塞这个键，走 poll 的兜底字面量。
# probePendingMs=300 / 其余 60s：走错分支要等 60s，5s 即红。
$worker=Start-FakePoll 1 'StartPending' 0 @{ probePendingMs = 300; probeIntervalMs = 60000; probeIdleMs = 60000 } -omitPendingStates
try {
  Assert ($worker.Sync.probeStarted.WaitOne(3000)) 'Worker did not start.'
  Assert (-not $worker.Sync.ContainsKey('scmPendingStates')) '本轮夹具应刻意不注入 scmPendingStates。'
  # (b) 缺注入不得改变「启动中」的既有行为：仍按中间态分支原样入队（h 为空，不是探测结果的健康值）。
  Start-Sleep -Milliseconds 700
  $item=$null; $seenStartPending=$false; $badHealth=$false
  while ($worker.Sync.queue.TryDequeue([ref]$item)) {
    if ($item.n -eq 'Fake0' -and $item.st -eq '启动中') {
      $seenStartPending=$true
      if ([string]$item.h -ne '') { $badHealth=$true }
    }
  }
  Assert $seenStartPending '缺注入时「启动中」没有送到 UI（兜底失效：中间态漏报或被降级）。'
  Assert (-not $badHealth) '缺注入时「启动中」带上了健康值——中间态应走非探测分支（h 为空）。'
  # (a) 缺注入时仍按 ProbePendingMs 短间隔轮询（两侧间隔必须远小于 ProbeIdleMs=60000）。
  $p0=$worker.Sync.probeCount; $t0=[datetime]::UtcNow
  $deadline=[datetime]::UtcNow.AddSeconds(5)
  while ($worker.Sync.probeCount -le $p0 -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
  $elapsed=([datetime]::UtcNow-$t0).TotalMilliseconds
  Assert ($worker.Sync.probeCount -gt $p0) 'No second cycle within 5s — 缺 scmPendingStates 时中间态睡到了 ProbeIntervalMs/ProbeIdleMs。'
  Assert ($elapsed -lt 2500) "缺注入时中间态睡眠 ${elapsed}ms；应回落到兜底四态并走 ProbePendingMs=300ms（远小于 ProbeIdleMs=60000）。"
  Write-Output "PASS: missing scmPendingStates still polls pending states at ProbePendingMs (${elapsed}ms)."
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

# ---- busy 标记：整段命令处理必须包在单一 try/finally 窗口内（AST 级不变式，防回退） ----
# 阻塞点不止一处：start 的 $svc.Start() 实测等满 30032ms；stop/restart/remove 的 Wait-Stopped
# 最长等满该服务预算（默认 12s）。期间产不出探测样本，卡片判据只有 2×ProbeIntervalMs（默认 8s）。
# 判据走 AST，不走文本 IndexOf：文本版有两个假通过口——
#   ① 把 switch($act){...} 整体挪到 try 外面（置位与 finally 位置不变）仍能通过：文本门禁只比
#      「置位在 switch 之前」，没断言分发在 try 体内；
#   ② 把阻塞锚点只写进字符串 / here-string 也通过：Get-SourceCodeOnly 只剥注释不剥字符串，
#      IndexOf 会命中字符串内容。
# AST 里字符串只是字面量，CommandAst 只认真正的调用，两者都能杀掉。
# 注意：poll.ps1 的循环体是 here-string 字面量（在 runspace 里执行），直接解析 poll.ps1 拿不到
# 循环体里的任何 CommandAst——必须先从 $script:poll 的赋值里取出字面量，再重新解析它。
$pollPath = Join-Path $RepoRoot 'lib/poll.ps1'
$pollTokens = $null; $pollParseErrors = @()
$pollFileAst = [System.Management.Automation.Language.Parser]::ParseFile($pollPath, [ref]$pollTokens, [ref]$pollParseErrors)
Assert ($pollParseErrors.Count -eq 0) "lib/poll.ps1 解析失败：$(($pollParseErrors | ForEach-Object { $_.Message }) -join '; ')"
$pollAssigns = @($pollFileAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$script:poll'
}, $true))
Assert ($pollAssigns.Count -eq 1) "lib/poll.ps1 里 `$script:poll 的赋值应恰好一处，实际 $($pollAssigns.Count) 处。"
$pollLiterals = @($pollAssigns[0].Right.FindAll({
  param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
}, $true) | Sort-Object -Property { $_.Value.Length } -Descending)
Assert ($pollLiterals.Count -ge 1) 'lib/poll.ps1 的 $script:poll 里找不到 here-string 字面量（循环体消失了？）。'
Assert ($pollLiterals[0].Value -match 'function Invoke-PendingCommands') '取到的字面量不是循环体（缺 Invoke-PendingCommands 定义）。'
$pollBodyTokens = $null; $pollBodyErrors = @()
$pollBody = [System.Management.Automation.Language.Parser]::ParseInput($pollLiterals[0].Value, [ref]$pollBodyTokens, [ref]$pollBodyErrors)
Assert ($pollBodyErrors.Count -eq 0) "poll 循环体解析失败：$(($pollBodyErrors | ForEach-Object { $_.Message }) -join '; ')"
# CommandAst 计数天然忽略注释与字符串，这就是上面两个反例的根治点。
$pollCmds = @($pollBody.FindAll({
  param($node) $node -is [System.Management.Automation.Language.CommandAst]
}, $true))
$busyOn = @($pollCmds | Where-Object {
  $_.GetCommandName() -eq 'Set-PollBusy' -and $_.CommandElements.Count -ge 2 -and $_.CommandElements[1].Extent.Text -eq '$true'
})
$busyOff = @($pollCmds | Where-Object {
  $_.GetCommandName() -eq 'Set-PollBusy' -and $_.CommandElements.Count -ge 2 -and $_.CommandElements[1].Extent.Text -eq '$false'
})
# 不写死 -eq 1：允许将来在 try 之前合法地多置一次位（如按服务分支各置一次）。
# 判据是**结构位置**而不是次数——次数门禁会把当前覆盖范围固化成不变式，合法新增反而变红。
Assert ($busyOn.Count -ge 1) 'Set-PollBusy $true 至少一处（否则 busy 窗口不存在）。'
Assert ($busyOff.Count -ge 1) 'Set-PollBusy $false 至少一处（否则异常路径不复位）。'
$pollTries = @($pollBody.FindAll({
  param($node) $node -is [System.Management.Automation.Language.TryStatementAst]
}, $true))
# 承载复位的 try：复位必须写在 finally 里（挪到 try 尾部后，抛异常或 break 就不再复位）。
$busyTry = @($pollTries | Where-Object {
  $finallyBlock = $_.Finally
  if (-not $finallyBlock) { return $false }
  @($busyOff | Where-Object {
    $_.Extent.StartOffset -ge $finallyBlock.Extent.StartOffset -and $_.Extent.EndOffset -le $finallyBlock.Extent.EndOffset
  }).Count -gt 0
})
Assert ($busyTry.Count -eq 1) "复位所在的 try/finally 应恰好一处（整段命令处理只该有一个 busy 窗口），实际 $($busyTry.Count) 处。"
$busyBlock = $busyTry[0]
foreach ($offCmd in $busyOff) {
  Assert ($offCmd.Extent.StartOffset -ge $busyBlock.Finally.Extent.StartOffset -and
          $offCmd.Extent.EndOffset -le $busyBlock.Finally.Extent.EndOffset) "Set-PollBusy `$false（第 $($offCmd.Extent.StartLineNumber) 行）不在 finally 里：抛异常或 break 时不会复位。"
}
foreach ($onCmd in $busyOn) {
  Assert ($onCmd.Extent.StartOffset -lt $busyBlock.Extent.StartOffset) "Set-PollBusy `$true（第 $($onCmd.Extent.StartLineNumber) 行）必须在 try 之前：否则 try 之外的命令处理不在 busy 窗口内。"
}
# 命令分发（switch($act)）必须在 try 体内：挪出去就整段不受 busy 覆盖。
$actSwitch = @($busyBlock.Body.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.SwitchStatementAst] -and $node.Condition.Extent.Text -eq '$act'
}, $true))
Assert ($actSwitch.Count -eq 1) "命令分发 switch(`$act) 必须在 try 体内且只有一处，实际 $($actSwitch.Count) 处。"
$dispatch = $actSwitch[0]
Assert ($dispatch.Extent.StartOffset -ge $busyBlock.Body.Extent.StartOffset -and
        $dispatch.Extent.EndOffset -le $busyBlock.Body.Extent.EndOffset) 'switch($act) 必须完整落在 try 体内（含结尾）。'
# busy 窗口 = 最后一次置位的结束 → 最早一次复位的开始。
$windowStart = ($busyOn | ForEach-Object { $_.Extent.EndOffset } | Measure-Object -Maximum).Maximum
$windowEnd = ($busyOff | ForEach-Object { $_.Extent.StartOffset } | Measure-Object -Minimum).Minimum
Assert ($windowStart -le $windowEnd) 'busy 窗口为空（置位在复位之后）。'
# 每一个阻塞调用都必须在窗口内——按命令名取**全部**出现再逐个断言，不是只看第一处。
# 旧门禁（文本 IndexOf）漏的正是第二处：restart 分支的 Invoke-ServiceStart / Wait-Stopped
# 与 stop 分支同名，IndexOf 永远命中第一处，把第二处挪到 finally 之后照样 GREEN。
$blockingNames = @('Invoke-ServiceStart', 'Wait-Stopped', 'Invoke-ServiceRemove')
foreach ($name in $blockingNames) {
  $hits = @($pollCmds | Where-Object { $_.GetCommandName() -eq $name })
  Assert ($hits.Count -ge 1) "命令队列里必须有真实的 $name 调用（字符串里的同名文本不算；全删了也要红）。"
  foreach ($hit in $hits) {
    Assert ($hit.Extent.StartOffset -ge $windowStart -and $hit.Extent.EndOffset -le $windowEnd) "$name（第 $($hit.Extent.StartLineNumber) 行）不在 busy 窗口内：阻塞期间会漏标 busy。"
  }
}
# 已知阻塞锚点按分支断言：每个分支里必须有**真实调用**（CommandAst），字符串里的同名文本顶不上。
$blockingAnchors = @(
  @{ Label = 'start'; Command = 'Invoke-ServiceStart'; Why = 'start 的 $svc.Start()' }
  @{ Label = 'stop'; Command = 'Wait-Stopped'; Why = 'stop 的等停' }
  @{ Label = 'restart'; Command = 'Wait-Stopped'; Why = 'restart 的等停' }
  @{ Label = 'remove'; Command = 'Invoke-ServiceRemove'; Why = 'remove 的等停+删除' }
)
# Clauses 元素的形态随 PowerShell 版本变过：7.4+ 是 (标签, 语句块) 元组，旧版是 SwitchClauseAst。
# 归一成 { Label; Body }，不直接依赖某一种形态（否则换 runner 就红）。
$switchBranches = @($dispatch.Clauses | ForEach-Object {
  if ($_.PSObject.Properties['Item1']) {
    [pscustomobject]@{ Label = [string]$_.Item1.Value; Body = $_.Item2 }
  } else {
    [pscustomobject]@{ Label = ($_.Extent.Text -replace "(?s)^\s*'([^']*)'.*", '$1'); Body = $_ }
  }
})
foreach ($anchor in $blockingAnchors) {
  $branch = @($switchBranches | Where-Object { $_.Label -eq $anchor.Label })
  Assert ($branch.Count -eq 1) "switch(`$act) 里应恰好有一个 '$($anchor.Label)' 分支，实际 $($branch.Count) 个。"
  $calls = @($branch[0].Body.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq $anchor.Command
  }, $true))
  Assert ($calls.Count -ge 1) "'$($anchor.Label)' 分支里必须有真实调用 $($anchor.Command)（$($anchor.Why)）；字符串里的同名文本不算。"
}
Write-Output 'PASS: 整段命令处理包在单一 busy 窗口内（AST），switch($act) 在 try 体内，四个分支的阻塞调用都是真实调用。'

# ---- busy 缺键（writer 侧）：$sync 没有 busy 键时 Set-PollBusy 静默跳过，且不许凭空加键 ----
# CLI 路径与夹具都可能没预置这个键；Set-PollBusy 的守卫是 ContainsKey。凭空补一个 busy=$false
# 会让 UI 侧以为注入齐了，把真正的注入缺失掩盖成「一切正常」。
$worker=Start-FakePoll 1 'Stopped' 0 @{ waitStoppedTimeoutMs = 300; waitStoppedPollMs = 20 }
try {
  Assert ($worker.Sync.probeStarted.WaitOne(3000)) 'No-busy worker did not start.'
  Assert (-not $worker.Sync.ContainsKey('busy')) '夹具：这一路刻意不注入 busy 键。'
  $worker.Sync.cmd.Enqueue([pscustomobject]@{n='Fake0';act='stop';e=71})
  [void]$worker.Sync.wake.Set()
  $ackNoBusy = Wait-FakePollAck $worker
  Assert ($null -ne $ackNoBusy) '缺 busy 键时 stop 没有产出回执——Set-PollBusy 抛异常了？'
  Assert ($ackNoBusy.ok -eq $true) "缺 busy 键不该影响停止结果，got ok=$($ackNoBusy.ok) why=$($ackNoBusy.why)"
  Assert (-not $worker.Sync.ContainsKey('busy')) 'Set-PollBusy 不得往 $sync 里凭空加 busy 键。'
  Write-Output 'PASS: $sync 缺 busy 键时 stop 照常完成，且该键仍不存在（Set-PollBusy 静默跳过）。'
} finally { Close-FakePoll $worker }

# ---- busy 缺键（reader 侧）：Update-CardFreshness 的行为必须与 busy=false 一致 ----
# 只加断言、不改 lib/card.ps1：缺键时 $script:sync['busy'] -eq $true 为 $false，照常判陈旧。
# 两种 $sync 各跑一次同一夹具（60s 前的样本 > 2×ProbeIntervalMs=8s），逐项结果必须相同。
. (Join-Path $RepoRoot 'lib/util.ps1')
. (Join-Path $RepoRoot 'lib/card.ps1')
function Update-CardAutomationName($card) { }   # 读屏名字要真 WPF 控件，与陈旧判据无关，置空桩
$script:T = @{ BrushStale = 'BrushStale#stub' }
$script:svcState = @{ Fake0 = @{ st='运行中'; h='正常'; at=[datetime]::Now.AddSeconds(-60) } }
function New-StaleFixtureCard {
  [pscustomobject]@{
    SvcName='Fake0'; ST='运行中'; Stale=$false; PendingSave=$false; Offline=$false
    LblSt=[pscustomobject]@{ Text='运行中'; Foreground=$null }
    Dot=[pscustomobject]@{ Fill=$null }
    LblUpBase=''
    Btn=[pscustomobject]@{ IsEnabled=$true }
    BtnStop=[pscustomobject]@{ IsEnabled=$true }
    ReadyToToggle=$true
  }
}
# 真实 runspace 里 $sync 是同步哈希表，夹具照做，免得只测到普通 @{} 的行为。
$script:sync = [hashtable]::Synchronized(@{ gate = [object]::new() })                  # 刻意没有 busy 键
$cardNoBusyKey = New-StaleFixtureCard
Update-CardFreshness $cardNoBusyKey (Get-Date)
$script:sync = [hashtable]::Synchronized(@{ gate = [object]::new(); busy = $false })   # 同样「不忙」，只是键存在
$cardBusyFalse = New-StaleFixtureCard
Update-CardFreshness $cardBusyFalse (Get-Date)
Assert ($cardNoBusyKey.Stale -eq $cardBusyFalse.Stale) "缺 busy 键与 busy=false 的 Stale 必须一致（$($cardNoBusyKey.Stale) vs $($cardBusyFalse.Stale)）。"
Assert ($cardNoBusyKey.Stale -eq $true) '缺 busy 键时 60s 前的样本也必须判陈旧（缺键不等于永久豁免）。'
Assert ($cardNoBusyKey.LblSt.Text -eq $cardBusyFalse.LblSt.Text) "缺键与 busy=false 的状态文案必须一致（$($cardNoBusyKey.LblSt.Text) vs $($cardBusyFalse.LblSt.Text)）。"
Assert ($cardNoBusyKey.LblSt.Text -eq '状态未知') "陈旧样本应显示「状态未知」，实际「$($cardNoBusyKey.LblSt.Text)」。"
Assert ($cardNoBusyKey.Btn.IsEnabled -eq $false -and $cardBusyFalse.Btn.IsEnabled -eq $false) '两种 $sync 都必须禁用主按钮。'
Write-Output 'PASS: $sync 缺 busy 键时 Update-CardFreshness 与 busy=false 判定一致（reader 侧正则守卫）。'

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

# ---- worker 泄漏门禁：本文件启动的 runspace 必须全部关掉 ----
# 修前（v1.0.22）：1062 用例嵌在抛异常用例的 try 里，$worker 中途改指向新 worker，
# 于是前一个 worker 从未关闭（runspace 泄漏），后一个被关两次（异常当年被 Close-FakePoll 吞掉）。
Assert ([int]$script:fakePollOpen -eq 0) "有 $($script:fakePollOpen) 个 fake worker 没被 Close-FakePoll 关掉（runspace 泄漏）。"
Assert ([int]$script:fakePollStarted -ge 10) "worker 计数自检失败（Started=$($script:fakePollStarted)），别把门禁写成永远绿灯。"
Write-Output "PASS: 本文件启动的 $($script:fakePollStarted) 个 worker 全部关闭（无 runspace 泄漏）。"

Write-Output 'PASS: wakeup, priority between probes, FIFO, and idle shutdown; no real services or network used.'
