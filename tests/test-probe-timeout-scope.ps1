#requires -Version 7.0
# 回归：并行探测块里的超时变量必须经 $using: 传入，否则在子 runspace 里取到 $null。
#
# 背景：ForEach-Object -Parallel 开新 runspace，不继承父作用域变量。poll.ps1 的
# 并行块里 $httpClient=$using:http 是对的，但 $tcpMs 曾裸用——子 runspace 里是 $null，
# WaitOne($null,$false) 等价 WaitOne(0)，TCP 握手没完成就返回 False，运行中服务被
# 判「无响应」（红点）。启停服务时后台更忙，0ms 扑空概率上升，于是「启停一个服务，
# 别的运行中服务变红」。
#
# 本测试两路：静态扫裸引用（确定性）+ 真监听端口端到端（行为）。
# 注意 test-parallel-probe.ps1 探的是未监听端口，0ms 与 200ms 结果都是「无响应」，
# 对这类 bug 天然免疫——所以必须单开一份探真端口的测试。
#
# 行为段的判定：真监听端口（接受连接但不应答 HTTP）——
#   修好后 → TCP 探测成功 → 转 HTTP → 超时 → h='超时'
#   带 bug → TCP 探测 WaitOne(0) 失败 → 直接 h='无响应'
# 所以断言「真监听端口的 h 从不为『无响应』」即可区分；未监听端口仍应为『无响应』
# （作为夹具自检，确认探测本身在跑）。
param([string]$RepoRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $RepoRoot 'lib/poll.ps1')
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }

# ---- 1. 静态：并行块内不得裸用 $tcpMs / $httpMs / $waitMs ----
# 从 "ForEach-Object -Parallel {" 到 "-ThrottleLimit" 之间即并行块体。
# 先剥掉注释——注释里提到 $tcpMs 不该算命中（本文件的说明文字就写了它）。
$rawBlock = [regex]::Match($script:poll, '(?s)ForEach-Object\s+-Parallel\s*\{(.*?)\}\s*-ThrottleLimit').Groups[1].Value
Assert ($rawBlock.Length -gt 0) 'Could not locate the ForEach-Object -Parallel block in poll.ps1.'
$block = ($rawBlock -split "`n" | ForEach-Object { $_ -replace '#.*$','' }) -join "`n"
foreach ($v in 'tcpMs','httpMs','waitMs') {
  # 裸引用 = 前面不是 $using: 也不是 $script: 的 $v。
  # 正则用单引号拼接，避免 PowerShell 把 "$using:" 当变量解析。
  $bare  = [regex]::Matches($block, '(?<![\w:])\$' + $v + '\b')
  $using = [regex]::Matches($block, '\$using:' + $v + '\b')
  Assert ($bare.Count -eq 0) "Parallel block references `$$v bare ($($bare.Count)x); must use `$using:$v (new runspace does not inherit parent scope)."
  if ($v -eq 'tcpMs') { Assert ($using.Count -ge 1) "Parallel block does not pass `$using:$v at all." }
}
Write-Output 'PASS: parallel block has no bare timeout-variable references.'

# ---- 2. 行为：真监听端口 + 真实 poll 脚本块 ----
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$held = [System.Collections.Generic.List[System.Net.Sockets.TcpClient]]::new()

# 主线程接受并按住连接，避免 backlog 堆积；不断开（断开会让 HTTP 报 connection 类错）。
function Invoke-AcceptTick {
  try {
    while ($listener.Pending()) { $held.Add($listener.AcceptTcpClient()) }
  } catch {}
}

# 3 个真监听 + 3 个未监听；httpTimeoutMs=500 让每轮 HTTP 超时只花 0.5s
$svc = [ordered]@{}
for ($i=0; $i -lt 3; $i++) { $svc["Live$i"] = @{ port=$port; url="http://127.0.0.1:$port/" } }
for ($i=0; $i -lt 3; $i++) { $svc["Dead$i"] = @{ port=(59900+$i); url="http://127.0.0.1:$(59900+$i)/" } }

$shared = [hashtable]::Synchronized(@{
  svc = $svc
  gate = [object]::new(); stop = $false
  queue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
  cmd   = [Collections.Concurrent.ConcurrentQueue[object]]::new()
  msg   = [Collections.Concurrent.ConcurrentQueue[string]]::new()
  wake  = [Threading.AutoResetEvent]::new($false)
  nssm  = 'Invoke-TestNssm'
  httpTimeoutMs = 500
})
$rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState='STA'; $rs.Open()
$rs.SessionStateProxy.SetVariable('sync', $shared)
$mocks = @"
function Get-Service {
  [CmdletBinding()]param([string[]]`$Name)
  foreach (`$n in `$Name) { [pscustomobject]@{ Name=`$n; Status='Running' } }
}
"@
$ps = [powershell]::Create().AddScript($mocks).AddScript($script:poll)
$ps.Runspace = $rs
$handle = $ps.BeginInvoke()

try {
  # 收集真监听端口的探测结果，h 从不为「无响应」；未监听端口应报「无响应」（夹具自检）。
  # Live/Dead 同轮收——主循环里只留 Live 会把 Dead 挤没，自检就永远过不去。
  $want = 12; $seen = 0; $bad = 0; $deadSeen = 0; $deadBad = 0; $lastHealth = ''
  $deadline = [datetime]::UtcNow.AddSeconds(40)
  while (($seen -lt $want -or $deadSeen -lt 1) -and [datetime]::UtcNow -lt $deadline) {
    Invoke-AcceptTick
    [void]$shared.wake.Set()
    $item = $null
    while ($shared.queue.TryDequeue([ref]$item)) {
      if ($item.done) { continue }
      if ($item.n.StartsWith('Live')) {
        $lastHealth = [string]$item.h
        if ($item.h -eq '无响应') { $bad++ }
        $seen++
      } else {
        $deadSeen++
        if ($item.h -ne '无响应') { $deadBad++ }
      }
      if ($seen -ge $want -and $deadSeen -ge 3) { break }
    }
    Start-Sleep -Milliseconds 50
  }
  Assert ($seen -ge $want) "Live-port results only $seen/$want in 40s; poll loop stalled."
  Assert ($bad -eq 0) "Listening loopback port judged '无响应' $bad/$seen time(s) (last h='$lastHealth'). TCP timeout not applied — check `$using:tcpMs."
  Assert ($deadSeen -ge 3) "No results for unlistened ports; probe path did not exercise them."
  Assert ($deadBad -eq 0) "Unlistened port should be '无响应', got otherwise ($deadBad/$deadSeen)."
} finally {
  # 收尾不用 PowerShell.Stop()——它对正在 ForEach-Object -Parallel 的 runspace 会阻塞。
  # 置 stop + 唤醒，让 poll 自己退出循环，再等句柄。
  $shared.stop = $true; [void]$shared.wake.Set()
  try { if ($handle.AsyncWaitHandle.WaitOne(3000)) { $ps.EndInvoke($handle) } } catch {}
  # 错误流快照必须放在这里，不能放 try 里：$ps.Streams.Error 是 PSDataCollection，
  # 管道未结束时枚举会一直阻塞（实测 -join 在 2.5s 内不返回，而 .Count 4ms 就返回）。
  # 在 try 里写 "$($ps.Streams.Error -join '; ')" 会把测试挂死——卡的是那句枚举，不是探测。
  $errSnapshot = @($ps.Streams.Error)
  $rs.Close(); $rs.Dispose(); $ps.Dispose(); $shared.wake.Dispose()
  foreach ($c in $held) { try { $c.Close() } catch {} }
  $listener.Stop()
}

Assert ($errSnapshot.Count -eq 0) "Background errors present: $($errSnapshot -join '; ')"
Write-Output "PASS: listening port never '无响应' ($seen/$seen), unlistened port '无响应' ($deadSeen/$deadSeen)."
Write-Output 'PASS: probe timeout variables reach the parallel runspace; listening services stay green.'
