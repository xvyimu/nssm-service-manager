#requires -Version 7.0
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
. (Join-Path $RepoRoot 'lib/acl.ps1')
. (Join-Path $RepoRoot 'lib/security-check.ps1')

# ---- 1. 判据层：读不到 ACL 必须是「未知」，不是「否」 ----
Assert ((Test-DirAclPermissive $null) -eq '未知（无法读取 ACL）') 'null ACL 必须返回未知'

# ---- 2. 汇总层：可注入 ACL 读取，直接断言三种结果 ----
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("sm-verdict-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $t = [ordered]@{ '模块目录' = $tmp }

  $r = Get-SecurityVerdicts $t -AclProvider { param($p) $null }
  Assert ($r.Findings.Count -eq 0 -and $r.Unknown.Count -eq 1) "读不到 ACL 必须进未知，实际 findings=$($r.Findings.Count) unknown=$($r.Unknown.Count)"
  Assert ($r.Unknown[0] -match '模块目录') '未知项要带目标名'

  $r = Get-SecurityVerdicts $t -AclProvider { param($p) throw 'boom' }
  Assert ($r.Findings.Count -eq 0 -and $r.Unknown.Count -eq 1) 'Get-Acl 抛错必须进未知'

  # 判据层可遮蔽：验证「可写」确实进 findings 而不是未知
  function Test-DirAclPermissive($acl) { '是' }
  $r = Get-SecurityVerdicts $t -AclProvider { param($p) 'fake-acl' }
  Assert ($r.Findings.Count -eq 1 -and $r.Unknown.Count -eq 0) "可写必须进 findings，实际 findings=$($r.Findings.Count)"
  Assert ($r.Findings[0] -match '可被普通用户写入') '可写项文案要说明原因'
  Remove-Item function:Test-DirAclPermissive -Force
  . (Join-Path $RepoRoot 'lib/security-check.ps1')

  $r = Get-SecurityVerdicts ([ordered]@{ '缺失目录' = (Join-Path $tmp 'nope') }) -AclProvider { param($p) $null }
  Assert ($r.Unknown.Count -eq 1 -and $r.Unknown[0] -match '不存在') '目录不存在要留痕，不能静默 continue'
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -EA SilentlyContinue }

# ---- 3. 入口脚本必须走这个函数，不得再内联判定 ----
$gui = Get-SourceCodeOnly (Get-Content (Join-Path $RepoRoot 'service-manager-gui.ps1') -Raw -Encoding utf8)
Assert ($gui -match 'Get-SecurityVerdicts') 'GUI 必须调用 Get-SecurityVerdicts'
Assert ($gui -notmatch '\$verdict\s*=\s*try') 'GUI 不得再内联 verdict 判定'

Write-Output 'PASS: ACL 三态在判据层、汇总层与入口接线三处都成立，且入口不再内联判定。'
