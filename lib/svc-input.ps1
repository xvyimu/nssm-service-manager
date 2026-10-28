# lib/svc-input.ps1 — 添加服务的纯函数族：输入校验 · env 解析 · NSSM set 规格
#
# 从 lib/add-svc.ps1 抽出，使纯函数可被单测直接点源（不加载 WPF / NSSM / 对话框）。
# 无副作用：不碰文件系统（除 Test-Path 校验）、不调 sc.exe/nssm、不弹 UI。
#
# 【作用域约定】Get-NssmSetSpec 读调用方作用域的 $logDir（dot-source 时由
# service-manager-gui.ps1 / 各测试赋值），不是模块级变量。调用方必须在
# dot-source 之后赋值，否则 $logDir 为 $null，AppStdout/Stderr 路径拼出空段。

# CLI 与 GUI 共用的输入校验。通过返回 $null，否则返回 @{code; msg}。
# code ∈ name|exe|port|dup。GUI 的端口文案与 CLI 不同，调用方按 code 自行覆盖 msg。
# 调用顺序与两处原逻辑一致（名称 → 可执行文件 → 端口 → 重名），保持报错优先级不变。
function Test-SvcInput([string]$n,[int]$p,[string]$exe,$existing){
  if($n -notmatch '^[A-Za-z0-9_.-]+$'){ return @{code='name'; msg="服务名含非法字符（仅允许字母数字 . _ -）：$n"} }
  # 拒绝纯 `.` / `..`：它们作为路径段会被归一化（`Services\..` → `Services` 父键），
  # 拼进注册表路径 `...\Services\<名>\Parameters` 时会指到祖先键，脚本可能收紧错的键。
  # 点开头/含点但非纯点段的名字（`.hidden` / `A..B`）合法，放行。
  if($n -eq '.' -or $n -eq '..'){ return @{code='name'; msg="服务名不能是 . 或 ..（路径归一化会指错注册表键）：$n"} }
  if(-not (Test-Path -LiteralPath $exe)){ return @{code='exe'; msg="可执行文件不存在：$exe"} }
  if($p -lt 1 -or $p -gt 65535){ return @{code='port'; msg="端口非法: $p"} }
  if($existing -and $existing.Contains($n)){ return @{code='dup'; msg="$n 已存在"} }
  $null
}

# 按分隔符切分 env 字符串为去空白的非空项。CLI 用 ';'，GUI 用 ','。
# **只在「下一段以 KEY= 开头」时才真断开**：值本身可能含分隔符，最典型的是
# NO_PROXY=127.0.0.1,localhost——原实现无脑 split，逗号把值拆成两段，Test-EnvPairs 随即
# 报「localhost 格式错误」，GUI 里根本填不进多地址 NO_PROXY。
# 「像新变量」的判据就是**这一段里有 `=`**——不能收紧成 `^[A-Za-z_]\w*=`：合法的 Windows
# 变量名可以数字开头（2FA_TOKEN），也可以带括号（ProgramFiles(x86)），收紧会把它们并进上一个值，
# 变量根本不进 AppEnvironmentExtra，连敏感键检测也扫不到。
# 也不能要求 `=` 前无空白：`B = 2` 是合法的 env 写法（Test-EnvPairs 会 Trim）。
# 反例（有意不处理）：值里出现形如 x=1 的片段（如 URL 查询串）会被当成新变量。
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
    # 键与值都 Trim 再判：`APPDATA= C:\Users\x`（等号后带空格）此前绕过检测——$kv[1] 未 Trim，
    # 正则锚 `^C:\\Users\\` 匹配不到前导空格。
    if($kv[0].Trim() -eq 'APPDATA' -and $kv[1].Trim() -match '^C:\\Users\\'){ return 'LocalSystem 服务不能使用交互用户的 APPDATA。' }
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
    # 键名形态清单：常见密钥/令牌/口令变量名。刻意不收裸 KEY——会误报 MONKEY 这类词。
    # 单独的 PASS 用 (^|[_-])PASS([_-]|$) 匹配 DB_PASS / REDIS_PASS——**不能**用 \bPASS\b：
    # 下划线是 \w，DB_PASS 的 _P 之间没有词边界，\bPASS\b 实测对 DB_PASS 返回 False。
    # APIKEY / PRIVATEKEY 无下划线；*_AUTH / *_SALT / *_PAT / *_WEBHOOK 是常见凭证后缀。
    if($key -match '(?i)(API[_-]?KEY|APIKEY|TOKEN|SECRET|PASSWORD|PASSWD|PWD|ACCESS[_-]?KEY|CREDENTIAL|PRIVATE[_-]?KEY|PASSPHRASE|SIGNING[_-]?KEY|_AUTH|_SALT|_PAT$|_WEBHOOK)|(^|[_-])PASS([_-]|$)'){
      $looksLikePath = $kv[1] -match '^[A-Za-z]:[\\/]|^\\\\|^\.{1,2}[\\/]|^/'
      if($key -notmatch '(?i)_FILE$' -or -not $looksLikePath){ $hits += $key }
    }
  }
  $hits
}

# 运行账户白名单：只有三个内置账户。它们不需要密码——nssm 按 well-known SID 认出来
# （account.cpp 的 well_known_username → password 强制空串），所以一条 argv 就能设。
# 自定义用户账户**故意不支持**：nssm 要求密码，而密码只能作为命令行参数传，
# 同机管理员在进程列表里可见；本工具不引入这个暴露面。需要时用 nssm edit 或服务管理器改。
# 空串 = 不改，沿用 nssm install 的默认（LocalSystem）。
# 对话框的账户下拉直接从这里建（Label 给用户看，Key 传给 nssm）——两处各存一份列表时，
# 加一个账户就得改两边，迟早只剩一边被改。
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

# NSSM 注册后需要 set 的键值序列（不含 install 与失败回滚）。抽出来是为可单测参数组合：
# AppExit 双 token、AppEnvironmentExtra 多 token 这类容易被展开方式搞错的地方。
# $rotateBytes / $stopMethodMs 由调用方从 config 传入（默认值与 config.ps1 的
# AppRotateBytes / AppStopMethodConsole 一致）——本文件保持纯函数，不读 $script:config，
# 单独点源即可测（不加载 WPF / config）。
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
  # 年龄门槛：AppRotateFiles=1 是「每次服务启动就轮转」，频繁重启的服务一天能堆几十个档。
  # 设了这个之后文件至少活 N 秒才允许被轮转，堆积速度立刻降下来。
  $spec.Add(@{k='AppRotateSeconds'; v=@($rotateSeconds)})
  $spec.Add(@{k='AppStopMethodConsole'; v=@($stopMethodMs)})
  $spec.Add(@{k='Start'; v=@('SERVICE_DEMAND_START')})
  $spec.Add(@{k='AppExit'; v=@('Default','Ignore')})
  # 运行账户：LocalSystem 就是 install 的默认值，不必再 set（保持 spec 最小，
  # 也让「没选账户」和「显式选 LocalSystem」走同一条路径——少一条就少一处漂移）。
  if ($account -and $account -ine 'LocalSystem') { $spec.Add(@{k='ObjectName'; v=@($account)}) }
  if($envPairs -and $envPairs.Count){ $spec.Add(@{k='AppEnvironmentExtra'; v=@($envPairs)}) }
  $spec
}
