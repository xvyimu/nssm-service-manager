# lib/dialogs.ps1 — GUI 对话框：添加服务、删除服务
#
# 从 lib/add-svc.ps1 抽出，使 add-svc.ps1 只剩 CLI 逻辑（Add-SvcFromCli），
# 对话框与 CLI 的共享注册逻辑（Install-NssmService）在 lib/nssm.ps1。
# 依赖加载顺序：Show-Add 用 Test-SvcInput（lib/svc-input.ps1）、Install-NssmService
# （lib/nssm.ps1）、Send-ServiceCommand（lib/util.ps1）、Save-Svc（lib/util.ps1）——
# 主入口按序点源，本文件不自加载。$script:svc / $script:nssm / $logDir / $sync.gate
# 从调用方作用域读。WPF 程序集须由调用方先 Add-Type 加载。

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
    # 校验顺序与 CLI 同（Test-SvcInput）；端口文案 GUI 保留自己的措辞，按 code 覆盖
    $bad = Test-SvcInput $n $p $exe $script:svc
    if($bad){
      $msg = if($bad.code -eq 'port'){ '端口必须是 1-65535' } else { $bad.msg }
      [System.Windows.MessageBox]::Show($f,$msg,'错误','OK','Error'); return
    }
    if(-not $url){ $url="http://127.0.0.1:$p" }
    # GUI 的 env 以逗号分隔（字段分隔符），且多一层格式校验（CLI 不做）
    $envPairs = ConvertTo-EnvPairs $env ','
    $envErr = Test-EnvPairs $envPairs
    if($envErr){ [System.Windows.MessageBox]::Show($f,$envErr,'错误','OK','Error'); return }
    # 敏感键名提示：明文密钥会进注册表 AppEnvironmentExtra（BUILTIN\Users 可读）。
    # 不阻断注册（用户可能确有需要），提示改用 *_FILE 让服务本体从密钥文件读。
    $sensitive = Find-SensitiveEnvKeys $envPairs
    if($sensitive.Count){
      $tip = "以下环境变量将明文写入注册表（BUILTIN\Users 可读）：`n$($sensitive -join ', ')`n`n推荐改用 *_FILE 路径让服务本体从密钥文件读，文件权限收口到 Administrators+SYSTEM。`n仍要继续注册吗？"
      $choice = [System.Windows.MessageBox]::Show($f,$tip,'敏感键名提示','OKCancel','Warning')
      if($choice -ne 'OK'){ return }
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