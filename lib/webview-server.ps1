# lib/webview-server.ps1 — 只读 Web 视图的服务器端（在独立 runspace 里执行）
# 由 webview.ps1 拼成 core + 本文件后 AddScript。依赖调用方注入的 $sync / $webToken。
# 只听 loopback、只接受 GET：这是故意收窄的——GUI 以管理员身份运行，不把读接口放到外部网卡。
$listener = $null
try {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, [int]$sync.webPort)
  $listener.Start()
  $sync.webPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
} catch {
  $sync.webError = $_.Exception.Message
  return
}
try {
  while (-not $sync.stop -and -not $sync.webStop) {
    if (-not $listener.Pending()) { Start-Sleep -Milliseconds 200; continue }
    $client = $listener.AcceptTcpClient()
    try {
      $client.ReceiveTimeout = 2000
      $stream = $client.GetStream()
      $buf = New-Object byte[] 4096
      $n = $stream.Read($buf, 0, 4096)
      if ($n -le 0) { continue }
      $req = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
      $first = ($req -split "`r`n")[0]
      $ok = $false
      $body = '<!doctype html><meta charset="utf-8"><h1>403</h1><p>需要正确的 token。</p>'
      if ($first -match '^GET\s+(\S+)\s+HTTP/1\.') {
        $path = $Matches[1]
        $tok = ''
        if ($path -match '[?&]t=([0-9a-fA-F]{8,})') { $tok = $Matches[1] }
        if (Test-WebToken $tok $webToken) {
          $ok = $true
          $body = Get-WebPageHtml (Get-WebSnapshot $sync.svc $sync.svcState $sync.gate)
        }
      }
      $bytes = [Text.Encoding]::UTF8.GetBytes($body)
      $status = if ($ok) { '200 OK' } else { '403 Forbidden' }
      $head = "HTTP/1.1 $status`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
      $hb = [Text.Encoding]::ASCII.GetBytes($head)
      $stream.Write($hb, 0, $hb.Length)
      $stream.Write($bytes, 0, $bytes.Length)
      $stream.Flush()
    } catch { } finally { try { $client.Close() } catch {} }
  }
} finally { try { $listener.Stop() } catch {} }
