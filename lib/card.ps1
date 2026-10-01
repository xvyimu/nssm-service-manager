# lib/card.ps1 — 服务卡片：名称与端口、健康状态、面板入口和启停
$script:TOGGLE_COOLDOWN_MS = 8000

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

  $card.ST=if ($action -eq 'stop') { '停止中' } else { '启动中' }
  $card.LastToggle=$now
  $card.Btn.IsEnabled=$false
  $card.ReadyToToggle=$false
  $card.LblSt.Text=$card.ST
  $card.LblSt.Foreground=[System.Windows.Media.Brushes]::Orange
  $card.Dot.Fill=[System.Windows.Media.Brushes]::Orange
  $card.Btn.Content=$card.ST
  Send-ServiceCommand $name $action
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
    SvcName=$name; Port=$info.port; Url=$info.url
    ST='查询中'; HT=''; LastToggle=[datetime]::MinValue; ReadyToToggle=$false
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
    foreach ($d in @(@('启动','start'),@('停止','stop'),@('重启','restart'),@('面板','open'),@('日志','log'),@('安全检查','security'),@('删除','remove'))) {
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
  $c.Port = $info.port; $c.Url = $info.url
  $c.PortText.Text = ":$($info.port)"
  $c.Endpoint.Text = $info.url
  $c.Endpoint.ToolTip = $info.url
  $c.OpenBtn.Tag = $info.url
  $c.OpenBtn.IsEnabled = (-not [string]::IsNullOrWhiteSpace($info.url))
}

# 更新卡片数据（由 DispatcherTimer 调用）
function Update-CardData([string]$n,[string]$st,[string]$h){
  if (-not $script:cards.ContainsKey($n)) { return }
  $c = $script:cards[$n]
  # 过渡态保护（发现 3）：卡片处于启动中/停止中时，在途的旧探测结果不应覆盖
  # 用户刚刚触发的过渡态，也不应重新启用按钮——否则慢停止期间显示与实际不符。
  # 按方向判期望终态：启动中只接受运行中收尾，停止中只接受已停止收尾；
  # 未安装/未知属异常态（服务被卸载或出错），允许通过。
  # Altitude 注：这是症状层补丁，根因是缺少命令纪元；个人工具暂不引入。
  $transitionExpect = @{ '启动中' = '运行中'; '停止中' = '已停止' }
  if ($transitionExpect.ContainsKey($c.ST)) {
    $expected = $transitionExpect[$c.ST]
    if ($st -ne $expected -and $st -notin @('未安装','未知')) { return }
  }
  $c.ST = $st; $c.HT = $h
  $running = $st -eq '运行中'
  $healthy = $h -eq '正常'
  # 状态颜色映射
  $dotColor = switch ($st) {
    '运行中' { if ($h -eq '正常') { 'Green' } elseif ($h -eq '超时') { 'Orange' } else { 'Red' } }
    '已停止' { 'Gray' }
    '未安装' { 'Gray' }
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
