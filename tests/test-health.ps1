#requires -Version 7.0
# 健康历史：只在变化时落一条、NDJSON 按天分文件、最新在前、坏行跳过、按天清理，
# 以及「UI 入队 → 后台 runspace 落盘」这条链路（UI 线程不碰 I/O）。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'lib/health.ps1')
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }

$dir = Join-Path ([IO.Path]::GetTempPath()) "sm-health-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $dir | Out-Null
try {
  # ---- 1. 变化判定：首次观测算变化，之后比「状态+健康」二元组 ----
  Assert (Test-HealthChanged $null $null '已停止' '') '首次观测应算变化'
  Assert (-not (Test-HealthChanged '已停止' '' '已停止' '')) '值没变不该记'
  Assert (Test-HealthChanged '已停止' '' '运行中' '') '状态变化应记'
  Assert (Test-HealthChanged '运行中' '正常' '运行中' '超时') '健康变化应记'
  Assert (-not (Test-HealthChanged '运行中' '' '运行中' '')) '空健康前后一致不该记'

  # ---- 2. 落盘：按天分文件、UTF-8 无 BOM、一行一个 JSON ----
  $null = Add-HealthEvent $dir (New-HealthEvent 'SvcA' '已停止' '')
  Start-Sleep -Milliseconds 5
  $null = Add-HealthEvent $dir (New-HealthEvent 'SvcA' '运行中' '正常')
  Start-Sleep -Milliseconds 5
  $null = Add-HealthEvent $dir (New-HealthEvent 'SvcA' '运行中' '超时')
  $null = Add-HealthEvent $dir (New-HealthEvent 'SvcB' '运行中' '正常')
  $file = Get-HealthFile $dir
  Assert (Test-Path -LiteralPath $file) "应按天落到 health-YYYYMMDD.ndjson，实际目录：$((Get-ChildItem $dir).Name -join ',')"
  $bytes = [IO.File]::ReadAllBytes($file)
  Assert ($bytes.Length -gt 0 -and -not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) '文件不该带 BOM'
  Assert ((@([IO.File]::ReadAllLines($file)).Count) -eq 4) '四次追加应有四行'

  # ---- 3. 读取：按名过滤、最新在前、Limit 生效 ----
  $a = @(Get-HealthEvents $dir 'SvcA' 10 7)
  Assert ($a.Count -eq 3) "SvcA 应有 3 条，got $($a.Count)"
  Assert ($a[0].h -eq '超时' -and $a[-1].h -eq '') "应最新在前，got [$($a[0].h) .. $($a[-1].h)]"
  Assert ($a[0].n -eq 'SvcA') '过滤应按服务名'
  $two = @(Get-HealthEvents $dir 'SvcA' 2 7)
  Assert ($two.Count -eq 2 -and $two[0].h -eq '超时') 'Limit 应只取最新的两条'
  Assert (@(Get-HealthEvents $dir 'SvcB' 10 7).Count -eq 1) 'SvcB 应只有 1 条'
  Assert (@(Get-HealthEvents $dir '' 10 7).Count -eq 4) '不给名字应返回全部'

  # ---- 4. 坏行跳过，不影响其余记录 ----
  [IO.File]::AppendAllText($file, "{not json`n", [Text.UTF8Encoding]::new($false))
  Assert (@(Get-HealthEvents $dir 'SvcA' 10 7).Count -eq 3) '坏行应被跳过而不是整份失败'

  # ---- 5. 按天清理：只删超期文件，非标准文件名不碰 ----
  $old = Join-Path $dir 'health-20200101.ndjson'
  [IO.File]::WriteAllText($old, "{`"ts`":`"2020-01-01T00:00:00+08:00`",`"n`":`"SvcA`",`"st`":`"已停止`",`"h`":`"`"}`n", [Text.UTF8Encoding]::new($false))
  $keep = Join-Path $dir 'notes.txt'
  [IO.File]::WriteAllText($keep, 'x', [Text.UTF8Encoding]::new($false))
  $removed = @(Remove-OldHealthFiles $dir 30)
  Assert ($removed -contains 'health-20200101.ndjson') '超期文件应被删除'
  Assert (-not (Test-Path -LiteralPath $old)) '超期文件应真的消失'
  Assert (Test-Path -LiteralPath $file) '当天文件不该删'
  Assert (Test-Path -LiteralPath $keep) '非标准文件名不该碰'
  Assert (@(Remove-OldHealthFiles $dir 0).Count -eq 0) 'KeepDays<1 时应 no-op'

  # ---- 6. UI 入队 → 后台 runspace 落盘（UI 线程不碰 I/O 的那一半）----
  . (Join-Path $RepoRoot 'lib/poll.ps1')
  . (Join-Path $RepoRoot 'tests/test-helpers.ps1')
  $q = [Collections.Concurrent.ConcurrentQueue[object]]::new()
  $bgDir = Join-Path $dir 'bg'
  $worker = Start-FakePoll 1 'Running' 0 @{ healthQ = $q; healthDir = $bgDir; probeIntervalMs = 300; probeIdleMs = 300 }
  try {
    Assert ($worker.Sync.probeStarted.WaitOne(3000)) '后台 worker 未启动'
    $q.Enqueue((New-HealthEvent 'Fake0' '运行中' '正常'))
    $deadline = [datetime]::Now.AddSeconds(6)
    while (-not (Test-Path -LiteralPath (Get-HealthFile $bgDir)) -and [datetime]::Now -lt $deadline) {
      Start-Sleep -Milliseconds 100
    }
    $bgFile = Get-HealthFile $bgDir
    Assert (Test-Path -LiteralPath $bgFile) '后台应把队列里的事件写进 health 文件'
    Assert ((Get-Content -LiteralPath $bgFile -Raw -Encoding UTF8) -match 'Fake0') '落盘内容应包含事件'
  } finally { Close-FakePoll $worker }
} finally {
  Remove-Item -LiteralPath $dir -Recurse -Force -EA SilentlyContinue
} #guard-ok

Write-Output 'PASS: 健康历史只在变化时落一条、按天分文件、最新在前、坏行跳过、按天清理；后台 runspace 消费队列落盘。'
