#requires -Version 7.0
# 窗口布局：列数按宽度自适应（先减列不压卡）、尺寸/位置记忆的读取与夹取、关窗快照。
# 全是纯函数与文件往返，不碰 NSSM/服务；窗口对象只在快照用例里出现，且挂在屏幕外。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
foreach ($module in 'theme','util','card','xaml') { . (Join-Path $RepoRoot "lib/$module.ps1") }
. (Join-Path $PSScriptRoot 'test-helpers.ps1')

# 本机 config.json 会覆盖 CardMinWidth / CardMinHeight 等默认值——测的是「默认行为」，先挪开再还原。
$repoConfig = Join-Path $RepoRoot 'config.json'
$configBackup = $null
if (Test-Path -LiteralPath $repoConfig) {
  $configBackup = Join-Path ([IO.Path]::GetTempPath()) ('sm-window-layout-config-' + [guid]::NewGuid().ToString('N') + '.json')
  Move-Item -LiteralPath $repoConfig $configBackup -Force
  $script:config = $null
  . (Join-Path $RepoRoot 'lib/config.ps1')
}

try {

# 夹具工作区：1920×1080，原点 0,0（不与真机工作区耦合）
$wa = [pscustomobject]@{ Width = 1920; Height = 1080; Left = 0; Top = 0 }

# ---- 1. 列数：只按数量时保持原有分档，且行数能把全部卡片装下 ----
$cases = @(
  @(0,1), @(1,1), @(2,2), @(3,3), @(4,4), @(5,3), @(6,3), @(7,4), @(8,4), @(9,3), @(12,4)
)
foreach ($c in $cases) {
  $cols = Get-GridColumns $c[0]
  Assert ($cols -eq $c[1]) "count=$($c[0]) 应排 $($c[1]) 列，实际 $cols"
  $rows = [int][math]::Ceiling($c[0] / $cols)
  Assert (($cols * $rows) -ge $c[0]) "count=$($c[0]) 排成 $($rows)×$cols 装不下"
}

# ---- 2. 列数：宽度不够时先减列（卡片不被压到 CardMinWidth 以下）----
Assert ((Get-GridColumns 7 500 240 4) -eq 2) '500px 宽只放得下 2 张 240px 的卡'
Assert ((Get-GridColumns 7 2000 240 4) -eq 4) '再宽也停在 MaxGridColumns=4'
Assert ((Get-GridColumns 6 100 240 4) -eq 1) '宽度连一张卡都不够时仍给 1 列'
Assert ((Get-GridColumns 3 2000 240 2) -eq 2) 'maxCols 上限对宽窗口同样生效'
# 任何宽度下都不超过「数量 / 宽度 / 配置上限」三者最小值
foreach ($n in 1..15) {
  foreach ($w in 0, 300, 700, 1200, 2400) {
    $cols = Get-GridColumns $n $w 240 4
    Assert ($cols -ge 1) "count=$n width=$w 列数应 ≥1"
    Assert ($cols -le $n) "count=$n width=$w 列数不应超过服务数"
    Assert ($cols -le 4) "count=$n width=$w 列数不应超过上限 4"
  }
}

# ---- 3. 放置：无记忆用默认尺寸并居中 ----
$p = Get-WindowPlacement $null $wa
Assert ($p.Width -eq 1040 -and $p.Height -eq 640) "默认应为 1040×640，实际 $($p.Width)×$($p.Height)"
Assert ($null -eq $p.Left -and $null -eq $p.Top) '无记忆时不应指定位置（交给 CenterScreen）'
Assert (-not $p.Maximized) '无记忆时不应最大化'

# ---- 4. 放置：记忆值夹到工作区与最小可用尺寸之间 ----
$p = Get-WindowPlacement ([pscustomobject]@{ width = 5000; height = 4000; left = 10; top = 10 }) $wa
Assert ($p.Width -eq 1920 -and $p.Height -eq 1080) "超出工作区应夹回 1920×1080，实际 $($p.Width)×$($p.Height)"
Assert ($p.Left -eq 10 -and $p.Top -eq 10) '还在屏内的坐标应保留'

$p = Get-WindowPlacement ([pscustomobject]@{ width = 100; height = 100 }) $wa
Assert ($p.Width -eq 840 -and $p.Height -eq 540) "小于最小可用尺寸应抬到 840×540，实际 $($p.Width)×$($p.Height)"

# ---- 5. 放置：屏幕外的旧坐标不恢复（拔掉外接屏的场景）----
$p = Get-WindowPlacement ([pscustomobject]@{ width = 1040; height = 640; left = 5000; top = 5000 }) $wa
Assert ($null -eq $p.Left -and $null -eq $p.Top) '完全在屏外的坐标应丢弃，退回居中'

# ---- 6. 放置：坏值当没有；最大化标志原样带回 ----
$p = Get-WindowPlacement ([pscustomobject]@{ width = 'abc'; height = ''; left = 'x'; top = 'y' }) $wa
Assert ($p.Width -eq 1040 -and $p.Height -eq 640) '坏尺寸应回落默认值'
Assert ($null -eq $p.Left) '坏坐标不应把窗口钉到 0,0'

$p = Get-WindowPlacement ([pscustomobject]@{ width = 1200; height = 800; maximized = $true }) $wa
Assert ($p.Maximized -and $p.Width -eq 1200 -and $p.Height -eq 800) '最大化标志应带回，尺寸仍记正常尺寸'

# ---- 6b. 多显示器：副屏（负坐标）的位置在虚拟屏幕范围内应保留 ----
$vs = [pscustomobject]@{ Width = 3840; Height = 1080; Left = -1920; Top = 0 }   # 副屏拼在主屏左侧
$savedLeft = [pscustomobject]@{ width = 1040; height = 640; left = -1800; top = 100 }
$p = Get-WindowPlacement $savedLeft $wa $vs
Assert ($p.Left -eq -1800 -and $p.Top -eq 100) '副屏上的坐标在虚拟屏幕内应原样恢复'
$p = Get-WindowPlacement $savedLeft $wa
Assert ($null -eq $p.Left) '没有虚拟屏幕信息时（单屏）副屏坐标应被判不可见'

# ---- 7. 记忆文件往返：写→读一致，坏 json 当没有 ----
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('svc-ui-state-' + [guid]::NewGuid().ToString('N') + '.json')
try {
  $state = [ordered]@{ width = 1200; height = 700; left = 100; top = 50; maximized = $false }
  Save-UiState $state $tmp
  Assert (Test-Path -LiteralPath $tmp) '记忆文件应写成功'
  $back = Load-UiState $tmp
  Assert ($back.width -eq 1200 -and $back.height -eq 700 -and $back.left -eq 100 -and $back.top -eq 50) '读回的尺寸/位置应与写入一致'
  Assert ($back.maximized -eq $false) '读回的最大化标志应为 false'

  Set-Content -LiteralPath $tmp -Value 'not json {' -Encoding UTF8
  Assert ($null -eq (Load-UiState $tmp)) '坏 json 应回落成「没有记忆」而不是抛错'
  Assert ($null -eq (Load-UiState (Join-Path ([IO.Path]::GetTempPath()) ('missing-' + [guid]::NewGuid().ToString('N') + '.json')))) '文件不存在应返回 $null'

  $script:uiStatePath = $tmp
  Assert ((Get-UiStatePath) -eq $tmp) '测试/截图脚本应能把记忆文件改指临时路径'
  $script:uiStatePath = $null
  $envPath = Join-Path ([IO.Path]::GetTempPath()) ('sm-ui-env-' + [guid]::NewGuid().ToString('N') + '.json')
  $env:NSSM_SM_UI_STATE = $envPath
  try { Assert ((Get-UiStatePath) -eq $envPath) 'run-all 用环境变量给子进程统一隔离记忆文件' }
  finally { $env:NSSM_SM_UI_STATE = $null }
  Assert ((Get-UiStatePath) -notlike '*svc-ui-state-*') '未改指时回到程序目录下的 ui-state.json'
} finally {
  Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

# ---- 8. 关窗快照：只记正常尺寸；最大化时用 RestoreBounds ----
$win = New-Object System.Windows.Window -Property @{
  Width = 900; Height = 600; Left = -20000; Top = -20000; WindowStartupLocation = 'Manual'
}
try {
  Assert ($null -eq (Get-WindowPlacementSnapshot $win)) '未 Show、无实际尺寸时快照应为 $null'
  $win.Show(); $win.UpdateLayout()
  $snap = Get-WindowPlacementSnapshot $win
  Assert ($null -ne $snap) 'Show 之后应能取到快照'
  Assert ($snap.width -eq 900 -and $snap.height -eq 600) "应记 900×600，实际 $($snap.width)×$($snap.height)"
  Assert ($snap.maximized -eq $false) '正常窗口不应标最大化'

  $win.WindowState = 'Maximized'; $win.UpdateLayout()
  $snap = Get-WindowPlacementSnapshot $win
  Assert ($snap.maximized -eq $true) '最大化后标志应为 true'
  Assert ($snap.width -eq 900 -and $snap.height -eq 600) "最大化时应记正常尺寸 900×600，实际 $($snap.width)×$($snap.height)"
} finally {
  $win.Close()
}

# ---- 9. 面板宽度未知时列数退回按数量算 ----
Assert ((Get-CardPanelWidth) -eq 0) '没有面板/窗口时应返回 0，交给数量兜底'
Assert ((Get-WindowChromeHeight) -eq 0) '没有窗口时应返回 0'
$null = Update-WindowMinHeight 3   # 没有窗口时是空操作，不能抛错
Assert ($script:config.CardMinHeight -eq 170) '默认单卡最小高度应为 170'
Assert ($script:config.CardMaxHeight -eq 320) '默认单卡最大高度应为 320'

# 装得下 → 用配置值；装不下 → 按可用高度等分，且不得超出行高（超了 UniformGrid 会让行相互压叠）
Assert ((Get-EffectiveCardMinHeight 3 148 1080) -eq 170) '3 行装得下时应取 CardMinHeight'
$tight = Get-EffectiveCardMinHeight 8 148 1080
Assert ($tight -eq 116) "8 行装不下时应等分成 116，实际 $tight"
Assert ((($tight * 8) + 148) -le 1080) '等分后的行高之和不得超出工作区'

# ---- 10. 窗口最小高度随行数反推：窄窗口下卡片不能被压到状态行叠按钮 ----
$script:uiStatePath = Join-Path ([IO.Path]::GetTempPath()) ('svc-ui-minh-' + [guid]::NewGuid().ToString('N') + '.json')
$script:svc = [ordered]@{}
foreach ($i in 1..7) { $script:svc["svc0$i"] = @{ port = 3000 + $i; url = "http://127.0.0.1:$(3000 + $i)" } }
$script:sync = @{ wake = [Threading.AutoResetEvent]::new($false) }
$win2 = New-MainWindow
try {
  $win2.Width = 840; $win2.Height = 540
  Render-Page
  $win2.WindowStartupLocation = 'Manual'; $win2.Left = -20000; $win2.Top = -20000
  $win2.Show(); $win2.UpdateLayout()
  Update-GridLayout          # 首帧 SizeChanged 可能早于面板真正量到宽度，这里显式再收敛一次
  $win2.UpdateLayout()

  $rows = [int]$script:cardPanel.Rows
  Assert ($rows -eq 3) "840px 宽 + 7 个服务应排 3 行，实际 $rows"
  $chrome = Get-WindowChromeHeight
  Assert ($chrome -gt 0) '窗口显示后应能量出非卡片区高度'
  $expectMin = $chrome + (3 * [int]$script:config.CardMinHeight)
  $waH = [int][math]::Floor([System.Windows.SystemParameters]::WorkArea.Height)
  if ($expectMin -lt $waH) {
    Assert ([math]::Abs($win2.MinHeight - $expectMin) -le 1) "窗口最小高度应为 $expectMin，实际 $($win2.MinHeight)"
    Assert ($win2.ActualHeight -ge ($expectMin - 1)) "窗口实际高度不应低于最小高度，实际 $([int]$win2.ActualHeight)"
  }
  $cellH = $script:cardPanel.ActualHeight / $rows
  Assert ($cellH -ge ([int]$script:config.CardMinHeight - 1)) "每行可用高度应 ≥ CardMinHeight，实际 $([int]$cellH)"
  foreach ($c in @($script:cards.Values)) {
    Assert ([math]::Abs([double]$c.MinHeight - [int]$script:config.CardMinHeight) -le 1) "卡片最小高度应为 CardMinHeight，实际 $($c.MinHeight)"
  }
} finally {
  $win2.Close()
  Remove-Item -LiteralPath $script:uiStatePath -Force -ErrorAction SilentlyContinue
  $script:uiStatePath = $null
}

Write-Output 'PASS: 列数自适应（宽度先减列、行数平衡、上限生效）、放置夹取与屏幕外丢弃、记忆文件往返与坏值回落、关窗快照（最大化记 RestoreBounds）、窗口最小高度随行数反推。'
} finally {
  # 还原本机 config.json：测试中途抛错也不能把用户的配置留在临时目录里。
  if ($configBackup) { Move-Item -LiteralPath $configBackup -Destination $repoConfig -Force }
}
