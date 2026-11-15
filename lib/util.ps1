# lib/util.ps1 — 聚合加载点：配置持久化 / UI 状态栏 / 日志轮转 / 安全检查 / 关停
#
# 函数体直接读调用方作用域的 $cfg / $logDir；参数不得同名，大小写不敏感会遮蔽外层变量。
# 各段实现按职责拆在独立文件里（见下方加载列表），本文件只保留加载顺序、共用格式化与两处兼容垫片，
# 调用方（GUI 入口、单测）仍然只需 dot-source 本文件。
# 实现细节：docs/IMPLEMENTATION-NOTES.md

# 健康历史是纯函数族，Update-StatusTick 依赖它；单独 dot-source util 的脚本（含单测）也要能用。
if (-not (Get-Command Test-HealthChanged -EA SilentlyContinue)) { . (Join-Path $PSScriptRoot 'health.ps1') }

# 人读时长（card.ps1 的时长后缀与陈旧提示共用这一份）：12s / 3分12秒 / 2小时05分。
# 负值（时钟回拨）返回空串，调用方按「没有时长」处理。card.ps1 不自我加载本文件——调用方须先点源 util.ps1。
function Format-Duration([datetime]$since, [datetime]$now) {
  $s = [int](($now - $since).TotalSeconds)
  if ($s -lt 0) { return '' }
  if ($s -lt 60) { return "${s}s" }
  $m = [int][math]::Floor($s / 60); $r = $s % 60
  if ($m -lt 60) { return "${m}分${r}秒" }
  $h = [int][math]::Floor($m / 60); $m = $m % 60
  return "${h}小时${m}分"
}

# 提示收口函数常驻 config.ps1（先于本文件加载）；单测只点源本文件时补一份同义实现，
# 免得每个调用点各写一遍 `$null -eq` 守卫。
if (-not (Get-Command Add-ConfigNotice -ErrorAction SilentlyContinue)) {
  function Add-ConfigNotice([string]$message) {
    if ($null -eq $script:configNotices) { $script:configNotices = @() }
    $script:configNotices += $message
  }
}

# 加载顺序 = 依赖顺序：配置读写 → 命令/状态栏 → 日志轮转 → 安全检查 → 关停。
# 循环变量用完置空：dot-source 不建作用域，残留的 $utilModule 会留在调用方脚本作用域里。
$utilModule = $null
foreach ($utilModule in 'svc-store','ui-status','log-retention','security-check','shutdown') {
  . (Join-Path $PSScriptRoot "$utilModule.ps1")
}
Remove-Variable utilModule -ErrorAction SilentlyContinue
