# IMPLEMENTATION-NOTES.md — 代码内联注记

> 2026-10-29 从 `lib/` 与主脚本迁入。代码里对应位置留一行指针，指向本文件的小节。
> 只搬「为什么」的长段说明与实测数据；一眼能看懂的一行注释留在代码里。
>
> 与 `PROJECT.md` 的分工：PROJECT.md 讲**架构决策**（为什么选这套方案），本文件讲**实现里的坑**（这一行为什么必须这么写）。

## card.ps1

### Set-CardTransition

留档进入过渡态之前的终态：命令失败要 Set-CardRollback 原样放回。
不许反推方向——restart 的期望终态与起始方向相反，remove 干脆没有方向，
「按目标状态取反」会猜出错的终态。

过渡时钟独立于 LastToggle：后者兼作冷却起算点、回执到达时会被重写，
拿它算超时会在回执后把计时重置。TransitionAt 只在进出过渡态时动。

TransitionStartedAt 是过渡态的**起点**，只在进入时记一次；TransitionAt 会被探测刷新（慢启动），
它不刷新。逃生硬上限用它算，防止刷新把逃生口永久顶掉。

StateSince 是卡片时长的起算点，与 TransitionStartedAt 同步。分开是因为语义不同——
那个服务超时判据，这个服务显示，将来改一个不该动另一个。

过渡态要换自己的副标题：不换的话，启动中会一直挂着上一次的「随时可以启动」，
再叠上时长就变成「随时可以启动 · 已 12s」，自相矛盾。

### Update-CardClock

只改 LblUp 的**后缀**——正文由 Update-CardData 写进 LblUpBase，这里不重算，
否则健康文案会被时钟逻辑复制一份、两边迟早不一致。

**必须用 StateSince，不能用 TransitionAt**：后者会在每次探测报同一中间态时被刷新
（那是超时逃生判据的一部分），拿它算时长的话，慢启动服务会永远显示「已 0s」。

### Resolve-ToggleTimeoutMs

卡片过渡态阈值：services.json 的 per-service 覆盖优先，缺省回落全局。
New-Card 与 Update-CardInfo 都要算它——写成一份，免得将来改判据时只改一边（本仓的惯常教训）。

### Test-TransitionTimedOut

阈值优先取卡片自己的 ToggleTimeoutMs（services.json 的 per-service 覆盖），缺省回落全局。
重服务（AI 服务冷启动一分钟起）不该被全局 45s 硬套；旧夹具手工搭的卡片对象没有该字段，
取到 $null 即回落，不抛错。

硬上限：探测报同一过渡态时 TransitionAt 会刷新（慢启动不误判），但累计超过阈值×倍数
就强制逃生，否则「命令发了没回执」的卡片会一直停在中间态。
只管命令驱动的过渡态（MinValue 直接 false）；代价见 `PROJECT.md` 已知限制。

### Update-CardButtons

按当前状态/健康算两个按钮的可用性。三处（回执成功、回执失败、探测刷新）共用一份，
免得拆成两个按钮后某条路径只更新了其中一个。

### Set-CardRollback

命令失败（回执 ok=false）或过渡态超时逃生时，把卡片放回一个确定终态并解封按钮。
不能复用 Invoke-CardToggle 的方向推导：失败时服务状态没变，要的是「回到原样」。

$toState / $toHealth 可选覆盖目标态：删除中回执丢失时服务实际状态不明，调用方传
'未知' 收敛（见 Update-CardData 的删除中分支与 util.ps1 的过渡态 sweep）——回滚到
删除前的终态会让卡片显示「运行中」，但服务可能已被删掉。

先落回目标终态，再交给 Update-CardData 走常规渲染——否则过渡态守卫会按旧 ST 拦下这个值。

### Invoke-TransitionTimeoutEscape

过渡态超时逃生：把超时的过渡态卡片放出来。由 Update-StatusTick 每帧无条件扫描调用，
**不依赖队列生产者**——后台 runspace 死掉时也要能逃出来。
启动中/停止中回到命令前的终态；删除中收敛到「未知」（成败只有回执知道）。

### Invoke-CardAction

记录本次命令纪元：Update-CardData 只接受 epoch ≥ 这个值的结果/回执。
顺序与原实现一致：先置 UI 过渡态，再入队命令（入队返回值作纪元）。

### New-Card

右侧并排两个按钮：关闭 在左、启动 在右。拆开而不是一个来回变文字的按钮——
「启动」和「关闭」是两个不同方向的动作，合成一个按钮时用户要靠读文字确认当前能干什么。

### Update-CardInfo

刷新缓存卡片的端口/URL/按钮 Tag（配置变更后命中缓存时调用）。
同名重建或端口变更后，旧缓存的 Port/Url/Tag 会与 $script:svc 不一致——
发现 1 的根因：New-Card 把 port/url 固化进控件，Render-Page 命中缓存直接复用。

### Update-CardData

调用方据 $item.done 分流：命令完成回执走 -ack 分支，探测结果走普通分支。
epoch 只过滤**命令回执**：旧命令的回执不解除新命令的过渡态。
**普通探测仍按方向匹配收尾**——服务真正进入期望终态时让过渡态退出，这是有意保留的行为，
不是「症状层补丁消除」。回执丢失时由超时逃生兜底。

失败回执（T1）：命令没成功（启动抛异常/停止 sc.exe 非零/删除失败），不能只解封按钮——
卡片还停在过渡态文字上，而后续探测会被上面的过渡态守卫按「期望终态」永久丢弃
（启动失败时服务恒为已停止，永远等不到运行中）。故先回滚到命令前的终态，按钮恢复可用。

右键菜单的启停（start / stop）直接 Send-ServiceCommand、不置过渡态（TransitionAt 仍为 MinValue）。
失败回执只按 **epoch 归属** 决定回不回滚：`$e -ne $c.PendingEpoch` 时（右键命令的 epoch
恒大于卡片当前那条）只重算按钮，不动别人的过渡态。原来的判据是「卡片有没有 TransitionAt」，
会把双击建立的「停止中」刷回「运行中」，而那条停止命令其实还在途。

**重启（restart）是两段式**（2026-10-30）：右键「重启」不再直接入队，而是走 `Invoke-CardRestart`
——先按停止处理置「停止中」（双按钮禁用、双击被状态门闩拒掉），停止阶段结束后 poll 补发一条
`phase='start'` 的中间回执（不带 st/h），`Update-StatusTick` 收到后换成「启动中」，最终回执照旧
按 epoch 收尾。修前 restart 不置过渡态：卡片仍显示「运行中」、按钮可用，双击会再下发一条反向
命令——后到的 stop 落在 start 之后，服务被停掉而卡片先显示过「运行中」。

中间回执不是探测值，不写 `svcState` / 健康历史；`$e -lt PendingEpoch` 的旧回执被忽略。
两个阶段都受方向守卫保护（停止中只认已停止、启动中只认运行中），所以 stop 未生效时的「运行中」
或迟到的「已停止」都不会抢跑过渡态。失败时回滚到「未知」而不是谎报终态（两段交互后 PrevST
可能是中间态，`Set-CardRollback` 会把它过滤掉），下一拍探测（≤4s）纠正。

两条额外守卫（实测补的）：① **删除中、命令驱动的切换中拒绝重启**——删除的终态只能由 remove
回执决定，把卡片从「删除中」翻成「停止中」会让用户以为删除变成了重启；命令驱动的切换中再压一条
重启，只会让前一条的回执变成过期回执。② 探测驱动的卡死态（`TransitionAt = MinValue`，SCM 卡在
`StopPending`）**仍允许**重启——右键是那类状态的唯一逃生口。另外 `Update-CardRestartPhase` 只在
卡片仍处「停止中」且命令驱动时才换段，超时逃生后迟到的中间回执不会再把卡片推进「启动中」。

成功回执：解封按钮 + 起冷却，但门闩必须按**当前**状态重算——不能无条件置 $true。
右键菜单的启停不经 Invoke-CardToggle，故回执到达时卡片可能仍停在「已停止」而没进过渡态；
硬置 ReadyToToggle=$true 会让一个已经停下的服务点亮「关闭」按钮。
健康**不**参与按钮门闩（2026-10-30 改）：ReadyToToggle 只看状态，双击的健康检查在
Invoke-CardAction 里按 `$detailed` 分支单独做，理由见「健康口径 auto / tcp」。

删除中：终态由 remove 回执决定，没有「期望终态」可等。期间探测必然先报「已停止」、
随后可能报「未安装」，都只是过程态——一律丢弃，否则卡片会闪回并重新点亮按钮。
例外：超时逃生（回执彻底丢了时同样不能永久卡住）。

删除中回执丢失（后台异常退出）时收敛到「未知」，**不用**到达的探测值：
探测可能报「已停止」（删除本就先 stop）→ 收敛后按钮点亮，用户能对一个正在删除的
服务下「启动」。删除的成败只有 remove 回执知道，丢失时状态就是不确定，故显示未知、
不解封按钮。删除路径正常 ≤6s，走到这里说明后台确已失联。

方向守卫：启动中只接受「运行中」收尾、停止中只接受「已停止」，未安装/未知放行。
**只保护命令驱动的过渡态**（TransitionAt 有值）。探测驱动的（外部启停、MinValue）
若也按方向丢弃，启动失败的「已停止」会被永久丢、卡片卡死且连逃生都失效（H1）。

探测报的状态和卡片一样 → 服务还在动，不是回执丢了。刷新计时，让逃生阈值从
「最后一次看到它在动」起算（否则慢启动会一直停在点按钮那一刻）。

离开过渡态（旧 ST 是过渡态、新 ST 不是）→ 复位 TransitionAt。不复位它就会停在旧时间戳：
之后任何探测驱动的过渡态都会被误判成命令驱动（M1），方向守卫被错误施加。

只在状态**变化**时重记起算点：探测每 4 秒来一次，每次都重置的话时长永远停在 0。
**只有「查询中」算首帧**（查询中 → 终态）：那时长只能从「打开工具」算起，
不是服务真实的运行/停止时刻——一打开就跳「已运行 3 秒」是误导。
「未知」是探测出错或删除收敛后的真实状态，从它转进运行中/已停止要起算。

暂停态两个按钮都不可用（启动对已运行的服务无效，关闭要求健康正常）；
恢复得走右键菜单的「重启」——它先 stop 再 start，SCM 接受。

## util.ps1

### 文件头 · 作用域约定

函数体直接读调用方作用域里的 $cfg / $logDir（dot-source 后由调用方赋值），不是模块级变量。
故：参数**不得**叫 $cfg / $logDir——变量名大小写不敏感，参数会遮蔽外层变量、回落逻辑静默失效
（Get-LogFiles 曾因此让日志下拉框长期为空）。

兜底直接读仓里的示例清单，不在源码里再抄一份服务名（避免双源漂移）。
【不要在此初始化 $script:configWarning】config.ps1 可能已写入原因，这里赋 $null 会清掉它。

### Read-SvcFile

可选字段写错的收集箱（Load-Svc 读完并入 configNotices 弹给用户）。
为什么收集而不抛：抛会让 Load-Svc 落到 catch，整份清单退回 services.example.json——
GUI 里显示的是示例服务，用户点一次增删，Save-Svc 就把示例写回真实文件，清单全没。
一个可选字段写错只该让**那个字段**不生效。

可选 per-service 超时覆盖（缺省回落 config 的全局值）：
  toggleTimeoutMs — 卡片过渡态超时逃生（重服务冷启动一分钟起时调大）
  httpTimeoutMs   — HTTP 健康探测超时
  tcpTimeoutMs    — 端口探测超时
**必须在这里显式带走**：Save-Svc 写的是整份 $script:svc，本函数只挑 port/url 的话，
用户在 services.json 里写的覆盖字段会在下一次 GUI 增删服务时被静默抹掉。

**不能用 ContainsKey($opt)**：ConvertFrom-Json -AsHashtable 返回的是
System.Management.Automation.OrderedHashtable，它的键**大小写敏感**（实测：
写 ToggleTimeoutMs 时 ContainsKey('toggleTimeoutMs') 为 False，点访问却能取到值）。
而 config.json 的覆盖走 [ordered]@{} 的 Contains()，那个不敏感——两处行为不能不一致。
按 -ieq 找实际键名：用户照 README 表格写 ToggleTimeoutMs 也得生效。

写错/写 0 只让该字段不生效（回落全局），服务本身照常保留；原因记进收集箱弹给用户。

### Load-Svc

专用标志：$script:configWarning 有两个写入方（config.ps1 处理 config.json，这里处理
services.json），而两者后果完全不同——config.json 坏了按设计「不阻断，用默认值」。
调用方（CLI 的 -Add 门闩）要判断的是「服务清单是否回落成了示例」，只能认这个标志。

可选字段写错：清单照常用，只把原因攒成提示（configNotices），不走 configWarning——
后者配套的弹框会写「当前使用恢复配置」，而这里并没有用恢复配置。
**必须先判空初始化为 @()**：`$null += "x"` 得到的不是数组而是 String（+= 走字符串
拼接），后面 -join 就失效，多条提示会粘成一行。注意 `@($null)` 也不是空数组，
是「含一个 $null 的数组」——只能在确认是 $null 时显式赋 @()。
这里可以初始化：本变量没有别的模块写入，不存在 configWarning 那种被覆盖的问题。

消息自带文件名：主脚本的弹框用中性前缀（configWarning 可能来自 config.json 或
services.json，调用方无从判断），来源只能由写入方在这里讲清楚。

### Save-Svc

原子写回：$PID.$guid.tmp → Replace（避免写一半停电留下半截 JSON）。第三参给 `services.json.bak`：
清单不在 git 里，没有备份等于没有回滚（2026-10-30 加，修前传的是 `[NullString]::Value`）。

写前比对 mtime（Load-Svc 成功时记进 `$script:svcFileStamp`）：GUI 常驻期间有人手改、或另一个
会话抢先写，全量写回会把对方改动整份抹掉——直接拒写，让用户按 F5 重载后再改。写完刷新 stamp，
否则自己第二次保存会被判成外部修改。stamp 为 `$null`（没走 Load-Svc 的测试/首次无文件）时不校验。

`.bak` 只读会在写前自动清属性（它本来就是我们自己的上一版）；被其它进程占用时 Replace 失败，
整次保存报错——宁可让用户看到失败，也不静默丢掉备份。

**目标文件只读**（2026-10-30 加）：`File.Replace` 要求目标可写，被用户或备份工具标成只读后每次保存
都报「无法删除要被替换的文件」，而错误里没有任何「只读」线索。写前对 `$cfg` 做同样的属性清理
（它就是我们的配置文件），清不掉再抛一句「services.json 是只读的：<path>」。

### 只读 Web 视图（webview.ps1 / webview-core.ps1 / webview-server.ps1）

三个文件不是拆着玩：runspace 里不能 dot-source，只能把**文本**拼进去。core 是纯函数（无顶层语句），
server 是顶层循环；拼的是这两份。第一版把 `webview.ps1` 全文拼进去，里面正好有 `Start-WebView` 和
那段 `$script:webScript = ...` 赋值——进 runspace 后 `$PSCommandPath` 为空，赋值报错但脚本继续跑，
于是「能工作，但每次启动都带一条隐藏异常」。`test-webview` 现在断言 `$ps.Streams.Error.Count -eq 0`
把这条路封住。

三层取舍：

- **不用 `HttpListener`**：非管理员注册 URL 前缀要 `netsh urlacl`，便携运行和测试都多一道环境依赖；
  `TcpListener` + 60 行解析够用，代价是只支持 GET。
- **只听 127.0.0.1**：进程是管理员权限，监听 0.0.0.0 等于把「管理员工具的读接口」放到局域网。
  要看就 SSH 端口转发，鉴权交给 SSH，不自己写登录/会话。
- **token 走 query 而不是 Header**：目的只是挡住本机其它进程/页面的顺手访问（浏览器历史会留，
  所以每次启动换新的）。比较做成长度+逐字符，避免早退泄露前缀。

数据只读 `$sync.svc` / `$sync.svcState`，不碰卡片、不发命令；端口 0 = 随机，绑定失败写进
`$sync.webError` 由状态栏报出来（不静默）。

### 批量启停（card.ps1）

入口是状态栏汇总标签的右键菜单，目标由 `$script:svcState` 决定——这个表在 `Update-StatusTick` 里
对**每个**探测结果写一条（不只是有卡片的），所以翻页外、甚至从没翻到过的服务也能被全启/全停。
用 `$script:cards` 筛会漏：卡片只在翻到那一页时才建。

只处理「已停止 / 运行中」两种终态。启动中/停止中/暂停/未安装一律跳过——批量命令和手动命令
抢同一张卡时，过渡态是最容易打架的地方。停止前走 `Confirm-BatchStop`（MessageBox OKCancel），
单独成函数是为了无头测试能重定义。

每个目标都走 `Send-ServiceCommand`（同一条队列、同一套 epoch），有卡片的再 `Set-CardTransition`：
省掉一个探测周期的滞后和这期间的双击窗口；没卡片的就靠探测收敛，不额外造状态。

**过期状态门闩**（2026-10-30）：`$script:svcState[$n]` 除 `st/h` 外还落一个 `at`（探测落库时刻）。
批量跳过 `at` 早于 `2 × ProbeIntervalMs` 的条目，并在返回文案里说明「N 个状态过期已跳过」——
窗口刚打开、后台 runspace 死掉或探测被限流时，旧值会让批量朝「其实已经停了」的服务再发 stop，
刷一串 1056/1062。`at` 缺失的条目当新鲜处理（旧夹具/外部直接写 `svcState` 时不该被静默跳过）。

### 健康历史（health.ps1 + poll.ps1 + util.ps1）

事件形状 `{ts,n,st,h}`，一天一个 `health-YYYYMMDD.ndjson`。`Test-HealthChanged` 只放行变化：
首次观测（prev 都为 `$null`）算变化，之后按 `"$prevState|$prevHealth"` 字符串比对——用对象比较
会把 `$null` 与 `''` 当成反复变化。

写入路径：UI 线程只 `$script:healthQueue.Enqueue((New-HealthEvent ...))`，落盘在 poll 循环开头
（`Add-HealthEvent` 自己吞异常：历史写不进去不该影响探测）。因此 `lib/health.ps1` 要像 svc-common
一样被前置进 runspace 文本；util.ps1 另外按需 self-load 一次，让「只 dot-source util」的单测也能用。

读取从最新文件、最新行往前读，坏行跳过；清理只认标准文件名 `health-\d{8}`，按 `HealthKeepDays`
删整个文件——不做行级裁剪，文件本身就是一天的量。`HealthHistory=false` 时队列为 `$null`，
后台 `if ($sync.healthQ)` 整段跳过，不留「写空目录」的路径。

**只读尾部**（2026-10-30）：`Get-HealthEvents` 原来 `ReadAllLines` 把每个文件整份读进来，再逐行
`ConvertFrom-Json`，按天增长后点一次「健康历史」就卡 UI（与日志窗口同类的旧问题）。

现在的读法是 `Invoke-HealthTailScan`：从文件末尾按 64 KiB 块反向扫，块内找 0x0A 切行、再按行解码
（字节级切行，多字节字符不会被截断；跨块的行用 `carry` 拼回），边扫边判、凑够 `Limit` 就停。
`Read-HealthTailLines` 是它的「按行收集」封装，`$Days` 只决定最多看几个文件。

两层预筛（服务名是 ASCII，落盘用的是 `ConvertTo-Json -Compress`，所以 `"n":"<name>"` 可直接子串匹配）：
**块级**——整块（及遗留的 `carry`）都不含目标就只留块首半行、跳过块内所有行；**行级**——不命中的行
不付 UTF-8 解码与回调的钱。没有块级预筛时，稀疏服务（一天只变化一次、却在 20MB 文件头）要逐行
扫完，实测 8.8s；只加行级预筛是 1.9s；两层都加后 22MB/30 万行里捞 1 条是 237ms，密集场景（尾部 200
条）55ms。`test-health` 固定两条断言：20MB 尾部 200 条 < 500ms、4.5MB 稀疏 1 条 < 500ms。

### Test-SvcFileChanged / Invoke-SvcReload（util.ps1）

mtime 门闩挡住「手改后全量写回」，但原来只把用户挡在「关闭重开 GUI」。补的出口是 F5：
tick 里一次 `stat`（不读文件）判外部改动，命中就提示一次并置 `$script:svcFileHintShown`；
F5 走 `Invoke-SvcReload` 重新 `Load-Svc`，把 `$script:sync.svc` 指向新对象（后台每轮重读这个键，
不换就等于探测旧清单），再按名字差异摘掉消失的卡、由 `Render-Page` 复用/新建——所以健康值、
冷却、过渡态都不丢。

两个拒绝条件：有在途命令（`启动中/停止中/暂停中/继续中/删除中`）时拒绝——回执会落在不存在的
卡上，删除成功路径还会 `$script:svc.Remove` + `Save-Svc` 把旧内存清单写回磁盘；清单解析失败时
拒绝，原清单保持不变（`svcLoadFailed` 同时让后续保存也拒写）。

### Add-SvcEntry

把新服务写进内存清单并落盘——CLI（-Add）与 GUI 对话框共用一份。
返回 $null 表示成功；否则返回错误信息，由调用方决定怎么提示、是否关窗/退出。

**copy-on-write**（2026-10-30）：先按当前清单复制一份 `$next`，把新条目写进副本，`Save-Svc $next`
成功后才替换 `$script:svc` 并同步 `$sync.svc`（后台每轮重读这个键）。原来先改 `$script:svc` 再保存，
保存抛错时那条服务留在内存里——用户以为没加成，下一次任意保存（比如删掉别的服务）会把它写进磁盘。
失败路径因此变成「要么都在，要么都不在」。

`$probe` 只在非默认口径时落盘（`tcp` / `http`），`auto` 不写：它是缺省值，写出来只是噪声。

### Send-ServiceCommand

命令纪元：每次 Send-ServiceCommand 递增，随命令对象入队；后台执行完把同一 epoch 跟着
结果回 UI。Update-CardData 据此只认 epoch ≥ 卡片 PendingEpoch 的回执——旧命令的回执
不该解除新命令的过渡态。普通探测不带 epoch，仍按方向匹配收尾（见 card.ps1）。

### Open-PanelUrl

打开面板 URL 的统一入口：包住 Start-Process，URL 非法/无默认浏览器/注册表关联损坏时
只提示不崩 GUI。card.ps1 两处（按钮 Click、右键菜单 open）都走这里——否则 Start-Process
抛异常会经 Dispatcher 冒到 AppDomain，没有 Dispatcher 级兜底就整窗消失。
不记 URL 本身（crashlog 不记配置值），只记异常类型与消息。

先给用户可见的提示、再记日志，且各自包住——用户的提示不该被日志写入的失败连累
（Write-CrashLog 自身依赖 $logDir/配置，早期或异常场景下可能抛）。
走 Set-StatusMessage 而非直接赋 Text：带显示租约，否则用户没在操作时会被下一帧
自动刷新吞掉（与 T4 修的同类问题：失败提示必须留得住）。

### 状态栏消息

消息带**显示租约**：写入时记 $script:msgUntil，自动刷新在此之前不得覆盖。
没有这条，后台失败消息会被同一 tick 的「状态自动刷新」立刻盖掉，用户永远看不见——
用户没在操作时 $script:lastActionAt 早已超过 4 秒阈值，而 remove 路径的
stop + Wait-Stopped 最长 6 秒，失败消息必然跨过门槛。

### Set-UiErrorStatus

UI 回调抛异常时的状态栏提示（Dispatcher 兜底 handler 调用）。
抽成函数而非内联在 handler 里：handler 由 add_UnhandledException 注册在进程级上下文，
测不了；而「截断到 80 字符 + 带租约」这段才是真正会写错的部分。
只做最低风险的事（字符串处理 + 赋 Text）——此函数本身若抛，会走进程终止路径。

### Invoke-DispatcherErrorFallback

Dispatcher 未处理异常的兜底体（注册行在主脚本）。事件参数是私有构造，只能真抛真接验证。
每步各自包住：本函数内再抛会直接终止进程。
必须置 $e.Handled = $true：否则异常继续冒到 AppDomain，单次点击异常=整窗消失。

### Update-StatusTick

DispatcherTimer 每帧：排空结果队列（探测结果 / 命令回执）→ 排空消息队列写状态栏
→ 空闲 4 秒后自动刷新。抽成函数而不内联在 Add_Tick 里，是为了能直接单测：
内联在 Add_Tick 里时测试只能「复刻」这段逻辑，改这里而漏改测试就是静默漂移。

删除失败（stop 或 nssm remove 抛错/非零）：服务仍在、配置未动，不能走下面的清理
路径——那会把还活着的服务从 UI 抹掉，用户以为删掉了。回滚卡片过渡态并解封按钮，
失败原因由后台 msg 队列给出（poll.ps1 已 Enqueue）。

保存成功/失败只赋一次文案（T6）：原实现在 catch 里写完「保存失败」后又无条件写
「已删除」，把提示盖掉——services.json 未落盘时重开 GUI 服务会复活，用户却看不到原因。

过渡态超时逃生（T1 的后台死亡分支）：无条件扫描所有卡片，把超时的过渡态放出来。
不能只靠 Update-CardData 里的超时分支——那条只在**有探测结果到达**时才跑；后台 runspace
若已异常退出，队列再无生产者，卡片会永久卡在「启动中/停止中/删除中」。这里不依赖队列，
每帧独立判一次，是逃生口的兜底。卡片缓存未建时（CLI/部分单测）跳过。

Get-Command 守卫与主脚本的 Dispatcher handler 同款：card.ps1 未加载（CLI/部分单测）
时该函数不存在，不能让它把整个 tick 带崩。

同帧刷新卡片时长（启动/停止过程显示已用多久，运行中显示已运行多久）。
与逃生口同一处：两者都不依赖队列，后台 runspace 死了也照常走。

### Test-GuiInstanceRunning

探测单实例 mutex 是否已被 GUI 持有（CLI -Add 分支与 GUI 都靠它）。
$mutexName 形如 'Global\service-manager-gui'——用 Global 命名空间是因为 Local 只在当前会话
可见，计划任务/SSH 会话里跑 -Add 会误判「没有 GUI」，写进去的新增随后被 GUI 全量写回覆盖。

`WaitHandleCannotBeOpenedException`（互斥体不存在）→ 返回 $false，是正常路径。
其余打开失败（别的账户/SYSTEM 创建的 Global 互斥体 DACL 不允许当前用户打开）→ 返回 $true，
保守判「运行中」——宁可让 CLI 让路，也不要覆盖别人的清单。
抢到（WaitOne(0)=true）要立即释放，否则会把所有权留在本线程、影响后续判断。
AbandonedMutexException 等：视为「有实例曾持有」——保守判为运行中。

### Get-SvcLogDir

某服务的日志目录：读注册表 AppStdout 的父目录，读不到回落 $logDir。
手工 nssm 注册的服务（如 ComfyUI）日志在别处，用 $logDir 会看不到也清不到。
**名字必须校验**：注册表 provider 会归一化 `..`，坏名字能读到别的服务的目录。

### Remove-RotatedLogs

轮转档保留：NSSM 只改名不删档，只碰轮转档，永不动当前档。
按目录各算各的（调用方对 $logDir 与每个服务的 AppStdout 目录逐个调用）。
删除须同时满足「不在该目录前 KeepCount 份」且「早于 KeepDays 天」——
故天数窗口内的档一份不删。参数名不能用 $LogDir（大小写不敏感，会遮蔽外层变量）。

枚举所有 .log 文件，按 BaseName 过滤轮转档（行首锚定服务名已转义的写法在 Get-LogFiles；
这里只判「是不是轮转档」通用形态，不绑特定服务名）。
剩下的若早于 cut 也删；晚于 cut 的留（近期高频轮转不应被一刀切）。

### Resolve-ServiceExeDir

安全检查（借鉴 PSSM：路径引号加固 + 目录 ACL 过宽）。纯解析：从 Win32_Service PathName
提取 exe 目录与引号状态，不碰 UI 也不抛错。

### Test-DirAclPermissive

判定目录 ACL 是否「过宽」——本机任意标准用户可写。纯函数，不碰 UI（Show-SecurityCheck 会弹框）。
判据：主体是 Users/Everyone 之一，且权限含 Write/Modify/FullControl。
传入已读到的 ACL 对象（不在此处 Get-Acl），返回 '是' / '否' / '未知（无法读取 ACL）'。

「宽泛主体」= 本机任意登录用户即可写。Authenticated Users 是最常见的漏判形态
（目录只对 NT AUTHORITY\Authenticated Users 开放时，任何登录用户可替换 exe → 提权）；
AppContainer 包 SID（S-1-15-3-*）同理。判据与 set-service-params-acl.ps1 的
Test-LeakyAce 概念一致，但这里是文件系统 ACL、权限枚举不同，故不共用函数、只对齐主体清单。

## poll.ps1

### 文件头

内存取舍：端口探测用 TcpClient（Get-NetTCPConnection 会常驻 +10MB CIM provider）；
HTTP 用共享 HttpClient（IWR 每次新建并加载整套 cmdlet）。结果仍是字符串，不持有 UI 对象。

runspace 不能 dot-source 外部文件（脚本块字符串里没有 $PSScriptRoot），构造时把 svc-common.ps1
的文本前置进 $script:poll——UI 线程与后台引用的是同一份源码，原「SYNC: 两处同改」注释消除。

超时改由**每次请求**的 CancellationTokenSource 控制（services.json 里 per-service 的
httpTimeoutMs 可能比全局值更长，而 HttpClient.Timeout 是实例级上限，单次请求改不动）。
实例级放开到无限，全局 $httpMs 变成「没有 per-service 覆盖时」的默认值。
注意是 System.Threading.Timeout.InfiniteTimeSpan；TimeSpan.InfiniteTimeSpan 在旧运行时上不存在
（PowerShell 里取到 $null → 赋值抛 "Cannot convert null to type System.TimeSpan"）。

退出码映射与状态映射已移到 lib/svc-common.ps1（本文件头部把它的文本前置进 runspace，
故此处仍可用）；移出去是因为 UI 线程与 CLI 也要同一份映射，而 here-string 里的函数
不进 UI 作用域。

### Invoke-ServiceStart

Start() 对慢启动服务会等满 ServicesPipeTimeout（30s）再抛异常（实测 30032ms）——
所以 catch 里先看真实状态：StartPending/Running 就算启动成功，别回落 sc.exe（会弹控制台窗）。
两个坑（见 docs/HANDOFF.md P0-2）：① Status 对不存在的服务返回空串而非抛异常，
需先判空回落 sc.exe 取「未安装」错码；② 已运行/无权限时抛英文包壳异常，
回落到 sc.exe 取退出码经 Convert-ScExitCode 出中文更友好。
ServiceController 持有 SCM 句柄，用 try/finally 释放，不靠 GC。

构造点可注入：$sync.newSc 给出 runspace 内一个函数名时用它（同 $sync.nssm 的约定）。
runspace 里无法替身化 .NET 构造函数，测试要构造 StartPending 状态的替身只能从这里进；
未设时走真实 ServiceController，生产路径零开销。

Running 与 StartPending 同组：服务已在（或正在）启动，Start() 对这两种状态都会抛
MethodInvocationException，回落 sc.exe 取回 1056 → 状态栏出现「启动失败(1056 已在运行)」
这种自相矛盾的文案。触发路径真实：card.ps1 右键菜单的「启动」直接 Send-ServiceCommand，
不经 Invoke-CardToggle 的 ST 门闩，故 StartPending 能落到这里。
视作「已在启动」直接成功返回：不产生失败消息，也不白付一次 sc.exe 往返。

Start() 对**慢启动**服务会等满 ServicesPipeTimeout（实测 30s）再抛异常，而服务
其实已经在起。先看真实状态：StartPending/Running 就按启动成功返回，别回落 sc.exe。
回落那条路既会误报「启动失败」，又会给 GUI 进程弹出一个控制台窗口（实测：点启动约
30 秒后冒黑框，正是这一刻）。

### Invoke-PendingCommands

执行命令队列（启停与删除全在后台线程，避免 UI 线程同步等待 stop/remove 冻结界面）
返回本轮出队执行的命令条数——主循环据此判「有在途命令」，见下方面轮询间隔的取舍。

删除走后台：stop → Wait-Stopped ≤6s → nssm remove confirm → 实证复核 → 回执带 done=remove
UI 侧（Show-Remove 的 del_Click）入队后立即关弹窗，结果由 ack 回执处理。
序列本体在 svc-common.ps1 的 Invoke-ServiceRemove（本文件头部前置其文本），
与 nssm.ps1 的 Remove-NssmService 共用同一份——原先两处各写一份，
复核逻辑只改一侧就会漂移（例如有人简化这里，以为 nssm.ps1 有 canonical 实现）。
$nssm 在 runspace 里不可见——NSSM 路径经 $sync.nssm 从 UI 传入。

命令完成回执：把同一命令纪元与执行结果带回 UI。ack 分支据此解封按钮/冷却或处理删除收尾。
ok 必须带回来——失败时（启动/停止/删除抛异常或 sc.exe 返回非零）UI 侧要回滚卡片过渡态
并解封按钮，否则卡片永久卡在「启动中/停止中/删除中」（T1：原实现只在 $ok 时 Enqueue，
失败即静默，配合 card.ps1 的单一期望终态守卫，按钮再也不会亮）。

### 主循环

上一次全量健康探测（TCP+HTTP）的时刻（TickCount64，毫秒、单调）：
中间态快轮询只加快状态查询，不该把探测也提速。0 = 启动后还没探测过。

批量查询服务状态（发现 7）：一次 Get-Service 拿回全部，避免每服务一次 SCM 往返。
只要有任一名字不存在，Get-Service 就整批抛 ObjectNotFound（实测：不是部分返回，
赋值都完不成）——故 catch 退回逐个查询，在那里区分「未安装」与「未知」。

收集阶段：算状态，运行中的留待并行探测，其余直接入队。
并行化（发现 4）：原 foreach 串行 TCP+HTTP，6 服务最坏 ~19s；
改并行后最坏 ~3.2s（HTTP 超时上限）。命令在收集间隙仍优先处理，
但并行探测期间不插 Invoke-PendingCommands——最长等一次并行轮。

有服务停在 StartPending/StopPending/暂停中/继续中时也算「活跃」：否则过渡期间整轮没有可探测项，
轮询退到 ProbeIdleMs(15s)，卡片上的「启动中」十几秒才收到一次状态，过渡计时也迟迟不刷新。

并行探测运行中服务：每个服务一个并行块，内部 TCP→HTTP 串行，服务间并行。
$using:http 传 HttpClient 引用（线程安全）；结果按输入顺序返回，统一入队。
中间态快轮询期间（$pendingSeen）按 ProbeIntervalMs 限流 TCP+HTTP：1s 一轮会把
运行中服务的探测负载放大 4 倍，而服务卡在 StopPending 可能持续很久。
**但状态不能跟着慢**：被限流跳过的那一轮，仍把 $toProbe 各服务按「运行中 + 上次
健康值」入队——批量 Get-Service 已经拿到新状态，这里只是把它送到 UI。
用 TickCount64 而不是墙钟：NTP 校正/休眠恢复让时钟回拨时，墙钟差为负会让探测
一直被判定「还没到点」。

轻量端口探测：TcpClient $tcpMsLocal 超时（不用 Get-NetTCPConnection）。
$tcpMs 必须经 $using: 传入——ForEach-Object -Parallel 开新 runspace，
不继承父作用域变量；裸用 $tcpMs 在此取到 $null，WaitOne(0) 立刻返回 False，
运行中服务被误判「无响应」变红（启停时 runspace 更忙，0ms 扑空概率上升）。

HTTP 探测：共享 HttpClient，超时按请求给（默认 3s，per-service 可覆盖）。
响应必须 Dispose，否则内容缓冲滞留——每轮探测泄漏一份。
CTS 也必须 Dispose：它是 WaitHandle 持有者，每轮每服务泄漏一份。

异常归类：refused/connection 类 → 无响应，其余（含超时、DNS 失败等）→ 超时。
原 timeout 正则与 else 同归 '超时'，是死分支——此处折叠。

有运行中服务按 ProbeIntervalMs 轮询；全停止时拉长到 ProbeIdleMs——省下空转的
唤醒与整轮 Get-Service/TCP 扫描（服务数为 0 时 $toProbe 为空，整轮只做一次快照）。
除「有运行中服务」外，「本轮执行过命令」也算活跃：刚下发的启动命令那一轮里服务通常还
是 Stopped/StartPending（$toProbe 为空），若按空闲走 15s 长睡眠，卡片会停在「启动中」
最长约 15 秒才收到第一份探测结果。有在途命令时用短间隔，让回执与状态尽快收敛。
第三种活跃情形：有服务停在过渡态（$pendingSeen）——慢启动期间整轮
没有可探测项，若不特殊处理，卡片上的「启动中」要 15 秒才更新一次，过渡计时也迟迟不刷新。

有服务停在中间态 → 用更短的间隔，让「启动中 → 运行中」这类翻转在 1 秒内可见；
否则退到常规节奏。中间态时也照常探测运行中的服务（代价是本地回环 TCP/HTTP，可忽略）。

## svc-common.ps1

### Get-ScExe

sc.exe 的路径必须解析后调用：裸调一个不存在的命令时 $LASTEXITCODE 保留上一条的码，
而下面几个判据都从退出码读结论（本机 System32 一度不在 PATH，实测会误判）。
每次调用时才解析，便于注入：测试夹具经 $sync.scExe 给替身名。
盘上找不到就退回裸名——让「找不到」如实报错，而不是悄悄用一个不存在的路径。

### Invoke-ExternalQuiet

跑外部控制台程序但**不弹窗口**，返回 @{ exit; out }。GUI 进程直接 `& sc.exe` / `& nssm.exe`
会开出控制台窗口（实测：点启动约 30s 后冒黑框）。注入成函数名时直接调用，保留测试缝。

### Wait-Stopped

轮询服务到 Stopped，用于重启/删除前等端口释放。
超时取值：$sync 注入值（UI 线程与 runspace 同键）> $script:config.WaitStoppedTimeoutMs > 6000。
前两级在两条路径上都可见，故 UI 线程与 runspace 走同一份配置，不再各读各的。
服务已不存在（ObjectNotFound）= 等同已停止；其他错误（权限等）不掩盖，继续等待。

### Convert-ScExitCode

sc.exe / NSSM 退出码 → 中文文案（单一映射源）。
放这里而不是 poll.ps1：poll.ps1 的函数体在 here-string 里，只进 runspace——UI 线程
与 CLI 都看不到。CLI（add-svc.ps1）要报「启动失败(1053 服务进程无法启动）」就得有
同一份映射，否则同一个退出码在 GUI 与 CLI 给出不同粒度（GUI 中文、CLI 裸数字）。
本文件是 UI 线程（add-svc 直接点源）与 runspace（poll 前置其文本）共用的唯一原语，
映射放这里两条路径都拿得到，且只有一份实现。
常见码：1056=已在运行 / 1062=未启动 / 1060=未安装 / 1051=禁止启动 / 1053=进程起不来。
5=拒绝访问：非管理员调 sc.exe start <已运行服务> 实测返回 5（不是 1056，管理员下才是）。

### Invoke-ServiceRemove

删除序列：stop → 等 Stopped → nssm remove confirm → 实证复核是否真消失。
放在本文件是因为 poll.ps1 会前置它的文本，UI 线程与 runspace 共用同一份判定；
只共用「判定」不共用「呈现」——返回结果对象，由调用方决定抛错还是入 msg 队列。
$nssmExe 必须传参——runspace 里 $script:nssm 不可见（NSSM 路径经 $sync.nssm 从 UI 传入）。

退出码**不可信**：不非零只能说明「没报错」，不能说「删掉了」——故下面还要实证复核。
非零时不再查 Test-ServiceGone：命令根本没成功，服务必然还在，再查一次反而可能
因权限类错误把原因说成「服务仍存在」，掩盖真正的原因（退出码）。

实测（2026-10-05，NSSM 2.24-103-gdee49fc）：提权不足或服务不存在时，nssm remove/install
打印「Administrator access is needed to ...」却返回 **0**。只信退出码会把「删失败」判成功
——UI 清掉卡片并落盘，而服务仍在：用户以为删了、配置却丢了。

### Get-ServiceQueryCode

sc.exe query 的退出码——删除/注册复核共用的**底层原语**（两个谓词只解释码，不重抄调用）。
0 = 服务存在；1060 = 不存在；1072 = 已标记删除（句柄未全关，内核里已在消失路径上）。
非管理员也能 query（实测）。

### Test-ServiceGone

服务是否已从 SCM 消失——删除操作的**最终判据**，不能只信 nssm remove 的退出码。
实测（2026-10-05，NSSM 2.24-103-gdee49fc）：提权不足或服务不存在时，nssm remove/install
打印「Administrator access is needed to ...」却返回 **0**；其余动作（stop/start/restart）
失败返回 3、set/reset 返回 1。把删除成败押在这样一个退出码上，会出现「删失败被判成功」
——UI 清掉卡片并落盘，而服务仍在：用户以为删了、配置却丢了。
只认「明确消失」的两个码：其它（含权限类错误）不当已消失——宁可判失败，也不冤判成功。

### Test-ServicePresent

服务是否已在 SCM 中——install 后的复核判据（与 Test-ServiceGone 同一实证思路：
nssm install 失败也返回 0，见上）。
带重试：刚 install 完紧接着 query，SCM 一般已可见，但边界性延迟会把一次成功的注册
误判成失败（假阴性），而调用方会据此抛错。宁可多等几百毫秒。

## service-manager-gui.ps1（主脚本）

### 文件头 / 启动路径

六卡片主视图 · 系统字体 · 双击防抖(8s+健康门闩) · 无黑窗口 · 托盘可选(config.TrayEnabled)。

### 互斥名与 NSSM 探测

单实例互斥名（GUI 占用 + CLI -Add 前检测是否已有 GUI 常驻）。定义在此供两处共用，
避免 CLI 分支与 GUI 分支各写一份字符串而漂移。

NSSM 探测：优先 env > Get-Command > scoop 安装路径，避免硬编码 scoop。
NSSM_PATH 只做「存在 + 文件名是 nssm.exe」两项校验，不校验签名/路径——它随后会以管理员
身份被调用（install/set/remove），只做 Test-Path 会让「指向任意 exe」直接以管理员运行。
文件名校验挡住最直接的滥用，又不破坏 README 明写的「自备 NSSM 后设 NSSM_PATH」用法。

### config 的最先加载与日志根

可调常量最先加载——$logDir 与 Write-CrashLog 都依赖 config（前者取 LogDir 覆盖，
后者取 CrashLogMaxBytes）。Write-CrashLog 首次调用在提权检测处，早于模块加载区，
不提前就会读到未初始化的 $script:config。

日志根：默认仓内 logs/，可用 config.json 的 LogDir 覆盖。
注意：改 LogDir 只影响**新注册**的服务——已注册服务的 AppStdout/AppStderr 写死在
注册表 HKLM\...\Services\<名>\Parameters 里，仍会写旧路径，而本工具按新 LogDir 读，
那些服务的日志窗口会变「无日志」。迁移须逐个重新注册（改 AppStdout/AppStderr）。

### CLI -Add 分支

CLI -Add 与 GUI 都全量写回 services.json（Save-Svc 无合并语义，见 PROJECT.md 决策 3）。
若 GUI 常驻，它的内存副本是启动时读的；CLI 加完服务后 GUI 下一次保存会把这条覆盖掉
——NSSM 服务仍在跑，但配置里没了、界面也不显示。故 GUI 在跑时拒绝 CLI 写入，让调用方
改用 GUI「添加」或先关 GUI。判据见 util.ps1 的 Test-GuiInstanceRunning。

services.json 解析失败时 Load-Svc 会回落到 services.example.json。GUI 有弹框，CLI 没有——
若继续执行，Add-SvcFromCli 末尾的 Save-Svc 会把**示例清单 + 新服务**写回真实文件，
用户的真实条目整份消失，而且退出码还是 0。宁可拒绝执行。
只认 Load-Svc 的专用标志：config.json 坏了按设计不阻断（用默认值），不该连 -Add 一起拦。

### 单实例互斥

Mutex 是进程级的，进程退出 OS 自动释放，不会卡死。放在 Add-Type 之后是因为
命中时要静默退出（不弹窗，重复双击是常见操作）；放在提权之后是为了只让管理员实例占锁。
AbandonedMutexException：前一个实例被任务管理器杀掉或崩溃时，OS 把所有权
交给当前进程并抛此异常——不是失败，要当成"已获取"，否则第二个实例也起不来。

### 模块加载顺序

顺序即依赖：theme → util → svc-input → nssm → add-svc → logview → dialogs → tray →
poll → card → xaml。dialogs 与 card 双向依赖，顺序不分先后（函数体符号调用时解析）。

### Invoke-LogCleanup

日志清理：读 config 的保留策略并包住异常。两处调用（窗口关闭、首帧后）共用——
策略取值只此一处，改保留口径不必翻调用点。$label 区分日志里的触发时机。
除了工具自己的 $logDir，还要清理每个服务**实际**的日志目录（读 AppStdout）。
手工 nssm 注册的服务日志在别处，只清 $logDir 等于没管它们。

### 配置提示

configWarning 由 config.ps1（"config.json 无效：…"）或 Load-Svc（"services.json 无效：…"）
写入，**消息自带文件名**——故此处只加「当前使用恢复配置」的处置说明，不再拼文件名前缀
（否则会显示成「配置文件无效：config.json 无效：…」这种重复）。

配置提示（非致命）：目前唯一的来源是 services.json 里 per-service 可选字段写错
（toggleTimeoutMs / httpTimeoutMs / tcpTimeoutMs）。清单照常用，只是那个字段回落全局，
所以单独一条、措辞里不讲「恢复配置」——否则用户会以为整份清单被换掉了。

### ContentRendered 的日志清理

启动首帧后异步跑一次日志清理（不占首屏）。走 Dispatcher.BeginInvoke + Background 优先级，
避免在 ContentRendered 回调里阻塞渲染。
优先级必须写成枚举，不能写 'Background' 字符串：Dispatcher 没有 (Delegate, DispatcherPriority)
这个重载，PowerShell 会退回绑定 BeginInvoke(Delegate, Object[] args)，把字符串当成
委托的实参数组——委托在 UI 线程被以 1 个参数调用，抛 TargetParameterCountException，
清理永远不执行（曾记在 gui-crash.log 的 DispatcherUnhandled 里）。

## dialogs.ps1

### Submit-RemoveCommand

删除提交体（Show-Remove 的 del_Click 真正执行的部分）。抽出来是为了可直测：
弹模态框的 Click 在测试里够不着，但「入队 remove 命令 + 置卡片过渡态」这段才是会写错的
地方（曾因两处字段集不一致漏了 LastToggle/ReadyToToggle，配合 Update-CardData 守卫缺失
导致删除中卡片被探测结果刷回「已停止」）。

### Submit-AddService

添加提交体（Show-Add 的 ok_Click 执行的部分），$fields 各值已 trim。
返回 $true = 关弹窗（注册成功，或成功但保存失败）；$false = 被拦下，弹窗保持打开。
抽出来是为了可直测（原先全内联在 Click 里，没有测试缝）。

### New-AddDialog

只搭窗口、不 ShowDialog：给测试留缝。模态框在测试里打不开，但控件搭错、属性名写错
会在这里当场抛——那类错误在生产里表现为「点『添加服务』没反应」，冒烟测试比读代码可靠。
返回几个控件句柄，供测试断言账户下拉的选项与默认项。

运行账户：列表来自 svc-input.ps1 的 $script:SvcAccounts（白名单与下拉同一份）。
三个都是内置账户、都不需要密码，故本对话框不碰任何凭据。
默认 LocalSystem 就是 nssm install 建出来的账户，选它等于不改。

两个处理器必须 .GetNewClosure()：PowerShell 脚本块**不是闭包**（同 xaml.ps1 的
$script:toggleMax、logview.ps1 的 $load 那两处），变量在**点击时**按调用点动态解析。
New-AddDialog 返回后它的局部作用域就没了，不建闭包的话 $f / $inName 全是 $null ——
点「注册并启动」抛 null-valued 异常，Submit-AddService 一次都进不去，界面表现为点了没反应。

提交逻辑抽到 Submit-AddService 以便直测（校验顺序、Test-EnvPairs、敏感键 OKCancel
分支、Save 失败分支原本全内联在 Click 里，没有测试缝）。$f 作 owner 供 MessageBox 用。
返回 $true 表示注册成功（调用方据此关弹窗）。

### Show-Add

GUI 添加服务对话框：3 必填 + 高级折叠，注册成功后入队启动命令
Owner 只在这里设：WPF 要求 Owner 必须是**已经显示过**的窗口，放进 New-AddDialog 会让
无头构造（测试）直接抛「无法将 Owner 属性设置为之前未显示的 Window」。

## logview.ps1

### Get-LogFiles

枚举当前 + 轮转日志：out/err 是当前，out-YYYYMMDDHHMMSS.log / err-*.log 是轮转
服务名允许含 . 与 -（Test-SvcInput 的 [A-Za-z0-9_.-]），正则里这些是元字符——
必须先 [regex]::Escape 再插，否则 "My.Service" 的 . 会匹配任意字符，跨服务串台。
参数名必须是 $LogPath 不能是 $LogDir：PowerShell 变量名大小写不敏感，参数一旦叫
$LogDir 就会遮蔽同名（不区分大小写）的外层 $logDir，下面那句回落变成自己赋给自己，
GUI 的单参调用永远拿到 $null。改名后回落才能经动态作用域读到调用方的 $logDir。

不给路径时用该服务**实际**的日志目录（读注册表 AppStdout），而不是一律用 $logDir：
手工 nssm 注册的服务（如 ComfyUI）日志在别处，用 $logDir 会显示「无日志」。
Get-SvcLogDir 内部已处理读不到时回落 $logDir 的情形。

### Show-Log

日志查看器（闭包 hashtable 持久切换状态）。
发现 5：除当前 .out.log / .err.log 外，加轮转历史下拉（nssm AppRotateFiles 产生的
.out-*.log / .err-*.log）。22 个轮转文件此前在 GUI 中不可见。

## svc-input.ps1

### Test-SvcInput

CLI 与 GUI 共用的输入校验。通过返回 $null，否则返回 @{code; msg}。
code ∈ name|exe|port|dup。GUI 的端口文案与 CLI 不同，调用方按 code 自行覆盖 msg。
调用顺序与两处原逻辑一致（名称 → 可执行文件 → 端口 → 重名），保持报错优先级不变。

拒绝纯 `.` / `..`：它们作为路径段会被归一化（`Services\..` → `Services` 父键），
拼进注册表路径 `...\Services\<名>\Parameters` 时会指到祖先键，脚本可能收紧错的键。
点开头/含点但非纯点段的名字（`.hidden` / `A..B`）合法，放行。

### ConvertTo-EnvPairs

按分隔符切分 env 字符串为去空白的非空项。CLI 用 ';'，GUI 用 ','。
**只在「下一段以 KEY= 开头」时才真断开**：值本身可能含分隔符，最典型的是
NO_PROXY=127.0.0.1,localhost——原实现无脑 split，逗号把值拆成两段，Test-EnvPairs 随即
报「localhost 格式错误」，GUI 里根本填不进多地址 NO_PROXY。
「像新变量」的判据就是**这一段里有 `=`**——不能收紧成 `^[A-Za-z_]\w*=`：合法的 Windows
变量名可以数字开头（2FA_TOKEN），也可以带括号（ProgramFiles(x86)），收紧会把它们并进上一个值，
变量根本不进 AppEnvironmentExtra，连敏感键检测也扫不到。
也不能要求 `=` 前无空白：`B = 2` 是合法的 env 写法（Test-EnvPairs 会 Trim）。
反例（有意不处理）：值里出现形如 x=1 的片段（如 URL 查询串）会被当成新变量。

### Find-SensitiveEnvKeys

扫 env 项里的敏感键名（GUI/CLI 共用，提示性，不阻断）。返回命中项的键名列表，无则空。
命中 *_API_KEY / *_TOKEN / *SECRET / *PASSWORD / *ACCESS_KEY / *CREDENTIAL /
*PRIVATE_KEY / *PASSPHRASE 等键名时，值会随 NSSM AppEnvironmentExtra
明文进注册表 HKLM\...\Parameters，该键 ACL 默认 BUILTIN\Users 可读——本机标准用户能读出。
*_FILE 后缀本意是「让服务本体从独立密钥文件读，路径不进注册表」——但仅在值看起来像路径时
才跳过；否则视为有人把真密钥塞进了 *_FILE 变量，照样提示（键名后缀不等于值就是路径）。

键名形态清单：常见密钥/令牌/口令变量名。刻意不收裸 KEY——会误报 MONKEY 这类词。
单独的 PASS 用 (^|[_-])PASS([_-]|$) 匹配 DB_PASS / REDIS_PASS——**不能**用 \bPASS\b：
下划线是 \w，DB_PASS 的 _P 之间没有词边界，\bPASS\b 实测对 DB_PASS 返回 False。
APIKEY / PRIVATEKEY 无下划线；*_AUTH / *_SALT / *_PAT / *_WEBHOOK 是常见凭证后缀。

### SvcAccounts

运行账户白名单：只有三个内置账户。它们不需要密码——nssm 按 well-known SID 认出来
（account.cpp 的 well_known_username → password 强制空串），所以一条 argv 就能设。
自定义用户账户**故意不支持**：nssm 要求密码，而密码只能作为命令行参数传，
同机管理员在进程列表里可见；本工具不引入这个暴露面。需要时用 nssm edit 或服务管理器改。
空串 = 不改，沿用 nssm install 的默认（LocalSystem）。
对话框的账户下拉直接从这里建（Label 给用户看，Key 传给 nssm）——两处各存一份列表时，
加一个账户就得改两边，迟早只剩一边被改。

### Get-NssmSetSpec

NSSM 注册后需要 set 的键值序列（不含 install 与失败回滚）。抽出来是为可单测参数组合：
AppExit 双 token、AppEnvironmentExtra 多 token 这类容易被展开方式搞错的地方。
$rotateBytes / $stopMethodMs 由调用方从 config 传入（默认值与 config.ps1 的
AppRotateBytes / AppStopMethodConsole 一致）——本文件保持纯函数，不读 $script:config，
单独点源即可测（不加载 WPF / config）。

## nssm.ps1

### 文件头 · 作用域约定

读调用方的 $script:nssm（NSSM exe 路径）与 $logDir（日志目录，
Install-NssmService 经 Get-NssmSetSpec 拼日志路径）。两者由 service-manager-gui.ps1
或测试夹具在 dot-source 之后赋值。

自加载依赖：Get-NssmSetSpec（svc-input.ps1）、Wait-Stopped（svc-common.ps1）——
本文件单独点源也能工作，不必依赖调用方先加载。两个依赖文件均无反向依赖，无循环。

### Install-NssmService

install 的退出码同样不可信（实测：提权不足时打印 "Administrator access is needed"
却返回 0）。若真没装上，后续 set 会全挂，报出的却是 set 的错——误导排查方向。
以「服务是否真出现」复核一次，失败即抛，错误信息直指根因。

install 成功后服务已进服务数据库；任意 set 失败都会留下配置不全的半注册残骸
（无日志重定向/轮转/AppExit）。失败时尽力 remove 回滚，再抛原始错误。
日志轮转阈值与停止收尾毫秒从 config 取（默认值与 svc-input.ps1 的形参默认值一致）。
config 可能未加载（单独点源本模块时）——用 $null 判断回落，不靠 [int]$null=0。

轮转年龄门槛：不设的话「每次启动轮转一次」会把频繁重启的服务的日志堆成几十个档。

### Remove-NssmService

删除 NSSM 服务（同步、失败抛异常）。序列本体在 svc-common.ps1 的 Invoke-ServiceRemove，
与 runspace 共用一份文本。**无生产调用方是有意保留**：它是那条序列的单测入口
（tests/test-add-svc.ps1），也是将来 CLI 加 -Remove 的出口——死代码扫描请勿删。

## add-svc.ps1

### Add-SvcFromCli

CLI 模式：解析逗号分隔参数，注册 NSSM 服务并启动，不弹 GUI
用法：-Add Name,Port,Exe[,Url|tcp,Dir,Args,Env]
  第 4 段写 tcp 是简写：等价于 probe=tcp 且 url 为空（数据库/gRPC/纯 socket 不走 HTTP 探测）
  Env 多对用分号分隔：KEY=VAL;KEY2=VAL2；逗号分隔也认（只在 KEY= 处断开，值里的逗号不算）

Env：第 7 段往后全部属于 Env（Args 可能含逗号的情况不处理——Args 不应含逗号）
多对 env 优先用分号分隔；逗号分隔也认，因为 ConvertTo-EnvPairs 只在 KEY= 处真断开，
值里的逗号不会被当成下一对。

sc.exe start 失败返回非零（实测：5 拒绝访问 / 1051 被禁用 / 1053 进程起不来）。
注册本身是成功的，故不回滚、也不 exit 1——但绝不能报「已启动」：这个 CLI 是给
agent 用的，谎报成功会让调用方以为服务在跑。如实说清，并指出去哪儿看真实状态。
文案经 Convert-ScExitCode 映射（与 GUI 同一份，定义在 svc-common.ps1，本文件末尾
点源；函数体内符号是调用时解析，故此处可用）——裸退出码要让 agent 自己查表才知道
能不能重试。

### 文件头 · 自加载

纯函数族与 NSSM 注册/删除已抽去各自文件——本文件自加载，保证 CLI 模式
（service-manager-gui.ps1 -Add 分支只点源 util.ps1 + add-svc.ps1）拿得到全部依赖：
svc-input.ps1（Test-SvcInput 等）→ nssm.ps1（Install-NssmService，其内部又用
svc-input.ps1 的 Get-NssmSetSpec）→ svc-common.ps1（Wait-Stopped）。

## xaml.ps1

### New-MainWindow

最大化/还原共用一个切换（按钮与双击标题栏同逻辑）。
必须存 $script: —— New-MainWindow return 后局部变量脱作用域，
双击标题栏处理器里的 & $script:toggleMax 才能解析到（PowerShell scriptblock 非闭包）。

## theme.ps1

### Set-Backdrop

---- Mica 玻璃背景：DwmSetWindowAttribute(DWMWA_SYSTEMBACKDROP_TYPE) ----
官方 API（Win11 22000+），比 SetWindowCompositionAttribute 稳
type: 2=Mica(主窗口) 3=Acrylic(瞬时) 4=TabbedMica

## tray.ps1

无 3 行以上注释块（文件头按约定不搬；决策与副作用分离的说明压缩进文件头两行）。

## config.ps1

### ToggleTimeoutMs

卡片过渡态超时逃生（card.ps1 Test-TransitionTimedOut）：回执丢失时
按到达的探测值收敛并解封按钮，防永久卡住。启动失败回落路径已实测
30.0s（ServicesPipeTimeout），故 45000 留 15s 余量。
测法见 tests/probe-1053-timing.ps1；不能用「exe 路径不存在」造场景
（那条路 SCM 立刻返回 2，15ms 就结束，走不到管道等待）。

### LogKeepCount

轮转日志保留份数（util.ps1 Remove-RotatedLogs）——
口径是**按日志目录**各留前 N 份：共用 $logDir 的服务算一个目录，
有独立 AppStdout 目录的服务（如 ComfyUI）各算一份配额

### ProbePendingMs

有服务处于 StartPending/StopPending 时的轮询间隔——
查状态是廉价查询，没必要跟着 4s 的健康探测节奏，
否则「启动中」最多要 4 秒才翻成「运行中」

### AppRotateSeconds

文件「太新」就不轮转的年龄门槛（NSSM AppRotateSeconds，默认 1 天）——
AppRotateFiles=1 会在**每次服务启动**时轮转一次：频繁重启的服务
一天能堆几十个档（本机 ComfyUI 重启 18 次 → 37 个）。设了年龄门槛后
每个文件至少活 1 天才允许被轮转，堆积速度立刻降下来。

### config 加载

配置解析失败不阻断启动——用默认值。错误记进 configWarning，由 GUI 加载完成后弹框。
消息格式与 Load-Svc 的 `"services.json 无效：…"` 统一为 `<文件名> 无效：<原因>`：
弹框判断不了来源，文件名只能由写入方带。本变量不带处置语（弹框自己补）。
注：Load-Svc 的 services.json 分支无条件覆盖本变量，只有读示例清单的兜底分支带守卫。

## 2026-10-29 复审后的实现变更

### 命令执行异常不再终结轮询（poll.ps1）

`Invoke-PendingCommands` 的 switch 体包了 try/catch：任何一条命令抛终止性异常时，
记一条失败消息、`$ok=$false`，照常产出回执。修前异常穿透到主循环，runspace 直接结束——
之后探测与命令全部停摆，卡片冻结在最后一帧，状态栏却还在打「状态自动刷新」。

### 外部命令超时（svc-common.ps1）

`Invoke-ExternalQuiet` 改成异步读 + `WaitForExit($timeoutMs)` + `Kill($entireProcessTree)`，
超时返回 `exit=-1`。超时值来自 `$sync.extCommandTimeoutMs`（config 的 `ExtCommandTimeoutMs`，
默认 60000）。修前 `ReadToEnd()` 同步阻塞，`sc.exe` / `nssm.exe` 卡住时后台永久死亡，
连异常都没有。取结果本身也给了 2 秒上界：`WaitForExit` 只等进程退出、不等管道 EOF，
孙进程继承了 stdout 句柄时 `.Result` 仍会一直等。

### 清单解析失败时拒绝写盘（util.ps1）

`Save-Svc` 开头判 `$script:svcLoadFailed`，为真直接抛。修前只有 CLI 分支有门闩，
GUI 在清单解析失败后点一次增删，就把「示例清单 + 新服务」写回真实文件——当时 `File.Replace`
不带备份、services.json 又不在 git 里，覆盖后无法恢复（2026-10-30 起有 `.bak` + 载入后 mtime 拒写）。

### 配置覆盖值按类型校验（config.ps1）

覆盖时按默认值的类型 `TryParse`，失败保留默认并追加一条 `configNotices`。
修前原样赋值：`"TcpTimeoutMs": "200ms"` 会一路传到主脚本的 `[int]` 强转，
在 `$ErrorActionPreference='Stop'` 下抛 RuntimeException，窗口根本不出现。

2026-10-30 补区间：`$script:configRanges` 表给每个数值键 `min..max`。`TryParse` 只证明「是整数」，
`TcpTimeoutMs: -1` 会让 `WaitOne` / `CancellationTokenSource` 变成无限等待（后台 runspace
从此不返回），`PerPage: 0` 会让分页做除零（窗口起不来，只留一行 crash log）。
未知键也从静默忽略改成提示——拼错 `TcpTimeout` 时原来毫无反馈。

### 健康口径 auto / tcp（poll.ps1 + util.ps1）

`services.json` 每服务可选 `probe`: `auto`（缺省）/ `tcp` / `http`。`tcp` 或 `url` 为空时
TCP 通即「正常」，不发 HTTP；其余照旧 TCP 通后 `GET url` 要 200。

修前只有 HTTP 一条路，非 HTTP 服务（数据库、gRPC、纯 socket 守护）永远不是绿点；更糟的是
`Test-CardCanStop` 当时把健康一起判进去，这类服务的「关闭」按钮被永久禁用，只剩右键菜单。
现在按钮只看状态，健康只影响双击（误关保护），`Invoke-CardAction` 的 `$detailed` 分支负责。

### 路径形态校验（svc-input.ps1）

`Test-SvcInput` 拒三种：UNC（`^[\\/]{2}`，**正斜杠写法同样算**——`//localhost/C$/...`
经 `Test-Path` 是 true，只认反斜杠会被绕过）、drive-relative（`C:foo.exe`，
`IsPathRooted` 说 true 但它相对的是 C: 盘当前目录）、非文件（`-PathType Leaf`，
`Test-Path` 对目录也返回 true）。UNC 注册成 LocalSystem 服务后，共享写者即可在本机拿到 SYSTEM。

### 面板地址只放行 http/https（util.ps1）

`Open-PanelUrl` 对非 http/https 只更新状态栏、不启动。修前直接 `Start-Process` 任意 URI，
`file:///` 或自定义协议在提权 GUI 下等于以管理员**执行**任意程序，不只是「打开网页」。

### 轮转档正则锚到结尾（util.ps1）

`'\.(out|err)-\d{8}(T\d{6}\.\d{3})?$'`。修前不锚定，服务名本身含 `.err-20260101` 时，
当前日志 `MySvc.err-20260101.out.log` 也会命中，服务停着时当前日志被真删。

### 后台死亡检测（util.ps1）

每帧判 `$script:bgHandle.IsCompleted`，完成即写 crash log、状态栏提示「后台已停止响应，
请重启工具」、把仍停在「查询中」的卡片收敛到「未知」，并让自动刷新不再覆盖这条提示——
否则 5 秒租约一过又变回「状态自动刷新」，正是这条提示要纠正的错觉。

### 失败回执按 epoch 判归属（card.ps1）

见上文 Update-CardData。判据从「卡片有没有 TransitionAt」改成 `$e -ne $c.PendingEpoch`。

### 卡片等待中 / 无响应（card.ps1）

运行中但健康探测不通过时显示「等待中」+ 橙点；累计超过 `WaitHealthyTimeoutMs`
（默认 120 秒）升级为「无响应」+ 红点。累计起点 `UnhealthySince` 在离开运行中、
进过渡态、失败回滚时立即清零；恢复健康要**连续两次**探测正常（`HealthyStreak`）——
否则一次抖动就把累计打断，服务明明一直不响应也永远升不到「无响应」，颜色还会在
「等待中」和「运行中」之间闪。墙钟回拨按 0 处理。

### 关闭窗口不再等后台（主脚本）

`Stop-Background` 用 `BeginStop` 代替 `Stop`。`Stop()` 是同步的，后台卡在 `$svc.Start()`
（等满 ServicesPipeTimeout ≈ 30 秒）时会拖住 UI 线程；这段时间进程仍占着 mutex，
用户再双击图标是「没反应」。
