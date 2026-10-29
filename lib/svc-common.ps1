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
function Invoke-ExternalQuiet([string]$exe, [string[]]$argv){
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
  $timeoutMs = if ($sync -and $sync.extCommandTimeoutMs) { [int]$sync.extCommandTimeoutMs } else { 60000 }
  if (-not $p.WaitForExit($timeoutMs)) {
    try { $p.Kill($true) } catch {}
    return @{ exit = -1; out = "外部命令超时（${timeoutMs}ms）：$exe" }
  }
  # WaitForExit 只等进程退出，不等管道 EOF：若子进程派生的孙进程继承了 stdout 句柄，
  # .Result 会一直等下去。给个上界，拿不到就当空输出——总比卡死好。
  $stdout = ''; $stderr = ''
  try { if ($stdoutTask.Wait(2000)) { $stdout = $stdoutTask.Result } } catch {}
  try { if ($stderrTask.Wait(2000)) { $stderr = $stderrTask.Result } } catch {}
  @{ exit = $p.ExitCode; out = ($stdout + $stderr).Trim() }
}

function Invoke-ScQuiet([string[]]$argv){
  (Invoke-ExternalQuiet (Get-ScExe) $argv).exit
}

# 轮询服务到 Stopped。超时：$sync 注入值 > $script:config.WaitStoppedTimeoutMs > 6000。
# 服务已不存在（ObjectNotFound）= 已停止；其他错误（权限等）继续等待。
function Wait-Stopped([string]$n){
  $timeoutMs = if     ($sync -and $sync.waitStoppedTimeoutMs)                   { [int]$sync.waitStoppedTimeoutMs }
               elseif ($script:config -and $script:config.WaitStoppedTimeoutMs) { [int]$script:config.WaitStoppedTimeoutMs }
               else                                                             { 6000 }
  $w=0
  # 步长从 config 收口（WaitStoppedPollMs，默认 300）；测试夹具经 $sync 注入
  $stepMs = if ($sync -and $sync.waitStoppedPollMs) { [int]$sync.waitStoppedPollMs } else { 300 }
  while($w -lt $timeoutMs){
    try {
      $s=Get-Service -Name $n -EA Stop
      if([string]$s.Status -eq 'Stopped'){return $true}
    } catch {
      if($_.CategoryInfo.Category -eq 'ObjectNotFound'){return $true}
    }
    Start-Sleep -Milliseconds $stepMs; $w += $stepMs
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
  [void](Wait-Stopped $n)
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
function Get-ServiceQueryCode([string]$n){
  Invoke-ScQuiet @('query', $n)
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
