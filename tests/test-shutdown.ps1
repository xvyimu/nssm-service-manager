#requires -Version 7.0
# P3-1 回归：关闭必须有界、幂等，且把健康队列收尾。
# 背景：后台卡在 $svc.Start()（等满 ServicesPipeTimeout ≈ 30s）或一条外部命令里时，
# UI 线程跟着等会让窗口关不掉、进程不退、mutex 仍被占——用户再双击就是「没反应」。
# 现在 Stop-Background 只等 1500ms，未结束就只发停止请求、不 Dispose runspace。
# 另外 Closed 与托盘退出可能各触发一次，重复拆 runspace 会抛噪声异常，所以必须幂等。
# 这里用真 runspace 跑一条 30 秒的 Start-Sleep，模拟「后台不肯结束」。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
foreach ($module in 'config','util','health') { . (Join-Path $RepoRoot "lib/$module.ps1") }
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
# Write-CrashLog 由 GUI 入口定义（service-manager-gui.ps1）；单测不落盘。
function Write-CrashLog([string]$m) { }

$tmpDir = Join-Path ([IO.Path]::GetTempPath()) "sm-shutdown-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

$rs = $null
$ps = $null
try {
  # ---- 夹具：真 runspace 卡住 30 秒；健康队列里压着 2 条来不及 drain 的事件 ----
  $rs = [runspacefactory]::CreateRunspace()
  $rs.Open()
  $ps = [powershell]::Create().AddScript('Start-Sleep -Seconds 30')
  $ps.Runspace = $rs
  $handle = $ps.BeginInvoke()
  Assert ($handle.IsCompleted -eq $false) '夹具：后台管道应仍在运行'

  $script:sync = @{ stop = $false; wake = [Threading.AutoResetEvent]::new($false) }
  $script:bgStopped = $false
  $script:web = $null
  $script:healthQueue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
  $script:healthHistoryDir = $tmpDir
  $script:healthQueue.Enqueue((New-HealthEvent 'A' '运行中' '正常'))
  $script:healthQueue.Enqueue((New-HealthEvent 'A' '运行中' '正常'))

  # ---- 1. 有界：1500ms 等待 + 收尾，必须远小于后台的 30 秒 ----
  $sw = [Diagnostics.Stopwatch]::StartNew()
  Stop-Background -Handle $handle -Pipeline $ps -Runspace $rs
  $sw.Stop()
  Assert ($sw.ElapsedMilliseconds -lt 3000) "关闭必须在 3 秒内有界返回，实际 $($sw.ElapsedMilliseconds)ms"
  Assert ($script:sync.stop -eq $true) '关闭必须置 sync.stop'
  Assert ($script:bgStopped -eq $true) '关闭必须置 bgStopped（幂等标记）'

  # ---- 2. 健康队列收尾：关闭瞬间的事件不能丢 ----
  $healthFile = Get-HealthFile $tmpDir
  Assert (Test-Path -LiteralPath $healthFile) "关闭应把健康事件落盘，文件不存在：$healthFile"
  $lines = @(Get-Content -LiteralPath $healthFile)
  Assert ($lines.Count -eq 2) "健康历史应有 2 行，实际 $($lines.Count) 行"
  $healthOk = $true
  foreach ($line in $lines) {
    try { $ev = $line | ConvertFrom-Json } catch { $healthOk = $false; break }
    if ($ev.n -ne 'A' -or $ev.st -ne '运行中' -or $ev.h -ne '正常' -or -not $ev.ts) { $healthOk = $false }
  }
  Assert ($healthOk) "健康历史每行都应是完整的 NDJSON 事件：$($lines -join ' / ')"
  Assert ($script:healthQueue.IsEmpty) '关闭应把健康队列排空'
  Write-Output 'PASS: Stop-Background 有界返回（<3000ms）且置停止标志'
  Write-Output 'PASS: 关闭时健康队列收尾落盘（2 行完整 NDJSON）'

  # ---- 3. 幂等：第二次立即返回、不抛 ----
  $sw.Restart()
  Stop-Background -Handle $handle -Pipeline $ps -Runspace $rs
  $sw.Stop()
  Assert ($sw.ElapsedMilliseconds -lt 500) "重复调用应立即返回，实际 $($sw.ElapsedMilliseconds)ms"
  Assert (@(Get-Content -LiteralPath $healthFile).Count -eq 2) '重复调用不得重复写健康历史'
  Write-Output 'PASS: 重复调用 Stop-Background 立即返回且不抛（幂等）'
} finally {
  # 先尽量停掉仍在 sleep 的管道，再拆 runspace，避免整轮测试被 30 秒拖住。
  if ($ps) {
    try { if ($ps.InvocationStateInfo.State -eq 'Running') { $ps.Stop() } } catch { }
    try { $ps.Dispose() } catch { }
  }
  if ($rs) { try { $rs.Dispose() } catch { } }
  if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force }
}
Write-Output 'PASS: 关闭收尾（有界 / 幂等 / 健康队列收尾）'
