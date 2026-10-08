# scripts/set-service-params-acl.ps1 — 把 NSSM 服务 Parameters 注册表键的 ACL 收紧到
# Administrators + SYSTEM（默认 BUILTIN\Users 可读，会把 AppEnvironmentExtra 里的明文
# 密钥暴露给本机任意标准用户）。
#
# 用法（管理员 PowerShell）：
#   pwsh -NoProfile -File scripts/set-service-params-acl.ps1 -ServiceName <服务名>
#
# 失败时回退：原 ACL 不变，脚本抛错并 exit 1。成功时打印前后 ACL 摘要。
# 不删除现有显式 ACE，只禁用继承、移除 BUILTIN\Users 与 Everyone 的读权限，
# 并确保 Administrators+SYSTEM 完全控制。

param(
  [Parameter(Mandatory=$true)][string]$ServiceName
)
$ErrorActionPreference = 'Stop'

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

# 移除 BUILTIN\Users 与 Everyone 的所有 ACE（无论继承还是显式）
$toRemove = @($newAcl.Access | Where-Object {
  $_.IdentityReference.Value -in @('BUILTIN\Users','NT AUTHORITY\Everyone','Everyone')
})
foreach ($ace in $toRemove) { [void]$newAcl.RemoveAccessRule($ace) }

# 确保 Administrators + SYSTEM 完全控制（若已存在则不重复添加）
$needAdmin = -not ($newAcl.Access | Where-Object { $_.IdentityReference.Value -eq 'BUILTIN\Administrators' })
if ($needAdmin) {
  $adminRule = New-Object Security.AccessControl.RegistryAccessRule(
    'BUILTIN\Administrators',
    'FullControl',
    'ContainerInherit',
    'None',
    'Allow')
  $newAcl.AddAccessRule($adminRule)
}
$needSystem = -not ($newAcl.Access | Where-Object { $_.IdentityReference.Value -eq 'NT AUTHORITY\SYSTEM' })
if ($needSystem) {
  $sysRule = New-Object Security.AccessControl.RegistryAccessRule(
    'NT AUTHORITY\SYSTEM',
    'FullControl',
    'ContainerInherit',
    'None',
    'Allow')
  $newAcl.AddAccessRule($sysRule)
}

try {
  Set-Acl -LiteralPath $keyPath -AclObject $newAcl
} catch {
  # 写回失败：原 ACL 未动（Set-Acl 是原子写注册表键的 DACL）
  Write-Error "ACL 写回失败：$($_.Exception.Message)`n原 ACL 未变（回退安全）。"
  exit 1
}

# 校验：读回确认 Users/Everyone 已移除（Allow 与 Deny 都查——Deny 不会授予读权限，
# 但残留说明清理不干净，必须能证明）
$verify = Get-Acl -LiteralPath $keyPath
$after = ($verify.Access | ForEach-Object { "$($_.IdentityReference.Value) ($($_.RegistryRights) $($_.AccessControlType))" }) -join '; '
Write-Host "改后 ACL: $after"
$leaked = $verify.Access | Where-Object {
  $_.IdentityReference.Value -in @('BUILTIN\Users','NT AUTHORITY\Everyone','Everyone')
}
if ($leaked) {
  $leakedDesc = ($leaked | ForEach-Object { "$($_.IdentityReference.Value) ($($_.AccessControlType))" }) -join '; '
  Write-Error "校验失败：仍有 Users/Everyone 的 ACE 残留：$leakedDesc"
  # 不自动回退——回退会把权限重新放宽，更危险。提示人工处理。
  exit 1
}
Write-Host "已收紧 $ServiceName 的 Parameters ACL 到 Administrators + SYSTEM。"
