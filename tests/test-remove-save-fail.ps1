#requires -Version 7.0
# P2-3 回归：清单保存失败时不得先抹掉卡片。
# 背景：原序 stop → wait → remove → 实证 → 内存删 → save。保存失败时界面已经宣称「已删除」，
# 磁盘却仍留着条目，下次启动又冒出来（探针 CardRemoved=true 复现过）。
# 现序：先写盘成功、再改内存/卡片；写盘失败 → 卡片保留并标「待保存」，给右键「重试保存清单」。
# 反向用例守另一头：保存成功时条目与卡片都必须真的消失（别把「保留」写成「永不删除」）。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
foreach ($module in 'theme','util','card','xaml') { . (Join-Path $RepoRoot "lib/$module.ps1") }
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
# Write-CrashLog 由 GUI 入口定义（service-manager-gui.ps1）；单测不落盘。
function Write-CrashLog([string]$m) { }
function Stop-Background { }

$script:svc = [ordered]@{ A = @{ port = 1; url = '' } }
$script:sync = @{ gate = [object]::new(); svc = $script:svc }
$script:cards = @{}
$script:curPage = 0
$script:queue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:msgQueue = [Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:healthSeen = @{}
$script:healthQueue = $null
$script:svcState = @{ A = @{ st = '已停止'; h = ''; at = (Get-Date) } }
$script:lastActionAt = $null
$script:msgUntil = $null
$script:bgHandle = $null
$script:bgDeathReported = $false

# Save-Svc 由 util.ps1 定义；这里在点源之后同名重定义即覆盖（脚本作用域内后定义者生效）。
$script:saveAttempt = $null
$script:saved = $null

$win = New-MainWindow
try {
  Render-Page
  Assert ($script:cards.ContainsKey('A')) '夹具：A 的卡片应已创建'
  Update-CardData 'A' '已停止' ''
  Assert ($script:cards['A'].ST -eq '已停止') "夹具：A 应为已停止，实际「$($script:cards['A'].ST)」"

  # ---- 1. 保存失败：卡片保留、内存清单不动、状态栏说清原因 ----
  function Save-Svc($s) { $script:saveAttempt = $s; throw 'disk full' }
  $script:queue.Enqueue(@{ n = 'A'; act = 'remove'; done = $true; ok = $true; e = 1 })
  Update-StatusTick
  Assert ($script:svc.Contains('A')) '保存失败时不得从内存清单抹掉条目'
  Assert ($script:cards.ContainsKey('A')) '保存失败时不得移除卡片'
  Assert ($script:cards['A'].PendingSave -eq $true) '保存失败时卡片应标记 PendingSave'
  Assert ($script:cards['A'].ST -eq '待保存') "保存失败时卡片状态应为「待保存」，实际「$($script:cards['A'].ST)」"
  Assert ($script:null -ne $script:saveAttempt -and $script:saveAttempt.Count -eq 0) '应先尝试把「删掉 A 之后」的副本写盘'
  Assert ($script:statusBar.Text -match '清单保存失败|清单未保存') "状态栏应提示清单保存失败，实际「$($script:statusBar.Text)」"
  Write-Output 'PASS: 保存失败时条目与卡片保留、卡片标记 PendingSave、状态栏提示'

  # ---- 2. 保存成功：条目与卡片都被移除 ----
  $script:svc['B'] = @{ port = 2; url = '' }
  Render-Page
  Assert ($script:cards.ContainsKey('B')) '夹具：B 的卡片应已创建'
  Update-CardData 'B' '已停止' ''
  function Save-Svc($s) { $script:saved = $s }   # 覆盖成成功路径
  $script:queue.Enqueue(@{ n = 'B'; act = 'remove'; done = $true; ok = $true; e = 1 })
  Update-StatusTick
  Assert (-not $script:svc.Contains('B')) '保存成功后应从内存清单移除 B'
  Assert (-not $script:cards.ContainsKey('B')) '保存成功后应移除 B 的卡片（不存在 PendingSave 卡）'
  Assert ($null -ne $script:saved -and -not $script:saved.Contains('B')) '写盘内容应已不含 B'
  Assert ($script:saved.Contains('A')) '写盘内容应仍保留 A（待保存那条不动）'
  Assert ($script:cards.ContainsKey('A')) 'A 的待保存卡片不应被 B 的删除带走'
  Assert ($script:statusBar.Text -match 'B 已删除') "状态栏应报告 B 已删除，实际「$($script:statusBar.Text)」"
  Write-Output 'PASS: 保存成功时条目与卡片都被移除、写盘内容正确'
} finally {
  try { $win.Close() } catch { }
}
Write-Output 'PASS: 删除回执的保存失败/成功两条路径'
