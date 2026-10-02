# lib/svc-common.ps1 — UI 线程与后台 runspace 共用的服务操作原语
#
# 只有一份 Wait-Stopped 实现（原 poll.ps1 的 runspace 字符串里一份、add-svc.ps1 里一份，
# 靠「SYNC: 两处同改」注释人工同步）。poll.ps1 在构造 runspace 脚本时把本文件内容前置进
# 脚本字符串，add-svc.ps1 直接点源本文件——两边引用的是同一份文本。

# 轮询服务到 Stopped（最多 timeoutMs，默认 6s），用于重启/删除前等端口释放。
# 服务已不存在（ObjectNotFound）= 等同已停止；其他错误（权限等）不掩盖，继续等待。
function Wait-Stopped([string]$n,[int]$timeoutMs=6000){
  $w=0
  while($w -lt $timeoutMs){
    try {
      $s=Get-Service -Name $n -EA Stop
      if([string]$s.Status -eq 'Stopped'){return $true}
    } catch {
      if($_.CategoryInfo.Category -eq 'ObjectNotFound'){return $true}
    }
    Start-Sleep -Milliseconds 300; $w+=300
  }
  $false
}
