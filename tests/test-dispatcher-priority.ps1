#requires -Version 7.0
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'

# 回归：ContentRendered 里的日志清理是用 Dispatcher.BeginInvoke 异步排队的。
# 原写法把优先级写成字符串 'Background'，Dispatcher 没有 (Delegate, DispatcherPriority)
# 这个重载，PowerShell 会退回 BeginInvoke(Delegate, Object[] args)，把字符串当成委托的
# 实参数组——委托被以 1 个参数调用，抛 TargetParameterCountException，清理永远不执行。
#
# 这类 bug 的特征是「不抛错、不执行、只留一行日志」，眼睛看不出来。故这里不看源码文本，
# 而是真排一个队、真跑帧循环，验委托确实被执行了。
Add-Type -AssemblyName WindowsBase, PresentationCore, PresentationFramework

# 跑一小段帧循环，让排队的 BeginInvoke 出队执行。两条断言共用，避免各写一份帧/定时器样板。
function Invoke-DispatcherPump {
  $frame = [System.Windows.Threading.DispatcherFrame]::new()
  $timer = [System.Windows.Threading.DispatcherTimer]::new()
  $timer.Interval = [TimeSpan]::FromMilliseconds(600)
  $timer.Add_Tick({ $timer.Stop(); $frame.Continue = $false })
  $timer.Start()
  try { [System.Windows.Threading.Dispatcher]::PushFrame($frame) }
  finally { $timer.Stop() }
}

$gui = [IO.File]::ReadAllText((Join-Path $RepoRoot 'service-manager-gui.ps1'))

# 1) 源码约束：优先级参数必须是枚举，不能是字符串字面量。
if ($gui -match ",\s*'(Background|Normal|Low|High|ApplicationIdle|SystemIdle|Send|DataBind|Input|Loaded|Render)'\s*\)") {
  throw "Dispatcher.BeginInvoke 的优先级写成了字符串字面量 —— 会静默绑定到 (Delegate, Object[]) 重载。"
}
if ($gui -notmatch 'DispatcherPriority\]::Background') {
  throw 'service-manager-gui.ps1 里没找到 [System.Windows.Threading.DispatcherPriority]::Background —— 清理调用可能被改写。'
}

$disp = [System.Windows.Threading.Dispatcher]::CurrentDispatcher

# 2) 行为验证：枚举写法必须真的执行委托。
$script:ran = $false
[void]$disp.BeginInvoke([Action]{ $script:ran = $true },
  [System.Windows.Threading.DispatcherPriority]::Background)
Invoke-DispatcherPump
if (-not $script:ran) {
  throw 'Dispatcher.BeginInvoke 排队的委托没有执行 —— 首帧后的日志清理会静默失效。'
}

# 3) 反证：字符串写法确实会坏（防止有人"简化"回去还以为没问题）。
#    两个断言缺一不可——只验「抛了异常」不够，还要验「委托体没跑」，
#    因为这条 bug 的危害正是「异常被兜底接住、调用方看不出任何问题」。
$script:badRan = $false
$script:caught = $null
$disp.add_UnhandledException({
  param($s, $e)
  $script:caught = $e.Exception.GetType().Name
  $e.Handled = $true
})
[void]$disp.BeginInvoke([Action]{ $script:badRan = $true }, 'Background')
Invoke-DispatcherPump

if ($script:caught -ne 'TargetParameterCountException') {
  throw "字符串优先级应当抛 TargetParameterCountException，实际: '$($script:caught)'（此断言用于确认回归测试本身有效）。"
}
if ($script:badRan) {
  throw '字符串优先级竟然执行了委托 —— 若 PowerShell 行为变了，本回归测试的前提失效，需重新评估。'
}

Write-Output 'PASS: 异步清理回调的 DispatcherPriority 用枚举绑定，委托确实执行；字符串写法仍会抛 TargetParameterCountException 且委托体不执行（回归护栏有效）。'
