#requires -Version 7.0
# 外部命令超时：sc.exe / nssm.exe 卡住时必须 Kill 并返回失败。
# 修前：ReadToEnd() 同步阻塞，一条挂住的命令会让整个后台命令队列永久停摆——
# 连异常都不抛，crash log 里留不下线索。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'lib/svc-common.ps1')
. (Join-Path $PSScriptRoot 'test-helpers.ps1')

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

# ---- Get-SvcStateQuiet：状态查询必须带硬超时、且永不抛 ----
# 修前：poll.ps1 的 4 处状态查询都走 Get-Service——它没有超时参数，SCM 挂起（等不到的句柄 /
# 被安全软件挂起 / 服务数据库锁）时调用永久阻塞，后台探测 runspace 就此停摆、卡片冻结在最后一帧。
$pollSrc = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'lib/poll.ps1')
$pollCode = (($pollSrc -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
Assert ($pollCode -notmatch '\bGet-Service\b') 'poll.ps1 仍在直接调用 Get-Service（无超时，SCM 挂起会拖死 runspace）'

# (a) 真实查询：不存在的服务 → $null，不抛，且在硬超时内返回
$ghost = "sm-no-such-svc-$([guid]::NewGuid().ToString('N'))"
$sw = [Diagnostics.Stopwatch]::StartNew()
$state = Get-SvcStateQuiet $ghost
$sw.Stop()
Assert ($null -eq $state) "不存在的服务应返回 `$null，got [$state]"
Assert ($sw.ElapsedMilliseconds -lt 5000) "不存在的服务应在硬超时内返回，got $($sw.ElapsedMilliseconds)ms"

# (b) 超时：stub 返回 exit=-1 → $null 不抛；超时值必须真的传给 Invoke-ExternalQuiet（否则 Kill 不了）
$script:ieqTimeout = $null; $script:ieqArgv = $null
function Invoke-ExternalQuiet([string]$exe, [string[]]$argv, [int]$timeoutMs = 0) {
  $script:ieqArgv = @($argv); $script:ieqTimeout = $timeoutMs
  @{ exit = -1; out = '' }
}
$state = Get-SvcStateQuiet 'AnySvc'
Assert ($null -eq $state) "超时应返回 `$null，got [$state]"
Assert ($script:ieqTimeout -eq 3000) "默认硬超时应为 3000ms，got $($script:ieqTimeout)"
Assert ($script:ieqArgv[0] -eq 'query' -and $script:ieqArgv[1] -eq 'AnySvc') "应走 sc.exe query <name>，got $($script:ieqArgv -join ' ')"

# (c) 正常解析：stub 返回 sc.exe query 的 RUNNING 块 → 'Running'（与 ServiceController.Status 同口径）
function Invoke-ExternalQuiet([string]$exe, [string[]]$argv, [int]$timeoutMs = 0) {
  @{ exit = 0; out = "SERVICE_NAME: AnySvc`n        TYPE               : 10  WIN32_OWN_PROCESS`n        STATE              : 4  RUNNING" }
}
$state = Get-SvcStateQuiet 'AnySvc'
Assert ($state -eq 'Running') "STATE 4 应解析成 Running，got [$state]"

# (d) 超时提示 60s 限频：连续两次超时只入队一条
$script:svcStateTimeoutNoticeAt = 0
$msgQueue = [Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:sync = @{ msg = $msgQueue }
function Invoke-ExternalQuiet([string]$exe, [string[]]$argv, [int]$timeoutMs = 0) { @{ exit = -1; out = '' } }
[void](Get-SvcStateQuiet 'A')
[void](Get-SvcStateQuiet 'B')
Assert ($msgQueue.Count -eq 1) "两次超时只应入队一条提示，实际 $($msgQueue.Count)"

Write-Output 'PASS: 外部命令超时被 Kill 并返回失败；正常命令的退出码与输出不受影响。'
Write-Output 'PASS: Get-SvcStateQuiet 硬超时（3000ms 传入）+ 不存在/超时返回 $null 不抛 + STATE 解析；poll.ps1 不再直接调 Get-Service。'
