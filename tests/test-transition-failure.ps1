#requires -Version 7.0
# T1 的红测试：过渡态必须有失败出口，否则卡片永久卡死。
#
# 三段链路（修前全红）：
#   1. 根因（后台侧）：失败命令必须发回执。修前 poll.ps1 只在 $ok 时 Enqueue，
#      失败即静默——UI 侧根本没有失败出口可言。
#   2. 启动 ack 失败 / 停止失败：回执 ok=$false 时须回滚到命令前的终态并解封按钮。
#   3. 回执彻底丢失：超过 ToggleTimeoutMs 后须按到达的探测值收敛，不得永久卡在过渡态。
#      （修前启动中只认运行中、停止中只认已停止，反向探测一律丢弃 → 永久卡死。）
#
# 测试顺序刻意把根因排在最前：HEAD 版本上它会因「失败命令没有回执」而红（行为红），
# 而不是先撞上「新字段/新函数不存在」的报错——后者虽是红，却说明不了行为差异。
param([string]$RepoRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }

# ---- 1. 根因：失败命令必须发回执 ----
. (Join-Path $RepoRoot 'lib/poll.ps1')
. (Join-Path $RepoRoot 'tests/test-helpers.ps1')
# scExitCode=1062（未启动）：让替身 sc.exe stop 返回非零 → 命令执行失败
$worker=Start-FakePoll 1 'Stopped' 0 $null 1062
try {
  Assert ($worker.Sync.probeStarted.WaitOne(3000)) 'Worker did not start.'
  $worker.Sync.cmd.Enqueue([pscustomobject]@{n='Fake0';act='stop';e=7})
  [void]$worker.Sync.wake.Set()

  # 找**命令回执**（done=$true）——队列里混着普通探测结果（无 done 字段），不能混为一谈。
  # 修前 HEAD 只在 $ok 时 Enqueue，失败命令一条 done 都发不出来：若不过滤，会从队列里
  # 取到一条探测结果并误报「Ack shape wrong」，红了但红得不准。
  $ack = Wait-FakePollAck $worker
  Assert ($null -ne $ack) 'Failing command produced no ack at all — card has no failure exit.'
  Assert ($ack.act -eq 'stop') "Ack shape wrong: $ack"
  Assert ($ack.e -eq 7) "Ack epoch mismatch: got $($ack.e)"
  Assert ($ack.ok -eq $false) "Failed command should report ok=`$false, got ok=$($ack.ok)."
  Write-Output 'PASS: failing command emits an ack carrying ok=$false (UI can roll the card back).'
} finally { Close-FakePoll $worker }

# ---- 2/3. UI 侧：失败回滚与超时逃生 ----
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
foreach ($module in 'theme','util','card','xaml') { . (Join-Path $RepoRoot "lib/$module.ps1") }
$script:sync=@{wake=[Threading.AutoResetEvent]::new($false); gate=[object]::new()}
$script:svc=[ordered]@{TestService=@{port=8080;url='http://127.0.0.1:8080'}}
$script:cmdQueue=[Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:cmdEpoch=0
function Stop-Background {}

$win=New-MainWindow
try {
  Render-Page
  $card=$script:cards['TestService']

  # ---- 1. 启动失败（探测恒为已停止）：超时后必须收敛回停止态且按钮可用 ----
  Update-CardData 'TestService' '已停止' ''
  Invoke-CardToggle $card
  Assert ($card.ST -eq '启动中' -and -not $card.Btn.IsEnabled) 'Start transition not entered.'
  # 未超时：过渡态守卫照旧丢弃反向探测（既有行为，test-transition-race 覆盖）
  Update-CardData 'TestService' '已停止' ''
  Assert ($card.ST -eq '启动中') "Pre-timeout probe overwrote transition: ST=$($card.ST)."
  Assert (-not $card.Btn.IsEnabled) 'Pre-timeout probe re-enabled button.'
  # 把过渡起算点推到超时之外（模拟命令回执永远不会到）
  $card.TransitionAt=[datetime]::Now.AddMilliseconds(-($script:TOGGLE_TIMEOUT_MS+1000))
  Update-CardData 'TestService' '已停止' ''
  Assert ($card.ST -eq '已停止') "Post-timeout probe did not converge: ST=$($card.ST)."
  Assert ($card.Btn.IsEnabled) 'Post-timeout probe left button disabled (永久卡死).'
  Assert ($card.Btn.Content -eq '启动') "Post-timeout button label wrong: $($card.Btn.Content)."

  # ---- 2. 停止失败：回执 ok=$false 须回滚到命令前的终态并解封 ----
  $card.LastToggle=[datetime]::MinValue
  Update-CardData 'TestService' '运行中' '正常'
  Assert ($card.ST -eq '运行中' -and $card.ReadyToToggle) 'Running+healthy not armed.'
  Invoke-CardToggle $card
  Assert ($card.ST -eq '停止中' -and -not $card.Btn.IsEnabled) 'Stop transition not entered.'
  # 失败回执（ok=$false）：修前只解封按钮、文字仍是「停止中」（红）
  Update-CardData 'TestService' $null $null -e $card.PendingEpoch -ack -ok $false
  Assert ($card.ST -eq '运行中') "Failed stop did not roll back to 运行中: ST=$($card.ST)."
  # 回滚到「运行中+健康正常」→ 可用的是**关闭**按钮（启动键此刻应当禁用）
  Assert ($card.BtnStop.IsEnabled) 'Failed stop left the close button disabled.'
  Assert (-not $card.Btn.IsEnabled) 'Failed stop wrongly enabled the start button.'
  Assert ($card.ReadyToToggle) 'Failed stop did not restore toggle readiness.'
  Assert ($card.PendingEpoch -eq 0) 'Failed stop left PendingEpoch set.'

  # ---- 2b. 启停失败回滚后，用户能立刻重试（冷却不得把失败也锁上）----
  Assert ($card.LastToggle -eq [datetime]::MinValue) 'Failed stop left cooldown set (user cannot retry).'

  # ---- 3. 删除失败：不得永久停在「删除中」----
  $card.LastToggle=[datetime]::MinValue
  Update-CardData 'TestService' '已停止' ''
  $epoch=99
  Set-CardTransition $card '删除中' $epoch ([datetime]::Now)
  Assert ($card.ST -eq '删除中') 'Delete transition not entered.'
  # 删除没有「期望终态」：未超时时任何探测都不该改写（既有行为，test-transition-race 覆盖）
  Update-CardData 'TestService' '未安装' ''
  Assert ($card.ST -eq '删除中') "Pre-timeout probe overwrote 删除中: ST=$($card.ST)."
  # 超时后收敛到「未知」——**不用**到达的探测值：探测可能报「已停止」（删除本就先 stop），
  # 收敛后按钮点亮，用户能对一个正在删除的服务下「启动」。删除成败只有 remove 回执知道，
  # 丢失时状态不确定，故显示未知且不解封按钮。
  $card.TransitionAt=[datetime]::Now.AddMilliseconds(-($script:TOGGLE_TIMEOUT_MS+1000))
  Update-CardData 'TestService' '已停止' ''
  Assert ($card.ST -eq '未知') "Timed-out delete should converge to 未知: ST=$($card.ST)."
  Assert (-not $card.Btn.IsEnabled) 'Timed-out delete must not re-enable the button (service may be mid-delete).'

  # ---- 4. 后台死亡逃生：无任何探测结果时，Update-StatusTick 的 sweep 也要放出过渡态 ----
  # 这是 T1 逃生的**兜底分支**：Update-CardData 里的超时逻辑只在有探测结果到达时才跑，
  # 后台 runspace 若异常退出（队列再无生产者），卡片会永久卡在「启动中」。故 util.ps1 的
  # Update-StatusTick 每帧无条件扫一遍卡片，不依赖队列生产者。这里故意**不喂任何队列项**。
  $script:queue=[Collections.Concurrent.ConcurrentQueue[object]]::new()
  $script:msgQueue=[Collections.Concurrent.ConcurrentQueue[string]]::new()
  $card.LastToggle=[datetime]::MinValue
  Update-CardData 'TestService' '已停止' ''
  Invoke-CardToggle $card
  Assert ($card.ST -eq '启动中' -and -not $card.Btn.IsEnabled) 'Start transition not entered (sweep case).'
  # 无队列生产者：模拟后台死亡——把过渡起算点推到超时之外，只跑 Update-StatusTick
  $card.TransitionAt=[datetime]::Now.AddMilliseconds(-($script:TOGGLE_TIMEOUT_MS+1000))
  Update-StatusTick
  Assert ($card.ST -eq '已停止') "Sweep did not escape a stuck 启动中 without a probe result: ST=$($card.ST)."
  Assert ($card.Btn.IsEnabled) 'Sweep left the button disabled (永久卡死 on background death).'

  # ---- 4b. H1 回归：探测驱动的过渡态不得永久卡死 ----
  # 探测报 StartPending/StopPending 会把卡片带进过渡态，但**不经过 Set-CardTransition**，
  # 故 TransitionAt 仍是 MinValue。修前：方向守卫按「启动中只接受运行中」把回落「已停止」
  # 永久丢弃，而 Test-TransitionTimedOut 对 MinValue 恒 false → 45s 逃生也失效 → 卡片卡死
  # 在「启动中」、按钮永久灰。修后：方向守卫只保护命令驱动的过渡态（TransitionAt 有值）。
  $script:queue=[Collections.Concurrent.ConcurrentQueue[object]]::new()
  $script:msgQueue=[Collections.Concurrent.ConcurrentQueue[string]]::new()
  $card.LastToggle=[datetime]::MinValue
  Update-CardData 'TestService' '已停止' ''
  Update-CardData 'TestService' '启动中' ''   # 探测到 StartPending（非命令驱动）
  Assert ($card.ST -eq '启动中' -and -not $card.Btn.IsEnabled) 'Probe-driven start transition not entered.'
  Assert ($card.TransitionAt -eq [datetime]::MinValue) 'Probe-driven transition must not set TransitionAt.'
  # 服务启动失败回落「已停止」——修前被永久丢弃
  Update-CardData 'TestService' '已停止' ''
  Assert ($card.ST -eq '已停止') "Probe-driven transition never converged (H1): ST=$($card.ST)."
  Assert ($card.Btn.IsEnabled) 'Probe-driven transition left the button disabled (H1 永久卡死).'

  # ---- 5a. 两个方向的门闩真值表 ----
  Assert (Test-CardCanStart '已停止') '已停止应可启动。'
  Assert (-not (Test-CardCanStart '运行中')) '运行中不可再启动。'
  Assert (Test-CardCanStop '运行中' '正常') '运行中+正常应可关闭。'
  Assert (-not (Test-CardCanStop '运行中' '无响应')) '运行中+无响应不可关闭（健康门闩）。'
  Assert (-not (Test-CardCanStop '运行中' '超时')) '运行中+超时不可关闭。'
  Assert (-not (Test-CardCanStop '运行中' '')) '运行中+空健康不可关闭。'
  Assert (-not (Test-CardCanStop '已停止' '正常')) '已停止不可关闭。'

  # ---- 5. ack 门闩按当前状态/健康重算，不无条件点亮 ----
  # 右键菜单的启停直接 Send-ServiceCommand、不置过渡态，回执到达时卡片可能仍是
  # 「运行中/无响应」。成功回执若硬置 ReadyToToggle=$true，用户能双击关掉一个本不该
  # 关闭的服务（健康门闩被绕过）。
  $card.LastToggle=[datetime]::MinValue
  Update-CardData 'TestService' '运行中' '无响应'
  Assert (-not $card.ReadyToToggle) 'Unhealthy running card should not be toggle-ready.'
  Update-CardData 'TestService' $null $null -e 0 -ack -ok $true
  Assert (-not $card.ReadyToToggle) "Success ack bypassed the health gate: ReadyToToggle=$($card.ReadyToToggle)."
  Assert (-not $card.BtnStop.IsEnabled) 'Success ack enabled the close button on an unhealthy service.'

  # ---- 6. 非过渡态的失败回执不得回滚（右键启停路径）----
  # 右键启停不置过渡态（TransitionAt 仍 MinValue），PrevST/PrevH 还是 New-Card 初值。
  # 失败回执若回滚，会把卡片刷成「未知」并清掉按钮——而服务实际还在跑、状态没变。
  $card.LastToggle=[datetime]::MinValue
  Update-CardData 'TestService' '运行中' '正常'
  $stBefore=$card.ST; $hBefore=$card.H
  Update-CardData 'TestService' $null $null -e 0 -ack -ok $false
  Assert ($card.ST -eq $stBefore -and $card.H -eq $hBefore) "Non-transition failure rolled back a live card: ST=$($card.ST) H=$($card.H)."
  Assert ($card.ReadyToToggle) 'Non-transition failure should re-arm a healthy running card.'
  Assert ($card.BtnStop.IsEnabled) 'Non-transition failure left the close button disabled.'

  Write-Output 'PASS: transition states have a failure exit (rollback on ok=false, timeout escape, queue-independent sweep); no permanent card lock.'
} finally { $win.Close(); $script:sync.wake.Dispose() }

