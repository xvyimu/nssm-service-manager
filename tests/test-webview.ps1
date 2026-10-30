#requires -Version 7.0
# 只读 Web 视图：token 校验、快照形状、HTML 渲染与转义，以及「真起一个 loopback 服务器」的端到端。
# 安全前提：只听 127.0.0.1、只接受 GET、必须带 token；写操作一概不提供。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'lib/webview.ps1')
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }

# ---- 1. token：正确/错误/空/长度不同都判对 ----
$tok = 'a1b2c3d4e5f60718'
Assert (Test-WebToken $tok $tok) '相同 token 应通过'
Assert (-not (Test-WebToken ($tok + 'x') $tok)) '长度不同应拒'
Assert (-not (Test-WebToken 'a1b2c3d4e5f60719' $tok)) '差一位应拒'
Assert (-not (Test-WebToken '' $tok)) '空 token 应拒'
Assert (-not (Test-WebToken $tok '')) '未配置 token 时应拒'

# ---- 2. 快照：读 $sync.svc / $sync.svcState，缺探测值时留空而不是崩 ----
$svc = [ordered]@{ A = @{ port = 3000; url = '' }; B = @{ port = 5432; url = '' } }
$state = @{ A = @{ st = '运行中'; h = '正常' } }
$rows = @(Get-WebSnapshot $svc $state)
Assert ($rows.Count -eq 2) '应列出全部服务'
Assert ($rows[0].name -eq 'A' -and $rows[0].state -eq '运行中' -and $rows[0].health -eq '正常') 'A 的状态/健康应来自 svcState'
Assert ($rows[1].name -eq 'B' -and $rows[1].state -eq '') '还没探测到的服务应留空'
# $state 为 $null（早期/未接线）时只给空状态，不能抛——Web runspace 抛一次就是半张空页面
$rowsNull = @(Get-WebSnapshot $svc $null)
Assert ($rowsNull.Count -eq 2 -and $rowsNull[0].state -eq '') '没有 svcState 时应给空状态而不是抛错'

# ---- 3. HTML：含服务名与端口、按状态分色、注入被转义 ----
$html = Get-WebPageHtml @(
  [pscustomobject]@{ name = 'A'; port = 3000; state = '运行中'; health = '正常' },
  [pscustomobject]@{ name = '<script>x</script>'; port = 1; state = '已停止'; health = '' }
)
Assert ($html -match 'A' -and $html -match ':3000') '应渲染服务名与端口'
Assert ($html -match 'class="ok"') '运行中+正常应是 ok 档'
Assert ($html -match 'class="off"') '已停止应是 off 档'
Assert ($html -notmatch '<script>x') '服务名里的尖括号必须被转义'
Assert ($html -match '&lt;script&gt;') '转义后应出现实体'
Assert ($html -match 'refresh') '页面应自动刷新'

# ---- 4. 端到端：真起 loopback 服务器，带/不带 token 各一次 ----
$sync = [hashtable]::Synchronized(@{ svc = $svc; svcState = $state; stop = $false; webStop = $false })
$web = Start-WebView 0 $tok $sync
try {
  $deadline = [datetime]::Now.AddSeconds(5)
  while (-not $sync.webPort -and -not $sync.webError -and [datetime]::Now -lt $deadline) { Start-Sleep -Milliseconds 50 }
  Assert (-not $sync.webError) "服务器启动失败：$($sync.webError)"
  $port = [int]$sync.webPort
  Assert ($port -gt 0) '应回写实际端口'

  $ok = Invoke-WebRequest "http://127.0.0.1:$port/?t=$tok" -TimeoutSec 5 -UseBasicParsing
  Assert ($ok.StatusCode -eq 200) "带 token 应 200，got $($ok.StatusCode)"
  Assert ($ok.Content -match '>A<') '页面应含服务名'
  Assert ($ok.Headers['Content-Type'] -match 'text/html') '应声明 HTML 编码'

  foreach ($bad in @("http://127.0.0.1:$port/", "http://127.0.0.1:$port/?t=deadbeefdeadbeef")) {
    $code = 0
    try { $null = Invoke-WebRequest $bad -TimeoutSec 5 -UseBasicParsing } catch { $code = [int]$_.Exception.Response.StatusCode }
    Assert ($code -eq 403) "缺 token/错 token 应 403，got $code（$bad）"
  }

  # 只读：非 GET 一律 403（没有写入口）
  $resp = ''
  try {
    $c = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $port)
    $st = $c.GetStream()
    $req = [Text.Encoding]::ASCII.GetBytes("POST /?t=$tok HTTP/1.1`r`nHost: x`r`nContent-Length: 0`r`n`r`n")
    $st.Write($req, 0, $req.Length); $st.Flush()
    $sr = [IO.StreamReader]::new($st)
    $resp = $sr.ReadToEnd()
    $c.Close()
  } catch {}
  Assert ($resp -match ' 403 ') "非 GET 应 403，got [$($resp.Split("`r`n")[0])]"

  # 服务器脚本里不许有「报错但继续」的隐藏异常（曾经把 webview.ps1 全文拼进 runspace，自引用重跑）。
  # 必须先把循环停下来再读 Streams.Error：管道还在跑时枚举这个集合会卡住（本轮实测）。
  $sync.webStop = $true
  $null = $web.Handle.AsyncWaitHandle.WaitOne(3000)
  $serverErrors = @($web.PS.Streams.Error)
  Assert ($serverErrors.Count -eq 0) "服务器脚本不该有错误：$($serverErrors | Select-Object -First 1)"
} finally {
  $sync.webStop = $true
  Stop-WebView $web
}

# ---- 5. 端口被占用：报错进 webError，而不是静默不生效 ----
$busy = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$busy.Start()
try {
  $p2 = ([System.Net.IPEndPoint]$busy.LocalEndpoint).Port
  $sync2 = [hashtable]::Synchronized(@{ svc = $svc; svcState = $state; stop = $false; webStop = $false })
  $web2 = Start-WebView $p2 $tok $sync2
  try {
    $deadline = [datetime]::Now.AddSeconds(5)
    while (-not $sync2.webError -and [datetime]::Now -lt $deadline) { Start-Sleep -Milliseconds 50 }
    Assert ($sync2.webError) '端口被占用时应置 webError'
  } finally { $sync2.webStop = $true; Stop-WebView $web2 }
} finally { $busy.Stop() }

Write-Output 'PASS: token 校验、快照/HTML 渲染与转义、loopback 服务器 200/403、非 GET 拒绝、端口占用报错。'
