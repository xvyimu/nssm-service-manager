#requires -Version 7.0
# S1/S2 回归：scripts/set-service-params-acl.ps1 的「非管理员可读主体」判据必须只有一份。
#
# 背景（审计实测）：该脚本原先移除名单与校验名单各写一份，且都只列 BUILTIN\Users / Everyone。
# 而 NSSM 服务 Parameters 键的默认 ACL 里除 Users 外还有两条 ReadKey 主体：
#   APPLICATION PACKAGE AUTHORITY\ALL APPLICATION PACKAGES
#   S-1-15-3-*（= ALL RESTRICTED APPLICATION PACKAGES，AppContainer 包 SID）
# 于是脚本摘掉 Users、校验通过、打印「已收紧到 Administrators + SYSTEM」——声明不成立。
# 修法：判据抽成单一函数 Test-LeakyAce，移除与校验共用。本测试守这条不变量。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }

$scriptPath = Join-Path $RepoRoot 'scripts/set-service-params-acl.ps1'
Assert (Test-Path -LiteralPath $scriptPath) 'ACL script missing.'

$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) "ACL script has parse errors: $($errors[0].Message)"

# 取脚本里**真实的** Test-LeakyAce 定义并执行——测的是实现，不是副本。
$fn = $ast.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-LeakyAce'
}, $true) | Select-Object -First 1
Assert ($null -ne $fn) 'Test-LeakyAce 未定义——泄漏主体判据没有单一来源（回归到内联名单了？）。'
Invoke-Expression $fn.Extent.Text

# 默认 ACL 实测出现过的 ReadKey 主体都必须判为泄漏
$leaky = @(
  'BUILTIN\Users',
  'NT AUTHORITY\Everyone',
  'Everyone',
  'APPLICATION PACKAGE AUTHORITY\ALL APPLICATION PACKAGES',
  'APPLICATION PACKAGE AUTHORITY\ALL RESTRICTED APPLICATION PACKAGES',
  'S-1-15-3-1024-1065365936-1281604716-3511738428-1654721688-432734479-3232135806-4053264122-3456934681'
)
foreach ($id in $leaky) { Assert (Test-LeakyAce $id) "应判为泄漏却未命中：$id" }

# 非泄漏主体不得误判（否则会把该保留的 ACE 摘掉）
foreach ($id in @('BUILTIN\Administrators','NT AUTHORITY\SYSTEM','CREATOR OWNER','BUILTIN\Users2','S-1-5-18')) {
  Assert (-not (Test-LeakyAce $id)) "不应判为泄漏却命中：$id"
}

# 静态不变量：判据函数应被「定义 + 移除处 + 校验处」至少引用 3 次；
# 且脚本里不应再出现内联的主体名单（-in @(...) 形式）。
$text = Get-Content -Raw -LiteralPath $scriptPath
$uses = ([regex]::Matches($text, 'Test-LeakyAce')).Count
Assert ($uses -ge 3) "Test-LeakyAce 应被定义+移除+校验引用至少 3 次，实际 $uses 次。"
Assert ($text -notmatch [regex]::Escape("IdentityReference.Value -in @(")) '不应再出现内联的主体名单（-in @(...)）——名单必须单源。'

# ---- S2：Set-FullControlAce 必须判「权限」而非「ACE 存在」----
# 旧实现只判 ACE 存在：Administrators 只有 ReadKey 时脚本不补 FullControl 却报成功。
# 用记录调用的假 ACL 直测真函数（不碰注册表）。
$fnFull = $ast.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-FullControlAce'
}, $true) | Select-Object -First 1
Assert ($null -ne $fnFull) 'Set-FullControlAce 未定义。'
Invoke-Expression $fnFull.Extent.Text

class FakeAcl {
  [System.Collections.Generic.List[object]]$Access = @()
  [System.Collections.Generic.List[object]]$SetCalls = @()
  [void] SetAccessRule($rule) { $this.SetCalls.Add($rule) }
}
function New-FakeAceAcl([string]$principal, [string]$rights) {
  $a = [FakeAcl]::new()
  if ($principal) {
    $a.Access.Add([pscustomobject]@{
      IdentityReference = [pscustomobject]@{ Value = $principal }
      AccessControlType = 'Allow'
      RegistryRights    = [System.Security.AccessControl.RegistryRights]::$rights
    })
  }
  $a
}
# Administrators 只有 ReadKey → 应补 FullControl（SetAccessRule 被调一次）
$aclA = New-FakeAceAcl 'BUILTIN\Administrators' 'ReadKey'
Set-FullControlAce $aclA 'BUILTIN\Administrators'
Assert ($aclA.SetCalls.Count -eq 1) "ReadKey-only 主体应被补 FullControl，实际 SetAccessRule 调用 $($aclA.SetCalls.Count) 次。"
# 已 FullControl → 不重复添加（幂等）
$aclB = New-FakeAceAcl 'BUILTIN\Administrators' 'FullControl'
Set-FullControlAce $aclB 'BUILTIN\Administrators'
Assert ($aclB.SetCalls.Count -eq 0) "已 FullControl 不应重复添加，实际 $($aclB.SetCalls.Count) 次。"
# 无该主体 → 应添加
$aclC = New-FakeAceAcl '' ''
Set-FullControlAce $aclC 'NT AUTHORITY\SYSTEM'
Assert ($aclC.SetCalls.Count -eq 1) '缺失主体应被添加 FullControl。'

Write-Output 'PASS: ACL script has a single leaky-principal predicate (Test-LeakyAce) shared by removal and verification; covers AppContainer package SIDs; no inlined principal list; Set-FullControlAce keys on rights (ReadKey-only gets FullControl, already-full is idempotent).'
