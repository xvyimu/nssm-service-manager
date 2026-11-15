#requires -Version 7.0
# ACL 判据回归：三处（GUI 自检 / 注册表收紧 / 部署门禁）共用 lib/acl.ps1 的同一份名单。
# 此前各写一份并漂移过——deploy 那份只认 Users/Everyone，漏了 AppContainer SID（S-1-15-3-*）。
# 这里只用内存里的 ACL 对象验判据，不读真实文件系统、不改任何 ACL。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'lib/acl.ps1')
. (Join-Path $PSScriptRoot 'test-helpers.ps1')

# ---- A. 宽面主体名单 ----
$wide = @(
  'BUILTIN\Users', 'Users', 'Everyone', 'NT AUTHORITY\Everyone',
  'NT AUTHORITY\Authenticated Users', 'Authenticated Users',
  'APPLICATION PACKAGE AUTHORITY\ALL APPLICATION PACKAGES',
  'APPLICATION PACKAGE AUTHORITY\ALL RESTRICTED APPLICATION PACKAGES',
  'S-1-15-3-1024-1065365936-1281604716-3511738428-1654721687-432734479-3232135806-4053264122-3456934681'
)
foreach ($id in $wide) { Assert (Test-WidePrincipal $id) "「$id」应算宽面主体" }
$narrow = @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators', 'NT SERVICE\TrustedInstaller', 'NT AUTHORITY\LocalService', 'S-1-5-18', '', $null)
foreach ($id in $narrow) { Assert (-not (Test-WidePrincipal $id)) "「$id」不该算宽面主体" }
Write-Output 'PASS: 宽面主体名单（Users/Everyone/Authenticated Users/AppContainer 具名与 SID 前缀），SYSTEM/Administrators 不算。'

# ---- B. 写能力判据 ----
foreach ($r in @('Write', 'Modify', 'FullControl', 'Read, Write', 'WriteData')) {
  Assert (Test-WriteCapable $r) "「$r」应算可写"
}
foreach ($r in @('ReadAndExecute', 'Read', 'ExecuteFile', '', $null)) {
  Assert (-not (Test-WriteCapable $r)) "「$r」不该算可写"
}
Write-Output 'PASS: 写能力判据只认 Write/Modify/FullControl，Read/Execute 不算。'

# ---- C. 目录 ACL：宽面主体 + 写权限 = 过宽 ----
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new('BUILTIN\Users', 'Write', 'Allow'))
Assert ((Test-AclHasWideWrite $acl) -eq $true) '标准用户可写的目录应判过宽'

$aclDeny = [Security.AccessControl.DirectorySecurity]::new()
$aclDeny.SetAccessRuleProtection($true, $false)
$aclDeny.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new('BUILTIN\Users', 'Write', 'Deny'))
Assert ((Test-AclHasWideWrite $aclDeny) -eq $false) '显式 Deny 不是漏洞，不该判过宽'

$aclTight = [Security.AccessControl.DirectorySecurity]::new()
$aclTight.SetAccessRuleProtection($true, $false)
$aclTight.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new('BUILTIN\Administrators', 'FullControl', 'Allow'))
$aclTight.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new('NT AUTHORITY\SYSTEM', 'FullControl', 'Allow'))
$aclTight.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new('BUILTIN\Users', 'ReadAndExecute', 'Allow'))
Assert ((Test-AclHasWideWrite $aclTight) -eq $false) '仅管理员/系统可写、用户只读的目录不该判过宽'

Assert ($null -eq (Test-AclHasWideWrite $null)) '读不到 ACL 时应返回 $null（未知），不冒充「否」'
Write-Output 'PASS: 目录 ACL 判定（Allow+写=过宽；Deny 不算；只读不放宽；读不到返回未知）。'

# ---- D. 注册表 ACL：同一份主体名单，读权限不算可写 ----
$keyAcl = [Security.AccessControl.RegistrySecurity]::new()
$keyAcl.SetAccessRuleProtection($true, $false)
$keyAcl.AddAccessRule([Security.AccessControl.RegistryAccessRule]::new('BUILTIN\Users', 'ReadKey', 'Allow'))
Assert ((Test-AclHasWideWrite $keyAcl) -eq $false) '注册表只读不算可写（读暴露由 Test-WidePrincipal 单独判）'

$keyAcl2 = [Security.AccessControl.RegistrySecurity]::new()
$keyAcl2.SetAccessRuleProtection($true, $false)
# 用 SecurityIdentifier 构造：AppContainer 的 SID 在字符串构造时会被要求先能翻译成账户名。
$appContainerSid = [Security.Principal.SecurityIdentifier]::new('S-1-15-3-1024-1065365936-1281604716-3511738428-1654721687-432734479-3232135806-4053264122-3456934681')
$keyAcl2.AddAccessRule([Security.AccessControl.RegistryAccessRule]::new($appContainerSid, 'WriteKey', 'Allow'))
Assert ((Test-AclHasWideWrite $keyAcl2) -eq $true) 'AppContainer SID 有写权限应判过宽'
Write-Output 'PASS: 注册表 ACL 用同一份判据（ReadKey 不算；AppContainer 写权限算）。'

# ---- E. 三处调用方仍然按各自契约包装 ----
. (Join-Path $RepoRoot 'lib/security-check.ps1')
$wrapped = Test-DirAclPermissive $acl
Assert ($wrapped -eq '是') "Test-DirAclPermissive 应把过宽 ACL 翻成「是」，实际「$wrapped」"
$wrappedNull = Test-DirAclPermissive $null
Assert ($wrappedNull -match '^未知') "读不到 ACL 时应返回「未知」，实际「$wrappedNull」"
Write-Output 'PASS: GUI 自检的 Test-DirAclPermissive 仍返回「是/否/未知」三态。'
