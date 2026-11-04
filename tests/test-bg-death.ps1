#requires -Version 7.0
# P1-3 回归：后台 runspace 结束后，**所有**卡片都必须转「未知」并禁用动作。
# 背景：原来只把「查询中」改成未知，其余卡继续显示上一次的「运行中/正常」，加上状态栏还在
# 每 4 秒打「状态自动刷新」，整屏看着是活的（探针 CardStillSaysRunning=true 复现过）。
# 这里验两件事：① 死亡当帧全部卡片转未知 + 状态栏说人话；② 只报告一次，后续帧不得重复覆盖文案。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
foreach ($module in 'theme','util','card','xaml') { . (Join-Path $RepoRoot "lib/$module.ps1") }
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
# Write-CrashLog 由 GUI 入口定义（service-manager-gui.ps1）；单测不落盘。
function Write-CrashLog([string]$m) { }
function Stop-Background { }

$script:svc = [ordered]@{ A = @{ port = 1; url = '' }; B = @{ port = 2; url = '' } }
$script:sync = @{ gate = [object]::new(); svc = $script:svc }
$script:svcState = @{}
$script:healthSeen = @{}
$script:healthQueue = $null
$script:cards = @{}
$script:curPage = 0
$script:queue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:msgQueue = [Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:bgHandle = $null
$script:bgDeathReported = $false
$script:lastActionAt = $null
$script:msgUntil = $null

$win = New-MainWindow
try {
  Render-Page
  foreach ($n in 'A','B') { Assert ($null -ne $script:cards[$n]) "夹具：$n 的卡片应已创建" }

  # ---- 1. 先让两张卡都进入正常态（模拟后台活着时刚推过一拍结果） ----
  $now = Get-Date
  $script:queue.Enqueue(@{ n = 'A'; st = '运行中'; h = '正常'; at = $now })
  $script:queue.Enqueue(@{ n = 'B'; st = '运行中'; h = '正常'; at = $now })
  Update-StatusTick
  foreach ($n in 'A','B') {
    Assert ($script:cards[$n].ST -eq '运行中') "夹具：$n 应先运行中，实际「$($script:cards[$n].ST)」"
    Assert ($script:cards[$n].BtnStop.IsEnabled -and $script:cards[$n].ReadyToToggle) "夹具：$n 的「停止」应可用"
  }
  Write-Output 'PASS: 夹具进入正常态（A/B 均运行中且按钮可用）'

  # ---- 2. 后台结束：全部卡片转未知、按钮禁用、状态栏报「后台已停止响应」 ----
  $script:bgHandle = [pscustomobject]@{ IsCompleted = $true }
  $script:bgDeathReported = $false
  Update-StatusTick
  foreach ($n in 'A','B') {
    Assert ($script:cards[$n].ST -eq '未知') "后台死亡后 $n 应显示未知，实际「$($script:cards[$n].ST)」"
    Assert ($script:cards[$n].LblSt.Text -eq '状态未知') "后台死亡后 $n 文案应为状态未知，实际「$($script:cards[$n].LblSt.Text)」"
    Assert ($script:cards[$n].Btn.IsEnabled -eq $false) "后台死亡后 $n 主按钮必须禁用"
    Assert ($script:cards[$n].BtnStop.IsEnabled -eq $false) "后台死亡后 $n「停止」必须禁用"
    Assert ($script:cards[$n].Stale -eq $true) "后台死亡后 $n 应标记 Stale"
  }
  Assert ($script:bgDeathReported -eq $true) '后台死亡应置 bgDeathReported'
  Assert ($script:statusBar.Text -match '后台已停止响应') "状态栏应提示后台已停止响应，实际「$($script:statusBar.Text)」"
  Write-Output 'PASS: 后台结束后 A/B 全部转未知、按钮禁用、状态栏提示'

  # ---- 3. 再一拍：不重复报告、文案不被覆盖 ----
  $report = $script:statusBar.Text
  Update-StatusTick
  Assert ($script:bgDeathReported -eq $true) '第二拍 bgDeathReported 应保持 true'
  Assert ($script:statusBar.Text -eq $report) "第二拍不得覆盖状态栏文案，实际「$($script:statusBar.Text)」"
  foreach ($n in 'A','B') {
    Assert ($script:cards[$n].ST -eq '未知') "第二拍 $n 仍应是未知，实际「$($script:cards[$n].ST)」"
  }
  Write-Output 'PASS: 第二拍不重复报告、文案不被自动刷新覆盖'

  # ---- 4. 死前残样本不得把「未知」写回运行中 ----
  # 后台结束前最后一批结果可能还在队列里。bgDeathReported 已挡住新鲜度降级，
  # 若这些结果还能被应用，卡片就永久假装活着——正是 P1 要消灭的形态。
  $script:queue.Enqueue([pscustomobject]@{ n='A'; st='运行中'; h='正常'; at=[datetime]::Now })
  Update-StatusTick
  Assert ($script:cards['A'].ST -eq '未知') "残样本不得覆写离线态，实际「$($script:cards['A'].ST)」"
  Assert ($script:cards['A'].LblSt.Text -eq '状态未知') '残样本不得改写离线文案'
  Write-Output 'PASS: 后台死后的残样本被拒绝应用，卡片保持未知'
} finally {
  try { $win.Close() } catch { }
}
Write-Output 'PASS: 后台死亡处理（全员转未知 + 单次报告）'
