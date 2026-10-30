#requires -Version 7.0
# probe 口径：`probe: tcp` 与空 url 只做 TCP 判定，不发 HTTP。
# 修前：TCP 通后无条件 GetAsync，非 HTTP 端口（数据库/gRPC/纯 socket）必然失败 →
# 卡片永远不是绿点，且（配合旧门闩）「关闭」按钮被永久禁用。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'lib/poll.ps1')
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }

# 只 listen、从不回话的端口：TCP 握手由内核 backlog 完成，HTTP 永远等不到响应。
# 这正是数据库端口的形态——旧实现下 HTTP 那档必然卡满超时。
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port

$services = [ordered]@{
  TcpProbe = @{ port = $port; url = "http://127.0.0.1:$port/"; probe = 'tcp' }
  BlankUrl = @{ port = $port; url = '' }
}
$shared = [hashtable]::Synchronized(@{
  svc = $services; gate = [object]::new(); stop = $false
  queue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
  cmd   = [Collections.Concurrent.ConcurrentQueue[object]]::new()
  msg   = [Collections.Concurrent.ConcurrentQueue[string]]::new()
  wake  = [Threading.AutoResetEvent]::new($false)
  nssm  = 'Invoke-TestNssm'
  scExe = 'Invoke-TestSc'
  # 若真的发了 HTTP，这里会卡满 6s——下面用耗时区分「没发 HTTP」（阈值留足余量，避免慢机器误判）
  httpTimeoutMs = 6000
})
$mock = @'
function Get-Service {
  [CmdletBinding()]param([string[]]$Name)
  foreach ($n in $Name) { [pscustomobject]@{ Name = $n; Status = 'Running' } }
}
function Invoke-TestNssm { 0 }
function Invoke-TestSc { $global:LASTEXITCODE = 0 }
'@

$rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.Open()
$rs.SessionStateProxy.SetVariable('sync', $shared)
$ps = [powershell]::Create().AddScript($mock + "`n" + $script:poll)
$ps.Runspace = $rs
$sw = [Diagnostics.Stopwatch]::StartNew()
$handle = $ps.BeginInvoke()
try {
  $got = @{}
  $deadline = [datetime]::Now.AddSeconds(15)
  while ($got.Count -lt 2 -and [datetime]::Now -lt $deadline) {
    $item = $null
    while ($shared.queue.TryDequeue([ref]$item)) { if ($item.h) { $got[$item.n] = $item.h } }
    Start-Sleep -Milliseconds 50
  }
  $elapsed = $sw.Elapsed.TotalMilliseconds
  Assert ($got.Count -eq 2) "应拿到两个服务的健康值，got [$($got.Keys -join ',')]"
  Assert ($got['TcpProbe'] -eq '正常') "probe=tcp：TCP 通即正常，got [$($got['TcpProbe'])]"
  Assert ($got['BlankUrl'] -eq '正常') "url 为空：TCP 通即正常，got [$($got['BlankUrl'])]"
  Assert ($elapsed -lt 4000) "不该走 HTTP（耗时 $([int]$elapsed)ms，HTTP 超时 6000ms）"

  # 静态兜底：分支必须排在 GetAsync 之前，防止后续重构把顺序改回去
  $branch = $script:poll.IndexOf("probeLocal -eq 'tcp'")
  $http = $script:poll.IndexOf('GetAsync')
  Assert ($branch -ge 0 -and $http -gt $branch) 'tcp 分支必须位于 HTTP 探测之前'
} finally {
  $shared.stop = $true
  [void]$shared.wake.Set()
  try { if ($handle.AsyncWaitHandle.WaitOne(3000)) { $ps.EndInvoke($handle) | Out-Null } } catch {}
  try { $ps.Dispose() } catch {}
  try { $rs.Close(); $rs.Dispose() } catch {}
  try { $listener.Stop() } catch {}
}

Write-Output 'PASS: probe=tcp 与空 url 只做 TCP 判定（不发 HTTP），健康=正常。'
