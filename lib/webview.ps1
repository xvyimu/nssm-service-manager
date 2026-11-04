# lib/webview.ps1 — 只读 Web 视图的生命周期（纯函数在 webview-core.ps1，服务器在 webview-server.ps1）
# 目的：不占 GUI 也能看健康（NSSM 常驻机常不接显示器）。局域网访问走 SSH 端口转发，不监听外部网卡。
# 为什么不用 HttpListener：非管理员注册 URL 前缀需要 netsh urlacl，会让测试与便携运行都多一道坑；
# 这里只用 TcpListener + 极简 GET 解析，代价是「只支持 GET」——而这正是这个视图的全部需求。
. (Join-Path $PSScriptRoot 'webview-core.ps1')

# runspace 里不能 dot-source，只能拼文本：core（纯函数）+ server（顶层循环）。
# **不能**把本文件拼进去——里面有 Start-WebView 与这段赋值，进 runspace 会自引用重跑。
$script:webScript = (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'webview-core.ps1')) +
                    (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'webview-server.ps1'))

# 启动只读视图。$sync 里回写 webPort（实际端口）与 webError（启动失败原因）。
# 请求端口与「已绑定」必须分开：GUI 用 `-not $sync.webPort` 判断绑定成功，
# 若把传入端口预置进 webPort，固定端口 bind 失败也会立即通过（状态栏与日志宣称正在监听）。
function Start-WebView([int]$port, [string]$token, $sync) {
  $sync.webRequestedPort = $port
  $sync.webPort = 0
  $sync.webStop = $false
  $sync.webError = $null
  $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
  $rs.SessionStateProxy.SetVariable('sync', $sync)
  $rs.SessionStateProxy.SetVariable('webToken', $token)
  $ps = [powershell]::Create().AddScript($script:webScript); $ps.Runspace = $rs
  $handle = $ps.BeginInvoke()
  @{ PS = $ps; Runspace = $rs; Handle = $handle }
}

function Stop-WebView($web) {
  if (-not $web) { return }
  try { [void]$web.PS.BeginStop($null, $null) } catch {}
  # 等循环自己退出（200ms 轮询）再拆 runspace：否则可能在写响应时被打断
  try { [void]$web.Handle.AsyncWaitHandle.WaitOne(2000) } catch {}
  try { $web.Runspace.Close() } catch {}
  try { $web.Runspace.Dispose() } catch {}
  try { $web.PS.Dispose() } catch {}
}
