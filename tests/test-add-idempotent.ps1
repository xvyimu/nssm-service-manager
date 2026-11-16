#requires -Version 7.0
# P2-1 回归：服务已注册但清单缺失时，重试「注册并启动」不得重复 install。
# 背景：原序是 install → set… → save → start。install 成功、save 失败（磁盘/权限/外部改动）后，
# 用户只能 `nssm remove` 再重来；再点一次会撞 NSSM「服务已存在」。现在先查 Test-ServicePresent，
# 已存在就只补写参数（Set-NssmServiceParams）+ 保存 + 启动，点重试即可收敛。
# 反向用例守住另一头：服务不在时仍必须走 install，别把「幂等」写成「永不注册」。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
foreach ($module in 'config','util','svc-input','dialogs') { . (Join-Path $RepoRoot "lib/$module.ps1") }
. (Join-Path $PSScriptRoot 'test-helpers.ps1')

# ---- 夹具：不存在真实服务，全部副作用替身化 ----
$script:svc = @{}
$script:servicePresent = $true
$script:installCalls = @()
$script:setCalls = @()
$script:cmdCalls = @()
$script:dialogErrors = @()
$script:dialogWarnings = @()

function Test-ServicePresent([string]$n, [int]$retries = 3, [int]$delayMs = 100) { return [bool]$script:servicePresent }
function Install-NssmService([string]$n, [string]$exe, [string]$dir, [string]$par, $envPairs, [string]$account = '') {
  $script:installCalls += @{ n = $n; exe = $exe }
}
function Set-NssmServiceParams([string]$n, [string]$exe, [string]$dir, [string]$par, $envPairs, [string]$account = '') {
  $script:setCalls += @{ n = $n; exe = $exe }
}
function Add-SvcEntry([string]$n, [int]$p, [string]$url, [string]$probe) { return $null }
function Send-ServiceCommand([string]$name, [string]$action) { $script:cmdCalls += @{ n = $name; act = $action }; return 1 }
function Show-DialogError($owner, [string]$msg) { $script:dialogErrors += $msg }
function Show-DialogWarning($owner, [string]$msg, [string]$title) { $script:dialogWarnings += @{ msg = $msg; title = $title } }
# 单测不该受运行机器真实 ACL 影响
function Get-ExeDirVerdict([string]$exe) { return '否' }

# Test-SvcInput 要求 exe 是真实存在的文件（PathType Leaf），用临时目录里的空文件满足。
$tmpDir = New-TestTempDir 'sm-addidem'
$fakeExe = Join-Path $tmpDir 'fake.exe'
[IO.File]::WriteAllText($fakeExe, 'placeholder', [Text.UTF8Encoding]::new($false))
$win = $null   # 弹框已替身化，owner 不参与判断

try {
  # ---- 1. 已注册 + 清单缺失：只补参数，不重复 install ----
  $script:servicePresent = $true
  $ok = Submit-AddService $win @{ n = 'SvcI'; p = '8090'; exe = $fakeExe; url = ''; dir = ''; par = ''; env = ''; account = 'LocalSystem'; gpu = $false }
  Assert ($ok -eq $true) "已注册时提交应成功（补写清单），实际 $ok；弹框错误：$($script:dialogErrors -join ' | ')"
  Assert ($script:installCalls.Count -eq 0) "已注册时不得重复 install，实际调用 $($script:installCalls.Count) 次"
  Assert ($script:setCalls.Count -eq 1) "已注册时应补写一次参数，实际调用 $($script:setCalls.Count) 次"
  Assert ($script:setCalls[0].n -eq 'SvcI') "补写参数应针对 SvcI，实际「$($script:setCalls[0].n)」"
  Assert ($script:cmdCalls.Count -eq 1) "应下发 1 条命令，实际 $($script:cmdCalls.Count) 条"
  Assert ($script:cmdCalls[0].n -eq 'SvcI' -and $script:cmdCalls[0].act -eq 'start') "应下发 SvcI start，实际 $($script:cmdCalls[0].n) $($script:cmdCalls[0].act)"
  Assert ($script:dialogErrors.Count -eq 0) "成功路径不应弹错误框：$($script:dialogErrors -join ' | ')"
  Write-Output 'PASS: 已注册但清单缺失时不重复 install（install=0 / set=1 / start=1）'

  # ---- 1b. 已注册重试：必须提示「重启才生效」，且不依赖查询服务状态（UI 线程无 I/O）----
  $script:uiQueryCalls = 0
  function Get-Service { [CmdletBinding()]param([string]$Name) $script:uiQueryCalls++; throw 'UI must not query SCM synchronously.' }
  $script:setCalls = @(); $script:dialogWarnings = @()
  $okRunning = Submit-AddService $win @{ n = 'SvcI'; p = '8090'; exe = $fakeExe; url = ''; dir = ''; par = ''; env = ''; account = 'LocalSystem'; gpu = $false }
  Assert ($okRunning -eq $true) "运行中补参应成功，实际 $okRunning"
  Assert ($script:setCalls.Count -eq 1) "运行中应补写一次参数，实际 $($script:setCalls.Count)"
  Assert (@($script:dialogWarnings | Where-Object { $_.msg -match '重启' }).Count -eq 1) "运行中补参应提示需重启，实际警告：$((@($script:dialogWarnings | ForEach-Object { $_.msg })) -join ' | ')"
  Assert ($script:uiQueryCalls -eq 0) 'Retry notice must not query SCM on the UI thread.'
  Write-Output 'PASS: registered-service retry warns about restart without a synchronous SCM query.'

  # ---- 1c. 补参失败：弹错误、不下发 start、窗口保持打开 ----
  function Set-NssmServiceParams { throw 'injected param failure' }
  $script:cmdCalls = @(); $script:dialogErrors = @()
  $okFail = Submit-AddService $win @{ n = 'SvcI'; p = '8090'; exe = $fakeExe; url = ''; dir = ''; par = ''; env = ''; account = 'LocalSystem'; gpu = $false }
  Assert ($okFail -eq $false) '补参失败应返回 false（窗口保持打开）'
  Assert (@($script:dialogErrors | Where-Object { $_ -match 'injected param failure' }).Count -eq 1) "应把原始失败原因弹给用户，实际：$($script:dialogErrors -join ' | ')"
  Assert ($script:cmdCalls.Count -eq 0) "补参失败不得下发 start，实际 $($script:cmdCalls.Count) 条"
  Write-Output 'PASS: 补参失败弹原始原因、不下发 start、窗口保持打开。'

  # ---- 2. 反向：服务不存在时仍必须 install ----
  $script:servicePresent = $false
  $script:installCalls = @(); $script:setCalls = @(); $script:cmdCalls = @(); $script:dialogErrors = @()
  $ok2 = Submit-AddService $win @{ n = 'SvcJ'; p = '8091'; exe = $fakeExe; url = ''; dir = ''; par = ''; env = ''; account = 'LocalSystem'; gpu = $false }
  Assert ($ok2 -eq $true) "未注册时提交应成功，实际 $ok2；弹框错误：$($script:dialogErrors -join ' | ')"
  Assert ($script:installCalls.Count -eq 1) "未注册时应 install 一次，实际 $($script:installCalls.Count) 次"
  Assert ($script:installCalls[0].n -eq 'SvcJ') "install 应针对 SvcJ，实际「$($script:installCalls[0].n)」"
  Assert ($script:setCalls.Count -eq 0) "未注册时不应单独补参数，实际 $($script:setCalls.Count) 次"
  Assert ($script:cmdCalls.Count -eq 1 -and $script:cmdCalls[0].act -eq 'start') '未注册路径也应下发 start'
  Write-Output 'PASS: 服务不存在时仍走 install（install=1 / set=0 / start=1）'

  # ---- 3. 重试补参必须同步 Application：install 写死的 exe 不会随用户改正而变 ----
  . (Join-Path $RepoRoot 'lib/nssm.ps1')
  $script:nssmSetCalls = @()
  function nssm-set([string]$n,[string]$k,$v) { $script:nssmSetCalls += @{ n = $n; k = $k; v = @($v) } }
  Set-NssmServiceParams 'SvcK' 'C:\apps\new\svc.exe' $null $null @() 'LocalSystem'
  $appCalls = @($script:nssmSetCalls | Where-Object { $_.k -eq 'Application' })
  Assert ($appCalls.Count -eq 1) "补参必须写 Application，实际键：$(($script:nssmSetCalls | ForEach-Object { $_.k }) -join ',')"
  Assert ($appCalls[0].v[0] -eq 'C:\apps\new\svc.exe') "Application 应指向新 exe，实际 $($appCalls[0].v -join ' ')"
  $script:nssmSetCalls = @()
  Set-NssmServiceParams 'SvcK' '' $null $null @() 'LocalSystem'
  Assert (@($script:nssmSetCalls | Where-Object { $_.k -eq 'Application' }).Count -eq 0) '空 exe 不应清掉 Application'
  Set-NssmServiceParams 'SvcK' 'C:\apps\new\svc.exe' $null $null @() 'LocalSystem' -SkipApplication
  Assert (@($script:nssmSetCalls | Where-Object { $_.k -eq 'Application' }).Count -eq 0) 'Install must skip the redundant Application write.'
  Write-Output 'PASS: retry writes Application; empty exe and install skip it.'

  # 真 install 链路也不能重复 set Application；任意 set 失败仍回滚新注册的服务。
  $script:externalCalls = @(); $script:failSet = $false; $script:nssm = 'mock-nssm'
  function Invoke-ExternalQuiet($file, $argv) { $script:externalCalls += ,@($argv); @{exit=0;out=''} }
  function Test-ServiceGone([string]$n) { $true }
  function nssm-set([string]$n,[string]$k,$v) {
    $script:nssmSetCalls += @{n=$n;k=$k;v=@($v)}
    if ($script:failSet) { throw 'injected set failure' }
  }
  $script:servicePresent = $true; $script:nssmSetCalls = @()
  Install-NssmService 'SvcInstall' $fakeExe $null $null @()
  Assert (@($script:nssmSetCalls | Where-Object { $_.k -eq 'Application' }).Count -eq 0) 'Install emitted a redundant Application write.'
  Assert ($script:externalCalls[0][0] -eq 'install') 'Real install wrapper was not exercised.'
  $script:failSet = $true; $caught = $false
  try { Install-NssmService 'SvcFail' $fakeExe $null $null @() } catch { $caught = $_.Exception.Message -eq 'injected set failure' }
  Assert $caught 'Set failure must propagate unchanged.'
  Assert ($script:externalCalls[-1][0] -eq 'remove' -and $script:externalCalls[-1][1] -eq 'SvcFail') 'Failed fresh install was not rolled back.'
  Write-Output 'PASS: actual install skips Application and rolls back on set failure.'

  # ---- 3c. 写序：参数先、Application 最后；参数失败时 exe 保持旧值 ----
  $script:nssmSetCalls = @()
  function nssm-set([string]$n,[string]$k,$v) {
    $script:nssmSetCalls += @{ n = $n; k = $k; v = @($v) }
    if ($k -eq 'AppDirectory') { throw 'injected AppDirectory failure' }
  }
  $caughtFail = $false
  try { Set-NssmServiceParams 'SvcR' 'C:\new\app.exe' 'C:\newdir' $null @() 'LocalSystem' } catch { $caughtFail = $_.Exception.Message -eq 'injected AppDirectory failure' }
  Assert $caughtFail '参数失败必须原样抛出'
  Assert (@($script:nssmSetCalls | Where-Object { $_.k -eq 'Application' }).Count -eq 0) '参数失败时不得改写 Application（服务仍跑旧 exe）'
  Write-Output 'PASS: 参数失败时 Application 未动，服务不会被指向半新状态。'

  # ---- 3d. 成功路径：Application 必须最后写 ----
  $script:nssmSetCalls = @()
  function nssm-set([string]$n,[string]$k,$v) { $script:nssmSetCalls += @{ n = $n; k = $k; v = @($v) } }
  Set-NssmServiceParams 'SvcS' 'C:\new\app.exe' $null $null @() 'LocalSystem'
  $keys = @($script:nssmSetCalls | ForEach-Object { $_.k })
  Assert ($keys[-1] -eq 'Application') "Application 必须最后写，实际顺序：$($keys -join ', ')"
  Write-Output 'PASS: Application 最后写，失败不会留下新 exe + 旧参数。'
} finally {
  if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force }
}
Write-Output 'PASS: 添加服务幂等续做（正反两例）'
