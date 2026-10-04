# lib/card.ps1 — 服务卡片：名称与端口、健康状态、面板入口和启停
# 自加载 config：测试 dot-source 本模块时未必先加载 config.ps1，此处自洽
if (-not $script:config) { . (Join-Path $PSScriptRoot 'config.ps1') }
$script:TOGGLE_COOLDOWN_MS = [int]$script:config.ToggleCooldownMs

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
    # wsl 类型无健康门闩（IsWsl 时 ReadyToToggle 在运行中即为 true），此处对 wsl 不拦截
    if (-not [bool]$card.IsWsl) {
      $detail=if ($detailed) { '（健康非正常）' } else { '' }
      $script:statusBar.Text="$name 服务未就绪$detail，暂不能关闭"
      return
    }
  }

  $card.ST=if ($action -eq 'stop') { '停止中' } else { '启动中' }
  $card.LastToggle=$now
  $card.Btn.IsEnabled=$false
  $card.ReadyToToggle=$false
  $card.LblSt.Text=$card.ST
  $card.LblSt.Foreground=[System.Windows.Media.Brushes]::Orange
  $card.Dot.Fill=[System.Windows.Media.Brushes]::Orange
  $card.Btn.Content=$card.ST
  # 记录本次命令纪元：Update-CardData 只接受 epoch ≥ 这个值的结果/回执。
  # 旧探测（epoch 更小或为 0）在过渡态期间直接丢，不再靠方向匹配做症状层补丁。
  $card.PendingEpoch = (Send-ServiceCommand $name $action)
  $script:statusBar.Text="$name $($card.ST)..."
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
  # wsl 类型不显示端口徽章和 URL 端点（无端口无面板）——用发行版名替代端口徽章，
  # 用空字符串隐藏 endpoint 行（Text 为空时 TextBlock 不占可见空间）。
  $isWsl = [string]$info.type -eq 'wsl'
  $port=New-Object System.Windows.Controls.Border -Property @{Background=$script:T.PortBg; CornerRadius=4; Padding='7,3'; VerticalAlignment='Center'}
  $portText=New-Object System.Windows.Controls.TextBlock -Property @{Text=$(if($isWsl){$info.distro}else{":$($info.port)"}); FontFamily=$script:fontMono; FontSize=12; Foreground=$script:T.Dim}
  $port.Child=$portText
  [void]$heading.Children.Add($lblName); [void]$heading.Children.Add($port)
  [System.Windows.Controls.Grid]::SetColumn($port,1)
  [void]$grid.Children.Add($heading)

  $endpointText = if($isWsl){''}else{$info.url}
  $endpoint=New-Object System.Windows.Controls.TextBlock -Property @{
    Text=$endpointText; FontFamily=$script:fontMono; FontSize=12; Foreground=$script:T.Dim
    Margin='0,8,0,0'; TextTrimming='CharacterEllipsis'; ToolTip=$endpointText
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
  # wsl 类型无面板可开，隐藏「打开面板」按钮（Collapse 不占空间）
  if ($isWsl) { $open.Visibility = [System.Windows.Visibility]::Collapsed }
  $open.Add_Click({ if ($this.Tag) { Start-Process ([string]$this.Tag) } })
  $btn=New-Object System.Windows.Controls.Button -Property @{
    Content='启动'; FontFamily=$script:cjkFont; FontSize=12; Padding='14,6'
    HorizontalAlignment='Right'; MinWidth=82; IsEnabled=$false
  }
  [void]$actions.Children.Add($open); [void]$actions.Children.Add($btn)
  [void]$grid.Children.Add($actions); [System.Windows.Controls.Grid]::SetRow($actions,3)
  $border.Child=$grid

  # 防抖状态（挂在 Border 上）
  $border | Add-Member -NotePropertyMembers @{
    SvcName=$name; Port=$info.port; Url=$info.url; Type=[string]$info.type; Distro=[string]$info.distro
    ST='查询中'; HT=''; LastToggle=[datetime]::MinValue; ReadyToToggle=$false
    PendingEpoch=0
    Dot=$dot; LblSt=$lblSt; LblUp=$lblUp; Btn=$btn
    PortText=$portText; Endpoint=$endpoint; OpenBtn=$open; IsWsl=$isWsl
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
    $isWsl = [bool]$s.IsWsl
    $ctx = New-Object System.Windows.Controls.ContextMenu
    # wsl 类型不支持重启/日志/安全检查（非 NSSM 服务，这些操作无意义），只留启停与删除
    $items = if ($isWsl) {
      @(@('启动','start'),@('停止','stop'),@('删除','remove'))
    } else {
      @(@('启动','start'),@('停止','stop'),@('重启','restart'),@('面板','open'),@('日志','log'),@('安全检查','security'),@('删除','remove'))
    }
    foreach ($d in $items) {
      $mi = New-Object System.Windows.Controls.MenuItem -Property @{Header=$d[0]; Tag=$d[1]+'|'+$n}
      if ($d[1] -eq 'remove') { $mi.Foreground = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(192,57,43)) }
      $mi.Add_Click({
        $parts = $this.Tag -split '\|'; $act = $parts[0]; $n = $parts[1]
        switch ($act) {
          { $_ -in @('start','stop','restart') } { Send-ServiceCommand $n $act }
          'open'    { if ($script:svc[$n].url) { Start-Process $script:svc[$n].url } }
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
  $c.Port = $info.port; $c.Url = $info.url; $c.Type = [string]$info.type; $c.Distro = [string]$info.distro
  $isWsl = [string]$info.type -eq 'wsl'
  # IsWsl 是 New-Card 里从 type 派生的缓存值，配置变更命中缓存时必须同步刷新——
  # 否则 Update-CardData / Invoke-CardToggle 读到旧值，WSL 卡片走 NSSM 健康门闩逻辑。
  $c.IsWsl = $isWsl
  $c.PortText.Text = if($isWsl){$info.distro}else{":$($info.port)"}
  $c.Endpoint.Text = if($isWsl){''}else{$info.url}
  $c.Endpoint.ToolTip = if($isWsl){''}else{$info.url}
  $c.OpenBtn.Tag = $info.url
  $c.OpenBtn.IsEnabled = (-not [string]::IsNullOrWhiteSpace($info.url))
  $c.OpenBtn.Visibility = if($isWsl){[System.Windows.Visibility]::Collapsed}else{[System.Windows.Visibility]::Visible}
}

# 更新卡片数据（由 DispatcherTimer 调用）
# 调用方据 $item.done 分流：命令完成回执走 -ack 分支，探测结果走普通分支。
# 普通探测结果不带 epoch（视为 0）；过渡态期间 PendingEpoch>0 时旧探测一律丢弃，
# 直到命令完成回执解封按钮，下一轮探测自然落到终态。原「方向匹配」症状层补丁消除。
function Update-CardData([string]$n,[string]$st,[string]$h,[int]$e=0,[switch]$ack){
  if (-not $script:cards.ContainsKey($n)) { return }
  $c = $script:cards[$n]
  if ($ack) {
    # 命令完成回执：epoch 低于卡片当前则丢弃（旧命令的回执不应解封新命令的过渡态）。
    if ($e -lt $c.PendingEpoch) { return }
    $c.Btn.IsEnabled = $true
    $c.ReadyToToggle = $true
    $c.LastToggle = [datetime]::Now
    return
  }
  # 过渡态保护（发现 3）：卡片处于启动中/停止中时，在途的旧探测结果不应覆盖
  # 用户刚刚触发的过渡态，也不应重新启用按钮——否则慢停止期间显示与实际不符。
  # 按方向判期望终态：启动中只接受运行中收尾，停止中只接受已停止收尾；
  # 未安装/未知属异常态（服务被卸载或出错），允许通过。
  # 命令纪元（PendingEpoch）用于 ack 回执过滤：旧命令的回执不应解封新命令的过渡态。
  # 普通探测仍按方向匹配收尾——服务真正进入终态时应当让过渡态退出。
  $transitionExpect = @{ '启动中' = '运行中'; '停止中' = '已停止' }
  if ($transitionExpect.ContainsKey($c.ST)) {
    $expected = $transitionExpect[$c.ST]
    if ($st -ne $expected -and $st -notin @('未安装','未知')) { return }
  }
  $c.ST = $st; $c.HT = $h
  $running = $st -eq '运行中'
  # wsl 类型无 HTTP 健康探测——运行中即健康（绿），无「无响应/超时」分档
  $healthy = if ([bool]$c.IsWsl) { $running } else { $h -eq '正常' }
  # 状态颜色映射：运行中按健康分档（wsl 直接绿），停止/未安装统一灰，其余橙
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
  $c.LblUp.Text = if ([bool]$c.IsWsl) {
    # wsl 类型：运行中显示发行版名，已停止显示提示，其余沿用通用逻辑
    if ($running) { $c.Distro + ' 运行中' }
    elseif ($st -eq '已停止') { '随时可以启动' }
    else { $h }
  } elseif ($running -and $healthy) {
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
