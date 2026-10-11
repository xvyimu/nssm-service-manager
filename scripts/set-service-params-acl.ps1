# scripts/set-service-params-acl.ps1 — 把 NSSM 服务 Parameters 注册表键的 ACL 收紧到
# Administrators + SYSTEM（默认 BUILTIN\Users 可读，会把 AppEnvironmentExtra 里的明文
# 密钥暴露给本机任意标准用户）。
#
# 用法（管理员 PowerShell）：
#   pwsh -NoProfile -File scripts/set-service-params-acl.ps1 -ServiceName <服务名>
#
# 失败时回退：原 ACL 不变，脚本抛错并 exit 1。成功时打印前后 ACL 摘要。
# 不删除现有显式 ACE，只禁用继承、移除「非管理员可读」的主体（见下），
# 并确保 Administrators+SYSTEM 完全控制。

param(
  [Parameter(Mandatory=$true)][string]$ServiceName
)
$ErrorActionPreference = 'Stop'

# 需要移除的「非管理员可读」主体。**移除名单与校验名单必须共用这一个判据**——
# 两处各写一份曾导致只摘了 BUILTIN\Users，而默认 ACL 里还有两个 ReadKey 主体
# （实测：APPLICATION PACKAGE AUTHORITY\ALL APPLICATION PACKAGES 与裸 SID
# S-1-15-3-* = ALL RESTRICTED APPLICATION PACKAGES），脚本却报「已收紧到
# Administrators + SYSTEM」——声明不成立。S-1-15-3-* 是 AppContainer 包 SID 前缀，
# 具体后缀随系统而变，故按前缀匹配而非写死。
function Test-LeakyAce([string]$identity){
  $identity -eq 'BUILTIN\Users' -or
  $identity -eq 'NT AUTHORITY\Everyone' -or
  $identity -eq 'Everyone' -or
  $identity -eq 'APPLICATION PACKAGE AUTHORITY\ALL APPLICATION PACKAGES' -or
  $identity -eq 'APPLICATION PACKAGE AUTHORITY\ALL RESTRICTED APPLICATION PACKAGES' -or
  $identity -like 'S-1-15-3-*'
}

# 确保某主体对注册表键有 FullControl。用 SetAccessRule（存在则替换、不存在则添加）——
# 只判「ACE 存在」不判权限，Administrators 只有 ReadKey 时脚本会不补却报成功。
function Set-FullControlAce($acl,[string]$principal){
  $full = [Security.AccessControl.RegistryRights]::FullControl
  $hasFull = $acl.Access | Where-Object {
    $_.IdentityReference.Value -eq $principal -and
    $_.AccessControlType -eq 'Allow' -and
    ($_.RegistryRights -band $full) -eq $full
  }
  if ($hasFull) { return }
  $rule = New-Object Security.AccessControl.RegistryAccessRule(
    $principal, 'FullControl', 'ContainerInherit', 'None', 'Allow')
  $acl.SetAccessRule($rule)
}

$keyPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName\Parameters"
if (-not (Test-Path -LiteralPath $keyPath)) {
  Write-Error "注册表键不存在：$keyPath`n服务可能未注册，或 NSSM 尚未写入 Parameters。"
  exit 1
}

# 取当前 ACL（禁用继承前先存快照，用于失败回退）
$origAcl = Get-Acl -LiteralPath $keyPath
$before = ($origAcl.Access | ForEach-Object { "$($_.IdentityReference.Value) ($($_.RegistryRights) $($_.AccessControlType))" }) -join '; '
Write-Host "改前 ACL: $before"

$newAcl = Get-Acl -LiteralPath $keyPath  # 副本，用于改后写回
# 禁用继承：本键的显式 ACE 保留，继承来的 ACE 移除（这是收紧的关键——继承自 Services 的 Users 读权限）
$newAcl.SetAccessRuleProtection($true, $true)

# 移除所有「非管理员可读」主体的 ACE（无论继承还是显式）——判据集中在 Test-LeakyAce，
# 与下面的校验共用，避免两处名单漂移。
$toRemove = @($newAcl.Access | Where-Object { Test-LeakyAce $_.IdentityReference.Value })
foreach ($ace in $toRemove) { [void]$newAcl.RemoveAccessRule($ace) }

# 确保 Administrators + SYSTEM 完全控制（SetAccessRule 幂等：已有 FullControl 则不重复添加）
Set-FullControlAce $newAcl 'BUILTIN\Administrators'
Set-FullControlAce $newAcl 'NT AUTHORITY\SYSTEM'

try {
  Set-Acl -LiteralPath $keyPath -AclObject $newAcl
} catch {
  # 写回失败：原 ACL 未动（Set-Acl 是原子写注册表键的 DACL）
  Write-Error "ACL 写回失败：$($_.Exception.Message)`n原 ACL 未变（回退安全）。"
  exit 1
}

# 校验：读回确认所有「非管理员可读」主体已移除（Allow 与 Deny 都查——Deny 不会授予读权限，
# 但残留说明清理不干净，必须能证明）。判据与移除阶段共用 Test-LeakyAce，名单不会再漂移。
$verify = Get-Acl -LiteralPath $keyPath
$after = ($verify.Access | ForEach-Object { "$($_.IdentityReference.Value) ($($_.RegistryRights) $($_.AccessControlType))" }) -join '; '
Write-Host "改后 ACL: $after"
$leaked = $verify.Access | Where-Object { Test-LeakyAce $_.IdentityReference.Value }
if ($leaked) {
  $leakedDesc = ($leaked | ForEach-Object { "$($_.IdentityReference.Value) ($($_.AccessControlType))" }) -join '; '
  Write-Error "校验失败：仍有 Users/Everyone 的 ACE 残留：$leakedDesc"
  # 不自动回退——回退会把权限重新放宽，更危险。提示人工处理。
  exit 1
}
Write-Host "已收紧 $ServiceName 的 Parameters ACL 到 Administrators + SYSTEM。"
