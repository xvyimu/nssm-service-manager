#requires -Version 7.0
# 停止/重启等待期的确定进度条（卡片过渡态区域）。
# 数据契约由 poll 侧生产：$sync.stopProgress = $null 或 @{ name; elapsedMs; totalMs }。
# 卡片每帧消费：名字匹配且 totalMs>0 → 按 elapsedMs/totalMs 夹到 0..1 显示；其余一律 Collapsed。
# 本测试只走真实每帧节拍（Update-StatusTick），不直接调 Update-CardStopProgress：
# 若有人把更新摘出 tick 或改回「单独调用才对」，下面的断言会红。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
foreach ($module in 'theme','util','card','xaml','dialogs') { . (Join-Path $RepoRoot "lib/$module.ps1") }
. (Join-Path $PSScriptRoot 'test-helpers.ps1')

$script:sync = @{ wake = [Threading.AutoResetEvent]::new($false) }
$script:svc = [ordered]@{
  SvcProg  = @{ port = 8080; url = 'http://127.0.0.1:8080' }
  SvcOther = @{ port = 8081; url = 'http://127.0.0.1:8081' }
}
$script:cmdQueue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:queue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:msgQueue = [Collections.Concurrent.ConcurrentQueue[string]]::new()

$win = New-MainWindow
try {
  Render-Page
  $prog = $script:cards['SvcProg']
  $other = $script:cards['SvcOther']
  Assert ($null -ne $prog -and $null -ne $other) '两张卡片都应建出来。'
  $bar = $prog.StopBar
  Assert ($null -ne $bar) '卡片上应有 StopBar 进度条。'

  # 落点：细条必须与状态副标题同处一块（过渡态区域），不是状态栏/标题栏
  Assert ($null -ne $bar.Parent -and $bar.Parent.Children.Contains($prog.LblUp)) '进度条应与状态副标题同处一块（过渡态区域）。'
  Assert ($bar.Height -ge 3 -and $bar.Height -le 4) "进度条应为 3-4px 细条，got $($bar.Height)"
  # 自检模板：Value 对了但模板缺 PART_Indicator 时进度条是「空槽」，肉眼看不见却全绿。
  [void]$bar.ApplyTemplate()
  $indicator = $bar.Template.FindName('PART_Indicator', $bar)
  Assert ($null -ne $indicator) '进度条模板必须带 PART_Indicator（否则 Value 正确也画不出填充）。'
  Assert ($bar.Maximum -gt $bar.Minimum) '进度条必须是确定模式（Maximum 大于 Minimum）。'

  # 两卡都进「停止中」：这时的等待是真实场景
  Update-CardData 'SvcProg' '运行中' '正常'
  Update-CardData 'SvcOther' '运行中' '正常'
  Set-CardTransition $prog '停止中' 1 ([datetime]::Now)
  Set-CardTransition $other '停止中' 1 ([datetime]::Now)

  # 1) 根本没有该键：隐藏
  Update-StatusTick
  Assert ($bar.Visibility -eq 'Collapsed') "无 stopProgress 应隐藏，got $($bar.Visibility)"

  # 2) 显式 $null：隐藏
  $script:sync['stopProgress'] = $null
  Update-StatusTick
  Assert ($bar.Visibility -eq 'Collapsed') "stopProgress 为 `$null 应隐藏，got $($bar.Visibility)"

  # 3) 名字匹配、50%：显示且 Value 约等于 0.5
  $script:sync['stopProgress'] = [pscustomobject]@{ name = 'SvcProg'; elapsedMs = 6000; totalMs = 12000 }
  Update-StatusTick
  Assert ($bar.Visibility -eq 'Visible') "名字匹配且有总时长应显示，got $($bar.Visibility)"
  Assert ([math]::Abs($bar.Value - 0.5) -lt 0.001) "6000/12000 应为 0.5，got $($bar.Value)"
  Assert ($bar.Value -ge $bar.Minimum -and $bar.Value -le $bar.Maximum) 'Value 必须落在 Minimum..Maximum 内。'
  # 反方向不串台：别的卡这帧不该冒出进度
  Assert ($other.StopBar.Visibility -eq 'Collapsed') '同一帧里其它卡片不得显示这条进度（串台）。'

  # 4) 名字不匹配：两张卡都不显示
  $script:sync['stopProgress'] = [pscustomobject]@{ name = 'NoSuchSvc'; elapsedMs = 6000; totalMs = 12000 }
  Update-StatusTick
  Assert ($bar.Visibility -eq 'Collapsed') "名字不匹配时必须隐藏，got $($bar.Visibility)"
  Assert ($other.StopBar.Visibility -eq 'Collapsed') '名字不匹配时任何卡片都不该显示进度。'

  # 5) 名字指向另一张卡：进度只出现在那张卡上
  $script:sync['stopProgress'] = [pscustomobject]@{ name = 'SvcOther'; elapsedMs = 3000; totalMs = 12000 }
  Update-StatusTick
  Assert ($bar.Visibility -eq 'Collapsed') "进度属于别的服务时本卡必须隐藏，got $($bar.Visibility)"
  Assert ($other.StopBar.Visibility -eq 'Visible') "进度属于自己时该显示，got $($other.StopBar.Visibility)"
  Assert ([math]::Abs($other.StopBar.Value - 0.25) -lt 0.001) "3000/12000 应为 0.25，got $($other.StopBar.Value)"

  # 6) 越界夹取：超时仍满格、负值仍空条，都不越 0..1
  $script:sync['stopProgress'] = [pscustomobject]@{ name = 'SvcProg'; elapsedMs = 20000; totalMs = 12000 }
  Update-StatusTick
  Assert ([math]::Abs($bar.Value - 1.0) -lt 0.001) "超时应收口到 1.0，got $($bar.Value)"
  $script:sync['stopProgress'] = [pscustomobject]@{ name = 'SvcProg'; elapsedMs = -500; totalMs = 12000 }
  Update-StatusTick
  Assert ([math]::Abs($bar.Value - 0.0) -lt 0.001) "负 elapsed 应收口到 0，got $($bar.Value)"

  # 7) 总时长非法（0）：按约定隐藏，不画一条 1 秒就满格的假进度
  $script:sync['stopProgress'] = [pscustomobject]@{ name = 'SvcProg'; elapsedMs = 500; totalMs = 0 }
  Update-StatusTick
  Assert ($bar.Visibility -eq 'Collapsed') "totalMs<=0 应隐藏，got $($bar.Visibility)"

  # 8) 脏数据（缺 totalMs）：不能带崩 tick，直接当没有
  $script:sync['stopProgress'] = [pscustomobject]@{ name = 'SvcProg'; elapsedMs = 500 }
  Update-StatusTick
  Assert ($bar.Visibility -eq 'Collapsed') "缺字段的脏数据应隐藏，got $($bar.Visibility)"

  # 9) 等待结束：置回 $null 后隐藏（不残留）
  $script:sync['stopProgress'] = [pscustomobject]@{ name = 'SvcProg'; elapsedMs = 12000; totalMs = 12000 }
  Update-StatusTick
  Assert ($bar.Visibility -eq 'Visible') '满格那一帧仍应可见。'
  $script:sync['stopProgress'] = $null
  Update-StatusTick
  Assert ($bar.Visibility -eq 'Collapsed') "等待结束后应隐藏，got $($bar.Visibility)"

  # 10) worker 忙（阻塞等停）期间不判陈旧：默认停服预算 12s > 2×探测周期 8s，
  #     照常判会把其余「运行中」卡片全刷成「状态未知」并禁用按钮（P1 的根因）。
  $other.TransitionAt = [datetime]::MinValue
  $other.ST = '运行中'; $other.Stale = $false
  $script:svcState = @{ SvcOther = @{ at = [datetime]::Now.AddSeconds(-60) } }
  $script:sync['busy'] = $true
  Update-CardFreshness $other ([datetime]::Now)
  Assert ($other.Stale -eq $false) 'busy=true（worker 正阻塞等停）时不得判陈旧。'
  Assert ($other.LblSt.Text -ne '状态未知') "busy=true 应保持现有显示，got $($other.LblSt.Text)"
  $script:sync['busy'] = $false
  Update-CardFreshness $other ([datetime]::Now)
  Assert ($other.Stale -eq $true) 'busy=false 且样本 60s 前 → 必须判陈旧（否则这条门禁形同虚设）。'
  Assert ($other.LblSt.Text -eq '状态未知') "判陈旧应显示状态未知，got $($other.LblSt.Text)"
  # 复位，避免影响同一窗口里的后续帧
  [void]$script:sync.Remove('busy'); $script:svcState = @{}
  $other.ST = '运行中'; $other.Stale = $false

  Write-Output 'PASS: 停止进度条只在名字匹配且有总时长时显示（0..1 夹取），其余状态隐藏且不串台。'
  Write-Output 'PASS: worker 忙（阻塞等停）期间不判陈旧，busy 复位后照常判。'
} finally {
  $win.Close()
}

# ---- GUI 接线判据 + 生产端不凭空加键 ----
# 上面对进度条消费端做足了用例，但若 GUI 入口的 $script:sync 字面量没有 stopProgress 键，
# Wait-Stopped 永远不发布进度——两组用例各自为绿，真实 GUI 里却永远看不到进度条。
# 这里把「GUI 到底有没有这个键」变成源码级机器判据，再验生产端缺键时不凭空加键。
$guiSrc = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'service-manager-gui.ps1') -Encoding utf8
$guiCode = Get-SourceCodeOnly $guiSrc
$m = [regex]::Match($guiCode, '(?s)\$script:sync\s*=\s*\[hashtable\]::Synchronized\(@\{(.*?)\r?\n\}\)')
Assert $m.Success '在 gui 源码里找不到 $script:sync 字面量（选择器失效，断言形同虚设）。'
# 键名按「行首或分号之后」抓：字面量里有 `svc = ...; queue = ...` 这种一行多键的写法。
$syncKeys = @([regex]::Matches($m.Groups[1].Value, '(?m)(?:^|;)\s*([A-Za-z_]\w*)\s*=') | ForEach-Object { $_.Groups[1].Value })
# 自检：选择器本身要能抓到已知邻居键，否则「恰好抓到 stopProgress」可能只是巧合。
Assert ($syncKeys -contains 'waitStoppedTimeoutMs' -and $syncKeys -contains 'probeThrottleLimit') "sync 键名提取选择器失效，实际键：$($syncKeys -join ',')"
Assert ($syncKeys -contains 'stopProgress') "GUI 的 `$script:sync 字面量必须含 stopProgress 键（否则进度条永远不显示）；实际键：$($syncKeys -join ',')"
# busy 同理必须预置：poll 只在键已存在时置位，缺键 = 阻塞期间卡片照样翻「状态未知」。
Assert ($syncKeys -contains 'busy') "GUI 的 `$script:sync 字面量必须含 busy 键（否则阻塞等停期间卡片会误判陈旧）；实际键：$($syncKeys -join ',')"
Write-Output "PASS: GUI 的 `$script:sync 字面量含 stopProgress（源码级判据，共 $($syncKeys.Count) 键）。"

# 生产端不凭空加键：用**不带**该键的同步哈希表跑 Wait-Stopped，必须不抛错、不补键。
. (Join-Path $RepoRoot 'lib/svc-common.ps1')
$script:waitScans = 0
function Get-SvcStateQuiet([string]$name, [int]$timeoutMs = 0){ $script:waitScans++; 'Running' }
function Get-ServiceQueryCode([string]$name, [int]$timeoutMs = 0){ 0 }
$bareSync = @{ waitStoppedPollMs = 30; svcStateTimeoutMs = 50; waitStoppedNoticeMs = 600000 }
$script:sync = $bareSync
$rBare = Wait-Stopped 'NoKeySvc' -TimeoutMs 150
Assert ($rBare -eq $false) '无 stopProgress 键时等待行为应不变（超时应返回 false）。'
Assert (-not $bareSync.ContainsKey('stopProgress')) '没有该键时 Wait-Stopped 不该凭空加键。'
Assert ($script:waitScans -ge 1) '没观察到等待轮询（用例没真正跑起来）。'
Write-Output "PASS: 缺 stopProgress 键时 Wait-Stopped 静默跳过（$($script:waitScans) 次轮询，未加键）。"