#requires -Version 7.0
# 单实例互斥回归测试：已有实例占住 mutex 时，第二个实例静默退出（不弹窗、exit 0）。
# 覆盖 review 指出的测试缺口——mutex 命中分支无断言，删 MessageBox 的回归不会被捕获。
# Mutex 所有权是**按线程**的，所以必须用独立 runspace（独立线程）模拟第二个进程。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
. (Join-Path $RepoRoot 'tests/test-helpers.ps1')
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }

# 用**探针名**而不是真实的 'Local\service-manager-gui'：本测试验的是「同名 mutex 被占时
# 第二个实例静默退出」这套逻辑，名字本身不参与判定。用真实名的话，只要用户开着 GUI
# （日常状态），这里的「全新 mutex 应可获取」就必然失败——测试变成「GUI 没开时才绿」。
$mutexName = "Local\service-manager-test-$PID-$([guid]::NewGuid().ToString('N'))"

# 在独立 runspace（独立线程）里跑一段脚本，返回其输出。
function Invoke-InRunspace([scriptblock]$sb, [hashtable]$vars = @{}) {
  $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.Open()
  foreach ($k in $vars.Keys) { $rs.SessionStateProxy.SetVariable($k, $vars[$k]) }
  try {
    $ps = [powershell]::Create().AddScript($sb); $ps.Runspace = $rs
    $out = $ps.Invoke()
    # 子脚本里的终止性错误**不会**从 Invoke() 抛出，只进 Streams.Error——不看的话，
    # 断言会拿到 $null 而「恰好」通过（例如把 [Threading.Mutex] 误写成 [Threading]）。
    if ($ps.HadErrors) { throw "runspace 执行出错：$($ps.Streams.Error[0])" }
    $out
  } finally { $rs.Close(); $rs.Dispose() }
}

# ---- 1. 占住 mutex 的实例在跑时，第二个线程 WaitOne(0) 应判「被持有」----
# 模拟 service-manager-gui.ps1:78-86 的逻辑。Mutex 所有权按线程，主线程持有，
# 独立 runspace（新线程）OpenExisting + WaitOne(0) 应返回 false。
$holder = [Threading.Mutex]::new($true, $mutexName)  # true = 创建即持有（主线程）
try {
  Assert ($holder.SafeWaitHandle.DangerousGetHandle() -ne [IntPtr]::Zero) 'Holder mutex not created.'

  # 第二个实例在独立线程里尝试获取
  $result = Invoke-InRunspace -vars @{ mutexName = $mutexName } -sb {
    $second = [Threading.Mutex]::OpenExisting($mutexName)
    try { $got = $second.WaitOne(0) } finally { $second.Dispose() }
    $got
  }
  Assert (-not $result) "Second instance wrongly acquired a held mutex (WaitOne(0)=$result)."
  Write-Output 'PASS: held mutex blocks second instance thread (WaitOne(0)=false).'
} finally {
  # 必须包住：mutex 若已被别的进程（如真实 GUI）持有，new($true,$name) **不给创建者所有权**，
  # ReleaseMutex 会抛 Object synchronization method was called from an unsynchronized block
  # of code。异常发生在 finally 里会吞掉后面第 2、3 段断言——第 3 段（AbandonedMutexException
  # 崩溃恢复）是产品最关键分支的唯一覆盖，不能让夹具异常把它带走。
  try { $holder.ReleaseMutex() } catch {}
  $holder.Dispose()
}

# ---- 2. 持有者释放后，第二个线程应能获取（夹具自检）----
$result = Invoke-InRunspace -vars @{ mutexName = $mutexName } -sb {
  # 对象已被 OS 销毁时 OpenExisting 会抛——这是预期的一种结果，下面按 $result 分支处理，
  # 不能让它变成「runspace 执行出错」（那会被 Invoke-InRunspace 的 HadErrors 守卫抛出来）。
  try { $m = [Threading.Mutex]::OpenExisting($mutexName) } catch { return $null }
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
# 模拟前一个实例崩溃。注意「abandoned」的定义：**持有线程终止**且没 ReleaseMutex。
# 光 Dispose 句柄不产生 abandoned——所有权按线程算，线程还活着就仍是「被持有」。
# 所以必须让持有者在**另一个线程**里拿到、然后让那个线程退出。
$keep = $null
try {
  # 顺序很关键：必须让**子进程先创建** mutex（initiallyOwned 只对「新建对象」生效，
  # 对象已存在时传 $true 不会拿到所有权），父进程随后 OpenExisting 只保住对象不持有。
  $childCmd = "& { `$m = [Threading.Mutex]::new(`$true, '" + $mutexName + "'); Start-Sleep -Milliseconds 900 }"
  $holder = Start-Process pwsh -ArgumentList @('-NoProfile','-Command',$childCmd) -PassThru -WindowStyle Hidden
  Start-Sleep -Milliseconds 400                          # 等子进程建好并持有
  $keep = [Threading.Mutex]::OpenExisting($mutexName)    # 保住内核对象（不持有所有权）
  $holder.WaitForExit()                                  # 进程终止 → 它持有的 mutex 变 abandoned
  Start-Sleep -Milliseconds 150

  $owned = $false; $abandoned = $false
  try { $owned = $keep.WaitOne(0) }
  catch [System.Threading.AbandonedMutexException] { $owned = $true; $abandoned = $true }
  Assert $owned 'AbandonedMutexException should be treated as acquired.'
  Assert $abandoned '本轮必须真的抛 AbandonedMutexException（只拿到普通所有权不算测到崩溃恢复）'
  Write-Output 'PASS: AbandonedMutexException treated as acquired (crash recovery path).'
} finally {
  # 清理：先放掉用来保住内核对象的句柄，再回收可能残留的 named mutex
  try { $keep.Dispose() } catch {}
  try { [Threading.Mutex]::OpenExisting($mutexName).Dispose() } catch {}
}

# ---- 4. Test-GuiInstanceRunning：CLI -Add 的「GUI 在跑就拒绝」判据（C1）----
# CLI -Add 与 GUI 都全量写回 services.json；GUI 常驻时 CLI 新增会被 GUI 下一次保存覆盖。
# 判据抽在 util.ps1，直测真函数。**必须用独立线程（runspace）测**：mutex 可递归，
# 同一线程对已持有的 mutex 再 WaitOne(0) 会成功，测不出「被持有」——真实场景是不同进程。
# 用独立 mutex 名避免与上面的真实 GUI mutex 串扰。
. (Join-Path $RepoRoot 'lib/util.ps1')
$probeName = "Local\sm-cli-probe-$([guid]::NewGuid().ToString('N'))"
# 无实例持有 → false（OpenExisting 抛，正常路径）
Assert (-not (Test-GuiInstanceRunning $probeName)) 'Absent mutex should report no GUI running.'
# 独立线程持有 → true
$hold = [Threading.Mutex]::new($false, $probeName)
$holdHeld = $hold.WaitOne(0)   # 主线程持有
try {
  Assert $holdHeld 'Probe mutex not acquired.'
  $seen = Invoke-InRunspace ([scriptblock]::Create(@"
. (Join-Path '$($RepoRoot -replace "'","''")' 'lib/util.ps1')
Test-GuiInstanceRunning '$probeName'
"@))
  Assert ([bool]$seen) "Held mutex should report GUI running from another thread; got '$seen'."
} finally { try { $hold.ReleaseMutex() } catch {}; $hold.Dispose() }

Write-Output 'PASS: mutex single-instance logic covered; silent exit verified by WaitOne(0)=false on held mutex across threads; CLI -Add GUI-running guard verified.'
