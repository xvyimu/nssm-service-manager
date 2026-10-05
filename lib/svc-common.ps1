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
