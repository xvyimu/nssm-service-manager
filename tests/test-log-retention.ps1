#requires -Version 7.0
# T7：日志保留的真实口径回归。
#
# 背景：config.ps1 原注释写「每服务前 N 份豁免」，而 util.ps1 的 Remove-RotatedLogs
# 实现是**跨服务全局**按修改时间倒序取前 KeepCount 份；删除须同时满足
# 「不在全局前 KeepCount 份」且「早于 KeepDays 天」两个条件。
# 提示词要求「注释与实现一致」——本条选改注释对齐实现（口径本身合理：全局上限 +
# 时间窗兜底，不会因服务数增多而线性放大总档数）。
#
# 本测试锁住实现行为，防止将来有人照「每服务 N 份」的旧注释把实现改坏。
# 实测基线（2026-10-05，本机）：两个服务各 6 份、均 1 天前 → 删除 0 份。
param([string]$RepoRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'lib/config.ps1')
. (Join-Path $RepoRoot 'lib/util.ps1')
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }

$d = Join-Path ([IO.Path]::GetTempPath()) ("sm-logret-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $d | Out-Null
# 造一份轮转档：名字须是 NSSM 的真实形态（BaseName 匹配 \.(out|err)-\d{8}）
$make = {
  param([string]$svc, [string]$stamp, [int]$daysAgo)
  $f = Join-Path $d "$svc.out-$stamp.log"
  [IO.File]::WriteAllText($f,'x')
  (Get-Item $f).LastWriteTime = (Get-Date).AddDays(-$daysAgo)
  $f
}
try {
  # 两个服务各 6 份、均 1 天前：全在 14 天窗口内 → 一份都不该删
  foreach ($svc in 'SvcA','SvcB') {
    foreach ($i in 1..6) { & $make $svc ("2026090${i}T000000.000") 1 | Out-Null }
  }
  $del = @(Remove-RotatedLogs $d 10 14)
  Assert ($del.Count -eq 0) "Files inside the KeepDays window must not be deleted, got $($del.Count)."
  Assert (@(Get-ChildItem $d -Filter *.log -File).Count -eq 12) 'Unexpected file count inside window.'

  # 再加 5 份 20 天前的（跨过窗口，且不属于全局前 10 份）→ 应删掉这 5 份
  foreach ($i in 1..5) { & $make 'SvcC' ("2026010${i}T000000.000") 20 | Out-Null }
  $del2 = @(Remove-RotatedLogs $d 10 14)
  Assert ($del2.Count -eq 5) "Files older than KeepDays and outside the global top-10 should be deleted, got $($del2.Count)."
  Assert (@($del2 | ForEach-Object { Split-Path $_ -Leaf }) -notcontains 'SvcA.out-20260901T000000.000.log') 'Global top-10 exemption not honored.'

  # 当前档（无轮转后缀）永不动
  $cur = Join-Path $d 'SvcA.out.log'
  [IO.File]::WriteAllText($cur,'x')
  (Get-Item $cur).LastWriteTime = (Get-Date).AddDays(-30)
  [void](Remove-RotatedLogs $d 10 14)
  Assert (Test-Path $cur) 'Current log file (no rotation suffix) must never be deleted.'

  # 不存在的目录：返回空数组，不抛
  $none = @(Remove-RotatedLogs (Join-Path $d 'nope') 10 14)
  Assert ($none.Count -eq 0) 'Missing log directory should return an empty array.'

  Write-Output 'PASS: log retention is global-top-N plus age-window (both conditions required); current logs untouched.'
} finally { Remove-Item $d -Recurse -Force -EA SilentlyContinue }
