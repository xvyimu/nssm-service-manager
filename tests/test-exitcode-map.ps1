#requires -Version 7.0
# T6：Convert-ScExitCode / Convert-ServiceStatus 的文案表此前无直接断言——现有测试只断言
# 消息含「删除失败」/「启动失败」前缀，不校验 README 声明的用户可见映射（1060 → 服务未安装 等）。
# 这两个映射是 GUI 状态栏与 CLI 提示的用户可见文案，码→文案若悄悄改错，用户看到的是裸数字
# 或错的中文，测试却全绿。这里直测真函数（不是复制一张表）。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'lib/svc-common.ps1')
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }

# ---- Get-ScExe：sc.exe 必须解析出可执行路径，不能裸调 ----
# 本机实测 System32 不在 PATH 里，裸调 `sc.exe` 会 CommandNotFoundException，而
# $LASTEXITCODE 保留上一条命令的码——删除/安装的实证复核会据此误判。
# 这里断言解析规则本身（注入优先级 + 兜底），不依赖当前机器的 PATH 状态。
$injected = Get-ScExe
Assert ($injected -eq 'sc.exe' -or (Test-Path -LiteralPath $injected)) "Get-ScExe 解析出的路径必须可执行或退回裸名，got [$injected]"
# 没有注入时若盘上有 System32\sc.exe，必须优先用它（本机就是这种情况）
if (-not $script:ScExe -and -not $sync) {
  $sys = Join-Path $env:SystemRoot 'System32\sc.exe'
  if (Test-Path -LiteralPath $sys) { Assert ($injected -eq $sys) "应解析到 System32 全路径，got [$injected]" }
}
# 注入优先级：$sync.scExe 压过 $script:ScExe（runspace 用它注入替身名）
$script:ScExe = 'from-script'
Assert ((Get-ScExe) -eq 'from-script') '应优先使用 $script:ScExe'
$sync = @{ scExe = 'from-sync' }
Assert ((Get-ScExe) -eq 'from-sync') '应优先使用 $sync.scExe'
$sync = $null
Remove-Variable scExe -Scope Script -ErrorAction SilentlyContinue
Write-Output 'PASS: Get-ScExe resolves an executable path and honors $sync.scExe / $script:ScExe injection.'

# sc.exe / NSSM 退出码 → 中文（README「功能」节与 svc-common.ps1 注释声明的映射）
$exitCases = @{
  0    = ''
  1056 = '已在运行'
  1062 = '未启动'
  1060 = '服务未安装'
  1051 = '禁止启动（禁用或只读）'
  1053 = '服务进程无法启动'
  1058 = '服务被禁用'
  1067 = '进程意外退出'
  1072 = '服务已被标记为删除'
  5    = '拒绝访问（可能非管理员）'
}
foreach ($code in $exitCases.Keys) {
  $got = Convert-ScExitCode $code
  Assert ($got -eq $exitCases[$code]) "退出码 $code 文案错误：期望 '$($exitCases[$code])'，实际 '$got'。"
}
# 未列入的码走 default：必须带出码本身，便于排查
Assert ((Convert-ScExitCode 9999) -eq '错误码 9999') '未知退出码应回落到「错误码 <n>」。'

# ServiceController.Status → 中文状态（单一映射源）
$statusCases = @{
  'Stopped'      = '已停止'
  'StartPending' = '启动中'
  'StopPending'  = '停止中'
  'Running'      = '运行中'
}
foreach ($s in $statusCases.Keys) {
  Assert ((Convert-ServiceStatus $s) -eq $statusCases[$s]) "状态 $s 文案错误：$(Convert-ServiceStatus $s)。"
}
# 未知/空 → 未知（不抛错）
Assert ((Convert-ServiceStatus 'Whatever') -eq '未知') '未知状态应回落「未知」。'
Assert ((Convert-ServiceStatus '') -eq '未知') '空状态应回落「未知」。'

Write-Output 'PASS: Convert-ScExitCode maps all declared codes (+default); Convert-ServiceStatus maps all SCM states (+unknown); both are the real functions.'
