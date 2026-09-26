Requires -Version 7.0
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

# ---- 主题 ----
$fReg = New-Object System.Drawing.Font('Microsoft YaHei UI',10)
$fB   = New-Object System.Drawing.Font('Microsoft YaHei UI',10,[System.Drawing.FontStyle]::Bold)
$fS   = New-Object System.Drawing.Font('Microsoft YaHei UI',9)
$fL   = New-Object System.Drawing.Font('Microsoft YaHei UI',11,[System.Drawing.FontStyle]::Bold)
$fMono= New-Object System.Drawing.Font('Consolas',9)
function C($r,$g,$b){ [System.Drawing.Color]::FromArgb($r,$g,$b) }
$bg=C 250 250 252; $card=C 255 255 255; $brd=C 228 231 235; $fg=C 33 33 33; $dim=C 150 150 150
$grn=C 52 168 83; $red=C 234 67 53; $org=C 251 146 60; $gry=C 140 140 140; $acc=C 0 120 215
$tBg = C 245 246 247

# ---- 服务清单 ----
$default = [ordered]@{
  'NewAPI'=@{port=3000;url='http://127.0.0.1:3000'}; 'Router9'=@{port=20128;url='http://127.0.0.1:20128/dashboard'}
  'OmniRoute'=@{port=20129;url='http://127.0.0.1:20129/dashboard'}; 'CPA'=@{port=8317;url='http://127.0.0.1:8317/management.html'}
  'WorkBuddy2API'=@{port=7863;url='http://127.0.0.1:7863/panel/'}; 'TTSShim'=@{port=8001;url='http://127.0.0.1:8001/health'}
}
function Load-Svc { if(Test-Path $cfg){try{$j=Get-Content $cfg -Raw|ConvertFrom-Json -AsHashtable;$o=[ordered]@{};foreach($k in $j.Keys){$o[$k]=$j[$k]};$o}catch{$default}}else{$default} }
function Save-Svc($s){ $s|ConvertTo-Json -Depth 5|Set-Content $cfg -Encoding UTF8 }
function Get-Svc([string]$n){ $o=(sc.exe query $n 2>&1)-join"`n"; if($o -match 'FAILED 1060'){return @{name='未安装';code=-1}}; $c=if($o-match 'STATE\s+:\s*(\d+)'){[int]$Matches[1]}else{0}; $names=@{1='已停止';2='启动中';3='停止中';4='运行中';0='未知'}; @{name=($names[$c]??'未知');code=$c} }

# ---- 主窗口（固定大小）----
$cols=3; $cardW=190; $cardH=132; $gap=14; $margin=16
$rows=[math]::Ceiling($default.Count/$cols)
$cliW=$margin*2 + $cols*$cardW + ($cols-1)*$gap
$cliH=$margin*2 + $rows*$cardH + ($rows-1)*$gap + 34 + 22
$form = New-Object System.Windows.Forms.Form -Property @{
  Text='服务管理'; ClientSize=New-Object System.Drawing.Size($cliW,$cliH); StartPosition='CenterScreen'
  Font=$fReg; BackColor=$bg; ForeColor=$fg; FormBorderStyle='FixedDialog'; MaximizeBox=$false; MinimizeBox=$false
}

# 工具栏
$rnd = New-Object System.Windows.Forms.ToolStripProfessionalRenderer(New-Object System.Windows.Forms.ProfessionalColorTable)
$rnd.ColorTable.GetType().GetProperties() | ?{ $_.Name -like 'ToolStrip*' } | %{ $_.SetValue($rnd.ColorTable,$tBg) }
$tb = New-Object System.Windows.Forms.ToolStrip -Property @{ Dock='Top'; BackColor=$tBg; GripStyle='Hidden'; Renderer=$rnd; Padding=New-Object System.Windows.Forms.Padding(6,3,6,3) }
$form.Controls.Add($tb)
function New-TB([string]$t,[int]$w=70){ New-Object System.Windows.Forms.ToolStripButton -Property @{Text=$t;DisplayStyle='Text';AutoSize=$false;Width=$w;Height=28;Font=$fS;ForeColor=$fg;BackColor=$tBg} }
$tbDefs=@(@('➕ 添加','add'),@('🗑 删除','remove'),@('🔄 刷新','refresh'),@('services.msc','msc',100))
$tbBtns=@{}; foreach($d in $tbDefs){ $b=New-TB $d[0] $(if($d.Count-ge 3){$d[2]}else{70}); $tbBtns[$d[1]]=$b; [void]$tb.Items.Add($b) }

# 状态栏
$ss = New-Object System.Windows.Forms.StatusStrip -Property @{ Dock='Bottom'; BackColor=$tBg }
$sLbl = New-Object System.Windows.Forms.ToolStripStatusLabel -Property @{ Text='就绪'; ForeColor=$dim }
[void]$ss.Items.Add($sLbl); $form.Controls.Add($ss)

# 卡片容器（Dock=Fill，最后加入）
$panel = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{ Dock='Fill'; BackColor=$bg; BorderStyle='None'; WrapContents=$true; FlowDirection='LeftToRight'; AutoScroll=$true; Padding=New-Object System.Windows.Forms.Padding($margin,$margin,$margin,$margin) }
$form.Controls.Add($panel)

# ---- 卡片（全自绘：圆角 Region + Paint 画文字/圆点，无子 Label）----
$script:cards = @{}
# 圆角路径（标准四角弧 + 隐式直线连接）
function New-RoundPath([int]$w,[int]$h,[int]$r){
  $p=New-Object System.Drawing.Drawing2D.GraphicsPath
  $p.AddArc(0,0,$r,$r,180,90); $p.AddArc($w-$r,0,$r,$r,270,90); $p.AddArc($w-$r,$h-$r,$r,$r,0,90); $p.AddArc(0,$h-$r,$r,$r,90,90)
  $p.CloseFigure(); $p
}
# 缓存笔刷（Paint 频繁调用，避免每次 New+Dispose 的开销与 GDI 句柄泄漏）
$brushes = @{ fg=New-Object System.Drawing.SolidBrush $fg; dim=New-Object System.Drawing.SolidBrush $dim; grn=New-Object System.Drawing.SolidBrush $grn; red=New-Object System.Drawing.SolidBrush $red; org=New-Object System.Drawing.SolidBrush $org; gry=New-Object System.Drawing.SolidBrush $gry; crd=New-Object System.Drawing.SolidBrush $card }
$penBrd = New-Object System.Drawing.Pen $brd,1
$cardPath = New-RoundPath $cardW $cardH 8

function New-Card([string]$name, $info){
  $p = New-Object System.Windows.Forms.Panel -Property @{ Size=New-Object System.Drawing.Size($cardW,$cardH); BackColor=$card; Margin=New-Object System.Windows.Forms.Padding(0,$gap,0,0); Cursor='Hand'; Tag=$name }
  $p.Region = New-Object System.Drawing.Region $cardPath
  # 状态缓存到属性（Paint 读这些画，Update 只改属性 + Invalidate）
  $p | Add-Member -NotePropertyName Port -NotePropertyValue $info.port
  $p | Add-Member -NotePropertyName Url  -NotePropertyValue $info.url
  $p | Add-Member -NotePropertyName ST   -NotePropertyValue '查询中'
  $p | Add-Member -NotePropertyName HT   -NotePropertyValue ''
  $p | Add-Member -NotePropertyName SC   -NotePropertyValue $gry
  # 自绘：描边 + 圆点 + 四行文字
  $p.Add_Paint({
    param($s,$e)
    $g=$e.Graphics; $g.SmoothingMode=[System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.DrawPath($penBrd,$cardPath)
    # 状态圆点（14,66 8x8）
    $sc=$s.SC
    $dotBr = if($sc -eq $grn){$brushes.grn}elseif($sc -eq $red){$brushes.red}elseif($sc -eq $org){$brushes.org}else{$brushes.gry}
    $g.FillEllipse($dotBr,14,66,8,8)
    # 文字画笔：状态色与圆点同色
    $stBr=$dotBr
    $hBr = switch($s.HT){'正常'{$brushes.grn}'无响应'{$brushes.red}default{$brushes.dim}}
    # 服务名(粗 11pt) / 端口(小) / 状态(粗) / 健康(小)
    $g.DrawString([string]$s.Tag,$fL,$brushes.fg,14,7)
    $g.DrawString(':'+$s.Port,$fS,$brushes.dim,14,33)
    $g.DrawString($s.ST,$fB,$stBr,28,62)
    $g.DrawString($s.HT,$fS,$hBr,14,90)
  })
  # 双击 = 启停切换（Tag 直接取，无闭包问题）
  $p.Add_DoubleClick({ $n=[string]$this.Tag; $s=Get-Svc $n; Invoke-Svc $n $(if($s.name -eq '运行中'){'stop'}else{'start'}) })
  # 右键菜单
  $p.Add_MouseDown({
    if($_.Button -ne 'Right'){return}
    $n=[string]$this.Tag
    $ctx=New-Object System.Windows.Forms.ContextMenuStrip -Property @{BackColor=$tBg;ForeColor=$fg}
    foreach($d in @(@('▶ 启动','start'),@('■ 停止','stop'),@('↻ 重启','restart'),@('🌐 面板','open'),@('📋 日志','log'))){
      $mi=$ctx.Items.Add($d[0]); $mi.Tag=($d[1]+'|'+$n)
      $mi.Add_Click({ $parts=[string]$this.Tag -split '\|'; $act=$parts[0]; $n=$parts[1]
        switch($act){'start'{Invoke-Svc $n 'start'}'stop'{Invoke-Svc $n 'stop'}'restart'{Invoke-Svc $n 'restart'}'open'{if($script:svc[$n].url){Start-Process $script:svc[$n].url}}'log'{Show-Log $n}} })
    }
    $ctx.Show($form,$form.PointToClient([System.Windows.Forms.Cursor]::Position))
  })
  $script:cards[$name]=@{panel=$p}
  [void]$panel.Controls.Add($p)
}

# 就地更新卡片（只改属性 + Invalidate，无 I/O）
function Update-CardData([string]$n,[string]$st,[string]$h){
  if(-not $script:cards.ContainsKey($n)){return}
  $p=$script:cards[$n].panel
  $p.ST=$st; $p.HT=$h
  $p.SC = switch($st){ '运行中'{if($h -eq '无响应'){$red}else{$grn}} '已停止'{$gry} '未安装'{$gry} default{$org} }
  $p.Invalidate()
}

# ---- 启停：fire-and-forget，乐观翻状态，真实结果等后台探测 ----
function Invoke-Svc([string]$n,[string]$action){
  switch($action){
    'start'   { $s=Get-Svc $n; if($s.name -eq '运行中'){$sLbl.Text="$n 已在运行";return}; sc.exe start $n 2>&1|Out-Null; Update-CardData $n '启动中' ''; $sLbl.Text="启动 $n..." }
    'stop'    { $s=Get-Svc $n; if($s.name -eq '已停止'){$sLbl.Text="$n 未在运行";return}; sc.exe stop $n 2>&1|Out-Null; Update-CardData $n '停止中' ''; $sLbl.Text="停止 $n..." }
    'restart' { Invoke-Svc $n 'stop'; Start-Sleep -Milliseconds 800; Invoke-Svc $n 'start' }
  }
}

# ---- 后台探测 runspace：sc.exe + HTTP 全在后台线程，结果丢队列 ----
$script:svc = Load-Svc
$queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
$sync = [hashtable]::Synchronized(@{ svc=$script:svc; queue=$queue; stop=$false })
$poll = @'
while(-not $sync.stop){
  foreach($n in @($sync.svc.Keys)){
    $info=$sync.svc[$n]
    $o=(sc.exe query $n 2>&1)-join"`n"
    $st=if($o -match 'FAILED 1060'){'未安装'}elseif($o -match 'STATE\s+:\s*(\d+)'){switch([int]$Matches[1]){1{'已停止'}2{'启动中'}3{'停止中'}4{'运行中'}default{'未知'}}}else{'未知'}
    $h=''
    if($st -eq '运行中'){ try{Invoke-WebRequest("http://127.0.0.1:"+$info.port) -UseBasicParsing -TimeoutSec 2|Out-Null;$h='正常'}catch{$h='无响应'} }
    $sync.queue.Enqueue([pscustomobject]@{n=$n;st=$st;h=$h})
  }
  Start-Sleep -Seconds 4
}
'@
$bgRS=[runspacefactory]::CreateRunspace(); $bgRS.ApartmentState='STA'; $bgRS.ThreadOptions='ReuseThread'; $bgRS.Open()
$bgRS.SessionStateProxy.SetVariable('sync',$sync)
$bgPS=[powershell]::Create().AddScript($poll); $bgPS.Runspace=$bgRS; $bgHandle=$bgPS.BeginInvoke()

# UI 定时器：从队列取结果更新卡片
$uiTimer=New-Object System.Windows.Forms.Timer -Property @{Interval=400}
$uiTimer.Add_Tick({ $item=$null; while($queue.TryDequeue([ref]$item)){ Update-CardData $item.n $item.st $item.h }; $sLbl.Text="$(Get-Date -Format 'HH:mm:ss') 监控中" })
$uiTimer.Start()

# ---- 内置日志 ----
function Show-Log([string]$n){
  $lf=New-Object System.Windows.Forms.Form -Property @{Text="$n 日志";Size=New-Object System.Drawing.Size(750,500);StartPosition='CenterParent';Font=$fReg;BackColor=$bg;ForeColor=$fg}
  $box=New-Object System.Windows.Forms.TextBox -Property @{Dock='Fill';Multiline=$true;ReadOnly=$true;ScrollBars='Vertical';BackColor=$card;ForeColor=$fg;Font=$fMono;BorderStyle='None'}
  $lt=New-Object System.Windows.Forms.ToolStrip -Property @{Dock='Top';BackColor=$tBg;GripStyle='Hidden';Renderer=$rnd}
  $cur='out'
  $load={ $box.Clear(); $f2="$logDir\$n.$cur.log"; if(Test-Path $f2){ $box.Lines=Get-Content $f2 -Tail 500 -EA SilentlyContinue; $box.SelectionStart=$box.TextLength; $box.ScrollToCaret() }else{ $box.Text="无日志: $f2" } }
  foreach($d in @(@('输出(out)','out'),@('错误(err)','err'),@('🔄 刷新','reload'))){ $b=New-TB $d[0] 80; $b.Tag=$d[1]; $b.Add_Click({ $t=$this.Tag; if($t -in 'out','err'){$script:cur=$t}; & $load }); [void]$lt.Items.Add($b) }
  $lf.Controls.Add($box); $lf.Controls.Add($lt); & $load; [void]$lf.ShowDialog($form)
}

# ---- 添加服务 ----
function Show-Add{
  $dlg=New-Object System.Windows.Forms.Form -Property @{Text='添加服务';Size=New-Object System.Drawing.Size(460,480);StartPosition='CenterParent';FormBorderStyle='FixedDialog';MaximizeBox=$false;Font=$fReg;BackColor=$bg;ForeColor=$fg}
  $fields=[ordered]@{'服务名'='';'端口'='0';'面板URL'='';'可执行文件'='';'工作目录'='';'启动参数'='';'环境变量'=''}
  $inp=@{}; $y=15
  foreach($k in $fields.Keys){ $l=New-Object System.Windows.Forms.Label -Property @{Text=$k;Location=New-Object System.Drawing.Point(15,$y);Width=100;Height=24;ForeColor=$dim}; $t=New-Object System.Windows.Forms.TextBox -Property @{Location=New-Object System.Drawing.Point(120,$y);Width=315;BackColor=$card;ForeColor=$fg;BorderStyle='FixedSingle';Text=$fields[$k]}; $dlg.Controls.Add($l); $dlg.Controls.Add($t); $inp[$k]=$t; $y+=30 }
  $tip=New-Object System.Windows.Forms.Label -Property @{Text='环境变量: KEY=VAL,KEY2=VAL2（一次传入）';Location=New-Object System.Drawing.Point(15,$y);Width=420;Height=20;ForeColor=$dim;Font=$fS}
  $dlg.Controls.Add($tip); $y+=28
  $ok=New-Object System.Windows.Forms.Button -Property @{Text='注册并启动';Location=New-Object System.Drawing.Point(250,$y);Size=New-Object System.Drawing.Size(90,30);BackColor=$acc;ForeColor=(C 255 255 255);FlatStyle='Flat'}
  $cancel=New-Object System.Windows.Forms.Button -Property @{Text='取消';Location=New-Object System.Drawing.Point(350,$y);Size=New-Object System.Drawing.Size(75,30);BackColor=$tBg;ForeColor=$fg;FlatStyle='Flat'}
  $cancel.Add_Click({$dlg.DialogResult='Cancel'}); $ok.Add_Click({$dlg.DialogResult='OK'}); $dlg.Controls.Add($ok); $dlg.Controls.Add($cancel); $dlg.AcceptButton=$ok; $dlg.CancelButton=$cancel
  if($dlg.ShowDialog($form) -ne 'OK'){return}
  $n=$inp['服务名'].Text.Trim(); $p=[int]$inp['端口'].Text.Trim(); $url=$inp['面板URL'].Text.Trim()
  $exe=$inp['可执行文件'].Text.Trim(); $dir=$inp['工作目录'].Text.Trim(); $par=$inp['启动参数'].Text.Trim(); $env=$inp['环境变量'].Text.Trim()
  if(-not $n -or -not $exe){[System.Windows.Forms.MessageBox]::Show($dlg,'服务名和可执行文件必填','错误','OK','Error')|Out-Null;return}
  if($script:svc.ContainsKey($n)){[System.Windows.Forms.MessageBox]::Show($dlg,"$n 已存在",'错误','OK','Error')|Out-Null;return}
  & $nssm install $n $exe 2>&1|Out-Null
  if($dir){& $nssm set $n AppDirectory $dir 2>&1|Out-Null}
  if($par){& $nssm set $n AppParameters $par 2>&1|Out-Null}
  & $nssm set $n AppStdout "$logDir\$n.out.log" 2>&1|Out-Null; & $nssm set $n AppStderr "$logDir\$n.err.log" 2>&1|Out-Null
  & $nssm set $n AppStdoutCreationDisposition 4 2>&1|Out-Null; & $nssm set $n AppStderrCreationDisposition 4 2>&1|Out-Null
  & $nssm set $n AppStopMethodConsole 5000 2>&1|Out-Null; & $nssm set $n Start SERVICE_DEMAND_START 2>&1|Out-Null
  if($env){ $a=@($env -split ','|%{$_.Trim()}|?{$_}); if($a.Count){& $nssm set $n AppEnvironmentExtra $a 2>&1|Out-Null} }
  $script:svc[$n]=@{port=$p;url=$url}; Save-Svc $script:svc; New-Card $n $script:svc[$n]; sc.exe start $n 2>&1|Out-Null; $sLbl.Text="$n 已添加并启动"
}

# ---- 删除服务 ----
function Show-Remove{
  $dlg=New-Object System.Windows.Forms.Form -Property @{Text='删除服务';Size=New-Object System.Drawing.Size(320,400);StartPosition='CenterParent';FormBorderStyle='FixedDialog';MaximizeBox=$false;Font=$fReg;BackColor=$bg;ForeColor=$fg}
  $lb=New-Object System.Windows.Forms.ListBox -Property @{Location=New-Object System.Drawing.Point(15,15);Size=New-Object System.Drawing.Size(275,280);BackColor=$card;ForeColor=$fg;BorderStyle='FixedSingle';Font=$fReg}
  foreach($n in $script:svc.Keys){[void]$lb.Items.Add($n)}
  $dlg.Controls.Add($lb)
  $ok=New-Object System.Windows.Forms.Button -Property @{Text='删除';Location=New-Object System.Drawing.Point(140,310);Size=New-Object System.Drawing.Size(75,30);BackColor=$red;ForeColor=(C 255 255 255);FlatStyle='Flat'}
  $cancel=New-Object System.Windows.Forms.Button -Property @{Text='取消';Location=New-Object System.Drawing.Point(220,310);Size=New-Object System.Drawing.Size(70,30);BackColor=$tBg;ForeColor=$fg;FlatStyle='Flat'}
  $cancel.Add_Click({$dlg.DialogResult='Cancel'}); $ok.Add_Click({$dlg.DialogResult='OK'}); $dlg.AcceptButton=$ok; $dlg.CancelButton=$cancel; $dlg.Controls.Add($ok); $dlg.Controls.Add($cancel)
  if($dlg.ShowDialog($form) -ne 'OK' -or $lb.SelectedIndex -lt 0){return}
  $n=[string]$lb.SelectedItem
  if([System.Windows.Forms.MessageBox]::Show($form,"删除 $n ？`n`n停止+注销+移除清单`n数据目录不动。",'确认','OKCancel','Warning') -ne 'OK'){return}
  sc.exe stop $n 2>&1|Out-Null; Start-Sleep 2; sc.exe delete $n 2>&1|Out-Null
  $script:svc.Remove($n); Save-Svc $script:svc
  if($script:cards.ContainsKey($n)){ $panel.Controls.Remove($script:cards[$n].panel); $script:cards.Remove($n) }
  $sLbl.Text="$n 已删除"
}

# ---- 托盘 ----
$notify=New-Object System.Windows.Forms.NotifyIcon -Property @{Icon=[System.Drawing.SystemIcons]::Application;Visible=$true;Text='服务管理'}
$tray=New-Object System.Windows.Forms.ContextMenuStrip -Property @{BackColor=$tBg;ForeColor=$fg}
$trayShow=$tray.Items.Add('显示窗口'); $trayHide=$tray.Items.Add('隐藏到托盘'); $tray.Items.Add('-')|Out-Null; $trayExit=$tray.Items.Add('退出')
$notify.ContextMenuStrip=$tray
$trayShow.Add_Click({ $form.Show(); $form.WindowState='Normal'; $form.Activate() })
$trayHide.Add_Click({ $form.Hide() })
$script:exiting=$false
$trayExit.Add_Click({ $script:exiting=$true; $notify.Visible=$false; $form.Close() })
$form.Add_FormClosing({ param($s,$e) if(-not $script:exiting -and $e.CloseReason -eq 'UserClosing'){ $e.Cancel=$true; $form.Hide(); $notify.ShowBalloonTip(1500,'服务管理','右键托盘退出',[System.Windows.Forms.ToolTipIcon]::Info) } })

# ---- 工具栏事件 ----
$tbBtns['add'].Add_Click({ Show-Add })
$tbBtns['remove'].Add_Click({ Show-Remove })
$tbBtns['refresh'].Add_Click({ $queue.Clear(); $sLbl.Text="$(Get-Date -Format 'HH:mm:ss') 已触发刷新" })
$tbBtns['msc'].Add_Click({ Start-Process services.msc })

# ---- 初始化：建卡片（后台马上推数据）----
foreach($n in $script:svc.Keys){ New-Card $n $script:svc[$n] }

[void]$form.ShowDialog()
# 收尾
$uiTimer.Stop(); $sync.stop=$true
try{ $bgPS.EndInvoke($bgHandle) }catch{}
try{ $bgPS.Stop() }catch{}
$bgRS.Close(); $bgRS.Dispose(); $bgPS.Dispose()
$brushes.Values|%{ $_.Dispose() }; $penBrd.Dispose(); $notify.Visible=$false
