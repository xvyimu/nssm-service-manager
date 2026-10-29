# lib/card.ps1 — 服务卡片：名称与端口、健康状态、面板入口和启停
# 自加载 config：测试 dot-source 本模块时未必先加载 config.ps1，此处自洽
#
# 与 dialogs.ps1 双向依赖（右键菜单调 Show-Remove），符号调用时解析，加载顺序不分先后。
# 实现细节与踩坑记录：docs/IMPLEMENTATION-NOTES.md
if (-not $script:config) { . (Join-Path $PSScriptRoot 'config.ps1') }
$script:TOGGLE_COOLDOWN_MS = [int]$script:config.ToggleCooldownMs
$script:TOGGLE_TIMEOUT_MS = [int]$script:config.ToggleTimeoutMs
$script:TRANSITION_HARD_CAP_FACTOR = if ($script:config.TransitionHardCapFactor) { [int]$script:config.TransitionHardCapFactor } else { 10 }  # 缺键回落 10，[int]$null=0 会把上限归零
$script:WAIT_HEALTHY_TIMEOUT_MS = if ($script:config.WaitHealthyTimeoutMs) { [int]$script:config.WaitHealthyTimeoutMs } else { 120000 }

# 置过渡态：转橙、禁用按钮、记命令纪元。启停与删除共用。§Set-CardTransition
function Set-CardTransition($card, [string]$state, [int]$epoch, [datetime]$at){
  $card.PrevST=$card.ST; $card.PrevH=$card.H
  $card.ST=$state
  $card.LastToggle=$at
  $card.TransitionAt=$at
  $card.TransitionStartedAt=$at
  $card.StateSince=$at
  # 状态切换就重新计时：否则重启后的服务会带着上一次的等待时长，一点就红。
  $card.UnhealthySince=[datetime]::MinValue
  $card.HealthyStreak=0
  $card.Btn.IsEnabled=$false
  if ($card.BtnStop) { $card.BtnStop.IsEnabled=$false }
  $card.ReadyToToggle=$false
  $card.LblSt.Text=$state
  # 换副标题，否则会挂着上一次的「随时可以启动」再叠时长
  $card.LblUpBase = switch ($state) {
    '启动中' { '正在启动…' }
    '停止中' { '正在停止…' }
    '删除中' { '正在删除…' }
    default  { $card.LblUpBase }
  }
  # 立刻补一次时长后缀：否则最长有 400ms 空窗，副标题会闪一下
  Update-CardClock $card ([datetime]::Now)
  $card.LblSt.Foreground=[System.Windows.Media.Brushes]::Orange
  $card.Dot.Fill=[System.Windows.Media.Brushes]::Orange
  $card.PendingEpoch=$epoch
}

# 把时长格式化成「12s / 3分12秒 / 2小时05分」。负值（时钟回拨）返回空串。
function Format-Elapsed([datetime]$since, [datetime]$now) {
  $s = [int](($now - $since).TotalSeconds)
  if ($s -lt 0) { return '' }
  if ($s -lt 60) { return "${s}s" }
  $m = [int][math]::Floor($s / 60); $r = $s % 60
  if ($m -lt 60) { return "${m}分${r}秒" }
  $h = [int][math]::Floor($m / 60); $m = $m % 60
  return "${h}小时${m}分"
}

# 每帧刷新时长后缀，只改后缀不重算正文。§Update-CardClock
function Update-CardClock($card, [datetime]$now) {
  if (-not $card -or -not $card.LblUp) { return }
  $label = switch ($card.ST) {
    { $_ -in @('启动中','停止中','删除中','暂停中','继续中') } { '已' }
    '运行中' { if ($card.H -and $card.H -ne '正常') { '已等待' } else { '已运行' } }
    '已停止' { '已停' }
    default   { $null }
  }
  $suffix = ''
  if ($label -and $card.StateSince -and $card.StateSince -ne [datetime]::MinValue) {
    $e = Format-Elapsed $card.StateSince $now
    if ($e) { $suffix = " · $label $e" }
  }
  $base = if ($null -ne $card.LblUpBase) { [string]$card.LblUpBase } else { '' }
  $card.LblUp.Text = $base + $suffix
}

# 过渡阈值：per-service 覆盖优先，缺省回落全局。两处共用，免得改判据只改一边。
function Resolve-ToggleTimeoutMs($info){
  if($info -and $info.toggleTimeoutMs){ [int]$info.toggleTimeoutMs } else { $script:TOGGLE_TIMEOUT_MS }
}

# 取卡片自己的覆盖，缺省回落全局；旧夹具没该字段，$null 即回落。§Test-TransitionTimedOut
function Test-TransitionTimedOut($card, [datetime]$now){
  if ($card.ST -notin @('启动中','停止中','删除中')) { return $false }
  if ($card.TransitionAt -eq [datetime]::MinValue) { return $false }
  $limit = Resolve-ToggleTimeoutMs $card
  $started = if ($card.TransitionStartedAt -and $card.TransitionStartedAt -ne [datetime]::MinValue) { $card.TransitionStartedAt } else { $card.TransitionAt }
  # 墙钟被回拨（NTP 校正/手改时间）时差值恒为负，两个阈值都判不出来，卡片永久卡在过渡态。
  # 判不了就按超时处理——逃生只是解封按钮，比卡死好。
  if ($now -lt $started) { return $true }
  if (($now - $started).TotalMilliseconds -ge ($limit * $script:TRANSITION_HARD_CAP_FACTOR)) { return $true }
  ($now - $card.TransitionAt).TotalMilliseconds -ge $limit
}

# 两个动作各自的门闩：启动只看状态；关闭额外要求健康正常（把不健康的服务关掉通常不是用户本意）
function Test-CardCanStart([string]$state){ $state -eq '已停止' }
function Test-CardCanStop([string]$state, [string]$health){
  $state -eq '运行中' -and $health -eq '正常'
}

# 按状态/健康算按钮可用性。三处共用一份，免得某条路径只更新了一个按钮。
function Update-CardButtons($card){
  if (-not $card) { return }
  $card.ReadyToToggle = Test-CardCanStop $card.ST $card.H
  $card.Btn.IsEnabled = Test-CardCanStart $card.ST
  if ($card.BtnStop) { $card.BtnStop.IsEnabled = $card.ReadyToToggle }
}

# 失败/超时逃生时放回确定终态并解封按钮。不能复用方向推导：失败时状态没变，要的是回到原样。§Set-CardRollback
function Set-CardRollback($card, [string]$toState, [string]$toHealth){
  if (-not $card) { return }
  if (-not $toState) {
    $toState=[string]$card.PrevST
    if ([string]::IsNullOrEmpty($toState) -or $toState -in @('启动中','停止中','删除中','查询中')) { $toState='未知' }
  }
  $h = if ($PSBoundParameters.ContainsKey('toHealth')) { $toHealth } else { $card.PrevH }
  # 先落回目标终态再交给 Update-CardData，否则过渡态守卫会按旧 ST 拦下这个值
  $card.ST=$toState
  $card.StateSince=[datetime]::Now   # 回滚也是「进入终态」，时长从此刻重新起算
  $card.UnhealthySince=[datetime]::MinValue
  $card.HealthyStreak=0
  $card.PendingEpoch=0          # 清纪元：失败命令的回执/旧探测不再干扰
  $card.TransitionAt=[datetime]::MinValue
  $card.TransitionStartedAt=[datetime]::MinValue
  $card.LastToggle=[datetime]::MinValue  # 清冷却：用户刚吃了失败，应能立刻重试
  Update-CardData $card.SvcName $toState $h
}

# 超时逃生：每帧无条件扫描，不依赖队列——后台 runspace 死掉也要能逃。§Invoke-TransitionTimeoutEscape
function Invoke-TransitionTimeoutEscape($card,[datetime]$now){
  if (-not $card) { return $false }
  if (-not (Test-TransitionTimedOut $card $now)) { return $false }
  if ($card.ST -eq '删除中') { Set-CardRollback $card '未知' '' } else { Set-CardRollback $card }
  $true
}

# 按钮和双击共用校验与状态切换；仅保留各入口原有的反馈文案。
function Invoke-CardAction($card, [string]$action, [string]$source='Button') {
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
  if ($action -eq 'start' -and -not (Test-CardCanStart $state)) {
    Set-StatusMessage "$name 状态尚未就绪"
    return
  }
  if ($action -eq 'stop' -and -not (Test-CardCanStop $state $card.H)) {
    $detail=if ($detailed) { '（健康非正常）' } else { '' }
    Set-StatusMessage "$name 服务未就绪$detail，暂不能关闭"
    return
  }

  # 先置 UI 过渡态再入队命令；入队返回值作纪元。§Invoke-CardAction
  $state = if ($action -eq 'stop') { '停止中' } else { '启动中' }
  Set-CardTransition $card $state 0 $now
  $card.PendingEpoch = (Send-ServiceCommand $name $action)
  Set-StatusMessage "$name $state..."
}

# 双击/双击式入口：按当前状态推导动作（启动中的服务再点是停止，反之亦然）
function Invoke-CardToggle($card, [string]$source='DoubleClick') {
  $action = if ($card.ST -eq '运行中') { 'stop' } else { 'start' }
  Invoke-CardAction $card $action $source
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
  $open.Add_Click({ Open-PanelUrl ([string]$this.Tag) })
  # 「启动」和「关闭」是两个方向，拆成两个按钮——合成一个要靠读文字才知道能干什么。§New-Card
  $rightBtns=New-Object System.Windows.Controls.StackPanel -Property @{Orientation='Horizontal'; HorizontalAlignment='Right'}
  # 两个按钮同尺寸：它们是对等的两个方向，尺寸差会让「关闭」看起来比「启动」轻。
  $btnStop=New-Object System.Windows.Controls.Button -Property @{
    Content='关闭'; FontFamily=$script:cjkFont; FontSize=12; Padding='14,6'; Margin='0,0,8,0'
    MinWidth=82; IsEnabled=$false
  }
  $btn=New-Object System.Windows.Controls.Button -Property @{
    Content='启动'; FontFamily=$script:cjkFont; FontSize=12; Padding='14,6'
    MinWidth=82; IsEnabled=$false
  }
  [void]$rightBtns.Children.Add($btnStop); [void]$rightBtns.Children.Add($btn)
  [void]$actions.Children.Add($open); [void]$actions.Children.Add($rightBtns)
  [void]$grid.Children.Add($actions); [System.Windows.Controls.Grid]::SetRow($actions,3)
  $border.Child=$grid

  # 防抖状态（挂在 Border 上）
  $border | Add-Member -NotePropertyMembers @{
    SvcName=$name
    ST='查询中'; LastToggle=[datetime]::MinValue; ReadyToToggle=$false
    PendingEpoch=0
    # PrevST/PrevH 留档进入过渡态前的终态（失败时原样放回）；TransitionAt 是超时起算点。
    H=''; PrevST='未知'; PrevH=''; TransitionAt=[datetime]::MinValue
    TransitionStartedAt=[datetime]::MinValue
    # 进入当前终态的时刻（运行中=启动成功的时间；已停止=停下的时间），供卡片上的时长显示
    StateSince=[datetime]::MinValue
    # 首次看到「运行中但健康不通过」的时刻；恢复健康或离开运行中即清零。
    # 用来区分「还在冷启动」与「已经卡死」——见 Update-CardData 的等待中/无响应判定。
    UnhealthySince=[datetime]::MinValue
    # 连续健康探测为「正常」的次数。抖动（不健康→正常→不健康）不该清零累计，
    # 连续两次正常才算真恢复——见 Update-CardData。
    HealthyStreak=0
    # LblUp 的正文（健康文案），时钟只在它后面追加后缀，不重算
    LblUpBase='正在获取服务状态'
    # per-service 过渡态超时（services.json 的 toggleTimeoutMs），缺省用全局
    ToggleTimeoutMs=$(Resolve-ToggleTimeoutMs $info)
    Dot=$dot; LblSt=$lblSt; LblUp=$lblUp; Btn=$btn; BtnStop=$btnStop
    PortText=$portText; Endpoint=$endpoint; OpenBtn=$open
  }
  # 按钮持有卡片引用，Click 里直接取，省得爬 VisualTree
  $btn.Tag = $border

  $border.Add_MouseLeftButtonDown({
    param($sender,$eventArgs)
    if ($eventArgs.ClickCount -ge 2) { Invoke-CardToggle $sender 'DoubleClick' }
  })
  $btn.Add_Click({ Invoke-CardAction $this.Tag 'start' })
  $btnStop.Tag = $border
  $btnStop.Add_Click({ Invoke-CardAction $this.Tag 'stop' })

  # 右键菜单
  $border.Add_MouseRightButtonDown({
    param($s,$e)
    $n = $s.SvcName
    $ctx = New-Object System.Windows.Controls.ContextMenu
    $items = @(@('启动','start'),@('停止','stop'),@('重启','restart'),@('面板','open'),@('日志','log'),@('安全检查','security'),@('删除','remove'))
    foreach ($d in $items) {
      # Tag 存结构而不是 'act|name' 拼串：服务名允许的字符集不含 |，但配置是手写的，
      # 名字里带 | 时拼串会把右键动作打偏到截断后的另一个服务上。
      $mi = New-Object System.Windows.Controls.MenuItem -Property @{Header=$d[0]; Tag=@{act=$d[1]; name=$n}}
      if ($d[1] -eq 'remove') { $mi.Foreground = $script:T.Danger }
      $mi.Add_Click({
        $act = $this.Tag.act; $n = $this.Tag.name
        switch ($act) {
          # 右键是逃生口：绕过卡片按钮的状态门闩，直接下发——服务卡在 StopPending 时
          # 这是唯一还能下命令的入口（PROJECT.md 已知限制里承诺过）。失败回执不会错误
          # 回滚别人的过渡态，那由 Update-CardData 的 epoch 归属判断兜住，不靠这里拦。
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

# 刷新缓存卡片的端口/URL/Tag（配置变更命中缓存时）。New-Card 把它们固化进控件，不复用会过期。§Update-CardInfo
function Update-CardInfo([string]$name, $info){
  if (-not $script:cards.ContainsKey($name)) { return }
  $c = $script:cards[$name]
  $c.ToggleTimeoutMs = Resolve-ToggleTimeoutMs $info
  $c.PortText.Text = ":$($info.port)"
  $c.Endpoint.Text = $info.url
  $c.Endpoint.ToolTip = $info.url
  $c.OpenBtn.Tag = $info.url
  $c.OpenBtn.IsEnabled = (-not [string]::IsNullOrWhiteSpace($info.url))
}

# 更新卡片数据（DispatcherTimer 调用）。$item.done 分流：回执走 -ack，探测走普通分支。§Update-CardData
function Update-CardData([string]$n,[string]$st,[string]$h,[int]$e=0,[switch]$ack,[bool]$ok=$true){
  if (-not $script:cards.ContainsKey($n)) { return }
  $c = $script:cards[$n]
  if ($ack) {
    if ($e -lt $c.PendingEpoch) { return }
    if (-not $ok) {
      # 只有回执对应的就是卡片当前那条命令时才回滚。右键启停的 epoch 恒大于 PendingEpoch，
      # 它的失败不该把别人的过渡态回滚掉——那会把「停止中」刷成「运行中」，而停止命令仍在途。
      if ($e -ne $c.PendingEpoch -or $c.TransitionAt -eq [datetime]::MinValue) {
        Update-CardButtons $c
        return
      }
      Set-CardRollback $c; return
    }
    # 成功回执：按当前状态重算门闩，硬置 $true 会绕过健康门闩
    $c.LastToggle = [datetime]::Now
    Update-CardButtons $c
    return
  }
  $timedOut = Test-TransitionTimedOut $c ([datetime]::Now)
  if ($c.ST -eq '删除中') {
    if (-not $timedOut) { return }
    Set-CardRollback $c '未知' ''
    return
  }
  # 方向守卫：只保护命令驱动的过渡态；探测驱动的若也丢弃，启动失败会卡死（H1）
  $commandDriven = $c.TransitionAt -ne [datetime]::MinValue
  # 探测报同一状态 → 服务还在动，刷新 TransitionAt，逃生阈值从最后一次看到它在动起算
  if (-not $timedOut -and $commandDriven -and $st -eq $c.ST) { $c.TransitionAt = [datetime]::Now }
  $transitionExpect = @{ '启动中' = '运行中'; '停止中' = '已停止' }
  if (-not $timedOut -and $commandDriven -and $transitionExpect.ContainsKey($c.ST)) {
    $expected = $transitionExpect[$c.ST]
    if ($st -ne $expected -and $st -notin @('未安装','未知')) { return }
  }
  if ($timedOut) { $c.PendingEpoch=0 }  # 逃生后清纪元，避免迟到回执再搅一次
  # 离开过渡态复位 TransitionAt，否则旧时间戳会让后续探测驱动的过渡态被误判成命令驱动（M1）
  if ($c.ST -in @('启动中','停止中') -and $st -notin @('启动中','停止中')) {
    $c.TransitionAt = [datetime]::MinValue
  }
  $prevST = $c.ST
  $c.ST = $st
  # 只在状态变化时重记起算点；首次观测不算变化，否则一打开就跳「已运行 3 秒」。
  # 只有「查询中」是首帧——「未知」是探测出错/删除收敛后的真实状态，从它转进运行中该起算。
  if ($st -ne $prevST) {
    $c.StateSince = if ($prevST -eq '查询中') { [datetime]::MinValue } else { [datetime]::Now }
  }
  $c.H = $h   # 记住生效的健康文案：进入下一次过渡态时由 Set-CardTransition 留档为 PrevH
  $running = $st -eq '运行中'
  $healthy = $h -eq '正常'
  # 服务进程在、但健康探测还没通过（冷启动、端口未监听、HTTP 超时）：先显示「等待中」。
  # 等太久就不该再叫「等待中」——那是服务已经卡住，显示「无响应」+ 红点。
  # UnhealthySince 只在「运行中且不健康」时累计，恢复健康或离开运行中立刻清零。
  if ($running -and -not $healthy) {
    $c.HealthyStreak = 0
    if (-not $c.UnhealthySince -or $c.UnhealthySince -eq [datetime]::MinValue) { $c.UnhealthySince = [datetime]::Now }
  } elseif ($running) {
    # 抖动（不健康 → 一次正常 → 不健康）不该清零累计，否则永远升不到「无响应」。
    # 连续两次正常才算真恢复：4 秒一拍，相当于多等一拍。
    $c.HealthyStreak = [int]$c.HealthyStreak + 1
    if ($c.HealthyStreak -ge 2) { $c.UnhealthySince = [datetime]::MinValue }
  } else {
    $c.UnhealthySince = [datetime]::MinValue   # 离开运行中立即清零，不等连击
    $c.HealthyStreak = 0
  }
  $waitedMs = if ($c.UnhealthySince -and $c.UnhealthySince -ne [datetime]::MinValue) {
    ([datetime]::Now - $c.UnhealthySince).TotalMilliseconds
  } else { 0 }
  if ($waitedMs -lt 0) { $waitedMs = 0 }   # 墙钟回拨
  # 显示用的「健康」：从等待中恢复要连续两次正常，否则单次探测报正常会让颜色闪一下再变回去。
  $settledHealthy = $healthy -and (-not $c.UnhealthySince -or $c.UnhealthySince -eq [datetime]::MinValue)
  $stuck = $running -and (-not $healthy) -and $waitedMs -ge $script:WAIT_HEALTHY_TIMEOUT_MS
  $displaySt = if ($running -and -not $settledHealthy) { if ($stuck) { '无响应' } else { '等待中' } } else { $st }
  $dotColor = switch ($st) {
    '运行中' { if ($settledHealthy) { 'Green' } elseif ($stuck) { 'Red' } else { 'Orange' } }
    { $_ -in @('已停止','未安装') } { 'Gray' }
    default { 'Orange' }
  }
  # 静态画刷已经冻结；这里只替换引用，不修改画刷颜色。
  $brush = [System.Windows.Media.Brushes]::$dotColor
  $c.Dot.Fill = $brush
  $c.LblSt.Text = $displaySt
  $c.LblSt.Foreground = $brush

  # 健康文字：正文存进 LblUpBase，时长后缀由 Update-CardClock 追加（它每帧跑）。
  $c.LblUpBase = if ($running -and $settledHealthy) {
    '服务响应正常'
  } elseif ($running) {
    $h
  } elseif ($st -eq '已停止') {
    '随时可以启动'
  } elseif ($st -eq '已暂停') {
    # 暂停态按钮都不可用，恢复走右键「重启」（先 stop 再 start，SCM 接受）
    '服务已暂停，可用右键「重启」尝试恢复'
  } elseif ($h) {
    $h
  } else {
    '等待服务状态更新'
  }
  Update-CardClock $c ([datetime]::Now)
  Update-CardButtons $c
}
