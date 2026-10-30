# lib/util.ps1 — 配置持久化（services.json）· UI 工具 · 日志轮转保留 · 安全检查
#
# 函数体直接读调用方作用域的 $cfg / $logDir；参数不得同名，大小写不敏感会遮蔽外层变量。
# 实现细节：docs/IMPLEMENTATION-NOTES.md

# 健康历史是纯函数族，Update-StatusTick 依赖它；单独 dot-source util 的脚本（含单测）也要能用。
if (-not (Get-Command Test-HealthChanged -EA SilentlyContinue)) { . (Join-Path $PSScriptRoot 'health.ps1') }

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
    $p = [int]$j[$k].port; $u = [string]$j[$k].url
    if ($p -lt 1 -or $p -gt 65535) { throw "$k 端口非法: $p" }
    $entry = @{ port = $p; url = $u }
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
    # 探测口径：auto（默认，TCP 通后还要求 HTTP 200）/ tcp（TCP 通即正常）。
    # 非 HTTP 服务（数据库、gRPC、纯 socket 守护）必须写 tcp：HTTP 探测对它必然失败，
    # 卡片会永远不是绿点。§Read-SvcFile
    $actualProbe = @($j[$k].Keys | Where-Object { $_ -ieq 'probe' }) | Select-Object -First 1
    if ($actualProbe) {
      $rawProbe = [string]$j[$k][$actualProbe]
      $pv = $rawProbe.Trim().ToLowerInvariant()
      if ($pv -in @('auto','tcp','http')) { $entry['probe'] = $pv }
      else { $script:svcFieldWarnings += "$k 的 probe 无效（$rawProbe），已回落 auto（TCP 通且 HTTP 200）" }
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

function Load-Svc {
  # 专用标志：configWarning 有两个写入方，后果不同——调用方只能认这个判断「是否回落成示例」。§Load-Svc
  $script:svcLoadFailed = $false
  if (Test-Path $cfg) {
    try {
      $loaded = Read-SvcFile $cfg
      # 可选字段写错只攒提示不走 configWarning（后者弹框写「使用恢复配置」）。
      # **必须先判空初始化为 @()**：$null += "x" 变成 String，@($null) 也不是空数组。§Load-Svc
      if ($null -eq $script:configNotices) { $script:configNotices = @() }
      foreach ($w in $script:svcFieldWarnings) { $script:configNotices += "services.json：$w" }
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
    if ($c.ST -in @('启动中','停止中','暂停中','继续中','删除中')) {
      return "$($c.SvcName) 正在切换中，稍后重载"
    }
  }
  $script:svcLoadFailed = $false
  $script:configWarning = $null
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

# 写进内存清单并落盘，CLI 与对话框共用。返回 $null 成功，否则错误信息。§Add-SvcEntry
function Add-SvcEntry([string]$n,[int]$p,[string]$url){
  [Threading.Monitor]::Enter($sync.gate)
  try { $script:svc[$n]=@{port=$p;url=$url} } finally { [Threading.Monitor]::Exit($sync.gate) }
  try { Save-Svc $script:svc } catch { return $_.Exception.Message }
  $null
}

# 命令纪元：随命令入队并随结果回 UI；Update-CardData 只认 epoch ≥ PendingEpoch 的回执。§Send-ServiceCommand
$script:cmdEpoch = 0

# 所有 GUI 命令统一入队并唤醒后台；队列保留 FIFO，事件只负责结束空闲等待。
function Send-ServiceCommand([string]$name,[string]$action) {
  $script:cmdEpoch++
  $e = $script:cmdEpoch
  $script:cmdQueue.Enqueue([pscustomobject]@{n=$name;act=$action;e=$e})
  [void]$script:sync.wake.Set()
  $e
}

# 打开面板 URL 的统一入口：包住 Start-Process，失败只提示不崩 GUI。§Open-PanelUrl
function Open-PanelUrl([string]$url){
  if ([string]::IsNullOrWhiteSpace($url)) { return }
  # 只放行 http/https：提权进程里 Start-Process 一个 file:/// 或自定义协议，等于管理员执行任意程序。
  if ($url -notmatch '^(?i)https?://') { Set-StatusMessage "只支持 http/https 面板地址：$url"; return }
  try { Start-Process $url -EA Stop }
  catch {
    # 先提示再记日志，各自包住；走 Set-StatusMessage 带租约，否则会被下一帧自动刷新吞掉。§Open-PanelUrl
    try { Set-StatusMessage "打开面板失败：$($_.Exception.Message)" } catch {}
    try { Write-CrashLog "Open-PanelUrl 失败: $($_.Exception.GetType().FullName): $($_.Exception.Message)" } catch {}
  }
}

# ---- 状态栏消息与每帧队列处理（DispatcherTimer 的回调体）----
# 消息带显示租约（$script:msgUntil）：否则后台失败消息会被同一 tick 的自动刷新盖掉。§状态栏消息
$script:MSG_LEASE = [TimeSpan]::FromSeconds(5)

function Set-StatusMessage([string]$text){
  if (-not $script:statusBar) { return }   # 模块可能被 CLI/测试加载，此时无状态栏
  $script:statusBar.Text = $text
  $script:msgUntil = [datetime]::Now + $script:MSG_LEASE
}

# UI 回调异常时的状态栏提示。抽成函数才测得了「截断 + 租约」这段。§Set-UiErrorStatus
function Set-UiErrorStatus([string]$message){
  if (-not $script:statusBar) { return }
  $m = [string]$message
  if ($m.Length -gt 80) { $m = $m.Substring(0,80) + '…' }
  Set-StatusMessage "操作出错：$m"
}

# Dispatcher 未处理异常的兜底体。每步各自包住；必须置 Handled，否则单次异常=整窗消失。§Invoke-DispatcherErrorFallback
function Invoke-DispatcherErrorFallback($e){
  try { Set-UiErrorStatus ([string]$e.Exception.Message) } catch {}
  try { Write-CrashLog "DispatcherUnhandled: $($e.Exception.GetType().FullName): $($e.Exception.Message)" } catch {}
  $e.Handled = $true
}

# 每帧：排空结果队列 → 排空消息队列 → 空闲 4 秒自动刷新。抽成函数才可单测，内联会导致测试复刻逻辑而漂移。§Update-StatusTick
function Update-StatusTick {
  $item = $null
  while ($script:queue.TryDequeue([ref]$item)) {
    if ($item.done) {
      if ($item.act -eq 'remove') {
        if (-not $item.ok) {
          # 删除失败：服务仍在、配置未动，不能走清理路径（那会把活着的服务从 UI 抹掉）。§Update-StatusTick
          Set-CardRollback $script:cards[$item.n]
          continue
        }
        [Threading.Monitor]::Enter($script:sync.gate)
        try { $script:svc.Remove($item.n) } finally { [Threading.Monitor]::Exit($script:sync.gate) }
        $script:cards.Remove($item.n)
        if ($script:healthSeen) { $script:healthSeen.Remove($item.n) }   # 同名重建时重记「首次观测」
        if ($script:svcState) { $script:svcState.Remove($item.n) }
        # 保存成败只赋一次文案（T6）：原实现对「保存失败」又被「已删除」盖掉，用户看不到。§Update-StatusTick
        $note = try { Save-Svc $script:svc; "$($item.n) 已删除" }
                catch { "$($item.n) 已删除但配置保存失败：$($_.Exception.Message)" }
        Set-StatusMessage $note
        Render-Page
      } else {
        # 启停回执：ok=$false 时 Update-CardData 回滚过渡态（T1），否则解封按钮与冷却。
        Update-CardData $item.n $null $null -e $item.e -ack -ok ([bool]$item.ok)
      }
    } else {
      # 健康历史：只有「状态或健康值变了」才记一条（4 秒一拍的重复值不落盘，否则一天几万行）。
      # 写盘交给后台 runspace（UI 线程不碰 I/O），这里只入队。
      if ($null -eq $script:healthSeen) { $script:healthSeen = @{} }   # 单测/CLI 直接调 tick 时没有初始化
      if ($null -eq $script:svcState) { $script:svcState = @{} }       # 同上；批量启停也读它
      # 全量记「最近一次探测值」：批量启停按它筛目标，翻页外（没有卡片）的服务也要能全启/全停。
      $script:svcState[$item.n] = @{ st = $item.st; h = $item.h }
      $prev = $script:healthSeen[$item.n]
      $prevSt = if ($prev) { $prev.st } else { $null }
      $prevH = if ($prev) { $prev.h } else { $null }
      if (Test-HealthChanged $prevSt $prevH $item.st $item.h) {
        $script:healthSeen[$item.n] = @{ st = $item.st; h = $item.h }
        if ($script:healthQueue) { $script:healthQueue.Enqueue((New-HealthEvent $item.n $item.st $item.h)) }
      }
      Update-CardData $item.n $item.st $item.h
    }
  }
  $msg = $null
  while ($script:msgQueue.TryDequeue([ref]$msg)) { Set-StatusMessage $msg }
  # 过渡态超时逃生：不依赖队列（后台 runspace 死了也要能逃），每帧独立判一次。§Update-StatusTick
  if ($script:cards -and (Get-Command Invoke-TransitionTimeoutEscape -EA SilentlyContinue)) {
    $now = [datetime]::Now
    # Get-Command 守卫：card.ps1 未加载（CLI/部分单测）时该函数不存在，不能带崩整个 tick。§Update-StatusTick
    foreach ($card in @($script:cards.Values)) {
      [void](Invoke-TransitionTimeoutEscape $card $now)
      # 同帧刷新时长：与逃生口一样不依赖队列。§Update-StatusTick
      Update-CardClock $card $now
    }
  }
  # 后台 runspace 结束 = 探测与命令都没人处理了。不提示的话按钮全灰、卡片停在最后一帧，
  # 而状态栏还在每 4 秒打「状态自动刷新」，看起来是活的——用户只能杀进程重开。
  if ($script:bgHandle -and $script:bgHandle.IsCompleted -and -not $script:bgDeathReported) {
    $script:bgDeathReported = $true
    try { Write-CrashLog 'Background runspace completed unexpectedly' } catch {}
    Set-StatusMessage '后台已停止响应，请重启工具'
    foreach ($card in @($script:cards.Values)) {
      if ($card.ST -eq '查询中') { Set-CardRollback $card '未知' '' }
    }
  }
  # 空闲 4 秒后自动刷新状态文字；消息租约未到期时不覆盖（T4）。
  # 后台已死时不再自动刷新——那会把「后台已停止响应」那条提示盖掉，又变成「看起来是活的」。
  if (-not $script:bgDeathReported -and $script:statusBar -and (-not $script:lastActionAt -or ([datetime]::Now - $script:lastActionAt).TotalSeconds -ge 4)) {
    if (-not $script:msgUntil -or [datetime]::Now -ge $script:msgUntil) {
      $script:statusBar.Text = "$(Get-Date -Format 'HH:mm:ss')  状态自动刷新"
    }
  }
}

# 探测单实例 mutex 是否被 GUI 持有。OpenExisting 抛 = 无 GUI（正常）；抢到要立即释放。§Test-GuiInstanceRunning
function Test-GuiInstanceRunning([string]$mutexName){
  try {
    $m = [Threading.Mutex]::OpenExisting($mutexName)
  } catch [System.Threading.WaitHandleCannotBeOpenedException] {
    return $false   # 互斥体不存在 = 没有 GUI 常驻
  } catch {
    # 存在但打不开（别的账户/SYSTEM 服务创建的 Global 互斥体 DACL 不允许）：保守判「运行中」，
    # 宁可让 CLI 让路，也不要覆盖别人的清单。
    return $true
  }
  try {
    $held = -not $m.WaitOne(0)
    if (-not $held) { $m.ReleaseMutex() }
    $held
  } catch {
    # AbandonedMutexException 等：保守判为运行中，宁可让 CLI 让路
    $true
  } finally { $m.Dispose() }
}

# 某服务的日志目录：读注册表 AppStdout 父目录，读不到回落 $logDir。**名字必须校验**（注册表会归一化 ..）。§Get-SvcLogDir
function Get-SvcLogDir([string]$n){
  if (-not $n -or $n -notmatch '^[A-Za-z0-9_.-]+$' -or $n -eq '.' -or $n -eq '..') { return $logDir }
  try {
    $p = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$n\Parameters" -Name AppStdout -EA Stop
    $dir = Split-Path ([string]$p.AppStdout) -Parent
    if ($dir -and (Test-Path -LiteralPath $dir)) { return $dir }
  } catch {}
  $logDir
}

# ---- 轮转档保留：只碰轮转档，永不动当前档 ----
# 删除须同时满足「不在前 KeepCount 份」且「早于 KeepDays 天」。参数名不能用 $LogDir（会遮蔽外层变量）。§Remove-RotatedLogs
function Remove-RotatedLogs([string]$LogPath,[int]$KeepCount=10,[int]$KeepDays=14){
  if (-not $LogPath) { $LogPath = $logDir }
  if (-not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) { return @() }
  $cut = (Get-Date).AddDays(-$KeepDays)
  # 只判「是不是轮转档」通用形态，不绑特定服务名。
  # 必须锚到结尾：服务名允许点与横线（`MySvc.err-20260101`），当前档 `MySvc.err-20260101.out.log`
  # 的 BaseName 里同样含 `.err-20260101`——不锚定就会把当前日志当轮转档删掉。§Remove-RotatedLogs
  $rot = @(Get-ChildItem -LiteralPath $LogPath -File -Filter '*.log' -EA SilentlyContinue |
    Where-Object { $_.BaseName -match '\.(out|err)-\d{8}(T\d{6}\.\d{3})?$' } |
    Sort-Object LastWriteTime -Descending)
  # 最近 KeepCount 份豁免（按修改时间倒序的前 KeepCount 个）。
  $keep = @($rot | Select-Object -First $KeepCount | ForEach-Object { $_.FullName })
  # 剩下的若早于 cut 也删；晚于 cut 的留（近期高频轮转不应被一刀切）。
  $del = @($rot | Where-Object {
    $_.FullName -notin $keep -and $_.LastWriteTime -lt $cut
  } | ForEach-Object { $_.FullName })
  foreach ($f in $del) { Remove-Item -LiteralPath $f -Force -EA SilentlyContinue }
  $del
}

# ---- 安全检查（借鉴 PSSM：路径引号加固 + 目录 ACL 过宽）：纯解析，不碰 UI 也不抛错。§Resolve-ServiceExeDir
function Resolve-ServiceExeDir([string]$path){
  if (-not $path) { return @{ dir = ''; quoted = $false } }
  $quoted = $path.StartsWith('"')
  # 去首尾引号，匹配到首个 .exe 的路径段，取父路径
  $clean = $path.Trim('"')
  if ($clean -match '^[a-zA-Z]:\\.*?\.exe') { $clean = $matches[0] }
  elseif ($clean.Contains(' ')) { $clean = ($clean -split '(?<=\.exe)\s')[0] }
  $dir = if ($clean) { try { Split-Path $clean -Parent -EA Stop } catch { '' } } else { '' }
  @{ dir = $dir; quoted = $quoted }
}

# 判定目录 ACL 是否「过宽」（本机任意标准用户可写）。返回 '是' / '否' / '未知'。§Test-DirAclPermissive
function Test-DirAclPermissive($acl){
  if (-not $acl) { return '未知（无法读取 ACL）' }
  # 宽泛主体含 Authenticated Users 与 AppContainer SID（S-1-15-3-*）；判据与 set-service-params-acl.ps1 的 Test-LeakyAce 对齐。§Test-DirAclPermissive
  foreach ($a in $acl.Access) {
    $id = $a.IdentityReference.Value
    $wide = @('BUILTIN\Users','Everyone','Users','NT AUTHORITY\Authenticated Users','Authenticated Users') -contains $id -or $id -like 'S-1-15-3-*'
    if ($wide -and $a.FileSystemRights.ToString() -match 'Write|Modify|FullControl') { return '是' }
  }
  '否'
}

function Show-SecurityCheck([string]$n){
  # 名字要拼进 WQL 过滤器：services.json 里的名字没过 Test-SvcInput 的正则，
  # 带单引号的名字能把过滤器改成别的查询，安全检查就会给出错误的路径与 ACL 结论。
  if ($n -notmatch '^[A-Za-z0-9_.-]+$') {
    [System.Windows.MessageBox]::Show("服务名含非法字符，无法安全检查：$n",'错误','OK','Error') | Out-Null
    return
  }
  try {
    $ci = Get-CimInstance Win32_Service -Filter "Name='$n'" -EA Stop
  } catch {
    [System.Windows.MessageBox]::Show("无法查询 $n 的服务信息。`n$($_.Exception.Message)",'错误','OK','Error') | Out-Null
    return
  }
  $path = [string]$ci.PathName
  if (-not $path) {
    [System.Windows.MessageBox]::Show("无法读取 $n 的可执行路径。",'错误','OK','Error') | Out-Null
    return
  }
  $r = Resolve-ServiceExeDir $path
  $dir = $r.dir; $quoted = $r.quoted
  $permissive = '否'
  if ($dir -and (Test-Path $dir)) {
    try { $permissive = Test-DirAclPermissive (Get-Acl -Path $dir) }
    catch { $permissive = '未知（无法读取 ACL）' }
  }
  $qTxt = if($quoted){'是（已加固）'}else{'否（路径含空格时有提权风险）'}
  $msg = "$n`n`n路径: $path`n`n引号加固: $qTxt`n目录: $dir`n目录 ACL 过宽: $permissive"
  [System.Windows.MessageBox]::Show($msg,"$n 安全检查",'OK',$(if($quoted -and $permissive -eq '否'){'Information'}else{'Warning'})) | Out-Null
}
