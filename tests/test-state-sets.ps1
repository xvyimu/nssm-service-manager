#requires -Version 7.0
# 状态集合回归（先覆盖、后收敛）：本工具的状态被分成五组语义，任何一处判据漂移都会在这里露出来。
#   过渡态   = 本工具发起的命令、有回执在等 → 退出确认 / F5 拒绝 / 超时逃生（启动中·停止中·删除中）
#   SCM 中间态 = SCM 侧 pending → poll 用更快的轮询间隔（+暂停中·继续中）
#   切换态   = 视觉上的「正在切换」→ 卡片时长后缀「已…」
#   陈旧豁免 = 过渡态 + 待保存 → 不被探测降级为「状态未知」
#   托盘计数 = 过渡态 + 待保存（暂停中/继续中由 SCM 或外部操作引起，本工具没有对应命令）
# 这些集合此前以字面量散落在 card/xaml/tray/ui-status/poll 里，靠人工同步；本文件先钉住行为。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
foreach ($module in 'config','theme','util','card','xaml','tray') { . (Join-Path $RepoRoot "lib/$module.ps1") }
. (Join-Path $PSScriptRoot 'test-helpers.ps1')

$script:svc = [ordered]@{ A = @{ port = 1; url = '' }; B = @{ port = 2; url = '' }; C = @{ port = 3; url = '' }; D = @{ port = 4; url = '' }; E = @{ port = 5; url = '' } }
$script:sync = @{ gate = [object]::new(); svc = $script:svc }
$script:svcState = @{}
$script:cards = @{}
$script:curPage = 0
$script:queue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
$script:msgQueue = [Collections.Concurrent.ConcurrentQueue[string]]::new()

$allStates = @('启动中','停止中','删除中','暂停中','继续中','待保存','运行中','已停止','未知')
$win = New-MainWindow
try {
  Render-Page
  $card = $script:cards['A']
  Assert ($null -ne $card) '夹具：A 的卡片应已创建'

  # ---- A. 过渡态：只有本工具发起的三态超时逃生 ----
  $transition = @('启动中','停止中','删除中')
  foreach ($st in $allStates) {
    $card.ST = $st
    $card.TransitionAt = (Get-Date).AddSeconds(-600)
    $card.TransitionStartedAt = [datetime]::MinValue
    $card.toggleTimeoutMs = $null
    $expect = $st -in $transition
    $got = Test-TransitionTimedOut $card (Get-Date)
    Assert ($got -eq $expect) "Test-TransitionTimedOut(「$st」) 应为 $expect，实际 $got"
  }
  Write-Output 'PASS: 过渡态只有「启动中/停止中/删除中」会超时逃生，暂停中/继续中/待保存不参与。'

  # ---- B. 退出确认清单：同一组三态，且只算清单里还在的服务 ----
  $busyCards = [ordered]@{}
  $busySvc = [ordered]@{}
  foreach ($st in $allStates) {
    $busyCards["S_$st"] = @{ SvcName = "S_$st"; ST = $st }
    $busySvc["S_$st"] = @{ port = 0 }
  }
  $busy = @(Get-ExitBusy $busyCards $busySvc)
  Assert ($busy.Count -eq 3) "退出确认应只算三态（3），实际 $($busy.Count)：$(($busy | ForEach-Object { $_.ST }) -join ',')"
  foreach ($b in $busy) { Assert ($b.ST -in $transition) "退出确认混入非过渡态：$($b.ST)" }
  Write-Output 'PASS: 退出确认只把「启动中/停止中/删除中」算作在途，待保存与 SCM 中间态不拦退出。'

  # ---- C. 陈旧豁免：过渡态 + 待保存 ----
  # 显式钉住探测间隔：config.json 可能把这台机器的 ProbeIntervalMs 调过，阈值会跟着变。
  $script:config.ProbeIntervalMs = 4000
  $exempt = @('启动中','停止中','删除中','待保存')
  foreach ($st in $allStates) {
    $card.ST = $st
    $card.Stale = $false
    $card.Offline = $false
    $card.PendingSave = $false
    $script:svcState['A'] = @{ st = '运行中'; h = '正常'; at = (Get-Date).AddSeconds(-30) }
    Update-CardFreshness $card (Get-Date)
    $expectStale = -not ($st -in $exempt)
    Assert ($card.Stale -eq $expectStale) "Update-CardFreshness(「$st」) 的 Stale 应为 $expectStale，实际 $($card.Stale)"
  }
  Write-Output 'PASS: 陈旧豁免只覆盖「启动中/停止中/删除中/待保存」，暂停中/继续中仍会被判陈旧。'

  # ---- D. 时长后缀：视觉上的五种切换态 ----
  foreach ($st in $allStates) {
    $card.ST = $st
    $card.H = '正常'
    $card.LblUpBase = 'BASE'
    $card.StateSince = (Get-Date).AddSeconds(-5)
    Update-CardClock $card (Get-Date)
    $text = [string]$card.LblUp.Text
    $isSwitching = $st -in @('启动中','停止中','删除中','暂停中','继续中')
    if ($isSwitching) {
      Assert ($text -match '· 已 ') "切换态「$st」应有「· 已 …」后缀，实际「$text」"
    } else {
      Assert ($text -notmatch '· 已 ') "非切换态「$st」不该有「· 已 …」后缀，实际「$text」"
    }
  }
  Write-Output 'PASS: 时长后缀覆盖「启动中/停止中/删除中/暂停中/继续中」，待保存与未知不显示。'

  # ---- E. 新鲜度胶囊的「待处理」：过渡态 + 待保存 ----
  $savedCards = $script:cards
  $script:cards = [ordered]@{
    P1 = [pscustomobject]@{ ST = '启动中' }
    P2 = [pscustomobject]@{ ST = '停止中' }
    P3 = [pscustomobject]@{ ST = '删除中' }
    P4 = [pscustomobject]@{ ST = '待保存' }
    P5 = [pscustomobject]@{ ST = '暂停中' }
  }
  $script:svcState['A'] = @{ st = '运行中'; h = '正常'; at = (Get-Date) }
  Update-FreshnessPill
  Assert ($script:freshPill.Text -match '5 个服务 · 4 个待处理') "胶囊应显示 4 个待处理，实际「$($script:freshPill.Text)」"
  $script:cards = $savedCards
  Write-Output 'PASS: 标题栏胶囊的待处理数 = 过渡态 + 待保存（暂停中不计）。'

  # ---- F. 托盘文案：过渡态 + 待保存 ----
  $script:svcState = [ordered]@{
    A = @{ st = '启动中' }; B = @{ st = '暂停中' }; C = @{ st = '删除中' }; D = @{ st = '运行中' }; E = @{ st = '停止中' }
  }
  $script:cards = [ordered]@{ Z = @{ PendingSave = $true } }
  $trayText = Get-TrayStatusText
  Assert ($trayText -match '5 个服务') "托盘文案应带服务数，实际「$trayText」"
  Assert ($trayText -match '4 个待处理') "托盘待处理应为 4（启动中+删除中+停止中+待保存），实际「$trayText」"
  $script:svcState = @{}
  $script:cards = $savedCards
  Write-Output 'PASS: 托盘待处理 = 过渡态 + 待保存（暂停中/继续中不计，与退出确认同一份判定）。'

  # ---- G. 单独点源也要拿到状态集合（不再维护第二份字面量） ----
  # 子进程里只点源 ui-status / tray：config 未加载时它们各自自加载，回落清单不会再单独漂一份。
  $probe = & pwsh -NoProfile -Command "& { . '$RepoRoot\lib\ui-status.ps1'; . '$RepoRoot\lib\tray.ps1'; (@(`$script:TRANSITION_STATES) -join ',') }"
  Assert ($probe -eq '启动中,停止中,删除中') "单独点源 ui-status/tray 时应自加载 config 得到三态，实际「$probe」"
  $pollSrc = [IO.File]::ReadAllText((Join-Path $RepoRoot 'lib/poll.ps1'))
  # 负向断言两条（旧版 "'启动中'.*'停止中'.*'继续中'" 顺串匹配，换序或拆行复制都能绕过）：
  #  (a) poll.ps1 里含 ≥2 个中间态的数组字面量最多一处——唯一允许的那一处是脚本开头「runspace 缺注入
  #      时的兜底」（$sync 没塞 scmPendingStates 才会用到）。多出任何一处（换序、拆行、只抄两三个）
  #      都说明又维护了一份集合，直接红。
  $stateLiteral = '(?s)@\([^)]*(?:启动中|停止中|暂停中|继续中)[^)]*(?:启动中|停止中|暂停中|继续中)[^)]*\)'
  $groups = [regex]::Matches($pollSrc, $stateLiteral)
  Assert ($groups.Count -le 1) "poll.ps1 出现 $($groups.Count) 处含 ≥2 个中间态的数组字面量：只允许缺注入兜底那一份，其余必须读 `$sync.scmPendingStates"
  if ($groups.Count -eq 1) {
    # 兜底本身也必须完整四态：少一个，那类中间态就会退回 ProbeIdleMs 长轮询（卡片停在「启动中」）。
    foreach ($stName in '启动中','停止中','暂停中','继续中') {
      Assert ($groups[0].Value.Contains("'$stName'")) "poll.ps1 唯一的兜底字面量缺「$stName」——兜底也必须是完整四态"
    }
  }
  #  (b) 必须真的读注入键：只留兜底、不读 $sync.scmPendingStates 等于把注入通道拆了（config 改了也不生效）。
  Assert ($pollSrc -match '(?s)\$sync\.scmPendingStates') 'poll.ps1 未读取 $sync.scmPendingStates（入口注入的中间态集合）'
  Write-Output 'PASS: 单独点源 ui-status / tray 时自加载 config，状态集合仍只有一份。'
} finally {
  $win.Close()
}
