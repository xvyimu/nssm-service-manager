#requires -Version 7.0
# P2-1 回归：服务已注册但清单缺失时，重试「注册并启动」不得重复 install。
# 背景：原序是 install → set… → save → start。install 成功、save 失败（磁盘/权限/外部改动）后，
# 用户只能 `nssm remove` 再重来；再点一次会撞 NSSM「服务已存在」。现在先查 Test-ServicePresent，
# 已存在就只补写参数（Set-NssmServiceParams）+ 保存 + 启动，点重试即可收敛。
# 反向用例守住另一头：服务不在时仍必须走 install，别把「幂等」写成「永不注册」。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
foreach ($module in 'config','util','svc-input','dialogs') { . (Join-Path $RepoRoot "lib/$module.ps1") }
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
# Write-CrashLog 由 GUI 入口定义（service-manager-gui.ps1）；单测不落盘。
function Write-CrashLog([string]$m) { }
function Stop-Background { }

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
function Test-ExeDirPermissive([string]$exe) { return $false }

# Test-SvcInput 要求 exe 是真实存在的文件（PathType Leaf），用临时目录里的空文件满足。
$tmpDir = Join-Path ([IO.Path]::GetTempPath()) "sm-addidem-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
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
} finally {
  if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force }
}
Write-Output 'PASS: 添加服务幂等续做（正反两例）'
