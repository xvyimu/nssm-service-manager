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

  # ---- 7. 目标 services.json 被标只读：写前清属性，保存仍应成功 ----
  # 不清属性时 File.Replace 报「无法删除要被替换的文件」，错误里没有「只读」线索，用户无从下手。
  (Get-Item -LiteralPath $cfg).IsReadOnly = $true
  $saved = $true; $roErr = ''
  try { Save-Svc ([ordered]@{ A = @{ port = 5555; url = '' } }) } catch { $saved = $false; $roErr = $_.Exception.Message }
  Assert $saved "只读 services.json 应在清属性后保存成功：$roErr"
  Assert (-not (Get-Item -LiteralPath $cfg -Force).IsReadOnly) '保存后不该留着只读属性'
  Assert ((Get-Content -LiteralPath $cfg -Raw -Encoding UTF8) -match '5555') '只读场景下新内容应写入'

  # ---- 8. 只读属性清不掉时：错误文案必须点明「只读」----
  # 造法：先置只读，再对当前用户 deny WRITE_ATTRIBUTES（deny 优先，管理员身份也拦得住）。
  # 不覆盖这条分支的话，用户看到的仍是 File.Replace 的「无法删除要被替换的文件」，无从下手。
  if (-not ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem)) {
    (Get-Item -LiteralPath $cfg).IsReadOnly = $true
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = Get-Acl -LiteralPath $cfg
    $deny = [Security.AccessControl.FileSystemAccessRule]::new(
      $sid, [Security.AccessControl.FileSystemRights]::WriteAttributes, [Security.AccessControl.AccessControlType]::Deny)
    try {
      $acl.AddAccessRule($deny)
      Set-Acl -LiteralPath $cfg -AclObject $acl
      $threw = $false; $roErr2 = ''
      try { Save-Svc ([ordered]@{ A = @{ port = 6666; url = '' } }) } catch { $threw = $true; $roErr2 = $_.Exception.Message }
      Assert $threw '清不掉只读属性时 Save-Svc 必须失败（否则用户以为存进去了）'
      Assert ($roErr2 -match '只读') "清属性失败的错误文案应点明「只读」，got [$roErr2]"
      Assert ((Get-Content -LiteralPath $cfg -Raw -Encoding UTF8) -notmatch '6666') '失败时不得改动原文件'
    } finally {
      # 还原：拿掉 deny ACE 再清只读，否则外层 Remove-Item -Force 也会被属性写入拒绝绊住
      $acl2 = Get-Acl -LiteralPath $cfg
      $acl2.RemoveAccessRule($deny) | Out-Null
      Set-Acl -LiteralPath $cfg -AclObject $acl2
      (Get-Item -LiteralPath $cfg -Force).IsReadOnly = $false
    }
  } else {
    Write-Output 'SKIP: 以 SYSTEM 运行，deny ACE 会连清理一起锁死，跳过「清不掉只读」用例。'
  }
} finally {
  Remove-Item -LiteralPath $dir -Recurse -Force -EA SilentlyContinue
}

Write-Output 'PASS: services.json 顶层形状/解析失败/外部修改三道门闩、.bak 备份、只读 .bak、只读目标与「只读清不掉」兜底；probe 字段原样保留。'
