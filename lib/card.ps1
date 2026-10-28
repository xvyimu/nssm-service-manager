# lib/card.ps1 — 服务卡片：名称与端口、健康状态、面板入口和启停
# 自加载 config：测试 dot-source 本模块时未必先加载 config.ps1，此处自洽
#
# 对外契约：Set-CardTransition 被 lib/dialogs.ps1 的 Show-Remove 调用（删除过渡态），
# New-Card / Render-Page / Update-CardData 被 xaml.ps1 与主脚本调用。本文件与 dialogs.ps1
# 双向依赖（右键菜单 'remove' 调 Show-Remove），调用时解析符号，加载顺序不分先后。
if (-not $script:config) { . (Join-Path $PSScriptRoot 'config.ps1') }
$script:TOGGLE_COOLDOWN_MS = [int]$script:config.ToggleCooldownMs
# 过渡态超时上限：命令回执迟迟不到时（后台异常/命令丢失），探测到点后按到达值强制收敛，
# 不让卡片永久卡在启动中/停止中/删除中。取值见 config.ps1 的说明。
$script:TOGGLE_TIMEOUT_MS = [int]$script:config.ToggleTimeoutMs
# 过渡计时刷新的硬上限倍数（见 config.ps1）。config 缺该键时回落 10，别让 [int]$null=0 把上限归零。
$script:TRANSITION_HARD_CAP_FACTOR = if ($script:config.TransitionHardCapFactor) { [int]$script:config.TransitionHardCapFactor } else { 10 }

# 把卡片置为过渡态：状态文字、按钮、指示灯统一转橙并禁用操作，记录命令纪元。
# 启停（本文件）与删除（dialogs.ps1）共用——两处字段集曾不一致：删除路径漏了
# LastToggle / ReadyToToggle，配合 Update-CardData 的守卫缺失，导致删除进行中
# 探测结果到达时卡片被刷回「已停止」且按钮重新点亮。
# $at 由调用方给（启停用函数入口捕获的 $now，删除用触发时刻），保持各自原时间语义。
function Set-CardTransition($card, [string]$state, [int]$epoch, [datetime]$at){
  # 留档进入过渡态之前的终态：命令失败要 Set-CardRollback 原样放回。
  # 不许反推方向——restart 的期望终态与起始方向相反，remove 干脆没有方向，
  # 「按目标状态取反」会猜出错的终态。
  $card.PrevST=$card.ST; $card.PrevH=$card.H
  $card.ST=$state
  $card.LastToggle=$at
  # 过渡时钟独立于 LastToggle：后者兼作冷却起算点、回执到达时会被重写，
  # 拿它算超时会在回执后把计时重置。TransitionAt 只在进出过渡态时动。
  $card.TransitionAt=$at
  # 过渡态的**起点**，只在进入时记一次；TransitionAt 会被探测刷新（慢启动），它不刷新。
  # 逃生硬上限用它算，防止刷新把逃生口永久顶掉。
  $card.TransitionStartedAt=$at
  $card.Btn.IsEnabled=$false
  $card.Btn.Content=$state
  $card.ReadyToToggle=$false
  $card.LblSt.Text=$state
  $card.LblSt.Foreground=[System.Windows.Media.Brushes]::Orange
  $card.Dot.Fill=[System.Windows.Media.Brushes]::Orange
  $card.PendingEpoch=$epoch
}

# 过渡态是否已超时：回执迟迟不到时，不能无限期把卡片钉在过渡态上。
# 超时后调用方（Update-CardData）按到达的探测值收敛并解封按钮；这是丢失回执的最后逃生口。
# TransitionAt 未记录（MinValue：手工置态的旧夹具、或状态被直接赋值绕过 Set-CardTransition）
# 时不判超时——没有起算点就无法断言「超时了」，宁可维持原守卫行为。
# 卡片过渡态阈值：services.json 的 per-service 覆盖优先，缺省回落全局。
# New-Card 与 Update-CardInfo 都要算它——写成一份，免得将来改判据时只改一边（本仓的惯常教训）。
function Resolve-ToggleTimeoutMs($info){
  if($info -and $info.toggleTimeoutMs){ [int]$info.toggleTimeoutMs } else { $script:TOGGLE_TIMEOUT_MS }
}

# 阈值优先取卡片自己的 ToggleTimeoutMs（services.json 的 per-service 覆盖），缺省回落全局。
# 重服务（AI 服务冷启动一分钟起）不该被全局 45s 硬套；旧夹具手工搭的卡片对象没有该字段，
# 取到 $null 即回落，不抛错。
function Test-TransitionTimedOut($card, [datetime]$now){
  if ($card.ST -notin @('启动中','停止中','删除中')) { return $false }
  if ($card.TransitionAt -eq [datetime]::MinValue) { return $false }
  $limit = if ($card.ToggleTimeoutMs) { [int]$card.ToggleTimeoutMs } else { $script:TOGGLE_TIMEOUT_MS }
  # 硬上限：探测报同一过渡态时 TransitionAt 会被刷新（慢启动不误判），但**不能无限刷新**——
  # 服务永久卡在 StartPending/StopPending（停止回调挂死这类）时，逃生口会彻底失效，
  # 而那正是这套机制存在的理由。取 10 倍阈值：正常慢启动够用，真挂了也一定会被放出来。
  # TransitionStartedAt 缺失（MinValue：旧夹具手工置态）时退回 TransitionAt 当起点。
  $started = if ($card.TransitionStartedAt -and $card.TransitionStartedAt -ne [datetime]::MinValue) { $card.TransitionStartedAt } else { $card.TransitionAt }
  if (($now - $started).TotalMilliseconds -ge ($limit * $script:TRANSITION_HARD_CAP_FACTOR)) { return $true }
  ($now - $card.TransitionAt).TotalMilliseconds -ge $limit
}

# 健康门闩：卡片此刻是否允许切换（停止或启动）。已停止 → 可启动；运行中且健康正常 → 可停止。
# 单一来源：ack 成功分支、ack 失败的非过渡态分支、Update-CardData 末尾三处都用它——三处
# 各写一遍表达式时，改判据（如健康档位）只改一处就会漂移。
function Test-CardToggleReady([string]$state, [string]$health){
  ($state -eq '已停止') -or ($state -eq '运行中' -and $health -eq '正常')
}

# 命令失败（回执 ok=false）或过渡态超时逃生时，把卡片放回一个确定终态并解封按钮。
# 不能复用 Invoke-CardToggle 的方向推导：失败时服务状态没变，要的是「回到原样」。
# $toState / $toHealth 可选覆盖目标态：删除中回执丢失时服务实际状态不明，调用方传
# '未知' 收敛（见 Update-CardData 的删除中分支与 util.ps1 的过渡态 sweep）——回滚到
# 删除前的终态会让卡片显示「运行中」，但服务可能已被删掉。
function Set-CardRollback($card, [string]$toState, [string]$toHealth){
  if (-not $card) { return }
  if (-not $toState) {
    $toState=[string]$card.PrevST
    if ([string]::IsNullOrEmpty($toState) -or $toState -in @('启动中','停止中','删除中','查询中')) { $toState='未知' }
  }
  $h = if ($PSBoundParameters.ContainsKey('toHealth')) { $toHealth } else { $card.PrevH }
  # 先落回目标终态，再交给 Update-CardData 走常规渲染——否则过渡态守卫会按旧 ST 拦下这个值。
  $card.ST=$toState
  $card.PendingEpoch=0          # 清纪元：失败命令的回执/旧探测不再干扰
  $card.TransitionAt=[datetime]::MinValue
  $card.TransitionStartedAt=[datetime]::MinValue
  $card.LastToggle=[datetime]::MinValue  # 清冷却：用户刚吃了失败，应能立刻重试
  Update-CardData $card.SvcName $toState $h
}

# 过渡态超时逃生：把一张超时的过渡态卡片放出来。返回是否放出了。
# 由 Update-StatusTick 每帧无条件扫描调用——**不依赖队列生产者**：后台 runspace 若已死亡
# （不再入队任何探测结果），Update-CardData 里的超时分支永远等不到触发点，卡片会永久卡在
# 「启动中/停止中/删除中」——README 承诺的逃生在「后台死亡」这一前提下不成立。
# 启动中/停止中：回到命令前的终态（服务状态没变）；删除中：收敛到「未知」（删除成败只有
# remove 回执知道，丢失时状态不确定，不能按到达的探测值点亮按钮）。
function Invoke-TransitionTimeoutEscape($card,[datetime]$now){
  if (-not $card) { return $false }
  if (-not (Test-TransitionTimedOut $card $now)) { return $false }
  if ($card.ST -eq '删除中') { Set-CardRollback $card '未知' '' } else { Set-CardRollback $card }
  $true
}

# 按钮和双击共用校验与状态切换；仅保留各入口原有的反馈文案。
function Invoke-CardToggle($card, [string]$source='Button') {
  $name=$card.SvcName
  $state=$card.ST
  $now=[datetime]::Now
  $script:lastActionAt=$now
  $detailed=$source -eq 'DoubleClick'

  if ($state -in @('启动中','停止中')) {
    Set-StatusMessage $(if ($detailed) { "$name 正在切换中，请稍候" } else { "$name 正在切换中" })
    return
  }
  $elapsed=($now-$card.LastToggle).TotalMilliseconds
  if ($elapsed -lt $script:TOGGLE_COOLDOWN_MS) {
    $remaining=[math]::Ceiling(($script:TOGGLE_COOLDOWN_MS-$elapsed)/1000)
    $suffix=if ($detailed) { ' 再操作' } else { '' }
    Set-StatusMessage "$name 请等待 ${remaining}s$suffix"
    return
  }
  if ($state -notin @('运行中','已停止')) {
    Set-StatusMessage "$name 状态尚未就绪"
    return
  }
  $action=if ($state -eq '运行中') { 'stop' } else { 'start' }
  if ($action -eq 'stop' -and -not $card.ReadyToToggle) {
    $detail=if ($detailed) { '（健康非正常）' } else { '' }
    Set-StatusMessage "$name 服务未就绪$detail，暂不能关闭"
    return
  }

  # 记录本次命令纪元：Update-CardData 只接受 epoch ≥ 这个值的结果/回执。
  # 旧探测（epoch 更小或为 0）在过渡态期间直接丢，不再靠方向匹配做症状层补丁。
  # 顺序与原实现一致：先置 UI 过渡态，再入队命令（入队返回值作纪元）。
  $state = if ($action -eq 'stop') { '停止中' } else { '启动中' }
  Set-CardTransition $card $state 0 $now
  $card.PendingEpoch = (Send-ServiceCommand $name $action)
  Set-StatusMessage "$name $state..."
}

function New-Card([string]$name, $info){
  $border = New-Object System.Windows.Controls.Border -Property @{
    CornerRadius=10; Margin='8'; Padding='18'
    BorderBrush=$script:T.CardBrd; BorderThickness='1'; Background=$script:T.Card
  }
  $grid=New-Object System.Windows.Controls.Grid
  foreach ($height in 'Auto','Auto','*','Auto') {
    [void]$grid.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition -Property @{Height=$height}))
  }
  $heading=New-Object System.Windows.Controls.Grid
  [void]$heading.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width='*'}))
  [void]$heading.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width='Auto'}))
  $lblName=New-Object System.Windows.Controls.TextBlock -Property @{
    Text=$name; FontFamily=$script:cjkFont; FontSize=19; FontWeight='SemiBold'; Foreground=$script:T.Fg
    VerticalAlignment='Center'; TextTrimming='CharacterEllipsis'; ToolTip=$name; Margin='0,0,8,0'
  }
  # 端口徽章与 endpoint 行：端口号与面板 URL
  $port=New-Object System.Windows.Controls.Border -Property @{Background=$script:T.PortBg; CornerRadius=4; Padding='7,3'; VerticalAlignment='Center'}
  $portText=New-Object System.Windows.Controls.TextBlock -Property @{Text=":$($info.port)"; FontFamily=$script:fontMono; FontSize=12; Foreground=$script:T.Dim}
  $port.Child=$portText
  [void]$heading.Children.Add($lblName); [void]$heading.Children.Add($port)
  [System.Windows.Controls.Grid]::SetColumn($port,1)
  [void]$grid.Children.Add($heading)

  $endpoint=New-Object System.Windows.Controls.TextBlock -Property @{
    Text=$info.url; FontFamily=$script:fontMono; FontSize=12; Foreground=$script:T.Dim
    Margin='0,8,0,0'; TextTrimming='CharacterEllipsis'; ToolTip=$info.url
  }
  [void]$grid.Children.Add($endpoint); [System.Windows.Controls.Grid]::SetRow($endpoint,1)
  $state=New-Object System.Windows.Controls.StackPanel -Property @{VerticalAlignment='Center'; Margin='0,12,0,12'}
  $stateLine=New-Object System.Windows.Controls.StackPanel -Property @{Orientation='Horizontal'}
  $dot=New-Object System.Windows.Shapes.Ellipse -Property @{Width=10; Height=10; Fill=[System.Windows.Media.Brushes]::Gray; Margin='0,0,9,0'; VerticalAlignment='Center'}
  $lblSt=New-Object System.Windows.Controls.TextBlock -Property @{Text='查询中'; FontFamily=$script:cjkFont; FontSize=21; FontWeight='SemiBold'; Foreground=$script:T.Fg}
  $lblUp=New-Object System.Windows.Controls.TextBlock -Property @{Text='正在获取服务状态'; FontFamily=$script:cjkFont; FontSize=12; Foreground=$script:T.Dim; Margin='19,4,0,0'; TextTrimming='CharacterEllipsis'}
  [void]$stateLine.Children.Add($dot); [void]$stateLine.Children.Add($lblSt)
  [void]$state.Children.Add($stateLine); [void]$state.Children.Add($lblUp)
  [void]$grid.Children.Add($state); [System.Windows.Controls.Grid]::SetRow($state,2)

  $actions=New-Object System.Windows.Controls.Grid
  $open=New-Object System.Windows.Controls.Button -Property @{
    Content='打开面板'; FontFamily=$script:cjkFont; FontSize=12; Padding='10,6'
    HorizontalAlignment='Left'; Background='Transparent'; BorderThickness='0'; Foreground=$script:T.Accent
    Tag=$info.url; IsEnabled=(-not [string]::IsNullOrWhiteSpace($info.url))
  }
  # 无面板 URL 时禁用「打开面板」（IsEnabled 由 url 是否为空决定）
  $open.Add_Click({ Open-PanelUrl ([string]$this.Tag) })
  $btn=New-Object System.Windows.Controls.Button -Property @{
    Content='启动'; FontFamily=$script:cjkFont; FontSize=12; Padding='14,6'
    HorizontalAlignment='Right'; MinWidth=82; IsEnabled=$false
  }
  [void]$actions.Children.Add($open); [void]$actions.Children.Add($btn)
  [void]$grid.Children.Add($actions); [System.Windows.Controls.Grid]::SetRow($actions,3)
  $border.Child=$grid

  # 防抖状态（挂在 Border 上）
  $border | Add-Member -NotePropertyMembers @{
    SvcName=$name; Port=$info.port; Url=$info.url
    ST='查询中'; LastToggle=[datetime]::MinValue; ReadyToToggle=$false
    PendingEpoch=0
    # H 记住最近一次生效的健康文案；PrevST/PrevH 留档「进入过渡态之前的终态」，
    # 供命令失败时 Set-CardRollback 原样放回（反推方向会猜错 restart/remove）。
    # TransitionAt 是过渡态超时的独立起算点（MinValue = 不在过渡态）。
    H=''; PrevST='未知'; PrevH=''; TransitionAt=[datetime]::MinValue
    TransitionStartedAt=[datetime]::MinValue
    # per-service 过渡态超时（services.json 的 toggleTimeoutMs），缺省用全局
    ToggleTimeoutMs=$(Resolve-ToggleTimeoutMs $info)
    Dot=$dot; LblSt=$lblSt; LblUp=$lblUp; Btn=$btn
    PortText=$portText; Endpoint=$endpoint; OpenBtn=$open
  }
  # 按钮持有卡片引用，Click 里直接取，省得爬 VisualTree
  $btn.Tag = $border

  $border.Add_MouseLeftButtonDown({
    param($sender,$eventArgs)
    if ($eventArgs.ClickCount -ge 2) { Invoke-CardToggle $sender 'DoubleClick' }
  })
  $btn.Add_Click({ Invoke-CardToggle $this.Tag })

  # 右键菜单
  $border.Add_MouseRightButtonDown({
    param($s,$e)
    $n = $s.SvcName
    $ctx = New-Object System.Windows.Controls.ContextMenu
    $items = @(@('启动','start'),@('停止','stop'),@('重启','restart'),@('面板','open'),@('日志','log'),@('安全检查','security'),@('删除','remove'))
    foreach ($d in $items) {
      $mi = New-Object System.Windows.Controls.MenuItem -Property @{Header=$d[0]; Tag=$d[1]+'|'+$n}
      if ($d[1] -eq 'remove') { $mi.Foreground = $script:T.Danger }
      $mi.Add_Click({
        $parts = $this.Tag -split '\|'; $act = $parts[0]; $n = $parts[1]
        switch ($act) {
          { $_ -in @('start','stop','restart') } { Send-ServiceCommand $n $act }
          'open'    { Open-PanelUrl $script:svc[$n].url }
          'log'     { Show-Log $n $script:window }
          'security'{ Show-SecurityCheck $n }
          'remove'  { Show-Remove $n $script:window; Render-Page }
        }
      })
      [void]$ctx.Items.Add($mi)
    }
    $ctx.IsOpen = $true
    $e.Handled = $true
  })

  $script:cards[$name] = $border
  $border
}

# 刷新缓存卡片的端口/URL/按钮 Tag（配置变更后命中缓存时调用）。
# 同名重建或端口变更后，旧缓存的 Port/Url/Tag 会与 $script:svc 不一致——
# 发现 1 的根因：New-Card 把 port/url 固化进控件，Render-Page 命中缓存直接复用。
function Update-CardInfo([string]$name, $info){
  if (-not $script:cards.ContainsKey($name)) { return }
  $c = $script:cards[$name]
  $c.Port = $info.port; $c.Url = $info.url
  # 配置改了超时覆盖时，命中缓存的旧卡片要跟着换阈值
  $c.ToggleTimeoutMs = Resolve-ToggleTimeoutMs $info
  $c.PortText.Text = ":$($info.port)"
  $c.Endpoint.Text = $info.url
  $c.Endpoint.ToolTip = $info.url
  $c.OpenBtn.Tag = $info.url
  $c.OpenBtn.IsEnabled = (-not [string]::IsNullOrWhiteSpace($info.url))
}

# 更新卡片数据（由 DispatcherTimer 调用）
# 调用方据 $item.done 分流：命令完成回执走 -ack 分支，探测结果走普通分支。
# epoch 只过滤**命令回执**（-ack 分支）：旧命令的回执不解除新命令的过渡态。
# **普通探测仍按方向匹配收尾**（见下 $transitionExpect）——服务真正进入期望终态时让
# 过渡态退出，这是有意保留的行为，不是「症状层补丁消除」。回执丢失时由超时逃生兜底。
function Update-CardData([string]$n,[string]$st,[string]$h,[int]$e=0,[switch]$ack,[bool]$ok=$true){
  if (-not $script:cards.ContainsKey($n)) { return }
  $c = $script:cards[$n]
  if ($ack) {
    # 命令完成回执：epoch 低于卡片当前则丢弃（旧命令的回执不应解封新命令的过渡态）。
    if ($e -lt $c.PendingEpoch) { return }
    # 失败回执（T1）：命令没成功（启动抛异常/停止 sc.exe 非零/删除失败），
    # 不能只解封按钮——卡片还停在过渡态文字上，而后续探测会被上面的过渡态守卫
    # 按「期望终态」永久丢弃（启动失败时服务恒为已停止，永远等不到运行中）。
    # 故先回滚到命令前的终态，按钮恢复可用，让用户能重试。
    if (-not $ok) {
      # 但右键菜单的启停（card.ps1 右键 'start'/'stop' 分支）直接 Send-ServiceCommand、
      # 不置过渡态（TransitionAt 仍为 MinValue）——此时 PrevST/PrevH 还是 New-Card 的初值，
      # 回滚会把卡片刷成「未知」并清掉按钮，而服务实际状态没变、还在跑。不在过渡态就
      # 不回滚，只按当前状态/健康重算按钮（与成功分支同一门闩）。
      if ($c.TransitionAt -eq [datetime]::MinValue) {
        $c.ReadyToToggle = Test-CardToggleReady $c.ST $c.H
        $c.Btn.IsEnabled = $c.ReadyToToggle
        return
      }
      Set-CardRollback $c; return
    }
    # 成功回执：解封按钮 + 起冷却，但门闩必须按**当前**状态/健康重算——不能无条件置 $true。
    # 右键菜单的启停（card.ps1 右键 'start'/'stop' 分支）直接 Send-ServiceCommand，不经
    # Invoke-CardToggle，故回执到达时卡片可能仍停在「运行中/无响应」而没进过渡态；硬置
    # ReadyToToggle=$true 会绕过健康门闩，用户此刻能双击关掉一个本不该关闭的服务。
    $c.LastToggle = [datetime]::Now
    $c.ReadyToToggle = Test-CardToggleReady $c.ST $c.H
    $c.Btn.IsEnabled = $c.ReadyToToggle
    return
  }
  # 删除中：终态由 remove 回执决定（主脚本 ack 分支清 svc/cards + Render-Page），
  # 与启动/停止不同——它没有「期望终态」可等。期间探测每轮都到，且删除本就先 stop，
  # 探测必然先报「已停止」，随后可能报「未安装」——两者都只是过程中的中间态。
  # 故此处一律丢弃，不套用下面的方向匹配（否则卡片会从「删除中」闪回「已停止」
  # 并重新点亮按钮，用户还能对一个正在删除的服务下命令）。
  # 例外：超时逃生（见下）——回执彻底丢了时删除中同样不能永久卡住。
  $timedOut = Test-TransitionTimedOut $c ([datetime]::Now)
  if ($c.ST -eq '删除中') {
    if (-not $timedOut) { return }
    # 删除中回执丢失（后台异常退出）时收敛到「未知」，**不用**到达的探测值：
    # 探测可能报「已停止」（删除本就先 stop）→ 收敛后按钮点亮，用户能对一个正在删除的
    # 服务下「启动」。删除的成败只有 remove 回执知道，丢失时状态就是不确定，故显示未知、
    # 不解封按钮。删除路径正常 ≤6s，走到这里说明后台确已失联。
    Set-CardRollback $c '未知' ''
    return
  }
  # 过渡态保护（发现 3）：卡片处于启动中/停止中时，在途的旧探测结果不应覆盖
  # 用户刚刚触发的过渡态，也不应重新启用按钮——否则慢停止期间显示与实际不符。
  # 按方向判期望终态：启动中只接受运行中收尾，停止中只接受已停止收尾；
  # 未安装/未知属异常态（服务被卸载或出错），允许通过。
  # **方向守卫只保护「命令发起」的过渡态**（TransitionAt 有值 = Set-CardTransition 设过，
  # 即用户经双击/右键走 Invoke-CardToggle 或 Submit-RemoveCommand）。探测驱动的过渡态
  # （TransitionAt=MinValue，如外部工具启动、右键直接 Send-ServiceCommand 时探测到
  # StartPending）没有在途命令要保护，不该按方向丢弃——否则服务启动失败回落「已停止」
  # 会被永久丢弃、卡片卡死在「启动中」、连 45s 逃生也失效（因为 Test-TransitionTimedOut
  # 对 MinValue 恒 false）。H1。
  # 超时逃生（T1）：命令驱动的过渡态若回执丢失，超过 ToggleTimeoutMs 后不再按方向过滤，
  # 直接接受到达的探测值并解封按钮。
  $commandDriven = $c.TransitionAt -ne [datetime]::MinValue
  # 探测报的状态和卡片一样（都在启动中/停止中）→ 服务确实还在动，不是回执丢了。
  # 刷新过渡计时，让逃生阈值从「最后一次看到它在动」起算：重服务冷启动 90s 时，
  # 卡片不会在第 45 秒显示「未知」。不刷新的话，下面这道方向守卫会把 st='启动中'
  # 直接丢掉，计时永远停在用户点下按钮那一刻。
  # 有界：SCM 自己会把卡在 StartPending 的服务收敛到 Stopped（ServicesPipeTimeout），
  # 一旦探测不再报同一状态，计时就不再刷新，逃生照常生效。
  if (-not $timedOut -and $commandDriven -and $st -eq $c.ST) { $c.TransitionAt = [datetime]::Now }
  $transitionExpect = @{ '启动中' = '运行中'; '停止中' = '已停止' }
  if (-not $timedOut -and $commandDriven -and $transitionExpect.ContainsKey($c.ST)) {
    $expected = $transitionExpect[$c.ST]
    if ($st -ne $expected -and $st -notin @('未安装','未知')) { return }
  }
  if ($timedOut) { $c.PendingEpoch=0 }  # 逃生后清纪元，避免迟到回执再搅一次
  # 离开过渡态（旧 ST 是过渡态、新 ST 不是）→ 复位 TransitionAt。不复位它就会停在旧时间戳：
  # 之后任何探测驱动的过渡态都会被误判成命令驱动（M1），方向守卫被错误施加。
  if ($c.ST -in @('启动中','停止中') -and $st -notin @('启动中','停止中')) {
    $c.TransitionAt = [datetime]::MinValue
  }
  $c.ST = $st
  $c.H = $h   # 记住生效的健康文案：进入下一次过渡态时由 Set-CardTransition 留档为 PrevH
  $running = $st -eq '运行中'
  $healthy = $h -eq '正常'
  # 状态颜色映射：运行中按健康分档，停止/未安装统一灰，其余橙
  $dotColor = switch ($st) {
    '运行中' { if ($healthy) { 'Green' } elseif ($h -eq '超时') { 'Orange' } else { 'Red' } }
    { $_ -in @('已停止','未安装') } { 'Gray' }
    default { 'Orange' }
  }
  # 静态画刷已经冻结；这里只替换引用，不修改画刷颜色。
  $brush = [System.Windows.Media.Brushes]::$dotColor
  $c.Dot.Fill = $brush
  $c.LblSt.Text = $st
  $c.LblSt.Foreground = $brush

  # 健康文字
  $c.LblUp.Text = if ($running -and $healthy) {
    '服务响应正常'
  } elseif ($running) {
    $h
  } elseif ($st -eq '已停止') {
    '随时可以启动'
  } elseif ($h) {
    $h
  } else {
    '等待服务状态更新'
  }
  $c.ReadyToToggle = Test-CardToggleReady $st $h
  $c.Btn.Content = if ($running) { '停止' } else { '启动' }
  $c.Btn.IsEnabled = $c.ReadyToToggle
}
