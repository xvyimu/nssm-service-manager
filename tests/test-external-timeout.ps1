#requires -Version 7.0
# 外部命令超时：sc.exe / nssm.exe 卡住时必须 Kill 并返回失败。
# 修前：ReadToEnd() 同步阻塞，一条挂住的命令会让整个后台命令队列永久停摆——
# 连异常都不抛，crash log 里留不下线索。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'lib/svc-common.ps1')
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }

$pwshExe = (Get-Command pwsh -EA SilentlyContinue).Source
Assert $pwshExe '找不到 pwsh，无法测外部进程超时'

$prev = $script:sync
try {
  $script:sync = @{ extCommandTimeoutMs = 500 }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $r = Invoke-ExternalQuiet $pwshExe @('-NoProfile','-Command','Start-Sleep 30')
  $sw.Stop()
  Assert ($r.exit -eq -1) "超时应返回 exit=-1，got $($r.exit)"
  Assert ($r.out -match '超时') "超时消息应可辨识，got [$($r.out)]"
  Assert ($sw.ElapsedMilliseconds -lt 10000) "超时应在 10s 内返回，got $($sw.ElapsedMilliseconds)ms"

  # 正常命令的退出码与输出不受影响
  $script:sync = @{ extCommandTimeoutMs = 10000 }
  $r = Invoke-ExternalQuiet $pwshExe @('-NoProfile','-Command','Write-Output hi; exit 3')
  Assert ($r.exit -eq 3) "正常命令退出码应为 3，got $($r.exit)"
  Assert ($r.out -match 'hi') "正常命令输出应保留，got [$($r.out)]"
} finally { $script:sync = $prev }

Write-Output 'PASS: 外部命令超时被 Kill 并返回失败；正常命令的退出码与输出不受影响。'
