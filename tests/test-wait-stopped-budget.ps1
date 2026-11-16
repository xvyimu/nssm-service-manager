#requires -Version 7.0
# Wait-Stopped 的预算封顶：轮次、单次查询、步长与收尾都必须在总预算内。
# 单独成文件是因为它要遮蔽 Get-SvcStateQuiet / Get-ServiceQueryCode（行为级夹具），
# 塞进 test-config-params 会把那个文件的注入断言搅混。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
. (Join-Path $RepoRoot 'lib/svc-common.ps1')

$script:queryLog = @()

# 夹具：每次查询吃满调用方给的超时（模拟 sc.exe 挂起），永远回 null；退出码永远 0（服务还在）。
function Get-SvcStateQuiet([string]$name, [int]$timeoutMs = 0){
  $script:queryLog += [pscustomobject]@{ kind = 'state'; ms = $timeoutMs }
  if ($timeoutMs -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Min($timeoutMs, 400)) }
  $null
}
function Get-ServiceQueryCode([string]$name, [int]$timeoutMs = 0){
  $script:queryLog += [pscustomobject]@{ kind = 'code'; ms = $timeoutMs }
  if ($timeoutMs -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Min($timeoutMs, 400)) }
  0
}

# ---- A. 多轮：查询 + 步长都被收口，总耗时不超过预算 ----
$script:sync = @{ waitStoppedTimeoutMs = 1500; waitStoppedPollMs = 50; svcStateTimeoutMs = 200 }
$script:queryLog = @()
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Wait-Stopped 'FakeA'
$elapsed = $sw.ElapsedMilliseconds
Assert (-not $r) "服务永不停止时应返回 false，实际 $r"
Assert ($elapsed -le 1750) "多轮路径超预算：实测 ${elapsed}ms，预算 1500ms + 250ms 容差"
Assert (@($script:queryLog).Count -ge 3) "应发生多轮查询，实际 $((@($script:queryLog)).Count) 次"
$lastState = @($script:queryLog | Where-Object { $_.kind -eq 'state' })[-1]
Assert ($lastState.ms -le 200) "单次查询不得超过传入上限，实际 $($lastState.ms)ms"

# ---- B. 小预算：固定 1000ms 预留会把窗口吃成负数，必须按比例缩 ----
foreach ($budget in 100, 300, 1200) {
  $script:sync = @{ waitStoppedTimeoutMs = $budget; waitStoppedPollMs = 20; svcStateTimeoutMs = 5000 }
  $script:queryLog = @()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  [void](Wait-Stopped 'FakeB')
  $elapsed = $sw.ElapsedMilliseconds
  # 容差 = 一次最坏查询（夹具最多睡 400ms）
  Assert ($elapsed -le ($budget + 450)) "预算 ${budget}ms 未被兑现：实测 ${elapsed}ms"
}

# ---- C. 收尾补查：服务在最后一刻停了，不能被「剩余不足一格」直接 break 掉 ----
$script:sync = @{ waitStoppedTimeoutMs = 400; waitStoppedPollMs = 50; svcStateTimeoutMs = 60 }
$script:queryLog = @()
$script:stopAfter = 4
function Get-SvcStateQuiet([string]$name, [int]$timeoutMs = 0){
  $script:queryLog += 1
  Start-Sleep -Milliseconds 50
  if (@($script:queryLog).Count -ge $script:stopAfter) { return 'Stopped' }
  $null
}
$r = Wait-Stopped 'FakeC'
Assert $r "服务在第 $($script:stopAfter) 次查询停止时，Wait-Stopped 应返回 true（收尾补查不得被跳过）"

Write-Output 'PASS: Wait-Stopped caps total elapsed at the configured budget across rounds, small budgets and the final tail query.'
