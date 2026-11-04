# lib/dialogs.ps1 — GUI 对话框：添加服务、删除服务
# 依赖调用时解析；从调用方作用域读 $script:svc / $script:cards / $sync.gate / $script:statusBar。
# 实现细节与踩坑记录：docs/IMPLEMENTATION-NOTES.md

# exe 目录是否对普通用户可写（LocalSystem 服务的提权面）。缺依赖或读不到 ACL 时一律当「否」——
# 这是告警不是门闩，误报比漏报更烦人。抽成函数让单测能 stub，不受运行机器真实 ACL 影响。
function Test-ExeDirPermissive([string]$exe){
  if (-not $exe) { return $false }
  if (-not (Get-Command Test-DirAclPermissive -EA SilentlyContinue)) { return $false }
  try {
    $dir = Split-Path $exe -Parent
    if (-not $dir) { return $false }
    return ((Test-DirAclPermissive (Get-Acl -LiteralPath $dir -EA Stop)) -eq '是')
  } catch { return $false }
}

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
  $wa = [System.Windows.SystemParameters]::WorkArea
  $maxH = if ($wa.Height -gt 0) { [int][math]::Min(480, [math]::Floor($wa.Height * 0.8)) } else { 420 }
  $f = New-Object System.Windows.Window -Property @{
    Title="删除服务 $n"; Width=440; SizeToContent='Height'; MaxHeight=$maxH; MinHeight=200
    WindowStartupLocation='CenterOwner'; Background=[System.Windows.Media.Brushes]::White; ResizeMode='NoResize'
  }
  $stack=New-Object System.Windows.Controls.StackPanel -Property @{Margin='15'}
  $warn=New-Object System.Windows.Controls.TextBlock -Property @{
    Text="将从 NSSM 删除服务「$n」并移除配置。`n此操作不可撤销：服务会先停止再删除。`n`n输入完整服务名以确认："
    FontFamily=$script:cjkFont; FontSize=12; TextWrapping='Wrap'
  }
  [void]$stack.Children.Add($warn)
  # 不要叫 $input：那是 PowerShell 的自动变量（管道输入枚举器），遮蔽它迟早出怪事。
  $confirmBox=New-Object System.Windows.Controls.TextBox -Property @{FontFamily=$script:cjkFont; FontSize=13; Margin='0,8,0,4'}
  [void]$stack.Children.Add($confirmBox)
  # 实时差量：还差 N 个字符 / 大小写不一致 / 名称一致，给到删除前最后一眼确认。
  $hint=New-Object System.Windows.Controls.TextBlock -Property @{
    FontFamily=$script:cjkFont; FontSize=11; Foreground=$script:T.Dim; Margin='0,0,0,12'
  }
  [void]$stack.Children.Add($hint)

  $btnPanel=New-Object System.Windows.Controls.StackPanel -Property @{Orientation='Horizontal';HorizontalAlignment='Right'}
  $cancel=New-Object System.Windows.Controls.Button -Property @{Content='取消';Padding='16,6';Margin='0,0,8,0'; IsCancel=$true}
  $del=New-Object System.Windows.Controls.Button -Property @{
    Content='删除'; Padding='16,6'; IsEnabled=$false; IsDefault=$true
    Background=$script:T.Danger
    Foreground=[System.Windows.Media.Brushes]::White
  }
  [void]$btnPanel.Children.Add($cancel); [void]$btnPanel.Children.Add($del)
  [void]$stack.Children.Add($btnPanel)
  # 内容超长时（小屏 / 极长服务名）能滚，而不是把删除按钮顶出屏幕。
  $scroll = New-Object System.Windows.Controls.ScrollViewer -Property @{
    Content=$stack; VerticalScrollBarVisibility='Auto'; HorizontalScrollBarVisibility='Disabled'
    Padding='0'; Margin='0'
  }
  $f.Content=$scroll

  $updateHint = {
    $t = $confirmBox.Text.Trim()
    if (-not $t) {
      $hint.Text = ''; $hint.Visibility = 'Collapsed'
    } elseif ($t -ceq $n) {
      $hint.Text = '名称一致，可以删除'; $hint.Foreground = $script:T.BrushOk; $hint.Visibility = 'Visible'
    } elseif ($t -ieq $n) {
      $hint.Text = '大小写不一致（区分大小写才能删除）'; $hint.Foreground = $script:T.BrushBusy; $hint.Visibility = 'Visible'
    } elseif ($n.StartsWith($t, [System.StringComparison]::OrdinalIgnoreCase)) {
      # 只看「还差几个字符」时不较真大小写：真正卡住提交的是大小写，那句提示在上面单独给。
      $remain = $n.Length - $t.Length
      $hint.Text = "还差 $remain 个字符"; $hint.Foreground = $script:T.BrushDim; $hint.Visibility = 'Visible'
    } else {
      $hint.Text = '与服务名不一致'; $hint.Foreground = $script:T.BrushDim; $hint.Visibility = 'Visible'
    }
  }
  $onText = {
    $del.IsEnabled = ($confirmBox.Text.Trim() -ceq $n)
    & $updateHint
  }
  $cancel.Add_Click({ $f.DialogResult=$false; $f.Close() })
  # GetNewClosure 把弹窗局部变量（$n/$del/$hint/...）封进处理器；不封的话事件回调在全局
  # 作用域解析，一律是 $null（$ErrorActionPreference=Stop 下第一次输入就抛）。
  $confirmBox.Add_TextChanged($onText.GetNewClosure())
  & $updateHint   # 初始就给一次提示，免得空框时按钮灰着、用户不知道要输入到哪一步

  $del.Add_Click({
    # 提交逻辑在 Submit-RemoveCommand，这里只负责关弹窗。抛错时不要关窗：状态栏被模态窗口
    # 盖住，用户只会看到「点了没反应」，然后反复点。
    try { Submit-RemoveCommand $n }
    catch { Show-DialogError $f $_.Exception.Message; return }
    $f.DialogResult=$true; $f.Close()
  }.GetNewClosure())

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

# 批量停止的二次确认。停止可逆，但一次误点会停掉整台机器的服务，所以给一次 OKCancel。
# 单独成函数是为了让无头测试能重定义它（MessageBox 会真弹窗）。
# 名单：≤6 个全列，多出来的只报个数——确认框不该因为服务多就变成一屏文字。
function Format-BatchStopMessage([string[]]$names){
  $all = @($names | Where-Object { $_ })
  $count = $all.Count
  if ($count -eq 0) { return '将停止 0 个正在运行的服务，继续？' }
  if ($count -le 6) {
    "将停止 $count 个正在运行的服务：`n`n$($all -join '、')`n`n继续？"
  } else {
    $head = ($all[0..5] -join '、')
    "将停止 $count 个正在运行的服务：`n`n$head 等 $count 个`n`n继续？"
  }
}

function Confirm-BatchStop($owner,[int]$count,[string[]]$names){
  # 老调用点只传个数，没有名单时退回纯计数文案。
  $msg = if ($PSBoundParameters.ContainsKey('names') -and $names) { Format-BatchStopMessage $names } else { "将停止 $count 个正在运行的服务，继续？" }
  ([System.Windows.MessageBox]::Show($owner,$msg,'全部停止','OKCancel','Warning')) -eq 'OK'
}

# 有在途命令时退出，问一句「仍要退出吗」。同样单独成函数：MessageBox 在无头测试进程里
# 会真弹窗并永久阻塞（run-all 给子进程设 NSSM_SM_HEADLESS=1，这里直接放行）。§Confirm-ExitBusy
function Confirm-ExitBusy($owner,[string]$what){
  if ($env:NSSM_SM_HEADLESS -eq '1') { return $true }
  # 没有可见窗口时没人能点这个框，MessageBox 会一直卡住调用方（无头测试、或被代码直接 Close）：
  # 这种情况按「允许退出」处理。生产里用户点 X 时窗口是可见的，照常问。
  if (-not $owner -or -not $owner.IsVisible) { return $true }
  ([System.Windows.MessageBox]::Show($owner,
    "$what。`n`n现在退出，这些操作可能在没人看的情况下完成，或停在中间状态。`n下次启动会重新查询真实状态。`n`n仍要退出吗？",
    '有操作在途','YesNo','Warning','No')) -eq 'Yes'
}

# 添加提交体（ok_Click 执行部分），$fields 各值已 trim；返回 $true 关弹窗、$false 保持打开。§Submit-AddService
function Submit-AddService($owner,[hashtable]$fields){
  $n=[string]$fields.n; $exe=[string]$fields.exe
  # 端口先 TryParse 再进 Test-SvcInput：原来直接 [int] 强转，输入 "3000ms" 会在校验之前抛异常，
  # 异常冒到 Dispatcher 兜底只写状态栏（被模态窗盖住）= 点了什么都没发生。
  $p=0
  if(-not [int]::TryParse([string]$fields.p,[ref]$p)){ Show-DialogError $owner '端口必须是 1-65535 的整数'; return $false }
  $url=[string]$fields.url; $dir=[string]$fields.dir; $par=[string]$fields.par; $envRaw=[string]$fields.env
  $account=[string]$fields.account; $gpu=[bool]$fields.gpu
  # 探测口径：auto（缺省，TCP 通且 HTTP 200）/ tcp（TCP 通即正常）/ http。
  # 非 HTTP 服务（数据库、gRPC、纯 socket）必须选 tcp，否则卡片永远不是绿点。§Read-SvcFile
  $probe=([string]$fields.probe).Trim().ToLowerInvariant()
  if($probe -notin @('auto','tcp','http')){ $probe='auto' }
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
  # tcp 口径不填 URL：非 HTTP 服务写面板地址只会让人以为探测按 HTTP 走。
  if($probe -eq 'tcp'){ $url='' } elseif(-not $url){ $url="http://127.0.0.1:$p" }
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
  # LocalSystem + 用户可写目录：UNC 已被拒，本地可写目录是同一根因（scoop 装出来的服务就长这样）。
  # 只提示不阻断：阻断会直接打断现有部署；先把「可被替换」这件事说出来。
  # 判定抽成函数：单测不该受运行机器真实 ACL 影响，stub 它即可。
  if((-not $account -or $account -ieq 'LocalSystem') -and (Test-ExeDirPermissive $exe)){
    Show-DialogWarning $owner "「$n」将以 LocalSystem 运行，但可执行文件位于普通用户可写的目录：`n$(Split-Path $exe -Parent)`n`n该目录的任何可写者都能替换 exe，服务重启后即以 SYSTEM 运行。`n建议先把程序移到仅管理员可写的目录，再注册服务。" '安全姿态提示'
  }
  # 幂等续做：上次注册成功但清单没写成时，重试会走到这里。再 install 只会报「已存在」，
  # 因此已存在就只补写参数——用户点重试即可收敛，不必先 nssm remove 再重来。
  $alreadyRegistered = $false
  try { $alreadyRegistered = Test-ServicePresent $n } catch {}
  try {
    if ($alreadyRegistered) { Set-NssmServiceParams $n $exe $dir $par $envPairs $account }
    else { Install-NssmService $n $exe $dir $par $envPairs $account }
  } catch {
    Show-DialogError $owner $_.Exception.Message; return $false
  }
  $saveErr = Add-SvcEntry $n $p $url $probe
  if ($saveErr) {
    # 服务已注册但没落盘：不 remove（那会丢掉一个实际可用的服务）。**保持窗口**：关窗会让人以为
    # 「没加成」，常见反应是再填一次 → NSSM 报服务已存在，越描越乱。§Submit-AddService
    Show-DialogError $owner "服务已在 NSSM 注册但没写入清单：$saveErr`n`n修好配置后点「注册并启动」重试——已注册的服务会直接补写清单，不会重复 install。"
    return $false
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
  $mkLabel={ param($t) New-Object System.Windows.Controls.TextBlock -Property @{Text=$t;Margin='0,8,0,2';FontFamily=$script:cjkFont;Foreground=$script:T.Dim} }
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
  # 探测方式：默认 auto；数据库/gRPC/纯 socket 选 tcp，否则 HTTP 探测必然失败、卡片永远橙点。
  $inProbe=New-Object System.Windows.Controls.ComboBox -Property @{ Margin='0,0,0,8'; FontFamily=$script:cjkFont }
  [void]$inProbe.Items.Add((New-Object System.Windows.Controls.ComboBoxItem -Property @{Content='自动（TCP 通且 HTTP 200）'; Tag='auto'}))
  [void]$inProbe.Items.Add((New-Object System.Windows.Controls.ComboBoxItem -Property @{Content='只探测 TCP（数据库 / gRPC / 纯 socket）'; Tag='tcp'}))
  $inProbe.SelectedIndex=0
  $advContent.Children.Add((& $mkLabel '探测方式')) | Out-Null; $advContent.Children.Add($inProbe) | Out-Null
  # 选 tcp 时置空并禁用 URL：非 HTTP 服务填了面板地址只会误导（GetNewClosure：闭包要持有 $inUrl）。
  $inProbe.Add_SelectionChanged({
    param($sender,$eventArgs)
    $tcp = ([string]$sender.SelectedItem.Tag -eq 'tcp')
    if ($tcp) { $inUrl.Text = '' }
    $inUrl.IsEnabled = -not $tcp
  }.GetNewClosure())
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
        probe=[string]$inProbe.SelectedItem.Tag
        account=[string]$inAcct.SelectedItem.Tag; gpu=[bool]$inGpu.IsChecked }) {
      $f.DialogResult=$true; $f.Close()
    }
  }.GetNewClosure())

  # 返回 OK 按钮与输入框句柄：测试要点真按钮走真处理器，才测得出闭包类错误。
  [pscustomobject]@{
    Window = $f; Account = $inAcct; Gpu = $inGpu; Ok = $ok; Probe = $inProbe
    Inputs = @{ name=$inName; port=$inPort; exe=$inExe; url=$inUrl; dir=$inDir; par=$inPar; env=$inEnv }
  }
}

# GUI 添加服务对话框：3 必填 + 高级折叠。Owner 只能这里设（WPF 要求 Owner 已显示过）。§Show-Add
function Show-Add($owner){
  $d = New-AddDialog
  $d.Window.Owner = $owner
  $d.Window.ShowDialog() | Out-Null
}
