#requires -Version 7.0
# companions：随主服务一起启停的伴随服务（例：ARTEX ← PostgreSQL-ARTEX）。
# 口径：伴随服务不出卡片；级联在后台执行器里做（lib/svc-common.ps1 + lib/poll.ps1），
# UI 只下发主服务一条命令；清单写错只丢该条不毁整份。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Xaml
foreach ($module in 'theme','util','card','xaml','dialogs') { . (Join-Path $RepoRoot "lib/$module.ps1") }
# 级联执行器在 svc-common.ps1：生产里由 poll.ps1 把该文件文本前置进 runspace，测试里直接点源。
. (Join-Path $RepoRoot 'lib/svc-common.ps1')
. (Join-Path $PSScriptRoot 'test-helpers.ps1')

# 批量停止的确认框在无头进程里会真弹并卡死；本用例验的是入队，不是对话框。
function Confirm-BatchStop { $true }

$script:sync = @{ wake = [Threading.AutoResetEvent]::new($false) }

$dir = New-TestTempDir 'sm-companions'
$cfg = Join-Path $dir 'services.json'
$utf8 = [Text.UTF8Encoding]::new($false)
function Write-Cfg([string]$text) { [IO.File]::WriteAllText($cfg, $text, $utf8) }

$win = New-MainWindow
try {
  # ---- 1. 解析与校验 ----
  Write-Cfg '{"ARTEX":{"port":18787,"url":"","companions":["PostgreSQL-ARTEX"]},"PostgreSQL-ARTEX":{"port":5432,"probe":"tcp"}}'
  $svc = Read-SvcFile $cfg
  Assert ((@($svc['ARTEX']['companions']) -join ',') -eq 'PostgreSQL-ARTEX') 'companions 应解析成数组'

  # 单个字符串也接受；大小写不同要归一成清单里的真实键名
  Write-Cfg '{"ARTEX":{"port":18787,"url":"","Companions":"postgresql-artex"},"PostgreSQL-ARTEX":{"port":5432,"probe":"tcp"}}'
  $svc = Read-SvcFile $cfg
  Assert ((@($svc['ARTEX']['companions']) -join ',') -eq 'PostgreSQL-ARTEX') '单个字符串应支持，且归一成真实键名'

  # 指向不存在的服务 → 丢这条并提示，主服务本身保留
  Write-Cfg '{"ARTEX":{"port":18787,"url":"","companions":["NoSuchSvc"]},"PostgreSQL-ARTEX":{"port":5432,"probe":"tcp"}}'
  $svc = Read-SvcFile $cfg
  Assert (-not $svc['ARTEX'].Contains('companions')) '不存在的伴随服务应被丢弃'
  Assert (@($script:svcFieldWarnings | Where-Object { $_ -match 'NoSuchSvc' }).Count -eq 1) '不存在的伴随服务应有一条提示'

  # 一个伴随服务只能被一个主服务认领
  Write-Cfg '{"A":{"port":1,"url":"","companions":["PG"]},"B":{"port":2,"url":"","companions":["PG"]},"PG":{"port":5432,"probe":"tcp"}}'
  $svc = Read-SvcFile $cfg
  Assert ((@($svc['A']['companions']) -join ',') -eq 'PG' -and -not $svc['B'].Contains('companions')) '第二个认领者应被丢弃'
  Assert (@($script:svcFieldWarnings | Where-Object { $_ -match '已经是' }).Count -eq 1) '重复认领应有一条提示'

  # 不支持嵌套：伴随服务自己再带 companions 时整条丢弃
  Write-Cfg '{"A":{"port":1,"url":"","companions":["B"]},"B":{"port":2,"url":"","companions":["C"]},"C":{"port":3,"url":""}}'
  $svc = Read-SvcFile $cfg
  Assert (-not $svc['A'].Contains('companions')) '嵌套的伴随关系应被拒绝'
  Assert (@($script:svcFieldWarnings | Where-Object { $_ -match '嵌套' }).Count -eq 1) '嵌套拒绝要留一条提示（静默丢弃也能过）'

  # 指向自己
  Write-Cfg '{"A":{"port":1,"url":"","companions":["a"]}}'
  $svc = Read-SvcFile $cfg
  Assert (-not $svc['A'].Contains('companions')) '自己不能是自己的伴随服务'
  Assert (@($script:svcFieldWarnings | Where-Object { $_ -match '自己' }).Count -eq 1) '自引用拒绝要留一条提示'

  # 互相认领：结果不能取决于 JSON 键序（旧实现边循环边改清单，会塌缩成一个方向）
  Write-Cfg '{"A":{"port":1,"url":"","companions":["B"]},"B":{"port":2,"url":"","companions":["A"]}}'
  $svcAB = Read-SvcFile $cfg
  Write-Cfg '{"B":{"port":2,"url":"","companions":["A"]},"A":{"port":1,"url":"","companions":["B"]}}'
  $svcBA = Read-SvcFile $cfg
  Assert (-not $svcAB['A'].Contains('companions') -and -not $svcAB['B'].Contains('companions')) '互相认领两边都该丢弃（A 在前）'
  Assert (-not $svcBA['A'].Contains('companions') -and -not $svcBA['B'].Contains('companions')) '互相认领两边都该丢弃（B 在前）'

  # 落盘往返：Save-Svc 全量写回不能把 companions 抹掉（白名单 + 整条拷贝）
  Write-Cfg '{"ARTEX":{"port":18787,"url":"","companions":["PostgreSQL-ARTEX"]},"PostgreSQL-ARTEX":{"port":5432,"probe":"tcp"}}'
  $script:svc = Read-SvcFile $cfg
  Save-Svc $script:svc
  $round = Read-SvcFile $cfg
  Assert ((@($round['ARTEX']['companions']) -join ',') -eq 'PostgreSQL-ARTEX') "保存往返后 companions 应保留：$(($round['ARTEX']['companions'] -join ',') -replace '^$','<空>')"

  # ---- 2. 伴随服务不出卡片 ----
  Write-Cfg '{"ARTEX":{"port":18787,"url":"","companions":["PostgreSQL-ARTEX"]},"PostgreSQL-ARTEX":{"port":5432,"probe":"tcp"},"Other":{"port":9000,"url":""}}'
  $script:svc = Read-SvcFile $cfg
  $script:svcState = [hashtable]::Synchronized(@{})
  $script:sync = @{ wake = $script:sync.wake; gate = [object]::new(); svc = $script:svc; stop = $true }
  $script:cmdQueue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
  $script:cmdEpoch = 0
  $script:cards = @{}
  $script:curPage = 0
  Render-Page
  Assert ((@(Get-SvcNames) -join ',') -eq 'ARTEX,Other') "Get-SvcNames 应隐藏伴随服务：$((@(Get-SvcNames)) -join ',')"
  Assert ($script:cards.Count -eq 2 -and -not $script:cards.ContainsKey('PostgreSQL-ARTEX')) '伴随服务不该有自己的卡片'
  Assert ($script:serviceSummary.Text -eq '2 个本地服务') "状态栏计数应只算卡片：$($script:serviceSummary.Text)"
  Assert ((Get-SvcCompanionOwner 'PostgreSQL-ARTEX') -eq 'ARTEX') '伴随服务应能找到它的主服务'
  Assert ((Get-SvcCompanionOwner 'ARTEX') -eq '') '主服务本身不该有主服务'

  # ---- 3. 级联执行器（后台）：顺序、失败收集、无伴随时零调用 ----
  $cascadeSvc = [ordered]@{
    ARTEX = @{ port = 1; url = ''; companions = @('PG1', 'PG2') }
    PG1   = @{ port = 2; url = '' }
    PG2   = @{ port = 3; url = '' }
    Plain = @{ port = 4; url = '' }
  }
  $script:log = @()
  $failed = @(Invoke-CompanionStart 'ARTEX' $cascadeSvc $null { param($c) $script:log += "start:$c"; $c -ne 'PG2' })
  Assert (($script:log -join ',') -eq 'start:PG1,start:PG2') "启动应先起伴随：$($script:log -join ',')"
  Assert (($failed -join ',') -eq 'PG2') "失败的伴随应被收集：$($failed -join ',')"

  $script:log = @()
  $failed = @(Invoke-CompanionStop 'ARTEX' $cascadeSvc $null { param($c) $script:log += "stop:$c"; $true })
  Assert (($script:log -join ',') -eq 'stop:PG1,stop:PG2') "停止应逐个撤伴随：$($script:log -join ',')"
  Assert ($failed.Count -eq 0) '全部成功时不该有失败项'

  $script:log = @()
  $failed = @(Invoke-CompanionStart 'Plain' $cascadeSvc $null { param($c) $script:log += "start:$c"; $true })
  Assert ($script:log.Count -eq 0 -and $failed.Count -eq 0) '没有伴随时不该调用执行器'

  # 后台分支真的接了级联（纯函数测通不代表接线接上了；这里按源码锚点钉住两条不变式）
  $pollSrc = Get-SourceCodeOnly (Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'lib/poll.ps1'))
  Assert ($pollSrc -match "'start'\s*\{[\s\S]*?Invoke-CompanionStart") "start 分支应调用级联：$($pollSrc.Length) 字符里没找到"
  Assert ($pollSrc -match "'stop'[\s\S]*?if \(\`$ok\)[\s\S]{0,500}Invoke-CompanionStop") '只有主服务停成功（$ok）才允许撤伴随'

  # ---- 4. 副标题点出伴随服务状态（它没有自己的卡片，这是唯一入口）----
  $card = $script:cards['ARTEX']
  $script:cards = @{ ARTEX = $card }
  $script:svcState['ARTEX'] = @{ st = '运行中'; at = [datetime]::Now }
  $script:svcState['PostgreSQL-ARTEX'] = @{ st = '已停止'; at = [datetime]::Now }
  $card.ST = '运行中'; $card.TransitionAt = [datetime]::MinValue; $card.PendingEpoch = 0
  Update-CardData 'ARTEX' '运行中' '正常'
  Assert ($card.LblUpBase -match '伴随 PostgreSQL-ARTEX 已停止') "伴随异常应在副标题点名：$($card.LblUpBase)"
  $script:svcState['PostgreSQL-ARTEX'] = @{ st = '运行中'; at = [datetime]::Now }
  Update-CardData 'ARTEX' '运行中' '正常'
  Assert ($card.LblUpBase -notmatch '伴随') "伴随正常时副标题不该加字：$($card.LblUpBase)"

  # 过渡态不是结论：伴随/主服务处于过渡态时，正常时序不能被点成故障
  $script:svcState['PostgreSQL-ARTEX'] = @{ st = '启动中'; at = [datetime]::Now }
  Update-CardData 'ARTEX' '运行中' '正常'
  Assert ($card.LblUpBase -notmatch '伴随') "伴随处于过渡态时不该点名：$($card.LblUpBase)"
  $script:svcState['PostgreSQL-ARTEX'] = @{ st = '运行中'; at = [datetime]::Now }
  Update-CardData 'ARTEX' '启动中' ''
  Assert ($card.LblUpBase -notmatch '伴随') "主服务过渡态时不该点名：$($card.LblUpBase)"

  # ---- 5. 批量：只下发主服务（级联在后台），孤儿伴随按主服务真实状态放行 ----
  $script:svcState['ARTEX'] = @{ st = '已停止'; at = [datetime]::Now }
  $script:svcState['PostgreSQL-ARTEX'] = @{ st = '已停止'; at = [datetime]::Now }
  $script:svcState['Other'] = @{ st = '已停止'; at = [datetime]::Now }
  [void](Invoke-BatchCommand 'start')
  $q = @(); $item = $null
  while ($script:cmdQueue.TryDequeue([ref]$item)) { $q += "$($item.act):$($item.n)" }
  Assert (($q -join ',') -eq 'start:ARTEX,start:Other') "批量启动只下发主服务，不重复下发伴随：$($q -join ',')"

  # 主服务已停、伴随还在跑 → 孤儿，必须能单独停掉
  $script:svcState['ARTEX'] = @{ st = '已停止'; at = [datetime]::Now }
  $script:svcState['PostgreSQL-ARTEX'] = @{ st = '运行中'; at = [datetime]::Now }
  $script:svcState['Other'] = @{ st = '已停止'; at = [datetime]::Now }
  [void](Invoke-BatchCommand 'stop')
  $q = @()
  while ($script:cmdQueue.TryDequeue([ref]$item)) { $q += "$($item.act):$($item.n)" }
  Assert (($q -join ',') -eq 'stop:PostgreSQL-ARTEX') "孤儿的伴随服务应被单独停掉：$($q -join ',')"

  # 主服务还在启动中 → 不是孤儿：此时停伴随等于把正在起来的服务脚下抽走
  $script:svcState['ARTEX'] = @{ st = '启动中'; at = [datetime]::Now }
  $script:svcState['PostgreSQL-ARTEX'] = @{ st = '运行中'; at = [datetime]::Now }
  $script:svcState['Other'] = @{ st = '已停止'; at = [datetime]::Now }
  $msg = Invoke-BatchCommand 'stop'
  Assert ($script:cmdQueue.IsEmpty) "主服务启动中时不该停它的伴随：$msg"

  Write-Output 'PASS: companions parse (array/single/case), reject unknown/duplicate/nested/self with warnings; hidden from cards and counts; owner lookup; background cascade order and failure collection; batch sends mains only and only stops an orphan companion whose owner is freshly stopped; subtitle names a mismatched companion.'
} finally {
  $win.Close()
  $script:sync.wake.Dispose()
  Remove-Item -LiteralPath $dir -Recurse -Force -EA SilentlyContinue
}
