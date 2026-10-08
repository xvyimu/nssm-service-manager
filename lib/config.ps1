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
  ToggleTimeoutMs     = 45000    # 卡片过渡态超时逃生（card.ps1 Test-TransitionTimedOut）——
                                 # 命令回执丢失（后台异常退出/命令未入队）时，过渡态不能永久卡住：
                                 # 超时后按到达的探测值收敛并解封按钮。取值须大于正常路径的最长耗时，
                                 # 否则会在正常失败流程里抢先触发。
                                 # 已实测：删除路径 stop + Wait-Stopped ≤ 6s（WaitStoppedTimeoutMs）。
                                 # 已实测：SCM 的 ServicesPipeTimeout 本机注册表未设 = 内置默认 **30000ms**
                                 # （HKLM\SYSTEM\CurrentControlSet\Control）。原默认值 30000 与它恰好
                                 # 相等——启动失败回落 sc.exe start 走 SCM 同步管道时，管道压满 30s
                                 # 与逃生阈值同一时刻触发，卡片会先被探测值收敛、再被迟到回执改一次，
                                 # 表现为状态抖动。故抬到 45000（+15s 余量），让回执先到。
                                 # **该路径耗时仍未真机实测**（需建服务，见 tests/probe-1053-timing.ps1，
                                 # 管理员跑）：45000 是按「管道上限 + 余量」推的，不是量出来的。实测后
                                 # 若确认真实耗时远小于 30s，可回落；若接近 30s，保持本值并考虑再放大。
  WaitStoppedTimeoutMs = 6000    # 重启/删除前轮询 Stopped 的上限（add-svc.ps1 / poll.ps1 Wait-Stopped）
  LogKeepCount        = 10       # 轮转日志保留份数（util.ps1 Remove-RotatedLogs）——
                                 # 口径是**跨服务全局**按修改时间倒序的前 N 份豁免，不是每服务各 N 份
  LogKeepDays         = 14       # 轮转日志保留天数：删除须同时满足「不在全局前 N 份」且「早于 N 天」。
                                 # 故 14 天内高频轮转的档一份都不删——保留份数上限只在跨过天数后生效
  LogDir              = ''       # 日志根覆盖；空 = 仓内 logs/。改它只影响新注册的服务——
                                 # 已注册服务的 AppStdout/AppStderr 写死在注册表，须逐个重新注册
  # ---- 轮询与探测节奏（原硬编码在 poll.ps1 / svc-common.ps1）----
  ProbeThrottleLimit  = 8        # 并行探测的 ThrottleLimit（poll.ps1 ForEach-Object -Parallel）
  ProbeIntervalMs     = 4000     # 有运行中服务时的轮询间隔（poll.ps1 循环尾 WaitOne）
  ProbeIdleMs         = 15000    # 全停止时的轮询间隔——省下空转的唤醒与整轮扫描
  WaitStoppedPollMs   = 300      # Wait-Stopped 轮询步长（svc-common.ps1）
  # ---- NSSM 注册参数（原硬编码在 Get-NssmSetSpec）----
  AppRotateBytes      = 5242880  # 单日志档轮转阈值（5 MiB，NSSM AppRotateBytes）
  AppStopMethodConsole = 5000    # 停止时给控制台进程的收尾毫秒（NSSM AppStopMethodConsole）
  # ---- UI 节奏 ----
  AckPollIntervalMs   = 400      # 命令回执/探测结果轮询的 DispatcherTimer 间隔（主脚本）
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
    # 配置解析失败不阻断启动——用默认值。错误记进 configWarning，由 GUI 加载完成后弹框。
    # 下面那句 statusBar 直写在正常启动路径下**不会执行**：本文件在主脚本第 34 行加载，
    # 而 $script:statusBar 要到 New-MainWindow（223 行）才建。保留它是给「调用方先建窗口
    # 再加载 config」的将来顺序变动兜底；那时也不该带租约（Set-StatusMessage 定义在 util.ps1，
    # 本文件之前，此刻尚不可用）。
    # Load-Svc 尊重已设的 configWarning（util.ps1 不覆盖）。
    $msg = "config.json 无效：$($_.Exception.Message)，用默认配置"
    if (-not $script:configWarning) { $script:configWarning = $msg }
    if ($script:statusBar) { $script:statusBar.Text = $msg }
  }
}
