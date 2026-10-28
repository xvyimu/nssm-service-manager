# tests/test-helpers.ps1 — 跨测试共享的 WPF 可视树遍历与 runspace 夹具
# 抽出以消除多个测试里 Get-VisualNodes / Start-FakePoll 的重复实现。
# 被 dot-source，不需 #requires（避免被 run-all.ps1 当独立脚本解析）。

# WPF 可视树递归遍历
function Get-VisualNodes($node) {
  $node
  for ($i = 0; $i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($node); $i++) {
    Get-VisualNodes ([Windows.Media.VisualTreeHelper]::GetChild($node, $i))
  }
}

# 起 runspace 跑 poll 脚本块，mock Get-Service 返回指定 Status。
# $count=服务数，$serviceStatus=mock 返回状态（'Stopped'/'Running'），$delayMs=每次 Get-Service 延迟。
# $extraSyncKeys=额外塞进 $shared 的键（如 waitStoppedTimeoutMs），BeginInvoke 前合并——poll 开头只读一次。
# $scExitCode=非零时让替身 sc.exe 返回该退出码（模拟启停失败；默认 0=成功）。
# $controllerStatus=非空时给 runspace 注入 $sync.newSc='New-TestSc'，由替身 ServiceController
#   返回该状态（如 StartPending）。真实 ServiceController 构造在 runspace 里无法替身化，
#   中间态只能从这里进；未设时 poll 走真实 ServiceController。
# 返回 @{Sync;Runspace;PowerShell;Handle}。Close-FakePoll 清理。
# $statusMap=按服务名指定状态（如 @{Fake0='Running';Fake1='StartPending'}），未列出的用 $serviceStatus。
#   混合状态用来验「有服务卡在中间态时，其它运行中服务的状态仍要按时送达」。
function Start-FakePoll([int]$count, [string]$serviceStatus = 'Stopped', [int]$delayMs = 0, [hashtable]$extraSyncKeys = $null, [int]$scExitCode = 0, [string]$controllerStatus = '', [hashtable]$statusMap = $null) {
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
    # sc.exe 的解析优先读 $sync.scExe（见 svc-common.ps1 的 Get-ScExe）——夹具必须注入
    # 替身名，否则 runspace 会拿全路径去调真 sc.exe，测试就碰到了真服务数据库。
    scExe = 'Invoke-TestSc'
    scExitCode = $scExitCode
    # serviceGone 由调用方在 BeginInvoke 后按需置位：$true = query 返回 1060（服务已消失）,
    # 用于让 Remove 路径的实证复核（Test-ServiceGone）认为删除生效。默认未设 = 服务存在。
  })
  if ($controllerStatus) { $shared.newSc = 'New-TestSc' }
  if ($extraSyncKeys) { foreach ($k in $extraSyncKeys.Keys) { $shared[$k] = $extraSyncKeys[$k] } }
  # 状态表字面量：注入 mock 的哈希表文本（键名与 Start-FakePoll 生成的服务名一致）
  $statusLiteral = if ($statusMap) {
    ($statusMap.GetEnumerator() | ForEach-Object { "'$($_.Key)' = '$($_.Value)'" }) -join '; '
  } else { '' }
  $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.Open()
  $rs.SessionStateProxy.SetVariable('sync', $shared)
  $mocks = @"
function Get-Service {
  [CmdletBinding()]param([string[]]`$Name)
  `$sync.probeCount++
  [void]`$sync.probeStarted.Set()
  if (`$sync.delayMs) { Start-Sleep -Milliseconds `$sync.delayMs }
  `$map = @{ $statusLiteral }
  foreach (`$n in `$Name) {
    `$st = if (`$map.ContainsKey(`$n)) { `$map[`$n] } else { '$serviceStatus' }
    [pscustomobject]@{ Name=`$n; Status=`$st }
  }
}
function Invoke-TestSc {
  `$sync.executed.Enqueue([pscustomobject]@{action=`$args[0];name=`$args[1];probes=`$sync.probeCount})
  [void]`$sync.executedReady.Set()
  if (`$args[0] -eq 'query') {
    # Test-ServicePresent / Test-ServiceGone 走这里。$sync.serviceGone=$true 时模拟
    # 「服务已从 SCM 消失」（1060）；否则当它存在。默认 $null -> 存在（0）。
    `$global:LASTEXITCODE = if (`$sync.serviceGone) { 1060 } else { 0 }
    return
  }
  `$global:LASTEXITCODE = if (`$sync.scExitCode) { `$sync.scExitCode } else { 0 }
}
# 故意不再定义 sc.exe 的替身：生产代码必须经 Get-ScExe 解析（本机 System32 不在 PATH，
# 裸调会拿不到命令、$LASTEXITCODE 残留旧值）。留一个**会抛**的占位，让「退回裸调」
# 立刻炸而不是悄悄命中替身——注入名若和裸调同名，这条回归就测不出来。
function sc.exe { throw 'bare sc.exe call — 生产代码必须经 Get-ScExe 解析' }
function Invoke-TestNssm {
  # remove confirm 等——记一次 nssm 调用，退出码由 $sync.nssmExitCode 控制
  # （0 = nssm 谎报成功但服务其实还在；非零 = 常规失败；未设 = 0）。
  `$sync.executed.Enqueue([pscustomobject]@{action='nssm';name=`$args[1];probes=`$sync.probeCount})
  `$code = `$sync.nssmExitCode
  `$global:LASTEXITCODE = if (`$null -eq `$code) { 0 } else { [int]`$code }
}
function New-TestSc {
  # 替身 ServiceController：只实现 Invoke-ServiceStart 用到的 Status 与 finally 里的 Dispose。
  # 用 Add-Member 挂 ScriptMethod，避免为 ScriptMethod 构造 pscustomobject 的语法噪音。
  param([string]`$n)
  `$o = [pscustomobject]@{ Status = '$controllerStatus' }
  `$o | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
  `$o
}
"@
  $ps = [powershell]::Create().AddScript($mocks).AddScript($script:poll); $ps.Runspace = $rs
  # runspace 里 `Invoke-ExternalQuiet $sync.nssm ...` 解析到 sync.nssm 字符串 'Invoke-TestNssm'，
  # 再由 runspace 内定义的同名函数承接。
  [pscustomobject]@{ Sync = $shared; Runspace = $rs; PowerShell = $ps; Handle = $ps.BeginInvoke() }
}

function Close-FakePoll($worker) {
  $worker.Sync.stop = $true; [void]$worker.Sync.wake.Set()
  $worker.PowerShell.Stop(); $worker.PowerShell.Dispose(); $worker.Runspace.Dispose()
  foreach ($name in 'wake', 'executedReady', 'probeStarted') { $worker.Sync[$name].Dispose() }
}

# 等一条**命令回执**（done=$true）出队，最多等 $TimeoutSec 秒；超时返回 $null。
# 队列里混着普通探测结果（无 done 字段）——必须过滤，否则会取到探测结果并误判回执内容。
# test-poll-commands / test-transition-failure 都用这段，抽出来免得两处各抄一份后漂移。
function Wait-FakePollAck($worker, [int]$TimeoutSec = 4) {
  $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
  while ([datetime]::UtcNow -lt $deadline) {
    $x = $null
    while ($worker.Sync.queue.TryDequeue([ref]$x)) { if ($x.done) { return $x } }
    Start-Sleep -Milliseconds 20
  }
  $null
}
