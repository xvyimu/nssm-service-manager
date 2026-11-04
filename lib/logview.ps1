# lib/logview.ps1 — 日志查看器：枚举轮转档 + WPF 查看窗口
# 依赖调用方作用域的 $logDir 与字体变量。实现细节：docs/IMPLEMENTATION-NOTES.md

# 枚举当前 + 轮转日志；服务名须 [regex]::Escape，参数名必须是 $LogPath 以免遮蔽外层 $logDir。§Get-LogFiles
function Get-LogFiles([string]$n, [string]$LogPath){
  # 不给路径时读该服务实际的日志目录（AppStdout），手工注册的服务日志可能不在 $logDir。
  if(-not $LogPath){ $LogPath = Get-SvcLogDir $n }
  if(-not $LogPath -or -not (Test-Path -LiteralPath $LogPath)){ return @() }
  $esc = [regex]::Escape($n)
  $current = @()
  $rotated = @()
  # -Filter 走 Windows shell 通配（非正则），点号原样匹配；用 $n 不用 $esc。
  $pattern = "{0}.*.log" -f $n
  $files = @(Get-ChildItem -LiteralPath $LogPath -Filter $pattern -File -EA SilentlyContinue |
    Sort-Object LastWriteTime -Descending)
  foreach ($f in $files) {
    $base = $f.BaseName  # e.g. "MyAPI.out" or "MyAPI.out-20260930120000"
    # 锚到行首：服务名本身的点号已转义，不会吞掉相邻服务名；行尾按 out/err 或轮转后缀分档。
    if ($base -match "^$esc\.(out|err)$") {
      $current += [pscustomobject]@{ Path=$f.FullName; Label="$($matches[1]) (当前)" }
    } elseif ($base -match "^$esc\.(out|err)-") {
      $rotated += [pscustomobject]@{ Path=$f.FullName; Label="$($matches[1]) 轮转 $($f.LastWriteTime.ToString('MM-dd HH:mm'))" }
    }
  }
  # 当前在前，轮转按时间倒序
  @($current) + @($rotated)
}

# 读日志尾部：只读最后 $MaxBytes，取其中最后 $Keep 行。整文件读会卡住 UI 线程（NSSM 日志没有上限），
# 而用户只看最后几百行。抽成无 WPF 依赖的函数，才能在没有界面的情况下单测。§Read-LogTail
function Read-LogTail([string]$path, [int]$Keep = 500, [int]$MaxBytes = 262144) {
  if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  $fs = [IO.File]::Open($path, 'Open', 'Read', [IO.FileShare]::ReadWrite)
  try {
    $truncated = $fs.Length -gt $MaxBytes
    if ($truncated) { [void]$fs.Seek(-$MaxBytes, 'End') }
    $sr = [IO.StreamReader]::new($fs, [Text.UTF8Encoding]::new($false))
    try { $text = $sr.ReadToEnd() } finally { $sr.Dispose() }
  } finally { $fs.Dispose() }
  $lines = @($text -split "`r?`n")
  # 从中间切进来时第一行是残片，丢掉（否则会显示半行乱码）
  if ($truncated -and $lines.Count -gt 1) { $lines = $lines[1..($lines.Count - 1)] }
  (@($lines) | Select-Object -Last $Keep) -join "`r`n"
}

# 健康历史窗口：最近 200 条（最新在前）。和日志窗口同款只读文本框，不做表格。§Show-HealthHistory
function Show-HealthHistory([string]$n, $owner){
  # 目录来源与写入侧一致（$script:healthHistoryDir 由主脚本按 HealthHistory 开关算）
  $dir = if ($script:healthHistoryDir) { $script:healthHistoryDir }
         elseif ($logDir) { Join-Path $logDir 'health' }
         else { $null }
  $events = @(Get-HealthEvents $dir $n 200 ([int]$script:config.HealthKeepDays))
  $text = if (-not $events.Count) {
    '还没有历史记录。健康历史只在「状态或健康值变化」时落一条，服务一直平稳就没有内容。'
  } else {
    ($events | ForEach-Object {
      $ts = if ($_.ts) { ([datetime]$_.ts).ToString('MM-dd HH:mm:ss') } else { '?' }
      '{0}  {1,-8} {2}' -f $ts, $_.st, $_.h
    }) -join "`r`n"
  }
  $w = New-Object System.Windows.Window -Property @{
    Title="$n 健康历史"; Width=620; Height=460; WindowStartupLocation='CenterOwner'
    Background=[System.Windows.Media.Brushes]::White
  }
  $box = New-Object System.Windows.Controls.TextBox -Property @{
    IsReadOnly=$true; Text=$text; AcceptsReturn=$true; TextWrapping='NoWrap'
    FontFamily=$script:cjkFont; FontSize=11; Margin='10'; BorderThickness='0'
    VerticalScrollBarVisibility='Auto'; HorizontalScrollBarVisibility='Auto'
  }
  $w.Content = $box
  if ($owner) { $w.Owner = $owner }
  $w.ShowDialog() | Out-Null
}

# 日志查看器（闭包 hashtable 持久切换状态）。§Show-Log
function Show-Log([string]$n, $owner){
  $f2 = New-Object System.Windows.Window -Property @{
    Title = "$n 日志"; Width = 760; Height = 520; WindowStartupLocation='CenterOwner'
    Background = [System.Windows.Media.Brushes]::White
  }
  # 正文等宽 11px：日志是用来对齐扫读的，CJK 字体下多空格会错位。
  $box = New-Object System.Windows.Controls.TextBox -Property @{
    IsReadOnly = $true; FontFamily = $script:fontMono; FontSize = 11
    VerticalScrollBarVisibility = 'Auto'; TextWrapping = 'NoWrap'
    Background = [System.Windows.Media.Brushes]::White; Foreground = [System.Windows.Media.Brushes]::Black
  }
  # 顶部元信息：行数上限 / 文件大小 / 最后写入时刻——一眼判断「日志到底还活着没有」。
  $meta = New-Object System.Windows.Controls.TextBlock -Property @{
    FontFamily=$script:cjkFont; FontSize=11; Foreground=$script:T.Dim; Margin='10,8,4,0'
  }
  $lt = New-Object System.Windows.Controls.StackPanel -Property @{ Orientation='Horizontal'; Margin='6,4,6,6' }
  # 当前日志 + 轮转历史下拉；切换时重新加载
  $state = @{ File = $null }
  $combo = New-Object System.Windows.Controls.ComboBox -Property @{ Margin='4,2'; MinWidth=220 }
  $refreshBtn = New-Object System.Windows.Controls.Button -Property @{ Content='刷新'; Margin='4,2' }
  # 跟随最新：默认开，用户往上一滚就自动关（看历史时不该被新行顶回底部）。
  $follow = New-Object System.Windows.Controls.CheckBox -Property @{
    Content='跟随最新'; IsChecked=$true; Margin='12,0,4,0'; VerticalAlignment='Center'; FontFamily=$script:cjkFont; FontSize=11
  }
  $openDir = New-Object System.Windows.Controls.Button -Property @{ Content='打开文件夹'; Margin='4,2' }
  $copyPath = New-Object System.Windows.Controls.Button -Property @{ Content='复制路径'; Margin='4,2' }
  $logRoot = if ($logDir) { [string]$logDir } else { $null }   # 调用方脚本作用域，闭包里显式带走

  $updateMeta = {
    $sizeText = ''
    $whenText = ''
    if ($state.File -and (Test-Path -LiteralPath $state.File -PathType Leaf)) {
      try {
        $fi = [IO.FileInfo]$state.File
        $sizeText = if ($fi.Length -ge 1MB) { '{0:N1} MB' -f ($fi.Length / 1MB) }
                    elseif ($fi.Length -ge 1KB) { '{0:N0} KB' -f ($fi.Length / 1KB) }
                    else { "$($fi.Length) B" }
        $whenText = $fi.LastWriteTime.ToString('HH:mm:ss')
      } catch {}
    }
    $meta.Text = "最近 500 行" + $(if ($sizeText) { " · 文件 $sizeText" } else { '' }) + $(if ($whenText) { " · 更新于 $whenText" } else { '' })
  }.GetNewClosure()

  $load = {
    $box.Clear()
    # 读失败（被占用/无权限）只显示原因：这个闭包原来无 catch，异常会冒到 Dispatcher 兜底，
    # 日志窗留着上一次的内容，用户以为文件没变。
    try {
      $text = Read-LogTail $state.File 500
      $box.Text = if ($null -eq $text) { '无日志' } else { $text }
    } catch {
      $box.Text = "读取日志失败：$($_.Exception.Message)"
    }
    & $updateMeta
    if ($follow.IsChecked) { $box.ScrollToEnd() }
  }.GetNewClosure()

  # 初始填充与刷新共用：枚举文件 → 建 ComboBoxItem → 选中 oldPath（或首项）
  $fillCombo = {
    param($selectPath)
    $combo.Items.Clear()
    $files = Get-LogFiles $n
    if ($files.Count -eq 0) {
      [void]$combo.Items.Add((New-Object System.Windows.Controls.ComboBoxItem -Property @{Content='无日志'; Tag=''}))
      $state.File = $null
    } else {
      $selIdx = 0
      for ($i=0; $i -lt $files.Count; $i++) {
        $item = New-Object System.Windows.Controls.ComboBoxItem -Property @{ Content=$files[$i].Label; Tag=$files[$i].Path }
        [void]$combo.Items.Add($item)
        if ($selectPath -and $files[$i].Path -eq $selectPath) { $selIdx = $i }
      }
      $combo.SelectedIndex = $selIdx
      $state.File = $files[$selIdx].Path
    }
  }.GetNewClosure()

  & $fillCombo $null
  $combo.Add_SelectionChanged({
    $item = $combo.SelectedItem
    if ($item -and $item.Tag) { $state.File = [string]$item.Tag; & $load }
  }.GetNewClosure())
  $refreshBtn.Add_Click({
    # 刷新下拉（轮转文件可能新增）并重载当前
    & $fillCombo $state.File
    & $load
  }.GetNewClosure())

  # 上滚即关跟随：滚轮 / PageUp / Up / Home 都算「用户想看历史」。内容装得下时不算（滚不动）。
  $box.Add_PreviewMouseWheel({
    param($s,$e)
    if ($e.Delta -gt 0 -and $box.ScrollableHeight -gt 0) { $follow.IsChecked = $false }
  }.GetNewClosure())
  $box.Add_PreviewKeyDown({
    param($s,$e)
    if ($box.ScrollableHeight -gt 0 -and ($e.Key -eq [System.Windows.Input.Key]::Up -or $e.Key -eq [System.Windows.Input.Key]::PageUp -or $e.Key -eq [System.Windows.Input.Key]::Home)) {
      $follow.IsChecked = $false
    }
  }.GetNewClosure())

  $openDir.Add_Click({
    $p = if ($state.File) { Split-Path -Parent $state.File } elseif ($logRoot) { $logRoot } else { $null }
    if (-not $p -or -not (Test-Path -LiteralPath $p)) {
      [System.Windows.MessageBox]::Show($f2,'还没有日志目录。','打开文件夹','OK','Information') | Out-Null
      return
    }
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$p`"" } catch {}
  }.GetNewClosure())
  $copyPath.Add_Click({
    if (-not $state.File) { return }
    try { [System.Windows.Clipboard]::SetText([string]$state.File) } catch {}
  }.GetNewClosure())

  [void]$lt.Children.Add($combo); [void]$lt.Children.Add($refreshBtn); [void]$lt.Children.Add($follow)
  [void]$lt.Children.Add($openDir); [void]$lt.Children.Add($copyPath)
  $dock = New-Object System.Windows.Controls.DockPanel
  $dock.LastChildFill = $true
  $meta.SetValue([System.Windows.Controls.DockPanel]::DockProperty, [System.Windows.Controls.Dock]::Top)
  [void]$dock.Children.Add($meta)
  $lt.SetValue([System.Windows.Controls.DockPanel]::DockProperty, [System.Windows.Controls.Dock]::Top)
  [void]$dock.Children.Add($lt)
  [void]$dock.Children.Add($box)
  $f2.Content = $dock
  & $load
  $f2.Owner = $owner
  $f2.ShowDialog() | Out-Null
}
