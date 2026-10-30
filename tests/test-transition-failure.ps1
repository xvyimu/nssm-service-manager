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
  # 未超时：过渡态守卫照旧丢弃反向探测
  Update-CardData 'TestService' '已停止' ''
  Assert ($card.ST -eq '启动中') "Pre-timeout probe overwrote transition: ST=$($card.ST)."
  Assert (-not $card.Btn.IsEnabled) 'Pre-timeout probe re-enabled button.'
  # 把过渡起算点推到超时之外（模拟命令回执永远不会到）
  $card.TransitionAt=[datetime]::Now.AddMilliseconds(-($script:TOGGLE_TIMEOUT_MS+1000))
  Update-CardData 'TestService' '已停止' ''
  Assert ($card.ST -eq '已停止') "Post-timeout probe did not converge: ST=$($card.ST)."
  Assert ($card.Btn.IsEnabled -and -not $card.BtnStop.IsEnabled) 'Post-timeout probe left the wrong buttons enabled.'

  # ---- 2. 停止失败：回执 ok=$false 须回滚到命令前的终态并解封 ----
  $card.LastToggle=[datetime]::MinValue
  Update-CardData 'TestService' '运行中' '正常'
  Assert ($card.ST -eq '运行中' -and $card.ReadyToToggle) 'Running+healthy not armed.'
  Invoke-CardToggle $card
  Assert ($card.ST -eq '停止中' -and -not $card.Btn.IsEnabled) 'Stop transition not entered.'
  # 方向守卫的另一半：停止中收到「运行中」必须丢弃，否则慢停止期间卡片会闪回运行中、
  # 关闭键重新点亮（用户还能对着正在停的服务再点一次）
  Update-CardData 'TestService' '运行中' '正常'
  Assert ($card.ST -eq '停止中') "Stop transition overwritten by reverse probe: ST=$($card.ST)."
  Assert (-not $card.BtnStop.IsEnabled -and -not $card.Btn.IsEnabled) 'Reverse probe re-enabled buttons mid-stop.'
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

  # ---- 2c. 失败回执的归属：别人命令的失败不许回滚当前过渡态 ----
  # 双击关闭 → 停止中（PendingEpoch=N）；期间右键「启动」入队（epoch=N+1，不置过渡态、
  # 不写 PendingEpoch）；后台启动失败 → 回执 e=N+1 ok=false。修前只看「卡片有没有
  # TransitionAt」，会把别人的停止中过渡态回滚成 PrevST=运行中，而停止命令仍在途。
  $card.LastToggle=[datetime]::MinValue
  $card.TransitionAt=[datetime]::MinValue
  Update-CardData 'TestService' '运行中' '正常'
  Invoke-CardToggle $card
  Assert ($card.ST -eq '停止中') "应进入停止中，got $($card.ST)"
  $pending = $card.PendingEpoch
  Update-CardData 'TestService' $null $null -e ($pending + 1) -ack -ok $false
  Assert ($card.ST -eq '停止中') "别人命令的失败回执不该回滚当前过渡态，got $($card.ST)"
  Assert (-not $card.Btn.IsEnabled) '误回滚后启动键被错误点亮'

  # ---- 3. 删除失败：不得永久停在「删除中」----
  $card.LastToggle=[datetime]::MinValue
  Update-CardData 'TestService' '已停止' ''
  $epoch=99
  Set-CardTransition $card '删除中' $epoch ([datetime]::Now)
  Assert ($card.ST -eq '删除中') 'Delete transition not entered.'
  # 删除没有「期望终态」：未超时时任何探测都不该改写
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

  # ---- 4c. 重启两段式（B2）：停止中 →（phase='start' 中间回执）→ 启动中 ----
  # 两点在这里才验得到：① 中间回执走真实的 Update-StatusTick 分流（直接调 Update-CardRestartPhase
  # 会让 util.ps1 里漏掉 phase 分支也照样绿）；② 探测不许从两个方向抢跑过渡态。
  $script:queue=[Collections.Concurrent.ConcurrentQueue[object]]::new()
  $script:msgQueue=[Collections.Concurrent.ConcurrentQueue[string]]::new()
  $script:svcState=@{}
  $script:healthSeen=@{}
  $card.LastToggle=[datetime]::MinValue
  $card.TransitionAt=[datetime]::MinValue
  Update-CardData 'TestService' '运行中' '正常'
  Invoke-CardRestart $card
  Assert ($card.ST -eq '停止中' -and -not $card.Btn.IsEnabled -and -not $card.BtnStop.IsEnabled) '重启应按停止处理（过渡态 + 双禁用）。'
  # 停止阶段探测仍报「运行中」（stop 还没生效）：方向守卫必须丢弃，否则按钮重新点亮
  Update-CardData 'TestService' '运行中' '正常'
  Assert ($card.ST -eq '停止中') "重启停止阶段被探测抢跑：ST=$($card.ST)"
  Assert (-not $card.Btn.IsEnabled) '重启停止阶段被探测点亮了启动键。'
  # 中间回执：必须经 Update-StatusTick 才换段
  $script:queue.Enqueue([pscustomobject]@{n='TestService';st=$null;h=$null;e=$card.PendingEpoch;phase='start'})
  Update-StatusTick
  Assert ($card.ST -eq '启动中' -and $card.LblSt.Text -eq '启动中') "中间回执没把过渡态换成启动中：ST=$($card.ST)"
  Assert (-not $card.Btn.IsEnabled -and -not $card.BtnStop.IsEnabled) '启动阶段按钮应保持禁用。'
  Assert ($script:svcState.Count -eq 0 -and $script:healthSeen.Count -eq 0) '中间回执不该落 svcState / 健康历史（它不是探测值）。'
  # 启动阶段探测报「已停止」（迟到的 stop 快照）：同样丢弃，否则卡片闪回停止态、按钮解封
  Update-CardData 'TestService' '已停止' ''
  Assert ($card.ST -eq '启动中') "重启启动阶段被滞后探测抢跑：ST=$($card.ST)"
  # 最终成功回执：不自行结束过渡态（等探测收敛），按钮保持禁用
  Update-CardData 'TestService' $null $null -e $card.PendingEpoch -ack -ok $true
  Assert ($card.ST -eq '启动中' -and -not $card.Btn.IsEnabled) "最终回执不该提前结束过渡态：ST=$($card.ST)"
  # 探测收敛到运行中 + 连续两次健康 → 回到运行中
  Update-CardData 'TestService' '运行中' '正常'
  Assert ($card.ST -eq '运行中') "探测收敛后应回到运行中：ST=$($card.ST)"
  # 第二次重启：启动阶段失败 → 回滚到「未知」而不是谎报某个终态，按钮立刻可用（探测 4 秒内纠正）
  $card.LastToggle=[datetime]::MinValue
  Invoke-CardRestart $card
  $script:queue.Enqueue([pscustomobject]@{n='TestService';st=$null;h=$null;e=$card.PendingEpoch;phase='start'})
  Update-StatusTick
  Assert ($card.ST -eq '启动中') "第二次重启应进入启动阶段：ST=$($card.ST)"
  Update-CardData 'TestService' $null $null -e $card.PendingEpoch -ack -ok $false
  Assert ($card.ST -eq '未知') "重启失败应回滚到「未知」（不谎报终态），got [$($card.ST)]"
  # 未知态不给启动键：这时服务到底停没停还没人确认，等下一拍探测（≤4s）再说
  Assert (-not $card.Btn.IsEnabled) '未知态不该点亮启动键'
  Update-CardData 'TestService' '已停止' ''
  Assert ($card.ST -eq '已停止' -and $card.Btn.IsEnabled) '探测确认已停止后启动键应可用'

  # ---- 5a. 两个方向的门闩真值表 ----
  Assert (Test-CardCanStart '已停止') '已停止应可启动。'
  Assert (-not (Test-CardCanStart '运行中')) '运行中不可再启动。'
  # 关闭只看状态：健康探测的失败原因太多（非 HTTP 服务、面板 401、抖动），接进按钮会锁死出口。
  # 健康门闩只保留在双击路径（Invoke-CardAction 的 $detailed 分支）。
  Assert (Test-CardCanStop '运行中') '运行中应可关闭（健康不参与按钮门闩）。'
  Assert (-not (Test-CardCanStop '已停止')) '已停止不可关闭。'
  Assert (-not (Test-CardCanStop '暂停中')) '暂停中不可关闭。'

  # ---- 5. ack 门闩按当前状态重算，不无条件点亮 ----
  # 右键菜单的启停直接 Send-ServiceCommand、不置过渡态，回执到达时卡片可能仍是终态。
  # 成功回执若硬置 ReadyToToggle=$true，一个已停止的服务会被点亮关闭按钮。
  $card.LastToggle=[datetime]::MinValue
  Update-CardData 'TestService' '已停止' ''
  Assert (-not $card.ReadyToToggle) 'Stopped card should not be toggle-ready.'
  Update-CardData 'TestService' $null $null -e 0 -ack -ok $true
  Assert (-not $card.ReadyToToggle) "Success ack armed a stopped card: ReadyToToggle=$($card.ReadyToToggle)."
  Assert (-not $card.BtnStop.IsEnabled) 'Success ack enabled the close button on a stopped service.'
  # 运行中但健康未过：关闭按钮必须可用（这是 P0-1 的修复点，健康只管双击）
  Update-CardData 'TestService' '运行中' '无响应'
  Assert ($card.ReadyToToggle -and $card.BtnStop.IsEnabled) 'Unhealthy running card must stay closable from the button.'

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

  Write-Output 'PASS: transition states have a failure exit (rollback on ok=false, timeout escape, queue-independent sweep); restart switches 停止中→启动中 on the phase receipt via Update-StatusTick, and probes cannot pre-empt it in either phase; no permanent card lock.'
} finally { $win.Close(); $script:sync.wake.Dispose() }

