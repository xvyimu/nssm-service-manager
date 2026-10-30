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

# 从文件末尾按块反向扫，逐行回调 $onLine（**最新在前**）；$onLine 返回 $true 时停止扫描。
# 为什么不用「先圈窗口再整段读」：稀疏服务的记录很少，窗口要一路翻倍，每翻一次都得重新解码
# 整个尾部——21MB 文件实测 8.8 秒。这里边扫边判，只付一次代价。
#
# 字节级切行（找 0x0A）再解码，多字节字符不会被截断；跨块的行由 $carry 拼回。
# 给了 $Needle 时先做整块预筛：整块（和遗留的半行）都不含目标就只留块首那半行、跳过其余行。
# 稀疏服务扫 20MB 由 1.9s 降到几十毫秒（2026-10-30 实测）。
function Invoke-HealthTailScan([string]$path, [scriptblock]$onLine, [int]$ChunkBytes = 65536, [string]$Needle) {
  if (-not $path -or -not $onLine -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
  $latin1 = [Text.Encoding]::GetEncoding(28591)   # 只用于搜索：ASCII 字节原样、非 ASCII 变 '?'
  $fs = [IO.File]::Open($path, 'Open', 'Read', [IO.FileShare]::ReadWrite)
  try {
    $pos = $fs.Length
    if ($pos -le 0) { return }
    $buf = [byte[]]::new($ChunkBytes)
    $carry = [byte[]]::new(0)     # 「行首在更早的块里」的那些字节（来自较新的块）
    $empty = [byte[]]::new(0)
    $nl = [System.Collections.Generic.List[int]]::new()
    while ($pos -gt 0) {
      $read = [int][math]::Min($ChunkBytes, $pos)
      $pos -= $read
      [void]$fs.Seek($pos, 'Begin')
      $n = $fs.Read($buf, 0, $read)
      if ($n -le 0) { break }
      $ct = $latin1.GetString($buf, 0, $n)
      if ($Needle -and -not $ct.Contains($Needle) -and
          -not ($carry.Length -and $latin1.GetString($carry).Contains($Needle))) {
        # 整块无目标：只留下块首那半行（它是某条行的尾巴，行首在更早的块里）
        $firstNl = $ct.IndexOf("`n")
        if ($firstNl -lt 0) {
          # 整块属于同一行：接在已有 carry 后面
          $nb = [byte[]]::new($n + $carry.Length)
          [Array]::Copy($buf, 0, $nb, 0, $n)
          if ($carry.Length) { [Array]::Copy($carry, 0, $nb, $n, $carry.Length) }
          $carry = $nb
        } elseif ($firstNl -gt 0) {
          # 换行前是上一条的尾巴；旧 carry 那条已在本块内完整结束且无目标，丢掉
          $carry = [byte[]]::new($firstNl)
          [Array]::Copy($buf, 0, $carry, 0, $firstNl)
        } else {
          $carry = $empty       # 块以换行开头：旧 carry 那条也在块内结束了
        }
        continue
      }
      # 本块含目标：按行切（换行位置用原生 IndexOf 找，别逐字节跑 PS 循环）
      $nl.Clear()
      $s = 0
      while ($s -lt $n) {
        $idx = $ct.IndexOf("`n", $s)
        if ($idx -lt 0) { break }
        $nl.Add($idx); $s = $idx + 1
      }
      $end = $n
      for ($k = $nl.Count - 1; $k -ge 0; $k--) {
        $i = $nl[$k]
        $headLen = $end - ($i + 1)
        $end = $i
        $lb = [byte[]]::new($headLen + $carry.Length)
        if ($headLen) { [Array]::Copy($buf, $i + 1, $lb, 0, $headLen) }
        if ($carry.Length) { [Array]::Copy($carry, 0, $lb, $headLen, $carry.Length) }
        $carry = $empty
        # 行级预筛同理：不命中的行不付 UTF8 解码 + 回调的钱
        if ($Needle -and -not $latin1.GetString($lb).Contains($Needle)) { continue }
        $line = [Text.Encoding]::UTF8.GetString($lb).TrimEnd("`r")
        if ($line -and (& $onLine $line)) { return }
      }
      if ($end -gt 0) {
        # 本块左端还有半行：和已攒的尾部拼起来，等更早的块给出行首
        $nb = [byte[]]::new($end + $carry.Length)
        [Array]::Copy($buf, 0, $nb, 0, $end)
        if ($carry.Length) { [Array]::Copy($carry, 0, $nb, $end, $carry.Length) }
        $carry = $nb
      }
    }
    # 文件第一行没有前置换行：残留的就是它
    if ($carry.Length) {
      $line = [Text.Encoding]::UTF8.GetString($carry).TrimEnd("`r")
      if ($line) { [void](& $onLine $line) }
    }
  } finally { $fs.Dispose() }
}

# 返回最后 $Max 条非空行（**最新在前**）。给单测与「只看几行」的场景用，实现复用反向扫描。
function Read-HealthTailLines([string]$path, [int]$Max = 200) {
  $lines = [System.Collections.Generic.List[string]]::new()
  if (-not $path -or $Max -lt 1) { return $lines }
  Invoke-HealthTailScan $path {
    param($line)
    $lines.Add($line)
    $lines.Count -ge $Max
  }
  $lines
}

# 读历史，**最新在前**，最多 $Limit 条，只看最近 $Days 个文件（一天一个）。
# 每个文件从尾部反向扫、凑够 $Limit 条就停；$Days 只决定最多看几个文件。坏行跳过而不是整份失败。
function Get-HealthEvents([string]$dir, [string]$name, [int]$Limit = 200, [int]$Days = 7) {
  if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return @() }
  $files = @(Get-ChildItem -LiteralPath $dir -Filter 'health-*.ndjson' -File |
    Sort-Object Name -Descending | Select-Object -First ([math]::Max(1, $Days)))
  $out = [System.Collections.Generic.List[object]]::new()
  # 快路径：落盘用的是 ConvertTo-Json -Compress，键值之间没有空格，所以 `"n":"<name>"` 可以直接
  # 子串匹配。服务名正常限定在 A-Za-z0-9_.-（Test-SvcInput），但清单是手写的，含引号/反斜杠时
  # JSON 会转义、子串就匹配不上——那种名字直接放弃预筛，退回全行扫描（慢但不丢条目）。
  $needle = if ($name -and $name -match '^[A-Za-z0-9_.-]+$') { '"n":"' + $name + '"' } else { $null }
  foreach ($f in $files) {
    if ($out.Count -ge $Limit) { break }
    Invoke-HealthTailScan $f.FullName {
      param($line)
      $e = $null
      try { $e = $line | ConvertFrom-Json -AsHashtable } catch { return $false }
      if (-not $e -or -not $e.n) { return $false }
      if ($name -and $e.n -ne $name) { return $false }   # 预筛只是加速，真判据仍在这里
      $out.Add([pscustomobject]$e)
      $out.Count -ge $Limit
    } -Needle $needle
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
