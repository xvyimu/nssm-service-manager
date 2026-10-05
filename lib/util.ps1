# lib/util.ps1 — 配置持久化（services.json）· UI 工具 · 日志轮转保留 · 安全检查
#
# 【本模块的作用域约定】本文件的函数体直接读调用方作用域里的 $cfg 与 $logDir
# （dot-source 时由 service-manager-gui.ps1 / 各测试脚本赋值），不是模块级变量。
# 因此：(1) 调用方必须在 dot-source 之后赋值，否则函数读到 $null；
#       (2) 本模块的函数**不得**把参数命名为 $cfg / $logDir 等约定变量——PowerShell
#           变量名大小写不敏感，参数会遮蔽同名外层变量，回落逻辑会静默失效。
#           历史事故：Get-LogFiles 曾把参数叫 $LogDir，遮蔽了外层 $logDir，
#           GUI 日志下拉框自上线起一直为空（d442fcf 修复）。
#
# 2026-10-05 拆分：Get-LogFiles / Show-Log 移去 lib/logview.ps1，nssm-set 移去
# lib/nssm.ps1。util.ps1 现在只有——配置持久化（Read/Load/Save）、命令纪元与入队
# （Send-ServiceCommand）、打开面板（Open-PanelUrl）、日志轮转保留（Remove-RotatedLogs）、
# 安全检查（Resolve-ServiceExeDir / Show-SecurityCheck）。

# ---- 配置层（services.json 是 SSOT，services.example.json 是兜底）----
# 兜底直接读仓里的示例清单，不在源码里再抄一份服务名（避免双源漂移）。
$script:configWarning = $null

function Read-SvcFile([string]$path){
  $j = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
  $o = [ordered]@{}; foreach ($k in $j.Keys) {
    $p = [int]$j[$k].port; $u = [string]$j[$k].url
    if ($p -lt 1 -or $p -gt 65535) { throw "$k 端口非法: $p" }
    $o[$k] = @{ port = $p; url = $u }
  }
  $o
}

function Load-Svc {
  if (Test-Path $cfg) {
    try { return Read-SvcFile $cfg }
    catch { $script:configWarning = $_.Exception.Message }
  }
  # 兜底：services.json 缺失或损坏时读示例清单，让首次运行有内容可看
  $example = Join-Path (Split-Path $cfg -Parent) 'services.example.json'
  if (Test-Path $example) {
    try { return Read-SvcFile $example }
    catch { if (-not $script:configWarning) { $script:configWarning = $_.Exception.Message } }
  }
  [ordered]@{}
}

# 原子写回：$PID.$guid.tmp → Replace（避免写一半停电留下半截 JSON）
# 写的是调用方传入的整个对象（`$s | ConvertTo-Json -Depth 5`）。
function Save-Svc($s) {
  $json  = $s | ConvertTo-Json -Depth 5
  $tmp   = "$cfg.$PID.$([guid]::NewGuid()).tmp"
  [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
  try {
    # [NullString]::Value 传真正的 CLR null；直接写 $null 会被 PowerShell 绑成空字符串，
    # 触发 File.Replace「The path is empty」（备份路径被当成非空字符串校验）。
    if (Test-Path -LiteralPath $cfg) { [IO.File]::Replace($tmp, $cfg, [NullString]::Value) }
    else { [IO.File]::Move($tmp, $cfg) }
  } finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -EA SilentlyContinue }
  }
}

# 命令纪元：每次 Send-ServiceCommand 递增，随命令对象入队；后台执行完把同一 epoch 跟着
# 结果回 UI。Update-CardData 据此过滤在途旧探测——过渡态期间只接受 epoch ≥ 卡片
# PendingEpoch 的回执，旧探测（无 epoch）直接丢弃，不再靠「方向匹配」做症状层补丁。
$script:cmdEpoch = 0

# 所有 GUI 命令统一入队并唤醒后台；队列保留 FIFO，事件只负责结束空闲等待。
function Send-ServiceCommand([string]$name,[string]$action) {
  $script:cmdEpoch++
  $e = $script:cmdEpoch
  $script:cmdQueue.Enqueue([pscustomobject]@{n=$name;act=$action;e=$e})
  [void]$script:sync.wake.Set()
  $e
}

# NSSM set 包装已移去 lib/nssm.ps1（同文件合并 Install/Remove-NssmService）。

# 打开面板 URL 的统一入口：包住 Start-Process，URL 非法/无默认浏览器/注册表关联损坏时
# 只提示不崩 GUI。card.ps1 两处（按钮 Click、右键菜单 open）都走这里——否则 Start-Process
# 抛异常会经 Dispatcher 冒到 AppDomain，没有 Dispatcher 级兜底就整窗消失。
# 不记 URL 本身（crashlog 不记配置值），只记异常类型与消息。
function Open-PanelUrl([string]$url){
  if ([string]::IsNullOrWhiteSpace($url)) { return }
  try { Start-Process $url -EA Stop }
  catch {
    Write-CrashLog "Open-PanelUrl 失败: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
    if ($script:statusBar) { $script:statusBar.Text = "打开面板失败：$($_.Exception.Message)" }
  }
}

# ---- 状态栏消息与每帧队列处理（DispatcherTimer 的回调体）----
# 消息带**显示租约**：写入时记 $script:msgUntil，自动刷新在此之前不得覆盖。
# 没有这条，后台失败消息会被同一 tick 的「状态自动刷新」立刻盖掉，用户永远看不见——
# 用户没在操作时 $script:lastActionAt 早已超过 4 秒阈值，而 remove 路径的
# stop + Wait-Stopped 最长 6 秒，失败消息必然跨过门槛。
$script:MSG_LEASE = [TimeSpan]::FromSeconds(5)

function Set-StatusMessage([string]$text){
  if (-not $script:statusBar) { return }   # 模块可能被 CLI/测试加载，此时无状态栏
  $script:statusBar.Text = $text
  $script:msgUntil = [datetime]::Now + $script:MSG_LEASE
}

# UI 回调抛异常时的状态栏提示（Dispatcher 兜底 handler 调用）。
# 抽成函数而非内联在 handler 里：handler 由 add_UnhandledException 注册在进程级上下文，
# 测不了；而「截断到 80 字符 + 带租约」这段才是真正会写错的部分。
# 只做最低风险的事（字符串处理 + 赋 Text）——此函数本身若抛，会走进程终止路径。
function Set-UiErrorStatus([string]$message){
  if (-not $script:statusBar) { return }
  $m = [string]$message
  if ($m.Length -gt 80) { $m = $m.Substring(0,80) + '…' }
  Set-StatusMessage "操作出错：$m"
}

# DispatcherTimer 每帧：排空结果队列（探测结果 / 命令回执）→ 排空消息队列写状态栏
# → 空闲 4 秒后自动刷新。抽成函数而不内联在 Add_Tick 里，是为了能直接单测：
# 原实现让 test-remove-async 只能「复刻」这段逻辑，改这里而漏改测试就是静默漂移。
function Update-StatusTick {
  $item = $null
  while ($script:queue.TryDequeue([ref]$item)) {
    if ($item.done) {
      if ($item.act -eq 'remove') {
        if (-not $item.ok) {
          # 删除失败（stop 或 nssm remove 抛错/非零）：服务仍在、配置未动，不能走下面的清理
          # 路径——那会把还活着的服务从 UI 抹掉，用户以为删掉了。回滚卡片过渡态并解封按钮，
          # 失败原因由后台 msg 队列给出（poll.ps1 已 Enqueue）。
          Set-CardRollback $script:cards[$item.n]
          continue
        }
        # 删除回执：清 svc 与卡片缓存、落盘配置、刷新分页。
        [Threading.Monitor]::Enter($script:sync.gate)
        try { $script:svc.Remove($item.n) } finally { [Threading.Monitor]::Exit($script:sync.gate) }
        $script:cards.Remove($item.n)
        # 保存成功/失败只赋一次文案（T6）：原实现在 catch 里写完「保存失败」后又无条件写
        # 「已删除」，把提示盖掉——services.json 未落盘时重开 GUI 服务会复活，用户却看不到原因。
        $note = try { Save-Svc $script:svc; "$($item.n) 已删除" }
                catch { "$($item.n) 已删除但配置保存失败：$($_.Exception.Message)" }
        Set-StatusMessage $note
        Render-Page
      } else {
        # 启停回执：ok=$false 时 Update-CardData 回滚过渡态（T1），否则解封按钮与冷却。
        Update-CardData $item.n $null $null -e $item.e -ack -ok ([bool]$item.ok)
      }
    } else {
      Update-CardData $item.n $item.st $item.h
    }
  }
  $msg = $null
  while ($script:msgQueue.TryDequeue([ref]$msg)) { Set-StatusMessage $msg }
  # 空闲 4 秒后自动刷新状态文字；消息租约未到期时不覆盖（T4）。
  if ($script:statusBar -and (-not $script:lastActionAt -or ([datetime]::Now - $script:lastActionAt).TotalSeconds -ge 4)) {
    if (-not $script:msgUntil -or [datetime]::Now -ge $script:msgUntil) {
      $script:statusBar.Text = "$(Get-Date -Format 'HH:mm:ss')  状态自动刷新"
    }
  }
}

# ---- 日志轮转档保留策略：NSSM 只改名不删档，logs/ 会无界增长 ----
# 只碰轮转档（BaseName 匹配 \.(out|err)-\d{8}，NSSM 实际命名带 T 与毫秒，如
# NewAPI.err-20261001T154751.222.log），永不动当前档（NewAPI.out.log / .err.log）。
# 策略：**跨服务全局**按修改时间倒序保留最近 KeepCount 份，其余若早于 KeepDays 天则删除。
# 两个条件是「且」——删除须同时满足「不在全局前 KeepCount 份」且「早于 KeepDays 天」。
# 故 KeepDays 窗口内的轮转档一份都不会删（高频轮转的服务在这段时间仍会堆积），
# 保留份数上限只在该时间之后才起作用。实测（2026-10-05，两个服务各 6 份、均 1 天前）：
# 删除 0 份；再加 5 份 20 天前的，删掉的是那 5 份（全局前 10 份豁免留给了另外两组）。
# 返回被删文件路径列表。
# 注：参数名不能用 $LogDir（PS 变量名大小写不敏感，会遮蔽外层 $logDir，与 Get-LogFiles 同坑）。
function Remove-RotatedLogs([string]$LogPath,[int]$KeepCount=10,[int]$KeepDays=14){
  if (-not $LogPath) { $LogPath = $logDir }
  if (-not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) { return @() }
  $cut = (Get-Date).AddDays(-$KeepDays)
  # 枚举所有 .log 文件，按 BaseName 过滤轮转档（行首锚定服务名已转义的写法在 Get-LogFiles；
  # 这里只判「是不是轮转档」通用形态，不绑特定服务名）。
  $rot = @(Get-ChildItem -LiteralPath $LogPath -File -Filter '*.log' -EA SilentlyContinue |
    Where-Object { $_.BaseName -match '\.(out|err)-\d{8}' } |
    Sort-Object LastWriteTime -Descending)
  if ($rot.Count -eq 0) { return @() }
  # 最近 KeepCount 份豁免（按修改时间倒序的前 KeepCount 个）。
  $keep = @($rot | Select-Object -First $KeepCount | ForEach-Object { $_.FullName })
  # 剩下的若早于 cut 也删；晚于 cut 的留（近期高频轮转不应被一刀切）。
  $del = @($rot | Where-Object {
    $_.FullName -notin $keep -and $_.LastWriteTime -lt $cut
  } | ForEach-Object { $_.FullName })
  foreach ($f in $del) { Remove-Item -LiteralPath $f -Force -EA SilentlyContinue }
  $del
}

# ---- 安全检查（借鉴 PSSM：路径引号加固 + 目录 ACL 过宽）----
# 纯解析：从 Win32_Service PathName 提取 exe 目录与引号状态，不碰 UI 也不抛错。
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

function Show-SecurityCheck([string]$n){
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
    try {
      $acl = Get-Acl -Path $dir
      foreach ($a in $acl.Access) {
        if (@('BUILTIN\Users','Everyone','Users') -contains $a.IdentityReference.Value -and $a.FileSystemRights.ToString() -match 'Write|Modify|FullControl') { $permissive = '是'; break }
      }
    } catch { $permissive = '未知（无法读取 ACL）' }
  }
  $qTxt = if($quoted){'是（已加固）'}else{'否（路径含空格时有提权风险）'}
  $msg = "$n`n`n路径: $path`n`n引号加固: $qTxt`n目录: $dir`n目录 ACL 过宽: $permissive"
  [System.Windows.MessageBox]::Show($msg,"$n 安全检查",'OK',$(if($quoted -and $permissive -eq '否'){'Information'}else{'Warning'})) | Out-Null
}

# ---- 安全检查（借鉴 PSSM：路径引号加固 + 目录 ACL 过宽）----
