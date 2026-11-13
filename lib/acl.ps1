# lib/acl.ps1 — ACL 判定的唯一来源：哪些主体算「本机任意用户」、哪些权限算「能替换文件」。
#
# 三处调用方此前各写一份名单：GUI 安全检查（lib/security-check.ps1）、注册表收紧
# （scripts/set-service-params-acl.ps1）、部署门禁（scripts/deploy-local.ps1）。
# 已经漂过一次：deploy 那份只匹配 Users/Everyone，漏了 AppContainer SID（S-1-15-3-*）。
# 纯函数，不碰文件系统、不弹窗；判据回归见 tests/test-acl.ps1。

# 宽面主体：本机任意标准用户，或能承载任意代码的包容器。
# 名字与 SID 都要认：真实 ACL 经 Get-Acl 回来是本地化名字（德语机器上是
# VORDEFINIERT\Benutzer），而按 SID 读回来又是裸 SID——只认一种会在别的语言/调用路径上漏判。
# 实测默认注册表 ACL 里出现的是 APPLICATION PACKAGE AUTHORITY\ALL APPLICATION PACKAGES 与裸 SID。
function Test-WidePrincipal([string]$identity){
  if (-not $identity) { return $false }
  # 知名 SID：BUILTIN\Users / Everyone / Authenticated Users，以及 AppContainer 包前缀。
  if ($identity -in @('S-1-5-32-545','S-1-1-0','S-1-5-11')) { return $true }
  if ($identity -like 'S-1-15-3-*') { return $true }
  $identity -in @(
    'BUILTIN\Users', 'Users',
    'Everyone', 'NT AUTHORITY\Everyone',
    'NT AUTHORITY\Authenticated Users', 'Authenticated Users',
    'APPLICATION PACKAGE AUTHORITY\ALL APPLICATION PACKAGES',
    'APPLICATION PACKAGE AUTHORITY\ALL RESTRICTED APPLICATION PACKAGES'
  )
}

# 写能力：Read/Execute 不算。「别人能替换文件」只由 Write 位决定，Modify/FullControl 都含 Write 位。
function Test-WriteCapable($rights){
  if ($null -eq $rights) { return $false }
  ([string]$rights) -match 'Write|Modify|FullControl'
}

# 目录 / 注册表键的 ACL 是否对宽面主体开放了写权限。
# 返回 $true / $false；$acl 为 $null（读不到）时返回 $null——调用方自己决定按「未知」还是「不通过」处理
# （GUI 显示未知，部署门禁直接判失败）。
function Test-AclHasWideWrite($acl){
  if ($null -eq $acl) { return $null }
  # 内存里新建的 ACL 对象 .Access 为 $null，只有从文件/键读回来的才有值：
  # 统一走 GetAccessRules，且按 SID 取（不翻译名字，避免本地化名与非映射 SID 抛异常）。
  $rules = $null
  try { $rules = $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) } catch { $rules = $null }
  if ($null -eq $rules) { try { $rules = $acl.Access } catch { return $null } }
  if ($null -eq $rules) { return $null }
  foreach ($a in $rules) {
    # 显式 Deny 不是漏洞：只判 Allow。此前三份实现都没管类型，Deny ACE 会把结论翻成「过宽」。
    if ($a.AccessControlType -ne 'Allow') { continue }
    if (-not (Test-WidePrincipal $a.IdentityReference.Value)) { continue }
    $rights = if ($a.PSObject.Properties['FileSystemRights']) { $a.FileSystemRights }
              elseif ($a.PSObject.Properties['RegistryRights']) { $a.RegistryRights }
              else { $null }
    if (Test-WriteCapable $rights) { return $true }
  }
  $false
}
