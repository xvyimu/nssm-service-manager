#requires -Version 7.0
# 回归：无端口服务（probe=none）与「服务已停止但端口仍被占用」两条路径。
#   - 缺 port 不再让整份 services.json 退回示例清单，只降级该条＋留提示；
#   - poll.ps1 对已停止服务做轻量 TCP 探，命中即报「端口被占用」；
#   - card.ps1 把这条提示渲染成副标题，而不是继续说「随时可以启动」。
param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'lib/config.ps1')
. (Join-Path $RepoRoot 'lib/util.ps1')
. (Join-Path $PSScriptRoot 'test-helpers.ps1')

$tmp = Join-Path ([IO.Path]::GetTempPath()) "sm-probe-none-$([guid]::NewGuid().ToString('N')).json"
try {
  # 1. probe=none 的无端口服务正常加载，不产生警告
  [IO.File]::WriteAllText($tmp,
    '{"Mount":{"probe":"none"},"Web":{"port":5244,"url":"http://127.0.0.1:5244"}}',
    [Text.UTF8Encoding]::new($false))
  $parsed = Read-SvcFile $tmp
  Assert ($parsed['Mount'].port -eq 0) 'probe=none 的服务 port 应为 0'
  Assert ($parsed['Mount'].probe -eq 'none') 'probe=none 未被保留'
  Assert ($parsed['Web'].port -eq 5244) '相邻正常服务被误伤'
  Assert (@($script:svcFieldWarnings).Count -eq 0) "probe=none 不该产生警告：$($script:svcFieldWarnings -join ';')"

  # 2. 缺 port 且没声明 probe=none：照常加载，但留一条提示
  [IO.File]::WriteAllText($tmp, '{"NoPort":{"url":"http://127.0.0.1:9"}}', [Text.UTF8Encoding]::new($false))
  $parsed2 = Read-SvcFile $tmp
  Assert ($parsed2['NoPort'].port -eq 0) '缺 port 应降级为 0'
  Assert (@($script:svcFieldWarnings).Count -ge 1) '缺 port 应留下一条提示'

  # 3. 端口非法（0 / 超范围 / 非数字）只降级该条
  [IO.File]::WriteAllText($tmp, '{"Bad":{"port":"abc"},"Good":{"port":8080}}', [Text.UTF8Encoding]::new($false))
  $parsed3 = Read-SvcFile $tmp
  Assert ($parsed3['Bad'].port -eq 0) '非法端口应降级为 0'
  Assert ($parsed3['Good'].port -eq 8080) '非法端口不该让整份清单失效'
  Assert (@($script:svcFieldWarnings).Count -ge 1) '非法端口应留下一条提示'

  # 2b. 服务值不是对象（数字/null/字符串）：跳过该条 + 提示，不影响其它
  [IO.File]::WriteAllText($tmp, '{"Num":123,"Nul":null,"Good":{"port":8080}}', [Text.UTF8Encoding]::new($false))
  $parsed4 = Read-SvcFile $tmp
  Assert ($null -eq $parsed4['Num'] -and $null -eq $parsed4['Nul']) '非对象值应被跳过'
  Assert ($parsed4['Good'].port -eq 8080) '非对象值不该让整份清单失效'
  Assert (@($script:svcFieldWarnings).Count -ge 2) '非对象值应逐条提示'

  # 3b. probe=none 时端口无意义：写 0 / 乱写不报警，合法端口原样保留（改探测口径后还认得原端口）
  [IO.File]::WriteAllText($tmp,
    '{"Zero":{"probe":"none","port":0},"Junk":{"probe":"none","port":"abc"},"Keep":{"probe":"none","port":5244}}',
    [Text.UTF8Encoding]::new($false))
  $parsed5 = Read-SvcFile $tmp
  Assert ($parsed5['Zero'].port -eq 0 -and $parsed5['Junk'].port -eq 0) 'probe=none 的非法端口应静默归零'
  Assert ($parsed5['Keep'].port -eq 5244) 'probe=none 的合法端口应保留'
  Assert (@($script:svcFieldWarnings).Count -eq 0) "probe=none 的端口字段不该报警：$($script:svcFieldWarnings -join ';')"

  # 3c. probe 大小写/空白归一化后仍是 none
  [IO.File]::WriteAllText($tmp, '{"Trim":{"probe":" NONE ","port":0}}', [Text.UTF8Encoding]::new($false))
  $parsed6 = Read-SvcFile $tmp
  Assert ($parsed6['Trim'].probe -eq 'none') 'probe 应归一化为 none'
  Assert ($parsed6['Trim'].port -eq 0 -and @($script:svcFieldWarnings).Count -eq 0) '归一化后仍不该因端口报警'
} finally {
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
}

# 4. 静态扫描：poll.ps1 的两条新分支必须在位（并行块跑在独立 runspace，单测成本高）
# 去掉整行注释再断言，避免「注释里写了同一句」造成假绿。
function Get-CodeOnly([string]$path) {
  (Get-Content -LiteralPath $path | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n"
}
$poll = Get-CodeOnly (Join-Path $RepoRoot 'lib/poll.ps1')
Assert ($poll -match "probe -eq 'none'") 'poll.ps1 缺少 probe=none 分支'
Assert ($poll -match 'stopped=\$true') 'poll.ps1 缺少已停止服务的探测标记'
Assert ($poll -match '端口被占用') 'poll.ps1 缺少端口占用文案'
Assert ($poll -match '\$r\.stopped') 'poll.ps1 结果处理未区分 stopped'
Assert ($poll -match 'if \(\$p\.stopped\) \{ continue \}') 'poll.ps1 跳过轮未排除 stopped 条目'
Assert ($poll -match '\$activeProbe') 'poll.ps1 的空闲间隔仍被 stopped 条目拉高'

# 5. 静态扫描：卡片要能显示这条提示
$card = Get-CodeOnly (Join-Path $RepoRoot 'lib/card.ps1')
Assert ($card -match '端口被其它进程占用') 'card.ps1 缺少端口占用副标题'

Write-Output 'PASS: probe=none 无端口服务、非法端口降级、已停止服务的端口占用提示三处行为与静态分支。'
