# lib/add-svc.ps1 — 添加服务（GUI 简化 + CLI agent 友好）
# 人：3 必填（服务名/exe/端口）+ 高级折叠（URL/工作目录/启动参数/env）
# agent：-Add Name,Port,Exe[,Url,Dir,Args,Env] 不弹 GUI
# 自加载 config：CLI 模式（-Add）分支不加载 config.ps1，Wait-Stopped 需要默认值
if (-not $script:config) { . (Join-Path $PSScriptRoot 'config.ps1') }

# ---- 纯函数：可被单测直接调用，不含副作用 ----

# CLI 与 GUI 共用的输入校验。通过返回 $null，否则返回 @{code; msg}。
# code ∈ name|exe|port|dup。GUI 的端口文案与 CLI 不同，调用方按 code 自行覆盖 msg。
# 调用顺序与两处原逻辑一致（名称 → 可执行文件 → 端口 → 重名），保持报错优先级不变。
function Test-SvcInput([string]$n,[int]$p,[string]$exe,$existing){
  if($n -notmatch '^[A-Za-z0-9_.-]+$'){ return @{code='name'; msg="服务名含非法字符（仅允许字母数字 . _ -）：$n"} }
  if(-not (Test-Path -LiteralPath $exe)){ return @{code='exe'; msg="可执行文件不存在：$exe"} }
  if($p -lt 1 -or $p -gt 65535){ return @{code='port'; msg="端口非法: $p"} }
  if($existing -and $existing.Contains($n)){ return @{code='dup'; msg="$n 已存在"} }
  $null
}

# 按分隔符切分 env 字符串为去空白的非空项。CLI 用 ';'，GUI 用 ','（字段分隔符占用逗号）。
function ConvertTo-EnvPairs([string]$raw,[string]$separator){
  if(-not $raw){ return @() }
  @($raw -split $separator | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# 校验 env 项格式（GUI 专用；CLI 不做此项校验，保持原行为）。返回 $null 或错误消息。
function Test-EnvPairs([object[]]$pairs){
  foreach($pair in $pairs){
    $kv=$pair -split '=',2
    if($kv.Count -ne 2 -or [string]::IsNullOrWhiteSpace($kv[0])){ return "环境变量格式错误: $pair`n应为 KEY=VAL" }
    if($kv[0].Trim() -eq 'APPDATA' -and $kv[1] -match '^C:\\Users\\'){ return 'LocalSystem 服务不能使用交互用户的 APPDATA。' }
  }
  $null
}

# 扫 env 项里的敏感键名（GUI/CLI 共用，提示性，不阻断）。返回命中项的键名列表，无则空。
# 命中 *_API_KEY / *_TOKEN / *SECRET / *PASSWORD / *ACCESS_KEY / *CREDENTIAL /
# *PRIVATE_KEY / *PASSPHRASE 等键名时，值会随 NSSM AppEnvironmentExtra
# 明文进注册表 HKLM\...\Parameters，该键 ACL 默认 BUILTIN\Users 可读——本机标准用户能读出。
# *_FILE 后缀本意是「让服务本体从独立密钥文件读，路径不进注册表」——但仅在值看起来像路径时
# 才跳过；否则视为有人把真密钥塞进了 *_FILE 变量，照样提示（键名后缀不等于值就是路径）。
function Find-SensitiveEnvKeys([object[]]$pairs){
  if(-not $pairs){ return @() }
  $hits = @()
  foreach($pair in $pairs){
    $kv = $pair -split '=',2
    if($kv.Count -ne 2){ continue }
    $key = $kv[0].Trim()
    if($key -match '(?i)API_KEY|TOKEN|SECRET|PASSWORD|ACCESS_KEY|CREDENTIAL|PRIVATE_KEY|PASSPHRASE|PWD'){
      $looksLikePath = $kv[1] -match '^[A-Za-z]:[\\/]|^\\\\|^\.{1,2}[\\/]|^/'
      if($key -notmatch '(?i)_FILE$' -or -not $looksLikePath){ $hits += $key }
    }
  }
  $hits
}

# NSSM 注册后需要 set 的键值序列（不含 install 与失败回滚）。抽出来是为可单测参数组合：
# AppExit 双 token、AppEnvironmentExtra 多 token 这类容易被展开方式搞错的地方。
function Get-NssmSetSpec([string]$n,[string]$dir,[string]$par,[object[]]$envPairs){
  $spec = [System.Collections.Generic.List[object]]::new()
  if($dir){ $spec.Add(@{k='AppDirectory'; v=@($dir)}) }
  if($par){ $spec.Add(@{k='AppParameters'; v=@($par)}) }
  $spec.Add(@{k='AppStdout'; v=@("$logDir\$n.out.log")})
  $spec.Add(@{k='AppStderr'; v=@("$logDir\$n.err.log")})
  $spec.Add(@{k='AppStdoutCreationDisposition'; v=@(4)})
  $spec.Add(@{k='AppStderrCreationDisposition'; v=@(4)})
  $spec.Add(@{k='AppRotateFiles'; v=@(1)})
  $spec.Add(@{k='AppRotateOnline'; v=@(1)})
  $spec.Add(@{k='AppRotateBytes'; v=@(5242880)})
  $spec.Add(@{k='AppStopMethodConsole'; v=@(5000)})
  $spec.Add(@{k='Start'; v=@('SERVICE_DEMAND_START')})
  $spec.Add(@{k='AppExit'; v=@('Default','Ignore')})
  if($envPairs -and $envPairs.Count){ $spec.Add(@{k='AppEnvironmentExtra'; v=@($envPairs)}) }
  $spec
}

# GUI/CLI 共用 NSSM 注册与配置；输入校验、错误显示、保存和启动仍由调用方处理。
function Install-NssmService([string]$n,[string]$exe,[string]$dir,[string]$par,$envPairs){
  $nssmOut=& $script:nssm install $n $exe 2>&1
  if($LASTEXITCODE -ne 0){ throw "NSSM install 失败($LASTEXITCODE): $($nssmOut -join ' ')" }
  # install 成功后服务已进服务数据库；任意 set 失败都会留下配置不全的半注册残骸
  # （无日志重定向/轮转/AppExit）。失败时尽力 remove 回滚，再抛原始错误。
  try {
    foreach($s in Get-NssmSetSpec $n $dir $par $envPairs){ nssm-set $n $s.k $s.v }
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
  $url=if($parts.Count -gt 3){$parts[3].Trim()}else{"http://127.0.0.1:$p"}
  $dir=if($parts.Count -gt 4){$parts[4].Trim()}else{''}
  $par=if($parts.Count -gt 5){$parts[5].Trim()}else{''}
  # Env：第 7 段往后全部属于 Env（Args 可能含逗号的情况不处理——Args 不应含逗号）
  # 多对 env 用分号分隔，避免与字段逗号冲突
  $envRaw=if($parts.Count -gt 6){($parts[6..($parts.Count-1)] -join ',').Trim()}else{''}
  # 校验顺序：名称 → 可执行文件 → 端口 → 重名（与 GUI 同，抽进 Test-SvcInput）
  $bad = Test-SvcInput $n $p $exe $script:svc
  if($bad){ Write-Host $bad.msg; exit 1 }
  $envPairs = ConvertTo-EnvPairs $envRaw ';'
  try {
    Install-NssmService $n $exe $dir $par $envPairs
  } catch { Write-Host "注册失败: $($_.Exception.Message)"; exit 1 }
  # 敏感键名提示：明文密钥会进注册表 AppEnvironmentExtra（BUILTIN\Users 可读）。
  # CLI 不阻断，只把命中键名列出来提示用户改用 *_FILE。
  $sensitive = Find-SensitiveEnvKeys $envPairs
  if ($sensitive.Count) {
    Write-Host "提示: 以下环境变量将明文写入注册表（BUILTIN\Users 可读）：$($sensitive -join ', ')"
    Write-Host "      推荐改用 *_FILE 路径让服务本体从密钥文件读，文件权限收口到 Administrators+SYSTEM。"
  }
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
# 该实现读 $sync 注入的超时（UI 线程里即 $script:sync.waitStoppedTimeoutMs），无 $sync 时回落 config.ps1。
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
