#requires -Version 7.0
# 离屏渲染主窗口逐帧导出 PNG 序列，再用 ffmpeg 合成演示 GIF（README 动图用）。
# 与 make-screenshot.ps1 同构：不启提权、不碰 NSSM/服务，只加载模块、建窗口、填状态、逐帧渲染。
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
  'TTSShim'  = @{ port = 8001;  url = 'http://127.0.0.1:8001/health' }
}
$script:cmdQueue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:sync = @{ wake = [Threading.AutoResetEvent]::new($false) }
function Stop-Background {}

$win = New-MainWindow
try {
  Render-Page
  # 初态：一组有代表性的健康分档（绿/橙/红/灰），让动图开头就是完整全览
  $initial = @(
    @('MyAPI','运行中','正常'), @('RouterA','运行中','正常'), @('RouterB','运行中','正常'),
    @('ProxyA','已停止',''), @('BuddyAPI','运行中','无响应'), @('TTSShim','运行中','正常')
  )
  foreach ($s in $initial) { Update-CardData $s[0] $s[1] $s[2] }

  $win.WindowStartupLocation = 'Manual'
  $win.Left = -20000; $win.Top = -20000
  $win.ShowInTaskbar = $false
  $win.Show(); $win.UpdateLayout()

  # 帧序列：RouterB 走一遍「停止中→已停止→启动中→运行中(超时)→运行中(正常)」，
  # 状态栏文字同步变化——演示启停交互与健康三档颜色分档。
  $frames = @(
    @('RouterB','停止中','','RouterB 停止中...'),
    @('RouterB','停止中','','RouterB 停止中...  等待服务退出'),
    @('RouterB','已停止','','RouterB 已停止  随时可以启动'),
    @('RouterB','已停止','','RouterB 已停止  随时可以启动'),
    @('RouterB','启动中','','RouterB 启动中...'),
    @('RouterB','启动中','','RouterB 启动中...  等待端口就绪'),
    @('RouterB','运行中','超时','RouterB 运行中（超时）  服务响应慢'),
    @('RouterB','运行中','超时','RouterB 运行中（超时）  服务响应慢'),
    @('RouterB','运行中','正常','RouterB 运行中  服务响应正常'),
    @('RouterB','运行中','正常','6 个本地服务  全部就绪'),
    @('RouterB','运行中','正常','双击启停 · 右键更多操作'),
    @('RouterB','运行中','正常',"$(Get-Date -Format 'HH:mm:ss')  状态自动刷新")
  )

  $tmp = Join-Path $RepoRoot '.demo-tmp'
  New-Item -ItemType Directory -Force $tmp | Out-Null
  $n = 0
  foreach ($f in $frames) {
    Update-CardData $f[0] $f[1] $f[2]
    $script:statusBar.Text = $f[3]
    $win.UpdateLayout()
    $win.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
    $w=[int]$win.ActualWidth; $h=[int]$win.ActualHeight
    $rtb=[Windows.Media.Imaging.RenderTargetBitmap]::new($w,$h,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($win)
    $enc=[Windows.Media.Imaging.PngBitmapEncoder]::new()
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs=[IO.File]::Create((Join-Path $tmp ("frame-{0:D2}.png" -f $n)))
    try { $enc.Save($fs) } finally { $fs.Dispose() }
    $n++
  }
  Write-Output "PASS: wrote $n frames to $tmp"
} finally {
  if ($win.IsLoaded) { $win.Close() }
  $script:sync.wake.Dispose()
}