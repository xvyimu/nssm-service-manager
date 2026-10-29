#requires -Version 7.0
# 轮转档识别：只删轮转档，永不动当前档。
# 修前：判据 `'\.(out|err)-\d{8}'` 未锚定结尾，服务名本身含 `.err-20260101` 时
# 当前日志 `MySvc.err-20260101.out.log` 的 BaseName 也命中，服务停着时当前日志被真删。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'lib/util.ps1')
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }

$dir = Join-Path ([IO.Path]::GetTempPath()) "sm-rot-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $dir | Out-Null
try {
  $old = (Get-Date).AddDays(-20)
  # 当前档：服务名本身叫 MySvc.err-20260101
  $current = Join-Path $dir 'MySvc.err-20260101.out.log'
  [IO.File]::WriteAllText($current, 'current', [Text.UTF8Encoding]::new($false))
  [IO.File]::SetLastWriteTime($current, $old)
  # 真轮转档（NSSM 格式带 T 时间戳）
  $rot1 = Join-Path $dir 'MySvc.err-20260101T120000.000.log'
  [IO.File]::WriteAllText($rot1, 'rot', [Text.UTF8Encoding]::new($false))
  [IO.File]::SetLastWriteTime($rot1, $old)
  $rot2 = Join-Path $dir 'MySvc.out-20260102T130000.500.log'
  [IO.File]::WriteAllText($rot2, 'rot', [Text.UTF8Encoding]::new($false))
  [IO.File]::SetLastWriteTime($rot2, $old)
  # 天数窗口内的轮转档：不该删
  $recent = Join-Path $dir 'MySvc.out-20260103T140000.000.log'
  [IO.File]::WriteAllText($recent, 'rot', [Text.UTF8Encoding]::new($false))

  $null = Remove-RotatedLogs $dir 0 1
  Assert (Test-Path -LiteralPath $current) '当前日志被误删（轮转档正则未锚定结尾）'
  Assert (-not (Test-Path -LiteralPath $rot1)) '旧轮转档应被删'
  Assert (-not (Test-Path -LiteralPath $rot2)) '旧轮转档应被删'
  Assert (Test-Path -LiteralPath $recent) '天数窗口内的轮转档不该删'
} finally { Remove-Item -LiteralPath $dir -Recurse -Force -EA SilentlyContinue }

Write-Output 'PASS: 当前日志保留；NSSM 格式的旧轮转档被删；窗口内的轮转档保留。'
