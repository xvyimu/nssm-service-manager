#requires -Version 7.0
# 回归：部署与打包共用入口解析及纯文件完整性断言。
# 同时覆盖解析规则、调用方接线与临时目标目录中的缺失模块行为。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
. (Join-Path $RepoRoot 'scripts/lib-entry-modules.ps1')

# ---- 1. 标准写法：只认 "$root\lib\*.ps1" 的 dot-source 行 ----
$synthetic = @'
$root = Split-Path $PSScriptRoot -Parent
. "$root\lib\a.ps1"
. "$root\lib\sub\b.ps1"
  . "$root\lib\c.ps1"
. "$root\lib\a.ps1"
. './other.ps1'
'@
$mods = @(Get-EntryLibModules $synthetic)
Assert ($mods.Count -eq 4) "应解析出 4 行，实际 $($mods.Count)：$($mods -join ',')"
Assert ($mods[0] -eq 'lib\a.ps1' -and $mods[1] -eq 'lib\sub\b.ps1' -and $mods[2] -eq 'lib\c.ps1') "解析结果不对：$($mods -join ',')"
Assert (-not ($mods -contains './other.ps1')) '非 $root\lib 的 dot-source 不该进清单'
Write-Output 'PASS: 只解析 "$root\lib\*.ps1" 的 dot-source 行（含缩进与重复行）'

# ---- 2. 空输入 / 无匹配：返回空集合，不抛（throw 由调用方决定）----
Assert (@(Get-EntryLibModules '').Count -eq 0) '空文本应返回空集合'
Assert (@(Get-EntryLibModules 'Write-Output hi').Count -eq 0) '无匹配应返回空集合'
Write-Output 'PASS: 空输入与无匹配返回空集合，不抛错'

# ---- 3. 真实入口：解析结果非空，且每项都在仓内存在 ----
$entry = Get-Content -LiteralPath (Join-Path $RepoRoot 'service-manager-gui.ps1') -Raw -Encoding UTF8
$real = @(Get-EntryLibModules $entry)
Assert ($real.Count -ge 10) "真实入口解析结果过少：$($real.Count)"
foreach ($m in $real) {
  Assert (Test-Path -LiteralPath (Join-Path $RepoRoot $m)) "入口引用的模块不存在：$m"
}
Write-Output "PASS: 真实入口解析出 $($real.Count) 行，且文件都存在"

# ---- 4. 两个调用方共用共享文件（防止又回到两份正则）----
foreach ($script in 'scripts/deploy-local.ps1', 'scripts/package-release.ps1') {
  $text = Get-Content -LiteralPath (Join-Path $RepoRoot $script) -Raw -Encoding UTF8
  Assert ($text -match 'lib-entry-modules\.ps1') "$script 未 dot-source 共享解析"
  Assert ($text -match 'Assert-EntryLibFiles\s+-SourceRoot\s+\$(SourceRoot|RepoRoot)\s+-TargetRoot\s+\$(Target|stage)') "$script 未调用共享完整性断言"
  Assert ($text -notmatch '\[regex\]::Matches') "$script 仍保留自己的入口正则"
}
Write-Output 'PASS: deploy-local.ps1 与 package-release.ps1 共用 scripts/lib-entry-modules.ps1'

# ---- 5. 纯文件行为：临时夹具，不执行 deploy、入口或 lib 脚本 ----
function Assert-IntegrityFailure([string]$source, [string]$target, [string]$expectedMessage) {
  $failure = $null
  try { Assert-EntryLibFiles -SourceRoot $source -TargetRoot $target } catch { $failure = $_ }
  Assert ($null -ne $failure) "完整性校验应失败：$expectedMessage"
  Assert ($failure.Exception.Message -eq $expectedMessage) "失败原因不符：$($failure.Exception.Message)"
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) "sm-entry-$([guid]::NewGuid().ToString('N'))"
$source = Join-Path $fixture 'source'
$target = Join-Path $fixture 'target'
try {
  New-Item -ItemType Directory -Path (Join-Path $source 'lib'), (Join-Path $target 'lib'), (Join-Path $target 'assets') -Force | Out-Null
  $fixtureEntry = '. "$root\lib\webview-server.ps1"'
  Set-Content -LiteralPath (Join-Path $target 'service-manager-gui.ps1') -Value $fixtureEntry -Encoding UTF8
  foreach ($file in 'launch.vbs', 'assets\icon.ico', 'lib\webview-server.ps1') {
    Set-Content -LiteralPath (Join-Path $target $file) -Value '' -Encoding UTF8
  }
  Set-Content -LiteralPath (Join-Path $source 'lib\webview-server.ps1') -Value '' -Encoding UTF8
  $output = @(Assert-EntryLibFiles -SourceRoot $source -TargetRoot $target)
  Assert ($output.Count -eq 0) '完整目标应成功且无输出'
  Write-Output 'PASS: 完整目标校验成功且无输出'

  foreach ($emptyEntry in '', 'Write-Output hi') {
    Set-Content -LiteralPath (Join-Path $target 'service-manager-gui.ps1') -Value $emptyEntry -Encoding UTF8
    Assert-IntegrityFailure $source $target '未能从 service-manager-gui.ps1 解析出 lib 模块 dot-source 列表'
  }
  Write-Output 'PASS: 空入口与解析零项均拒绝'
  Set-Content -LiteralPath (Join-Path $target 'service-manager-gui.ps1') -Value $fixtureEntry -Encoding UTF8

  Remove-Item -LiteralPath (Join-Path $target 'lib\webview-server.ps1') -Force
  Assert-IntegrityFailure $source $target '程序文件不完整，缺：lib\webview-server.ps1'
  Write-Output 'PASS: 缺 webview-server.ps1 拒绝，入口与源清单重叠只报一次'
  Set-Content -LiteralPath (Join-Path $target 'lib\webview-server.ps1') -Value '' -Encoding UTF8

  New-Item -ItemType Directory -Path (Join-Path $source 'lib\nested') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $source 'lib\nested\indirect.ps1') -Value '' -Encoding UTF8
  Assert-IntegrityFailure $source $target '程序文件不完整，缺：lib\nested\indirect.ps1'
  Write-Output 'PASS: 源新增间接模块而目标缺少时自动拒绝'
  New-Item -ItemType Directory -Path (Join-Path $target 'lib\nested') -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $source 'lib\nested\indirect.ps1') -Destination (Join-Path $target 'lib\nested\indirect.ps1')
  Assert-EntryLibFiles -SourceRoot $source -TargetRoot $target
  Write-Output 'PASS: 补齐新增间接模块后成功'
} finally {
  if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
