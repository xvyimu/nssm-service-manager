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
function Test-TransitionTimedOut($card, [datetime]$now){
  if ($card.ST -notin @('启动中','停止中','删除中')) { return $false }
  if ($card.TransitionAt -eq [datetime]::MinValue) { return $false }
  ($now - $card.TransitionAt).TotalMilliseconds -ge $script:TOGGLE_TIMEOUT_MS
}

# 命令失败（回执 ok=false）时把卡片从过渡态放回原终态并解封按钮。
# 不能复用 Invoke-CardToggle 的方向推导：失败时服务状态没变，要的是「回到原样」。
function Set-CardRollback($card){
  if (-not $card) { return }
  $st=[string]$card.PrevST
  if ([string]::IsNullOrEmpty($st) -or $st -in @('启动中','停止中','删除中','查询中')) { $st='未知' }
  # 先落回原终态，再交给 Update-CardData 走常规渲染——否则过渡态守卫会按旧 ST 拦下这个值。
  $card.ST=$st
  $card.PendingEpoch=0          # 清纪元：失败命令的回执/旧探测不再干扰
  $card.TransitionAt=[datetime]::MinValue
  $card.LastToggle=[datetime]::MinValue  # 清冷却：用户刚吃了失败，应能立刻重试
  Update-CardData $card.SvcName $st $card.PrevH
}

# 按钮和双击共用校验与状态切换；仅保留各入口原有的反馈文案。
function Invoke-CardToggle($card, [string]$source='Button') {
  $name=$card.SvcName
  $state=$card.ST
  $now=[datetime]::Now
  $script:lastActionAt=$now
  $detailed=$source -eq 'DoubleClick'

  if ($state -in @('启动中','停止中')) {
    $script:statusBar.Text=if ($detailed) { "$name 正在切换中，请稍候" } else { "$name 正在切换中" }
    return
  }
  $elapsed=($now-$card.LastToggle).TotalMilliseconds
  if ($elapsed -lt $script:TOGGLE_COOLDOWN_MS) {
    $remaining=[math]::Ceiling(($script:TOGGLE_COOLDOWN_MS-$elapsed)/1000)
    $suffix=if ($detailed) { ' 再操作' } else { '' }
    $script:statusBar.Text="$name 请等待 ${remaining}s$suffix"
    return
  }
  if ($state -notin @('运行中','已停止')) {
    $script:statusBar.Text="$name 状态尚未就绪"
    return
  }
  $action=if ($state -eq '运行中') { 'stop' } else { 'start' }
  if ($action -eq 'stop' -and -not $card.ReadyToToggle) {
    $detail=if ($detailed) { '（健康非正常）' } else { '' }
    $script:statusBar.Text="$name 服务未就绪$detail，暂不能关闭"
    return
  }

  # 记录本次命令纪元：Update-CardData 只接受 epoch ≥ 这个值的结果/回执。
  # 旧探测（epoch 更小或为 0）在过渡态期间直接丢，不再靠方向匹配做症状层补丁。
  # 顺序与原实现一致：先置 UI 过渡态，再入队命令（入队返回值作纪元）。
  $state = if ($action -eq 'stop') { '停止中' } else { '启动中' }
  Set-CardTransition $card $state 0 $now
  $card.PendingEpoch = (Send-ServiceCommand $name $action)
  $script:statusBar.Text="$name $state..."
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
  $c.PortText.Text = ":$($info.port)"
  $c.Endpoint.Text = $info.url
  $c.Endpoint.ToolTip = $info.url
  $c.OpenBtn.Tag = $info.url
  $c.OpenBtn.IsEnabled = (-not [string]::IsNullOrWhiteSpace($info.url))
}

# 更新卡片数据（由 DispatcherTimer 调用）
# 调用方据 $item.done 分流：命令完成回执走 -ack 分支，探测结果走普通分支。
# 普通探测结果不带 epoch（视为 0）；过渡态期间 PendingEpoch>0 时旧探测一律丢弃，
# 直到命令完成回执解封按钮，下一轮探测自然落到终态。原「方向匹配」症状层补丁消除。
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
    if (-not $ok) { Set-CardRollback $c; return }
    $c.Btn.IsEnabled = $true
    $c.ReadyToToggle = $true
    $c.LastToggle = [datetime]::Now
    return
  }
  # 删除中：终态由 remove 回执决定（主脚本 ack 分支清 svc/cards + Render-Page），
  # 与启动/停止不同——它没有「期望终态」可等。期间探测每轮都到，且删除本就先 stop，
  # 探测必然先报「已停止」，随后可能报「未安装」——两者都只是过程中的中间态。
  # 故此处一律丢弃，不套用下面的方向匹配（否则卡片会从「删除中」闪回「已停止」
  # 并重新点亮按钮，用户还能对一个正在删除的服务下命令）。
  # 例外：超时逃生（见下）——回执彻底丢了时删除中同样不能永久卡住。
  $timedOut = Test-TransitionTimedOut $c ([datetime]::Now)
  if ($c.ST -eq '删除中' -and -not $timedOut) { return }
  # 过渡态保护（发现 3）：卡片处于启动中/停止中时，在途的旧探测结果不应覆盖
  # 用户刚刚触发的过渡态，也不应重新启用按钮——否则慢停止期间显示与实际不符。
  # 按方向判期望终态：启动中只接受运行中收尾，停止中只接受已停止收尾；
  # 未安装/未知属异常态（服务被卸载或出错），允许通过。
  # 命令纪元（PendingEpoch）用于 ack 回执过滤：旧命令的回执不应解封新命令的过渡态。
  # 普通探测仍按方向匹配收尾——服务真正进入终态时应当让过渡态退出。
  # 超时逃生（T1）：回执丢失时（后台异常退出/命令未入队），过渡态不能永久卡住——
  # 超过 ToggleTimeoutMs 后不再按方向过滤，直接接受到达的探测值并解封按钮。
  # 正常的慢启动/慢停止由 ack 回执解封，远早于这个上限，不会误触发。
  $transitionExpect = @{ '启动中' = '运行中'; '停止中' = '已停止' }
  if (-not $timedOut -and $transitionExpect.ContainsKey($c.ST)) {
    $expected = $transitionExpect[$c.ST]
    if ($st -ne $expected -and $st -notin @('未安装','未知')) { return }
  }
  if ($timedOut) { $c.PendingEpoch=0 }  # 逃生后清纪元，避免迟到回执再搅一次
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
  $c.ReadyToToggle = ($st -eq '已停止') -or ($running -and $healthy)
  $c.Btn.Content = if ($running) { '停止' } else { '启动' }
  $c.Btn.IsEnabled = $c.ReadyToToggle
}
