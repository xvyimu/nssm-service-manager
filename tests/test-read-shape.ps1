#requires -Version 7.0
# services.json 的三道写入门闩：顶层形状、解析失败拒写、载入后外部修改拒写；外加 .bak 备份。
# 修前：`[]` / `"x"` 是合法 JSON 但取不到 .Keys，Read-SvcFile 返回空清单且当成功，
# 下一次保存把原文件整份覆盖成 `{}`（清单不在 git 里，覆盖后无法恢复）。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'lib/util.ps1')
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }

$dir = Join-Path ([IO.Path]::GetTempPath()) "sm-shape-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $dir | Out-Null
$cfg = Join-Path $dir 'services.json'
$utf8 = [Text.UTF8Encoding]::new($false)
function Write-Cfg([string]$text) { [IO.File]::WriteAllText($cfg, $text, $utf8) }
try {
  # ---- 1. 顶层不是对象：必须抛，不能静默返回空清单 ----
  foreach ($bad in @('[]', '[1,2]', '"hello"', '123', 'null')) {
    Write-Cfg $bad
    $threw = $false
    try { $null = Read-SvcFile $cfg } catch { $threw = $true }
    Assert $threw "Read-SvcFile 应拒绝顶层 $bad（返回空清单会被下一次保存覆盖）"
  }

  # ---- 2. 合法对象：空对象与正常条目都要能读；可选字段原样保留 ----
  Write-Cfg '{}'
  $o = Read-SvcFile $cfg
  Assert ($o.Count -eq 0) '空对象应返回空清单'
  Write-Cfg '{"A":{"port":1234,"url":"","probe":"tcp","httpTimeoutMs":5000}}'
  $o = Read-SvcFile $cfg
  Assert ($o['A'].port -eq 1234) '正常条目应能读出'
  Assert ($o['A'].probe -eq 'tcp') 'probe 应被显式保留（否则保存时被抹掉）'
  Assert ($o['A'].httpTimeoutMs -eq 5000) 'per-service 超时仍应保留'
  Write-Cfg '{"A":{"port":1234,"url":"","probe":"bogus"}}'
  $o = Read-SvcFile $cfg
  Assert (-not $o['A'].ContainsKey('probe')) '非法 probe 不该落进条目'
  Assert (@($script:svcFieldWarnings | Where-Object { $_ -match 'probe' }).Count -eq 1) '非法 probe 应给一条提示'

  # ---- 3. 形状错误要置 svcLoadFailed，后续 Save-Svc 一律拒写 ----
  Write-Cfg '[]'
  $script:svcLoadFailed = $false
  $null = Load-Svc
  Assert $script:svcLoadFailed '顶层形状错误必须置 svcLoadFailed'
  $threw = $false
  try { Save-Svc ([ordered]@{ X = @{ port = 1; url = '' } }) } catch { $threw = $true }
  Assert $threw 'svcLoadFailed 时 Save-Svc 必须拒写'
  Assert ((Get-Content -LiteralPath $cfg -Raw -Encoding UTF8) -eq '[]') '拒写时不得改动原文件'

  # ---- 4. 正常保存：写进新条目 + 上一版留成 .bak ----
  Write-Cfg '{"A":{"port":1234,"url":""}}'
  $svc = Load-Svc
  Assert (-not $script:svcLoadFailed) '合法清单不该被标成解析失败'
  $svc['B'] = @{ port = 2222; url = '' }
  Save-Svc $svc
  Assert (Test-Path -LiteralPath "$cfg.bak") 'Save-Svc 应把上一版留成 services.json.bak'
  Assert ((Get-Content -LiteralPath "$cfg.bak" -Raw -Encoding UTF8) -match '"A"') '.bak 应是保存前的内容'
  Assert ((Get-Content -LiteralPath $cfg -Raw -Encoding UTF8) -match '"B"') '保存后应含新条目'

  # ---- 5. 载入后文件被外部改过：拒绝写（全量写回会抹掉别人的改动）----
  Start-Sleep -Milliseconds 30   # mtime 分辨率约 10ms，避免同刻写入判不出来
  Write-Cfg '{"A":{"port":1234,"url":""},"C":{"port":3333,"url":""}}'
  $threw = $false
  try { Save-Svc $svc } catch { $threw = $true }
  Assert $threw '外部修改后 Save-Svc 必须拒写'
  Assert ((Get-Content -LiteralPath $cfg -Raw -Encoding UTF8) -match '"C"') '拒写后外部改动应原样保留'

  # ---- 6. .bak 被标只读：仍能保存（否则一次误设属性就再也存不了配置）----
  Write-Cfg '{"A":{"port":1234,"url":""}}'
  $script:svcFileStamp = $null
  Save-Svc ([ordered]@{ A = @{ port = 1234; url = '' } })      # 先有 .bak
  (Get-Item -LiteralPath "$cfg.bak").IsReadOnly = $true
  $saved = $true
  try { Save-Svc ([ordered]@{ A = @{ port = 4321; url = '' } }) } catch { $saved = $false }
  Assert $saved "只读 .bak 不该让保存失败：$($_.Exception.Message)"
  Assert ((Get-Content -LiteralPath $cfg -Raw -Encoding UTF8) -match '4321') '只读 .bak 场景下新内容应写入'
} finally {
  Remove-Item -LiteralPath $dir -Recurse -Force -EA SilentlyContinue
}

Write-Output 'PASS: services.json 顶层形状/解析失败/外部修改三道门闩、.bak 备份与只读 .bak 兜底；probe 字段原样保留。'
