# lib/svc-common.ps1 — UI 线程与后台 runspace 共用的服务操作原语
#
# 只有一份 Wait-Stopped 实现（原 poll.ps1 的 runspace 字符串里一份、add-svc.ps1 里一份，
# 靠「SYNC: 两处同改」注释人工同步）。poll.ps1 在构造 runspace 脚本时把本文件内容前置进
# 脚本字符串，add-svc.ps1 直接点源本文件——两边引用的是同一份文本。

# 轮询服务到 Stopped，用于重启/删除前等端口释放。
# 超时取值优先级：显式 -timeoutMs > $sync 注入值（UI 线程即 $script:sync.waitStoppedTimeoutMs，
# runspace 由 poll.ps1 从同一键读出并写回）> $script:config.WaitStoppedTimeoutMs > 6000。
# 前两级在两条路径上都可见，故 UI 线程与 runspace 走同一份配置，不再各读各的。
# 服务已不存在（ObjectNotFound）= 等同已停止；其他错误（权限等）不掩盖，继续等待。
function Wait-Stopped([string]$n,[int]$timeoutMs=0){
  if(-not $timeoutMs){
    if     ($sync -and $sync.waitStoppedTimeoutMs)                    { $timeoutMs = [int]$sync.waitStoppedTimeoutMs }
    elseif ($script:config -and $script:config.WaitStoppedTimeoutMs)  { $timeoutMs = [int]$script:config.WaitStoppedTimeoutMs }
    else                                                              { $timeoutMs = 6000 }
  }
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
# 放这里而不是 poll.ps1：poll.ps1 的函数体在 here-string 里，只进 runspace——UI 线程
# 与 CLI 都看不到。CLI（add-svc.ps1）要报「启动失败(1053 服务进程无法启动）」就得有
# 同一份映射，否则同一个退出码在 GUI 与 CLI 给出不同粒度（GUI 中文、CLI 裸数字）。
# 本文件是 UI 线程（add-svc 直接点源）与 runspace（poll 前置其文本）共用的唯一原语，
# 映射放这里两条路径都拿得到，且只有一份实现。
# 常见码：1056=已在运行 / 1062=未启动 / 1060=未安装 / 1051=禁止启动 / 1053=进程起不来。
# 5=拒绝访问：非管理员调 sc.exe start <已运行服务> 实测返回 5（不是 1056，管理员下才是）。
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
    'Stopped'      { '已停止' }
    'StartPending'  { '启动中' }
    'StopPending'   { '停止中' }
    'Running'       { '运行中' }
    default         { '未知' }
  }
}

# 删除服务的**核心序列**：stop → 等 Stopped → nssm remove confirm → 实证复核是否真消失。
# 放在本文件而不是 nssm.ps1：本文件文本被 poll.ps1 前置进 runspace，UI 线程与后台引用的是
# **同一份**——此前两处各写一份（nssm.ps1 的 Remove-NssmService 与 poll.ps1 的 remove 分支），
# 复核逻辑只在一侧被改就会漂移。这里只共用「判定」，不共用「呈现」：UI/CLI 要抛错、
# runspace 要入 msg 队列，故返回结果对象由调用方决定怎么报。
# $nssmExe 必须传参——runspace 里 $script:nssm 不可见（NSSM 路径经 $sync.nssm 从 UI 传入）。
function Invoke-ServiceRemove([string]$n,[string]$nssmExe){
  sc.exe stop $n 2>&1 | Out-Null
  # stop 失败不阻断（服务可能已停），等 Stopped 再删，避免删一个还在跑的服务
  [void](Wait-Stopped $n)
  $o = & $nssmExe remove $n confirm 2>&1
  $code = $LASTEXITCODE
  # 退出码**不可信**：不非零只能说明「没报错」，不能说「删掉了」——故下面还要实证复核。
  # 非零时不再查 Test-ServiceGone：命令根本没成功，服务必然还在，再查一次反而可能
  # 因权限类错误把原因说成「服务仍存在」，掩盖真正的原因（退出码）。
  if($code -ne 0){
    return [pscustomobject]@{ ok=$false; exitCode=$code; why=''; detail=($o -join ' ') }
  }
  # 实测（2026-10-05，NSSM 2.24-103-gdee49fc）：提权不足或服务不存在时，nssm remove/install
  # 打印「Administrator access is needed to ...」却返回 **0**。只信退出码会把「删失败」判成功
  # ——UI 清掉卡片并落盘，而服务仍在：用户以为删了、配置却丢了。
  if(-not (Test-ServiceGone $n)){
    $why = if(($o -join ' ') -match 'Administrator access'){ '需要管理员权限' } else { '服务仍存在' }
    return [pscustomobject]@{ ok=$false; exitCode=$code; why=$why; detail=($o -join ' ') }
  }
  [pscustomobject]@{ ok=$true; exitCode=$code; why=''; detail=($o -join ' ') }
}

# sc.exe query 的退出码——删除/注册复核共用的**底层原语**（两个谓词只解释码，不重抄调用）。
# 0 = 服务存在；1060 = 不存在；1072 = 已标记删除（句柄未全关，内核里已在消失路径上）。
# 非管理员也能 query（实测）。
function Get-ServiceQueryCode([string]$n){
  sc.exe query $n 2>&1 | Out-Null
  $LASTEXITCODE
}

# 服务是否已从 SCM 消失——删除操作的**最终判据**，不能只信 nssm remove 的退出码。
# 实测（2026-10-05，NSSM 2.24-103-gdee49fc）：提权不足或服务不存在时，nssm remove/install
# 打印「Administrator access is needed to ...」却返回 **0**；其余动作（stop/start/restart）
# 失败返回 3、set/reset 返回 1。把删除成败押在这样一个退出码上，会出现「删失败被判成功」
# ——UI 清掉卡片并落盘，而服务仍在：用户以为删了、配置却丢了。
# 只认「明确消失」的两个码：其它（含权限类错误）不当已消失——宁可判失败，也不冤判成功。
function Test-ServiceGone([string]$n){
  (Get-ServiceQueryCode $n) -in @(1060,1072)
}

# 服务是否已在 SCM 中——install 后的复核判据（与 Test-ServiceGone 同一实证思路：
# nssm install 失败也返回 0，见上）。
# 带重试：刚 install 完紧接着 query，SCM 一般已可见，但边界性延迟会把一次成功的注册
# 误判成失败（假阴性），而调用方会据此抛错。宁可多等几百毫秒。
function Test-ServicePresent([string]$n,[int]$retries=3,[int]$delayMs=100){
  for($i=0; $i -le $retries; $i++){
    if((Get-ServiceQueryCode $n) -eq 0){ return $true }
    if($i -lt $retries){ Start-Sleep -Milliseconds $delayMs }
  }
  $false
}
