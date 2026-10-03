# lib/config.ps1 — 可调常量集中收口（PER_PAGE / 探测超时 / 日志轮转 / 冷却）
# 默认值内嵌于此；仓根 config.json（已 git 忽略）存在时覆盖默认值——
# 与 services.json 同构：示例进仓，实配每台机器自定，不进 git。
$script:configPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'config.json'
$script:config = [ordered]@{
  PerPage             = 6        # 卡片每页数量（xaml.ps1 UniformGrid 3×2 与 Render-Page 分页共用）
  TcpTimeoutMs        = 200      # 端口探测超时（poll.ps1 TcpClient BeginConnect）
  HttpTimeoutMs       = 3000     # HTTP 探测超时（poll.ps1 共享 HttpClient.Timeout，本地面板冷启动宽限）
  CrashLogMaxBytes    = 524288   # gui-crash.log 轮转阈值（512 KiB，超则挪成 .1）
  ToggleCooldownMs    = 8000     # 双击启停冷却（card.ps1 Invoke-CardToggle）
  WaitStoppedTimeoutMs = 6000    # 重启/删除前轮询 Stopped 的上限（add-svc.ps1 / poll.ps1 Wait-Stopped）
  # ---- 可选托盘行为（默认全关，保持历史行为：最小化进任务栏、关闭即退出）----
  TrayEnabled     = $false   # 总开关；关时下面两项无效，也不加载 WinForms
  MinimizeToTray  = $false   # 点最小化收进托盘（需 TrayEnabled）
  CloseToTray     = $false   # 关闭窗口收进托盘而非退出（需 TrayEnabled）
}

# 可选覆盖：仓根 config.json 存在时按 key 覆盖（未知 key 忽略，类型强转）。
if (Test-Path -LiteralPath $script:configPath) {
  try {
    $override = Get-Content $script:configPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    foreach ($k in $override.Keys) {
      if ($script:config.Contains($k)) {
        $script:config[$k] = $override[$k]  # 已有 key 才覆盖，防注入未知字段
      }
    }
  } catch {
    # 配置解析失败不阻断启动——用默认值。错误记进 configWarning（GUI 加载后弹框），
    # 若 statusBar 已就绪（将来加载顺序变动）也同步显示。Load-Svc 尊重已设的 configWarning（util.ps1 不覆盖）。
    $msg = "config.json 无效：$($_.Exception.Message)，用默认配置"
    if (-not $script:configWarning) { $script:configWarning = $msg }
    if ($script:statusBar) { $script:statusBar.Text = $msg }
  }
}
