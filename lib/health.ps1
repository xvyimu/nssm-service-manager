# lib/health.ps1 — 健康状态历史：按天 NDJSON 落盘 + 读取（纯函数，不依赖 WPF）
# 为什么单独一份：poll.ps1 要把本文件文本前置进后台 runspace 才能写盘——UI 线程不碰 I/O。
# 只在「状态或健康值变了」时记一条，4 秒一拍的重复值不落盘（否则一天几万行）。

# 事件形状：{ ts: ISO8601(带时区), n: 服务名, st: 状态文案, h: 健康文案 }
function New-HealthEvent([string]$name, [string]$state, [string]$health) {
  [pscustomobject]@{
    ts = (Get-Date).ToString('o')
    n  = $name
    st = $state
    h  = $health
  }
}

# 只有变化才写：首次观测（prevState 为 $null）算变化，之后比较「状态+健康」二元组。
# 用字符串比对而不是对象比较：$null 与 '' 在这里都当「未知」，不该反复触发。
function Test-HealthChanged($prevState, $prevHealth, [string]$state, [string]$health) {
  if ($null -eq $prevState -and $null -eq $prevHealth) { return $true }
  "$prevState|$prevHealth" -ne "$state|$health"
}

function Get-HealthFile([string]$dir, [datetime]$at = (Get-Date)) {
  Join-Path $dir ("health-{0}.ndjson" -f $at.ToString('yyyyMMdd'))
}

# 追加一行。失败不抛给调用方（历史写不进去不该影响探测），返回 $true/$false 便于测试。
function Add-HealthEvent([string]$dir, $ev) {
  if (-not $dir -or -not $ev) { return $false }
  try {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $line = ($ev | ConvertTo-Json -Compress) + "`n"
    [IO.File]::AppendAllText((Get-HealthFile $dir), $line, [Text.UTF8Encoding]::new($false))
    $true
  } catch { $false }
}

# 读历史，**最新在前**，最多 $Limit 条，只看最近 $Days 个文件（一天一个）。
# 同一文件内按追加顺序（旧→新），所以从文件末尾往前读；坏行跳过而不是整份失败。
function Get-HealthEvents([string]$dir, [string]$name, [int]$Limit = 200, [int]$Days = 7) {
  if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return @() }
  $files = @(Get-ChildItem -LiteralPath $dir -Filter 'health-*.ndjson' -File |
    Sort-Object Name -Descending | Select-Object -First ([math]::Max(1, $Days)))
  $out = [System.Collections.Generic.List[object]]::new()
  foreach ($f in $files) {
    $lines = @([IO.File]::ReadAllLines($f.FullName, [Text.UTF8Encoding]::new($false)))
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
      $line = $lines[$i]
      if (-not $line) { continue }
      $e = $null
      try { $e = $line | ConvertFrom-Json -AsHashtable } catch { continue }
      if (-not $e -or -not $e.n) { continue }
      if ($name -and $e.n -ne $name) { continue }
      $out.Add([pscustomobject]$e)
      if ($out.Count -ge $Limit) { return $out.ToArray() }
    }
  }
  $out.ToArray()
}

# 删掉超过 $KeepDays 天的历史文件（由 Invoke-LogCleanup 调）。只认标准文件名，别的文件不碰。
function Remove-OldHealthFiles([string]$dir, [int]$KeepDays) {
  if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return @() }
  if ($KeepDays -lt 1) { return @() }
  $cut = (Get-Date).Date.AddDays(-$KeepDays)
  $removed = @()
  foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'health-*.ndjson' -File)) {
    $m = [regex]::Match($f.BaseName, '^health-(\d{8})$')
    if (-not $m.Success) { continue }
    $d = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($m.Groups[1].Value, 'yyyyMMdd', $null, 0, [ref]$d)) { continue }
    if ($d -lt $cut) {
      Remove-Item -LiteralPath $f.FullName -Force -EA SilentlyContinue
      $removed += $f.Name
    }
  }
  $removed
}
