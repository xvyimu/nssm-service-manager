# lib/xaml.ps1 — 六卡片主视图：3 列 × 2 行，窗口缩放时同步伸展
# 每页数量从 lib/config.ps1 取（默认 6）；UniformGrid 列数随之计算。
# 自加载 config / tray：测试 dot-source 本模块时未必先加载，此处自洽。
# tray.ps1 只定义纯函数与惰性 Initialize-Tray，dot-source 本身不加载 WinForms。
if (-not $script:config) { . (Join-Path $PSScriptRoot 'config.ps1') }
if (-not (Get-Command Get-CloseAction -EA SilentlyContinue)) { . (Join-Path $PSScriptRoot 'tray.ps1') }
$script:PER_PAGE = [int]$script:config.PerPage

function New-MainWindow {
  $win = New-Object System.Windows.Window -Property @{
    Width=1040; Height=640; MinWidth=840; MinHeight=540
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
  [void]$titleBar.Children.Add($windowActions)
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
  # UniformGrid 列数 = PER_PAGE 的约数里最接近 2 行排满的那个；默认 3 列 × 2 行（PER_PAGE=6）。
  # 非 6 时取上取整 sqrt：PER_PAGE=4 → 2×2，PER_PAGE=8 → 3×3（3 行），9 → 3×3。
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
    Text='双击启停 · 右键更多操作'; FontSize=11; Foreground=$script:T.Dim
    VerticalAlignment='Center'; HorizontalAlignment='Right'
  }
  [void]$footer.Children.Add($statusBar); [void]$footer.Children.Add($hint)
  [void]$grid.Children.Add($footer); [System.Windows.Controls.Grid]::SetRow($footer,2)
  $root.Child=$grid; $win.Content=$root

  $script:window=$win; $script:cardPanel=$cardPanel; $script:statusBar=$statusBar
  $script:lblPage=$lblPage; $script:btnPrev=$btnPrev; $script:btnNext=$btnNext
  $script:serviceSummary=$summary; $script:cards=@{}; $script:curPage=0

  # 最大化/还原共用一个切换（按钮与双击标题栏同逻辑）。
  # 必须存 $script: —— New-MainWindow return 后局部变量脱作用域，
  # 双击标题栏处理器里的 & $script:toggleMax 才能解析到（PowerShell scriptblock 非闭包）。
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
    } else {
      $script:window.WindowState='Minimized'
    }
  })
  $btnMax.Add_Click($script:toggleMax)
  $btnClose.Add_Click({ $script:window.Close() })
  # 关闭策略：CloseToTray 且非托盘「退出」时取消关闭、隐藏到托盘。
  # trayExitRequested 由托盘菜单「退出」置位——那条路径必须放行，否则退不掉。
  $win.Add_Closing({ param($s,$e)
    if ((Get-CloseAction $script:config) -eq 'tray' -and -not $script:trayExitRequested) {
      $e.Cancel = $true
      $script:window.Hide()
    }
  })
  $win.Add_Closed({ Stop-Background; Remove-Tray })
  $btnAdd.Add_Click({ Show-Add $script:window; Render-Page })
  $btnPrev.Add_Click({ if ($script:curPage -gt 0) { $script:curPage--; Render-Page } })
  $btnNext.Add_Click({
    $pages=[math]::Max(1,[math]::Ceiling($script:svc.Count / $script:PER_PAGE))
    if ($script:curPage -lt $pages-1) { $script:curPage++; Render-Page }
  })
  $win
}

function Render-Page {
  $script:cardPanel.Children.Clear()
  # 读 $script:svc 加 gate（发现 15）：与后台 runspace 的读路径对称。
  # 当前 UI 线程是唯一写者，无实际并发写，但锁不对称后续加后台写入即踩。
  # 测试夹具可能没初始化 $sync（CLI 路径与部分单测），退化成不加锁直接读。
  $gate = if ($script:sync -and $script:sync.gate) { $script:sync.gate } else { $null }
  if ($gate) { [Threading.Monitor]::Enter($gate) }
  try { $names=@($script:svc.Keys) } finally { if ($gate) { [Threading.Monitor]::Exit($gate) } }
  $pages=[math]::Max(1,[math]::Ceiling($names.Count / $script:PER_PAGE))
  $script:curPage=[math]::Max(0,[math]::Min($script:curPage,$pages-1))
  $start=$script:curPage*$script:PER_PAGE
  $end=[math]::Min($start+$script:PER_PAGE,$names.Count)-1
  if ($start -le $end) {
    foreach ($n in $names[$start..$end]) {
      # 重用卡片，翻页不丢失健康状态、过渡状态或 8 秒冷却。
      $cached = $script:cards.ContainsKey($n)
      $card=if ($cached) { $script:cards[$n] } else { New-Card $n $script:svc[$n] }
      # 命中缓存时刷新端口/URL/Tag——配置可能已变更（发现 1）。
      # 新建的卡已在 New-Card 里固化，不重复刷新。
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