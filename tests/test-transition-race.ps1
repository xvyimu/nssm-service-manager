#requires -Version 7.0
# 发现 3 的红测试：卡片处于启动中/停止中过渡态时，在途探测结果覆盖过渡态并重新启用按钮。
# 修前：红（Update-CardData 无条件覆盖 ST，旧探测把「启动中」刷回「已停止」并启用按钮）。
# 修后：绿（过渡态期间 Update-CardData 只更新健康文案，不覆盖 ST、不动按钮启用态）。
param([string]$RepoRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
foreach ($module in 'theme','util','card','xaml') { . (Join-Path $RepoRoot "lib/$module.ps1") }
$script:sync=@{wake=[Threading.AutoResetEvent]::new($false)}
$script:svc=[ordered]@{TestService=@{port=8080;url='http://127.0.0.1:8080'}}
$script:cmdQueue=[Collections.Concurrent.ConcurrentQueue[object]]::new()
function Stop-Background {}
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }

$win=New-MainWindow
try {
  Render-Page
  $card=$script:cards['TestService']

  # ---- 启动方向：已停止 → 启动中 ----
  Update-CardData 'TestService' '已停止' ''
  Assert ($card.ST -eq '已停止' -and $card.Btn.Content -eq '启动') 'Initial stopped state not set.'
  Invoke-CardToggle $card
  Assert ($card.ST -eq '启动中' -and -not $card.Btn.IsEnabled) 'Start transition not entered.'
  Assert ($card.Btn.Content -eq '启动中') 'Transition button label wrong.'

  # 在途的旧探测结果到达：服务还没真正起来，Get-Service 仍返回 Stopped。
  # 修前：覆盖回「已停止」并重新启用按钮（红）；修后：保留过渡态。
  Update-CardData 'TestService' '已停止' ''
  Assert ($card.ST -eq '启动中') "In-flight probe overwrote start transition: ST=$($card.ST)."
  Assert (-not $card.Btn.IsEnabled) "In-flight probe re-enabled button during start transition."
  Assert ($card.Btn.Content -eq '启动中') "Button label reverted during start transition: $($card.Btn.Content)."

  # ---- 停止方向：运行中 → 停止中 ----
  # 先重置冷却，再进入运行中健康态
  $card.LastToggle=[datetime]::MinValue
  Update-CardData 'TestService' '运行中' '正常'
  Assert ($card.ST -eq '运行中' -and $card.ReadyToToggle) 'Running+healthy not armed.'
  Invoke-CardToggle $card
  Assert ($card.ST -eq '停止中' -and -not $card.Btn.IsEnabled) 'Stop transition not entered.'

  # 在途旧探测：服务还在停，Get-Service 仍返回 Running。
  Update-CardData 'TestService' '运行中' '正常'
  Assert ($card.ST -eq '停止中') "In-flight probe overwrote stop transition: ST=$($card.ST)."
  Assert (-not $card.Btn.IsEnabled) "Button re-enabled during stop transition."
  Assert ($card.Btn.Content -eq '停止中') "Button label reverted during stop transition: $($card.Btn.Content)."

  # ---- 过渡态结束后，终态探测应正常应用 ----
  # 停止中的期望终态是「已停止」——先喂它收尾，过渡态退出。
  Update-CardData 'TestService' '已停止' ''
  Assert ($card.ST -eq '已停止' -and $card.Btn.IsEnabled) 'Stop terminal not applied.'
  # 再测一轮启动过渡：已停止→启动中→运行中
  $card.LastToggle=[datetime]::MinValue
  Invoke-CardToggle $card
  Assert ($card.ST -eq '启动中' -and -not $card.Btn.IsEnabled) 'Start transition not re-entered.'
  Update-CardData 'TestService' '运行中' '正常'
  Assert ($card.ST -eq '运行中' -and $card.Btn.IsEnabled) 'Terminal state not applied after transition.'
  Assert ($card.Btn.Content -eq '停止') 'Terminal button label wrong.'

  Write-Output 'PASS: in-flight probe results do not overwrite transition states; terminal state still applies.'
} finally { $win.Close(); $script:sync.wake.Dispose() }
