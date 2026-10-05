#requires -Version 7.0
# 任务 A 的新增回归：删除服务走后台命令队列（act=remove），不再 UI 线程同步 stop+wait+remove。
# 验证三段：
#   1. Show-Remove 的 del_Click 入队 remove 命令（带 epoch），不立即改 svc/cards。
#   2. runspace 侧 remove action 调 stop→Wait-Stopped→nssm remove confirm（用 Start-FakePoll 验）。
#   3. UI 侧 DispatcherTimer 收到 done+act=remove 回执后清 svc/cards、Save-Svc、Render-Page。
param([string]$RepoRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
foreach ($module in 'theme','util','svc-input','nssm','card','xaml','dialogs') { . (Join-Path $RepoRoot "lib/$module.ps1") }
. (Join-Path $RepoRoot 'tests/test-helpers.ps1')
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }

# ---- 1. del_Click 入队 remove，不立即改 svc/cards ----
$script:sync=@{gate=[object]::new(); wake=[Threading.AutoResetEvent]::new($false); nssm='Invoke-TestNssm'}
$script:svc=[ordered]@{RmSvc=@{port=9000;url='http://127.0.0.1:9000'}}
$script:cmdQueue=[Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:queue=[Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:msgQueue=[Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:cmdEpoch=0
function Stop-Background {}
function Save-Svc($data) { $script:saved=$data }  # 替身
function Invoke-TestNssm { $global:LASTEXITCODE=0 }
function sc.exe { $global:LASTEXITCODE=0 }
$script:nssm='Invoke-TestNssm'

$win=New-MainWindow
try {
  Render-Page
  $card=$script:cards['RmSvc']
  Assert ($card -ne $null) 'Card not created for RmSvc.'

  # del_Click 的真实路径是 Set-CardTransition $card '删除中' $epoch (Get-Date)——
  # Show-Remove 弹模态框测不了，但它调的正是这个函数，故直接调它并断言卡片状态。
  $epoch = Send-ServiceCommand 'RmSvc' 'remove'
  Assert ($epoch -gt 0) 'Send-ServiceCommand did not return a positive epoch.'
  Set-CardTransition $card '删除中' $epoch (Get-Date)
  Assert ($card.ST -eq '删除中') 'del_Click path did not put card into 删除中.'
  Assert (-not $card.Btn.IsEnabled) 'Card button enabled while deleting.'
  Assert (-not $card.ReadyToToggle) 'Card ReadyToToggle set while deleting.'
  Assert ($script:cmdQueue.Count -eq 1) 'Remove command was not enqueued.'
  $cmd=$null; [void]$script:cmdQueue.TryDequeue([ref]$cmd)
  Assert ($cmd.act -eq 'remove' -and $cmd.e -eq $epoch) "Enqueued command wrong: act=$($cmd.act) e=$($cmd.e) epoch=$epoch"
  # 删除中的过渡态必须扛过 Render-Page（右键菜单路径是 Show-Remove; Render-Page）与探测结果
  Render-Page
  Assert ($script:cards['RmSvc'].ST -eq '删除中') "Render-Page reset 删除中 to $($script:cards['RmSvc'].ST)."
  Update-CardData 'RmSvc' '已停止' ''
  Assert ($script:cards['RmSvc'].ST -eq '删除中') "Probe overwrote 删除中: $($script:cards['RmSvc'].ST)."
  # svc 与 cards 在 ack 回执到来前不应被清理
  Assert ($script:svc.Contains('RmSvc')) 'svc cleared before ack arrived.'
  Assert ($script:cards.Contains('RmSvc')) 'cards cleared before ack arrived.'

  # ---- 3. 模拟 DispatcherTimer 收到 done+act=remove 回执 ----
  $ackItem = [pscustomobject]@{n='RmSvc';st=$null;h=$null;e=$epoch;done=$true;act='remove';ok=$true}
  $script:queue.Enqueue($ackItem)
  # 调真实实现（lib/util.ps1 Update-StatusTick）而非复刻：T4 把 tick 抽出后这里能直测生产代码，
  # 不再抄一份逻辑——抄本与实现漂移是静默失效的常见来源（本段此前就是这么坏的）。
  $script:msgQueue=[Collections.Concurrent.ConcurrentQueue[string]]::new()
  Update-StatusTick
  Assert (-not $script:svc.Contains('RmSvc')) 'svc not cleared after remove ack.'
  Assert (-not $script:cards.Contains('RmSvc')) 'cards not cleared after remove ack.'
  Assert ($script:cardPanel.Children.Count -eq 0) 'Card still visible after remove ack.'

  Write-Output 'PASS: remove enqueues to background (not synchronous); ack clears svc/cards/panel.'
} finally { $win.Close(); $script:sync.wake.Dispose() }

# ---- 2. runspace 侧 remove action 调 stop→Wait-Stopped→nssm remove confirm ----
. (Join-Path $RepoRoot 'lib/poll.ps1')
$worker=Start-FakePoll 1 'Stopped'
try {
  Assert ($worker.Sync.probeStarted.WaitOne(3000)) 'Worker did not start.'
  $worker.Sync.cmd.Enqueue([pscustomobject]@{n='Fake0';act='remove';e=1})
  [void]$worker.Sync.wake.Set()
  # 等待 executed 队列里出现 stop 与 nssm 两条记录
  $deadline=[datetime]::UtcNow.AddSeconds(5)
  while (($worker.Sync.executed | Where-Object { $_.action -in @('stop','nssm') }).Count -lt 2 -and [datetime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 50
  }
  $actions = @($worker.Sync.executed | ForEach-Object { $_.action })
  Assert ($actions -contains 'stop') "runspace remove did not call sc.exe stop: $($actions -join ',')"
  Assert ($actions -contains 'nssm') "runspace remove did not call nssm remove confirm: $($actions -join ',')"
  # stop 必须在 nssm 之前
  $stopIdx = [Array]::IndexOf($actions, 'stop')
  $nssmIdx = [Array]::IndexOf($actions, 'nssm')
  Assert ($stopIdx -lt $nssmIdx) "stop must precede nssm remove: stop=$stopIdx nssm=$nssmIdx"
  # 回执必须带 done+act=remove
  $ack=$null
  $deadline=[datetime]::UtcNow.AddSeconds(2)
  while ($worker.Sync.queue.IsEmpty -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
  [void]$worker.Sync.queue.TryDequeue([ref]$ack)
  Assert ($ack -ne $null -and $ack.done -eq $true -and $ack.act -eq 'remove') "ack wrong: $ack"
  Assert ($ack.e -eq 1) "ack epoch mismatch: got $($ack.e)"
  Assert ($worker.PowerShell.Streams.Error.Count -eq 0) 'Background errors present during remove.'
  Write-Output 'PASS: runspace remove action runs stop→Wait-Stopped→nssm remove confirm; ack carries done+act+epoch.'
} finally { Close-FakePoll $worker }
