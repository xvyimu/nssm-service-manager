#requires -Version 7.0
# 批量启停：目标按「最近一次探测值」($script:svcState) 筛——翻页外没有卡片的服务也要能全启/全停；
# 只处理终态（已停止/运行中）；停止必须过一次二次确认。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
foreach ($module in 'theme','util','card','xaml') { . (Join-Path $RepoRoot "lib/$module.ps1") }
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }

$script:svc = [ordered]@{
  A = @{ port = 1; url = '' }; B = @{ port = 2; url = '' }
  C = @{ port = 3; url = '' }; D = @{ port = 4; url = '' }
}
$script:sync = @{ gate = [object]::new(); svc = $script:svc; stop = $true; wake = [Threading.AutoResetEvent]::new($false) }
$script:cmdQueue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:cmdEpoch = 0
$script:svcState = @{}
$script:healthSeen = @{}
$script:cards = @{}
$script:curPage = 0
$script:batchConfirm = $true
function Confirm-BatchStop($owner, [int]$count) { $script:batchConfirm }
function Stop-Background {}
function Drain-Queue { $out = @(); $c = $null; while ($script:cmdQueue.TryDequeue([ref]$c)) { $out += $c }; $out }

$win = New-MainWindow
try {
  Render-Page
  # 模拟「只翻到过第一页」：B/C/D 有配置但没有卡片
  $cardA = $script:cards['A']
  foreach ($n in 'B', 'C', 'D') { $script:cards.Remove($n) }
  Assert ($null -ne $cardA -and -not $script:cards.ContainsKey('B')) '夹具应只剩 A 的卡片'

  # A 已停止、B 运行中、C 启动中（非终态）、D 已停止（无卡片）
  $script:svcState = @{
    A = @{ st = '已停止'; h = '' }; B = @{ st = '运行中'; h = '正常' }
    C = @{ st = '启动中'; h = '' }; D = @{ st = '已停止'; h = '' }
  }

  # ---- 1. 全部启动：只挑已停止（A 有卡、D 无卡），逐个入队并置过渡态 ----
  $msg = Invoke-BatchCommand 'start'
  $cmd = @(Drain-Queue)
  Assert ($cmd.Count -eq 2) "应下发 2 个启动命令，got $($cmd.Count)：$msg"
  Assert (@($cmd | Where-Object { $_.act -eq 'start' }).Count -eq 2) '命令动作应为 start'
  Assert (@($cmd | Where-Object { $_.n -eq 'D' }).Count -eq 1) '翻页外（无卡片）的服务也该被下发'
  Assert (@($cmd | Where-Object { $_.n -eq 'C' }).Count -eq 0) '启动中的服务不该被批量碰'
  Assert ($cardA.ST -eq '启动中' -and -not $cardA.Btn.IsEnabled) '有卡片的服务应进入过渡态'
  Assert ($cardA.PendingEpoch -eq $cmd[0].e) '过渡态应绑定下发的 epoch'
  Assert ($msg -match '2') "状态栏文案应含数量，got [$msg]"

  # ---- 2. 全部停止：取消则一条都不发 ----
  $script:batchConfirm = $false
  $msg = Invoke-BatchCommand 'stop'
  Assert ($msg -eq '已取消') "取消应返回「已取消」，got [$msg]"
  Assert (@(Drain-Queue).Count -eq 0) '取消后不该有任何命令入队'

  # ---- 3. 全部停止：确认后只挑运行中 ----
  $script:batchConfirm = $true
  $msg = Invoke-BatchCommand 'stop'
  $cmd = @(Drain-Queue)
  Assert ($cmd.Count -eq 1 -and $cmd[0].n -eq 'B' -and $cmd[0].act -eq 'stop') "应只停 B，got $($cmd | ForEach-Object { $_.n })"
  Assert ($msg -match '1') "状态栏文案应含数量，got [$msg]"

  # ---- 4. 没有可处理的目标：给一句话，不发命令 ----
  $script:svcState = @{ A = @{ st = '启动中'; h = '' }; B = @{ st = '已暂停'; h = '' } }
  $msg = Invoke-BatchCommand 'start'
  Assert ($msg -match '没有可启动') "非终态时应说明没有目标，got [$msg]"
  Assert (@(Drain-Queue).Count -eq 0) '没有目标时不该入队'

  # ---- 5. 状态过期：探测落库太久（后台 runspace 死掉/探测被限流）时不按旧值下发 ----
  # 朝「其实已经停了」的服务再发 stop，只会刷一串 1056/1062。
  $script:svcState = @{
    A = @{ st = '已停止'; h = ''; at = (Get-Date).AddSeconds(-30) }   # 30s 前：过期
    B = @{ st = '已停止'; h = ''; at = (Get-Date) }                   # 刚探测：新鲜
  }
  $msg = Invoke-BatchCommand 'start'
  $cmd = @(Drain-Queue)
  Assert ($cmd.Count -eq 1 -and $cmd[0].n -eq 'B') "过期状态应跳过 A，只下发 B，got $($cmd | ForEach-Object { $_.n })"
  Assert ($msg -match '过期') "状态栏文案应说明「N 个状态过期已跳过」，got [$msg]"

  # ---- 6. 边界：略早于阈值算新鲜、未来时间（时钟回拨）放行、at 为 ISO 字符串也认 ----
  $interval = [int]$script:config.ProbeIntervalMs
  $script:svcState = @{
    A = @{ st = '已停止'; h = ''; at = (Get-Date).AddMilliseconds(-($interval * 2 - 1000)) }
    B = @{ st = '已停止'; h = ''; at = (Get-Date).AddMinutes(5) }
  }
  $msg = Invoke-BatchCommand 'start'
  Assert (@(Drain-Queue).Count -eq 2) "略早于阈值与未来时间都该放行，got [$msg]"
  Assert ($msg -notmatch '过期') "没有过期条目时不该提「过期」，got [$msg]"
  $script:svcState = @{ A = @{ st = '已停止'; h = ''; at = (Get-Date).AddMinutes(-10).ToString('o') } }
  $msg = Invoke-BatchCommand 'start'
  Assert (@(Drain-Queue).Count -eq 0 -and $msg -match '过期') "ISO 字符串形式的 at 也要能判过期，got [$msg]"
} finally {
  try { $win.Close() } catch {}
}

Write-Output 'PASS: 批量启停按最近探测值筛目标（含翻页外）、只碰终态、停止需确认、无目标不误发、过期状态跳过并说明（含阈值内/未来时间/ISO at 边界）。'
