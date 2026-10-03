# lib/util.ps1 — 配置持久化 · NSSM 操作 · 安全检查 · 日志
#
# 【本模块的作用域约定】本文件的函数体直接读调用方作用域里的 $cfg 与 $logDir
# （dot-source 时由 service-manager-gui.ps1 / 各测试脚本赋值），不是模块级变量。
# 因此：(1) 调用方必须在 dot-source 之后赋值，否则函数读到 $null；
#       (2) 本模块的函数**不得**把参数命名为 $cfg / $logDir 等约定变量——PowerShell
#           变量名大小写不敏感，参数会遮蔽同名外层变量，回落逻辑会静默失效。
#           历史事故：Get-LogFiles 曾把参数叫 $LogDir，遮蔽了外层 $logDir，
#           GUI 日志下拉框自上线起一直为空（d442fcf 修复）。

# ---- 配置层（services.json 是 SSOT，services.example.json 是兜底）----
# 兜底直接读仓里的示例清单，不在源码里再抄一份服务名（避免双源漂移）。
$script:configWarning = $null

function Read-SvcFile([string]$path){
  $j = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
  $o = [ordered]@{}; foreach ($k in $j.Keys) {
    $p = [int]$j[$k].port; $u = [string]$j[$k].url
    if ($p -lt 1 -or $p -gt 65535) { throw "$k 端口非法: $p" }
    $o[$k] = @{ port = $p; url = $u }
  }
  $o
}

function Load-Svc {
  if (Test-Path $cfg) {
    try { return Read-SvcFile $cfg }
    catch { $script:configWarning = $_.Exception.Message }
  }
  # 兜底：services.json 缺失或损坏时读示例清单，让首次运行有内容可看
  $example = Join-Path (Split-Path $cfg -Parent) 'services.example.json'
  if (Test-Path $example) {
    try { return Read-SvcFile $example }
    catch { if (-not $script:configWarning) { $script:configWarning = $_.Exception.Message } }
  }
  [ordered]@{}
}

# 原子写回：$PID.$guid.tmp → Replace（避免写一半停电留下半截 JSON）
function Save-Svc($s) {
  $json  = $s | ConvertTo-Json -Depth 5
  $tmp   = "$cfg.$PID.$([guid]::NewGuid()).tmp"
  [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
  try {
    # [NullString]::Value 传真正的 CLR null；直接写 $null 会被 PowerShell 绑成空字符串，
    # 触发 File.Replace「The path is empty」（备份路径被当成非空字符串校验）。
    if (Test-Path -LiteralPath $cfg) { [IO.File]::Replace($tmp, $cfg, [NullString]::Value) }
    else { [IO.File]::Move($tmp, $cfg) }
  } finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue }
  }
}

# 命令纪元：每次 Send-ServiceCommand 递增，随命令对象入队；后台执行完把同一 epoch 跟着
# 结果回 UI。Update-CardData 据此过滤在途旧探测——过渡态期间只接受 epoch ≥ 卡片
# PendingEpoch 的回执，旧探测（无 epoch）直接丢弃，不再靠「方向匹配」做症状层补丁。
$script:cmdEpoch = 0

# 所有 GUI 命令统一入队并唤醒后台；队列保留 FIFO，事件只负责结束空闲等待。
function Send-ServiceCommand([string]$name,[string]$action) {
  $script:cmdEpoch++
  $e = $script:cmdEpoch
  $script:cmdQueue.Enqueue([pscustomobject]@{n=$name;act=$action;e=$e})
  [void]$script:sync.wake.Set()
  $e
}

# NSSM set 包装：失败抛错
function nssm-set([string]$n,[string]$k,[Parameter(ValueFromRemainingArguments=$true)][object[]]$v){
  $o=& $script:nssm set $n $k @v 2>&1
  if($LASTEXITCODE -ne 0){ throw "NSSM set $k 失败($LASTEXITCODE): $($o -join ' ')" }
}

# ---- 安全检查（借鉴 PSSM：路径引号加固 + 目录 ACL 过宽）----
# 纯解析：从 Win32_Service PathName 提取 exe 目录与引号状态，不碰 UI 也不抛错。
function Resolve-ServiceExeDir([string]$path){
  if (-not $path) { return @{ dir = ''; quoted = $false } }
  $quoted = $path.StartsWith('"')
  # 去首尾引号，匹配到首个 .exe 的路径段，取父路径
  $clean = $path.Trim('"')
  if ($clean -match '^[a-zA-Z]:\\.*?\.exe') { $clean = $matches[0] }
  elseif ($clean.Contains(' ')) { $clean = ($clean -split '(?<=\.exe)\s')[0] }
  $dir = if ($clean) { try { Split-Path $clean -Parent -EA Stop } catch { '' } } else { '' }
  @{ dir = $dir; quoted = $quoted }
}

function Show-SecurityCheck([string]$n){
  try {
    $ci = Get-CimInstance Win32_Service -Filter "Name='$n'" -EA Stop
  } catch {
    [System.Windows.MessageBox]::Show("无法查询 $n 的服务信息。`n$($_.Exception.Message)",'错误','OK','Error') | Out-Null
    return
  }
  $path = [string]$ci.PathName
  if (-not $path) {
    [System.Windows.MessageBox]::Show("无法读取 $n 的可执行路径。",'错误','OK','Error') | Out-Null
    return
  }
  $r = Resolve-ServiceExeDir $path
  $dir = $r.dir; $quoted = $r.quoted
  $permissive = '否'
  if ($dir -and (Test-Path $dir)) {
    try {
      $acl = Get-Acl -Path $dir
      foreach ($a in $acl.Access) {
        if (@('BUILTIN\Users','Everyone','Users') -contains $a.IdentityReference.Value -and $a.FileSystemRights.ToString() -match 'Write|Modify|FullControl') { $permissive = '是'; break }
      }
    } catch { $permissive = '未知（无法读取 ACL）' }
  }
  $qTxt = if($quoted){'是（已加固）'}else{'否（路径含空格时有提权风险）'}
  $msg = "$n`n`n路径: $path`n`n引号加固: $qTxt`n目录: $dir`n目录 ACL 过宽: $permissive"
  [System.Windows.MessageBox]::Show($msg,"$n 安全检查",'OK',$(if($quoted -and $permissive -eq '否'){'Information'}else{'Warning'})) | Out-Null
}

# 枚举当前 + 轮转日志：out/err 是当前，out-YYYYMMDDHHMMSS.log / err-*.log 是轮转
# 服务名允许含 . 与 -（Test-SvcInput 的 [A-Za-z0-9_.-]），正则里这些是元字符——
# 必须先 [regex]::Escape 再插，否则 "My.Service" 的 . 会匹配任意字符，跨服务串台。
# 参数名必须是 $LogPath 不能是 $LogDir：PowerShell 变量名大小写不敏感，参数一旦叫
# $LogDir 就会遮蔽同名（不区分大小写）的外层 $logDir，下面那句回落变成自己赋给自己，
# GUI 的单参调用永远拿到 $null。改名后回落才能经动态作用域读到调用方的 $logDir。
function Get-LogFiles([string]$n, [string]$LogPath){
  if(-not $LogPath){ $LogPath = $logDir }
  if(-not $LogPath -or -not (Test-Path -LiteralPath $LogPath)){ return @() }
  $esc = [regex]::Escape($n)
  $current = @()
  $rotated = @()
  # -Filter 走 Windows shell 通配（非正则），点号原样匹配；用 $n 不用 $esc。
  $pattern = "{0}.*.log" -f $n
  $files = @(Get-ChildItem -LiteralPath $LogPath -Filter $pattern -File -EA SilentlyContinue |
    Sort-Object LastWriteTime -Descending)
  foreach ($f in $files) {
    $base = $f.BaseName  # e.g. "MyAPI.out" or "MyAPI.out-20260930120000"
    # 锚到行首：服务名本身的点号已转义，不会吞掉相邻服务名；行尾按 out/err 或轮转后缀分档。
    if ($base -match "^$esc\.(out|err)$") {
      $current += [pscustomobject]@{ Path=$f.FullName; Label="$($matches[1]) (当前)" }
    } elseif ($base -match "^$esc\.(out|err)-") {
      $rotated += [pscustomobject]@{ Path=$f.FullName; Label="$($matches[1]) 轮转 $($f.LastWriteTime.ToString('MM-dd HH:mm'))" }
    }
  }
  # 当前在前，轮转按时间倒序
  @($current) + @($rotated)
}

# ---- 日志查看器（闭包 hashtable 持久切换状态）----
# 发现 5：除当前 .out.log / .err.log 外，加轮转历史下拉（nssm AppRotateFiles 产生的
# .out-*.log / .err-*.log）。22 个轮转文件此前在 GUI 中不可见。
function Show-Log([string]$n, $owner){
  $f2 = New-Object System.Windows.Window -Property @{
    Title = "$n 日志"; Width = 760; Height = 520; WindowStartupLocation='CenterOwner'
    Background = [System.Windows.Media.Brushes]::White
  }
  $box = New-Object System.Windows.Controls.TextBox -Property @{
    IsReadOnly = $true; FontFamily = $script:cjkFont; FontSize = 10
    VerticalScrollBarVisibility = 'Auto'; TextWrapping = 'NoWrap'
    Background = [System.Windows.Media.Brushes]::White; Foreground = [System.Windows.Media.Brushes]::Black
  }
  $lt = New-Object System.Windows.Controls.StackPanel -Property @{ Orientation='Horizontal' }
  # 当前日志 + 轮转历史下拉；切换时重新加载
  $state = @{ File = $null }
  $combo = New-Object System.Windows.Controls.ComboBox -Property @{ Margin='4,2'; MinWidth=220 }
  $refreshBtn = New-Object System.Windows.Controls.Button -Property @{ Content='🔄 刷新'; Margin='4,2' }

  $load = {
    $box.Clear()
    $f3 = $state.File
    if (-not $f3 -or -not (Test-Path -LiteralPath $f3)) { $box.Text = "无日志"; return }
    # 逐行读，固定容量队列只留最后 500 行——避免把整个大日志物化到内存
    $tail = [System.Collections.Generic.Queue[string]]::new(500)
    foreach ($l in [System.IO.File]::ReadLines($f3)) {
      if ($tail.Count -ge 500) { [void]$tail.Dequeue() }
      $tail.Enqueue($l)
    }
    $box.Text = ($tail -join "`r`n")
    $box.ScrollToEnd()
  }.GetNewClosure()

  # 初始填充与刷新共用：枚举文件 → 建 ComboBoxItem → 选中 oldPath（或首项）
  $fillCombo = {
    param($selectPath)
    $combo.Items.Clear()
    $files = Get-LogFiles $n
    if ($files.Count -eq 0) {
      [void]$combo.Items.Add((New-Object System.Windows.Controls.ComboBoxItem -Property @{Content='无日志'; Tag=''}))
      $state.File = $null
    } else {
      $selIdx = 0
      for ($i=0; $i -lt $files.Count; $i++) {
        $item = New-Object System.Windows.Controls.ComboBoxItem -Property @{ Content=$files[$i].Label; Tag=$files[$i].Path }
        [void]$combo.Items.Add($item)
        if ($selectPath -and $files[$i].Path -eq $selectPath) { $selIdx = $i }
      }
      $combo.SelectedIndex = $selIdx
      $state.File = $files[$selIdx].Path
    }
  }.GetNewClosure()

  & $fillCombo $null
  $combo.Add_SelectionChanged({
    $item = $combo.SelectedItem
    if ($item -and $item.Tag) { $state.File = [string]$item.Tag; & $load }
  }.GetNewClosure())
  $refreshBtn.Add_Click({
    # 刷新下拉（轮转文件可能新增）并重载当前
    & $fillCombo $state.File
    & $load
  }.GetNewClosure())

  [void]$lt.Children.Add($combo); [void]$lt.Children.Add($refreshBtn)
  $dock = New-Object System.Windows.Controls.DockPanel
  $dock.LastChildFill = $true
  $lt.SetValue([System.Windows.Controls.DockPanel]::DockProperty, [System.Windows.Controls.Dock]::Top)
  [void]$dock.Children.Add($lt)
  [void]$dock.Children.Add($box)
  $f2.Content = $dock
  & $load
  $f2.Owner = $owner
  $f2.ShowDialog() | Out-Null
}
