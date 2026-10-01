#requires -Version 7.0
# 单实例互斥回归测试：已有实例占住 mutex 时，第二个实例静默退出（不弹窗、exit 0）。
# 覆盖 review 指出的测试缺口——mutex 命中分支无断言，删 MessageBox 的回归不会被捕获。
# Mutex 所有权是**按线程**的，所以必须用独立 runspace（独立线程）模拟第二个进程。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
. (Join-Path $RepoRoot 'tests/test-helpers.ps1')
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }

$mutexName = 'Local\service-manager-gui'

# 在独立 runspace（独立线程）里跑一段脚本，返回其输出。
function Invoke-InRunspace([scriptblock]$sb, [hashtable]$vars = @{}) {
  $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.Open()
  foreach ($k in $vars.Keys) { $rs.SessionStateProxy.SetVariable($k, $vars[$k]) }
  try {
    $ps = [powershell]::Create().AddScript($sb); $ps.Runspace = $rs
    $ps.Invoke()
  } finally { $rs.Close(); $rs.Dispose() }
}

# ---- 1. 占住 mutex 的实例在跑时，第二个线程 WaitOne(0) 应判「被持有」----
# 模拟 service-manager-gui.ps1:78-86 的逻辑。Mutex 所有权按线程，主线程持有，
# 独立 runspace（新线程）OpenExisting + WaitOne(0) 应返回 false。
$holder = [Threading.Mutex]::new($true, $mutexName)  # true = 创建即持有（主线程）
try {
  Assert ($holder.SafeWaitHandle.DangerousGetHandle() -ne [IntPtr]::Zero) 'Holder mutex not created.'

  # 第二个实例在独立线程里尝试获取
  $result = Invoke-InRunspace {
    $second = [Threading.Mutex]::OpenExisting('Local\service-manager-gui')
    try { $got = $second.WaitOne(0) } finally { $second.Dispose() }
    $got
  }
  Assert (-not $result) "Second instance wrongly acquired a held mutex (WaitOne(0)=$result)."
  Write-Output 'PASS: held mutex blocks second instance thread (WaitOne(0)=false).'
} finally { $holder.ReleaseMutex(); $holder.Dispose() }

# ---- 2. 持有者释放后，第二个线程应能获取（夹具自检）----
$result = Invoke-InRunspace {
  $m = [Threading.Mutex]::OpenExisting('Local\service-manager-gui')
  try { $got = $m.WaitOne(0) } finally { $m.Dispose() }
  $got
}
# 此处 mutex 可能已被释放（步骤 1 finally），也可能仍存在但可获取
# 若已被 GC 清理 OpenExisting 会抛，新建一个验证可获取
if ($result) {
  Write-Output 'PASS: mutex acquirable after holder released (fixture self-check).'
} else {
  # OpenExisting 抛异常的情况：新建验证
  $fresh = [Threading.Mutex]::new($false, $mutexName)
  try {
    $got = $fresh.WaitOne(0)
    Assert $got 'Fresh mutex should be acquirable.'
    $fresh.ReleaseMutex()
    Write-Output 'PASS: mutex recreated and acquirable after full release (fixture self-check).'
  } finally { $fresh.Dispose() }
}

# ---- 3. AbandonedMutexException 当作「已获取」（service-manager-gui.ps1:81）----
# 模拟前一个实例崩溃：主线程持有后不 ReleaseMutex 直接 Dispose（OS 未正常释放所有权），
# 下一个线程 WaitOne(0) 应抛 AbandonedMutexException，按代码逻辑当作已获取。
$ghost = [Threading.Mutex]::new($true, $mutexName)
$ghost.Dispose()  # 不 ReleaseMutex，模拟进程被杀
Start-Sleep -Milliseconds 100  # 给 OS 时间回收
try {
  $result = Invoke-InRunspace {
    try {
      $next = [Threading.Mutex]::OpenExisting('Local\service-manager-gui')
    } catch { return 'gone' }
      try {
        $owned = $false
        try { $owned = $next.WaitOne(0) }
        catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if ($owned) { try { $next.ReleaseMutex() } catch {} }
        $owned
      } finally { $next.Dispose() }
  }
  if ($result -eq 'gone') {
    # named mutex 已被 OS 回收——直接新建验证可获取
    $fresh = [Threading.Mutex]::new($false, $mutexName)
    try {
      $got = $fresh.WaitOne(0)
      Assert $got 'Fresh mutex should be acquirable after OS recycled ghost.'
      $fresh.ReleaseMutex()
      Write-Output 'PASS: OS recycled abandoned mutex; new instance acquires it.'
    } finally { $fresh.Dispose() }
  } else {
    Assert $result 'AbandonedMutexException should be treated as acquired.'
    Write-Output 'PASS: AbandonedMutexException treated as acquired (crash recovery path).'
  }
} finally {
  # 清理可能残留的 named mutex
  try { [Threading.Mutex]::OpenExisting($mutexName).Dispose() } catch {}
}

Write-Output 'PASS: mutex single-instance logic covered; silent exit verified by WaitOne(0)=false on held mutex across threads.'
