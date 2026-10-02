# tests/test-helpers.ps1 — 跨测试共享的 WPF 可视树遍历与 runspace 夹具
# 抽出以消除 test-card-cache / test-gui-smoke 的 Get-VisualNodes 重复（Reuse-1）
# 与 test-parallel-probe / test-poll-commands 的 Start-FakePoll 重复（Reuse-2）。
# 被 dot-source，不需 #requires（避免被 run-all.ps1 当独立脚本解析）。

# WPF 可视树递归遍历（与 test-gui-smoke 原实现一致）
function Get-VisualNodes($node) {
  $node
  for ($i = 0; $i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($node); $i++) {
    Get-VisualNodes ([Windows.Media.VisualTreeHelper]::GetChild($node, $i))
  }
}

# 起 runspace 跑 poll 脚本块，mock Get-Service 返回指定 Status。
# $count=服务数，$serviceStatus=mock 返回状态（'Stopped'/'Running'），$delayMs=每次 Get-Service 延迟。
# $extraSyncKeys=额外塞进 $shared 的键（如 waitStoppedTimeoutMs），BeginInvoke 前合并——poll 开头只读一次。
# 返回 @{Sync;Runspace;PowerShell;Handle}。Close-FakePoll 清理。
function Start-FakePoll([int]$count, [string]$serviceStatus = 'Stopped', [int]$delayMs = 0, [hashtable]$extraSyncKeys = $null) {
  $services = [ordered]@{}
  for ($i = 0; $i -lt $count; $i++) { $services["Fake$i"] = @{ port = 10000 + $i; url = "http://127.0.0.1:10000/fake$i" } }
  $shared = [hashtable]::Synchronized(@{
    svc = $services; gate = [object]::new(); stop = $false
    queue   = [Collections.Concurrent.ConcurrentQueue[object]]::new()
    cmd     = [Collections.Concurrent.ConcurrentQueue[object]]::new()
    msg     = [Collections.Concurrent.ConcurrentQueue[string]]::new()
    wake    = [Threading.AutoResetEvent]::new($false)
    probeCount = 0; delayMs = $delayMs
    probeStarted = [Threading.AutoResetEvent]::new($false)
    executed     = [Collections.Concurrent.ConcurrentQueue[object]]::new()
    executedReady = [Threading.AutoResetEvent]::new($false)
    nssm = 'Invoke-TestNssm'
  })
  if ($extraSyncKeys) { foreach ($k in $extraSyncKeys.Keys) { $shared[$k] = $extraSyncKeys[$k] } }
  $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.Open()
  $rs.SessionStateProxy.SetVariable('sync', $shared)
  $mocks = @"
function Get-Service {
  [CmdletBinding()]param([string[]]`$Name)
  `$sync.probeCount++
  [void]`$sync.probeStarted.Set()
  if (`$sync.delayMs) { Start-Sleep -Milliseconds `$sync.delayMs }
  foreach (`$n in `$Name) { [pscustomobject]@{ Name=`$n; Status='$serviceStatus' } }
}
function sc.exe {
  `$sync.executed.Enqueue([pscustomobject]@{action=`$args[0];name=`$args[1];probes=`$sync.probeCount})
  [void]`$sync.executedReady.Set()
  `$global:LASTEXITCODE=0
}
function Invoke-TestNssm {
  # remove confirm 等——记一次 nssm 调用，成功退出
  `$sync.executed.Enqueue([pscustomobject]@{action='nssm';name=`$args[1];probes=`$sync.probeCount})
  `$global:LASTEXITCODE=0
}
"@
  $ps = [powershell]::Create().AddScript($mocks).AddScript($script:poll); $ps.Runspace = $rs
  # runspace 里 `& $sync.nssm remove ...` 解析到 sync.nssm 字符串 'Invoke-TestNssm'，
  # 再由 runspace 内定义的同名函数承接。
  [pscustomobject]@{ Sync = $shared; Runspace = $rs; PowerShell = $ps; Handle = $ps.BeginInvoke() }
}

function Close-FakePoll($worker) {
  $worker.Sync.stop = $true; [void]$worker.Sync.wake.Set()
  $worker.PowerShell.Stop(); $worker.PowerShell.Dispose(); $worker.Runspace.Dispose()
  foreach ($name in 'wake', 'executedReady', 'probeStarted') { $worker.Sync[$name].Dispose() }
}
