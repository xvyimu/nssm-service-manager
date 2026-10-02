# lib/add-svc.ps1 — 添加服务（GUI 简化 + CLI agent 友好）
# 人：3 必填（服务名/exe/端口）+ 高级折叠（URL/工作目录/启动参数/env）
# agent：-Add Name,Port,Exe[,Url,Dir,Args,Env] 不弹 GUI

# GUI/CLI 共用 NSSM 注册与配置；输入校验、错误显示、保存和启动仍由调用方处理。
function Install-NssmService([string]$n,[string]$exe,[string]$dir,[string]$par,$envPairs){
  $nssmOut=& $script:nssm install $n $exe 2>&1
  if($LASTEXITCODE -ne 0){ throw "NSSM install 失败($LASTEXITCODE): $($nssmOut -join ' ')" }
  # install 成功后服务已进服务数据库；任意 set 失败都会留下配置不全的半注册残骸
  # （无日志重定向/轮转/AppExit）。失败时尽力 remove 回滚，再抛原始错误。
  try {
    if($dir){ nssm-set $n AppDirectory $dir }
    if($par){ nssm-set $n AppParameters $par }
    nssm-set $n AppStdout "$logDir\$n.out.log"; nssm-set $n AppStderr "$logDir\$n.err.log"
    nssm-set $n AppStdoutCreationDisposition 4; nssm-set $n AppStderrCreationDisposition 4
    nssm-set $n AppRotateFiles 1; nssm-set $n AppRotateOnline 1; nssm-set $n AppRotateBytes 5242880
    nssm-set $n AppStopMethodConsole 5000; nssm-set $n Start SERVICE_DEMAND_START
    nssm-set $n AppExit Default Ignore
    if($envPairs.Count){ nssm-set $n AppEnvironmentExtra $envPairs }
  } catch {
    try { & $script:nssm remove $n confirm 2>&1 | Out-Null } catch {}
    throw
  }
}

# CLI 模式：解析逗号分隔参数，注册 NSSM 服务并启动，不弹 GUI
# 用法：-Add Name,Port,Exe[,Url,Dir,Args,Env]
#   Env 多对用分号分隔：KEY=VAL;KEY2=VAL2（逗号已被字段分隔符占用）
function Add-SvcFromCli([string]$spec){
  $parts = $spec -split ','
  if ($parts.Count -lt 3) { Write-Host "用法: -Add Name,Port,Exe[,Url,Dir,Args,Env]"; exit 1 }
  $n=$parts[0].Trim(); $p=[int]$parts[1].Trim(); $exe=$parts[2].Trim()
  # 服务名字符集：Windows 服务名禁止含 / \ : | 等保留字符，这里收口到安全子集
  if ($n -notmatch '^[A-Za-z0-9_.-]+$') { Write-Host "服务名含非法字符（仅允许字母数字 . _ -）：$n"; exit 1 }
  # 可执行文件必须存在，避免注册一个启动即失败的服务
  if (-not (Test-Path -LiteralPath $exe)) { Write-Host "可执行文件不存在：$exe"; exit 1 }
  $url=if($parts.Count -gt 3){$parts[3].Trim()}else{"http://127.0.0.1:$p"}
  $dir=if($parts.Count -gt 4){$parts[4].Trim()}else{''}
  $par=if($parts.Count -gt 5){$parts[5].Trim()}else{''}
  # Env：第 7 段往后全部属于 Env（Args 可能含逗号的情况不处理——Args 不应含逗号）
  # 多对 env 用分号分隔，避免与字段逗号冲突
  $env=if($parts.Count -gt 6){($parts[6..($parts.Count-1)] -join ',').Trim()}else{''}
  if($p -lt 1 -or $p -gt 65535){ Write-Host "端口非法: $p"; exit 1 }
  if($script:svc.Contains($n)){ Write-Host "$n 已存在"; exit 1 }
  $envPairs=@()
  if($env){ $envPairs=($env -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
  try {
    Install-NssmService $n $exe $dir $par $envPairs
  } catch { Write-Host "注册失败: $($_.Exception.Message)"; exit 1 }
  [Threading.Monitor]::Enter($sync.gate)
  try { $script:svc[$n]=@{port=$p;url=$url} } finally { [Threading.Monitor]::Exit($sync.gate) }
  try {
    Save-Svc $script:svc
  } catch {
    # Save-Svc 失败：NSSM 服务已注册且可用，但 services.json 未落盘。
    # 回滚 NSSM 会丢掉一个实际可用的服务，故不自动 remove——提示用户手动迁移。
    Write-Host "警告: 服务已注册但配置保存失败：$($_.Exception.Message)"
    Write-Host "$n 已在 NSSM 注册，请手动将其加入 services.json 或用 -Add 重新注册后删除旧服务。"
    exit 1
  }
  sc.exe start $n 2>&1 | Out-Null
  Write-Host "$n 已添加并启动 (port=$p url=$url)"
}

# Wait-Stopped 抽到 lib/svc-common.ps1，与 poll.ps1 的 runspace 引用同一份实现（原 SYNC 注释消除）。
. (Join-Path $PSScriptRoot 'svc-common.ps1')

function Remove-NssmService([string]$n){
  sc.exe stop $n 2>&1 | Out-Null
  # stop 失败不阻断（服务可能已停），等 Stopped 再删，避免删一个还在跑的服务
  [void](Wait-Stopped $n)
  $o=& $script:nssm remove $n confirm 2>&1
  if($LASTEXITCODE -ne 0){ throw "NSSM remove 失败($LASTEXITCODE): $($o -join ' ')" }
}

# GUI 删除服务（输入服务名确认才点亮删除——借鉴 PSSM，-ceq 区分大小写）
# OKCancel 太容易误点；NSSM remove 是不可逆操作，要求打全名。
function Show-Remove([string]$n, $owner){
  $f = New-Object System.Windows.Window -Property @{
    Title="删除服务 $n"; Width=420; Height=260; WindowStartupLocation='CenterOwner'
    Background=[System.Windows.Media.Brushes]::White; ResizeMode='NoResize'
  }
  $stack=New-Object System.Windows.Controls.StackPanel -Property @{Margin='15'}
  $warn=New-Object System.Windows.Controls.TextBlock -Property @{
    Text="将从 NSSM 删除服务「$n」并移除配置。`n此操作不可撤销：服务会先停止再删除。`n`n输入完整服务名以确认："
    FontFamily=$script:cjkFont; FontSize=12; TextWrapping='Wrap'
  }
  [void]$stack.Children.Add($warn)
  $input=New-Object System.Windows.Controls.TextBox -Property @{FontFamily=$script:cjkFont; FontSize=13; Margin='0,8,0,12'}
  [void]$stack.Children.Add($input)

  $btnPanel=New-Object System.Windows.Controls.StackPanel -Property @{Orientation='Horizontal';HorizontalAlignment='Right'}
  $cancel=New-Object System.Windows.Controls.Button -Property @{Content='取消';Padding='16,6';Margin='0,0,8,0'}
  $del=New-Object System.Windows.Controls.Button -Property @{
    Content='删除'; Padding='16,6'; IsEnabled=$false
    Background=(New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(192,57,43)))
    Foreground=[System.Windows.Media.Brushes]::White
  }
  [void]$btnPanel.Children.Add($cancel); [void]$btnPanel.Children.Add($del)
  [void]$stack.Children.Add($btnPanel)
  $f.Content=$stack

  # 精确匹配（-ceq 区分大小写）才点亮删除按钮
  $input.Add_TextChanged({ $del.IsEnabled = ($input.Text.Trim() -ceq $n) })
  $cancel.Add_Click({ $f.DialogResult=$false; $f.Close() })

  $del.Add_Click({
    $script:lastActionAt=[datetime]::Now
    $script:statusBar.Text="正在删除 $n ..."
    # 删除走后台命令队列（act=remove），避免 UI 线程同步等 stop+Wait-Stopped+remove 冻结界面。
    # 真正的 stop/wait/remove 在 runspace 里执行；这里只关弹窗，回执由 DispatcherTimer 处理。
    $card = $script:cards[$n]
    if ($card) {
      $card.ST='删除中'; $card.Btn.IsEnabled=$false; $card.Btn.Content='删除中'
      $card.LblSt.Text='删除中'; $card.LblSt.Foreground=[System.Windows.Media.Brushes]::Orange
      $card.Dot.Fill=[System.Windows.Media.Brushes]::Orange
      $card.PendingEpoch = (Send-ServiceCommand $n 'remove')
    } else {
      Send-ServiceCommand $n 'remove' | Out-Null
    }
    $f.DialogResult=$true; $f.Close()
  })

  $f.Owner=$owner
  $f.ShowDialog() | Out-Null
}

# GUI 添加服务对话框：3 必填 + 高级折叠，注册成功后入队启动命令
function Show-Add($owner){
  $f = New-Object System.Windows.Window -Property @{
    Title='添加服务'; Width=460; Height=540; WindowStartupLocation='CenterOwner'
    Background=[System.Windows.Media.Brushes]::White; ResizeMode='NoResize'
  }
  $stack=New-Object System.Windows.Controls.StackPanel -Property @{Margin='15'}
  $mkLabel={ param($t) New-Object System.Windows.Controls.TextBlock -Property @{Text=$t;Margin='0,8,0,2';FontFamily=$script:cjkFont;Foreground=[System.Windows.Media.Brushes]::Gray} }
  $mkBox={ param($w) New-Object System.Windows.Controls.TextBox -Property @{Width=$w;FontFamily=$script:cjkFont;Margin='0,0,0,8'} }
  $mkExp = {
    param($t) New-Object System.Windows.Controls.Expander -Property @{Header=$t;Margin='0,8,0,8';FontFamily=$script:cjkFont}
  }
  $inName=& $mkBox 200; $inPort=& $mkBox 200; $inPort.Text=''
  $inExe=& $mkBox 380; $inUrl=& $mkBox 380; $inDir=& $mkBox 380; $inPar=& $mkBox 380; $inEnv=& $mkBox 380
  $inExe.ToolTip='完整路径，如 C:\app\server.exe'
  $inEnv.ToolTip='格式 KEY=VAL,KEY2=VAL2（一次传入；LocalSystem 服务勿填交互用户 APPDATA）'

  $stack.Children.Add((& $mkLabel '服务名 *')) | Out-Null; $stack.Children.Add($inName) | Out-Null
  $stack.Children.Add((& $mkLabel '端口 *（1-65535）')) | Out-Null; $stack.Children.Add($inPort) | Out-Null
  $stack.Children.Add((& $mkLabel '可执行文件 *')) | Out-Null; $stack.Children.Add($inExe) | Out-Null

  $adv=& $mkExp '高级（可选）'
  $advContent=New-Object System.Windows.Controls.StackPanel
  $advContent.Children.Add((& $mkLabel '面板URL（默认 http://127.0.0.1:端口）')) | Out-Null; $advContent.Children.Add($inUrl) | Out-Null
  $advContent.Children.Add((& $mkLabel '工作目录')) | Out-Null; $advContent.Children.Add($inDir) | Out-Null
  $advContent.Children.Add((& $mkLabel '启动参数')) | Out-Null; $advContent.Children.Add($inPar) | Out-Null
  $advContent.Children.Add((& $mkLabel '环境变量 KEY=VAL,KEY2=VAL2')) | Out-Null; $advContent.Children.Add($inEnv) | Out-Null
  $adv.Content=$advContent
  $stack.Children.Add($adv) | Out-Null

  $btnPanel=New-Object System.Windows.Controls.StackPanel -Property @{Orientation='Horizontal';HorizontalAlignment='Right';Margin='0,12,0,0'}
  $ok=New-Object System.Windows.Controls.Button -Property @{Content='注册并启动';Padding='16,6';Margin='0,0,8,0';Background=[System.Windows.Media.Brushes]::DodgerBlue;Foreground=[System.Windows.Media.Brushes]::White}
  $cancel=New-Object System.Windows.Controls.Button -Property @{Content='取消';Padding='16,6'}
  [void]$btnPanel.Children.Add($ok); [void]$btnPanel.Children.Add($cancel)
  [void]$stack.Children.Add($btnPanel)

  $f.Content=$stack
  $cancel.Add_Click({ $f.DialogResult=$false; $f.Close() })

  $ok.Add_Click({
    $n=$inName.Text.Trim(); $p=[int]$inPort.Text.Trim(); $exe=$inExe.Text.Trim()
    $url=$inUrl.Text.Trim(); $dir=$inDir.Text.Trim(); $par=$inPar.Text.Trim(); $env=$inEnv.Text.Trim()
    if(-not $n -or -not $exe){ [System.Windows.MessageBox]::Show($f,'服务名和可执行文件必填','错误','OK','Error'); return }
    if ($n -notmatch '^[A-Za-z0-9_.-]+$') { [System.Windows.MessageBox]::Show($f,"服务名含非法字符（仅允许字母数字 . _ -）：$n",'错误','OK','Error'); return }
    if (-not (Test-Path -LiteralPath $exe)) { [System.Windows.MessageBox]::Show($f,"可执行文件不存在：$exe",'错误','OK','Error'); return }
    if($p -lt 1 -or $p -gt 65535){ [System.Windows.MessageBox]::Show($f,'端口必须是 1-65535','错误','OK','Error'); return }
    if($script:svc.Contains($n)){ [System.Windows.MessageBox]::Show($f,"$n 已存在",'错误','OK','Error'); return }
    if(-not $url){ $url="http://127.0.0.1:$p" }
    $envPairs=@()
    if($env){ $envPairs=($env -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
      foreach($pair in $envPairs){
        $kv=$pair -split '=',2
        if($kv.Count -ne 2 -or [string]::IsNullOrWhiteSpace($kv[0])){ [System.Windows.MessageBox]::Show($f,"环境变量格式错误: $pair`n应为 KEY=VAL",'错误','OK','Error'); return }
        if($kv[0].Trim() -eq 'APPDATA' -and $kv[1] -match '^C:\\Users\\'){ [System.Windows.MessageBox]::Show($f,'LocalSystem 服务不能使用交互用户的 APPDATA。','错误','OK','Error'); return }
      }
    }
    try {
      Install-NssmService $n $exe $dir $par $envPairs
    } catch {
      [System.Windows.MessageBox]::Show($f,$_.Exception.Message,'注册失败','OK','Error'); return
    }
    [Threading.Monitor]::Enter($sync.gate)
    try { $script:svc[$n]=@{port=$p;url=$url} } finally { [Threading.Monitor]::Exit($sync.gate) }
    try {
      Save-Svc $script:svc
    } catch {
      # Save-Svc 失败：NSSM 服务已注册且可用，但 services.json 未落盘。
      # 回滚 NSSM 会丢掉一个实际可用的服务，故不自动 remove——提示用户手动迁移。
      [System.Windows.MessageBox]::Show($f,"服务已注册但配置保存失败：$($_.Exception.Message)`n$n 已在 NSSM 注册，请手动将其加入 services.json。",'保存失败','OK','Warning') | Out-Null
      $f.DialogResult=$true; $f.Close(); return
    }
    Send-ServiceCommand $n 'start'
    $f.DialogResult=$true; $f.Close()
  })

  $f.Owner=$owner
  $f.ShowDialog() | Out-Null
}
