#requires -Version 7.0
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$cfg=Join-Path $RepoRoot 'services.json'
$cfgExisted = Test-Path -LiteralPath $cfg
$before = if ($cfgExisted) { (Get-FileHash -LiteralPath $cfg).Hash } else { $null }
. (Join-Path $RepoRoot 'lib/util.ps1')
. (Join-Path $RepoRoot 'lib/add-svc.ps1')
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

  # ---- Test-EnvPairs：缺 = / 空 key / APPDATA 交互路径 ----
  Assert ($null -eq (Test-EnvPairs @('A=1','B=2'))) 'well-formed pairs should pass'
  Assert ((Test-EnvPairs @('NOVALUE')) -match '格式错误') 'pair without = should fail'
  Assert ((Test-EnvPairs @('=1')) -match '格式错误') 'empty key should fail'
  Assert ((Test-EnvPairs @('APPDATA=C:\Users\bob\AppData\Roaming')) -match 'APPDATA') 'interactive APPDATA should fail'
  Assert ($null -eq (Test-EnvPairs @('APPDATA=C:\Windows\System32\config\systemprofile\AppData\Roaming'))) 'system-profile APPDATA should pass'
  Assert ($null -eq (Test-EnvPairs @())) 'empty pair list should pass'

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

  if ($cfgExisted) {
    if ((Get-FileHash -LiteralPath $cfg).Hash -ne $before) { throw 'Test changed services.json.' }
  } elseif (Test-Path -LiteralPath $cfg) {
    throw 'Test created services.json where none existed.'
  }
  Write-Output 'PASS: Test-SvcInput (name/exe/port/dup + order), ConvertTo-EnvPairs (sep/trim/drop-empty), Test-EnvPairs (format/APPDATA), Get-NssmSetSpec (AppExit dual-token, env multi-token, optional-key omission, array-typed values).'
} finally {
  Remove-Item -LiteralPath $fakeExe -Force -EA SilentlyContinue
}