# lib/tray.ps1 — 可选托盘图标（config.json 的 TrayEnabled 打开才加载 WinForms）
# 决策（纯函数，只读 config）与副作用（Initialize-Tray 才 Add-Type WinForms）分离；默认 TrayEnabled=false：最小化进任务栏、关闭即退出。

# 关闭窗口时该做什么：两个开关都开才进托盘，只开 CloseToTray 而无 TrayEnabled 按退出处理。
function Get-CloseAction($config){
  if($config -and $config.TrayEnabled -and $config.CloseToTray){ 'tray' } else { 'exit' }
}

# 点最小化时该做什么：'tray'=收进托盘，'minimize'=常规最小化（默认）。
function Get-MinimizeAction($config){
  if($config -and $config.TrayEnabled -and $config.MinimizeToTray){ 'tray' } else { 'minimize' }
}

# 托盘「退出」置位后，Closing 不再取消，窗口真正关闭 → Closed 里 Stop-Background + Remove-Tray。
$script:trayExitRequested = $false
$script:trayIcon = $null
$script:trayMenu = $null
# 首次收进托盘只提示一次：窗口消失不等于退出，用户第一次会找不着程序。
$script:trayHintShown = $false

# tooltip / 菜单用的计数文案。N=清单里的服务数，M=正在切换（含待保存）的数量。
# 读 $script:svc 与 $script:svcState；任一处拿不到就退回「服务管理」，不让 tooltip 抛异常。
function Get-TrayStatusText {
  try {
    $count = 0
    if ($script:svc) { $count = @($script:svc.Keys).Count }
    if ($count -le 0) { return '服务管理' }
    $pending = 0
    if ($script:svcState) {
      $pending += @($script:svcState.Values | Where-Object { $_.st -and $_.st -in @('启动中','停止中','删除中') }).Count
    }
    if ($script:cards) {
      $pending += @($script:cards.Values | Where-Object { $_.PendingSave }).Count
    }
    if ($pending -gt 0) { "服务管理 · $count 个服务 · $pending 个待处理" } else { "服务管理 · $count 个服务" }
  } catch { '服务管理' }
}

# 每帧刷新 tooltip（由 Update-FreshnessPill 调用）。NotifyIcon.Text 上限 63 字符，超了会抛。
function Update-TrayText {
  if (-not $script:trayIcon) { return }
  try {
    $t = Get-TrayStatusText
    if ($t -and $t.Length -gt 63) { $t = $t.Substring(0,63) }
    if ($script:trayIcon.Text -ne $t) { $script:trayIcon.Text = $t }
  } catch {}
}

# 首次「收进托盘」弹一次气泡。
function Show-TrayHint {
  if (-not $script:trayIcon -or $script:trayHintShown) { return }
  $script:trayHintShown = $true
  try {
    $script:trayIcon.ShowBalloonTip(4000, '服务管理', '仍在后台运行。要彻底退出，请用托盘菜单的「退出」。', [System.Windows.Forms.ToolTipIcon]::Info)
  } catch {}
}

# 打开日志目录（托盘菜单）。目录取自调用方脚本作用域的 $logDir；没有就提示一句。
function Invoke-TrayOpenLogs {
  $dir = if ($script:logDir) { [string]$script:logDir } else { $null }
  if (-not $dir -or -not (Test-Path -LiteralPath $dir)) {
    try { $script:trayIcon.ShowBalloonTip(3000, '服务管理', '还没有日志目录。', [System.Windows.Forms.ToolTipIcon]::Info) } catch {}
    return
  }
  try { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$dir`"" } catch {}
}

# 创建托盘图标（幂等）。WinForms 程序集在此按需加载——未启用托盘的机器不加载。
function Initialize-Tray($window){
  if($script:trayIcon){ return $script:trayIcon }
  # 必须存 $script:：scriptblock 非闭包，函数返回后 $window 脱作用域会解析到 $null（同 xaml.ps1 $script:toggleMax）。
  $script:trayWindow = $window
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  $ni = [System.Windows.Forms.NotifyIcon]::new()
  if($script:iconPath -and (Test-Path -LiteralPath $script:iconPath)){
    try { $ni.Icon = [System.Drawing.Icon]::new($script:iconPath) } catch {}
  }
  $ni.Text = Get-TrayStatusText

  $menu = [System.Windows.Forms.ContextMenuStrip]::new()
  $show = $menu.Items.Add('显示主窗口')
  $startAll = $menu.Items.Add('全部启动')
  $stopAll = $menu.Items.Add('全部停止')
  $openLogs = $menu.Items.Add('打开日志目录')
  [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
  $exit = $menu.Items.Add('退出')
  $restore = {
    $w = $script:trayWindow
    if(-not $w){ return }
    $w.Show()
    if($w.WindowState -eq 'Minimized'){ $w.WindowState = 'Normal' }
    $w.Activate() | Out-Null
  }
  # 事件脚本块不是闭包：别的处理器要调用它就必须存 $script:，否则解析到 $null。
  $script:trayRestore = $restore
  $show.add_Click($restore)
  # 批量入口：与状态栏右键同一个 Invoke-BatchCommand（同一套「只处理终态 + 过期跳过」）。
  $startAll.add_Click({
    try { $m = Invoke-BatchCommand 'start' } catch { $m = $_.Exception.Message }
    if ($m) { Set-StatusMessage $m }
  })
  $stopAll.add_Click({
    # 停止要先过二次确认，确认框以主窗口为 owner：窗口藏着就先把窗口叫出来，否则框看不见。
    if ($script:trayRestore) { & $script:trayRestore }
    try { $m = Invoke-BatchCommand 'stop' } catch { $m = $_.Exception.Message }
    if ($m) { Set-StatusMessage $m }
  })
  $openLogs.add_Click({ Invoke-TrayOpenLogs })
  # 托盘退出：置位后 Close() 不再被 Closing 取消，走正常退出路径
  $exit.add_Click({ $script:trayExitRequested = $true; $script:trayWindow.Close() })
  $ni.ContextMenuStrip = $menu
  $ni.add_MouseDoubleClick($restore)


  $ni.Visible = $true
  $script:trayIcon = $ni
  $script:trayMenu = $menu
  $ni
}

# 移除托盘图标（退出时调用；幂等）。
function Remove-Tray {
  if($script:trayIcon){
    try { $script:trayIcon.Visible = $false } catch {}
    try { $script:trayIcon.Dispose() } catch {}
    $script:trayIcon = $null
  }
  if($script:trayMenu){
    try { $script:trayMenu.Dispose() } catch {}
    $script:trayMenu = $null
  }
  $script:trayWindow = $null
  $script:trayRestore = $null
}
