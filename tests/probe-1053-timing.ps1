#requires -Version 7.0
<#
用途：实测「启动失败（SCM 1053）路径的真实耗时」，判定 lib/config.ps1 的
      ToggleTimeoutMs = 30000 是否够大。

背景：ToggleTimeoutMs 必须大于**正常路径**最长耗时，否则过渡态超时逃生会在正常
      失败流程里抢先触发。已实测的下界是删除路径的 stop + Wait-Stopped ≤ 6s；
      未实测的是启动失败路径——Invoke-ServiceStart 在 $svc.Start() 抛异常后回落
      sc.exe start，而后者走 SCM 同步管道（ServicesPipeTimeout，本机未设 =
      默认 30000ms，恰好等于 ToggleTimeoutMs）。

做法：注册一个 exe 路径故意写错的服务（SCM 拉不起进程 → 1053），分别计时
      ServiceController.Start() 与 sc.exe start，最后在 finally 里删掉该服务。

需要管理员权限（注册/删除服务）。临时服务名 __sm_1053_probe__。
用法：以管理员身份运行  pwsh -NoProfile -File tests/probe-1053-timing.ps1
#>
$ErrorActionPreference='Stop'

$isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw '需要管理员权限（注册/删除服务）。请以管理员身份运行本脚本。' }

$SVC = '__sm_1053_probe__'
$BAD = 'C:\__sm_no_such_dir__\__sm_no_such__.exe'   # 故意不存在

function Measure-Step([string]$label, [scriptblock]$sb) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $err = $null
  try { & $sb } catch { $err = $_.Exception.Message }
  $sw.Stop()
  $extra = if ($err) { "  异常: $($err.Substring(0,[Math]::Min(70,$err.Length)))" } else { '' }
  "  {0,-42} {1,7} ms  LASTEXITCODE={2}{3}" -f $label, $sw.ElapsedMilliseconds, $LASTEXITCODE, $extra
  $sw.ElapsedMilliseconds
}

$pipe = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name ServicesPipeTimeout -EA SilentlyContinue).ServicesPipeTimeout
Write-Output "SCM ServicesPipeTimeout = $(if ($pipe) { "$pipe ms" } else { '未设 -> SCM 默认 30000 ms' })"
Write-Output "将注册临时服务 $SVC，exe = $BAD（不存在）"
Write-Output ''

# 清掉可能的上次残留
if (Get-Service -Name $SVC -EA SilentlyContinue) { Remove-Service -Name $SVC }

try {
  Write-Output '== 注册 =='
  New-Service -Name $SVC -BinaryPathName $BAD -StartupType Manual | Out-Null
  Start-Sleep -Milliseconds 300
  & sc.exe query $SVC 2>&1 | Out-Null
  Write-Output "  注册后 sc query 返回 $LASTEXITCODE（0 = 服务存在）"
  Write-Output ''

  Write-Output '== 计时：启动失败路径 =='
  $msSvc = Measure-Step 'ServiceController.Start()（Invoke-ServiceStart 主路径）' {
    $s = [System.ServiceProcess.ServiceController]::new($SVC)
    try { $s.Start() } finally { $s.Dispose() }
  }
  $msSc = Measure-Step 'sc.exe start（回落路径，走 SCM 同步管道）' {
    sc.exe start $SVC 2>&1 | Out-Null
  }
  Write-Output ''

  Write-Output '== 结论 =='
  $max = [Math]::Max($msSvc, $msSc)
  Write-Output "  实测最长 $max ms；当前 ToggleTimeoutMs = 30000 ms"
  if ($max -ge 25000) {
    $suggest = [Math]::Ceiling(($max + 6000) / 5000) * 5000
    Write-Output "  ⚠ 启动失败路径已达 $max ms，与 ToggleTimeoutMs 同量级 —— 过渡态超时逃生会在"
    Write-Output "    正常失败流程里抢先触发。建议把 ToggleTimeoutMs 提到 $suggest ms（留出删除路径 6s 余量）。"
  } else {
    Write-Output '  ✓ 启动失败路径远小于 ToggleTimeoutMs，当前默认值够用。'
  }
} finally {
  Write-Output ''
  Write-Output '== 清理 =='
  if (Get-Service -Name $SVC -EA SilentlyContinue) {
    Remove-Service -Name $SVC
    Write-Output "  已删除 $SVC"
  } else {
    Write-Output "  $SVC 不存在，无需清理"
  }
  Start-Sleep -Milliseconds 300
  & sc.exe query $SVC 2>&1 | Out-Null
  Write-Output "  复核 sc query 返回 $LASTEXITCODE（1060 = 已删除）"
}
