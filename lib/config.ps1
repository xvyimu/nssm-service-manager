# lib/config.ps1 — 可调常量集中收口（PER_PAGE / 探测超时 / 日志轮转 / 冷却）
# 默认值内嵌；仓根 config.json（已 git 忽略）存在时覆盖——与 services.json 同构：示例进仓、实配不进 git。
# 实现细节与踩坑记录：docs/IMPLEMENTATION-NOTES.md
$script:configPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'config.json'
$script:config = [ordered]@{
  PerPage             = 6        # 卡片每页数量（xaml.ps1 UniformGrid 3×2 与 Render-Page 分页共用）
  TcpTimeoutMs        = 200      # 端口探测超时（poll.ps1 TcpClient BeginConnect）
  HttpTimeoutMs       = 3000     # HTTP 探测超时（poll.ps1 共享 HttpClient.Timeout，本地面板冷启动宽限）
  CrashLogMaxBytes    = 524288   # gui-crash.log 轮转阈值（512 KiB，超则挪成 .1）
  ToggleCooldownMs    = 8000     # 双击启停冷却（card.ps1 Invoke-CardToggle）
  ToggleTimeoutMs     = 45000    # 卡片过渡态超时逃生（回执丢失时按探测值收敛解封）。§ToggleTimeoutMs
  WaitHealthyTimeoutMs = 120000  # 「运行中但健康探测不通过」超过此时长：从「等待中」升级为「无响应」+ 红点
  TransitionHardCapFactor = 10   # 过渡计时刷新的硬上限倍数：累计超过 ToggleTimeoutMs × 本值就强制逃生。
  WaitStoppedTimeoutMs = 6000    # 重启/删除前轮询 Stopped 的上限（svc-common.ps1 Wait-Stopped）
  ExtCommandTimeoutMs = 60000    # 外部命令（sc.exe / nssm.exe）超时；超时即 Kill 并返回 exit=-1
  LogKeepCount        = 10       # 轮转日志保留份数（util.ps1 Remove-RotatedLogs），按日志目录各留前 N 份。§LogKeepCount
  LogKeepDays         = 14       # 轮转日志保留天数：删除须同时满足「不在全局前 N 份」且「早于 N 天」。
  HealthHistory       = $true    # 健康状态历史（logs/health/health-YYYYMMDD.ndjson）；只在状态变化时落一条
  HealthKeepDays      = 30       # 健康历史保留天数（按天分文件，删更早的）
  LogDir              = ''       # 日志根覆盖；空 = 仓内 logs/。已注册服务的 AppStdout/AppStderr 写死在注册表，须重新注册。
  # ---- 轮询与探测节奏（原硬编码在 poll.ps1 / svc-common.ps1）----
  ProbeThrottleLimit  = 8        # 并行探测的 ThrottleLimit（poll.ps1 ForEach-Object -Parallel）
  ProbeIntervalMs     = 4000     # 有运行中服务时的轮询间隔（poll.ps1 循环尾 WaitOne）
  ProbePendingMs      = 1000     # 有服务处于 Pending 时的轮询间隔（查状态廉价，不必跟 4s 健康探测节奏）。§ProbePendingMs
  ProbeIdleMs         = 15000    # 全停止时的轮询间隔——省下空转的唤醒与整轮扫描
  WaitStoppedPollMs   = 300      # Wait-Stopped 轮询步长（svc-common.ps1）
  # ---- NSSM 注册参数（原硬编码在 Get-NssmSetSpec）----
  AppRotateBytes      = 5242880  # 单日志档轮转阈值（5 MiB，NSSM AppRotateBytes）
  AppRotateSeconds    = 86400    # 文件「太新」不轮转的年龄门槛；AppRotateFiles=1 每次服务启动都轮转，靠它压堆积。§AppRotateSeconds
  AppStopMethodConsole = 5000    # 停止时给控制台进程的收尾毫秒（NSSM AppStopMethodConsole）
  # ---- UI 节奏 ----
  AckPollIntervalMs   = 400      # 命令回执/探测结果轮询的 DispatcherTimer 间隔（主脚本）
  # ---- 可选托盘行为（默认全关，保持历史行为：最小化进任务栏、关闭即退出）----
  # ---- 只读 Web 视图（默认关；loopback + token，局域网走 SSH 端口转发）----
  WebView         = $false   # 总开关；开时状态栏显示带 token 的地址
  WebViewPort     = 0        # 0 = 每次启动随机端口（避免和别的工具抢固定端口）
  TrayEnabled     = $false   # 总开关；关时下面两项无效，也不加载 WinForms
  MinimizeToTray  = $false   # 点最小化收进托盘（需 TrayEnabled）
  CloseToTray     = $false   # 关闭窗口收进托盘而非退出（需 TrayEnabled）
}

# 数值键的合法区间（含端点）。TryParse 只证明「是整数」：-1 会让 WaitOne/CTS 变成无限等待，
# 0 会让分页做除零（窗口根本起不来）。越界一律回落默认值 + 提示，与「坏值不阻断」同一策略。§configRanges
$script:configRanges = @{
  PerPage                 = @(1, 12)
  TcpTimeoutMs            = @(50, 600000)
  HttpTimeoutMs           = @(50, 600000)
  CrashLogMaxBytes        = @(1024, 104857600)
  ToggleCooldownMs        = @(1000, 600000)
  ToggleTimeoutMs         = @(1000, 600000)
  WaitHealthyTimeoutMs    = @(1000, 3600000)
  TransitionHardCapFactor = @(1, 100)
  WaitStoppedTimeoutMs    = @(100, 600000)
  ExtCommandTimeoutMs     = @(100, 600000)
  LogKeepCount            = @(0, 1000)
  LogKeepDays             = @(0, 3650)
  HealthKeepDays          = @(1, 365)
  ProbeThrottleLimit      = @(1, 64)
  ProbeIntervalMs         = @(200, 600000)
  ProbePendingMs          = @(200, 600000)
  ProbeIdleMs             = @(500, 3600000)
  WaitStoppedPollMs       = @(10, 60000)
  AppRotateBytes          = @(0, 1073741824)
  AppRotateSeconds        = @(0, 31536000)
  AppStopMethodConsole    = @(0, 600000)
  AckPollIntervalMs       = @(100, 5000)
  WebViewPort             = @(0, 65535)
}

# 可选覆盖：仓根 config.json 存在时按 key 覆盖（未知 key 忽略）。
# 覆盖值按默认值的类型校验：`"TcpTimeoutMs": "200ms"` 这种带单位的写法若原样赋值，
# 主脚本的 [int] 强转会抛 RuntimeException，而那时 $ErrorActionPreference='Stop' 已生效
# → 窗口根本不出现。坏值只让该字段保留默认 + 记一条提示。
if (Test-Path -LiteralPath $script:configPath) {
  try {
    $override = Get-Content $script:configPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    foreach ($k in $override.Keys) {
      # 未知键：拼错（`TcpTimeout` 少个 Ms）或版本不符时，静默忽略等于「配了但没生效」。
      # services.json 那侧有同样的白名单提示，这里保持一致。§config 加载
      if (-not $script:config.Contains($k)) {
        if ($null -eq $script:configNotices) { $script:configNotices = @() }
        $script:configNotices += "config.json：未知键 $k 已忽略（拼写或版本不符）"
        continue
      }
      $def = $script:config[$k]
      $raw = $override[$k]
      $value = $null
      $valid = $false
      $rangeNoted = $false
      if ($def -is [int]) {
        $n = 0
        if ([int]::TryParse([string]$raw, [ref]$n)) {
          $value = $n; $valid = $true
          # 范围校验（负数/0 会变成无限等待或除零）；越界单独措辞，免得用户以为类型写错。
          if ($script:configRanges.ContainsKey($k)) {
            $lo, $hi = $script:configRanges[$k]
            if ($n -lt $lo -or $n -gt $hi) {
              $valid = $false; $rangeNoted = $true
              if ($null -eq $script:configNotices) { $script:configNotices = @() }
              $script:configNotices += "config.json：$k=$n 超出允许范围（$lo..$hi），已用默认值 $def"
            }
          }
        }
      } elseif ($def -is [bool]) {
        $b = $false
        if ([bool]::TryParse([string]$raw, [ref]$b)) { $value = $b; $valid = $true }
      } else {
        $value = [string]$raw; $valid = $true
      }
      if ($valid) { $script:config[$k] = $value }
      elseif ($rangeNoted) { }   # 已记过更具体的越界提示，别再叠一条「值无效」
      else {
        if ($null -eq $script:configNotices) { $script:configNotices = @() }
        $script:configNotices += "config.json：$k 的值 '$raw' 无效，已用默认值 $def"
      }
    }
  } catch {
    # 解析失败不阻断启动：记 configWarning，由 GUI 加载后弹框（格式 `<文件名> 无效：<原因>`）。§config 加载
    $msg = "config.json 无效：$($_.Exception.Message)"
    if (-not $script:configWarning) { $script:configWarning = $msg }
    # 正常启动顺序下 statusBar 还没建（config 先于窗口加载）；这句是给「先建窗口再加载 config」兜底。
    if ($script:statusBar) { $script:statusBar.Text = "$msg，用默认配置" }
  }
}
