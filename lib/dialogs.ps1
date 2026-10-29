# lib/dialogs.ps1 — GUI 对话框：添加服务、删除服务
# 依赖调用时解析；从调用方作用域读 $script:svc / $script:cards / $sync.gate / $script:statusBar。
# 实现细节与踩坑记录：docs/IMPLEMENTATION-NOTES.md

# 删除提交体（Show-Remove 的 del_Click 执行部分），抽出以便直测。§Submit-RemoveCommand
function Submit-RemoveCommand([string]$n){
  $script:lastActionAt=[datetime]::Now
  Set-StatusMessage "正在删除 $n ..."
  # 删除入队到后台 runspace（stop/wait/remove 不阻塞 UI），回执由 DispatcherTimer 处理。
  $card = $script:cards[$n]
  # 卡片不在缓存（如翻页外/已重建）也照样入队删除，只是不置过渡态。
  $epoch = Send-ServiceCommand $n 'remove'
  if ($card) { Set-CardTransition $card '删除中' $epoch (Get-Date) }
}

# GUI 删除服务：输入完整服务名才点亮删除（-ceq 区分大小写），避免不可逆误操作。
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

  $input.Add_TextChanged({ $del.IsEnabled = ($input.Text.Trim() -ceq $n) })
  $cancel.Add_Click({ $f.DialogResult=$false; $f.Close() })

  $del.Add_Click({
    # 提交逻辑在 Submit-RemoveCommand，这里只负责关弹窗。
    Submit-RemoveCommand $n
    $f.DialogResult=$true; $f.Close()
  })

  $f.Owner=$owner
  $f.ShowDialog() | Out-Null
}

# MessageBox 入口集中于此（WPF 静态调用会阻塞，测试 dot-source 后重定义即可无头驱动）。
function Show-DialogError($owner,[string]$msg){
  [System.Windows.MessageBox]::Show($owner,$msg,'错误','OK','Error') | Out-Null
}
function Confirm-SensitiveEnvKeys($owner,[string]$tip){
  ([System.Windows.MessageBox]::Show($owner,$tip,'敏感键名提示','OKCancel','Warning')) -eq 'OK'
}
function Show-DialogWarning($owner,[string]$msg,[string]$title){
  [System.Windows.MessageBox]::Show($owner,$msg,$title,'OK','Warning') | Out-Null
}

# 添加提交体（ok_Click 执行部分），$fields 各值已 trim；返回 $true 关弹窗、$false 保持打开。§Submit-AddService
function Submit-AddService($owner,[hashtable]$fields){
  $n=[string]$fields.n; $p=[int]$fields.p; $exe=[string]$fields.exe
  $url=[string]$fields.url; $dir=[string]$fields.dir; $par=[string]$fields.par; $envRaw=[string]$fields.env
  $account=[string]$fields.account; $gpu=[bool]$fields.gpu
  if(-not $n -or -not $exe){ Show-DialogError $owner '服务名和可执行文件必填'; return $false }
  # 校验顺序与 CLI 同（Test-SvcInput）；端口文案 GUI 保留自己的措辞，按 code 覆盖
  $bad = Test-SvcInput $n $p $exe $script:svc
  if($bad){
    $msg = if($bad.code -eq 'port'){ '端口必须是 1-65535' } else { $bad.msg }
    Show-DialogError $owner $msg; return $false
  }
  # 未知账户直接拒——静默回落到 LocalSystem 会让用户以为「按最小权限跑了」。
  $badAcct = Test-SvcAccount $account
  if($badAcct){ Show-DialogError $owner $badAcct.msg; return $false }
  if(-not $url){ $url="http://127.0.0.1:$p" }
  # GUI 的 env 以逗号分隔（字段分隔符），且多一层格式校验（CLI 不做）
  $envPairs = ConvertTo-EnvPairs $envRaw ','
  $envErr = Test-EnvPairs $envPairs
  if($envErr){ Show-DialogError $owner $envErr; return $false }
  # 敏感键名只提示不阻断：明文会进注册表（BUILTIN\Users 可读），建议改用 *_FILE。
  $sensitive = Find-SensitiveEnvKeys $envPairs
  if($sensitive.Count){
    $tip = "以下环境变量将明文写入注册表（BUILTIN\Users 可读）：`n$($sensitive -join ', ')`n`n推荐改用 *_FILE 路径让服务本体从密钥文件读，文件权限收口到 Administrators+SYSTEM。`n仍要继续注册吗？"
    if(-not (Confirm-SensitiveEnvKeys $owner $tip)){ return $false }
  }
  # GPU/桌面程序 + LocalSystem：只提示不阻断（由用户勾选声明，不做自动判断）。
  if($gpu -and (-not $account -or $account -ieq 'LocalSystem')){
    Show-DialogWarning $owner "「$n」将以 LocalSystem 运行。`nGPU/桌面交互程序在 LocalSystem 下未必拿得到显卡或桌面（取决于驱动与会话形态）。`n若启动后异常，改成本机用户账户运行——那需要该账户密码，本工具不代管，请用 nssm edit 或服务管理器修改。" '运行账户提示'
  }
  try {
    Install-NssmService $n $exe $dir $par $envPairs $account
  } catch {
    Show-DialogError $owner $_.Exception.Message; return $false
  }
  $saveErr = Add-SvcEntry $n $p $url
  if ($saveErr) {
    # 服务已注册但没落盘：不 remove（那会丢掉一个实际可用的服务），提示手动迁移并关窗。
    Show-DialogWarning $owner "服务已注册但配置保存失败：$saveErr`n$n 已在 NSSM 注册，请手动将其加入 services.json。" '保存失败'
    return $true
  }
  Send-ServiceCommand $n 'start' | Out-Null   # 返回值是 epoch，函数契约只返回 $true/$false
  $true
}

# 只搭窗口不 ShowDialog，给测试留缝；返回控件句柄供断言。§New-AddDialog
function New-AddDialog(){
  # 高度跟内容走：SizeToContent + MaxHeight，超长时由 ScrollViewer 接管。
  $f = New-Object System.Windows.Window -Property @{
    Title='添加服务'; Width=460; MaxHeight=720; SizeToContent='Height'; WindowStartupLocation='CenterOwner'
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

  # 列表来自 $script:SvcAccounts（白名单与下拉同一份），均为内置账户、无需凭据。§SvcAccounts
  $inAcct=New-Object System.Windows.Controls.ComboBox -Property @{ Margin='0,0,0,8'; FontFamily=$script:cjkFont }
  foreach($a in $script:SvcAccounts){
    [void]$inAcct.Items.Add((New-Object System.Windows.Controls.ComboBoxItem -Property @{Content=$a.Label; Tag=$a.Key}))
  }
  $inAcct.SelectedIndex=0
  $advContent.Children.Add((& $mkLabel '运行账户')) | Out-Null; $advContent.Children.Add($inAcct) | Out-Null
  # 「是不是 GPU/桌面程序」由用户勾选，不做自动判断——按 exe 猜不准，误报比不报更烦。
  $inGpu=New-Object System.Windows.Controls.CheckBox -Property @{
    Content='这是 GPU / 桌面交互程序（需要显卡或桌面）'; FontFamily=$script:cjkFont; Margin='0,4,0,8'
  }
  $advContent.Children.Add($inGpu) | Out-Null
  $adv.Content=$advContent
  $stack.Children.Add($adv) | Out-Null

  $btnPanel=New-Object System.Windows.Controls.StackPanel -Property @{Orientation='Horizontal';HorizontalAlignment='Right';Margin='0,12,0,0'}
  $ok=New-Object System.Windows.Controls.Button -Property @{Content='注册并启动';Padding='16,6';Margin='0,0,8,0';Background=[System.Windows.Media.Brushes]::DodgerBlue;Foreground=[System.Windows.Media.Brushes]::White}
  $cancel=New-Object System.Windows.Controls.Button -Property @{Content='取消';Padding='16,6'}
  [void]$btnPanel.Children.Add($ok); [void]$btnPanel.Children.Add($cancel)
  [void]$stack.Children.Add($btnPanel)

  # 不加滚动，超出窗口高度的控件会被静默裁掉。
  $scroll=New-Object System.Windows.Controls.ScrollViewer -Property @{VerticalScrollBarVisibility='Auto'}
  $scroll.Content=$stack
  $f.Content=$scroll
  # 必须 GetNewClosure()：脚本块非闭包，作用域销毁后变量全为 $null，点按钮静默失败。
  $cancel.Add_Click({ $f.DialogResult=$false; $f.Close() }.GetNewClosure())

  $ok.Add_Click({
    # 提交逻辑在 Submit-AddService；$f 作 MessageBox owner，返回 $true 表示注册成功。
    if (Submit-AddService $f @{ n=$inName.Text.Trim(); p=$inPort.Text.Trim(); exe=$inExe.Text.Trim()
        url=$inUrl.Text.Trim(); dir=$inDir.Text.Trim(); par=$inPar.Text.Trim(); env=$inEnv.Text.Trim()
        account=[string]$inAcct.SelectedItem.Tag; gpu=[bool]$inGpu.IsChecked }) {
      $f.DialogResult=$true; $f.Close()
    }
  }.GetNewClosure())

  # 返回 OK 按钮与输入框句柄：测试要点真按钮走真处理器，才测得出闭包类错误。
  [pscustomobject]@{
    Window = $f; Account = $inAcct; Gpu = $inGpu; Ok = $ok
    Inputs = @{ name=$inName; port=$inPort; exe=$inExe; url=$inUrl; dir=$inDir; par=$inPar; env=$inEnv }
  }
}

# GUI 添加服务对话框：3 必填 + 高级折叠。Owner 只能这里设（WPF 要求 Owner 已显示过）。§Show-Add
function Show-Add($owner){
  $d = New-AddDialog
  $d.Window.Owner = $owner
  $d.Window.ShowDialog() | Out-Null
}
