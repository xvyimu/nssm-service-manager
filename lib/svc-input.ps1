# lib/svc-input.ps1 — 添加服务的纯函数族：输入校验 · env 解析 · NSSM set 规格
# 可被单测直接点源（不加载 WPF / NSSM / 对话框）。Get-NssmSetSpec 读调用方作用域的 $logDir。
# 实现细节与踩坑记录：docs/IMPLEMENTATION-NOTES.md

# CLI 与 GUI 共用的输入校验：通过返回 $null，否则 @{code; msg}（name|exe|port|dup）。§Test-SvcInput
function Test-SvcInput([string]$n,[int]$p,[string]$exe,$existing){
  if($n -notmatch '^[A-Za-z0-9_.-]+$'){ return @{code='name'; msg="服务名含非法字符（仅允许字母数字 . _ -）：$n"} }
  # 拒绝纯 . / ..：路径归一化会指到祖先注册表键。
  if($n -eq '.' -or $n -eq '..'){ return @{code='name'; msg="服务名不能是 . 或 ..（路径归一化会指错注册表键）：$n"} }
  if([string]::IsNullOrWhiteSpace($exe)){ return @{code='exe'; msg='可执行文件路径为空'} }
  # 拒绝 UNC：注册成 LocalSystem 服务后，谁对那个共享有写权谁就能在本机拿到 SYSTEM。
  # 正斜杠写法同样算 UNC：`//localhost/C$/...` 经 Test-Path 是 true，只认反斜杠会被绕过。
  if($exe -match '^[\\/]{2}'){ return @{code='exe'; msg="不支持网络共享路径（共享写者可替换 exe）：$exe"} }
  # drive-relative（`C:foo.exe`）：IsPathRooted 返回 true，但它相对的是 C: 盘当前目录。
  if($exe -match '^[A-Za-z]:(?![\\/])'){ return @{code='exe'; msg="路径不完整（盘符后需要反斜杠）：$exe"} }
  if(-not [IO.Path]::IsPathRooted($exe)){ return @{code='exe'; msg="请填完整路径（相对路径会按服务的工作目录解析）：$exe"} }
  # PathType Leaf：Test-Path 对目录也返回 true，填个文件夹能注册出必然 1053 的服务。
  if(-not (Test-Path -LiteralPath $exe -PathType Leaf)){ return @{code='exe'; msg="可执行文件不存在或不是文件：$exe"} }
  if($p -lt 1 -or $p -gt 65535){ return @{code='port'; msg="端口非法: $p"} }
  if($existing -and $existing.Contains($n)){ return @{code='dup'; msg="$n 已存在"} }
  $null
}

# 按分隔符切分 env：只在下一段含 = 时才断开，值里的分隔符（如 NO_PROXY 里的逗号）原样保留。§ConvertTo-EnvPairs
function ConvertTo-EnvPairs([string]$raw,[string]$separator){
  if(-not $raw){ return @() }
  # 分隔符按字面量切，不按正则（原来直接 -split $separator，传 '|' 之类的分隔符会炸）
  $pairs = [System.Collections.Generic.List[string]]::new()
  foreach($part in ($raw -split [regex]::Escape($separator))){
    $t = $part.Trim()
    if(-not $t){ continue }
    if($pairs.Count -and $t -notmatch '='){
      # 不含 = → 上一段值的续写（NO_PROXY=127.0.0.1,localhost 的 localhost、PATH 的 C:\b）
      $pairs[$pairs.Count-1] = $pairs[$pairs.Count-1] + $separator + $t
    } else { $pairs.Add($t) }
  }
  $pairs.ToArray()
}

# 校验 env 项格式（GUI 专用；CLI 不做此项校验，保持原行为）。返回 $null 或错误消息。
function Test-EnvPairs([object[]]$pairs){
  foreach($pair in $pairs){
    $kv=$pair -split '=',2
    if($kv.Count -ne 2 -or [string]::IsNullOrWhiteSpace($kv[0])){ return "环境变量格式错误: $pair`n应为 KEY=VAL" }
    # 键与值都 Trim 再判：等号后带空格曾绕过 ^C:\\Users\\ 锚定。
    if($kv[0].Trim() -eq 'APPDATA' -and $kv[1].Trim() -match '^C:\\Users\\'){ return 'LocalSystem 服务不能使用交互用户的 APPDATA。' }
  }
  $null
}

# 扫敏感键名（提示用，不阻断）；*_FILE 仅当值像路径时豁免。§Find-SensitiveEnvKeys
function Find-SensitiveEnvKeys([object[]]$pairs){
  if(-not $pairs){ return @() }
  $hits = @()
  foreach($pair in $pairs){
    $kv = $pair -split '=',2
    if($kv.Count -ne 2){ continue }
    $key = $kv[0].Trim()
    # 不收裸 KEY（误报 MONKEY）；PASS 用 (^|[_-])PASS([_-]|$)，\b 对下划线无效。
    if($key -match '(?i)(API[_-]?KEY|APIKEY|TOKEN|SECRET|PASSWORD|PASSWD|PWD|ACCESS[_-]?KEY|CREDENTIAL|PRIVATE[_-]?KEY|PASSPHRASE|SIGNING[_-]?KEY|_AUTH|_SALT|_PAT$|_WEBHOOK)|(^|[_-])PASS([_-]|$)'){
      $looksLikePath = $kv[1] -match '^[A-Za-z]:[\\/]|^\\\\|^\.{1,2}[\\/]|^/'
      if($key -notmatch '(?i)_FILE$' -or -not $looksLikePath){ $hits += $key }
    }
  }
  $hits
}

# 运行账户白名单：仅三个内置账户（nssm 按 well-known SID 免密）。不支持自定义账户——密码只能走 argv，进程列表可见。下拉直接从这里建。§SvcAccounts
$script:SvcAccounts = @(
  @{ Key='LocalSystem';                 Label='LocalSystem（默认，权限最高）' }
  @{ Key='NT AUTHORITY\LocalService';   Label='LocalService（本地服务，最小权限）' }
  @{ Key='NT AUTHORITY\NetworkService'; Label='NetworkService（网络服务，以计算机身份访网）' }
)

function Test-SvcAccount([string]$account){
  if (-not $account) { return $null }
  if ($script:SvcAccounts.Key -contains $account) { return $null }
  return @{code='account'; msg="不支持的运行账户：$account`n仅支持 $(($script:SvcAccounts.Key) -join ' / ')"}
}

# NSSM set 键值序列（不含 install 与回滚）；参数默认值与 config.ps1 一致，本文件保持纯函数。§Get-NssmSetSpec
function Get-NssmSetSpec([string]$n,[string]$dir,[string]$par,[object[]]$envPairs,
                         [int]$rotateBytes = 5242880, [int]$stopMethodMs = 5000,
                         [string]$account = '', [int]$rotateSeconds = 86400){
  $spec = [System.Collections.Generic.List[object]]::new()
  if($dir){ $spec.Add(@{k='AppDirectory'; v=@($dir)}) }
  if($par){ $spec.Add(@{k='AppParameters'; v=@($par)}) }
  $spec.Add(@{k='AppStdout'; v=@("$logDir\$n.out.log")})
  $spec.Add(@{k='AppStderr'; v=@("$logDir\$n.err.log")})
  $spec.Add(@{k='AppStdoutCreationDisposition'; v=@(4)})
  $spec.Add(@{k='AppStderrCreationDisposition'; v=@(4)})
  $spec.Add(@{k='AppRotateFiles'; v=@(1)})
  $spec.Add(@{k='AppRotateOnline'; v=@(1)})
  $spec.Add(@{k='AppRotateBytes'; v=@($rotateBytes)})
  # 年龄门槛：文件至少活 N 秒才允许轮转，避免频繁重启堆积日志档。
  $spec.Add(@{k='AppRotateSeconds'; v=@($rotateSeconds)})
  $spec.Add(@{k='AppStopMethodConsole'; v=@($stopMethodMs)})
  $spec.Add(@{k='Start'; v=@('SERVICE_DEMAND_START')})
  $spec.Add(@{k='AppExit'; v=@('Default','Ignore')})
  # LocalSystem 是 install 默认值，不必 set（让没选与显式选走同一路径）。
  if ($account -and $account -ine 'LocalSystem') { $spec.Add(@{k='ObjectName'; v=@($account)}) }
  if($envPairs -and $envPairs.Count){ $spec.Add(@{k='AppEnvironmentExtra'; v=@($envPairs)}) }
  $spec
}
