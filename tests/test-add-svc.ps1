#requires -Version 7.0
# $logDir 不在本文件里引用，但 lib/svc-input.ps1 的 Get-NssmSetSpec 直接读调用方作用域（AppStdout/AppStderr），
# 静态分析看不到这种跨作用域用法。
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments','',Justification='svc-input.ps1 读调用方作用域的 $logDir')]
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$cfg=Join-Path $RepoRoot 'services.json'
# services.json 已 git 忽略——新克隆的仓里不存在。测试需在两种情况下都跑：
# 存在则记录哈希核对未被改动；不存在则结束时确认仍不存在。
$cfgExisted = Test-Path -LiteralPath $cfg
$before = if ($cfgExisted) { (Get-FileHash -LiteralPath $cfg).Hash } else { $null }
. (Join-Path $RepoRoot 'lib/util.ps1')
. (Join-Path $RepoRoot 'lib/add-svc.ps1')
$script:svc=Load-Svc
$script:sync=@{gate=[object]::new(); scExe='sc.exe'}
$logDir=Join-Path $RepoRoot 'logs'
$script:calls=[Collections.Generic.List[object]]::new()
$script:saved=$false
# Replace only side-effect boundaries; exercise the real parser and NSSM wrapper.
function Invoke-TestNssm {
  $script:calls.Add(@($args))
  # 同步服务数据库状态：install/remove 后 sc.exe query 替身据此应答
  if ($args[0] -eq 'install') { [void]$script:nssmInstalled.Add($args[1]) }
  if ($args[0] -eq 'remove')  { [void]$script:nssmInstalled.Remove($args[1]) }
  $global:LASTEXITCODE=0
}
function Save-Svc($data) { $script:saved=$data.Contains('__sm_add_test__') }
# sc.exe 替身：本测试不碰真服务数据库，但要模拟 Install-NssmService / Remove-NssmService
# 新增的实证复核（Test-ServicePresent / Test-ServiceGone 都走 sc.exe query 的退出码）。
# 语义：install 过的服务 query 返回 0，remove 过的返回 1060。
function sc.exe {
  if ($args[0] -eq 'query') {
    # 实证复核判据（Test-ServicePresent / Test-ServiceGone）走这里；
    # 不记进 startArgs——它不是「命令」，记了会把 stop/start 的断言覆盖掉。
    if ($script:nssmInstalled -contains $args[1]) { $global:LASTEXITCODE=0 } else { $global:LASTEXITCODE=1060 }
    return
  }
  $script:startArgs=@($args)   # 最近一条 sc.exe 命令（stop/start 等非 query 都记这里）
  $global:LASTEXITCODE=0
}
$script:nssmInstalled=[System.Collections.Generic.HashSet[string]]::new()
$script:nssm='Invoke-TestNssm'
# Add-SvcFromCli 现在做 Test-Path 校验，需要一个真实存在的 exe（NSSM 被 mock，不碰真 exe）
$fakeExe = Join-Path ([IO.Path]::GetTempPath()) "sm-test-$([guid]::NewGuid().ToString('N')).exe"
[IO.File]::WriteAllText($fakeExe, 'placeholder', [Text.UTF8Encoding]::new($false))
try {
Add-SvcFromCli "__sm_add_test__,8080,$fakeExe"
if (-not $script:saved) { throw 'Service was not handed to persistence.' }
if (($script:startArgs -join '|') -ne 'start|__sm_add_test__') { throw 'Service start request missing.' }
$exitSetting=@($script:calls | Where-Object { $_[0] -eq 'set' -and $_[2] -eq 'AppExit' })
if ($exitSetting.Count -ne 1 -or ($exitSetting[0] -join '|') -ne 'set|__sm_add_test__|AppExit|Default|Ignore') {
  throw 'NSSM AppExit must receive both Default and Ignore.'
}

# 敏感键名提示分支：CLI 带敏感 env 时，stdout 应含「明文写入注册表」提示并点名该键。
# 安全相关代码此前只有纯函数单测，这条补 CLI 端到端断言（mock NSSM，不碰真服务）。
# Write-Host 走信息流（stream 6），用 6>&1 并入输出流才能被 Out-String 捕获。
# 放在 AppExit 断言之后：这些调用会往 $script:calls 塞别的服务的 set 记录，会盖掉 __sm_add_test__。
$script:calls.Clear()
$script:saved = $false
$script:startArgs = $null
$cliOut = (Add-SvcFromCli "__sm_warn_test__,8090,$fakeExe,http://127.0.0.1:8090,,,MY_API_KEY=sk-test" 6>&1 | Out-String)
if ($cliOut -notmatch '明文写入注册表') { throw "CLI should warn sensitive key goes to registry. Output: $cliOut" }
if ($cliOut -notmatch 'MY_API_KEY') { throw "CLI warning should name the sensitive key. Output: $cliOut" }
# _FILE + 路径值不提示；_FILE + 非路径值仍提示（值形态双判）
$script:calls.Clear()
$cliOutPath = (Add-SvcFromCli "__sm_warn_path__,8091,$fakeExe,http://127.0.0.1:8091,,,MY_TOKEN_FILE=C:\keys\t.k" 6>&1 | Out-String)
if ($cliOutPath -match '明文写入注册表') { throw "_FILE with path value should NOT warn. Output: $cliOutPath" }
$script:calls.Clear()
$cliOutNoPath = (Add-SvcFromCli "__sm_warn_nopath__,8092,$fakeExe,http://127.0.0.1:8092,,,MY_TOKEN_FILE=sk-live-xxx" 6>&1 | Out-String)
if ($cliOutNoPath -notmatch '明文写入注册表') { throw "_FILE with non-path value SHOULD warn. Output: $cliOutNoPath" }


# CLI env 解析：值里的逗号不得被吃掉。原实现 `$spec -split ','` 把 Env 段先拆散，
# NO_PROXY=127.0.0.1,localhost 会变成一个名为 NO_PROXY、值为 127.0.0.1 的变量 + 一个
# 名为 localhost 的残片（Test-EnvPairs 在 CLI 不跑，静默注册了错东西）。
$script:calls.Clear()
Add-SvcFromCli "__sm_env_comma__,8093,$fakeExe,http://127.0.0.1:8093,,,NO_PROXY=127.0.0.1,localhost" 6>&1 | Out-Null
$envSetting = @($script:calls | Where-Object { $_[0] -eq 'set' -and $_[2] -eq 'AppEnvironmentExtra' })
if ($envSetting.Count -ne 1) { throw "应下发一条 AppEnvironmentExtra，got $($envSetting.Count)" }
$tokens = @($envSetting[0])[3..(@($envSetting[0]).Count - 1)]
if ($tokens.Count -ne 1 -or $tokens[0] -ne 'NO_PROXY=127.0.0.1,localhost') {
  throw "CLI env 值被拆坏：$($tokens -join ' | ')"
}
# 逗号用作对数分隔符时仍应拆开（A=1,B=2 → 两条），与上手共用同一条解析规则
$script:calls.Clear()
Add-SvcFromCli "__sm_env_pairs__,8094,$fakeExe,http://127.0.0.1:8094,,,A=1,B=2" 6>&1 | Out-Null
$envSetting = @($script:calls | Where-Object { $_[0] -eq 'set' -and $_[2] -eq 'AppEnvironmentExtra' })
$tokens = @($envSetting[0])[3..(@($envSetting[0]).Count - 1)]
if ($tokens.Count -ne 2 -or ($tokens -join '|') -ne 'A=1|B=2') {
  throw "逗号分隔的多对 env 未被拆开：$($tokens -join ' | ')"
}

# B1：CLI 第 4 段写 tcp 是简写——probe=tcp 且 url 为空。数据库/gRPC/纯 socket 不再需要
# 注册完手改 services.json（不写就只有 HTTP 探测，卡片永远橙点）。
$script:calls.Clear()
Add-SvcFromCli "__sm_probe_tcp__,8096,$fakeExe,tcp" 6>&1 | Out-Null
$tcpEntry = $script:svc['__sm_probe_tcp__']
if (-not $tcpEntry) { throw 'B1: CLI 的 tcp 简写没有落进清单。' }
if ($tcpEntry.probe -ne 'tcp' -or $tcpEntry.url -ne '') {
  throw "B1: tcp 简写应落 probe=tcp / url 空，实际 probe=[$($tcpEntry.probe)] url=[$($tcpEntry.url)]"
}

# 回滚路径：install 成功后某个 set 失败，应 remove 残骸并抛错。
$script:calls.Clear()
$script:removed=$null
function Invoke-TestNssmRollback {
  $a=$args
  if ($a[0] -eq 'install') { [void]$script:nssmInstalled.Add($a[1]); $global:LASTEXITCODE=0; return }
  if ($a[0] -eq 'remove')  { $script:removed=$a[1]; [void]$script:nssmInstalled.Remove($a[1]); $global:LASTEXITCODE=0; return }
  if ($a[0] -eq 'set' -and $a[2] -eq 'AppRotateFiles') { $global:LASTEXITCODE=5; return 'set failed' }
  $global:LASTEXITCODE=0
}
$script:nssm='Invoke-TestNssmRollback'
$rolled=$false
# Install-NssmService 不做 Test-Path（仅 Add-SvcFromCli/Show-Add 入口校验），直接用假路径
try { Install-NssmService '__sm_rollback__' 'C:\rb.exe' $null $null @() } catch { $rolled=$true }
if (-not $rolled) { throw 'Failing NSSM set should surface the error.' }
if ($script:removed -ne '__sm_rollback__') { throw 'Half-registered service was not rolled back via nssm remove.' }

# Remove-NssmService：stop→Wait-Stopped→nssm remove confirm
$script:calls.Clear()
$script:removed=$null
$script:startArgs=$null
function Invoke-TestNssmRemove {
  $a=$args
  if ($a[0] -eq 'remove')  { $script:removed=$a[1]; [void]$script:nssmInstalled.Remove($a[1]); $global:LASTEXITCODE=0; return }
  $global:LASTEXITCODE=0
}
# sc.exe 替身需先让服务"存在"，否则 Test-ServiceGone 会判删除失败。
# 不再单独重定义 sc.exe：第 28 行那个统一替身已含 query 分支（stop 也记进 $script:startArgs），
# 这里再定义一个无 query 分支的会把它覆盖掉，Test-ServiceGone 就只能拿到假的 0。
[void]$script:nssmInstalled.Add('__sm_remove_test__')
$script:nssm='Invoke-TestNssmRemove'
Remove-NssmService '__sm_remove_test__'
if ($script:startArgs -join '|' -ne 'stop|__sm_remove_test__') { throw 'Remove-NssmService must stop before nssm remove.' }
if ($script:removed -ne '__sm_remove_test__') { throw 'Remove-NssmService did not call nssm remove confirm.' }

# 启动失败路径：注册成功但 sc.exe start 返回非零时，CLI **不得**报「已启动」。
# 该 CLI 是给 agent 用的，谎报成功会让调用方以为服务在跑。走子进程（Add-SvcFromCli 用 Write-Host）。
$probeStart = Join-Path ([IO.Path]::GetTempPath()) "sm-start-fail-$([guid]::NewGuid().ToString('N')).ps1"
$probeStartBody = @'
$ErrorActionPreference = "Stop"
. (Join-Path $args[0] "lib/util.ps1")
. (Join-Path $args[0] "lib/add-svc.ps1")
$script:svc = [ordered]@{}
$script:sync = @{gate = [object]::new(); scExe = 'sc.exe'}
$logDir = Join-Path $args[0] "logs"
$script:nssm = "Invoke-Ok"
$script:startArgs = $null
$fakeExe3 = Join-Path ([IO.Path]::GetTempPath()) "sm-start-fail-$([guid]::NewGuid().ToString('N')).exe"
[IO.File]::WriteAllText($fakeExe3, 'placeholder', [Text.UTF8Encoding]::new($false))
function Invoke-Ok { $global:LASTEXITCODE = 0 }
function Save-Svc($data) { }
# install 后的实证复核（Test-ServicePresent）走 query -> 返回 0（服务在）；
# start 返回 1053（进程起不来）——两者都是实测见过的真实码。
function sc.exe {
  if ($args[0] -eq 'query') { $global:LASTEXITCODE = 0; return }
  if ($args[0] -eq 'start') { $global:LASTEXITCODE = 1053; return }
  $global:LASTEXITCODE = 0
}
Add-SvcFromCli "__sm_start_fail__,9092,$fakeExe3"
'@
[IO.File]::WriteAllText($probeStart, $probeStartBody, [Text.UTF8Encoding]::new($false))
try {
  $startOut = (& pwsh -NoProfile -File $probeStart $RepoRoot 2>&1 | Out-String)
  $startCode = $LASTEXITCODE
} finally { Remove-Item -LiteralPath $probeStart -Force -EA SilentlyContinue }
if ($startCode -ne 0) { throw "Start failure must not fail the whole CLI (registration succeeded); got exit $startCode." }
if ($startOut -notmatch '启动失败') { throw "Start failure was not reported. Output: $startOut" }
if ($startOut -match '已添加并启动') { throw "Start failure was reported as success (谎报). Output: $startOut" }

# Save-Svc 失败路径：NSSM 已注册但配置落盘失败时，CLI 必须 exit 1 且不启动服务。
# 用子进程验证，因为 Add-SvcFromCli 靠 exit 终止——不能在当前作用域内联运行。
$probe = Join-Path ([IO.Path]::GetTempPath()) "sm-save-fail-$([guid]::NewGuid().ToString('N')).ps1"
$probeBody = @'
$ErrorActionPreference = "Stop"
. (Join-Path $args[0] "lib/util.ps1")
. (Join-Path $args[0] "lib/add-svc.ps1")
$script:svc = [ordered]@{}
$script:sync = @{gate = [object]::new(); scExe = 'sc.exe'}
$logDir = Join-Path $args[0] "logs"
$script:nssm = "Invoke-Ok"
$script:startArgs = $null
# Add-SvcFromCli 校验 exe 存在；子进程里造一个临时 exe（NSSM 被 mock）
$fakeExe2 = Join-Path ([IO.Path]::GetTempPath()) "sm-save-fail-$([guid]::NewGuid().ToString('N')).exe"
[IO.File]::WriteAllText($fakeExe2, 'placeholder', [Text.UTF8Encoding]::new($false))
function Invoke-Ok { $global:LASTEXITCODE = 0 }
function Save-Svc($data) { throw "disk full" }
Add-SvcFromCli "__sm_save_fail__,9091,$fakeExe2"
'@
[IO.File]::WriteAllText($probe, $probeBody, [Text.UTF8Encoding]::new($false))
try {
  & pwsh -NoProfile -File $probe $RepoRoot 2>&1 | Out-Null
  $code = $LASTEXITCODE
} finally { Remove-Item -LiteralPath $probe -Force -EA SilentlyContinue }
if ($code -ne 1) { throw "Save-Svc failure must exit 1 (got $code), not swallow the error or start the service." }
if ($cfgExisted) {
  if ((Get-FileHash -LiteralPath $cfg).Hash -ne $before) { throw 'Test changed services.json.' }
} elseif (Test-Path -LiteralPath $cfg) {
  throw 'Test created services.json where none existed.'
}

# sc.exe 必须经 Get-ScExe 解析后调用，不能裸调。
# 夹具平时注入的是替身名 'sc.exe'，所以「调用点退回裸 sc.exe」照样能命中那个替身——
# 测不出来。这里换成一个**不同的**注入名：只有真的走了解析才会调到它。
# 本机实测 System32 不在 PATH，裸调会 CommandNotFoundException 且 $LASTEXITCODE 保留旧值。
$script:scMarker = @()
function Invoke-ScMarker {
  param([Parameter(ValueFromRemainingArguments = $true)]$a)
  $script:scMarker += ($a -join ' ')
  $global:LASTEXITCODE = 1060
}
$script:sync = @{ gate = [object]::new(); scExe = 'Invoke-ScMarker' }
$script:svc = [ordered]@{}
$qcode = Get-ServiceQueryCode 'NoSuchSvc'
if ($script:scMarker.Count -ne 1 -or $script:scMarker[0] -ne 'query NoSuchSvc') {
  throw "Get-ServiceQueryCode 没有走 Get-ScExe 解析出的命令（实际调用：$($script:scMarker -join ' | ')）"
}
if ($qcode -ne 1060) { throw "Get-ServiceQueryCode 未透传退出码（got $qcode）" }
$script:scMarker = @()
function Invoke-NoopNssm { $global:LASTEXITCODE = 0 }
$r = Invoke-ServiceRemove 'NoSuchSvc' 'Invoke-NoopNssm'
# 这条会先 stop 再查一次（Test-ServiceGone），故断言「包含」而不是「等于一条」
if ($script:scMarker -notcontains 'stop NoSuchSvc') {
  throw "Invoke-ServiceRemove 的 stop 没有走 Get-ScExe（实际调用：$($script:scMarker -join ' | ')）"
}
if (-not $r.ok) { throw "Invoke-ServiceRemove 在 sc=1060 + nssm=0 时应判成功：$($r.why)" }
Write-Output 'PASS: sc.exe call sites go through Get-ScExe (injected command name actually invoked), not bare sc.exe.'

# A1 回归：Save-Svc 抛错时内存清单必须原样（copy-on-write）。原实现先写 $script:svc 再保存，
# 失败后那条服务留在内存——用户以为没加成，下一次任意保存（比如删掉别的服务）会把它写进磁盘。
$svcBefore = $script:svc
function Save-Svc($data) { throw 'disk full (A1)' }
$err = Add-SvcEntry '__sm_cow__' 9097 'http://127.0.0.1:9097'
if (-not $err -or $err -notmatch 'disk full') { throw "A1: Add-SvcEntry 应把保存错误返回给调用方，got [$err]" }
if ($script:svc.Contains('__sm_cow__')) { throw 'A1: 保存失败后内存清单不得留着新条目（下一次保存会把它写进磁盘）' }
if (-not [object]::ReferenceEquals($script:svc, $svcBefore)) { throw 'A1: 保存失败后内存清单对象不该被替换' }
if ($script:sync.svc) { throw 'A1: 保存失败后不该同步 $sync.svc（后台会探测到没落盘的服务）' }
Write-Output 'PASS: Add-SvcEntry copy-on-write — a failed save leaves memory, $sync.svc and disk untouched.'

Write-Output 'PASS: CLI registration, NSSM multi-value arguments, rollback on partial set failure, remove flow (stop→wait→remove), persistence/start boundaries (mocked); config unchanged.'
} finally { Remove-Item -LiteralPath $fakeExe -Force -EA SilentlyContinue }
