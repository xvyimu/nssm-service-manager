#requires -Version 7.0
# 端到端接缝：**真 runspace 产出的删除回执 → 真 UI tick 消费**。
#
# 为什么单开一份：test-remove-async.ps1 把两半各自单测了——
#   第 2/3 段测 runspace 侧产出什么回执；第 1/4 段测 UI 侧拿到（手搓的）回执怎么处理。
# 中间那一跳（worker 的回执真的落进 UI 队列）从没被验过：两段用的是不同队列对象。
# 提示词建议「手动点一次删除服务走完整流程（含失败注入）」验的正是这个接缝；
# 这里用共享队列把两半接起来，比人工点击更可复现，也不需要可交互的提权 GUI。
#
# 两个方向都覆盖：
#   删除成功（服务真消失）    -> UI 清 svc/cards 并落盘
#   删除失败（nssm 谎报 0 而服务仍在） -> UI 回滚卡片、保留服务、不落盘
param([string]$RepoRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
foreach ($module in 'theme','util','svc-input','nssm','card','xaml','dialogs','poll') { . (Join-Path $RepoRoot "lib/$module.ps1") }
. (Join-Path $RepoRoot 'tests/test-helpers.ps1')
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }

function Invoke-RemoveSeam([bool]$serviceGone, [string]$label) {
  # 探测间隔拉长，避免整轮探测结果挤进队列干扰断言
  $worker = Start-FakePoll 1 'Stopped' 0 @{ probeIntervalMs = 60000; probeIdleMs = 60000 }
  if ($serviceGone) { $worker.Sync.serviceGone = $true }   # sc query 返回 1060 = 服务已消失
  try {
    # 把 UI 的命令/结果队列**指向 worker 的**：Send-ServiceCommand 入 worker.cmd，
    # worker 产出的回执直接落进 UI 的 $script:queue —— 这一跳就是被测的接缝。
    $script:sync     = $worker.Sync
    $script:cmdQueue = $worker.Sync.cmd
    $script:queue    = $worker.Sync.queue
    $script:msgQueue = $worker.Sync.msg   # 失败原因也走 worker 的队列，才能被 UI tick 排空
    $script:svc      = [ordered]@{Fake0=@{port=10000;url='http://127.0.0.1:10000'}}
    $script:cmdEpoch = 0
    $script:saved    = $null
    function Save-Svc($data) { $script:saved=$data }
    function Stop-Background {}

    Assert ($worker.Sync.probeStarted.WaitOne(3000)) "${label}: worker did not start."
    $win = New-MainWindow
    try {
      Render-Page
      $card = $script:cards['Fake0']
      Assert ($card -ne $null) "${label}: card not created."
      # 先给卡片一个真实稳态（真实流程里它已被探测过），再模拟 del_Click
      Update-CardData 'Fake0' '已停止' ''
      $epoch = Send-ServiceCommand 'Fake0' 'remove'
      Set-CardTransition $card '删除中' $epoch (Get-Date)
      Assert ($card.ST -eq '删除中') "${label}: card not in delete transition."

      # 等 worker 把 remove 跑完（executed 里出现 nssm），回执紧随其后入队
      $deadline = [datetime]::UtcNow.AddSeconds(6)
      while (($worker.Sync.executed | Where-Object { $_.action -eq 'nssm' }).Count -lt 1 -and [datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 25
      }
      Assert (($worker.Sync.executed | Where-Object { $_.action -eq 'nssm' }).Count -ge 1) "${label}: worker never reached nssm remove."
      Start-Sleep -Milliseconds 150   # 让回执 Enqueue 落定

      # 真 UI tick 消费真回执（它自己从 $script:queue 排空）
      Update-StatusTick

      if ($serviceGone) {
        Assert (-not $script:svc.Contains('Fake0'))  "${label}: svc not cleared on successful remove."
        Assert (-not $script:cards.Contains('Fake0')) "${label}: cards not cleared on successful remove."
        Assert ($script:saved -ne $null)             "${label}: Save-Svc not called on successful remove."
      } else {
        Assert ($script:svc.Contains('Fake0'))       "${label}: svc wrongly cleared on failed remove."
        Assert ($script:cards.Contains('Fake0'))     "${label}: cards wrongly cleared on failed remove."
        Assert ($card.ST -ne '删除中')                "${label}: card stuck in 删除中: ST=$($card.ST)."
        Assert ($card.Btn.IsEnabled)                 "${label}: button not re-enabled after failed remove."
        Assert ($script:saved -eq $null)             "${label}: Save-Svc must not run on failed remove."
        # 失败原因由后台 msg 队列给出，Update-StatusTick 在同一帧把它排空写进状态栏
        # （并带显示租约）——所以断言打在状态栏上，那才是用户看到的。
        Assert ($script:statusBar.Text -match '删除失败') "${label}: no failure feedback on status bar: '$($script:statusBar.Text)'"
        Assert ($script:msgUntil -gt [datetime]::Now)    "${label}: failure feedback took no display lease."
      }
      Write-Output "PASS: $label (serviceGone=$serviceGone)."
    } finally { $win.Close() }
  } finally { Close-FakePoll $worker }
}

Invoke-RemoveSeam $true  'remove success end-to-end'
Invoke-RemoveSeam $false 'remove failure end-to-end'

Write-Output 'PASS: real runspace ack drives real UI tick — success clears svc/cards, failure rolls the card back and keeps the service.'
