# lib/webview-core.ps1 — 只读 Web 视图的纯函数：token 校验 / 快照 / HTML
# 单独一份的原因：服务器在独立 runspace 里跑，runspace 不能 dot-source，只能把本文件文本前置进去；
# 本文件**只有函数定义、没有顶层语句**，前置进 runspace 不会有副作用（也不会有自引用）。

function Test-WebToken([string]$given, [string]$expected) {
  # 先比长度再逐字符比：不早退，避免按前缀命中时间泄露
  if (-not $given -or -not $expected) { return $false }
  if ($given.Length -ne $expected.Length) { return $false }
  $diff = 0
  for ($i = 0; $i -lt $given.Length; $i++) { if ($given[$i] -ne $expected[$i]) { $diff++ } }
  $diff -eq 0
}

# 快照只读 $sync.svc / $sync.svcState：不碰卡片、不发命令，所以对 GUI 无副作用。
# 枚举键要在 $gate 下做——UI 侧增删服务会改这个 hashtable，另一个 runspace 边枚举边改会抛。
function Get-WebSnapshot($svc, $state, $gate = $null) {
  $keys = @()
  if ($gate) { [Threading.Monitor]::Enter($gate) }
  try { $keys = @($svc.Keys) } finally { if ($gate) { [Threading.Monitor]::Exit($gate) } }
  foreach ($n in $keys) {
    $st = ''; $h = ''
    # $state 可能还没建（CLI/早期）或为 $null：给空状态而不是抛「Cannot index into a null array」
    $seen = if ($state) { $state[$n] } else { $null }
    if ($seen) { $st = [string]$seen.st; $h = [string]$seen.h }
    [pscustomobject]@{ name = [string]$n; port = [int]$svc[$n].port; state = $st; health = $h }
  }
}

function Get-WebPageHtml($rows) {
  $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
  $cells = foreach ($r in $rows) {
    $cls = if ($r.state -eq '运行中' -and $r.health -eq '正常') { 'ok' }
           elseif ($r.state -eq '运行中') { 'warn' }
           else { 'off' }
    $stateText = if ($r.state) { $r.state } else { '未知' }
    $healthText = if ($r.health) { $r.health } else { '-' }
    "<tr class=`"$cls`"><td>$(& $enc $r.name)</td><td>:$(& $enc $r.port)</td><td>$(& $enc $stateText)</td><td>$(& $enc $healthText)</td></tr>"
  }
  $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  @"
<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta http-equiv="refresh" content="5">
<title>服务健康（只读）</title>
<style>
body{font-family:system-ui,'Segoe UI',sans-serif;margin:24px;color:#222}
table{border-collapse:collapse;min-width:420px}
th,td{text-align:left;padding:6px 12px;border-bottom:1px solid #e3e3e3}
th{color:#666;font-weight:600}
tr.ok td:first-child{border-left:4px solid #2e9b4f}
tr.warn td:first-child{border-left:4px solid #d78b00}
tr.off td:first-child{border-left:4px solid #b9b9b9}
footer{margin-top:16px;color:#888;font-size:12px}
</style></head><body>
<h2>服务健康（只读）</h2>
<table><thead><tr><th>服务</th><th>端口</th><th>状态</th><th>健康</th></tr></thead>
<tbody>$($cells -join "`n")</tbody></table>
<footer>每 5 秒自动刷新 · $now · 数据来自 GUI 最近一次探测</footer>
</body></html>
"@
}
