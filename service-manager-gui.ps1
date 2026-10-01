#requires -Version 7.0
# service-manager-gui.ps1 — NSSM 服务管理 GUI（WPF 重构）
# 六卡片主视图 · 系统字体 · 双击防抖(8s+健康门闩) · 无黑窗口 · 无托盘
# 配置: services.json · logs/ · lib/*.ps1
#
# 启动路径（任选其一，都不闪黑窗）：
#   桌面 lnk → launch.vbs（wscript 无控制台）→ ShellExecute runas pwsh → 管理员 GUI
#   pwsh -File service-manager-gui.ps1（管理员下直接跑；非管理员会 VBS 提权）

param(
  # CLI 添加服务（agent 友好，不弹 GUI）：-Add Name,Port,Exe[,Url,Dir,Args,Env]
  [string]$Add
)

$root = $PSScriptRoot
$cfg = "$root\services.json"
$logDir = "$root\logs"
$script:nssm = "$env:USERPROFILE\scoop\apps\nssm\current\nssm.exe"

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force $logDir | Out-Null }

# 启动链路日志必须早于提权和 WPF 加载；仅记录阶段，不记录参数或配置值。
$script:crashLog = "$logDir\gui-crash.log"
$script:crashLogMaxBytes = 524288  # 512 KiB；超过则轮转一份 .1（发现 14：无轮转无上限会无限增长）
function Write-CrashLog([string]$m){
  try {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') pid=$PID $m`r`n"
    [IO.File]::AppendAllText($script:crashLog, $line, [Text.UTF8Encoding]::new($false))
    # 简单轮转：超过上限时把当前文件挪成 .1 再开新的。只保留最近一份历史，足够个人工具。
    $info = [IO.FileInfo]$script:crashLog
    if ($info.Exists -and $info.Length -gt $script:crashLogMaxBytes) {
      $bak = "$($script:crashLog).1"
      if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force -EA SilentlyContinue }
      [IO.File]::Move($script:crashLog, $bak)
    }
  } catch {}
}

# ---- CLI 模式：添加服务（不弹 GUI，不提权检测——NSSM 写需管理员，调用方自己提权）----
# 在加载 WPF 程序集之前处理，快速退出
if ($Add) {
  Add-Type -AssemblyName PresentationFramework  # MessageBox 需要
  . "$root\lib\util.ps1"
  $script:svc = Load-Svc
  # CLI 模式没有 runspace，但 add-svc.ps1 用 $sync.gate 加锁——给个本地锁
  $script:sync = @{ gate = [object]::new() }
  . "$root\lib\add-svc.ps1"
  Add-SvcFromCli $Add
  exit 0
}

# ---- GUI 启动：统一入口与早期错误留痕 ----
$ErrorActionPreference = 'Stop'
trap {
  Write-CrashLog "Startup failed: $($_.Exception.GetType().FullName); id=$($_.FullyQualifiedErrorId); line=$($_.InvocationInfo.ScriptLineNumber)"
  [Console]::Error.WriteLine("Service Manager startup failed. See $script:crashLog")
  exit 1
}
$isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-CrashLog "Startup: admin=$isAdmin; apartment=$([Threading.Thread]::CurrentThread.GetApartmentState())"
if (-not $isAdmin) {
  # 与桌面快捷方式共用启动器，避免临时 VBS 的编码/参数拼接漂移。
  Write-CrashLog 'Elevation requested via launch.vbs'
  $launcher = Start-Process -FilePath "$env:WINDIR\System32\wscript.exe" -ArgumentList "`"$root\launch.vbs`"" -WindowStyle Hidden -Wait -PassThru
  Write-CrashLog "Elevation launcher exited: code=$($launcher.ExitCode)"
  exit $launcher.ExitCode
}

# ---- WPF 程序集（PS7 不默认加载）----
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Write-CrashLog 'WPF assemblies loaded'

# ---- 单实例互斥：重复双击启动器时只保留第一个窗口 ----
# Mutex 是进程级的，进程退出 OS 自动释放，不会卡死。放在 Add-Type 之后是因为
# 命中时要静默退出（不弹窗，重复双击是常见操作）；放在提权之后是为了只让管理员实例占锁。
# AbandonedMutexException：前一个实例被任务管理器杀掉或崩溃时，OS 把所有权
# 交给当前进程并抛此异常——不是失败，要当成"已获取"，否则第二个实例也起不来。
$script:appMutex = [System.Threading.Mutex]::new($false, 'Local\service-manager-gui')
$owned = $false
try { $owned = $script:appMutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
  Write-CrashLog 'Already running; another instance holds the mutex'
  exit 0
}
Write-CrashLog 'Single-instance mutex acquired'

# DPI Aware：高缩放屏下不模糊
try {
  Add-Type -Namespace Win32 -Name Dpi -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
  [Win32.Dpi]::SetProcessDPIAware() | Out-Null
} catch {}

# NSSM 预检
if (-not (Test-Path -LiteralPath $script:nssm)) {
  Write-CrashLog 'Startup failed: NSSM dependency missing'
  [System.Windows.MessageBox]::Show("未在 $($script:nssm) 找到 NSSM。`n请用 scoop install nssm 安装后重试。",'依赖缺失','OK','Warning') | Out-Null
  exit 1
}

# ---- 运行期崩溃留痕 ----
[AppDomain]::CurrentDomain.add_UnhandledException({ param($s,$e)
  $x = $e.ExceptionObject
  Write-CrashLog "UnhandledException(terminating=$($e.IsTerminating)): $($x.GetType().FullName): $($x.Message)`n$($x.StackTrace)"
})

# ---- 加载模块 ----
. "$root\lib\theme.ps1"
. "$root\lib\util.ps1"
. "$root\lib\poll.ps1"
. "$root\lib\add-svc.ps1"
. "$root\lib\card.ps1"
. "$root\lib\xaml.ps1"
Write-CrashLog 'GUI modules loaded'

# ---- 加载服务清单 ----
$script:svc = Load-Svc

# ---- 后台 runspace（探测 + 命令执行，UI 线程不碰 I/O）----
$script:queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:cmdQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
# 命令失败反馈：后台 sc.exe 失败时把一句话塞进来，UI 线程取出显示到状态栏
$script:msgQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:sync = [hashtable]::Synchronized(@{
  svc = $script:svc; queue = $script:queue; cmd = $script:cmdQueue; msg = $script:msgQueue
  stop = $false; gate = [object]::new()
  wake = [Threading.AutoResetEvent]::new($false)
})
$bgRS = [runspacefactory]::CreateRunspace()
$bgRS.ApartmentState = 'STA'
$bgRS.ThreadOptions = 'ReuseThread'
$bgRS.Open()
$bgRS.SessionStateProxy.SetVariable('sync', $script:sync)
$bgPS = [powershell]::Create().AddScript($script:poll)
$bgPS.Runspace = $bgRS
$bgHandle = $bgPS.BeginInvoke()

# ---- 收尾：停后台 ----
function Stop-Background {
  $script:sync.stop = $true
  [void]$script:sync.wake.Set()
  try { if ($bgHandle.AsyncWaitHandle.WaitOne(1500)) { $bgPS.EndInvoke($bgHandle) } } catch {}
  try { $bgPS.Stop() } catch {}
  $bgRS.Close(); $bgRS.Dispose(); $bgPS.Dispose()
  $script:sync.wake.Dispose()
}

# ---- 构建主窗口 + 应用 Mica ----
$win = New-MainWindow
if (Test-Path -LiteralPath $script:iconPath) {
  $win.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$script:iconPath)
}
# SourceInitialized 后取 hwnd 调 DwmSetWindowAttribute（handle 已创建，最早能设 Mica 的时机）
$win.Add_SourceInitialized({
  $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($win).EnsureHandle()
  Set-Backdrop $hwnd 2  # 2 = Mica
})

# ---- 渲染分页卡片 ----
Render-Page
Write-CrashLog "Window constructed: cards=$($script:cardPanel.Children.Count)"

# ---- DispatcherTimer：从队列取探测结果更新卡片（替代 WinForms Timer）----
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(400)
$timer.Add_Tick({
  $item = $null
  while ($script:queue.TryDequeue([ref]$item)) { Update-CardData $item.n $item.st $item.h }
  # 后台 sc.exe 失败反馈：非空消息覆盖状态栏，否则 4 秒无操作后自动刷新
  $msg = $null
  while ($script:msgQueue.TryDequeue([ref]$msg)) { $script:statusBar.Text = $msg }
  if (-not $script:lastActionAt -or ([datetime]::Now - $script:lastActionAt).TotalSeconds -ge 4) {
    $script:statusBar.Text = "$(Get-Date -Format 'HH:mm:ss')  状态自动刷新"
  }
})
$timer.Start()

# 坏 JSON 提示
if ($script:configWarning) {
  [System.Windows.MessageBox]::Show("services.json 无效：$($script:configWarning)`n当前使用恢复配置，保存前请修复文件。",'配置错误','OK','Warning') | Out-Null
}

# ---- 显示（Application.Run 等价）----
$win.Add_ContentRendered({ Write-CrashLog 'Window content rendered' })
[void]$win.ShowDialog()
Write-CrashLog "ShowDialog returned (normal exit path)"
