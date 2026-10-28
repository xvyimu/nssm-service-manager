#requires -Version 7.0
# 阶段 2 回归：重服务（AI 服务冷启动一分钟起）不该被全局 45s/3s 硬套。
# 四件事各守一条：
#   1) services.json 的 per-service 超时字段必须被 Read-SvcFile 带走
#      —— 原实现只挑 port/url，写进去的覆盖会在下一次 GUI 保存时被静默抹掉；
#   2) 卡片过渡态阈值优先取 per-service 值，缺省回落全局；
#   3) 探测报「还在同一个过渡态」（StartPending/StopPending）时刷新过渡计时
#      —— 否则慢启动会在第 45 秒被当成「回执丢了」，卡片显示「未知」；
#   4) 探测超时按服务给（共享 HttpClient 的 Timeout 是实例级上限，改不动单次请求，
#      故改成每请求 CancellationTokenSource）。
param([string]$RepoRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
foreach ($module in 'theme','util','card','xaml') { . (Join-Path $RepoRoot "lib/$module.ps1") }
. (Join-Path $RepoRoot 'lib/poll.ps1')
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }

# ---- 1. Read-SvcFile 保留 per-service 字段 ----
$tmp = Join-Path ([IO.Path]::GetTempPath()) "sm-per-svc-$([guid]::NewGuid().ToString('N')).json"
$json = @'
{
  "SlowAI": { "port": 8188, "url": "http://127.0.0.1:8188", "toggleTimeoutMs": 180000, "httpTimeoutMs": 12000, "tcpTimeoutMs": 800 },
  "Quick":  { "port": 8081, "url": "http://127.0.0.1:8081" }
}
'@
[IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
try {
  $parsed = Read-SvcFile $tmp
  Assert ($parsed['SlowAI'].toggleTimeoutMs -eq 180000) 'toggleTimeoutMs 未被 Read-SvcFile 保留（保存后会被抹掉）'
  Assert ($parsed['SlowAI'].httpTimeoutMs -eq 12000) 'httpTimeoutMs 未被保留'
  Assert ($parsed['SlowAI'].tcpTimeoutMs -eq 800) 'tcpTimeoutMs 未被保留'
  Assert (-not $parsed['Quick'].ContainsKey('toggleTimeoutMs')) '未配置的服务不该凭空多出字段'
  Assert ($parsed['Quick'].port -eq 8081 -and $parsed['Quick'].url -eq 'http://127.0.0.1:8081') 'port/url 解析被破坏'

  # 读 → 整份写回 → 再读：这是「配了没生效」真正会发生的路径（Save-Svc 写的是整份对象）
  $cfg = $tmp
  $roundTrip = Read-SvcFile $tmp
  Save-Svc $roundTrip
  $again = Read-SvcFile $tmp
  Assert ($again['SlowAI'].toggleTimeoutMs -eq 180000) 'round-trip 后 toggleTimeoutMs 丢了'
  Assert ($again['SlowAI'].httpTimeoutMs -eq 12000) 'round-trip 后 httpTimeoutMs 丢了'
  Assert ($again['SlowAI'].tcpTimeoutMs -eq 800) 'round-trip 后 tcpTimeoutMs 丢了'

  # 写错的值（0 / 负数 / 非数字）：只让**该字段**不生效，服务条目必须保留。
  # 早先这里是 throw —— Load-Svc 落到 catch 后整份清单退回 services.example.json，
  # GUI 里显示成示例服务，用户点一次增删就把示例写回真实文件，真实清单全丢。
  foreach ($bad in 0, -1, 'abc') {
    $raw = if ($bad -is [string]) { "`"$bad`"" } else { "$bad" }
    [IO.File]::WriteAllText($tmp, "{ `"S`": { `"port`": 1, `"url`": `"u`", `"toggleTimeoutMs`": $raw } }", [Text.UTF8Encoding]::new($false))
    $one = Read-SvcFile $tmp
    Assert ($one.Contains('S')) "toggleTimeoutMs=$bad 时服务条目不该消失"
    Assert (-not $one['S'].ContainsKey('toggleTimeoutMs')) "toggleTimeoutMs=$bad 不该生效"
    Assert ($script:svcFieldWarnings.Count -eq 1) "toggleTimeoutMs=$bad 应记一条提示，got $($script:svcFieldWarnings.Count)"
    Assert ($script:svcFieldWarnings[0] -match 'toggleTimeoutMs') "提示应点名字段，got $($script:svcFieldWarnings[0])"
  }
} finally { Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue }

# ---- 1b. 一个坏字段不得让整份清单退回示例（这是会丢数据的路径）----
$dir = Join-Path ([IO.Path]::GetTempPath()) "sm-loadsvc-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
try {
  $cfg = Join-Path $dir 'services.json'
  [IO.File]::WriteAllText($cfg, @'
{
  "MyRealAPI": { "port": 3000, "url": "http://127.0.0.1:3000" },
  "MyRealDB":  { "port": 5432, "url": "http://127.0.0.1:5432" },
  "SlowAI":    { "port": 8188, "url": "http://127.0.0.1:8188", "toggleTimeoutMs": 0, "httpTimeoutMs": "abc" }
}
'@, [Text.UTF8Encoding]::new($false))
  # 仓里的示例清单就放在旁边——Load-Svc 的兜底来源。退回它就意味着用户下一次保存会写丢真实清单。
  Copy-Item (Join-Path $RepoRoot 'services.example.json') (Join-Path $dir 'services.example.json')
  $script:configWarning = $null
  # 置 $null 而不是 @()：生产里这个变量**从未初始化**，正是 $null 才暴露
  # `$null += "x"` 得到 String 的坑。夹具给「已经干净的数组」会把缺陷遮住。
  $script:configNotices = $null
  $svcList = Load-Svc
  Assert ($svcList.Contains('MyRealAPI') -and $svcList.Contains('MyRealDB')) "真实服务被示例清单顶掉了：$((@($svcList.Keys)) -join ', ')"
  Assert (-not $svcList.Contains('MyAPI')) '不该出现示例清单里的服务名'
  Assert (-not $script:configWarning) "这种情形不该报「使用恢复配置」：$($script:configWarning)"
  # 两条提示必须各自成项：`$null += "x"` 得到的是 String 而不是数组，会粘成一行
  Assert ($script:configNotices -is [array]) "configNotices 应是数组，got $($script:configNotices.GetType().Name)"
  Assert ($script:configNotices.Count -eq 2) "两个坏字段应给两条提示，got $($script:configNotices.Count)：$($script:configNotices -join ' | ')"
  Assert ($script:configNotices[0] -match 'toggleTimeoutMs' -and $script:configNotices[1] -match 'httpTimeoutMs') "提示应逐条点名字段，got $($script:configNotices -join ' | ')"
} finally { Remove-Item -LiteralPath $dir -Recurse -Force -EA SilentlyContinue }
Write-Output 'PASS: per-service overrides survive read/save round-trip; a bad override is dropped (with a notice) instead of falling back to the example list.'

# ---- 2/3. 卡片阈值与 StartPending 刷新 ----
$script:sync = @{ wake = [Threading.AutoResetEvent]::new($false) }
$script:cmdQueue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
function Stop-Background {}
$script:svc = [ordered]@{
  SlowAI = @{ port=8188; url='http://127.0.0.1:8188'; toggleTimeoutMs=180000 }
  Quick  = @{ port=8081; url='http://127.0.0.1:8081' }
}
$win = New-MainWindow
try {
  Render-Page
  $slow = $script:cards['SlowAI']; $quick = $script:cards['Quick']
  Assert ($slow.ToggleTimeoutMs -eq 180000) "per-service 阈值未挂到卡片：$($slow.ToggleTimeoutMs)"
  Assert ($quick.ToggleTimeoutMs -eq [int]$script:config.ToggleTimeoutMs) "未配置的服务应回落全局：$($quick.ToggleTimeoutMs)"

  # 同一时刻（60s 前点的按钮）：全局 45s 已超时，per-service 180s 不该超时
  $now = [datetime]::Now
  $slow.ST='启动中';  $slow.TransitionAt=$now.AddSeconds(-60)
  $quick.ST='启动中'; $quick.TransitionAt=$now.AddSeconds(-60)
  Assert (-not (Test-TransitionTimedOut $slow $now)) 'SlowAI 60s 时不该判超时（阈值 180s）'
  Assert (Test-TransitionTimedOut $quick $now) 'Quick 60s 时应判超时（阈值 45s）'

  # 探测报同一个过渡态 → 刷新计时，不判超时也不改状态
  $quick.LastToggle = [datetime]::MinValue
  $quick.ST = '已停止'; $quick.TransitionAt = [datetime]::MinValue
  Update-CardData 'Quick' '已停止' ''
  Invoke-CardToggle $quick
  Assert ($quick.ST -eq '启动中') "未进入启动过渡态：$($quick.ST)"
  $quick.TransitionAt = [datetime]::Now.AddSeconds(-44)
  Update-CardData 'Quick' '启动中' ''     # 探测到 StartPending
  Assert ($quick.ST -eq '启动中') "探测报同一过渡态不该改状态：$($quick.ST)"
  $ageSec = ([datetime]::Now - $quick.TransitionAt).TotalSeconds
  Assert ($ageSec -lt 5) "StartPending 应刷新过渡计时（44s 的旧起算点没被重置，age=$([int]$ageSec)s）"

  # 刷新不是无限续命：累计时长超过 10 倍阈值后仍判超时——服务真卡在中间态时逃生口不能失效
  $quick.ST = '启动中'
  $quick.TransitionAt = [datetime]::Now.AddSeconds(-1)             # 刚被探测刷新过
  $quick.TransitionStartedAt = [datetime]::Now.AddSeconds(-100)    # 累计 100s < 45s×10
  Assert (-not (Test-TransitionTimedOut $quick ([datetime]::Now))) '累计 100s 且刚刷新过，不该判超时'
  $quick.TransitionStartedAt = [datetime]::Now.AddSeconds(-500)    # 超过 45s×10=450s
  Assert (Test-TransitionTimedOut $quick ([datetime]::Now)) '累计超过 10 倍阈值应强制判超时，否则刷新会把逃生口顶掉'

  # 刷新不是永久豁免：真超时后仍按到达值收敛、解封按钮
  $quick.TransitionAt = [datetime]::Now.AddSeconds(-60)
  Update-CardData 'Quick' '已停止' ''
  Assert ($quick.ST -eq '已停止') "超时后仍应按到达的探测值收敛：$($quick.ST)"
  Assert ($quick.Btn.IsEnabled) '超时收敛后按钮应恢复可用'
  Write-Output 'PASS: per-service toggle timeout applied; StartPending refreshes the clock; hard timeout still escapes.'
} finally { $win.Close(); $script:sync.wake.Dispose() }

# ---- 4. 探测超时按服务给 ----
# 夹具：接受连接但不应答 HTTP 的端口。全局 httpTimeoutMs=6000，两份服务各自 200。
# per-service 生效 → 本轮 ~200ms 出结果；被忽略 → 要 6s。断言 3s 内出结果，留 3 倍余量。
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$held = [System.Collections.Generic.List[System.Net.Sockets.TcpClient]]::new()
function Invoke-AcceptTick {
  try { while ($listener.Pending()) { $held.Add($listener.AcceptTcpClient()) } } catch {}
}
$probeSvc = [ordered]@{
  HangA = @{ port=$port; url="http://127.0.0.1:$port/"; httpTimeoutMs=200 }
  HangB = @{ port=$port; url="http://127.0.0.1:$port/"; httpTimeoutMs=200 }
}
$shared = [hashtable]::Synchronized(@{
  svc = $probeSvc; gate = [object]::new(); stop = $false
  queue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
  cmd   = [Collections.Concurrent.ConcurrentQueue[object]]::new()
  msg   = [Collections.Concurrent.ConcurrentQueue[string]]::new()
  wake  = [Threading.AutoResetEvent]::new($false)
  nssm  = 'Invoke-TestNssm'
  httpTimeoutMs = 6000
  tcpTimeoutMs  = 1000
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
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $seen = 0
  # 8s > 全局 6000ms：per-service 被忽略时让「测出 6000ms」这条断言先报，而不是超时先说「没结果」
  $deadline = [datetime]::UtcNow.AddSeconds(8)
  while ($seen -lt 2 -and [datetime]::UtcNow -lt $deadline) {
    Invoke-AcceptTick
    $item = $null
    while ($shared.queue.TryDequeue([ref]$item)) {
      if ($item.done) { continue }
      $seen++
    }
    Start-Sleep -Milliseconds 20
  }
  $sw.Stop()
  Assert ($seen -ge 2) "探测未返回结果（$seen/2），已等 $([int]$sw.ElapsedMilliseconds)ms"
  Assert ($sw.ElapsedMilliseconds -lt 3000) "per-service httpTimeoutMs 未生效：本轮 $([int]$sw.ElapsedMilliseconds)ms（全局 6000ms 说明走的是全局值）"
  Write-Output "PASS: per-service httpTimeoutMs applied ($([int]$sw.ElapsedMilliseconds)ms < 3000ms; global would be 6000ms)."
} finally {
  $shared.stop = $true; [void]$shared.wake.Set()
  try { if ($handle.AsyncWaitHandle.WaitOne(3000)) { $ps.EndInvoke($handle) } } catch {}
  $errs = @($ps.Streams.Error)
  $rs.Close(); $rs.Dispose(); $ps.Dispose(); $shared.wake.Dispose()
  foreach ($c in $held) { try { $c.Close() } catch {} }
  $listener.Stop()
  Assert ($errs.Count -eq 0) "后台探测有错误：$($errs -join '; ')"
}
