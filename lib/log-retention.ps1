# lib/log-retention.ps1 — 服务日志目录解析与轮转档清理
#
# 由 lib/util.ps1 聚合加载；默认目录取调用方作用域的 $logDir。

# 某服务的日志目录：读注册表 AppStdout 父目录，读不到回落 $logDir。**名字必须校验**（注册表会归一化 ..）。§Get-SvcLogDir
function Get-SvcLogDir([string]$n){
  if (-not $n -or $n -notmatch '^[A-Za-z0-9_.-]+$' -or $n -eq '.' -or $n -eq '..') { return $logDir }
  try {
    $p = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$n\Parameters" -Name AppStdout -EA Stop
    $dir = Split-Path ([string]$p.AppStdout) -Parent
    if ($dir -and (Test-Path -LiteralPath $dir)) { return $dir }
  } catch {}
  $logDir
}

# ---- 轮转档保留：只碰轮转档，永不动当前档 ----
# 删除须同时满足「不在前 KeepCount 份」且「早于 KeepDays 天」。参数名不能用 $LogDir（会遮蔽外层变量）。§Remove-RotatedLogs
function Remove-RotatedLogs([string]$LogPath,[int]$KeepCount=10,[int]$KeepDays=14){
  if (-not $LogPath) { $LogPath = $logDir }
  if (-not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) { return @() }
  $cut = (Get-Date).AddDays(-$KeepDays)
  # 只判「是不是轮转档」通用形态，不绑特定服务名。
  # 必须锚到结尾：服务名允许点与横线（`MySvc.err-20260101`），当前档 `MySvc.err-20260101.out.log`
  # 的 BaseName 里同样含 `.err-20260101`——不锚定就会把当前日志当轮转档删掉。§Remove-RotatedLogs
  $rot = @(Get-ChildItem -LiteralPath $LogPath -File -Filter '*.log' -EA SilentlyContinue |
    Where-Object { $_.BaseName -match '\.(out|err)-\d{8}(T\d{6}\.\d{3})?$' } |
    Sort-Object LastWriteTime -Descending)
  # 最近 KeepCount 份豁免（按修改时间倒序的前 KeepCount 个）。
  $keep = @($rot | Select-Object -First $KeepCount | ForEach-Object { $_.FullName })
  # 剩下的若早于 cut 也删；晚于 cut 的留（近期高频轮转不应被一刀切）。
  $del = @($rot | Where-Object {
    $_.FullName -notin $keep -and $_.LastWriteTime -lt $cut
  } | ForEach-Object { $_.FullName })
  foreach ($f in $del) { Remove-Item -LiteralPath $f -Force -EA SilentlyContinue }
  $del
}
