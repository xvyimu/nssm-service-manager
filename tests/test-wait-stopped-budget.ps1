#requires -Version 7.0
# Wait-Stopped 的预算必须真正封顶：两次查询、步长、Kill 后的收尾都在预算内。
# 旧实现只给第一次查询收口，实测 12s 预算会跑成 12.2~12.8s（第二轮查询 + sleep 超支）。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
foreach ($module in 'config','util','svc-common') { . (Join-Path $RepoRoot "lib/$module.ps1") }
. (Join-Path $PSScriptRoot 'test-helpers.ps1')

$origState = ${function:Get-SvcStateQuiet}
$origCode  = ${function:Get-ServiceQueryCode}
# 模拟真实最坏路径：每次查询吃满自己的超时，再叠加 Invoke-ExternalQuiet 超时后
# WaitForExit(1000) 的收尾；查询永远拿不到 Stopped。
function Get-SvcStateQuiet([string]$name, [int]$timeoutMs = 0) {
  $spend = if ($timeoutMs -gt 0) { $timeoutMs + 1000 } else { 40 }
  Start-Sleep -Milliseconds $spend
  $null
}
function Get-ServiceQueryCode([string]$name, [int]$timeoutMs = 0) { Start-Sleep -Milliseconds 40; 0 }

try {
  # ---- 1. 一直不停：总耗时必须被预算封顶（含 kill 收尾），不能超支 ----
  $script:sync = @{ waitStoppedTimeoutMs = 1200; waitStoppedPollMs = 50; svcStateTimeoutMs = 5000 }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $stopped = Wait-Stopped 'NeverStops'
  $elapsed = $sw.ElapsedMilliseconds
  Assert (-not $stopped) '服务始终不停时必须返回 false。'
  Assert ($elapsed -le 1400) "Wait-Stopped 超出预算：实测 ${elapsed}ms，上限 1200ms + 200ms 容差（查询与 kill 收尾都必须按剩余预算收口）"

  # ---- 2. 明确停止：立刻返回 true，不空转 ----
  function Get-SvcStateQuiet([string]$name, [int]$timeoutMs = 0) { 'Stopped' }
  $sw2 = [Diagnostics.Stopwatch]::StartNew()
  $stopped2 = Wait-Stopped 'AlreadyStopped'
  $elapsed2 = $sw2.ElapsedMilliseconds
  Assert ($stopped2) '服务已停止时必须返回 true。'
  Assert ($elapsed2 -lt 500) "已停止的服务应立即返回，实测 ${elapsed2}ms"

  # ---- 3. 服务已被删除（1060）：也算停住 ----
  function Get-SvcStateQuiet([string]$name, [int]$timeoutMs = 0) { $null }
  function Get-ServiceQueryCode([string]$name, [int]$timeoutMs = 0) { 1060 }
  Assert (Wait-Stopped 'Gone') '服务已删除（1060）应判为停住。'

  Write-Output 'PASS: Wait-Stopped caps total elapsed at the configured budget (queries, sleep and kill tail all bounded).'
} finally {
  ${function:Get-SvcStateQuiet} = $origState
  ${function:Get-ServiceQueryCode} = $origCode
}
