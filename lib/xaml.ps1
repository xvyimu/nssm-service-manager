# lib/xaml.ps1 — 卡片主视图：一屏全量、列数按窗口宽度自适应，窗口尺寸/位置记在 ui-state.json。实现细节：docs/IMPLEMENTATION-NOTES.md
if (-not $script:config) { . (Join-Path $PSScriptRoot 'config.ps1') }
if (-not (Get-Command Get-CloseAction -EA SilentlyContinue)) { . (Join-Path $PSScriptRoot 'tray.ps1') }

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

# 窗口位置/尺寸记忆：运行时状态，跟 services.json / config.json 同目录、不进 git。
# 与 config.json 分开的理由：那是人改的常量；这是程序自己写的上次退出形状，写坏了只该丢记忆、不该毁配置。
# 记忆文件路径的三级回落：脚本变量（测试/截图夹具改指临时文件）→ 环境变量（run-all 给所有子进程统一隔离）
# → 程序目录。没有后两级时，回归套件里真建/真关主窗的用例会把离屏坐标写进仓根 ui-state.json。
function Get-UiStatePath {
  if ($script:uiStatePath) { return $script:uiStatePath }
  if ($env:NSSM_SM_UI_STATE) { return $env:NSSM_SM_UI_STATE }
  Join-Path (Split-Path $PSScriptRoot -Parent) 'ui-state.json'
}

# 读记忆：坏文件、缺字段、非整数一律当没有（回落到默认尺寸），不让一个坏 json 挡住启动。
function Load-UiState([string]$path) {
  if (-not $path) { $path = Get-UiStatePath }
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
  catch { Write-Verbose "ui-state.json 不可解析，按没有记忆处理：$($_.Exception.Message)"; return $null }
}

# 原子写记忆（临时文件 + Move-Item 替换）：写一半断电不会留下半个 json。
function Save-UiState($state, [string]$path) {
  if (-not $path) { $path = Get-UiStatePath }
  $tmp = "$path.$PID.tmp"
  try {
    ($state | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $path -Force
  } catch {
    Write-Verbose "ui-state.json 写入失败（下次仍用默认尺寸）：$($_.Exception.Message)"
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
  }
}

# 多显示器：SystemParameters.WorkArea 只给主屏，副屏的负坐标会被判成「不可见」。
# 可见性判定改用虚拟屏幕（所有显示器的并集）；尺寸夹取仍按主屏工作区，不给出比主屏还大的默认窗。
function Get-VirtualScreenBounds {
  $l = [System.Windows.SystemParameters]::VirtualScreenLeft
  $t = [System.Windows.SystemParameters]::VirtualScreenTop
  $w = [System.Windows.SystemParameters]::VirtualScreenWidth
  $h = [System.Windows.SystemParameters]::VirtualScreenHeight
  if ($w -le 0 -or $h -le 0) { return $null }
  @{ Left=$l; Top=$t; Width=$w; Height=$h }
}

function Get-IntOrZero($value) {
  $n = 0
  if ($null -ne $value -and [int]::TryParse([string]$value, [ref]$n)) { return $n }
  return 0
}

# 记忆的尺寸/位置 → 真正用的窗口放置参数（纯函数，可脱离桌面单测）。
# 尺寸夹在 [MinWidth/MinHeight, 主屏工作区] 之间；位置只在「矩形至少露出 120×80」时恢复，
# 其余交给 CenterScreen——拔掉外接屏后按旧坐标开窗会开到看不见的地方。
# $screenBounds 是可见性判定用的屏幕范围（多显示器传虚拟屏幕并集，单屏传工作区即可）。
function Get-WindowPlacement($saved, $workArea, $screenBounds) {
  $base = Get-MainWindowSize $workArea
  $aw = 0.0; $ah = 0.0
  if ($workArea) { $aw = [double]$workArea.Width; $ah = [double]$workArea.Height }
  $vis = if ($screenBounds) { $screenBounds } else { $workArea }
  $vw = 0.0; $vh = 0.0; $waLeft = 0.0; $waTop = 0.0
  if ($vis) {
    $vw = [double]$vis.Width; $vh = [double]$vis.Height
    $waLeft = [double]$vis.Left; $waTop = [double]$vis.Top
  }
  $placement = @{ Width=$base.Width; Height=$base.Height; Left=$null; Top=$null; Maximized=$false }
  if (-not $saved) { return $placement }
  if ($saved.maximized -eq $true) { $placement.Maximized = $true }
  $w = Get-IntOrZero $saved.width
  $h = Get-IntOrZero $saved.height
  if ($w -gt 0 -and $h -gt 0) {
    if ($aw -gt 0) { $w = [int][math]::Min($w, [math]::Floor($aw)) }
    if ($ah -gt 0) { $h = [int][math]::Min($h, [math]::Floor($ah)) }
    if ($w -lt $base.MinWidth) { $w = $base.MinWidth }
    if ($h -lt $base.MinHeight) { $h = $base.MinHeight }
    $placement.Width = $w; $placement.Height = $h
  }
  # 坐标两个都得是非空整数才算有位置：坏值（null / "abc"）退回居中，别把窗口钉到 0,0。
  $l = 0; $t = 0
  $hasPos = ($null -ne $saved.left) -and ($null -ne $saved.top) -and
            [int]::TryParse([string]$saved.left, [ref]$l) -and [int]::TryParse([string]$saved.top, [ref]$t)
  if ($hasPos -and $vw -gt 0 -and $vh -gt 0) {
    $visibleX = [math]::Min($l + $placement.Width, $waLeft + $vw) - [math]::Max([double]$l, $waLeft)
    $visibleY = [math]::Min($t + $placement.Height, $waTop + $vh) - [math]::Max([double]$t, $waTop)
    if ($visibleX -ge 120 -and $visibleY -ge 80) { $placement.Left = $l; $placement.Top = $t }
  }
  $placement
}

# 关窗时取「下次该恢复成什么样」：最大化/最小化时 RestoreBounds 才是正常尺寸，
# 直接读 Width/Height 会把最大化尺寸写进记忆。未 Show 过时 RestoreBounds 为空，回落到当前值。
function Get-WindowPlacementSnapshot($win) {
  $b = $win.RestoreBounds
  $w = 0.0; $h = 0.0; $l = 0.0; $t = 0.0
  if ($b -and $b.Width -gt 0 -and $b.Height -gt 0) {
    $w = $b.Width; $h = $b.Height; $l = $b.Left; $t = $b.Top
  } elseif ($win.ActualWidth -gt 0) {
    $w = $win.ActualWidth; $h = $win.ActualHeight; $l = $win.Left; $t = $win.Top
  }
  if ($w -le 0 -or $h -le 0) { return $null }
  [ordered]@{
    width     = [int][math]::Round($w)
    height    = [int][math]::Round($h)
    left      = [int][math]::Round($l)
    top       = [int][math]::Round($t)
    maximized = ($win.WindowState -eq [System.Windows.WindowState]::Maximized)
  }
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
  if ($script:cards) { $pending = @($script:cards.Values | Where-Object { $_.ST -in $script:STALE_EXEMPT_STATES }).Count }
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
  $interval = Get-StateSampleInterval
  $head = if ($pending -gt 0) { "$count 个服务 · $pending 个待处理" } else { "$count 个服务" }
  $text = if ($script:bgDeathReported) {
    '离线'
  } elseif ($newest) {
    $delta = $now - $newest
    if ($delta.TotalSeconds -lt 0) {
      # 样本时间在未来（NTP 校正/手工改钟）：任何未来时间都不可信，直接说实话。
      # 不要留 -60..0 这条「夹成 0s」的带——那会把 +30s 的脏数据粉饰成「刚刚更新」。
      "$head · 更新时间在未来（检查系统时钟）"
    } else {
      $ageText = Format-Duration $newest $now -Style Short
      "$head · 更新于 $ageText 前"
    }
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

# 建主窗口骨架：无边框标题栏（版本+汇总）、单页卡片面板、工具栏与页脚，并挂 F5 重载 / 批量菜单。
function New-MainWindow {
  $workArea = [System.Windows.SystemParameters]::WorkArea
  $size = Get-MainWindowSize $workArea
  $placement = Get-WindowPlacement (Load-UiState) $workArea (Get-VirtualScreenBounds)
  $win = New-Object System.Windows.Window -Property @{
    Width=$placement.Width; Height=$placement.Height; MinWidth=$size.MinWidth; MinHeight=$size.MinHeight
    WindowStyle='None'; AllowsTransparency=$false; Background=[System.Windows.Media.Brushes]::Transparent
    ResizeMode='CanResize'; WindowStartupLocation='CenterScreen'
    Title='服务管理'; FontFamily=$script:cjkFont; FontSize=12
    UseLayoutRounding=$true; SnapsToDevicePixels=$true
  }
  # 记忆里的位置只在还留在工作区内时生效（Get-WindowPlacement 已判定），否则维持居中。
  if ($null -ne $placement.Left) {
    $win.WindowStartupLocation = 'Manual'
    $win.Left = $placement.Left; $win.Top = $placement.Top
  }
  if ($placement.Maximized) { $win.WindowState = [System.Windows.WindowState]::Maximized }
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
    # 版本写进标题栏：装的哪一版一眼可见（换机器/换部署后先看这里）。
    Text=$(if ($script:appVersion) { "服务管理 v$($script:appVersion)" } else { '服务管理' })
    FontSize=14; FontWeight='SemiBold'; Foreground=$script:T.Fg; VerticalAlignment='Center'
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
  # 不分页：一屏放全部服务。列数在 Render-Page 里按宽度与服务数算，这里只建空面板。
  $btnAdd = New-Object System.Windows.Controls.Button -Property @{Content='+ 添加服务'; Foreground=$script:T.Accent; Padding='12,5'}
  [void]$actions.Children.Add($btnAdd)
  [void]$toolbar.Children.Add($actions)
  [System.Windows.Controls.DockPanel]::SetDock($toolbar, 'Top')
  [void]$content.Children.Add($toolbar)
  $cardPanel = New-Object System.Windows.Controls.Primitives.UniformGrid -Property @{Columns=1; Rows=1}
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
  $script:serviceSummary=$summary; $script:cards=@{}
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
  $win.Add_Closed({
    # 先记窗口形状再拆后台：Save-UiState 只用 UI 线程里的值，失败也只丢记忆。
    $snap = Get-WindowPlacementSnapshot $win
    if ($snap) { Save-UiState $snap }
    Stop-Background; Remove-Tray
  })
  # 缩放/最大化时列数跟着宽度走：只调 UniformGrid 的列与行，不重建卡片。
  $win.Add_SizeChanged({ Update-GridLayout })
  # 首帧布局完成后再收敛一次：SizeChanged 可能早于面板量到真实宽度，那时 chrome 高度也还是 0。
  $win.Add_ContentRendered({ Update-GridLayout })
  $btnAdd.Add_Click({ Show-Add $script:window; Render-Page })
  $win
}

# 加锁读服务名（与后台 runspace 对称）；$sync 未初始化时退化为不加锁。
function Get-SvcNames {
  $gate = if ($script:sync -and $script:sync.gate) { $script:sync.gate } else { $null }
  if ($gate) { [Threading.Monitor]::Enter($gate) }
  # 返回值会被调用方用 @() 包住：只有一个服务时函数输出会退化成单个字符串
  # 伴随服务（companions）不单独出卡片：它随主卡片级联启停，占位就白占一页。
  try { @($script:svc.Keys | Where-Object { -not (Test-SvcIsCompanion $_) }) } finally { if ($gate) { [Threading.Monitor]::Exit($gate) } }
}

# 一屏放下全部服务时的列数：由「窗口宽度能放下几张卡」与数量共同决定，行数再按 ceil(n/cols) 反推。
# 先减列不压卡：窄窗口列少了但每张卡仍有 CardMinWidth；宽窗口列到 MaxGridColumns 就停，剩下的宽度变成卡片留白。
# 平衡取行的例子：7 张卡、上限 6 列 → 行=ceil(7/6)=2 → 列=ceil(7/2)=4（4+3），而不是 6+1。
function Get-GridColumns([int]$count, [double]$width = 0, [int]$minCardWidth = 0, [int]$maxCols = 0) {
  if ($minCardWidth -le 0) { $minCardWidth = if ($script:config) { [int]$script:config.CardMinWidth } else { 240 } }
  if ($maxCols -le 0) { $maxCols = if ($script:config) { [int]$script:config.MaxGridColumns } else { 4 } }
  if ($minCardWidth -le 0) { $minCardWidth = 240 }
  if ($maxCols -lt 1) { $maxCols = 1 }
  if ($count -le 1) { return 1 }
  $byWidth = if ($width -gt 0) { [int][math]::Floor($width / $minCardWidth) } else { $maxCols }
  if ($byWidth -lt 1) { $byWidth = 1 }
  $cap = [int][math]::Min([math]::Min($maxCols, $byWidth), $count)
  if ($cap -lt 1) { $cap = 1 }
  $rows = [int][math]::Max(1, [int][math]::Ceiling($count / $cap))
  [int][math]::Max(1, [int][math]::Ceiling($count / $rows))
}

# 卡片面板当前可用宽度：首帧布局还没跑（ActualWidth=0）时按窗口宽减边距估算，再不行交给数量兜底。
function Get-CardPanelWidth {
  if ($script:cardPanel -and $script:cardPanel.ActualWidth -gt 0) { return [double]$script:cardPanel.ActualWidth }
  if ($script:window -and $script:window.ActualWidth -gt 0) { return [double]($script:window.ActualWidth - 40) }
  return 0.0
}

# 窗口「非卡片区」的高度：标题栏 + 汇总行 + 状态栏 + 内外边距。实测差值比写死常数稳：
# 换个字号/DPI 后常数会漂，差值是当前布局自己算出来的。
function Get-WindowChromeHeight {
  if (-not $script:window -or -not $script:cardPanel) { return 0 }
  if ($script:window.ActualHeight -le 0 -or $script:cardPanel.ActualHeight -le 0) { return 0 }
  [int][math]::Max(0, $script:window.ActualHeight - $script:cardPanel.ActualHeight)
}

# 每行实际可用的最小卡片高度：正常就是 CardMinHeight；服务多到屏幕装不下时按可用高度等分。
# 不设人为下限：UniformGrid 等分行高，子项 MinHeight 只要超过行高就会压到下一行上——
# 宁可卡片内容被裁（服务多到一屏装不下本来就是已知限制），也不能叠行。
function Get-EffectiveCardMinHeight([int]$rows, [double]$chrome = 0, [double]$workAreaHeight = 0) {
  $cardMin = if ($script:config) { [int]$script:config.CardMinHeight } else { 170 }
  if ($chrome -le 0) { $chrome = Get-WindowChromeHeight }
  if ($workAreaHeight -le 0) {
    $wa = [System.Windows.SystemParameters]::WorkArea
    if ($wa) { $workAreaHeight = [double]$wa.Height }
  }
  if ($chrome -gt 0 -and $rows -gt 0 -and $workAreaHeight -gt 0) {
    $fit = [int][math]::Floor(($workAreaHeight - $chrome) / $rows)
    if ($fit -lt $cardMin) { $cardMin = [int][math]::Max(0, $fit) }
  }
  $cardMin
}

# 窗口缩到极小时卡片会被压到内容放不下（状态行叠到按钮上）：最小高度按行数反推，
# 每行至少「实际可用最小高度」。夹在工作区高度以内——比屏幕还高的最小高度会让人没法用窗口。
# 返回本轮采用的最小卡片高度（$null = 还量不出 chrome，调用方不要动卡片），供 Update-CardMinHeight 同步。
function Update-WindowMinHeight([int]$rows) {
  if (-not $script:window -or $rows -le 0) { return $null }
  $chrome = Get-WindowChromeHeight
  if ($chrome -le 0) { return $null }
  $cardMin = Get-EffectiveCardMinHeight $rows
  $need = $chrome + ($rows * $cardMin)
  $wa = [System.Windows.SystemParameters]::WorkArea
  if ($wa -and $wa.Height -gt 0) { $need = [int][math]::Min($need, [int][math]::Floor($wa.Height)) }
  if ($need -gt 0 -and $script:window.MinHeight -ne $need) { $script:window.MinHeight = $need }
  $cardMin
}

# 卡片的 MinHeight 跟着网格走：默认取 config，装不下时取等分后的值（可能为 0，表示不设下限）。
function Update-CardMinHeight([double]$minHeight) {
  if (-not $script:cards -or $null -eq $minHeight -or $minHeight -lt 0) { return }
  foreach ($c in @($script:cards.Values)) {
    if ($c -and [math]::Abs([double]$c.MinHeight - $minHeight) -gt 0.5) { $c.MinHeight = $minHeight }
  }
}

# 窗口缩放/最大化时只重算网格形状：卡片对象、状态、冷却都不重来（重建会闪、会丢掉时长后缀）。
function Update-GridLayout {
  if (-not $script:cardPanel) { return }
  $count = $script:cardPanel.Children.Count
  if ($count -le 0) { return }
  $cols = Get-GridColumns $count (Get-CardPanelWidth)
  $rows = [int][math]::Max(1, [int][math]::Ceiling($count / $cols))
  if ($script:cardPanel.Columns -ne $cols) { $script:cardPanel.Columns = $cols }
  if ($script:cardPanel.Rows -ne $rows) { $script:cardPanel.Rows = $rows }
  $cardMin = Update-WindowMinHeight $rows
  if ($null -ne $cardMin) { Update-CardMinHeight $cardMin }
}

# 重建全部卡片（增删服务、配置重载后调用）；卡片对象缓存在 $cards，健康/过渡/冷却状态不丢。
function Render-Page {
  $script:cardPanel.Children.Clear()
  $gate = if ($script:sync -and $script:sync.gate) { $script:sync.gate } else { $null }
  $names = @(Get-SvcNames)
  $cols = Get-GridColumns $names.Count (Get-CardPanelWidth)
  $script:cardPanel.Columns = $cols
  $script:cardPanel.Rows = [math]::Max(1, [int][math]::Ceiling($names.Count / $cols))
  foreach ($n in $names) {
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
  $script:serviceSummary.Text="$($names.Count) 个本地服务"
  # 增删服务会改行数，最小高度与卡片下限得跟着重算：只靠 SizeChanged 的话，窗口没被缩放就不会收敛。
  Update-GridLayout
}
