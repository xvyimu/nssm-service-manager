# tests/test-helpers.ps1 — 跨测试共享的 runspace 夹具
# 被 dot-source，不需 #requires（避免被 run-all.ps1 当独立脚本解析）。

# GUI 入口（service-manager-gui.ps1）定义的副作用函数：单测只需要符号存在，不落盘、不动后台。
# Stop-Background 的空桩会盖掉 lib/shutdown.ps1 的真实现——要真实现的用例（test-shutdown.ps1）
# 必须先点源本文件、再点源 lib。
function Write-CrashLog([string]$m) { }
function Stop-Background { }

# 临时目录 / 假 exe：先建后用的夹具，前缀由调用方给，排障时一眼看出归属。
function New-TestTempDir([string]$prefix) {
  $dir = Join-Path ([IO.Path]::GetTempPath()) "$prefix-$([guid]::NewGuid().ToString('N'))"
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  $dir
}
function New-FakeExe([string]$prefix = 'sm-fake') {
  $exe = Join-Path ([IO.Path]::GetTempPath()) "$prefix-$([guid]::NewGuid().ToString('N')).exe"
  [IO.File]::WriteAllText($exe, 'placeholder', [Text.UTF8Encoding]::new($false))
  $exe
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
# -omitPendingStates=不往 $sync 塞 scmPendingStates（验 poll 在 runspace 缺注入时的兜底）。
function Start-FakePoll([int]$count, [string]$serviceStatus = 'Stopped', [int]$delayMs = 0, [hashtable]$extraSyncKeys = $null, [int]$scExitCode = 0, [string]$controllerStatus = '', [hashtable]$statusMap = $null, [switch]$omitPendingStates) {
  $services = [ordered]@{}
  for ($i = 0; $i -lt $count; $i++) { $services["Fake$i"] = @{ port = 10000 + $i; url = "http://127.0.0.1:10000/fake$i" } }
  # 夹具的中间态集合按三级取：① 调用方已点源 config.ps1 → $script:SCM_PENDING_STATES；
  # ② 没点源就地加载 lib/config.ps1 后重取；③ 仍拿不到才用字面量。
  # 唯一真实来源是 config.ps1 的 $script:SCM_PENDING_STATES——下面最后一档只是**夹具兜底**
  # （config 能被点源时夹具自动跟随真实集合，不会漂成第三份定义）。
  $pendingStates = if ($script:SCM_PENDING_STATES) { @($script:SCM_PENDING_STATES) } else {
    # 点源 config 会写进 $script: 作用域（config / 各状态集合）。夹具只借集合，取完把宿主原有的
    # 配置快照还原回去，免得「造替身」这个动作顺带改了被测测试看到的配置。
    $savedConfig  = $script:config
    $savedNotices = $script:configNotices
    try {
      . (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib/config.ps1')
      if ($script:SCM_PENDING_STATES) { @($script:SCM_PENDING_STATES) } else { @('启动中','停止中','暂停中','继续中') }
    } finally {
      $script:config        = $savedConfig
      $script:configNotices = $savedNotices
    }
  }
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
  # 中间态集合由入口注入 poll（$sync.scmPendingStates）；夹具按 config 的同名常量补一份。
  # -omitPendingStates：刻意不塞这个键，验 runspace 缺注入时 poll 的兜底（真实入口漏注入的情形）。
  if (-not $omitPendingStates) { $shared.scmPendingStates = $pendingStates }
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
  # 探测计数不在这里：poll 已改用 Get-SvcStateQuiet(sc query) 拿状态，
  # 计数点移到下面 Invoke-TestSc 的 query 分支。这里只剩 Wait-Stopped 的轮询会用。
  if (`$sync.delayMs) { Start-Sleep -Milliseconds `$sync.delayMs }
  `$map = @{ $statusLiteral }
  foreach (`$n in `$Name) {
    `$st = if (`$map.ContainsKey(`$n)) { `$map[`$n] } else { '$serviceStatus' }
    [pscustomobject]@{ Name=`$n; Status=`$st }
  }
}
function Invoke-ThrowingSc {
  # 每次调用都抛，模拟 sc.exe 启动失败（路径失效/EDR 拦子进程/句柄耗尽）。
  # 用 extraSyncKeys @{ scExe = 'Invoke-ThrowingSc' } 注入，验「单条命令抛异常不许终结轮询」。
  # 状态查询也走这个替身，所以计数要在这里做——否则 probeStarted 永远等不到，测的就不是原命题了。
  `$sync.probeCount++
  [void]`$sync.probeStarted.Set()
  throw 'simulated sc.exe failure'
}
function Invoke-TestSc {
  if (`$args[0] -eq 'query') {
    # 状态探测的计数点（poll 的 Get-SvcStateMapQuiet / Get-SvcStateQuiet 都落到这里）。
    # 不带名字 = 全量枚举：把全部夹具服务连成 sc.exe query 的块；带名字 = 单个服务。
    `$sync.probeCount++
    [void]`$sync.probeStarted.Set()
    if (`$sync.delayMs) { Start-Sleep -Milliseconds `$sync.delayMs }
    # Test-ServicePresent / Test-ServiceGone 走这里。$sync.serviceGone=$true 时模拟
    # 「服务已从 SCM 消失」（1060）；否则当它存在。默认 $null -> 存在（0）。
    if (`$sync.serviceGone) { `$global:LASTEXITCODE = 1060; return }
    `$map = @{ $statusLiteral }
    `$names = @()
    if (`$args.Count -gt 1 -and `$args[1]) { `$names = @([string]`$args[1]) } else { `$names = @(`$sync.svc.Keys) }
    `$global:LASTEXITCODE = 0
    foreach (`$n in `$names) {
      `$st = if (`$map.ContainsKey([string]`$n)) { `$map[[string]`$n] } else { '$serviceStatus' }
      `$code = switch (`$st) {
        'Running'         { 4 }
        'StartPending'    { 2 }
        'StopPending'     { 3 }
        'ContinuePending' { 5 }
        'PausePending'    { 6 }
        'Paused'          { 7 }
        default           { 1 }
      }
      "SERVICE_NAME: `$n"
      '        TYPE               : 10  WIN32_OWN_PROCESS'
      "        STATE              : `$code  `$(`$st.ToUpper())"
    }
    return
  }
  `$sync.executed.Enqueue([pscustomobject]@{action=`$args[0];name=`$args[1];probes=`$sync.probeCount})
  [void]`$sync.executedReady.Set()
  `$global:LASTEXITCODE = if (`$sync.scExitCode) { `$sync.scExitCode } else { 0 }
}
# 故意不再定义 sc.exe 的替身：生产代码必须经 Get-ScExe 解析（本机 System32 不在 PATH，
# 裸调会拿不到命令、$LASTEXITCODE 残留旧值）。留一个**会抛**的占位，让「退回裸调」
# 立刻炸而不是悄悄命中替身——注入名若和裸调同名，这条回归就测不出来。
function sc.exe { throw 'bare sc.exe call — 生产代码必须经 Get-ScExe 解析' }
function Invoke-TestNssm {
  # remove confirm 等——记一次 nssm 调用。固定返回 0（nssm 谎报成功），
  # 删除成败由 $sync.serviceGone 控制，正是要验的那条路径。
  `$sync.executed.Enqueue([pscustomobject]@{action='nssm';name=`$args[1];probes=`$sync.probeCount})
  `$global:LASTEXITCODE = 0
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
  # 未关闭 worker 计数：runspace 泄漏本身不会报错（尤其是在 finally 里又抛异常被吞掉时），
  # 只能由测试文件在末尾断言归零。Started 作自检，防「门禁永远绿灯」。
  $script:fakePollStarted = [int]$script:fakePollStarted + 1
  $script:fakePollOpen = [int]$script:fakePollOpen + 1
  [pscustomobject]@{ Sync = $shared; Runspace = $rs; PowerShell = $ps; Handle = $ps.BeginInvoke() }
}

# 刻意不 try/catch：同一个 worker 被关两次（wake 已 Dispose 再 Set）必须当场炸出来。
# 上一版的 try/catch 把「一个 worker 从未关、另一个关两次」静默吞成绿灯——泄漏就是这么溜过去的。
function Close-FakePoll($worker) {
  $worker.Sync.stop = $true; [void]$worker.Sync.wake.Set()
  $worker.PowerShell.Stop(); $worker.PowerShell.Dispose(); $worker.Runspace.Dispose()
  foreach ($name in 'wake', 'executedReady', 'probeStarted') { $worker.Sync[$name].Dispose() }
  $script:fakePollOpen = [int]$script:fakePollOpen - 1
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

# 断言：各测试不再各自复制一份；dot-source 本文件后即可使用。
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }

# 只保留可执行代码：去掉 <# ... #> 块注释、整行 # 注释与行内 # 注释。
# 源码级断言（状态字面量、注入键）必须看这个，而不是原文——否则注释里写同形内容就能满足断言。
# 简化前提：本仓源码里没有把 " #" 写进字符串常量的地方（有的话再加引号状态机）。
function Get-SourceCodeOnly([string]$text){
  if (-not $text) { return "" }
  $t = [regex]::Replace($text, '(?s)<#.*?#>', '')
  ($t -split "`r?`n" | Where-Object { $_.Trim() -notmatch '^#' } | ForEach-Object { ($_ -replace '\s+#.*$', '') }) -join "`n"
}
