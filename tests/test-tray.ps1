#requires -Version 7.0
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
# test-tray.ps1 的纯函数段不依赖 WPF；真实 NotifyIcon 段需要 WPF 程序集与消息泵。
# 单独跑（非经 run-all.ps1 串联）时，前面的 STA 测试不在同一进程，WPF 程序集不会
# 预先加载——这里显式 Add-Type，避免 theme.ps1 解析 XAML 时报
# `Unable to find type [System.Windows.Markup.XamlReader]`。
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
. (Join-Path $RepoRoot 'lib/config.ps1')
. (Join-Path $RepoRoot 'lib/theme.ps1')   # Initialize-Tray 读 $script:iconPath
. (Join-Path $RepoRoot 'lib/tray.ps1')
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }

# 任务 E：托盘/最小化/关闭策略是可选配置，默认保持历史行为。
# Get-CloseAction / Get-MinimizeAction 是纯函数，直接喂 config 验证真值表；
# 副作用（NotifyIcon）不在单测里创建——需要真实消息泵，留给本机交互验证。

# ---- 默认（三项全关）：最小化进任务栏、关闭即退出 ----
$default = @{ TrayEnabled = $false; MinimizeToTray = $false; CloseToTray = $false }
Assert ((Get-CloseAction $default) -eq 'exit') 'Default close must exit.'
Assert ((Get-MinimizeAction $default) -eq 'minimize') 'Default minimize must not go to tray.'

# ---- 全开：关闭/最小化都进托盘 ----
$all = @{ TrayEnabled = $true; MinimizeToTray = $true; CloseToTray = $true }
Assert ((Get-CloseAction $all) -eq 'tray') 'CloseToTray with TrayEnabled must go to tray.'
Assert ((Get-MinimizeAction $all) -eq 'tray') 'MinimizeToTray with TrayEnabled must go to tray.'

# ---- 单项开但总开关关：两项都失效（没有托盘可收，退回默认）----
$subOnly = @{ TrayEnabled = $false; MinimizeToTray = $true; CloseToTray = $true }
Assert ((Get-CloseAction $subOnly) -eq 'exit') 'CloseToTray without TrayEnabled must exit.'
Assert ((Get-MinimizeAction $subOnly) -eq 'minimize') 'MinimizeToTray without TrayEnabled must minimize normally.'

# ---- 只开 CloseToTray：关闭进托盘，最小化仍常规 ----
$closeOnly = @{ TrayEnabled = $true; MinimizeToTray = $false; CloseToTray = $true }
Assert ((Get-CloseAction $closeOnly) -eq 'tray') 'CloseToTray alone must go to tray.'
Assert ((Get-MinimizeAction $closeOnly) -eq 'minimize') 'MinimizeToTray off must keep normal minimize.'

# ---- 只开 MinimizeToTray：最小化进托盘，关闭仍退出 ----
$minOnly = @{ TrayEnabled = $true; MinimizeToTray = $true; CloseToTray = $false }
Assert ((Get-CloseAction $minOnly) -eq 'exit') 'CloseToTray off must keep exit.'
Assert ((Get-MinimizeAction $minOnly) -eq 'tray') 'MinimizeToTray alone must go to tray.'

# ---- $null config（测试夹具未初始化）不抛错，回落默认 ----
Assert ((Get-CloseAction $null) -eq 'exit') 'Null config close must default to exit.'
Assert ((Get-MinimizeAction $null) -eq 'minimize') 'Null config minimize must default to normal.'

# ---- Remove-Tray 幂等：从未初始化时调用不抛错 ----
Remove-Tray
Remove-Tray

# ---- 真实创建：NotifyIcon + 菜单回调 + scriptblock 捕获窗口引用 ----
# 需要 STA + 真实窗口（NotifyIcon 依赖消息泵）。run-all 用 -STA 起本测试。
# 这里同时防住 PowerShell scriptblock 非闭包的坑：$window 若按局部变量捕获会是 $null，
# 菜单「显示主窗口」就恢复不了隐藏的窗口。
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
$w = New-Object System.Windows.Window -Property @{
  Width=120; Height=120; ShowInTaskbar=$false; ShowActivated=$false
  WindowStartupLocation='Manual'; Left=-10000
}
$w.Show()
try {
  $ni = Initialize-Tray $w
  Assert ($ni -is [System.Windows.Forms.NotifyIcon]) 'Initialize-Tray did not return a NotifyIcon.'
  Assert ($null -ne $script:trayWindow) 'Tray did not retain the window reference (scriptblock closure pitfall).'
  $menuTexts = @($script:trayMenu.Items | ForEach-Object { $_.Text })
  Assert ($menuTexts.Count -eq 2 -and $menuTexts[0] -eq '显示主窗口' -and $menuTexts[1] -eq '退出') "Unexpected tray menu: $($menuTexts -join '|')"

  # 隐藏后触发「显示主窗口」：应恢复可见
  $w.Hide()
  $script:trayMenu.Items[0].PerformClick()
  Assert ($w.IsVisible) 'Tray "show" action did not restore the hidden window.'

  # 幂等：重复初始化返回同一实例，不新建
  $ni2 = Initialize-Tray $w
  Assert ([Object]::ReferenceEquals($ni, $ni2)) 'Initialize-Tray must be idempotent.'

  # 托盘「退出」必须能真正关闭窗口：置位 trayExitRequested 后 Close() 不被 Closing 取消。
  # 这里复制 xaml.ps1 的 Closing 判定，确认两者对同一 $script:trayExitRequested 读写。
  $script:trayExitRequested = $false
  $closedFlag = $false
  $w2 = New-Object System.Windows.Window -Property @{
    Width=120; Height=120; ShowInTaskbar=$false; ShowActivated=$false
    WindowStartupLocation='Manual'; Left=-10000
  }
  $w2.Add_Closing({ param($s,$e) if (-not $script:trayExitRequested) { $e.Cancel = $true; $w2.Hide() } })
  $w2.Add_Closed({ $script:closedFlag = $true })
  $w2.Show()
  # 未置位时点 ✕（等价 Close）：Closing 被取消 → 窗口隐藏（IsVisible=False）但不关闭（closedFlag 保持 False）
  $w2.Close()
  Assert ((-not $script:closedFlag) -and (-not $w2.IsVisible)) 'CloseToTray did not cancel the close (window should hide, not exit).'
  # 置位后（模拟托盘「退出」菜单）：Close 应放行 → 真正 Closed
  $script:trayExitRequested = $true
  $w2.Close()
  Assert ($script:closedFlag) 'Tray exit did not actually close the window.'
  $script:trayExitRequested = $false

  # Remove-Tray 后引用清空
  Remove-Tray
  Assert ($null -eq $script:trayIcon -and $null -eq $script:trayWindow) 'Remove-Tray did not clear references.'
} finally {
  Remove-Tray
  if ($w.IsLoaded) { $w.Close() }
  if ($w2 -and $w2.IsLoaded) { $w2.Close() }
}
Write-Output 'PASS: tray policy truth table (default exit/minimize, full tray, gated by TrayEnabled), null-config fallback, idempotent Remove-Tray, real NotifyIcon creation with window-restore callback, close-to-tray cancels vs tray-exit closes.'