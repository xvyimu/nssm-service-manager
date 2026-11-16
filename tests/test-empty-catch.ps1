#requires -Version 7.0
# 两条机器门禁：
# 1) 空 catch：全仓（lib/*.ps1 + service-manager-gui.ps1）只能有 6 处以内，且每一处的上一行必须是
#    「# 空 catch 有意：」注释。空 catch 是「刻意吞掉」的决定，写不出原因就该是普通 catch（带日志），
#    所以这里把「无注释的空 catch」变成红灯——新增一处没注释的空 catch 就红。
# 2) tick 里的磁盘 stat 降频：400ms 一帧 × 常驻几天不再每帧 stat services.json（5s 一次），
#    但「外部改动」的判定语义不变——到点仍由 Test-SvcFileChanged 回答，命中仍返回 $true。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'lib/config.ps1')
. (Join-Path $RepoRoot 'lib/util.ps1')
. (Join-Path $PSScriptRoot 'test-helpers.ps1')

# ---- 1. 空 catch：数量上限 + 每处带标记注释 ----
$marker = '# 空 catch 有意：'
$sources = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'lib') -Filter '*.ps1' -File | Sort-Object Name)
$sources += @(Get-Item -LiteralPath (Join-Path $RepoRoot 'service-manager-gui.ps1'))
$emptyTotal = 0
$unmarked = @()
$perFile = @()
foreach ($f in $sources) {
  $lines = @(Get-Content -LiteralPath $f.FullName -Encoding utf8)
  $count = 0
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -notmatch 'catch\s*\{\s*\}') { continue }
    $count++
    # 上一行必须是标记注释；允许中间隔一行空白，隔任何语句都算不合格。
    $j = $i - 1
    if ($j -ge 0 -and [string]::IsNullOrWhiteSpace($lines[$j])) { $j-- }
    if ($j -lt 0 -or -not $lines[$j].Contains($marker)) { $unmarked += "$($f.Name):$($i + 1)" }
  }
  if ($count) { $perFile += "$($f.Name)=$count" }
  $emptyTotal += $count
}
Assert ($emptyTotal -le 6) "空 catch 应 ≤6 处，实际 $emptyTotal 处（$($perFile -join ', ')）"
Assert (-not $unmarked.Count) "空 catch 的上一行必须是「$marker」注释；未标注：$($unmarked -join ', ')"
Write-Output "PASS: 空 catch $emptyTotal 处（上限 6：$($perFile -join ', ')），全部带「$marker」注释"

# ---- 2. tick 里的清单 stat 只按 5s 节流，判定语义仍归 Test-SvcFileChanged ----
# 遮蔽计数桩：同名重定义覆盖 svc-store 的实现，只数被调次数、不改判定口径。
$script:fileCheckCalls = 0
$script:fileCheckAnswer = $false
function Test-SvcFileChanged { $script:fileCheckCalls++; $script:fileCheckAnswer }

Assert ($script:SVC_FILE_CHECK_MS -eq 5000) "清单 stat 间隔应为 5000ms，实际 $($script:SVC_FILE_CHECK_MS)"

$script:fileCheckCalls = 0
$script:lastSvcFileCheck = 0                                   # 还没查过 → 首帧立刻查
$null = Invoke-SvcFileCheck
Assert ($script:fileCheckCalls -eq 1) "首帧应查一次清单 stat，实际 $($script:fileCheckCalls) 次"

# 时间戳设为「刚查过」，再 tick 两次：一次都不该查（这就是 2.5 次/秒 → 0.2 次/秒）
$script:lastSvcFileCheck = [Environment]::TickCount64
$null = Invoke-SvcFileCheck
$null = Invoke-SvcFileCheck
Assert ($script:fileCheckCalls -eq 1) "5s 内连跑两帧不该再 stat，实际累计 $($script:fileCheckCalls) 次"

# 到点必须恢复查询，且结果如实返回（调用方据此提示按 F5）——别把节流写成「只查一次」
$script:lastSvcFileCheck = [Environment]::TickCount64 - 6000
$script:fileCheckAnswer = $true
Assert (Invoke-SvcFileCheck) '到点查一次、命中外部改动时应返回 $true'
Assert ($script:fileCheckCalls -eq 2) "到点后应再查一次，实际累计 $($script:fileCheckCalls) 次"
Write-Output 'PASS: 清单 stat 按 5s 节流（5s 内两帧只查 1 次；到点恢复查询并如实返回 $true）'
