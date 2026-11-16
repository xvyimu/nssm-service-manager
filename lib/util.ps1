# lib/util.ps1 — 聚合加载点：配置持久化 / UI 状态栏 / 日志轮转 / 安全检查 / 关停
#
# 函数体直接读调用方作用域的 $cfg / $logDir；参数不得同名，大小写不敏感会遮蔽外层变量。
# 各段实现按职责拆在独立文件里（见下方加载列表），本文件只保留加载顺序、共用格式化与两处兼容垫片，
# 调用方（GUI 入口、单测）仍然只需 dot-source 本文件。
# 实现细节：docs/IMPLEMENTATION-NOTES.md

# 健康历史是纯函数族，Update-StatusTick 依赖它；单独 dot-source util 的脚本（含单测）也要能用。
if (-not (Get-Command Test-HealthChanged -EA SilentlyContinue)) { . (Join-Path $PSScriptRoot 'health.ps1') }

# 全仓唯一的时长格式化来源。两种样式各有归属，不要在调用方再拼串：
#   Full  —— 卡片后缀 / 日志：「3分12秒」「2小时05分」（精确到秒）
#   Short —— 状态栏药丸：「3 分钟」「2 小时」（粗粒度、带空格、无秒）
function Format-Duration([datetime]$since, [datetime]$now, [ValidateSet('Full','Short')][string]$Style = 'Full') {
  $s = [int](($now - $since).TotalSeconds)
  if ($Style -eq 'Short') {
    if ($s -lt 0) { $s = 0 }
    if ($s -lt 60) { return "${s}s" }
    if ($s -lt 3600) { return "$([int][math]::Floor($s / 60)) 分钟" }
    return "$([int][math]::Floor($s / 3600)) 小时"
  }
  if ($s -lt 0) { return '' }
  if ($s -lt 60) { return "${s}s" }
  $m = [int][math]::Floor($s / 60); $r = $s % 60
  if ($m -lt 60) { return "${m}分${r}秒" }
  $h = [int][math]::Floor($m / 60); $m = $m % 60
  return "${h}小时${m}分"
}

# Add-ConfigNotice 只定义在 config.ps1（它先于本文件加载）；单独点源本文件的测试须先点 config。

# 加载顺序 = 依赖顺序：配置读写 → 命令/状态栏 → 日志轮转 → 安全检查 → 关停。
# 循环变量用完置空：dot-source 不建作用域，残留的 $utilModule 会留在调用方脚本作用域里。
$utilModule = $null
foreach ($utilModule in 'svc-store','ui-status','log-retention','security-check','shutdown') {
  . (Join-Path $PSScriptRoot "$utilModule.ps1")
}
Remove-Variable utilModule -ErrorAction SilentlyContinue
