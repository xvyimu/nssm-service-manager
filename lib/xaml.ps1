# lib/xaml.ps1 — 卡片主视图：列数由 PerPage 计算，窗口缩放时同步伸展。实现细节：docs/IMPLEMENTATION-NOTES.md
if (-not $script:config) { . (Join-Path $PSScriptRoot 'config.ps1') }
if (-not (Get-Command Get-CloseAction -EA SilentlyContinue)) { . (Join-Path $PSScriptRoot 'tray.ps1') }
$script:PER_PAGE = [int]$script:config.PerPage

# 主窗口尺寸按工作区推算：150%/200% 缩放的笔记本上，1040×640 的 DIP 可能直接超出工作区，
# 底栏会被挤出屏幕。全部夹到工作区的 90%，MinHeight 也随工作区走（不再写死 540）。
# 纯函数（吃 WorkArea）是为了能脱离真实桌面单测夹取逻辑。
function Get-MainWindowSize($workArea){
  $aw = 0.0; $ah = 0.0
  if ($workArea) { $aw = [double]$workArea.Width; $ah = [double]$workArea.Height }
  if ($aw -le 0) { $aw = 1280 }   # 无桌面会话（WorkArea 为 0）：回落 DIP 基准，别算出 0×0
  if ($ah -le 0) { $ah = 720 }
  $width  = [int][math]::Min(1040, [math]::Floor($aw * 0.9))
  $height = [int][math]::Min(640,  [math]::Floor($ah * 0.9))
  $minW = [int][math]::Min(840, $width)
  $minH = [int][math]::Min(540, [math]::Floor($ah * 0.5))
  if ($minH -lt 240) { $minH = 240 }        # 底线：再小也没法用
  if ($minH -gt $height) { $minH = $height }
  if ($minW -gt $width)  { $minW = $width }
  @{ Width=$width; Height=$height; MinWidth=$minW; MinHeight=$minH }
}

# 标题栏新鲜度胶囊：只读 $script:svc / $script:svcState / $script:cards / $script:config，不碰探测。
# 「更新于 Ns 前」取所有服务里**最新**的采样时刻；超过 2 个探测周期没新样本转琥珀，
# 后台 runspace 已死时显示「离线」并转红。顺带刷新托盘 tooltip（同一帧的数据，别算两遍）。
function Update-FreshnessPill {
  if (-not $script:freshPill) { return }
  $now = [datetime]::Now
  $count = 0
  if ($script:svc) { $count = @($script:svc.Keys).Count }
  $pending = 0
  if ($script:cards) { $pending = @($script:cards.Values | Where-Object { $_.ST -in @('启动中','停止中','删除中','待保存') }).Count }
  $newest = $null
  if ($script:svcState) {
    foreach ($key in @($script:svcState.Keys)) {
      $seen = $script:svcState[$key]
      if ($seen -and $seen.at) {
        $at = [datetime]$seen.at
        if (-not $newest -or $at -gt $newest) { $newest = $at }
      }
    }
  }
  $interval = if ($script:config.ProbeIntervalMs) { [int]$script:config.ProbeIntervalMs } else { 4000 }
  $head = if ($pending -gt 0) { "$count 个服务 · $pending 个待处理" } else { "$count 个服务" }
  $text = if ($script:bgDeathReported) {
    '离线'
  } elseif ($newest) {
    $secs = [int]($now - $newest).TotalSeconds
    if ($secs -lt 0) { $secs = 0 }
    $ageText = if ($secs -lt 60) { "${secs}s" } elseif ($secs -lt 3600) { "$([int][math]::Floor($secs/60)) 分钟" } else { "$([int][math]::Floor($secs/3600)) 小时" }
    "$head · 更新于 $ageText 前"
  } else {
    "$head · 等待首次探测"
  }
  if ($script:freshPill.Text -ne $text) { $script:freshPill.Text = $text }
  # 陈旧样本（>2 个探测周期）转琥珀：数字还在变，但数据已经老了。
  # 时钟回拨时 $now < $newest，差值恒为负、永远判不出陈旧——那种情况的数据同样不可信，一并转琥珀。
  $stale = $newest -and (($now -lt $newest) -or (($now - $newest).TotalMilliseconds -gt (2 * $interval)))
  $fg = if ($script:bgDeathReported) { $script:T.BrushDanger }
        elseif ($stale) { $script:T.BrushBusy }
        else { $script:T.BrushDim }
  if ($script:freshPill.Foreground -cne $fg) { $script:freshPill.Foreground = $fg }
  if (Get-Command Update-TrayText -EA SilentlyContinue) { Update-TrayText }
}

function New-MainWindow {
  $size = Get-MainWindowSize ([System.Windows.SystemParameters]::WorkArea)
  $win = New-Object System.Windows.Window -Property @{
    Width=$size.Width; Height=$size.Height; MinWidth=$size.MinWidth; MinHeight=$size.MinHeight
    WindowStyle='None'; AllowsTransparency=$false; Background=[System.Windows.Media.Brushes]::Transparent
    ResizeMode='CanResize'; WindowStartupLocation='CenterScreen'
    Title='服务管理'; FontFamily=$script:cjkFont; FontSize=12
    UseLayoutRounding=$true; SnapsToDevicePixels=$true
  }
  # 原生非 layered 窗口允许 DWM 背景生效；WindowChrome 保留边缘缩放。
  $chrome = New-Object System.Windows.Shell.WindowChrome -Property @{
    CaptionHeight=0; ResizeBorderThickness='6'; GlassFrameThickness='-1'; UseAeroCaptionButtons=$false
  }
  [System.Windows.Shell.WindowChrome]::SetWindowChrome($win, $chrome)
  $win.Resources[[System.Windows.Controls.Button]] = $script:buttonStyle
  $root = New-Object System.Windows.Controls.Border -Property @{
    CornerRadius=10; BorderBrush=$script:T.CardBrd; BorderThickness='1'; Background=$script:T.RootBg
  }
  $grid = New-Object System.Windows.Controls.Grid
  foreach ($height in 'Auto','*','Auto') {
    [void]$grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{Height=$height}))
  }

  $titleBar = New-Object System.Windows.Controls.Grid -Property @{Height=44; Margin='20,0,8,0'; Background='Transparent'}
  $title = New-Object System.Windows.Controls.TextBlock -Property @{
    Text='服务管理'; FontSize=14; FontWeight='SemiBold'; Foreground=$script:T.Fg; VerticalAlignment='Center'
  }
  [void]$titleBar.Children.Add($title)
  $windowActions = New-Object System.Windows.Controls.StackPanel -Property @{
    Orientation='Horizontal'; HorizontalAlignment='Right'; VerticalAlignment='Center'
  }
  # 新鲜度胶囊（标题栏常驻）：服务数 + 最新采样距今 + 离线态；文案由 Update-FreshnessPill 每帧刷新。
  $freshPill = New-Object System.Windows.Controls.TextBlock -Property @{
    Text='正在获取状态…'; FontFamily=$script:cjkFont; FontSize=11; Foreground=$script:T.BrushDim
  }
  $freshPillBorder = New-Object System.Windows.Controls.Border -Property @{
    Background=$script:T.PortBg; BorderBrush=$script:T.CardBrd; BorderThickness='1'; CornerRadius=9
    Padding='9,3'; Margin='0,0,14,0'; VerticalAlignment='Center'; Child=$freshPill
  }
  $titleRight = New-Object System.Windows.Controls.StackPanel -Property @{
    Orientation='Horizontal'; HorizontalAlignment='Right'; VerticalAlignment='Center'
  }
  $btnMin = New-Object System.Windows.Controls.Button -Property @{
    Content='—'; Width=36; MinHeight=28; Height=28; Padding='0'; Background='Transparent'; BorderThickness='0'; ToolTip='最小化'
  }
  $btnMax = New-Object System.Windows.Controls.Button -Property @{
    Content='▢'; Width=36; MinHeight=28; Height=28; Padding='0'; Background='Transparent'; BorderThickness='0'; ToolTip='最大化/还原'
  }
  $btnClose = New-Object System.Windows.Controls.Button -Property @{
    Content='✕'; Width=36; MinHeight=28; Height=28; Padding='0'; Background='Transparent'; BorderThickness='0'; ToolTip='关闭'
  }
  [void]$windowActions.Children.Add($btnMin); [void]$windowActions.Children.Add($btnMax); [void]$windowActions.Children.Add($btnClose)
  # 胶囊在窗口按钮左侧，同一组右对齐；$script:freshPill 给 Update-FreshnessPill 写文案。
  [void]$titleRight.Children.Add($freshPillBorder); [void]$titleRight.Children.Add($windowActions)
  [void]$titleBar.Children.Add($titleRight)
  [void]$grid.Children.Add($titleBar)

  $content = New-Object System.Windows.Controls.DockPanel -Property @{Margin='12,0,12,0'}
  $toolbar = New-Object System.Windows.Controls.Grid -Property @{Height=50; Margin='8,0,8,4'}
  $summary = New-Object System.Windows.Controls.TextBlock -Property @{
    Text='本地服务'; Foreground=$script:T.Dim; FontSize=13; VerticalAlignment='Center'
  }
  [void]$toolbar.Children.Add($summary)
  $actions = New-Object System.Windows.Controls.StackPanel -Property @{
    Orientation='Horizontal'; HorizontalAlignment='Right'; VerticalAlignment='Center'
  }
  $btnPrev = New-Object System.Windows.Controls.Button -Property @{Content='上一页'; Padding='10,5'; Margin='0,0,6,0'}
  $lblPage = New-Object System.Windows.Controls.TextBlock -Property @{
    VerticalAlignment='Center'; Margin='4,0,10,0'; Foreground=$script:T.Dim
  }
  $btnNext = New-Object System.Windows.Controls.Button -Property @{Content='下一页'; Padding='10,5'; Margin='0,0,12,0'}
  $btnAdd = New-Object System.Windows.Controls.Button -Property @{Content='+ 添加服务'; Foreground=$script:T.Accent; Padding='14,6'}
  foreach ($control in $btnPrev,$lblPage,$btnNext,$btnAdd) { [void]$actions.Children.Add($control) }
  [void]$toolbar.Children.Add($actions)
  [System.Windows.Controls.DockPanel]::SetDock($toolbar, 'Top')
  [void]$content.Children.Add($toolbar)
  # 列数取上取整 sqrt：PER_PAGE=6 → 3×2，4 → 2×2，8 → 3×3。
  $cols = [math]::Ceiling([math]::Sqrt($script:PER_PAGE))
  $rows = [math]::Ceiling($script:PER_PAGE / $cols)
  $cardPanel = New-Object System.Windows.Controls.Primitives.UniformGrid -Property @{Columns=$cols; Rows=$rows}
  [void]$content.Children.Add($cardPanel)
  [void]$grid.Children.Add($content); [System.Windows.Controls.Grid]::SetRow($content,1)

  $footer = New-Object System.Windows.Controls.Grid -Property @{Height=34; Margin='20,0,20,0'}
  $statusBar = New-Object System.Windows.Controls.TextBlock -Property @{
    Text='正在获取状态…'; FontSize=11; Foreground=$script:T.Dim; VerticalAlignment='Center'
  }
  $hint = New-Object System.Windows.Controls.TextBlock -Property @{
    Text='F5 重新加载 · 双击启停 · 右键更多'; FontSize=11; Foreground=$script:T.Dim
    VerticalAlignment='Center'; HorizontalAlignment='Right'
  }
  [void]$footer.Children.Add($statusBar); [void]$footer.Children.Add($hint)
  [void]$grid.Children.Add($footer); [System.Windows.Controls.Grid]::SetRow($footer,2)
  $root.Child=$grid; $win.Content=$root

  $script:window=$win; $script:cardPanel=$cardPanel; $script:statusBar=$statusBar
  $script:lblPage=$lblPage; $script:btnPrev=$btnPrev; $script:btnNext=$btnNext
  $script:serviceSummary=$summary; $script:cards=@{}; $script:curPage=0
  $script:freshPill=$freshPill

  # 最大化/还原共用；必须存 $script:，否则局部作用域销毁后处理器解析不到（脚本块非闭包）。
  $script:toggleMax = { $script:window.WindowState = if ($script:window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' } }
  $titleBar.Add_MouseLeftButtonDown({ param($s,$e) if ($e.LeftButton -eq 'Pressed') {
    if ($e.ClickCount -ge 2) {
      # 双击标题栏切换最大化（发现 11）；DragMove 与双击互斥，ClickCount≥2 时不拖动
      & $script:toggleMax
    } else { $script:window.DragMove() }
  } })
  $btnMin.Add_Click({
    if ((Get-MinimizeAction $script:config) -eq 'tray') {
      # 收进托盘：隐藏窗口（不进任务栏），托盘图标已在主入口初始化
      $script:window.Hide()
      if (Get-Command Show-TrayHint -EA SilentlyContinue) { Show-TrayHint }
    } else {
      $script:window.WindowState='Minimized'
    }
  })
  $btnMax.Add_Click($script:toggleMax)
  $btnClose.Add_Click({ $script:window.Close() })
  # 关闭策略：CloseToTray 且非托盘「退出」时隐藏到托盘；trayExitRequested 必须放行。
  $win.Add_Closing({ param($s,$e)
    if ((Get-CloseAction $script:config) -eq 'tray' -and -not $script:trayExitRequested) {
      $e.Cancel = $true
      $script:window.Hide()
      # 首次收进托盘提示一次：窗口消失 ≠ 程序退出，别让用户以为已经关干净了。
      if (Get-Command Show-TrayHint -EA SilentlyContinue) { Show-TrayHint }
      return
    }
    # 有在途命令时退出：SCM 那边的操作不会因为关窗停下，但重启可能停在停止阶段。
    # 托盘「退出」是明确的收尾意图，不再二次确认。
    if (-not $script:trayExitRequested) {
      $now = [datetime]::Now
      # 「在途」= 过渡态**且没超时**。命令驱动的过渡态超时后会被逃生口解封，拿它拦关窗只会误报；
      # 探测驱动的卡死态（TransitionAt 为空）不判超时，仍算在途——那是 SCM 侧真的没走完，
      # 提示是对的（右键菜单是唯一出路，见 docs/PROJECT.md 已知限制）。
      # Test-TransitionTimedOut 不在（CLI / 部分单测只加载 util+xaml）时保守按在途处理。
      $canJudgeTimeout = [bool](Get-Command Test-TransitionTimedOut -EA SilentlyContinue)
      $busy = @(Get-ExitBusy $script:cards $script:svc | Where-Object {
        -not $canJudgeTimeout -or (-not (Test-TransitionTimedOut $_ $now))
      })
      $queued = if ($script:cmdQueue) { @($script:cmdQueue.ToArray()).Count } else { 0 }
      if ($busy.Count -or $queued) {
        $names = @($busy | ForEach-Object { $_.SvcName }) -join '、'
        $what = if ($busy.Count) { "$($busy.Count) 个服务还在切换中：$names" } else { "还有 $queued 条命令未执行" }
        if (-not (Confirm-ExitBusy $script:window $what)) { $e.Cancel = $true; return }
      }
    }
  })
  $win.Add_Closed({ Stop-Background; Remove-Tray })
  $btnAdd.Add_Click({ Show-Add $script:window; Render-Page })
  $btnPrev.Add_Click({ if ($script:curPage -gt 0) { $script:curPage--; Render-Page } })
  $btnNext.Add_Click({
    $names = @(Get-SvcNames)
    $pages = Get-PageCount $names.Count
    if ($script:curPage -lt $pages-1) { $script:curPage++; Render-Page }
  })
  $win
}

# 加锁读服务名（与后台 runspace 对称）；$sync 未初始化时退化为不加锁。
function Get-SvcNames {
  $gate = if ($script:sync -and $script:sync.gate) { $script:sync.gate } else { $null }
  if ($gate) { [Threading.Monitor]::Enter($gate) }
  # 返回值会被调用方用 @() 包住：只有一个服务时函数输出会退化成单个字符串
  try { @($script:svc.Keys) } finally { if ($gate) { [Threading.Monitor]::Exit($gate) } }
}

function Get-PageCount([int]$count) { [math]::Max(1,[math]::Ceiling($count / $script:PER_PAGE)) }

function Render-Page {
  $script:cardPanel.Children.Clear()
  $gate = if ($script:sync -and $script:sync.gate) { $script:sync.gate } else { $null }
  $names = @(Get-SvcNames)
  $pages = Get-PageCount $names.Count
  $script:curPage=[math]::Max(0,[math]::Min($script:curPage,$pages-1))
  $start=$script:curPage*$script:PER_PAGE
  $end=[math]::Min($start+$script:PER_PAGE,$names.Count)-1
  if ($start -le $end) {
    foreach ($n in $names[$start..$end]) {
      # 重用卡片，翻页不丢失健康状态、过渡状态或 8 秒冷却。
      $cached = $script:cards.ContainsKey($n)
      $card=if ($cached) { $script:cards[$n] } else { New-Card $n $script:svc[$n] }
      # 命中缓存时刷新端口/URL/Tag（配置可能已变）；新建卡已在 New-Card 固化。
      if ($cached) {
        if ($gate) { [Threading.Monitor]::Enter($gate) }
        try { $info = $script:svc[$n] } finally { if ($gate) { [Threading.Monitor]::Exit($gate) } }
        if ($info) { Update-CardInfo $n $info }
      }
      [void]$script:cardPanel.Children.Add($card)
    }
  }
  $script:serviceSummary.Text="$($names.Count) 个本地服务"
  $script:lblPage.Text="$($script:curPage+1) / $pages"
  foreach ($control in $script:btnPrev,$script:lblPage,$script:btnNext) {
    $control.Visibility=if ($pages -gt 1) { 'Visible' } else { 'Collapsed' }
  }
  $script:btnPrev.IsEnabled=($script:curPage -gt 0)
  $script:btnNext.IsEnabled=($script:curPage -lt $pages-1)
}