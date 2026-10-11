# lib/dialogs.ps1 — GUI 对话框：添加服务、删除服务
#
# 从 lib/add-svc.ps1 抽出，使 add-svc.ps1 只剩 CLI 逻辑（Add-SvcFromCli），
# 对话框与 CLI 的共享注册逻辑（Install-NssmService）在 lib/nssm.ps1。
#
# 依赖（均为「调用时解析」，PowerShell 函数体内符号延迟绑定——点源顺序不影响正确性，
# 只要调用发生在全部模块加载之后，即 GUI 运行时）：
#   Show-Add    → Test-SvcInput（svc-input.ps1）、Install-NssmService（nssm.ps1）、
#                 Send-ServiceCommand / Save-Svc（util.ps1）
#   Show-Remove → Set-CardTransition（card.ps1）、Send-ServiceCommand（util.ps1）
# 注意本文件与 card.ps1 是**双向**依赖（card.ps1 右键菜单调 Show-Remove），
# 故二者在加载顺序上不分先后。$script:svc / $script:cards / $script:nssm / $logDir /
# $sync.gate / $script:statusBar 从调用方作用域读。WPF 程序集须由调用方先 Add-Type 加载。

# 删除提交体（Show-Remove 的 del_Click 真正执行的部分）。抽出来是为了可直测：
# 弹模态框的 Click 在测试里够不着，但「入队 remove 命令 + 置卡片过渡态」这段才是会写错的
# 地方（曾因两处字段集不一致漏了 LastToggle/ReadyToToggle，配合 Update-CardData 守卫缺失
# 导致删除中卡片被探测结果刷回「已停止」）。
function Submit-RemoveCommand([string]$n){
  $script:lastActionAt=[datetime]::Now
  Set-StatusMessage "正在删除 $n ..."
  # 删除走后台命令队列（act=remove），避免 UI 线程同步等 stop+Wait-Stopped+remove 冻结界面。
  # 真正的 stop/wait/remove 在 runspace 里执行；这里只入队，回执由 DispatcherTimer 处理。
  $card = $script:cards[$n]
  if ($card) {
    # 过渡态设置与启停共用（card.ps1 Set-CardTransition）。
    $epoch = Send-ServiceCommand $n 'remove'
    Set-CardTransition $card '删除中' $epoch (Get-Date)
  } else {
    # 卡片不在缓存（如翻页外/已重建）：仍要入队删除，但不置过渡态。
    Send-ServiceCommand $n 'remove' | Out-Null
  }
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
    Background=$script:T.Danger
    Foreground=[System.Windows.Media.Brushes]::White
  }
  [void]$btnPanel.Children.Add($cancel); [void]$btnPanel.Children.Add($del)
  [void]$stack.Children.Add($btnPanel)
  $f.Content=$stack

  # 精确匹配（-ceq 区分大小写）才点亮删除按钮
  $input.Add_TextChanged({ $del.IsEnabled = ($input.Text.Trim() -ceq $n) })
  $cancel.Add_Click({ $f.DialogResult=$false; $f.Close() })

  $del.Add_Click({
    # 提交逻辑抽到 Submit-RemoveCommand 以便直测（模态框测不了，但提交体是真正会写错的
    # 部分——曾因字段集不一致漏了 LastToggle/ReadyToToggle）。这里只负责关弹窗。
    Submit-RemoveCommand $n
    $f.DialogResult=$true; $f.Close()
  })

  $f.Owner=$owner
  $f.ShowDialog() | Out-Null
}

# 弹框入口集中两处，便于测试替身（MessageBox 是 WPF 静态调用，测试里会阻塞）。
# 生产用真 MessageBox；测试 dot-source 后重定义这两个函数即可无头驱动 Submit-AddService。
function Show-DialogError($owner,[string]$msg){
  [System.Windows.MessageBox]::Show($owner,$msg,'错误','OK','Error') | Out-Null
}
function Confirm-SensitiveEnvKeys($owner,[string]$tip){
  ([System.Windows.MessageBox]::Show($owner,$tip,'敏感键名提示','OKCancel','Warning')) -eq 'OK'
}
function Show-DialogWarning($owner,[string]$msg,[string]$title){
  [System.Windows.MessageBox]::Show($owner,$msg,$title,'OK','Warning') | Out-Null
}

# 添加提交体（Show-Add 的 ok_Click 真正执行的部分）。$fields 各值是调用方 trim 过的字符串。
# 返回 $true 表示流程走到「关闭弹窗」（注册成功，或注册成功但保存失败——两种情况都关）；
# $false 表示被校验/确认拦下，弹窗应保持打开让用户改。
# 抽出来是为了可直测：校验顺序、Test-EnvPairs、敏感键 OKCancel 分支、Save 失败分支
# 原本全内联在 Click 里，没有测试缝。
function Submit-AddService($owner,[hashtable]$fields){
  $n=[string]$fields.n; $p=[int]$fields.p; $exe=[string]$fields.exe
  $url=[string]$fields.url; $dir=[string]$fields.dir; $par=[string]$fields.par; $envRaw=[string]$fields.env
  if(-not $n -or -not $exe){ Show-DialogError $owner '服务名和可执行文件必填'; return $false }
  # 校验顺序与 CLI 同（Test-SvcInput）；端口文案 GUI 保留自己的措辞，按 code 覆盖
  $bad = Test-SvcInput $n $p $exe $script:svc
  if($bad){
    $msg = if($bad.code -eq 'port'){ '端口必须是 1-65535' } else { $bad.msg }
    Show-DialogError $owner $msg; return $false
  }
  if(-not $url){ $url="http://127.0.0.1:$p" }
  # GUI 的 env 以逗号分隔（字段分隔符），且多一层格式校验（CLI 不做）
  $envPairs = ConvertTo-EnvPairs $envRaw ','
  $envErr = Test-EnvPairs $envPairs
  if($envErr){ Show-DialogError $owner $envErr; return $false }
  # 敏感键名提示：明文密钥会进注册表 AppEnvironmentExtra（BUILTIN\Users 可读）。
  # 不阻断注册（用户可能确有需要），提示改用 *_FILE 让服务本体从密钥文件读。
  $sensitive = Find-SensitiveEnvKeys $envPairs
  if($sensitive.Count){
    $tip = "以下环境变量将明文写入注册表（BUILTIN\Users 可读）：`n$($sensitive -join ', ')`n`n推荐改用 *_FILE 路径让服务本体从密钥文件读，文件权限收口到 Administrators+SYSTEM。`n仍要继续注册吗？"
    if(-not (Confirm-SensitiveEnvKeys $owner $tip)){ return $false }
  }
  try {
    Install-NssmService $n $exe $dir $par $envPairs
  } catch {
    Show-DialogError $owner $_.Exception.Message; return $false
  }
  [Threading.Monitor]::Enter($sync.gate)
  try { $script:svc[$n]=@{port=$p;url=$url} } finally { [Threading.Monitor]::Exit($sync.gate) }
  try {
    Save-Svc $script:svc
  } catch {
    # Save-Svc 失败：NSSM 服务已注册且可用，但 services.json 未落盘。
    # 回滚 NSSM 会丢掉一个实际可用的服务，故不自动 remove——提示用户手动迁移。
    Show-DialogWarning $owner "服务已注册但配置保存失败：$($_.Exception.Message)`n$n 已在 NSSM 注册，请手动将其加入 services.json。" '保存失败'
    return $true   # 服务已注册，关弹窗（与成功一致）
  }
  Send-ServiceCommand $n 'start'
  $true
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
    # 提交逻辑抽到 Submit-AddService 以便直测（校验顺序、Test-EnvPairs、敏感键 OKCancel
    # 分支、Save 失败分支原本全内联在 Click 里，没有测试缝）。$f 作 owner 供 MessageBox 用。
    # 返回 $true 表示注册成功（调用方据此关弹窗）。
    if (Submit-AddService $f @{ n=$inName.Text.Trim(); p=$inPort.Text.Trim(); exe=$inExe.Text.Trim()
        url=$inUrl.Text.Trim(); dir=$inDir.Text.Trim(); par=$inPar.Text.Trim(); env=$inEnv.Text.Trim() }) {
      $f.DialogResult=$true; $f.Close()
    }
  })

  $f.Owner=$owner
  $f.ShowDialog() | Out-Null
}
