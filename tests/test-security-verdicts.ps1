#requires -Version 7.0
# 安全自检三态的映射：判据返回「未知」时，消费端必须能区分「可写」与「读不到」，
# 不能把读不到当安全悄悄放过（2026-11-16 独立评审发现的口子）。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
. (Join-Path $RepoRoot 'lib/acl.ps1')
. (Join-Path $RepoRoot 'lib/security-check.ps1')

# 1. 判据层：拿不到 ACL（$null）必须返回「未知」，不能返回「否」。
$verdict = Test-DirAclPermissive $null
Assert ($verdict -eq '未知（无法读取 ACL）') "拿不到 ACL 时应返回未知，实际：$verdict"

# 2. 消费端：GUI 自检必须把「未知」单独收口，并与「宽 ACL」用不同措辞。
$guiRaw = [IO.File]::ReadAllText((Join-Path $RepoRoot 'service-manager-gui.ps1'), [Text.UTF8Encoding]::new($false))
$gui = ($guiRaw -split "`r?`n" | Where-Object { $_.Trim() -notmatch '^#' }) -join "`n"
Assert ($gui -match 'securityUnknown\s*=\s*@\(\)') 'GUI 自检缺少「无法判定」收集器。'
Assert ($gui -match '不等于安全') 'GUI 提示必须点明「读不到 ACL 不等于安全」，不能直接建议迁移。'
$wideIdx = $gui.IndexOf('管理员进程会执行这些位置的代码')
$unknownIdx = $gui.IndexOf('读不到 ACL 不等于安全')
Assert ($wideIdx -ge 0 -and $unknownIdx -gt $wideIdx) '两种结论的措辞必须分开，且「未知」段落独立成句。'

# 3. 重复日志回归：同一个失败不得既在 catch 里写、又被汇总循环再写一遍。
$crashWrites = [regex]::Matches($gui, 'Write-CrashLog "Security: \$f"').Count
Assert ($crashWrites -eq 1) "宽 ACL 的 crash log 只应写一次，实际 $crashWrites 处。"

Write-Output 'PASS: ACL 三态在判据与消费端都成立；「未知」不再被当安全；同一失败不重复写日志。'
