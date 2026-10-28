#requires -Version 7.0
<#
用途：实测「启动失败（SCM 1053）路径的真实耗时」，判定 lib/config.ps1 的
      ToggleTimeoutMs = 45000 是否够大。

背景：ToggleTimeoutMs 必须大于**正常路径**最长耗时，否则过渡态超时逃生会在正常
      失败流程里抢先触发。未实测的是启动失败路径——Invoke-ServiceStart 在
      $svc.Start() 抛异常后回落 sc.exe start，而后者走 SCM 同步管道
      （ServicesPipeTimeout，本机未设 = 默认 30000ms）。

  **要测的是 1053（ERROR_SERVICE_REQUEST_TIMEOUT）**：进程起来了，但没在
  ServicesPipeTimeout 内连上 SCP 报告 RUNNING。
  不能用「exe 路径不存在」来造——那条路 SCM 立刻返回 2（文件找不到），
  实测 15~18ms，压根走不到管道等待。2026-10-28 之前本探针就是这么写的，
  所以它从来没产出过有意义的数字。

做法：注册一个 BinaryPathName 指向**存在但非服务程序**的 exe（cmd.exe 跑个长 ping），
      SCM 会拉起进程、等它连 SCP、超时后返回 1053。分别计时两条启动路径，
      每种场景各用一个干净的服务实例。最后删除服务并清掉残留子进程。

需要管理员权限（注册/删除服务）。临时服务名 __sm_1053_probe__。
用法：以管理员身份运行  pwsh -NoProfile -File tests/probe-1053-timing.ps1
#>
$ErrorActionPreference='Stop'

$isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
# 与服务端同一套 sc.exe 解析：本机 System32 可能不在 PATH 里，裸调会拿不到命令
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib/svc-common.ps1')
if (-not $isAdmin) { throw '需要管理员权限（注册/删除服务）。请以管理员身份运行本脚本。' }

$SVC = '__sm_1053_probe__'
$APP = Join-Path $env:SystemRoot 'System32\cmd.exe'
$ARG = '/c ping -n 300 127.0.0.1 > nul'   # 够长：确保进程活过 ServicesPipeTimeout

function Measure-Step([string]$label, [scriptblock]$sb) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $err = $null
  try { & $sb } catch { $err = $_.Exception.Message }
  $sw.Stop()
  $extra = if ($err) { "  异常: $($err.Substring(0,[Math]::Min(60,$err.Length)))" } else { '' }
  # 必须 Write-Host：调用方写 `$ms = Measure-Step ...`，用 Write-Output 会把这行说明
  # 一起收进 $ms，既看不到、又把 $ms 变成数组（[Math]::Max 随即失效）。
  Write-Host ("  {0,-42} {1,7} ms  LASTEXITCODE={2}{3}" -f $label, $sw.ElapsedMilliseconds, $LASTEXITCODE, $extra)
  $sw.ElapsedMilliseconds
}

# 每个场景一个干净的服务实例：上一条路径可能把服务留在半启动态
function Invoke-Case([string]$label, [scriptblock]$sb) {
  Remove-ProbeService
  New-Service -Name $SVC -BinaryPathName "`"$APP`" $ARG" -StartupType Manual | Out-Null
  Start-Sleep -Milliseconds 300
  try { Measure-Step $label $sb } finally { Remove-ProbeService }
}

function Remove-ProbeService {
  if (Get-Service -Name $SVC -EA SilentlyContinue) {
    & (Get-ScExe) stop $SVC *> $null
    Start-Sleep -Milliseconds 200
    Remove-Service -Name $SVC -EA SilentlyContinue
  }
  Start-Sleep -Milliseconds 200
  # 只杀命令行精确匹配的探测用子进程，不碰用户自己的 cmd
  Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" -EA SilentlyContinue |
    Where-Object { $_.CommandLine -like '*ping -n 300 127.0.0.1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
}

$pipe = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name ServicesPipeTimeout -EA SilentlyContinue).ServicesPipeTimeout
Write-Output "SCM ServicesPipeTimeout = $(if ($pipe) { "$pipe ms" } else { '未设 -> SCM 默认 30000 ms' })"
Write-Output "临时服务 $SVC，BinaryPathName = `"$APP`" $ARG（存在、但不是服务程序 -> 1053）"
Write-Output ''

try {
  Write-Output '== 计时：启动失败（1053）路径 =='
  $msSvc = Invoke-Case 'ServiceController.Start()（Invoke-ServiceStart 主路径）' {
    $s = [System.ServiceProcess.ServiceController]::new($SVC)
    try { $s.Start() } finally { $s.Dispose() }
  }
  $msSc = Invoke-Case 'sc.exe start（回落路径，走 SCM 同步管道）' {
    & (Get-ScExe) start $SVC *> $null
  }
  Write-Output ''

  Write-Output '== 结论 =='
  $max = [Math]::Max($msSvc, $msSc)
  Write-Output "  实测最长 $max ms；当前 ToggleTimeoutMs = 45000 ms"
  # 门槛按 ToggleTimeoutMs 留 6s 删除路径余量反推：低于 (45000-6000)=39000 才算安全。
  if ($max -ge 39000) {
    $suggest = [Math]::Ceiling(($max + 6000) / 5000) * 5000
    Write-Output "  ⚠ 启动失败路径已达 $max ms，逼近 ToggleTimeoutMs=45000 —— 过渡态超时逃生会在"
    Write-Output "    正常失败流程里抢先触发。建议把 ToggleTimeoutMs 提到 $suggest ms（留出删除路径 6s 余量）。"
  } else {
    Write-Output '  ✓ 启动失败路径远小于 ToggleTimeoutMs(45000)，当前默认值够用。'
  }
} finally {
  Write-Output ''
  Write-Output '== 清理 =='
  Remove-ProbeService
  & (Get-ScExe) query $SVC *> $null
  Write-Output "  复核 sc query 返回 $LASTEXITCODE（1060 = 已删除）"
}
