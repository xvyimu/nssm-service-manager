# lib/tray.ps1 — 可选托盘图标（config.json 的 TrayEnabled 打开才加载 WinForms）
#
# 设计：决策与副作用分离。
#   Get-CloseAction / Get-MinimizeAction 是纯函数，只读 config，可被单测直接调用；
#   Initialize-Tray 才真正创建 NotifyIcon（按需 Add-Type WinForms，禁用时不付这份成本）。
# 默认 TrayEnabled=false，行为与历史一致：最小化进任务栏、关闭即退出。

# 关闭窗口时该做什么：'tray'=收进托盘，'exit'=真正退出（默认）。
# 两个开关都要开才进托盘——只开 CloseToTray 而不开 TrayEnabled 没有托盘可收，按退出处理。
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

# 创建托盘图标（幂等）。WinForms 程序集在此按需加载——未启用托盘的机器不加载。
function Initialize-Tray($window){
  if($script:trayIcon){ return $script:trayIcon }
  # 必须存 $script: —— PowerShell scriptblock 非闭包，函数返回后 $window 局部变量脱作用域，
  # 托盘菜单的「显示主窗口」处理器会解析到 $null（与 xaml.ps1 的 $script:toggleMax 同因）。
  $script:trayWindow = $window
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  $ni = [System.Windows.Forms.NotifyIcon]::new()
  if($script:iconPath -and (Test-Path -LiteralPath $script:iconPath)){
    try { $ni.Icon = [System.Drawing.Icon]::new($script:iconPath) } catch {}
  }
  $ni.Text = '服务管理'

  $menu = [System.Windows.Forms.ContextMenuStrip]::new()
  $show = $menu.Items.Add('显示主窗口')
  $exit = $menu.Items.Add('退出')
  $restore = {
    $w = $script:trayWindow
    if(-not $w){ return }
    $w.Show()
    if($w.WindowState -eq 'Minimized'){ $w.WindowState = 'Normal' }
    $w.Activate() | Out-Null
  }
  $show.add_Click($restore)
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
}
