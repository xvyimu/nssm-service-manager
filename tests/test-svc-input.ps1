#requires -Version 7.0
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$cfg=Join-Path $RepoRoot 'services.json'
$cfgExisted = Test-Path -LiteralPath $cfg
$before = if ($cfgExisted) { (Get-FileHash -LiteralPath $cfg).Hash } else { $null }
. (Join-Path $RepoRoot 'lib/util.ps1')
. (Join-Path $RepoRoot 'lib/add-svc.ps1')
. (Join-Path $RepoRoot 'lib/logview.ps1')   # Get-LogFiles 随拆分移来（util.ps1 只留配置持久化）
$script:svc = Load-Svc
$script:sync = @{gate=[object]::new()}
$logDir = Join-Path $RepoRoot 'logs'
$script:nssm = 'Invoke-TestNssm'
function Invoke-TestNssm { $global:LASTEXITCODE = 0 }
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }

$fakeExe = Join-Path ([IO.Path]::GetTempPath()) "sm-neg-$([guid]::NewGuid().ToString('N')).exe"
[IO.File]::WriteAllText($fakeExe, 'placeholder', [Text.UTF8Encoding]::new($false))
try {
  # ---- Test-SvcInput：四个 code 与通过路径 ----
  # 名称非法：Windows 服务名禁止 / \ : 等保留字符
  $r = Test-SvcInput 'bad/name' 8080 $fakeExe $null
  Assert ($r.code -eq 'name') "slash in name should be rejected, got $($r.code)"
  $r = Test-SvcInput 'bad name' 8080 $fakeExe $null
  Assert ($r.code -eq 'name') 'space in name should be rejected'
  $r = Test-SvcInput 'ok_name.v2-x' 8080 $fakeExe $null
  Assert ($null -eq $r) 'legal charset should pass'
  # 纯 . / .. 被拒（路径归一化会指错注册表键）；点开头/含点但非纯点段放行
  foreach ($dot in '.','..') {
    $r = Test-SvcInput $dot 8080 $fakeExe $null
    Assert ($r.code -eq 'name') "bare '$dot' should be rejected, got $($r.code)"
  }
  Assert ($null -eq (Test-SvcInput '.hidden' 8080 $fakeExe $null)) '.hidden should pass'
  Assert ($null -eq (Test-SvcInput 'A..B' 8080 $fakeExe $null)) 'A..B should pass'

  # exe 不存在
  $missing = Join-Path ([IO.Path]::GetTempPath()) "sm-neg-missing-$([guid]::NewGuid().ToString('N')).exe"
  $r = Test-SvcInput 'SvcA' 8080 $missing $null
  Assert ($r.code -eq 'exe') "missing exe should be rejected, got $($r.code)"

  # 端口边界：0 / 65536 / 负数 / 65535 合法
  foreach ($p in @(0, -1, 65536)) {
    $r = Test-SvcInput 'SvcA' $p $fakeExe $null
    Assert ($r.code -eq 'port') "port $p should be rejected, got $($r.code)"
  }
  Assert ($null -eq (Test-SvcInput 'SvcA' 65535 $fakeExe $null)) 'port 65535 should pass'
  Assert ($null -eq (Test-SvcInput 'SvcA' 1 $fakeExe $null)) 'port 1 should pass'

  # 重名
  $existing = [ordered]@{ 'SvcA' = @{port=1;url=''} }
  $r = Test-SvcInput 'SvcA' 8080 $fakeExe $existing
  Assert ($r.code -eq 'dup') "duplicate should be rejected, got $($r.code)"

  # 校验顺序：名称优先于端口（名称非法 + 端口非法 → 报名称）
  $r = Test-SvcInput 'bad/name' 0 $fakeExe $null
  Assert ($r.code -eq 'name') 'name check must run before port check'

  # ---- ConvertTo-EnvPairs：分隔符、去空白、丢空项 ----
  Assert ((ConvertTo-EnvPairs '' ';').Count -eq 0) 'empty env should yield 0 pairs'
  Assert ((ConvertTo-EnvPairs '  ' ';').Count -eq 0) 'whitespace env should yield 0 pairs'
  $pairs = ConvertTo-EnvPairs 'A=1; B=2 ;;C=3' ';'
  Assert ($pairs.Count -eq 3) "expected 3 pairs, got $($pairs.Count): $($pairs -join '|')"
  Assert ($pairs[1] -eq 'B=2') "trim should strip leading space, got [$($pairs[1])]"
  $pairs = ConvertTo-EnvPairs 'A=1,B=2' ','
  Assert ($pairs.Count -eq 2) 'comma separator should split GUI env'
  # 值里含分隔符时不得被拆散：GUI 填多地址 NO_PROXY 的真实场景（改前直接报格式错误）
  $pairs = ConvertTo-EnvPairs 'HTTP_PROXY=http://h:1,NO_PROXY=127.0.0.1,localhost' ','
  Assert ($pairs.Count -eq 2) "逗号出现在值里不应拆成新变量，got $($pairs.Count): $($pairs -join '|')"
  Assert ($pairs[1] -eq 'NO_PROXY=127.0.0.1,localhost') "NO_PROXY 的值必须原样保留，got [$($pairs[1])]"
  Assert ($null -eq (Test-EnvPairs $pairs)) 'NO_PROXY 多地址应通过格式校验'
  # 分号同理：CLI 的 PATH 值本身就含分号
  $pairs = ConvertTo-EnvPairs 'PATH=C:\Windows;C:\Windows\System32' ';'
  Assert ($pairs.Count -eq 1) "分号出现在值里不应拆成新变量，got $($pairs.Count): $($pairs -join '|')"
  # 分隔符按字面量切（原实现把 separator 当正则，传 | 会炸）
  $pairs = ConvertTo-EnvPairs 'A=1|B=2' '|'
  Assert ($pairs.Count -eq 2) "字面量分隔符应能切开，got $($pairs.Count): $($pairs -join '|')"
  # 变量名不限于「字母数字下划线开头」：数字开头、含括号都是合法的 Windows 变量名。
  # 判据收紧成 ^[A-Za-z_]\w*= 会把它们并进上一个值——变量根本不写进 AppEnvironmentExtra，
  # 敏感键检测也扫不到（TOKEN 明文进注册表都不提示）。
  $pairs = ConvertTo-EnvPairs 'A=1,2FA_TOKEN=x' ','
  Assert ($pairs.Count -eq 2) "数字开头的变量名应被识别，got $($pairs.Count): $($pairs -join '|')"
  Assert ((Find-SensitiveEnvKeys $pairs) -contains '2FA_TOKEN') '数字开头的敏感键名也应被检出'
  $pairs = ConvertTo-EnvPairs 'A=1,ProgramFiles(x86)=C:\PF' ','
  Assert ($pairs.Count -eq 2) "含括号的变量名应被识别，got $($pairs.Count): $($pairs -join '|')"

  # ---- Test-EnvPairs：缺 = / 空 key / APPDATA 交互路径 ----
  Assert ($null -eq (Test-EnvPairs @('A=1','B=2'))) 'well-formed pairs should pass'
  Assert ((Test-EnvPairs @('NOVALUE')) -match '格式错误') 'pair without = should fail'
  Assert ((Test-EnvPairs @('=1')) -match '格式错误') 'empty key should fail'
  Assert ((Test-EnvPairs @('APPDATA=C:\Users\bob\AppData\Roaming')) -match 'APPDATA') 'interactive APPDATA should fail'
  # 等号后带空格也应被识别（S5：$kv[1] 未 Trim 曾绕过）
  Assert ((Test-EnvPairs @('APPDATA= C:\Users\bob\AppData\Roaming')) -match 'APPDATA') 'APPDATA with leading space should still fail'
  Assert ($null -eq (Test-EnvPairs @('APPDATA=C:\Windows\System32\config\systemprofile\AppData\Roaming'))) 'system-profile APPDATA should pass'
  Assert ($null -eq (Test-EnvPairs @())) 'empty pair list should pass'

  # ---- Find-SensitiveEnvKeys：敏感键名检出（应用于先做 *_FILE，避免明文密钥进注册表） ----
  $hits = Find-SensitiveEnvKeys @('A=1','B=2')
  Assert ($hits.Count -eq 0) 'no sensitive key names should yield no hits'
  $hits = Find-SensitiveEnvKeys @('MY_API_KEY=sk-123','B=2','DB_PASSWORD=xyz','MY_TOKEN=abc','NORMAL=1')
  Assert (($hits -join '|') -eq 'MY_API_KEY|DB_PASSWORD|MY_TOKEN') "expected MY_API_KEY/DB_PASSWORD/MY_TOKEN, got $($hits -join '|')"
  # *_FILE 后缀 + 值是路径 → 跳过（路径不进注册表，本意成立）
  $hits = Find-SensitiveEnvKeys @('MY_API_KEY_FILE=C:\keys\my.key')
  Assert ($hits.Count -eq 0) '_FILE keys with path values should be skipped'
  # *_FILE 后缀 + 值不是路径（像真密钥） → 仍提示，键名后缀不等于值就是路径
  $hits = Find-SensitiveEnvKeys @('MY_API_KEY_FILE=sk-live-123456')
  Assert (($hits -join '|') -eq 'MY_API_KEY_FILE') '_FILE keys with non-path values should still be flagged'
  # 扩展键名清单：ACCESS_KEY / CREDENTIAL / PRIVATE_KEY / PASSPHRASE / PWD
  $hits = Find-SensitiveEnvKeys @('AWS_ACCESS_KEY_ID=AKIA...','MY_CREDENTIAL=user:pass','PRIVATE_KEY=-----BEGIN','JWT_PASSPHRASE=abc','DB_PWD=secret')
  Assert (($hits -join '|') -eq 'AWS_ACCESS_KEY_ID|MY_CREDENTIAL|PRIVATE_KEY|JWT_PASSPHRASE|DB_PWD') "expected expanded patterns, got $($hits -join '|')"
  # 无下划线 / 独立 PASS / 常见凭证后缀形态（S3：此前漏报）
  # APIKEY/PRIVATEKEY 不带下划线；DB_PASS/REDIS_PASS 有 PASS 无 PASSWORD/PWD；
  # *_AUTH / *_SALT / SIGNING_KEY / *_PAT / *_WEBHOOK 是常见凭证名。
  $hits = Find-SensitiveEnvKeys @('APIKEY=sk-x','PRIVATEKEY=-----BEGIN','DB_PASS=p','REDIS_PASS=r','MY_AUTH=1','DB_SALT=s','JWT_SIGNING_KEY=k','GH_PAT=p','SLACK_WEBHOOK=https://x')
  Assert (($hits -join '|') -eq 'APIKEY|PRIVATEKEY|DB_PASS|REDIS_PASS|MY_AUTH|DB_SALT|JWT_SIGNING_KEY|GH_PAT|SLACK_WEBHOOK') "expected S3-expanded patterns, got $($hits -join '|')"
  # 反例：不得误报 MONKEY / COMPASS / BYPASS / PASSENGER（含 PASS 子串但不是凭证）
  $hits = Find-SensitiveEnvKeys @('MONKEY=1','COMPASS=2','BYPASS=3','PASSENGER=4','PATH=/usr','LATEST=5')
  Assert ($hits.Count -eq 0) "普通词不应误报为敏感键：$($hits -join '|')"
  # 空/空壳入参
  Assert ((Find-SensitiveEnvKeys @()).Count -eq 0) 'empty pair list should yield no hits'
  Assert ((Find-SensitiveEnvKeys $null).Count -eq 0) 'null should yield no hits'

  # ---- Get-LogFiles：服务名含点号时正则转义，不跨服务串台 ----
  $logTmp = Join-Path ([IO.Path]::GetTempPath()) "sm-log-test-$([guid]::NewGuid().ToString('N'))"
  New-Item -ItemType Directory -Force $logTmp | Out-Null
  try {
    # 造两个名字相近的服务日志：My.Service 与 MyxService，点号若不转义会互相匹配
    'a' | Set-Content -LiteralPath (Join-Path $logTmp 'My.Service.out.log') -Encoding UTF8
    'b' | Set-Content -LiteralPath (Join-Path $logTmp 'MyxService.out.log') -Encoding UTF8
    $svcDotted = Get-LogFiles 'My.Service' $logTmp
    Assert ($svcDotted.Count -eq 1) "My.Service should match only its own log, got $($svcDotted.Count)"
    Assert ($svcDotted[0].Path -like '*My.Service.out.log') 'My.Service must not match MyxService'
    $svcX = Get-LogFiles 'MyxService' $logTmp
    Assert ($svcX.Count -eq 1 -and $svcX[0].Path -like '*MyxService.out.log') 'MyxService must match only its own log'
    # 轮转历史也按转义后名字匹配
    'r' | Set-Content -LiteralPath (Join-Path $logTmp 'My.Service.out-20260101000000.log') -Encoding UTF8
    $svcRot = Get-LogFiles 'My.Service' $logTmp
    Assert ($svcRot.Count -eq 2) "My.Service should pick up rotated log, got $($svcRot.Count)"
    # 不存在的服务返回空，不抛错
    Assert ((Get-LogFiles 'NoSuch' $logTmp).Count -eq 0) 'absent service should yield empty list'

    # ---- 单参调用：不传 LogPath，靠动态作用域回落外层 $logDir（GUI 走的就是这条） ----
    # 回归防护：参数若取名 $LogDir 会遮蔽同名的外层 $logDir（PS 变量名大小写不敏感），
    # 回落变成自己赋给自己，GUI 日志下拉框永远为空。这里把 $logDir 指到同一临时目录验证。
    $savedLogDir = $logDir
    try {
      $logDir = $logTmp
      $oneArg = Get-LogFiles 'My.Service'
      Assert ($oneArg.Count -eq 2) "single-arg call must fall back to outer `$logDir, got $($oneArg.Count)"
      Assert (@($oneArg | Where-Object { $_.Path -like '*My.Service.out.log' }).Count -eq 1) 'single-arg fallback must find the current log'
    } finally { $logDir = $savedLogDir }
  } finally { Remove-Item -LiteralPath $logTmp -Recurse -Force -EA SilentlyContinue }

  # ---- Get-NssmSetSpec：参数组合（AppExit 双 token / Env 多 token / 可选键省略） ----
  $spec = Get-NssmSetSpec 'SvcA' $null $null @()
  $byKey = @{}; foreach ($s in $spec) { $byKey[$s.k] = $s.v }
  Assert ($byKey['AppExit'] -join '|' -eq 'Default|Ignore') 'AppExit must carry both tokens'
  Assert ($byKey.ContainsKey('AppDirectory') -eq $false) 'AppDirectory omitted when dir empty'
  Assert ($byKey.ContainsKey('AppParameters') -eq $false) 'AppParameters omitted when par empty'
  Assert ($byKey.ContainsKey('AppEnvironmentExtra') -eq $false) 'AppEnvironmentExtra omitted when env empty'
  Assert ($byKey['AppStdout'] -join '|' -like "*SvcA.out.log") 'AppStdout should embed service name'
  Assert ($byKey['AppRotateBytes'] -join '|' -eq '5242880') 'AppRotateBytes should be 5242880'

  $spec = Get-NssmSetSpec 'SvcB' 'C:\app' '-x' @('K1=V1','K2=V2')
  $byKey = @{}; foreach ($s in $spec) { $byKey[$s.k] = $s.v }
  Assert ($byKey['AppDirectory'] -join '|' -eq 'C:\app') 'AppDirectory should be present when dir set'
  Assert ($byKey['AppParameters'] -join '|' -eq '-x') 'AppParameters should be present when par set'
  Assert ($byKey['AppEnvironmentExtra'].Count -eq 2) 'AppEnvironmentExtra should carry all pairs as separate tokens'
  Assert ($byKey['AppEnvironmentExtra'] -join '|' -eq 'K1=V1|K2=V2') 'AppEnvironmentExtra token order must be preserved'

  # spec 里每个 value 都必须是数组——nssm-set 的 ValueFromRemainingArguments 靠它展开
  foreach ($s in $spec) { Assert ($s.v -is [array]) "spec value for $($s.k) must be an array, got $($s.v.GetType().Name)" }

  # ---- 运行账户：白名单只有三个内置账户（都不需要密码）----
  foreach ($a in @('LocalSystem','NT AUTHORITY\LocalService','NT AUTHORITY\NetworkService','locALsystem')) {
    Assert ($null -eq (Test-SvcAccount $a)) "内置账户应通过：$a"
  }
  Assert ($null -eq (Test-SvcAccount '')) '空账户（沿用 nssm install 的默认）应通过'
  $bad = Test-SvcAccount 'DOMAIN\someone'
  Assert ($bad.code -eq 'account') "自定义用户账户应被拒绝，got $($bad.code)"

  # ObjectName 必须是一个 token：nssm 把它当 username（additional 参数），密码位留空由
  # well-known SID 识别路径补空串。多 token 会把第二个当成密码。
  $spec = Get-NssmSetSpec 'SvcC' $null $null @() 5242880 5000 'NT AUTHORITY\LocalService'
  $byKey = @{}; foreach ($s in $spec) { $byKey[$s.k] = $s.v }
  Assert ($byKey['ObjectName'].Count -eq 1) "ObjectName 必须是单个 token，got $($byKey['ObjectName'].Count)"
  Assert ($byKey['ObjectName'] -join '|' -eq 'NT AUTHORITY\LocalService') "ObjectName 值不对：$($byKey['ObjectName'] -join '|')"
  # LocalSystem 就是 nssm install 的默认账户，不必再 set（保持 spec 最小）
  foreach ($a in @('LocalSystem','')) {
    $spec = Get-NssmSetSpec 'SvcC' $null $null @() 5242880 5000 $a
    Assert (@($spec | Where-Object { $_.k -eq 'ObjectName' }).Count -eq 0) "账户 [$a] 不该产生 ObjectName"
  }

  if ($cfgExisted) {
    if ((Get-FileHash -LiteralPath $cfg).Hash -ne $before) { throw 'Test changed services.json.' }
  } elseif (Test-Path -LiteralPath $cfg) {
    throw 'Test created services.json where none existed.'
  }
  Write-Output 'PASS: Test-SvcInput (name/exe/port/dup + order), Test-SvcAccount (built-in whitelist, custom rejected), ConvertTo-EnvPairs (sep/trim/drop-empty, separator inside value kept), Test-EnvPairs (format/APPDATA), Find-SensitiveEnvKeys (sensitive-name detection + _FILE path-aware skip + expanded patterns), Get-LogFiles (regex-escaped service names), Get-NssmSetSpec (AppExit dual-token, env multi-token, ObjectName single token, optional-key omission, array-typed values).'
} finally {
  Remove-Item -LiteralPath $fakeExe -Force -EA SilentlyContinue
}