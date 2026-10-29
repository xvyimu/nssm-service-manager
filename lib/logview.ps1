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

# 日志查看器（闭包 hashtable 持久切换状态）。§Show-Log
function Show-Log([string]$n, $owner){
  $f2 = New-Object System.Windows.Window -Property @{
    Title = "$n 日志"; Width = 760; Height = 520; WindowStartupLocation='CenterOwner'
    Background = [System.Windows.Media.Brushes]::White
  }
  $box = New-Object System.Windows.Controls.TextBox -Property @{
    IsReadOnly = $true; FontFamily = $script:cjkFont; FontSize = 10
    VerticalScrollBarVisibility = 'Auto'; TextWrapping = 'NoWrap'
    Background = [System.Windows.Media.Brushes]::White; Foreground = [System.Windows.Media.Brushes]::Black
  }
  $lt = New-Object System.Windows.Controls.StackPanel -Property @{ Orientation='Horizontal' }
  # 当前日志 + 轮转历史下拉；切换时重新加载
  $state = @{ File = $null }
  $combo = New-Object System.Windows.Controls.ComboBox -Property @{ Margin='4,2'; MinWidth=220 }
  $refreshBtn = New-Object System.Windows.Controls.Button -Property @{ Content='🔄 刷新'; Margin='4,2' }

  $load = {
    $box.Clear()
    $f3 = $state.File
    if (-not $f3 -or -not (Test-Path -LiteralPath $f3)) { $box.Text = "无日志"; return }
    # 逐行读，固定容量队列只留最后 500 行——避免把整个大日志物化到内存
    $tail = [System.Collections.Generic.Queue[string]]::new(500)
    foreach ($l in [System.IO.File]::ReadLines($f3)) {
      if ($tail.Count -ge 500) { [void]$tail.Dequeue() }
      $tail.Enqueue($l)
    }
    $box.Text = ($tail -join "`r`n")
    $box.ScrollToEnd()
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

  [void]$lt.Children.Add($combo); [void]$lt.Children.Add($refreshBtn)
  $dock = New-Object System.Windows.Controls.DockPanel
  $dock.LastChildFill = $true
  $lt.SetValue([System.Windows.Controls.DockPanel]::DockProperty, [System.Windows.Controls.Dock]::Top)
  [void]$dock.Children.Add($lt)
  [void]$dock.Children.Add($box)
  $f2.Content = $dock
  & $load
  $f2.Owner = $owner
  $f2.ShowDialog() | Out-Null
}
