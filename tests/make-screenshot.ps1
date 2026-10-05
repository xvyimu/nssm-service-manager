#requires -Version 7.0
# 离屏渲染主窗口并导出 PNG（README 截图用）。
# 不启提权、不碰 NSSM/服务：只加载模块、建窗口、填假状态、渲染到 RenderTargetBitmap。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
foreach ($module in 'theme','util','card','xaml') { . (Join-Path $RepoRoot "lib/$module.ps1") }

# 假配置：避开本机 services.json，用示例清单（截图不含真实服务名）
$script:svc = [ordered]@{
  'MyAPI'    = @{ port = 3000;  url = 'http://127.0.0.1:3000' }
  'RouterA'  = @{ port = 20128; url = 'http://127.0.0.1:20128/dashboard' }
  'RouterB'  = @{ port = 20129; url = 'http://127.0.0.1:20129/dashboard' }
  'ProxyA'   = @{ port = 8317;  url = 'http://127.0.0.1:8317/management.html' }
  'BuddyAPI' = @{ port = 7863;  url = 'http://127.0.0.1:7863/panel/' }
  'ServiceF' = @{ port = 9000;  url = 'http://127.0.0.1:9000/health' }
}
$script:cmdQueue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:sync = @{ wake = [Threading.AutoResetEvent]::new($false) }
function Stop-Background {}

$win = New-MainWindow
try {
  Render-Page
  # 填一批有代表性的状态，让截图体现颜色分档
  $states = @(
    @('MyAPI','运行中','正常'), @('RouterA','运行中','正常'), @('RouterB','运行中','超时'),
    @('ProxyA','已停止',''), @('BuddyAPI','运行中','无响应'), @('ServiceF','运行中','正常')
  )
  foreach ($s in $states) { Update-CardData $s[0] $s[1] $s[2] }
  # 截图用状态栏文案：走 Set-StatusMessage 与生产代码同一条路径（含显示租约），
  # 免得截图里的状态栏与真实运行时的不一致。
  Set-StatusMessage "$(Get-Date -Format 'HH:mm:ss')  状态自动刷新"

  $win.WindowStartupLocation = 'Manual'
  $win.Left = -20000; $win.Top = -20000
  $win.ShowInTaskbar = $false
  $win.Show(); $win.UpdateLayout()

  # 等布局稳定（WPF 首帧需要一次 dispatcher 轮转）
  $win.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)

  $w = [int]$win.ActualWidth; $h = [int]$win.ActualHeight
  $rtb = [Windows.Media.Imaging.RenderTargetBitmap]::new($w, $h, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
  $rtb.Render($win)
  $enc = [Windows.Media.Imaging.PngBitmapEncoder]::new()
  $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
  $out = Join-Path $RepoRoot 'assets/screenshot.png'
  $fs = [IO.File]::Create($out)
  try { $enc.Save($fs) } finally { $fs.Dispose() }
  Write-Output "PASS: wrote $out ($w x $h, $((Get-Item $out).Length) bytes)"
} finally {
  if ($win.IsLoaded) { $win.Close() }
  $script:sync.wake.Dispose()
}
