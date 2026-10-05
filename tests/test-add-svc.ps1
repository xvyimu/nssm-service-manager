#requires -Version 7.0
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
$script:sync=@{gate=[object]::new()}
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

# Save-Svc 失败路径：NSSM 已注册但配置落盘失败时，CLI 必须 exit 1 且不启动服务。
# 用子进程验证，因为 Add-SvcFromCli 靠 exit 终止——不能在当前作用域内联运行。
$probe = Join-Path ([IO.Path]::GetTempPath()) "sm-save-fail-$([guid]::NewGuid().ToString('N')).ps1"
$probeBody = @'
$ErrorActionPreference = "Stop"
. (Join-Path $args[0] "lib/util.ps1")
. (Join-Path $args[0] "lib/add-svc.ps1")
$script:svc = [ordered]@{}
$script:sync = @{gate = [object]::new()}
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
Write-Output 'PASS: CLI registration, NSSM multi-value arguments, rollback on partial set failure, remove flow (stop→wait→remove), persistence/start boundaries (mocked); config unchanged.'
} finally { Remove-Item -LiteralPath $fakeExe -Force -EA SilentlyContinue }
