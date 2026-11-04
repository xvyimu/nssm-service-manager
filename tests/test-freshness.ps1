#requires -Version 7.0
# P1-2 回归：陈旧样本必须显示「状态未知」。
# 背景：worker 采样时刻（at）随结果回传后，UI 仍可能因为后台被限流、或卡在一条外部命令上，
# 拿着 30 秒前的样本继续显示「运行中·正常」——那是整屏在说谎，用户按「停止」却发现早停了。
# Update-CardFreshness 负责按「2 × ProbeIntervalMs」把陈旧样本降级为「状态未知」并禁用写操作；
# 它同时不能误伤两类卡片：刚拿到新样本的卡、以及走自己超时逃生通道的过渡态卡。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
foreach ($module in 'theme','util','card','xaml') { . (Join-Path $RepoRoot "lib/$module.ps1") }
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
# Write-CrashLog 由 GUI 入口定义（service-manager-gui.ps1）；单测不落盘。
function Write-CrashLog([string]$m) { }
function Stop-Background { }

$script:svc = @{ A = @{ port = 1; url = '' } }
$script:sync = @{ gate = [object]::new(); svc = $script:svc }
$script:svcState = @{}
$script:cards = @{}
$script:curPage = 0
$script:queue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:msgQueue = [Collections.Concurrent.ConcurrentQueue[string]]::new()

$win = New-MainWindow
try {
  Render-Page
  $card = $script:cards['A']
  Assert ($null -ne $card) '夹具：A 的卡片应已创建'
  $interval = [int]$script:config.ProbeIntervalMs
  Assert ($interval -gt 0) "夹具：ProbeIntervalMs 应为正数，实际 $interval"

  # ---- A. 30 秒前的样本（> 2 × ProbeIntervalMs = 8s）必须降级为「状态未知」 ----
  Update-CardData 'A' '运行中' '正常'
  Assert ($card.LblSt.Text -eq '运行中') "夹具：应先进入正常态，实际「$($card.LblSt.Text)」"
  Assert ($card.BtnStop.IsEnabled -and $card.ReadyToToggle) '夹具：正常态下「停止」应可用'
  $script:svcState['A'] = @{ st = '运行中'; h = '正常'; at = (Get-Date).AddSeconds(-30) }
  Update-CardFreshness $card (Get-Date)
  Assert ($card.LblSt.Text -eq '状态未知') "陈旧样本必须显示「状态未知」，实际「$($card.LblSt.Text)」"
  Assert ($card.Btn.IsEnabled -eq $false) '陈旧样本必须禁用主按钮（不能拿旧状态继续发命令）'
  Assert ($card.BtnStop.IsEnabled -eq $false) '陈旧样本必须禁用「停止」（运行中的停止按钮也要收掉）'
  Assert ($card.Stale -eq $true) '陈旧样本应标记 Stale'
  Write-Output 'PASS: 30s 前的样本被降级为「状态未知」且禁用写操作'
  Write-Output 'PASS: 降级样本 Stale=$true'

  # ---- B. at=now 的新样本不得被降级 ----
  Update-CardData 'A' '运行中' '正常'   # Freshness 只降级不还原显示，先复位
  Assert ($card.LblSt.Text -eq '运行中') "夹具：复位失败，实际「$($card.LblSt.Text)」"
  $script:svcState['A'] = @{ st = '运行中'; h = '正常'; at = (Get-Date) }
  Update-CardFreshness $card (Get-Date)
  Assert ($card.Stale -eq $false) '新样本不得标记 Stale'
  Assert ($card.LblSt.Text -ne '状态未知') "新样本不得被改成「状态未知」，实际「$($card.LblSt.Text)」"
  Write-Output 'PASS: at=now 的新样本不被降级（Stale=$false，文案不变未知）'

  # ---- C. 过渡态（启动中）走自己的超时逃生，不被陈旧判定降级 ----
  Set-CardTransition $card '启动中' 1 (Get-Date)
  Assert ($card.ST -eq '启动中') "夹具：应进入启动中过渡态，实际「$($card.ST)」"
  Assert ($card.LblSt.Text -eq '启动中') "夹具：卡片文案应为启动中，实际「$($card.LblSt.Text)」"
  $script:svcState['A'] = @{ st = '运行中'; h = '正常'; at = (Get-Date).AddSeconds(-30) }
  Update-CardFreshness $card (Get-Date)
  Assert ($card.LblSt.Text -ne '状态未知') "过渡态不得被陈旧判定降级，实际「$($card.LblSt.Text)」"
  Assert ($card.Stale -eq $false) '过渡态不应标记 Stale（超时由 Invoke-TransitionTimeoutEscape 管）'
  Write-Output 'PASS: 过渡态卡片不被陈旧判定降级'

  # ---- D. 无探测记录（首帧）不得报错、不得显示未知 ----
  Update-CardData 'A' '运行中' '正常'
  Assert ($card.ST -eq '运行中') "夹具：复位失败，实际「$($card.ST)」"
  $script:svcState = @{}
  Update-CardFreshness $card (Get-Date)
  Assert ($card.LblSt.Text -eq '运行中') "无记录时不得显示未知，实际「$($card.LblSt.Text)」"
  Assert (-not $card.Stale) '无记录时不应标记 Stale'
  Write-Output 'PASS: svcState 为空时不报错、不显示未知'
} finally {
  try { $win.Close() } catch { }
}
Write-Output 'PASS: 陈旧样本新鲜度判定（4 例）'
