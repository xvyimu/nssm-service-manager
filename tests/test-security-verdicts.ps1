#requires -Version 7.0
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'test-helpers.ps1')
. (Join-Path $RepoRoot 'lib/acl.ps1')
. (Join-Path $RepoRoot 'lib/security-check.ps1')
# CLI 的提示文案函数在 add-svc.ps1 里；该文件顶层只有函数定义，点源即可。
. (Join-Path $RepoRoot 'lib/add-svc.ps1')

# ---- 1. 判据层：读不到 ACL 必须是「未知」，不是「否」 ----
Assert ((Test-DirAclPermissive $null) -eq '未知（无法读取 ACL）') 'null ACL 必须返回未知'

# ---- 1b. 三态只有一份实现（Get-DirAclVerdict）：未解析 / 不存在 / 抛错都要带原因 ----
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("sm-verdict-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $v = Get-DirAclVerdict ''
  Assert ($v -eq '未知（无法定位目录）') "空目录必须是「无法定位目录」，got $v"

  $missingDir = Join-Path $tmp 'nope'
  $v = Get-DirAclVerdict $missingDir
  Assert ($v -eq '未知（目录不存在）') "目录不存在必须如实说，got $v"

  # 抛错不能压成「否」：异常消息要带回来，否则调用方只能看到「未知」瞎猜
  $v = Get-DirAclVerdict $tmp -AclProvider { param($p) throw '拒绝访问（模拟）' }
  Assert (($v -like '未知（无法读取 ACL*') -and ($v -match '拒绝访问（模拟）')) "抛错要带异常消息，got $v"

  # ---- 2. 汇总层：-AclProvider 注入，直接断言三种结果 ----
  $t = [ordered]@{ '模块目录' = $tmp }

  $r = Get-SecurityVerdicts $t -AclProvider { param($p) $null }
  Assert ($r.Findings.Count -eq 0 -and $r.Unknown.Count -eq 1) "读不到 ACL 必须进未知，实际 findings=$($r.Findings.Count) unknown=$($r.Unknown.Count)"
  $u = $r.Unknown[0]
  Assert ($u.Key -eq '模块目录' -and $u.Path -eq $tmp) "未知项要带目标名与路径，got Key=$($u.Key) Path=$($u.Path)"
  $props = @($u.PSObject.Properties.Name)
  Assert ((@('Key','Path','Reason','Detail') | Where-Object { $props -notcontains $_ }).Count -eq 0) "未知项必须有 Key/Path/Reason/Detail 四个属性，实际 $($props -join ',')"
  Assert ($u.Reason -eq 'unreadable') "读不到 ACL 的 Reason 必须是 unreadable，got $($u.Reason)"
  Assert ($u.Detail -like '未知（无法读取 ACL*') "Detail 要保留判定原文，got $($u.Detail)"

  $r = Get-SecurityVerdicts $t -AclProvider { param($p) throw 'boom' }
  Assert ($r.Findings.Count -eq 0 -and $r.Unknown.Count -eq 1) 'Get-Acl 抛错必须进未知'
  Assert ($r.Unknown[0].Reason -eq 'unreadable' -and $r.Unknown[0].Detail -match 'boom') "抛错原因要留痕，got $($r.Unknown[0].Reason) / $($r.Unknown[0].Detail)"

  # 判据层可遮蔽：验证「可写」确实进 findings 而不是未知
  function Test-DirAclPermissive($acl) { '是' }
  $r = Get-SecurityVerdicts $t -AclProvider { param($p) 'fake-acl' }
  Assert ($r.Findings.Count -eq 1 -and $r.Unknown.Count -eq 0) "可写必须进 findings，实际 findings=$($r.Findings.Count)"
  Assert ($r.Findings[0] -match '可被普通用户写入') '可写项文案要说明原因'
  Assert ($r.Findings[0] -match [regex]::Escape("模块目录（$tmp）")) '可写项要带目标名与路径'
  Remove-Item function:Test-DirAclPermissive -Force
  . (Join-Path $RepoRoot 'lib/security-check.ps1')

  $r = Get-SecurityVerdicts ([ordered]@{ '缺失目录' = $missingDir }) -AclProvider { param($p) $null }
  Assert ($r.Unknown.Count -eq 1) '目录不存在要留痕，不能静默 continue'
  Assert ($r.Unknown[0].Reason -eq 'missing' -and $r.Unknown[0].Detail -match '不存在') "目录不存在的 Reason 必须是 missing，got $($r.Unknown[0].Reason)"

  $r = Get-SecurityVerdicts ([ordered]@{ '空目标' = '' }) -AclProvider { param($p) $null }
  Assert ($r.Unknown.Count -eq 1 -and $r.Unknown[0].Reason -eq 'unresolved' -and $r.Unknown[0].Path -eq '') "未解析路径的 Reason 必须是 unresolved，got $($r.Unknown[0].Reason)"
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -EA SilentlyContinue }

# ---- 3. 入口必须走这个函数：用 AST 认命令调用，不看字面量（here-string / 注释都骗不过） ----
$guiPath = Join-Path $RepoRoot 'service-manager-gui.ps1'
$tk = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($guiPath, [ref]$tk, [ref]$parseErrors)
Assert ($parseErrors.Count -eq 0) "入口脚本必须可解析，got $($parseErrors.Count) 个语法错误"
# 名称按「可能带模块限定前缀」匹配；再用 InvocationOperator 抓 & $fn 这类解析不出名字的调用。
$aclCalls = $ast.FindAll({
    param($a) $a -is [System.Management.Automation.Language.CommandAst] -and ([string]$a.GetCommandName() -match '(^|\\)Get-Acl$')
  }, $true)
Assert ($aclCalls.Count -eq 0) '三态只在 lib 里：入口的 AST 里不得出现 Get-Acl 命令调用（含模块限定名）'
$indirect = $ast.FindAll({
    param($a) $a -is [System.Management.Automation.Language.CommandAst] -and
               $a.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and
               $a.CommandElements.Count -gt 0 -and $a.CommandElements[0] -is [System.Management.Automation.Language.VariableExpressionAst]
  }, $true)
Assert ($indirect.Count -eq 0) '入口不得用 & $fn 间接调用：AST 认不出名字，测试与审计都会漏'
# here-string 里的同样字串不是 CommandAst，按命令调用计数即可——正则做不到这一点。
$verdictCalls = $ast.FindAll({
    param($a) $a -is [System.Management.Automation.Language.CommandAst] -and $a.GetCommandName() -eq 'Get-SecurityVerdicts'
  }, $true)
Assert ($verdictCalls.Count -ge 1) '入口必须真的调用 Get-SecurityVerdicts（放进 here-string 或注释里不算）'
$guiCode = Get-SourceCodeOnly (Get-Content $guiPath -Raw -Encoding utf8)
Assert ($guiCode -match 'securityUnknown') '入口仍要消费未知项'

# ---- 4. 未知分支要带出原因：对话框与 CLI 都不能统一说成「读不到 ACL」 ----
$dlgCode = Get-SourceCodeOnly (Get-Content (Join-Path $RepoRoot 'lib\dialogs.ps1') -Raw -Encoding utf8)
Assert ($dlgCode -notmatch '读不到可执行文件所在目录的 ACL') '未知分支不得把三种原因统一说成「读不到 ACL」'
Assert ($dlgCode -match '\$exeDirVerdict' -and $dlgCode -match '无法判定') '未知分支要把判定结果（含原因）带进提示'
# CLI 侧：先按 AST 认「真的调用了判定函数」，再对提示文案做行为断言（文本匹配挡不住 here-string）。
$cliPath = Join-Path $RepoRoot 'lib\add-svc.ps1'
$tk2 = $null; $err2 = $null
$cliAst = [System.Management.Automation.Language.Parser]::ParseFile($cliPath, [ref]$tk2, [ref]$err2)
Assert ($err2.Count -eq 0) "add-svc.ps1 必须可解析，got $($err2.Count) 个语法错误"
$cliCalls = $cliAst.FindAll({
    param($a) $a -is [System.Management.Automation.Language.CommandAst] -and ([string]$a.GetCommandName() -match '(^|\\)Get-ExeDirVerdict$')
  }, $true)
Assert ($cliCalls.Count -ge 1) 'CLI 的 -Add 必须真的调用 Get-ExeDirVerdict（AST 计数，here-string 不算）'

# 行为断言：三种判定 → 三种输出，文案与原因同源。
$warn = Get-AddPreflightNotice 'C:\tools\svc.exe' '是'
Assert ($warn -like '警告*' -and $warn -match '仅管理员可写') "可写目录要给出迁移建议，got: $warn"
$unknown = Get-AddPreflightNotice 'C:\nope\svc.exe' '未知（目录不存在）'
Assert ($unknown -like '提示*' -and $unknown -match '这不等于安全' -and $unknown -match '目录不存在') "未知要给原因且声明不等于安全，got: $unknown"
Assert ((Get-AddPreflightNotice 'C:\tools\svc.exe' '否') -eq '') '不可写目录不该有提示'

# ---- 5. CLI 接线不能靠文件级计数假通过：调用要在 Add-SvcFromCli 体内，notice 由判定派生并被写出 ----
# 上面 4 的计数只证明「文件里出现过这个名字」，挡不住两类突变：
#   M1 保留调用却把 $notice 硬编码；M3 把调用挪到同文件另一个函数（文件级计数仍 ≥1）。
# 下面按数据流认：定义体 → 判定赋值 → 传给文案函数 → 写出。
$fnDefs = @($cliAst.FindAll({
    param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Add-SvcFromCli'
  }, $true))
Assert ($fnDefs.Count -eq 1) "add-svc.ps1 必须有且只有一个 Add-SvcFromCli 定义，实际 $($fnDefs.Count)"
$fn = $fnDefs[0]

# 5a. 调用点必须在函数定义体的 extent 内。
$inBodyVerdictCalls = @($fn.FindAll({
    param($a) $a -is [System.Management.Automation.Language.CommandAst] -and ([string]$a.GetCommandName() -match '(^|\\)Get-ExeDirVerdict$')
  }, $true))
Assert ($inBodyVerdictCalls.Count -ge 1) "Get-ExeDirVerdict 必须在 Add-SvcFromCli 体内调用（挪到同文件别的函数等于接线断了），实际 $($inBodyVerdictCalls.Count) 处"

# 5b. notice 必须由判定派生：$notice = Get-AddPreflightNotice $exe $verdict（$verdict 体内由 Get-ExeDirVerdict 赋值），
# 或等价的直接内联写法 $notice = Get-AddPreflightNotice $exe (Get-ExeDirVerdict $exe)。两种都算「判定结果流进文案」。
$noticeAssigns = @($fn.FindAll({
    param($a)
    $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $a.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
    $a.Left.VariablePath.UserPath -eq 'notice' -and
    @($a.Right.FindAll({
        param($b) $b -is [System.Management.Automation.Language.CommandAst] -and [string]$b.GetCommandName() -eq 'Get-AddPreflightNotice'
      }, $true)).Count -ge 1
  }, $true))
Assert ($noticeAssigns.Count -ge 1) 'notice 必须由 Get-AddPreflightNotice 的返回值产生（改成字面量 = 判定结果被丢弃）'
$noticeCmd = @($noticeAssigns[0].Right.FindAll({
    param($a) $a -is [System.Management.Automation.Language.CommandAst] -and [string]$a.GetCommandName() -eq 'Get-AddPreflightNotice'
  }, $true))[0]
$noticeArgs = @($noticeCmd.CommandElements | Select-Object -Skip 1)
$noticeArgVars = @($noticeArgs | Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] } |
  ForEach-Object { $_.VariablePath.UserPath })
# 内联写法：(Get-ExeDirVerdict $exe) 整个是参数子树里的命令调用，不是赋值。
$inlineVerdictArg = @($noticeArgs | Where-Object {
    @($_.FindAll({
        param($b) $b -is [System.Management.Automation.Language.CommandAst] -and [string]$b.GetCommandName() -match '(^|\\)Get-ExeDirVerdict$'
      }, $true)).Count -ge 1
  }).Count -ge 1
$verdictAssigns = @($fn.FindAll({
    param($a)
    $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $a.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
    @($a.Right.FindAll({
        param($b) $b -is [System.Management.Automation.Language.CommandAst] -and [string]$b.GetCommandName() -match '(^|\\)Get-ExeDirVerdict$'
      }, $true)).Count -ge 1
  }, $true))
$verdictVars = @($verdictAssigns | ForEach-Object { $_.Left.VariablePath.UserPath })
Assert (($verdictVars.Count -ge 1) -or $inlineVerdictArg) '函数体内必须让 Get-ExeDirVerdict 的结果进到文案函数（赋给变量或内联），否则提示与判定脱钩'
Assert ($inlineVerdictArg -or (@($noticeArgVars | Where-Object { $verdictVars -contains $_ }).Count -ge 1)) "Get-AddPreflightNotice 的判定参数必须来自判定函数的返回值，实际参数=$($noticeArgVars -join ',')、判定变量=$($verdictVars -join ',')、内联=$inlineVerdictArg"

# 5c. notice 必须被写出：写恒空字符串或写别的字面量都不算提示送到用户。
$noticeWrites = @($fn.FindAll({
    param($a)
    $a -is [System.Management.Automation.Language.CommandAst] -and
    ([string]$a.GetCommandName() -match '^Write-(Host|Output|Warning|Information)$') -and
    @($a.CommandElements | Select-Object -Skip 1 |
      Where-Object { $_ -is [System.Management.Automation.Language.VariableExpressionAst] -and $_.VariablePath.UserPath -eq 'notice' }).Count -ge 1
  }, $true))
Assert ($noticeWrites.Count -ge 1) '函数体内必须把 $notice 写出去（Write-Host $notice 或等价分支），否则提示到不了用户'

# ---- 5d. 降级路径的独立证据：只点源 add-svc.ps1（无 security-check）不抛，且必须提示「不等于安全」 ----
# 用子进程隔离：本测试进程已点源 lib/security-check.ps1，守卫在那里恒真，测不到降级。
$probeCmd = "& { . '" + $cliPath + "'; if (Get-Command Get-ExeDirVerdict -EA SilentlyContinue) { 'hasVerdict=yes' } else { 'hasVerdict=no' }; 'notice=' + (Get-AddPreflightNotice 'C:\x\svc.exe' '未知（判据未加载）') }"
$degraded = @(& pwsh -NoProfile -Command $probeCmd)
$probeRc = $LASTEXITCODE
$degradedText = $degraded -join "`n"
Assert ($probeRc -eq 0) "只点源 add-svc.ps1 的子进程必须正常退出（不得 CommandNotFoundException），实际 exit=$probeRc 输出=$degradedText"
Assert ($degradedText -match '(?m)^hasVerdict=no\r?$') "子进程里不应加载到 Get-ExeDirVerdict，否则降级路径没被测到，实际 $degradedText"
$degradedNotice = @($degraded | Where-Object { $_ -like 'notice=*' })
Assert ($degradedNotice.Count -eq 1) "降级路径必须给出提示行，实际 $degradedText"
Assert ($degradedNotice[0].Length -gt 'notice='.Length) "降级提示不能为空，实际「$($degradedNotice[0])」"
Assert ($degradedNotice[0] -match '不等于安全') "降级提示必须声明「不等于安全」，实际「$($degradedNotice[0])」"

Write-Output 'PASS: ACL 三态唯一实现在 Get-DirAclVerdict（未解析/不存在/读不到都带原因），汇总层给对象化未知名，入口与对话框都走这一份；CLI 的判定调用在 Add-SvcFromCli 体内、notice 由判定派生且写出，判据未加载时降级仍提示「不等于安全」。'
