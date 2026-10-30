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

  # ---- 3b. 尾部读的边界：空文件 / 末行无换行 / CRLF / 块边界多字节 ----
  $edge = Join-Path $dir 'edge'
  New-Item -ItemType Directory -Force $edge | Out-Null
  $u8 = [Text.UTF8Encoding]::new($false)
  $ef = Join-Path $edge 'health-20260103.ndjson'
  [IO.File]::WriteAllText($ef, '', $u8)
  Assert (@(Read-HealthTailLines $ef 5).Count -eq 0) '空文件应返回 0 行'
  [IO.File]::WriteAllText($ef, ('{"n":"SvcEdge","st":"运行中","h":"a"}' + "`r`n" + '{"n":"SvcEdge","st":"运行中","h":"b"}'), $u8)
  $tail = @(Read-HealthTailLines $ef 5)
  Assert ($tail.Count -eq 2 -and $tail[0] -like '*"h":"b"*' -and $tail[0] -notmatch "`r") '末行无换行要取全，CRLF 不得进内容'
  # 多字节字符横跨 64 KiB 块边界：行边界切分才不会被截成半个字符
  [IO.File]::WriteAllText($ef, ('x' * 65536) + "`n" + '中文行' + "`n", $u8)
  $tail = @(Read-HealthTailLines $ef 5)
  Assert ($tail.Count -eq 2 -and $tail[0] -eq '中文行') "块边界不该切坏多字节字符，got [$($tail[0])]"

  # ---- 3c. 跨天：新文件不够就续读旧文件，顺序仍是全局最新在前 ----
  $cd = Join-Path $dir 'crossday'
  New-Item -ItemType Directory -Force $cd | Out-Null
  [IO.File]::WriteAllText((Join-Path $cd 'health-20260101.ndjson'),
    ('{"n":"S","st":"运行中","h":"old1"}' + "`n" + '{"n":"S","st":"运行中","h":"old2"}' + "`n"), $u8)
  [IO.File]::WriteAllText((Join-Path $cd 'health-20260102.ndjson'),
    ('{"n":"S","st":"运行中","h":"new1"}' + "`n" + '{"n":"S","st":"运行中","h":"new2"}'), $u8)
  $ev = @(Get-HealthEvents $cd 'S' 4 7)
  Assert ($ev.Count -eq 4 -and ($ev.h -join ',') -eq 'new2,new1,old2,old1') "跨天应全局最新在前，got [$($ev.h -join ',')]"
  Assert (@(Get-HealthEvents $cd 'S' 4 1).Count -eq 2) 'Days=1 只应看最新文件'

  # ---- 4. 坏行跳过，不影响其余记录 ----
  [IO.File]::AppendAllText($file, "{not json`n", [Text.UTF8Encoding]::new($false))
  Assert (@(Get-HealthEvents $dir 'SvcA' 10 7).Count -eq 3) '坏行应被跳过而不是整份失败'

  # ---- 4b. 大文件只读尾部：20MB 当日文件不该整份读 + 逐行解析 ----
  # 旧实现 ReadAllLines 整份读，再对每一行 ConvertFrom-Json；按天增长后点一次「健康历史」就卡 UI。
  $bigDir = Join-Path $dir 'big'
  New-Item -ItemType Directory -Force $bigDir | Out-Null
  $bigFile = Get-HealthFile $bigDir
  $sb = [Text.StringBuilder]::new()
  $filler = '{"ts":"2026-01-01T00:00:00+08:00","n":"Other","st":"运行中","h":"正常"}'
  for ($i = 0; $i -lt 300000; $i++) { [void]$sb.AppendLine($filler) }   # ≈20MB
  for ($i = 0; $i -lt 200; $i++) { [void]$sb.AppendLine('{"ts":"2026-01-01T00:00:00+08:00","n":"SvcBig","st":"运行中","h":"marker' + $i + '"}') }
  [IO.File]::WriteAllText($bigFile, $sb.ToString(), [Text.UTF8Encoding]::new($false))
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $big = @(Get-HealthEvents $bigDir 'SvcBig' 200 1)
  $sw.Stop()
  Assert ($big.Count -eq 200) "大文件应仍返回最新 200 条，got $($big.Count)"
  Assert ($big[0].h -eq 'marker199' -and $big[-1].h -eq 'marker0') "大文件应最新在前，got [$($big[0].h) .. $($big[-1].h)]"
  Assert ($sw.ElapsedMilliseconds -lt 500) "只读尾部应 < 500ms，实际 $($sw.ElapsedMilliseconds)ms"

  # ---- 4c. 稀疏服务 + 大文件：整块预筛（不命中不逐行解析），不能退化回全文件 JSON 解析 ----
  $sparseFile = Join-Path $bigDir 'health-20260105.ndjson'
  $sb2 = [Text.StringBuilder]::new()
  [void]$sb2.AppendLine('{"ts":"2026-01-05T00:00:00+08:00","n":"SvcSparse","st":"运行中","h":"only-one"}')
  for ($i = 0; $i -lt 60000; $i++) { [void]$sb2.AppendLine($filler) }    # ≈4.5MB，目标行在文件头
  [IO.File]::WriteAllText($sparseFile, $sb2.ToString(), [Text.UTF8Encoding]::new($false))
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $sparse = @(Get-HealthEvents $bigDir 'SvcSparse' 200 2)
  $sw.Stop()
  Assert ($sparse.Count -eq 1 -and $sparse[0].h -eq 'only-one') "稀疏服务应仍能找到，got $($sparse.Count)"
  Assert ($sw.ElapsedMilliseconds -lt 500) "稀疏服务扫 4.5MB 应 < 500ms（整块预筛），实际 $($sw.ElapsedMilliseconds)ms"

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

Write-Output 'PASS: 健康历史只在变化时落一条、按天分文件、最新在前、坏行跳过、按天清理；大文件只读尾部（空文件/末行无换行/CRLF/64KB 边界多字节/跨天续读/稀疏服务整块预筛）；后台 runspace 消费队列落盘。'
