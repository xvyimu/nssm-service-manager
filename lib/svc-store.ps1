# lib/svc-store.ps1 — services.json 读写（SSOT）：解析、原子写回、外部修改检测、重载、新增条目
#
# 由 lib/util.ps1 聚合加载；函数体直接读调用方作用域的 $cfg（见 util.ps1 文件头）。
# 写回约定：copy-on-write + mtime 门闩 + 解析失败拒写，三条缺一就会把用户的配置覆盖掉。

# ---- 配置层（services.json 是 SSOT，services.example.json 是兜底）----
# 兜底读示例清单，不在源码里抄服务名；不要在此初始化 $script:configWarning（会清掉 config.ps1 写入的原因）。

function Read-SvcFile([string]$path){
  # 可选字段写错的收集箱。不能抛：抛会让 Load-Svc 落到 catch，整份清单退回示例并被 Save-Svc 写回。§Read-SvcFile
  $script:svcFieldWarnings = @()
  $j = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
  # 顶层形状必须校验：`[]` / `"x"` 是合法 JSON 但取不到 .Keys，旧代码返回空清单且当成功，
  # 之后一次保存就把原文件整份覆盖成 `{}`（svcLoadFailed 那条门闩只管「解析失败」）。§Read-SvcFile
  if ($j -isnot [System.Collections.IDictionary]) {
    # 顶层是 JSON null 时 $j 为 $null，直接取 .GetType() 会二次抛空引用——用户就看不到这句原因了
    $kind = if ($null -eq $j) { 'null' } else { $j.GetType().Name }
    throw "顶层必须是对象（服务名 → {port,url[,probe,...]}），实际是 $kind"
  }
  $o = [ordered]@{}; foreach ($k in $j.Keys) {
    # 服务值必须是对象：`"X": 123` / `"X": null` 取不到 .Keys，会静默丢一整条
    if ($null -eq $j[$k] -or $j[$k] -isnot [System.Collections.IDictionary]) {
      $kind = if ($null -eq $j[$k]) { 'null' } else { $j[$k].GetType().Name }
      $script:svcFieldWarnings += "$k 的值必须是对象（{port,url,...}），实际是 $kind，已跳过"
      continue
    }
    $u = [string]$j[$k].url
    # 探测口径先解析，port 校验依赖它：probe=none（rclone mount、纯守护进程）端口无意义，
    # 写 0 / 乱写都不该报警——否则每次启动都弹一条「端口非法」。
    # auto（默认，TCP 通后还要求 HTTP 200）/ tcp（TCP 通即正常）：非 HTTP 服务必须写 tcp，
    # 否则 HTTP 探测必然失败、卡片永远不是绿点。§Read-SvcFile
    $actualProbe = @($j[$k].Keys | Where-Object { $_ -ieq 'probe' }) | Select-Object -First 1
    $probe = 'auto'; $entryProbe = $null
    if ($actualProbe) {
      $rawProbe = [string]$j[$k][$actualProbe]
      $pv = $rawProbe.Trim().ToLowerInvariant()
      if ($pv -in @('auto','tcp','http','none')) { $probe = $pv; $entryProbe = $pv }
      else { $script:svcFieldWarnings += "$k 的 probe 无效（$rawProbe），已回落 auto（TCP 通且 HTTP 200）" }
    }
    # port 可选：缺 port 不再整份抛错——一条配错不该让其它服务一起退回示例清单。§Read-SvcFile
    $hasPort = @($j[$k].Keys | Where-Object { $_ -ieq 'port' }).Count -gt 0
    $p = 0
    if ($hasPort) {
      $parsed = 0
      # 合法端口一律保留（哪怕 probe=none，之后改探测口径还认得原端口）；非法值只在需要端口时提示。
      if ([int]::TryParse([string]$j[$k].port, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 65535) {
        $p = $parsed
      } elseif ($probe -ne 'none') {
        $script:svcFieldWarnings += "$k 端口非法（$($j[$k].port)），按无端口处理"
      }
    } elseif ($probe -ne 'none') {
      $script:svcFieldWarnings += "$k 未配置 port 且未声明 probe=none，健康探测会恒失败"
    }
    $entry = @{ port = $p; url = $u }
    if ($null -ne $entryProbe) { $entry['probe'] = $entryProbe }
    # 可选 per-service 超时覆盖（toggleTimeoutMs/httpTimeoutMs/tcpTimeoutMs），缺省回落全局。
    # **必须显式带走**：Save-Svc 写整份 $script:svc，只挑 port/url 会让用户的覆盖被静默抹掉。
    foreach ($opt in 'toggleTimeoutMs','httpTimeoutMs','tcpTimeoutMs') {
      # **不能用 ContainsKey**：-AsHashtable 返回的 OrderedHashtable 键大小写敏感，按 -ieq 找实际键名。§Read-SvcFile
      $actual = @($j[$k].Keys | Where-Object { $_ -ieq $opt }) | Select-Object -First 1
      if (-not $actual) { continue }
      $raw = $j[$k][$actual]
      $v = 0
      if (-not [int]::TryParse([string]$raw, [ref]$v) -or $v -le 0) {
        # 写错/写 0 只让该字段不生效（回落全局），服务本身照常保留；原因记进收集箱弹给用户。
        $script:svcFieldWarnings += "$k 的 $opt 无效（$raw），已回落全局值"
        continue
      }
      $entry[$opt] = $v
    }
    # 白名单外的键会被 Save-Svc 的全量写回静默抹掉——记一条提示。
    # 用户把字段名打错一个字母时，原来的表现是「配了但没生效」，且连提示都没有。
    $known = @('port','url','probe','toggleTimeoutMs','httpTimeoutMs','tcpTimeoutMs')
    foreach ($key in $j[$k].Keys) {
      if (-not @($known | Where-Object { $_ -ieq $key }).Count) {
        $script:svcFieldWarnings += "$k 的字段 $key 不被识别，保存时会被丢弃"
      }
    }
    $o[$k] = $entry
  }
  $o
}

# 载入服务清单：优先 services.json；缺失或解析失败时回落 services.example.json，
# 同时置 svcLoadFailed=true，让 Save-Svc 拒绝把示例清单写回真实文件。
function Load-Svc {
  # 专用标志：configWarning 只由「services.json 解析失败」写，调用方据它判定「是否回落成示例」。§Load-Svc
  $script:svcLoadFailed = $false
  if (Test-Path $cfg) {
    try {
      $loaded = Read-SvcFile $cfg
      # 可选字段写错只攒提示，不弹「使用恢复配置」那种框。
      foreach ($w in $script:svcFieldWarnings) { Add-ConfigNotice "services.json：$w" }
      # 记下 mtime：Save-Svc 写前比对，挡住「手改后 GUI 全量写回」的覆盖。§Save-Svc
      $script:svcFileStamp = (Get-Item -LiteralPath $cfg).LastWriteTimeUtc.Ticks
      $script:svcFileHintShown = $false
      return $loaded
    }
    # 消息自带文件名：调用方无从判断来源，由写入方讲清。§Load-Svc
    catch {
      $script:configWarning = "services.json 无效：$($_.Exception.Message)"
      $script:svcLoadFailed = $true
    }
  } else {
    # 首次运行/文件被移走：没有清单就没有可管的服务，留一句免得用户以为「服务全丢了」。
    Add-ConfigNotice "services.json 不存在（$cfg），当前显示示例清单；保存会把示例条目写进去"
  }
  # 兜底：services.json 缺失或损坏时读示例清单，让首次运行有内容可看
  $example = Join-Path (Split-Path $cfg -Parent) 'services.example.json'
  if (Test-Path $example) {
    try { return Read-SvcFile $example }
    catch { if (-not $script:configWarning) { $script:configWarning = "services.example.json 无效：$($_.Exception.Message)" } }
  }
  [ordered]@{}
}

# 原子写回：$PID.$guid.tmp → Replace，避免停电留下半截 JSON。§Save-Svc
function Save-Svc($s) {
  # 清单解析失败时 $script:svc 是示例清单（Load-Svc 回落的结果），写回会覆盖真实配置。
  if ($script:svcLoadFailed) { throw 'services.json 未能解析，已拒绝写入（请先修复该文件）' }
  # 外部修改检测：载入时记下 mtime，写前再取一次。GUI 常驻期间有人手改（或另一个会话抢先写），
  # 全量写回会把对方改动整份抹掉——拒绝写，让用户先按 F5 重载再改。§Save-Svc
  if (Test-Path -LiteralPath $cfg) {
    $nowStamp = (Get-Item -LiteralPath $cfg).LastWriteTimeUtc.Ticks
    if ($script:svcFileStamp -and $nowStamp -ne $script:svcFileStamp) {
      throw 'services.json 在载入后被外部修改，已拒绝写入（GUI 按 F5 重载后再试）'
    }
  }
  $json  = $s | ConvertTo-Json -Depth 5
  $tmp   = "$cfg.$PID.$([guid]::NewGuid()).tmp"
  [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
  try {
    if (Test-Path -LiteralPath $cfg) {
      # 目标被用户或备份工具标成只读时，File.Replace 报「无法删除要被替换的文件」，错误里没有
      # 任何「只读」线索。这就是我们自己的配置文件，写前清属性；清不掉再翻译成一句人话。§Save-Svc
      $target = Get-Item -LiteralPath $cfg -Force
      if ($target.IsReadOnly) {
        try { $target.IsReadOnly = $false } catch {}
        if ((Get-Item -LiteralPath $cfg -Force).IsReadOnly) { throw "services.json 是只读的：$cfg（去掉只读属性后重试）" }
      }
      # 第三参给备份路径：Replace 顺手把上一版留成 services.json.bak（清单不在 git 里，没有这层就无回滚）。
      # .bak 是自己上一版，被标只读时 File.Replace 会直接失败（「无法删除要被替换的文件」）——先清属性。
      $bak = "$cfg.bak"
      if (Test-Path -LiteralPath $bak) { try { (Get-Item -LiteralPath $bak).IsReadOnly = $false } catch {} }
      [IO.File]::Replace($tmp, $cfg, $bak)
    } else { [IO.File]::Move($tmp, $cfg) }
  } finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue }
  }
  # 自己写完同步刷新，否则下一次保存会被自己的 mtime 判成「外部修改」。
  $script:svcFileStamp = (Get-Item -LiteralPath $cfg).LastWriteTimeUtc.Ticks
  $script:svcFileHintShown = $false
}

# 重试保存清单：把「待保存」的删除重新落盘。状态栏菜单与卡片右键共用这一份，
# 免得两处各写一套后在「谁该被移除」上漂移。§Invoke-RetrySaveSvc
function Invoke-RetrySaveSvc([string]$name){
  $pending = @($script:cards.Values | Where-Object { $_.PendingSave } | ForEach-Object { $_.SvcName })
  if (-not $pending.Count) { Set-StatusMessage '没有待保存的清单变更'; return }
  $next = [ordered]@{}
  foreach ($k in $script:svc.Keys) { if ($k -notin $pending) { $next[$k] = $script:svc[$k] } }
  try { Save-Svc $next }
  catch { Set-StatusMessage "清单保存失败：$($_.Exception.Message)"; return }
  [Threading.Monitor]::Enter($script:sync.gate)
  try { foreach ($k in $pending) { [void]$script:svc.Remove($k) } } finally { [Threading.Monitor]::Exit($script:sync.gate) }
  foreach ($k in $pending) {
    $script:cards.Remove($k)
    if ($script:healthSeen) { $script:healthSeen.Remove($k) }
    if ($script:svcState) { $script:svcState.Remove($k) }
  }
  if (Get-Command Render-Page -EA SilentlyContinue) { Render-Page }
  Set-StatusMessage "已保存清单：$($pending.Count) 项删除已落盘"
}

# 清单是否被外部改过（GUI 常驻时手改、或另一个会话抢先写）：只做一次 stat，不读文件。
# Save-Svc 自己写完会刷新 stamp 并清提示标记，所以自己的保存不会触发。§Test-SvcFileChanged
function Test-SvcFileChanged {
  if (-not $script:svcFileStamp -or $script:svcFileHintShown) { return $false }
  try {
    if (-not (Test-Path -LiteralPath $cfg)) { return $false }
    if ((Get-Item -LiteralPath $cfg).LastWriteTimeUtc.Ticks -ne $script:svcFileStamp) {
      $script:svcFileHintShown = $true
      return $true
    }
  } catch {}
  $false
}

# F5 重新加载清单：保留卡片缓存（不丢健康值、冷却、过渡态），只增删差异卡片。
# 返回 $null 成功，否则一句原因（调用方塞状态栏）。§Invoke-SvcReload
function Invoke-SvcReload {
  # 有在途命令时拒绝：卡片被重建/丢弃后回执会落在不存在的卡上，而删除成功路径还会把旧内存
  # 清单写回磁盘（$script:svc.Remove + Save-Svc）。
  foreach ($c in @($script:cards.Values)) {
    if ($c.ST -in $script:TRANSITION_STATES) {
      return "$($c.SvcName) 正在切换中，稍后重载"
    }
  }
  $script:svcLoadFailed = $false
  $script:configWarning = $null
  $script:configNotices = @()   # 重载重算提示，否则托盘长驻期间每次 F5 都会追加一批
  $new = Load-Svc
  if ($script:svcLoadFailed) { return 'services.json 解析失败，未重载（原清单保持不变）' }
  $script:svc = $new
  # 后台每轮重读 $sync.svc；换了对象必须同步这个键，否则探测的还是旧清单。
  if ($script:sync) { $script:sync.svc = $script:svc }
  foreach ($n in @($script:cards.Keys)) {
    if (-not $script:svc.Contains($n)) { $script:cards.Remove($n) }
  }
  $script:curPage = 0
  $script:svcFileHintShown = $false
  Render-Page
  $null
}

# 写进内存清单并落盘，CLI 与对话框共用。返回 $null 成功，否则错误信息。
# copy-on-write：先写副本，Save-Svc 成功后才替换 $script:svc。原来先改内存再保存，保存抛错时那条
# 没落盘的服务仍留在内存里——下一次任意保存（比如删掉别的服务）会把它写进磁盘，用户以为没加成。§Add-SvcEntry
function Add-SvcEntry([string]$n,[int]$p,[string]$url,[string]$probe){
  $entry = @{ port = $p; url = $url }
  # probe 只在非默认口径时落盘：auto（TCP 通且 HTTP 200）是缺省，写出来只是噪声。§Read-SvcFile
  $pv = ([string]$probe).Trim().ToLowerInvariant()
  if ($pv -in @('tcp','http','none')) { $entry['probe'] = $pv }
  $next = [ordered]@{}
  [Threading.Monitor]::Enter($sync.gate)
  try {
    foreach ($k in $script:svc.Keys) { $next[$k] = $script:svc[$k] }
    $next[$n] = $entry
  } finally { [Threading.Monitor]::Exit($sync.gate) }
  try { Save-Svc $next } catch { return $_.Exception.Message }
  [Threading.Monitor]::Enter($sync.gate)
  try {
    $script:svc = $next
    # 后台每轮重读 $sync.svc；换了对象必须同步这个键，否则探测的还是旧清单（同 Invoke-SvcReload）。
    if ($script:sync) { $script:sync.svc = $script:svc }
  } finally { [Threading.Monitor]::Exit($sync.gate) }
  $null
}
