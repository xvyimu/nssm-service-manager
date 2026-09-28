# lib/util.ps1 — 配置持久化 · NSSM 操作 · 安全检查 · 日志

# ---- 配置层（services.json 是 SSOT，$default 是兜底）----
$script:default = [ordered]@{
  'NewAPI'=@{port=3000;url='http://127.0.0.1:3000'}; 'Router9'=@{port=20128;url='http://127.0.0.1:20128/dashboard'}
  'OmniRoute'=@{port=20129;url='http://127.0.0.1:20129/dashboard'}; 'CPA'=@{port=8317;url='http://127.0.0.1:8317/management.html'}
  'WorkBuddy2API'=@{port=7863;url='http://127.0.0.1:7863/panel/'}; 'TTSShim'=@{port=8001;url='http://127.0.0.1:8001/health'}
}
$script:configWarning = $null

function Load-Svc {
  if (-not (Test-Path $cfg)) { return $script:default }
  try {
    $j = Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    $o = [ordered]@{}; foreach ($k in $j.Keys) {
      $p = [int]$j[$k].port; $u = [string]$j[$k].url
      if ($p -lt 1 -or $p -gt 65535) { throw "$k 端口非法: $p" }
      $o[$k] = @{ port = $p; url = $u }
    }
    $o
  } catch {
    $script:configWarning = $_.Exception.Message
    $script:default
  }
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

# 所有 GUI 命令统一入队并唤醒后台；队列保留 FIFO，事件只负责结束空闲等待。
function Send-ServiceCommand([string]$name,[string]$action) {
  $script:cmdQueue.Enqueue([pscustomobject]@{n=$name;act=$action})
  [void]$script:sync.wake.Set()
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
    } catch {}
  }
  $qTxt = if($quoted){'是（已加固）'}else{'否（路径含空格时有提权风险）'}
  $msg = "$n`n`n路径: $path`n`n引号加固: $qTxt`n目录: $dir`n目录 ACL 过宽: $permissive"
  [System.Windows.MessageBox]::Show($msg,"$n 安全检查",'OK',$(if($quoted -and $permissive -eq '否'){'Information'}else{'Warning'})) | Out-Null
}

# ---- 日志查看器（闭包 hashtable 持久切换状态）----
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
  $state = @{ Current = 'out' }
  $load = {
    $box.Clear()
    $f3 = Join-Path $logDir "$n.$($state.Current).log"
    if (Test-Path $f3) {
      # 逐行读，固定容量队列只留最后 500 行——避免把整个大日志物化到内存
      # （Select-Object -Last 会枚举全部元素到集合，与 File.ReadLines 的惰性抵消）
      $tail = [System.Collections.Generic.Queue[string]]::new(500)
      foreach ($l in [System.IO.File]::ReadLines($f3)) {
        if ($tail.Count -ge 500) { [void]$tail.Dequeue() }
        $tail.Enqueue($l)
      }
      $box.Text = ($tail -join "`r`n")
      $box.ScrollToEnd()
    } else { $box.Text = "无日志: $f3" }
  }.GetNewClosure()
  foreach ($d in @(@('输出(out)','out'),@('错误(err)','err'),@('🔄 刷新','reload'))) {
    $b = New-Object System.Windows.Controls.Button -Property @{ Content=$d[0]; Margin='4,2'; Tag=$d[1] }
    $b.Add_Click({
      $tag = $this.Tag
      if ($tag -in 'out','err') { $state.Current = $tag }
      & $load
    }.GetNewClosure())
    [void]$lt.Children.Add($b)
  }
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
