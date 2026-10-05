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
  Assert ($card.Btn.IsEnabled) 'Failed stop left button disabled.'
  Assert ($card.Btn.Content -eq '停止') "Failed stop button label wrong: $($card.Btn.Content)."
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
  # 超时后按到达的探测值收敛（回执彻底丢了时的最后逃生口）
  $card.TransitionAt=[datetime]::Now.AddMilliseconds(-($script:TOGGLE_TIMEOUT_MS+1000))
  Update-CardData 'TestService' '运行中' '正常'
  Assert ($card.ST -eq '运行中') "Timed-out delete did not converge: ST=$($card.ST)."
  Assert ($card.Btn.IsEnabled) 'Timed-out delete left button disabled.'

  Write-Output 'PASS: transition states have a failure exit (rollback on ok=false, timeout escape); no permanent card lock.'
} finally { $win.Close(); $script:sync.wake.Dispose() }

