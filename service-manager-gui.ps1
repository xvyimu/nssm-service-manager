#requires -Version 7.0
# service-manager-gui.ps1 — NSSM 服务管理 GUI（卡片式）
# 白色简洁 · 圆角卡片(全自绘) · 固定窗口 · 后台探测(不卡 UI) · 托盘 · 内置日志
# 配置: services.json · logs/

$root = $PSScriptRoot; $cfg = "$root\services.json"; $logDir = "$root\logs"; $nssm = "$env:USERPROFILE\scoop\apps\nssm\current\nssm.exe"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force $logDir | Out-Null }

# 提权
if (-not (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$MyInvocation.MyCommand.Path; exit
}
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# ---- 崩溃留痕：UI 线程异常 / 进程级异常 / 关闭原因 → logs\gui-crash.log ----
# pwsh 7 下 UI 线程事件处理器抛出的未捕获异常会直接杀掉整个进程（无任何对话框），
# 表现为「点着点着窗口就没了」。这里把异常改为记录后存活，方便事后定位。
$crashLog = "$logDir\gui-crash.log"
function Write-CrashLog([string]$m){
  try { [IO.File]::AppendAllText($crashLog, "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') $m`r`n", [Text.UTF8Encoding]::new($false)) } catch {}
}
[System.Windows.Forms.Application]::SetUnhandledExceptionMode('CatchException')
[System.Windows.Forms.Application]::add_ThreadException({ param($s,$e)
  Write-CrashLog "ThreadException: $($e.Exception.GetType().FullName): $($e.Exception.Message)`n$($e.Exception.StackTrace)"
})
[AppDomain]::CurrentDomain.add_UnhandledException({ param($s,$e)
  $x = $e.ExceptionObject
  Write-CrashLog "UnhandledException(terminating=$($e.IsTerminating)): $($x.GetType().FullName): $($x.Message)`n$($x.StackTrace)"
})

# ---- 主题 ----
$fReg = New-Object System.Drawing.Font('Microsoft YaHei UI',10)
$fB   = New-Object System.Drawing.Font('Microsoft YaHei UI',10,[System.Drawing.FontStyle]::Bold)
$fS   = New-Object System.Drawing.Font('Microsoft YaHei UI',9)
$fL   = New-Object System.Drawing.Font('Microsoft YaHei UI',11,[System.Drawing.FontStyle]::Bold)
$fMono= New-Object System.Drawing.Font('Consolas',9)
function C($r,$g,$b){ [System.Drawing.Color]::FromArgb($r,$g,$b) }
$T = [ordered]@{
  Bg  = C 250 250 252; Card = C 255 255 255; Brd = C 228 231 235; Fg = C 33 33 33; Dim = C 150 150 150
  Grn = C 52 168 83;  Red = C 234 67 53;      Org = C 251 146 60;  Gry= C 140 140 140; Acc= C 0 120 215; TBg= C 245 246 247
}

# ---- 服务清单 ----
$default = [ordered]@{
  'NewAPI'=@{port=3000;url='http://127.0.0.1:3000'}; 'Router9'=@{port=20128;url='http://127.0.0.1:20128/dashboard'}
  'OmniRoute'=@{port=20129;url='http://127.0.0.1:20129/dashboard'}; 'CPA'=@{port=8317;url='http://127.0.0.1:8317/management.html'}
  'WorkBuddy2API'=@{port=7863;url='http://127.0.0.1:7863/panel/'}; 'TTSShim'=@{port=8001;url='http://127.0.0.1:8001/health'}
}
$script:configWarning = $null
function Load-Svc {
  if (-not (Test-Path $cfg)) { return $default }
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
    $default
  }
}
function Save-Svc($s) {
  $json  = $s | ConvertTo-Json -Depth 5
  $tmp   = "$cfg.$PID.$([guid]::NewGuid()).tmp"
  [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
  try {
    if (Test-Path -LiteralPath $cfg) { [IO.File]::Replace($tmp, $cfg, $null) }
    else { [IO.File]::Move($tmp, $cfg) }
  } finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue }
  }
}
# 结构化服务状态（Get-Service，不依赖 sc.exe 文本）
$svcNames = @{ Stopped='已停止'; StartPending='启动中'; StopPending='停止中'; Running='运行中' }
function Get-Svc([string]$n) {
  try {
    $s = Get-Service -Name $n -EA Stop
    @{ name = ($svcNames[[string]$s.Status] ?? '未知'); code = [int]$s.Status }
  } catch {
    if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { @{ name='未安装'; code=-1 } } else { @{ name='未知'; code=0 } }
  }
}
# 端口监听校验（判断端口是否被占用，不验 PID 归属——NSSM 子进程监听端口而非 wrapper）
function Test-PortListen([int]$port) {
  $null -ne (Get-NetTCPConnection -State Listen -LocalPort $port -EA SilentlyContinue)
}

# ---- 主窗口（高度按实际服务数动态算）----
$script:svc = Load-Svc
$cols=3; $cardW=190; $cardH=132; $gap=14; $margin=16
$rows=[math]::Max(1,[math]::Ceiling($script:svc.Count/$cols))
$cliW=$margin*2 + $cols*$cardW + ($cols-1)*$gap
$cliH=$margin*2 + $rows*$cardH + ($rows-1)*$gap + 34 + 22
$form = New-Object System.Windows.Forms.Form -Property @{
  Text='服务管理'; ClientSize=New-Object System.Drawing.Size($cliW,$cliH); StartPosition='CenterScreen'
  Font=$fReg; BackColor=$T.Bg; ForeColor=$T.Fg; FormBorderStyle='FixedDialog'; MaximizeBox=$false; MinimizeBox=$false
}
function Resize-Form() {
  $r=[math]::Max(1,[math]::Ceiling($script:svc.Count/$cols))
  $form.ClientSize=New-Object System.Drawing.Size($margin*2 + $cols*$cardW + ($cols-1)*$gap, $margin*2 + $r*$cardH + ($r-1)*$gap + 34 + 22)
}

# 通用对话框
function New-Dialog([string]$title, $w, $h) {
  New-Object System.Windows.Forms.Form -Property @{
    Text=$title; Size=New-Object System.Drawing.Size($w,$h); StartPosition='CenterParent'
    FormBorderStyle='FixedDialog'; MaximizeBox=$false; Font=$fReg; BackColor=$T.Bg; ForeColor=$T.Fg
  }
}

# 工具栏
$rnd = New-Object System.Windows.Forms.ToolStripProfessionalRenderer(New-Object System.Windows.Forms.ProfessionalColorTable)
$rnd.ColorTable.GetType().GetProperties() | ?{ $_.Name -like 'ToolStrip*' -and $_.CanWrite } | %{ $_.SetValue($rnd.ColorTable,$T.TBg) }
$tb = New-Object System.Windows.Forms.ToolStrip -Property @{ Dock='Top'; BackColor=$T.TBg; GripStyle='Hidden'; Renderer=$rnd; Padding=New-Object System.Windows.Forms.Padding(6,3,6,3) }
$form.Controls.Add($tb)
# 注意：参数名不能用 $t —— PowerShell 变量名大小写不敏感，$t 会和主题表 $T 是同一个变量，
# 于是 ForeColor=$T.Fg / BackColor=$T.TBg 实际取到的是传入的按钮文字（string），
# Color 属性收到字符串 → "The value supplied is not valid, or the property is read-only"
# → New-TB 返回 null → Items.Add($null) 报歧义重载 → 四个工具栏按钮全 null、Add_Click 全失败
# → 工具栏整条空白（用户看到的「空白的地方」）。参数名改 $label 即解。
function New-TB([string]$label,[int]$w=70){ New-Object System.Windows.Forms.ToolStripButton -Property @{Text=$label;DisplayStyle='Text';AutoSize=$false;Width=$w;Height=28;Font=$fS;ForeColor=$T.Fg;BackColor=$T.TBg} }
function Add-TB([string]$key,[string]$text,[int]$w=70){ $b=New-TB $text $w; [void]$tb.Items.Add($b); $b }
$tbBtns=@{
  add    = Add-TB 'add' '➕ 添加'
  remove = Add-TB 'remove' '🗑 删除'
  refresh= Add-TB 'refresh' '🔄 刷新'
  msc    = Add-TB 'msc' 'services.msc' 100
}

# 状态栏
$ss = New-Object System.Windows.Forms.StatusStrip -Property @{ Dock='Bottom'; BackColor=$T.TBg }
$sLbl = New-Object System.Windows.Forms.ToolStripStatusLabel -Property @{ Text='就绪'; ForeColor=$T.Dim }
[void]$ss.Items.Add($sLbl); $form.Controls.Add($ss)

# 卡片容器（Dock=Fill，最后加入）
$panel = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{ Dock='Fill'; BackColor=$T.Bg; BorderStyle='None'; WrapContents=$true; FlowDirection='LeftToRight'; AutoScroll=$true; Padding=New-Object System.Windows.Forms.Padding($margin,$margin,$margin,$margin) }
$form.Controls.Add($panel)

# ---- 卡片（全自绘：圆角 Region + Paint 画文字/圆点，无子 Label）----
$script:cards = @{}
# 圆角路径
function New-RoundPath([int]$w,[int]$h,[int]$r){
  $p=New-Object System.Drawing.Drawing2D.GraphicsPath
  $p.AddArc(0,0,$r,$r,180,90); $p.AddArc($w-$r,0,$r,$r,270,90); $p.AddArc($w-$r,$h-$r,$r,$r,0,90); $p.AddArc(0,$h-$r,$r,$r,90,90)
  $p.CloseFigure(); $p
}
# 缓存笔刷
$brushes = @{ fg=New-Object System.Drawing.SolidBrush $T.Fg; dim=New-Object System.Drawing.SolidBrush $T.Dim; grn=New-Object System.Drawing.SolidBrush $T.Grn; red=New-Object System.Drawing.SolidBrush $T.Red; org=New-Object System.Drawing.SolidBrush $T.Org; gry=New-Object System.Drawing.SolidBrush $T.Gry; crd=New-Object System.Drawing.SolidBrush $T.Card }
$penBrd = New-Object System.Drawing.Pen $T.Brd,1
# 每张卡独立的路径副本——Region 各自持有独立 GraphicsPath，互不影响
function New-CardPath(){ New-RoundPath $cardW $cardH 8 }

function New-Card([string]$name, $info){
  $p = New-Object System.Windows.Forms.Panel -Property @{ Size=New-Object System.Drawing.Size($cardW,$cardH); BackColor=$T.Card; Margin=New-Object System.Windows.Forms.Padding(0,$gap,0,0); Cursor='Hand'; Tag=$name }
  $p.Region = New-Object System.Drawing.Region (New-CardPath)
  $p | Add-Member -NotePropertyName Port -NotePropertyValue $info.port
  $p | Add-Member -NotePropertyName Url  -NotePropertyValue $info.url
  $p | Add-Member -NotePropertyName ST   -NotePropertyValue '查询中'
  $p | Add-Member -NotePropertyName HT   -NotePropertyValue ''
  $p | Add-Member -NotePropertyName SC   -NotePropertyValue $T.Gry
  $p.Add_Paint({
    param($s,$e)
    $g=$e.Graphics; $g.SmoothingMode=[System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    # 用局部路径画描边（不依赖全局共享对象）
    $bp = New-RoundPath $cardW $cardH 8
    try { $g.DrawPath($penBrd,$bp) } finally { $bp.Dispose() }
    $sc=$s.SC
    $dotBr = if($sc -eq $T.Grn){$brushes.grn}elseif($sc -eq $T.Red){$brushes.red}elseif($sc -eq $T.Org){$brushes.org}else{$brushes.gry}
    $g.FillEllipse($dotBr,14,66,8,8)
    $hBr = switch($s.HT){'正常'{$brushes.grn}'无响应'{$brushes.red}default{$brushes.dim}}
    $g.DrawString([string]$s.Tag,$fL,$brushes.fg,14,7)
    $g.DrawString(':'+$s.Port,$fS,$brushes.dim,14,33)
    $g.DrawString($s.ST,$fB,$dotBr,28,62)
    $g.DrawString($s.HT,$fS,$hBr,14,90)
  })
  $p.Add_DoubleClick({
    $n=[string]$this.Tag; $s=Get-Svc $n
    $act = if($s.name -eq '运行中'){'stop'}else{'start'}
    $cmdQueue.Enqueue([pscustomobject]@{ n=$n; act=$act })
    $sLbl.Text="$n $($(if($act -eq 'stop'){'停止'}else{'启动'}))中..."
  })
  $p.Add_MouseDown({
    if($_.Button -ne 'Right'){return}
    $n=[string]$this.Tag
    $ctx=New-Object System.Windows.Forms.ContextMenuStrip -Property @{BackColor=$T.TBg;ForeColor=$T.Fg}
    $ctx.Add_Closed({ $this.Dispose() })
    foreach($d in @(@('▶ 启动','start'),@('■ 停止','stop'),@('↻ 重启','restart'),@('🌐 面板','open'),@('📋 日志','log'))){
      $mi=$ctx.Items.Add($d[0]); $mi.Tag=($d[1]+'|'+$n)
      $mi.Add_Click({
        $parts=[string]$this.Tag -split '\|'; $act=$parts[0]; $n=$parts[1]
        switch($act){
          'start'   { $cmdQueue.Enqueue([pscustomobject]@{ n=$n; act='start' }) }
          'stop'    { $cmdQueue.Enqueue([pscustomobject]@{ n=$n; act='stop' }) }
          'restart' { $cmdQueue.Enqueue([pscustomobject]@{ n=$n; act='restart' }) }
          'open'    { if($script:svc[$n].url){ Start-Process $script:svc[$n].url } }
          'log'     { Show-Log $n }
        }
      })
    }
    $ctx.Show($form,$form.PointToClient([System.Windows.Forms.Cursor]::Position))
  })
  $script:cards[$name]=$p
  [void]$panel.Controls.Add($p)
}

function Update-CardData([string]$n,[string]$st,[string]$h){
  if(-not $script:cards.ContainsKey($n)){return}
  $p=$script:cards[$n]
  $p.ST=$st; $p.HT=$h
  $p.SC = switch($st){ '运行中'{if($h -eq '无响应'){$T.Red}else{$T.Grn}} '已停止'{$T.Gry} '未安装'{$T.Gry} default{$T.Org} }
  $p.Invalidate()
}

# ---- 后台探测 + 命令执行 runspace ----
$queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
$cmdQueue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
$sync = [hashtable]::Synchronized(@{ svc=$script:svc; queue=$queue; cmd=$cmdQueue; stop=$false; gate=[object]::new() })
$poll = @'
while(-not $sync.stop){
  # 拷快照（加锁，避免枚举期间 UI 侧增删）
  [Threading.Monitor]::Enter($sync.gate)
  try { $snap = @($sync.svc.Keys) } finally { [Threading.Monitor]::Exit($sync.gate) }

  foreach($n in $snap){
    # 读单条信息也加锁，避免读到半改的值
    [Threading.Monitor]::Enter($sync.gate)
    try { $info = $sync.svc[$n] } finally { [Threading.Monitor]::Exit($sync.gate) }
    if (-not $info) { continue }

    try {
      $s = Get-Service -Name $n -EA Stop
      $st = switch([string]$s.Status){ 'Stopped'{'已停止'} 'StartPending'{'启动中'} 'StopPending'{'停止中'} 'Running'{'运行中'} default{'未知'} }
    } catch {
      if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { $st='未安装' } else { $st='未知' }
    }

    $h=''
    if($st -eq '运行中'){
      $listen = $null -ne (Get-NetTCPConnection -State Listen -LocalPort ([int]$info.port) -EA SilentlyContinue)
      if (-not $listen) {
        $h='无响应'
      } else {
        try {
          $r = Invoke-WebRequest -Uri $info.url -TimeoutSec 2 -SkipHttpErrorCheck
          $h = if($r.StatusCode -eq 200){'正常'}else{'HTTP ' + $r.StatusCode}
        } catch { $h='无响应' }
      }
    }
    $sync.queue.Enqueue([pscustomobject]@{n=$n;st=$st;h=$h})
  }

  # 执行命令队列（启停全在后台线程，UI 线程不碰 sc.exe/NSSM/Start-Sleep）
  $item=$null
  while($sync.cmd.TryDequeue([ref]$item)){
    $n=[string]$item.n; $act=[string]$item.act
    switch($act){
      'start'   { sc.exe start $n 2>&1 | Out-Null }
      'stop'    { sc.exe stop $n 2>&1 | Out-Null }
      'restart' { sc.exe stop $n 2>&1 | Out-Null; Start-Sleep -Milliseconds 800; sc.exe start $n 2>&1 | Out-Null }
    }
  }

  Start-Sleep -Seconds 4
}
'@
$bgRS=[runspacefactory]::CreateRunspace(); $bgRS.ApartmentState='STA'; $bgRS.ThreadOptions='ReuseThread'; $bgRS.Open()
$bgRS.SessionStateProxy.SetVariable('sync',$sync)
$bgPS=[powershell]::Create().AddScript($poll); $bgPS.Runspace=$bgRS; $bgHandle=$bgPS.BeginInvoke()

# UI 定时器：从队列取结果更新卡片
$uiTimer=New-Object System.Windows.Forms.Timer -Property @{Interval=400}
$uiTimer.Add_Tick({
  $item=$null
  while($queue.TryDequeue([ref]$item)){ Update-CardData $item.n $item.st $item.h }
  $sLbl.Text="$(Get-Date -Format 'HH:mm:ss') 监控中"
})
$uiTimer.Start()

# ---- 内置日志 ----
function Show-Log([string]$n){
  $lf=New-Dialog "$n 日志" 750 500
  $box=New-Object System.Windows.Forms.TextBox -Property @{Dock='Fill';Multiline=$true;ReadOnly=$true;ScrollBars='Vertical';BackColor=$T.Card;ForeColor=$T.Fg;Font=$fMono;BorderStyle='None'}
  $lt=New-Object System.Windows.Forms.ToolStrip -Property @{Dock='Top';BackColor=$T.TBg;GripStyle='Hidden';Renderer=$rnd}
  # 用闭包 hashtable 持久切换状态，修 $cur scope bug
  $state = @{ Current = 'out' }
  $load = {
    $box.Clear()
    $f2 = Join-Path $logDir "$n.$($state.Current).log"
    if(Test-Path $f2){
      $box.Lines = Get-Content $f2 -Tail 500 -EA SilentlyContinue
      $box.SelectionStart = $box.TextLength; $box.ScrollToCaret()
    } else { $box.Text = "无日志: $f2" }
  }.GetNewClosure()
  foreach($d in @(@('输出(out)','out'),@('错误(err)','err'),@('🔄 刷新','reload'))){
    $b=New-TB $d[0] 80; $b.Tag=$d[1]
    $b.Add_Click({
      $tag=$this.Tag
      if($tag -in 'out','err'){ $state.Current = $tag }
      & $load
    }.GetNewClosure())
    [void]$lt.Items.Add($b)
  }
  $lf.Controls.Add($box); $lf.Controls.Add($lt); & $load; [void]$lf.ShowDialog($form)
}

# ---- 添加服务 ----
function Show-Add{
  $dlg=New-Dialog '添加服务' 460 480
  $fields=[ordered]@{'服务名'='';'端口'='0';'面板URL'='';'可执行文件'='';'工作目录'='';'启动参数'='';'环境变量'=''}
  $inp=@{}; $y=15
  foreach($k in $fields.Keys){
    $l=New-Object System.Windows.Forms.Label -Property @{Text=$k;Location=New-Object System.Drawing.Point(15,$y);Width=100;Height=24;ForeColor=$T.Dim}
    $txt=New-Object System.Windows.Forms.TextBox -Property @{Location=New-Object System.Drawing.Point(120,$y);Width=315;BackColor=$T.Card;ForeColor=$T.Fg;BorderStyle='FixedSingle';Text=$fields[$k]}
    $dlg.Controls.Add($l); $dlg.Controls.Add($txt); $inp[$k]=$txt; $y+=30
  }
  $tip=New-Object System.Windows.Forms.Label -Property @{Text='环境变量: KEY=VAL,KEY2=VAL2（一次传入；LocalSystem 服务勿填交互用户 APPDATA）';Location=New-Object System.Drawing.Point(15,$y);Width=430;Height=20;ForeColor=$T.Dim;Font=$fS}
  $dlg.Controls.Add($tip); $y+=28
  $ok=New-Object System.Windows.Forms.Button -Property @{Text='注册并启动';Location=New-Object System.Drawing.Point(250,$y);Size=New-Object System.Drawing.Size(90,30);BackColor=$T.Acc;ForeColor=(C 255 255 255);FlatStyle='Flat'}
  $cancel=New-Object System.Windows.Forms.Button -Property @{Text='取消';Location=New-Object System.Drawing.Point(350,$y);Size=New-Object System.Drawing.Size(75,30);BackColor=$T.TBg;ForeColor=$T.Fg;FlatStyle='Flat'}
  $cancel.Add_Click({$dlg.DialogResult='Cancel'}); $ok.Add_Click({$dlg.DialogResult='OK'}); $dlg.Controls.Add($ok); $dlg.Controls.Add($cancel); $dlg.AcceptButton=$ok; $dlg.CancelButton=$cancel
  if($dlg.ShowDialog($form) -ne 'OK'){return}
  $n=$inp['服务名'].Text.Trim(); $p=[int]$inp['端口'].Text.Trim(); $url=$inp['面板URL'].Text.Trim()
  $exe=$inp['可执行文件'].Text.Trim(); $dir=$inp['工作目录'].Text.Trim(); $par=$inp['启动参数'].Text.Trim(); $env=$inp['环境变量'].Text.Trim()
  if(-not $n -or -not $exe){[System.Windows.Forms.MessageBox]::Show($dlg,'服务名和可执行文件必填','错误','OK','Error')|Out-Null;return}
  if($p -lt 1 -or $p -gt 65535){[System.Windows.Forms.MessageBox]::Show($dlg,'端口必须是 1-65535','错误','OK','Error')|Out-Null;return}
  if($script:svc.ContainsKey($n)){[System.Windows.Forms.MessageBox]::Show($dlg,"$n 已存在",'错误','OK','Error')|Out-Null;return}
  # 校验环境变量格式 + 拦截 LocalSystem 的交互用户 APPDATA
  $envPairs = @()
  if($env){
    $envPairs = ($env -split ',') | %{ $_.Trim() } | ?{ $_ }
    foreach($pair in $envPairs){
      $kv = $pair -split '=',2
      if($kv.Count -ne 2 -or [string]::IsNullOrWhiteSpace($kv[0])){ [System.Windows.Forms.MessageBox]::Show($dlg,"环境变量格式错误: $pair`n应为 KEY=VAL","错误",'OK','Error')|Out-Null; return }
      if($kv[0].Trim() -eq 'APPDATA' -and $kv[1] -match '^C:\\Users\\'){ [System.Windows.Forms.MessageBox]::Show($dlg,'LocalSystem 服务不能使用交互用户的 APPDATA。','错误','OK','Error')|Out-Null; return }
    }
  }
  # NSSM 操作——失败抛错，不更新清单
  try {
    $nssmOut = & $nssm install $n $exe 2>&1
    if($LASTEXITCODE -ne 0){ throw "NSSM install 失败($LASTEXITCODE): $($nssmOut -join ' ')" }
    if($dir){ $o=& $nssm set $n AppDirectory $dir 2>&1; if($LASTEXITCODE -ne 0){throw "AppDirectory 失败: $($o -join ' ')"} }
    if($par){ $o=& $nssm set $n AppParameters $par 2>&1; if($LASTEXITCODE -ne 0){throw "AppParameters 失败: $($o -join ' ')"} }
    $o=& $nssm set $n AppStdout "$logDir\$n.out.log" 2>&1; if($LASTEXITCODE -ne 0){throw "AppStdout 失败"}
    $o=& $nssm set $n AppStderr "$logDir\$n.err.log" 2>&1; if($LASTEXITCODE -ne 0){throw "AppStderr 失败"}
    $o=& $nssm set $n AppStdoutCreationDisposition 4 2>&1; if($LASTEXITCODE -ne 0){throw "StdoutCreationDisposition 失败"}
    $o=& $nssm set $n AppStderrCreationDisposition 4 2>&1; if($LASTEXITCODE -ne 0){throw "StderrCreationDisposition 失败"}
    $o=& $nssm set $n AppStopMethodConsole 5000 2>&1; if($LASTEXITCODE -ne 0){throw "StopMethodConsole 失败"}
    $o=& $nssm set $n Start SERVICE_DEMAND_START 2>&1; if($LASTEXITCODE -ne 0){throw "Start 失败"}
    if($envPairs.Count){ $o=& $nssm set $n AppEnvironmentExtra $envPairs 2>&1; if($LASTEXITCODE -ne 0){throw "AppEnvironmentExtra 失败: $($o -join ' ')"} }
  } catch {
    [System.Windows.Forms.MessageBox]::Show($dlg,$_.Exception.Message,'注册失败','OK','Error')|Out-Null
    return
  }
  # NSSM 全部成功——更新清单（加锁）、原子保存、建卡
  [Threading.Monitor]::Enter($sync.gate)
  try { $script:svc[$n]=@{port=$p;url=$url} } finally { [Threading.Monitor]::Exit($sync.gate) }
  Save-Svc $script:svc; New-Card $n $script:svc[$n]; Resize-Form
  $cmdQueue.Enqueue([pscustomobject]@{ n=$n; act='start' })
  $sLbl.Text="$n 已添加，启动中..."
}

# ---- 删除服务 ----
function Show-Remove{
  $dlg=New-Dialog '删除服务' 320 400
  $lb=New-Object System.Windows.Forms.ListBox -Property @{Location=New-Object System.Drawing.Point(15,15);Size=New-Object System.Drawing.Size(275,280);BackColor=$T.Card;ForeColor=$T.Fg;BorderStyle='FixedSingle';Font=$fReg}
  [Threading.Monitor]::Enter($sync.gate)
  try { $keys = @($script:svc.Keys) } finally { [Threading.Monitor]::Exit($sync.gate) }
  foreach($n in $keys){[void]$lb.Items.Add($n)}
  $dlg.Controls.Add($lb)
  $ok=New-Object System.Windows.Forms.Button -Property @{Text='删除';Location=New-Object System.Drawing.Point(140,310);Size=New-Object System.Drawing.Size(75,30);BackColor=$T.Red;ForeColor=(C 255 255 255);FlatStyle='Flat'}
  $cancel=New-Object System.Windows.Forms.Button -Property @{Text='取消';Location=New-Object System.Drawing.Point(220,310);Size=New-Object System.Drawing.Size(70,30);BackColor=$T.TBg;ForeColor=$T.Fg;FlatStyle='Flat'}
  $cancel.Add_Click({$dlg.DialogResult='Cancel'}); $ok.Add_Click({$dlg.DialogResult='OK'}); $dlg.AcceptButton=$ok; $dlg.CancelButton=$cancel; $dlg.Controls.Add($ok); $dlg.Controls.Add($cancel)
  if($dlg.ShowDialog($form) -ne 'OK' -or $lb.SelectedIndex -lt 0){return}
  $n=[string]$lb.SelectedItem
  if([System.Windows.Forms.MessageBox]::Show($form,"删除 $n ？`n`n停止+注销+移除清单`n数据目录不动。",'确认','OKCancel','Warning') -ne 'OK'){return}
  try {
    $o = sc.exe stop $n 2>&1
    Start-Sleep 2
    $o = sc.exe delete $n 2>&1
    # sc.exe delete 在服务不存在时也可能返回非 0，不视为硬失败
  } catch {
    [System.Windows.Forms.MessageBox]::Show($form,"删除失败: $($_.Exception.Message)",'错误','OK','Error')|Out-Null
    return
  }
  [Threading.Monitor]::Enter($sync.gate)
  try { $script:svc.Remove($n) } finally { [Threading.Monitor]::Exit($sync.gate) }
  Save-Svc $script:svc
  if($script:cards.ContainsKey($n)){ $panel.Controls.Remove($script:cards[$n]); $script:cards[$n].Dispose(); $script:cards.Remove($n) }
  Resize-Form
  $sLbl.Text="$n 已删除"
}

# ---- 托盘 ----
$notify=New-Object System.Windows.Forms.NotifyIcon -Property @{Icon=[System.Drawing.SystemIcons]::Application;Visible=$true;Text='服务管理'}
$tray=New-Object System.Windows.Forms.ContextMenuStrip -Property @{BackColor=$T.TBg;ForeColor=$T.Fg}
$trayShow=$tray.Items.Add('显示窗口'); $trayHide=$tray.Items.Add('隐藏到托盘'); $tray.Items.Add('-')|Out-Null; $trayExit=$tray.Items.Add('退出')
$notify.ContextMenuStrip=$tray
$trayShow.Add_Click({ $form.Show(); $form.WindowState='Normal'; $form.Activate() })
$trayHide.Add_Click({ $form.Hide() })
$script:exiting=$false
$trayExit.Add_Click({ $script:exiting=$true; $notify.Visible=$false; $form.Close() })
$form.Add_FormClosing({ param($s,$e) Write-CrashLog "FormClosing reason=$($e.CloseReason) exiting=$script:exiting"; if(-not $script:exiting -and $e.CloseReason -eq 'UserClosing'){ $e.Cancel=$true; $form.Hide(); $notify.ShowBalloonTip(1500,'服务管理','右键托盘退出',[System.Windows.Forms.ToolTipIcon]::Info) } })

# ---- 工具栏事件 ----
$tbBtns['add'].Add_Click({ Show-Add })
$tbBtns['remove'].Add_Click({ Show-Remove })
$tbBtns['refresh'].Add_Click({ $queue.Clear(); $sLbl.Text="$(Get-Date -Format 'HH:mm:ss') 已触发刷新" })
$tbBtns['msc'].Add_Click({ Start-Process services.msc })

# ---- 初始化：建卡片 ----
foreach($n in $script:svc.Keys){ New-Card $n $script:svc[$n] }

# 坏 JSON 提示（加载时记下，建完 UI 再弹）
if($script:configWarning){
  [System.Windows.Forms.MessageBox]::Show($form,"services.json 无效：$($script:configWarning)`n当前使用恢复配置，保存前请修复文件。",'配置错误','OK','Warning')|Out-Null
}

[void]$form.ShowDialog()
Write-CrashLog "ShowDialog returned (normal exit path)"
# 收尾（有界等待，不卡退出）
$uiTimer.Stop(); $sync.stop=$true
try { $bgPS.StopAsync($null,$null).Wait(1500) } catch {}
try { if($bgHandle.AsyncWaitHandle.WaitOne(1000)){ $bgPS.EndInvoke($bgHandle) } } catch {}
try { $bgPS.Stop() } catch {}
$bgRS.Close(); $bgRS.Dispose(); $bgPS.Dispose()
$brushes.Values | %{ $_.Dispose() }; $penBrd.Dispose(); $notify.Visible=$false; $notify.Dispose(); $tray.Dispose()
$fReg.Dispose(); $fB.Dispose(); $fS.Dispose(); $fL.Dispose(); $fMono.Dispose()
