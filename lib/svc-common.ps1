# lib/svc-common.ps1 — UI 线程与后台 runspace 共用的服务操作原语
# poll.ps1 把本文件文本前置进 runspace 脚本，add-svc.ps1 直接点源——两边引用同一份。

# sc.exe 必须解析后全路径调用：裸调不存在的命令时 $LASTEXITCODE 保留上一条的码，会误判。
# 盘上找不到就退回裸名，让「找不到」如实报错。§Get-ScExe
function Get-ScExe {
  if ($sync -and $sync.scExe) { return [string]$sync.scExe }
  $p = Join-Path $env:SystemRoot 'System32\sc.exe'
  if (Test-Path -LiteralPath $p) { return $p }
  'sc.exe'
}

# 跑外部控制台程序但不弹窗，返回 @{ exit; out }。注入成函数名时直接调用，保留测试缝。
# $timeoutMs=0 表示用全局 ExtCommandTimeoutMs（命令类，宽松）；给值时是调用方的硬超时。
function Invoke-ExternalQuiet([string]$exe, [string[]]$argv, [int]$timeoutMs = 0){
  if (Get-Command -Name $exe -CommandType Function -EA SilentlyContinue) {
    $o = @(& $exe @argv 2>&1)
    return @{ exit = $LASTEXITCODE; out = ($o -join "`n") }
  }
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $exe
  foreach ($a in $argv) { $psi.ArgumentList.Add([string]$a) }
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $p = [Diagnostics.Process]::Start($psi)
  # 异步读 + 带超时的 WaitForExit：sc.exe / nssm.exe 卡住时（等不到的句柄、被安全软件挂起）
  # 同步 ReadToEnd 会永久阻塞，而命令是串行的——一条卡住，后续命令与所有探测一起停摆，
  # 连异常都不抛，crash log 里留不下线索。
  $stdoutTask = $p.StandardOutput.ReadToEndAsync()
  $stderrTask = $p.StandardError.ReadToEndAsync()
  # 调用方给了硬超时（状态探测 3s）就用它；否则走全局 ExtCommandTimeoutMs（命令类，宽松）。
  $timeoutMs = if ($timeoutMs -gt 0) { $timeoutMs }
               elseif ($sync -and $sync.extCommandTimeoutMs) { [int]$sync.extCommandTimeoutMs }
               else { 60000 }
  if (-not $p.WaitForExit($timeoutMs)) {
    # Kill 之后必须再 WaitForExit 并 Dispose：否则进程对象与两个 ReadToEndAsync 任务一起悬空，
    # 每次超时都留一份待回收句柄（探测是长跑循环，泄漏会累积）。
    try { $p.Kill($true) } catch {}
    try { [void]$p.WaitForExit(1000) } catch {}
    try { $p.Dispose() } catch {}
    return @{ exit = -1; out = "外部命令超时（${timeoutMs}ms）：$exe" }
  }
  # WaitForExit 只等进程退出，不等管道 EOF：若子进程派生的孙进程继承了 stdout 句柄，
  # .Result 会一直等下去。给个上界，拿不到就当空输出——总比卡死好。
  $stdout = ''; $stderr = ''
  try { if ($stdoutTask.Wait(2000)) { $stdout = $stdoutTask.Result } } catch {}
  try { if ($stderrTask.Wait(2000)) { $stderr = $stderrTask.Result } } catch {}
  @{ exit = $p.ExitCode; out = ($stdout + $stderr).Trim() }
}

# sc.exe 的静默包装：只回退出码，输出留给需要诊断时走 Invoke-ExternalQuiet。
# $timeoutMs=0 → Invoke-ExternalQuiet 用全局 ExtCommandTimeoutMs；状态探测传自己的短超时。
function Invoke-ScQuiet([string[]]$argv, [int]$timeoutMs = 0){
  (Invoke-ExternalQuiet (Get-ScExe) $argv $timeoutMs).exit
}

# 轮询服务到 Stopped。超时：$sync 注入值 > $script:config.WaitStoppedTimeoutMs > 12000。
# 服务已不存在（ObjectNotFound）= 已停止；其他错误（权限等）继续等待。
function Wait-Stopped([string]$n){
  $timeoutMs = if     ($sync -and $sync.waitStoppedTimeoutMs)                   { [int]$sync.waitStoppedTimeoutMs }
               elseif ($script:config -and $script:config.WaitStoppedTimeoutMs) { [int]$script:config.WaitStoppedTimeoutMs }
               else                                                             { 12000 }
  # 预算按真实耗时算，且要把「最后一次查询」和「超时后 Kill 的收尾」都算进去：
  # 只按步长累加会把「12s 预算」放大成 40 轮 × 两次查询，减掉 1000ms 兜住 Kill 后的 WaitForExit。
  $sw = [Diagnostics.Stopwatch]::StartNew()
  # 步长从 config 收口（WaitStoppedPollMs，默认 300）；测试夹具经 $sync 注入
  $stepMs = if ($sync -and $sync.waitStoppedPollMs) { [int]$sync.waitStoppedPollMs } else { 300 }
  $svcStateMs = if ($sync -and $sync.svcStateTimeoutMs) { [int]$sync.svcStateTimeoutMs } else { 0 }
  $capMs = if ($svcStateMs -gt 0) { $svcStateMs } else { 3000 }
  $deadline = $timeoutMs - 1000
  if ($deadline -lt 200) { $deadline = 200 }
  while($sw.ElapsedMilliseconds -lt $deadline){
    # 不用 Get-Service：它没有超时开关，SCM 挂起时这一行会永久阻塞，
    # 循环里的 $timeoutMs 根本轮不到判断。Get-SvcStateQuiet 走 sc.exe query（硬超时 + Kill）。
    # 两次查询与步长都按同一份剩余预算收口，否则「≤12s」是假话。
    $remain = $deadline - $sw.ElapsedMilliseconds
    $qms = [int][Math]::Min($capMs, $remain)
    if ($qms -lt 100) { break }
    $st = Get-SvcStateQuiet $n $qms
    if($st -eq 'Stopped'){return $true}
    if(-not $st){
      # $null 既可能是「服务没了」也可能是「查询超时」——只有 1060/1072 才算没了。
      $remain2 = $deadline - $sw.ElapsedMilliseconds
      if ($remain2 -lt 100) { break }
      $code = Get-ServiceQueryCode $n ([int][Math]::Min($capMs, $remain2))
      if($code -in 1060,1072){return $true}
    }
    $remain3 = $deadline - $sw.ElapsedMilliseconds
    if ($remain3 -le 0) { break }
    Start-Sleep -Milliseconds ([int][Math]::Min($stepMs, $remain3))
  }
  $false
}

# sc.exe / NSSM 退出码 → 中文文案（单一映射源）。
# 放这里因为 poll.ps1 的函数体在 here-string 里只进 runspace，UI 与 CLI 都看不到；同一码不能两边不同粒度。
# 常见码：1056=已在运行 / 1062=未启动 / 1060=未安装 / 1051=禁止启动 / 1053=进程起不来。
# 5=拒绝访问：非管理员调 sc.exe start <已运行服务> 实测返回 5（管理员下才是 1056）。
function Convert-ScExitCode([int]$code){
  switch ($code) {
    0      { '' }
    1056   { '已在运行' }
    1062   { '未启动' }
    1060   { '服务未安装' }
    1051   { '禁止启动（禁用或只读）' }
    1053   { '服务进程无法启动' }
    1058   { '服务被禁用' }
    1067   { '进程意外退出' }
    1072   { '服务已被标记为删除' }
    5      { '拒绝访问（可能非管理员）' }
    default { "错误码 $code" }
  }
}

# ServiceController.Status → 中文状态（与 Convert-ScExitCode 同处，避免兜底分支缩水版漂移）
function Convert-ServiceStatus([string]$s){
  switch ($s) {
    'Stopped'         { '已停止' }
    'StartPending'    { '启动中' }
    'StopPending'     { '停止中' }
    'Running'         { '运行中' }
    'Paused'          { '已暂停' }
    'PausePending'    { '暂停中' }
    'ContinuePending' { '继续中' }
    default           { '未知' }
  }
}

# 删除序列：stop → 等 Stopped → nssm remove confirm → 实证复核。只共用判定不共用呈现，由调用方决定抛错或入队。
# $nssmExe 必须传参——runspace 里 $script:nssm 不可见。
function Invoke-ServiceRemove([string]$n,[string]$nssmExe){
  [void](Invoke-ScQuiet @('stop', $n))
  # stop 失败不阻断（服务可能已停），等 Stopped 再删，避免删一个还在跑的服务
  # 还在跑就删，SCM 会把服务标记删除但进程仍在，后续状态查询全部不可信——宁可报错让用户重试。
  if(-not (Wait-Stopped $n)) {
    return [pscustomobject]@{ ok=$false; exitCode=0; why='服务未在超时内停止，已中止删除'; detail='' }
  }
  $r = Invoke-ExternalQuiet $nssmExe @('remove', $n, 'confirm')
  $o = $r.out
  $code = $r.exit
  # 退出码不可信。非零时不再查 Test-ServiceGone：命令没成功，服务必然还在，
  # 再查一次反而可能用「服务仍存在」掩盖真正的原因（退出码）。
  if($code -ne 0){
    return [pscustomobject]@{ ok=$false; exitCode=$code; why=''; detail=($o -join ' ') }
  }
  # 实测（2026-10-05，NSSM 2.24-103）：提权不足或服务不存在时，nssm remove/install
  # 打印「Administrator access is needed」却返回 0。只信退出码会把「删失败」判成功。
  if(-not (Test-ServiceGone $n)){
    $why = if(($o -join ' ') -match 'Administrator access'){ '需要管理员权限' } else { '服务仍存在' }
    return [pscustomobject]@{ ok=$false; exitCode=$code; why=$why; detail=($o -join ' ') }
  }
  [pscustomobject]@{ ok=$true; exitCode=$code; why=''; detail=($o -join ' ') }
}

# sc.exe query 的退出码——删除/注册复核共用的底层原语。
# 0=存在 / 1060=不存在 / 1072=已标记删除（句柄未全关）。非管理员也能 query。
function Get-ServiceQueryCode([string]$n, [int]$timeoutMs = 0){
  Invoke-ScQuiet @('query', $n) $timeoutMs
}

# 服务是否已从 SCM 消失——删除的最终判据，不能只信 nssm remove 的退出码。
# 实测（2026-10-05）：提权不足或服务不存在时打印「Administrator access is needed」却返回 0；
# 其余动作失败返回 3、set 返回 1。只认 1060/1072，其它（含权限错）宁可判失败也不冤判成功。
function Test-ServiceGone([string]$n){
  (Get-ServiceQueryCode $n) -in @(1060,1072)
}

# 服务是否已在 SCM 中——install 后的复核（nssm install 失败也返回 0）。
# 带重试：刚 install 完紧接着 query 可能因边界延迟误判失败（假阴性）。
function Test-ServicePresent([string]$n,[int]$retries=3,[int]$delayMs=100){
  for($i=0; $i -le $retries; $i++){
    if((Get-ServiceQueryCode $n) -eq 0){ return $true }
    if($i -lt $retries){ Start-Sleep -Milliseconds $delayMs }
  }
  $false
}

# ---- 服务状态查询（带硬超时）----
# 为什么不再用 Get-Service：它没有超时参数。SCM 挂起（等不到的句柄、被安全软件挂起、
# 服务数据库锁）时 Get-Service 会永久阻塞——后台探测 runspace 就此停摆，卡片冻结在最后一帧，
# 连异常都不抛，crash log 里留不下线索。sc.exe query 经 Invoke-ExternalQuiet 走
# WaitForExit(timeout) + Kill，超时变成「可返回的状态」。
# 返回英文状态名（与 ServiceController.Status 同口径，Convert-ServiceStatus 认得）；
# $null = 查不到（服务不存在 1060/1072、查询失败、超时）。**永不抛**。

# 超时取值：参数 > $script:config.SvcStateTimeoutMs > 3000。
# runspace 里拿不到 config（只前置了 svc-common/health/poll 的文本），由 poll.ps1 经 $sync 注入后传参。
function Get-SvcStateTimeoutMs([int]$timeoutMs = 0){
  if ($timeoutMs -gt 0) { return $timeoutMs }
  if ($script:config -and $script:config.SvcStateTimeoutMs) { return [int]$script:config.SvcStateTimeoutMs }
  3000
}

# sc.exe 的 STATE 数字 → ServiceController 的状态名（1..7 = SERVICE_STATUS.dwCurrentState）。
function Convert-ScStateName([int]$code){
  switch ($code) {
    1 { 'Stopped' }
    2 { 'StartPending' }
    3 { 'StopPending' }
    4 { 'Running' }
    5 { 'ContinuePending' }
    6 { 'PausePending' }
    7 { 'Paused' }
    default { '' }
  }
}

# sc.exe query 输出 → @{ 服务名 = 英文状态名 }；单服务查询与全量枚举共用这一份解析。
# 只认「SERVICE_NAME:」块里第一处 STATE 行的数字：状态名虽不随系统语言变，但数字是唯一稳定口径。
function Convert-ScQueryText([string]$text){
  $map = @{}
  $cur = $null
  foreach ($line in ([string]$text -split "`r?`n")) {
    if ($line -match '^\s*SERVICE_NAME:\s*(.+?)\s*$') { $cur = $Matches[1]; continue }
    if ($cur -and $line -match '\bSTATE\s*:\s*(\d+)') {
      $map[$cur] = Convert-ScStateName ([int]$Matches[1])
      $cur = $null
    }
  }
  $map
}

# 超时提示限频：SCM 挂起时每 4 秒一轮探测，不限频会把状态栏刷成滚屏。
function Write-SvcStateTimeoutNotice([string]$target, [int]$timeoutMs){
  $now = [Environment]::TickCount64
  if ($script:svcStateTimeoutNoticeAt -and ($now - $script:svcStateTimeoutNoticeAt) -lt 60000) { return }
  $script:svcStateTimeoutNoticeAt = $now
  if ($sync -and $sync.msg) { $sync.msg.Enqueue("服务状态查询超时（${timeoutMs}ms）：$target") }
}

# 单个服务状态。$null = 服务不存在或查询失败/超时。
# 调用方要区分「未安装」与「未知」时，再查 Get-ServiceQueryCode（1060/1072 = 未安装）。
function Get-SvcStateQuiet([string]$name, [int]$timeoutMs = 0){
  if (-not $name) { return $null }
  $ms = Get-SvcStateTimeoutMs $timeoutMs
  try {
    $r = Invoke-ExternalQuiet (Get-ScExe) @('query', $name) $ms
    if ($r.exit -ne 0) {
      if ($r.exit -eq -1) { Write-SvcStateTimeoutNotice $name $ms }   # -1 = Invoke-ExternalQuiet 的硬超时
      return $null
    }
    $map = Convert-ScQueryText ([string]$r.out)
    if ($map.ContainsKey($name)) { return [string]$map[$name] }
    # 名字大小写/别名对不上：单服务查询只会有一个块，直接取它
    if ($map.Count -eq 1) { return [string]@($map.Values)[0] }
    $null
  } catch {
    $null
  }
}

# 全量状态枚举（一次 sc query 拿全部）：sc.exe 没有「多服务名查询」，枚举是它唯一的一次性口径。
# 返回 @{ 服务名 = 英文状态名 }；失败/超时/输出不可解析 → $null（调用方回落逐个 Get-SvcStateQuiet）。
function Get-SvcStateMapQuiet([int]$timeoutMs = 0){
  $ms = Get-SvcStateTimeoutMs $timeoutMs
  try {
    $r = Invoke-ExternalQuiet (Get-ScExe) @('query') $ms
    if ($r.exit -ne 0) {
      if ($r.exit -eq -1) { Write-SvcStateTimeoutNotice '(全量枚举)' $ms }
      return $null
    }
    $map = Convert-ScQueryText ([string]$r.out)
    if ($map.Count -eq 0) { return $null }
    $map
  } catch {
    $null
  }
}
