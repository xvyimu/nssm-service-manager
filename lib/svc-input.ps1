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

# NSSM 注册后需要 set 的键值序列（不含 install 与失败回滚）。抽出来是为可单测参数组合：
# AppExit 双 token、AppEnvironmentExtra 多 token 这类容易被展开方式搞错的地方。
# $rotateBytes / $stopMethodMs 由调用方从 config 传入（默认值与 config.ps1 的
# AppRotateBytes / AppStopMethodConsole 一致）——本文件保持纯函数，不读 $script:config，
# 单独点源即可测（不加载 WPF / config）。
function Get-NssmSetSpec([string]$n,[string]$dir,[string]$par,[object[]]$envPairs,
                         [int]$rotateBytes = 5242880, [int]$stopMethodMs = 5000){
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
  $spec.Add(@{k='AppStopMethodConsole'; v=@($stopMethodMs)})
  $spec.Add(@{k='Start'; v=@('SERVICE_DEMAND_START')})
  $spec.Add(@{k='AppExit'; v=@('Default','Ignore')})
  if($envPairs -and $envPairs.Count){ $spec.Add(@{k='AppEnvironmentExtra'; v=@($envPairs)}) }
  $spec
}
