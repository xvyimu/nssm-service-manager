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

# 服务是否已从 SCM 消失——删除操作的**最终判据**，不能只信 nssm remove 的退出码。
# 实测（2026-10-05，NSSM 2.24-103-gdee49fc）：提权不足或服务不存在时，nssm remove/install
# 打印「Administrator access is needed to ...」却返回 **0**；其余动作（stop/start/restart）
# 失败返回 3、set/reset 返回 1。把删除成败押在这样一个退出码上，会出现「删失败被判成功」
# ——UI 清掉卡片并落盘，而服务仍在：用户以为删了、配置却丢了。
# sc.exe query 的退出码可靠：1060 = 服务不存在。1072 = 已标记删除（句柄未全关，
# 内核里已在消失路径上）同样视作已消失。非管理员也能 query（实测）。
function Test-ServiceGone([string]$n){
  sc.exe query $n 2>&1 | Out-Null
  $LASTEXITCODE -in @(1060,1072)
}

# 服务是否已在 SCM 中——install 后的复核判据（与 Test-ServiceGone 同一实证思路：
# nssm install 失败也返回 0，见上）。sc.exe query 返回 1060 = 不存在。
# 带重试：刚 install 完紧接着 query，SCM 一般已可见，但边界性延迟会把一次成功的注册
# 误判成失败（假阴性），而调用方会据此抛错。宁可多等几百毫秒。
function Test-ServicePresent([string]$n,[int]$retries=3,[int]$delayMs=100){
  for($i=0; $i -le $retries; $i++){
    sc.exe query $n 2>&1 | Out-Null
    if($LASTEXITCODE -eq 0){ return $true }
    if($i -lt $retries){ Start-Sleep -Milliseconds $delayMs }
  }
  $false
}
