# CHANGELOG.md — service-manager 迭代记录

> 本文件记录每次迭代的「为什么改」与「改了什么」，不重复 commit message（那是 git log 的事）。
> 代码是行为真相，本文件是**阶段性脉络**——读完能看懂这工具怎么走到今天。

## [未发布]

### 2026-10-30：独立复审后的三项止血（健康口径 / 配置区间 / 清单写入）

- **健康口径只有 HTTP 是个设计漏洞**：TCP 通后无条件 `GetAsync`，非 HTTP 服务（数据库、gRPC、
  纯 socket）永远不是绿点。更糟的是 `Test-CardCanStop` 把健康一起判进去，这类服务的「关闭」按钮
  被永久禁用，只剩右键菜单能用。现在清单支持 `"probe": "auto"|"tcp"|"http"`（缺省 `auto`），
  `tcp` 或 `url` 为空时 TCP 通即「正常」；健康门闩只保留在双击路径，按钮只看服务状态。
  README 那句「关闭只在运行中可点」原来与代码不符，一并改正。
- **`config.json` 只校验「是不是整数」不够**：`TcpTimeoutMs: -1` 会让 `WaitOne` / `CTS` 变成
  无限等待（后台 runspace 从此不返回，界面状态永不刷新），`PerPage: 0` 会让分页做除零
  （窗口根本起不来，只留一行 crash log）。改成表驱动的区间校验，越界回落默认值 + 弹提示；
  未知键也从静默忽略改为提示（拼错 `TcpTimeout` 少个 Ms 时原来毫无反馈）。
- **`services.json` 的写入门闩补齐**：顶层是 `[]` / `"x"` 这类合法 JSON 时，`Read-SvcFile`
  取不到 `.Keys`，旧实现返回空清单且当成功——用户看到 0 张卡，下一次保存把原文件覆盖成 `{}`。
  现在顶层形状不对直接抛（走既有的 `svcLoadFailed` 拒写路径）；另外写前比对 mtime，载入后
  被外部改过就拒写，并把上一版留成 `services.json.bak`（这文件不在 git 里，没备份等于没回滚）。
- **其它**：对话框里端口非数字不再抛异常（改成 `TryParse` + 错误框，原来异常只写状态栏、
  被模态窗盖住 = 点了没反应）；删除按钮的提交加了 try/catch，失败不关窗；日志查看器只读
  尾部 256 KiB（原来在 UI 线程整文件读，NSSM 日志没有上限），且读失败显示原因而不是静默；
  轮转日志清理从「只在启动/关闭跑」改成常驻期间每 6 小时一次；`run-all.ps1` 改通配收集
  `test-*.ps1` 并要求每个用例至少一行 `PASS:`（防「零断言但退出码 0」静默变绿）；
  `.gitignore` 补上 `services.json.bak*` 等备份文件。
- **清单热重载（F5）**：mtime 门闩原本只把用户挡在「关闭重开 GUI」这一步，现在补上出口——
  每次 400ms tick 做一次 stat，发现外部改动就在状态栏提示一次；按 F5 重新读清单，复用已有卡片
  （健康值/冷却/过渡态不丢），只增删差异。有在途命令（启动中/停止中/删除中）时拒绝重载：
  回执会落在不存在的卡上，而删除成功路径还会把旧内存清单写回磁盘。坏清单同样拒绝，
  原清单保持不变。
- **健康历史**：状态或健康值变化时落一条 `logs/health/health-YYYYMMDD.ndjson`（NDJSON，留 30 天），
  右键卡片「健康历史」看最近 200 条。写入放在后台 runspace——UI 线程只把事件塞进 `$sync.healthQ`，
  探测循环顺手写盘；`HealthHistory=false` 时队列为 `$null`，后台整段跳过。
  只记变化不记心跳：4 秒一拍全记就是一天几万行噪声，而「最近一次异常是什么时候」只需要变化点。
- **批量启停**：状态栏汇总标签右键 →「全部启动 / 全部停止」。目标取 `$script:svcState`（每轮探测
  结果全量记录，不只当前页），只处理「已停止 / 运行中」两种终态——启动中/停止中/暂停/未安装都不碰，
  避免和手动命令打架；停止前弹一次 OKCancel。有卡片的服务顺手置过渡态（省一个探测周期的滞后），
  没卡片的靠探测收敛。只做启停：日志、删除这类动作不进批量。
- **只读 Web 视图**（`WebView`，默认关）：独立 runspace 里跑一个 `TcpListener`，只听 `127.0.0.1`、
  只接受 `GET`、必须带 `?t=<128 位随机 token>`（状态栏给一次），没有任何写入口。用 TcpListener
  而不是 `HttpListener`：后者在非管理员下注册 URL 前缀要走 `netsh urlacl`，便携运行与测试都多一道坑；
  代价是只支持 GET——正好是这个视图的全部需求。局域网访问走 SSH 端口转发，不监听外部网卡。

### 2026-10-29：卡片状态显示与按钮尺寸

- 服务进程在、但健康探测还没通过（冷启动、端口未监听、HTTP 超时）时，状态标签从
  「运行中」+ 红点改为「等待中」+ 橙点，副标题前缀从「已运行」改为「已等待」。
  「运行中」这个词会让人以为服务已经可用，配一个红点更自相矛盾。
- 等太久（`WaitHealthyTimeoutMs`，默认 120 秒）后升级为「无响应」+ 红点——这时候已经不是
  「还在启动」，是服务卡住了。累计起点 `UnhealthySince` 在离开「运行中」、进过渡态、
  失败回滚时立即清零；恢复健康则要**连续两次**探测正常（`HealthyStreak`）才清零——
  否则一次探测抖动就把累计打断，服务明明一直不响应也永远升不到「无响应」，颜色还会
  在「等待中」和「运行中」之间闪。墙钟回拨按 0 处理。
- 「关闭」和「启动」两个按钮改为同尺寸（`MinWidth` 82、`Padding` 14,6）。它们是对等的
  两个方向，原来 72/82 的差会让「关闭」看起来比「启动」轻。

### 2026-10-29：注释搬迁 + 复审修 13 条

**精简**：`lib/` 与主脚本从 2492 行起步。注释搬迁让代码降到 2118 行；随后的复审修复又加回
约 150 行（try/catch、超时、类型校验、状态判定这些省不掉），最终 2268 行。
做法是把长段「为什么」注释搬进 `docs/IMPLEMENTATION-NOTES.md`，代码里只留一行结论或
`§小节名` 指针；另有 26 行是死代码与重复赋值。仓库没有可再砍的结构性余量——
117 个函数零死代码，剩下的注释都是踩坑记录。

**复审修的问题**（行为类都有回归测试；mutex、按钮尺寸、ACL 提示这类静态改动没有）：

- 后台单条命令抛异常会终结整个轮询循环 → switch 包 try/catch，异常也发失败回执
- `services.json` 解析失败后 GUI 仍全量写回，把真实配置覆盖成示例 → `Save-Svc` 加门闩
- `config.json` 写 `"TcpTimeoutMs": "200ms"` 让 GUI 根本打不开 → 覆盖时按默认值类型校验
- 轮转日志正则未锚定，会删掉**当前**日志 → 锚到结尾并容纳 NSSM 的 `T…` 时间戳格式
- 外部命令无超时，一次挂住后台永久死亡 → 异步读 + `WaitForExit(timeout)` + Kill
- 双击停止后右键启动失败，把别人的过渡态回滚成「运行中」→ 失败回执按 epoch 判归属
- `Open-PanelUrl` 在提权进程里执行任意 URI → 只放行 http/https
- 单实例 mutex 用 `Local\`，跨会话不互斥 → 改 `Global\`
- exe 校验接受 UNC / 目录 / 相对路径 → 三条都拒
- 白名单外的配置键被静默抹掉 → 收集成提示
- 时钟回拨导致过渡态永久卡死 → 判不了按超时逃生
- 「未知」状态转终态不起算运行时长 → 只有「查询中」算首帧
- 后台 runspace 死亡后 UI 无提示 → 每帧检测 `IsCompleted`，提示重启

**提权面**：`launch.vbs` 的 pwsh 解析改为 Program Files 优先（scoop 目录用户可写）；
NSSM 目录 ACL 可写时在状态栏提示。**关闭流程**：`Stop-Background` 改用 `BeginStop`，
不再在 UI 线程同步等待后台管道停下。

### 2026-10-29：打开工具就开始计时

卡片上的时长原本在**首次观测**服务状态时起算（「查询中/未知 → 运行中/已停止」也算一次状态变化），
于是打开工具的瞬间就显示「已运行 3 秒」「已停 3 秒」——那个数字是从工具启动算起的，
不是服务的真实运行/停止时刻。

现在首次观测不记起算点（`StateSince` 保持 MinValue，不显示时长）；只有看到服务**真的**换过状态
（点启动后的「启动中 → 运行中」、点关闭后的「停止中 → 已停止」）才开始计时。
`test-card-clock` 补了这条断言，改回原实现会红。

### 2026-10-28：状态补全 + 实时刷新 + 启停双按钮 + 精简 1/4

- **SCM 状态补全**：`Convert-ServiceStatus` 原先把 `Paused` / `PausePending` /
  `ContinuePending` 全落到「未知」，现在分别映射为「已暂停 / 暂停中 / 继续中」。
- **实时刷新**：新增 `ProbePendingMs`（默认 1000）。有服务停在 `StartPending` /
  `StopPending` 时按 1 秒轮询，而不是跟着 4 秒的健康探测节奏——否则「启动中」最多要 4 秒
  才翻成「运行中」。
- **启停拆成两个按钮**：「关闭」在左、「启动」在右。原来是同一个按钮靠文字变化在两个方向
  之间切换，用户得读文字才知道此刻点下去会发生什么。两个方向各用各的门闩
  （`Test-CardCanStart` / `Test-CardCanStop`），可用性由 `Update-CardButtons` 一处算。
- **nssm.exe 也走隐藏执行**：`Invoke-ScQuiet` 泛化成 `Invoke-ExternalQuiet`（返回 `exit` + `out`），
  `nssm install/set/remove` 一并改走它——加服务、删服务同样会弹控制台窗口。
- **精简**：`tests/` 从 31 个文件 / 3323 行裁到 16 个文件 / 1947 行（其中 11 个是回归用例），
  只留互不重叠的核心回归
  （输入校验、CLI 注册、对话框、卡片状态机与时钟、过渡态回滚、命令队列、按服务覆盖、
  配置参数、删除流程）。注释按「只留不显然的为什么」压缩，其余叙述已在本文档留档。
  仓内全部 `.ps1`（生产 + 测试 + 探针脚本）6024 → 4656 行（−22.7%，`git ls-files` 统计）。
  **拆分看**：`tests/` 3323 → 2042（−38.6%），生产代码（`lib/` + 主脚本，不含 `scripts/`）
  2593 → 2506（−3.4%）。
  也就是说「四分之一」主要来自删重复测试与压缩注释，产品代码本身没减多少——它本来
  就只做这几件事，再砍就是删功能了。唯一的性能改动是中间态轮询：状态查询提速到 1s，
  健康探测反而按 `ProbeIntervalMs` 限流，避免被一起放大。

### 2026-10-28：点启动约 30 秒后冒出的黑窗口

### 2026-10-28：卡片显示时长 + 日志按服务实际目录走

**卡片时长**：点「启动」后卡片只写「启动中」，没有任何时间感——分不出是真在启动还是卡住了。
现在过渡态显示已用时（`正在启动… · 已 12s`），运行中显示已运行多久（`· 已运行 1分30秒`），
已停止显示停了多久。计时只在**状态变化**时重记，探测每 4 秒来一次也不会把计时清零。
顺手修了个旧的观感问题：进入过渡态时副标题还挂着上一次的「随时可以启动」，现在换成「正在启动…」。

**日志**：两处都假定日志在 `$logDir` 里，但手工 `nssm install` 的服务日志在别处——
本机 ComfyUI 指向 `D:\AI\...\logs`，于是**日志窗口显示「无日志」、保留策略也永远清不到它**。
新增 `Get-SvcLogDir`（读注册表里该服务的 `AppStdout`，读不到回落到 `$logDir`），
日志窗口与 `Remove-RotatedLogs` 都改走它。实测：`Get-LogFiles ComfyUI` 从 0 个变成 38 个。

**轮转年龄门槛**：ComfyUI 一天堆了 37 个轮转档，根因是 `AppRotateFiles=1` 会在**每次服务启动**
时轮转一次，而它今天重启了十几遍，`AppRotateBytes`/`AppRotateSeconds` 又都是 0（不限制）。
- 工具注册的服务：`Get-NssmSetSpec` 补上 `AppRotateSeconds`（新配置键，默认 86400），
  以后新注册的服务不会再每次重启留一个档。
- 已注册的 ComfyUI：管理员下 `nssm set ComfyUI AppRotateBytes 5242880` /
  `AppRotateSeconds 86400`，已生效并复核。

### 2026-10-28：点启动约 30 秒后冒出的黑窗口

现象（用户实测）：用本工具启动 ComfyUI，约 **30 秒后**弹出一个黑色控制台窗口。

根因是两条叠在一起：

1. `ServiceController.Start()` 对慢启动服务**不是**异步的——它会等满
   `ServicesPipeTimeout`（30s）再抛异常（`probe-1053-timing.ps1` 实测 30032ms；
   `poll.ps1` 里原先「异步，不等 RUNNING」的注释是错的，已订正）。
2. 抛异常后 `Invoke-ServiceStart` 无条件回落到 `sc.exe start`。而本工具是 GUI 进程，
   `& sc.exe` 会让 Windows 给这个控制台子进程开一个窗口——那就是用户看到的黑框。

修法：

- catch 里**先看真实状态**：`StartPending`/`Running` 就按启动成功返回，不回落 `sc.exe`。
  慢启动但最终成功的服务从此不再走那条路（也正是用户要的「启动成功才拉起窗口」）。
- 兜底再加一层：新增 `Invoke-ScQuiet`，`Get-ServiceQueryCode` / `Invoke-ServiceRemove` /
  `Invoke-Sc` / `Add-SvcFromCli` 四处改走它——真进程路径用 `CreateNoWindow`，
  测试注入的函数名照旧直接调用（保留测试缝）。

回归：`test-poll-commands.ps1` 新增「慢启动（Start() 抛但服务在 StartPending）按成功处理、
不回落 sc.exe」的用例；回退该判断立刻失败。

### 2026-10-28：上面那批改动的复核修正

独立复核抓到的，逐条修：

- **过渡态时长每 4 秒被清零**（中等，正好废掉这个功能的目的）：时长读的是 `TransitionAt`，
  而该字段会在每次探测报同一中间态时被刷新（那是超时逃生判据的一部分）。一个冷启动 90s 的
  服务会一直显示「已 0s」。改用 `StateSince`（只在进入状态时记一次），与超时判据解耦。
  原测试手工设 `TransitionAt`，正好绕过了这条路径——补了一条**走 `Update-CardData` 真实路径**
  的用例，回退到旧写法立刻失败。
- **`Get-SvcLogDir` 的服务名没校验**：注册表 provider **会**归一化 `..`，实测
  `Get-SvcLogDir '..\..\CurrentControlSet\Services\ComfyUI'` 真读到了 ComfyUI 的目录。
  服务名来自 `services.json`，`Read-SvcFile` 只校验端口不校验名字。已按 `Test-SvcInput` 的
  字符集把关（不合格回落 `$logDir`），并改用 `-LiteralPath`（避免 `*` 被当通配符枚举）。
  > 我先前在注释里写「provider 不归一化 `..`，不需要校验」——那是错的，当时看到的
  > `Test-Path` 为 False 是「穿越后键不存在」，不是「没归一化」。已订正。
- **保留策略口径变了但文档没跟**：`Invoke-LogCleanup` 现在按目录各调一次，每个目录留各自的
  前 N 份；`config.ps1` / `util.ps1` / README 三处仍写着「跨服务全局」。已同步。
- **测试自身两处**：`Invoke-InRunspace` 不看 `HadErrors`，子脚本的终止性错误会被静默吞掉、
  断言拿到 `$null` 反而「通过」；步骤 3 只 Dispose 持有句柄，内核对象直接销毁，走的是
  「对象已消失」分支，**从没真正触发过 `AbandonedMutexException`**。改为：HadErrors 直接抛；
  用子进程持有后退出（进程终止才是 abandoned 的真实形态），并保留一个句柄让对象活着。

### 2026-10-28：`ToggleTimeoutMs` 从「推算」改成「实测」

`45000` 这个值一直标着「按管道上限推的，没量过」。把探针修好后真跑了一遍：
`ServiceController.Start()` 30032ms、`sc.exe start` 30034ms（exit 1053），与
`ServicesPipeTimeout` 默认 30000ms 吻合。45000 留 15s 余量，够用，不用改值。

探针本身有两个 bug，不修就永远测不出东西：

1. **造错了场景**：原来用「exe 路径不存在」的服务，SCM 立刻返回 2（文件找不到），
   15~18ms 就结束，压根走不到 `ServicesPipeTimeout` 的管道等待。1053 要的是
   「进程起来了但没在 30s 内连上 SCP」——改用「存在但非服务程序」的 exe
   （`cmd.exe` 跑长 ping）后，两路径都稳定测到 ~30.0s。
2. **测量值被输出污染**：`Measure-Step` 既 `Write-Output` 一行说明又返回毫秒数，
   而调用方写的是 `$ms = Measure-Step ...`——说明行被一起收进 `$ms`，屏幕上什么都不显示，
   `[Math]::Max($msSvc,$msSc)` 也跟着失效。改用 `Write-Host`。

顺带：探针也改用 `Get-ScExe`（它此前裸调 `sc.exe`，在 System32 不在 PATH 的机器上直接跑不起来）。

### 2026-10-28：`sc.exe` 不再裸调（本机 System32 不在 PATH）

做 `ObjectName` 真机验证时，提权脚本报 `sc.exe` 无法识别。追下去不是权限问题：

```
注册表机器 PATH 含 system32 : False
用户 PATH 含 system32       : False
Get-Command sc.exe / cmd.exe / where.exe : 全空
```

工具里 4 处裸调 `sc.exe`（`Get-ServiceQueryCode` / `Invoke-ServiceRemove` / `Invoke-Sc` /
`Add-SvcFromCli` 的启动）。裸调一个不存在的命令时，PowerShell 抛 CommandNotFoundException
的同时 **`$LASTEXITCODE` 保留上一条命令的码**——而这几处正是靠退出码判「服务删没删掉、
起没起来」的实证复核，假码会把「删失败」判成成功。实测对照：

```
伪造 $LASTEXITCODE = 42 → 裸调 sc.exe → 仍为 42（假码）
                         经 Get-ScExe  → 1060（真码）
```

修法：`svc-common.ps1` 加 `Get-ScExe`，按 `$sync.scExe` / `$script:ScExe` 注入 →
`%SystemRoot%\System32\sc.exe` → 裸名兜底 三档解析；4 处调用点全改成 `& (Get-ScExe)`。
测试夹具统一注入 `scExe='sc.exe'`（替身名），runspace 夹具经 `$sync.scExe` 注入。
手工探针 `probe-1053-timing.ps1` 一并改用同一套解析——它在同一台机器上会踩同样的坑。

### 2026-10-28：收掉两条剩余风险

- **CI 补上密钥扫描**：`.github/workflows/test.yml` 新增 `secrets` 任务（`gitleaks-action`，
  `fetch-depth: 0` 扫全历史）。本地钩子要每个 clone 手动 `core.hooksPath`，也覆盖不到
  「网页直接提交 / fork 的 PR」，CI 这一层是独立的。注意它只在推送 main 或开 PR 时触发，
  功能分支推送不跑。**已在 PR #7 上首次跑通**（12s，`no leaks found`）——该 action 对个人
  仓库免费，组织仓库要 `GITLEAKS_LICENSE`。
- **`ObjectName` 单 token 形状已完成真机验证**（管理员）：`nssm install` → `nssm set <svc>
  ObjectName "NT AUTHORITY\LocalService"` 返回 0 → `sc.exe qc` 读到
  `SERVICE_START_NAME : NT Authority\LocalService` → `nssm remove` 清干净。即
  `ChangeServiceConfig` 确实被调用并生效。早先只有源码推断（ObjectName 分支不校验参数、
  密码检查在打开服务之后、well-known 账户强制空串），现在源码与实测一致。

### 2026-10-28：代码审查后的一轮修正

- **`services.json` 的覆盖键名大小写**：用 `ContainsKey('toggleTimeoutMs')` 判存在，但
  `ConvertFrom-Json -AsHashtable` 返回的 `OrderedHashtable` **键大小写敏感**（实测：写
  `ToggleTimeoutMs` 时 `ContainsKey` 为 False，点访问却能取到值）。于是照 README 表格 /
  `config.json` 的拼法写大驼峰，字段被**静默丢弃且无任何提示**，功能等于没修。而 config.json
  那边的 `Contains()` 不敏感——两处行为不能不一致。改成按 `-ieq` 找实际键名。
- **env 切分的「新变量」判据放宽**：`^[A-Za-z_]\w*=` 会把 `2FA_TOKEN=x`、
  `ProgramFiles(x86)=C:\PF` 并进上一个值——变量根本没写进 `AppEnvironmentExtra`，
  敏感键检测也扫不到。改成「这一段含 `=`」即视为新变量（`NO_PROXY=...,localhost` 不受影响，
  `localhost` 不含 `=`）。
- **CLI `-Add` 在 services.json 解析失败时直接退出**：原来会拿回落的示例清单继续，
  `Save-Svc` 把示例 + 新服务写回真实文件，用户真实条目整份消失且**退出码 0**。GUI 至少有弹框，
  CLI 一点输出都没有。非致命提示（per-service 字段写错）则打印后继续。
- **硬上限的适用范围写清楚**：只管命令驱动的过渡态。探测驱动的中间态（服务真卡在 SCM 的
  StopPending）卡片正按钮不可用——那是 H1 修复的有意取舍，登记进「已知限制」，不再声称硬上限覆盖它。
  （2026-10-28 订正：当时写成「没有重试入口」是错的，右键菜单的启停/删除不经按钮门闩，一直可用。）
- `docs/HANDOFF.md` 的三个量纲数字更正（47/44/24 → 51/45/25，实测）。

**第二轮复审又抓到自己新引入的问题：**

- **门闩认错了文件**：`$script:configWarning` 有两个写入方——`Load-Svc`（services.json 坏）和
  `config.ps1`（config.json 坏）。而 config.json 坏了按设计是「不阻断、用默认值」。于是
  services.json 完全合法 + config.json 写坏一个字符时，`-Add` 会退出 1 并报「services.json 未能解析」
  ——拦错了，报错也指向没坏的文件。改用 `Load-Svc` 的专用标志 `$script:svcLoadFailed`。
- **环境变量判据与文档不一致**：代码要求 `=` 前无空白（`^[^=\s]+=`），而文档写的是「含 `=`」，
  于是 `A=1,B = 2` 会把 `B = 2` 并进上一个值（`B_TOKEN = x` 连敏感键提示都扫不到）。改成 `-match '='`。
- **那个 CLI 门闩的测试删掉了**：它跑真主脚本副本，会碰真单实例 mutex（GUI 常驻时误报），
  且门闩一旦回归、又恰好在管理员下跑，会真注册一个服务再留下孤儿。改成测 `svcLoadFailed`
  的纯函数级断言——不碰服务、不碰 mutex。
- `PROJECT.md` 两处自相矛盾/缺失：硬上限的适用范围（前一处写成能防「永久卡在 StopPending」，
  后一处又说探测驱动没有重试入口），以及 CLI 决策清单没跟上新门闩。

### 2026-10-28：收尾上一轮遗留的风险

- **pre-commit 的密钥扫描其实一次都没跑过**。scoop 明明装好了 gitleaks，但 shims 目录不在
  **git hook 拿到的 PATH** 里，hook 里 `command -v gitleaks` 失败 → 打一句警告 → `exit 0`。
  保护看着接上了，实际从没执行——又一个「声称 ≠ 接线」。改成 PATH 优先、找不到再探
  `$HOME/scoop/shims/gitleaks.exe`。验证用临时仓库 + 假 AWS key：修前 `exit 0 / no leaks found`，
  修后 `exit 1 / RuleID: aws-access-token`（值被 REDACTED）。
- **过渡刷新的硬上限提成可调项** `TransitionHardCapFactor`（默认 10）。原先写死在
  `Test-TransitionTimedOut` 里，是拍出来的魔数；现在进 `config.json`，与其它可调常量同一处收口。
- **补上真模态路径的测试**。之前只断言控件树 + 在**未显示**的窗口上点按钮，没走过真正的
  `ShowDialog`。新增一条：离屏窗口 + `ContentRendered` 里点「注册并启动」，验证下拉选中值、
  `NO_PROXY` 整条值、`DialogResult` 关闭。非交互会话自动跳过（那里 `ShowDialog` 会永久阻塞）。
- **方案 2.4 的 `NSSM_PATH` 签名校验：评估后不做**。实测本机官方 scoop 包的 nssm.exe 是
  `NotSigned`——加「签名无效就警告」会对所有正常安装报黄字，纯噪声。

### 2026-10-28：添加服务能选运行账户，GPU 程序有提示

给 ComfyUI 注册服务时的第一反应是「SYSTEM 账户能不能用 GPU」。本机实测能（驱动与显卡形态使然），但这不该靠运气——换个环境（纯集显、Optimus 混合、远程会话）就可能拿不到。工具原来对账户完全无感知。

做法，范围比原方案收窄了一档：

- 添加服务对话框加「运行账户」下拉，只列 `LocalSystem`（默认）/ `LocalService` / `NetworkService`。这三个都是 nssm 认得的 well-known SID，**不需要密码**，一条 argv 就够。
- **自定义用户账户故意不做**：nssm 只收 `nssm set <服务> ObjectName <用户名> <密码>`，密码是命令行参数，同机管理员在进程列表里可见。为一次性操作引入这个暴露面不划算，需要时用 `nssm edit`。
- 加「这是 GPU / 桌面交互程序」勾选：勾了且账户仍是 LocalSystem 时弹一条**不阻断**的提示。不做自动判断——按 exe 名猜不准，误报比不报更烦。
- `Get-NssmSetSpec` 对 `LocalSystem` 和空值不产生 `ObjectName`：那本来就是 `nssm install` 的默认值，写进去只是多一条无意义的 set，还会让「没选账户」和「选了 LocalSystem」两条路径分叉。

顺带修了一个自己制造的问题：高级区加了两个控件后内容超过固定高度 540。固定高度窗口里多出来的部分是被**裁掉**的，没有任何提示。改成 `SizeToContent='Height'` + `MaxHeight=720` + `ScrollViewer`：折叠时 3 个必填项窗口自然变矮（原 540 会在下方留近 300px 空白），展开到约 560，再高才出滚动条。离屏渲染核对过折叠/展开两态。

测试：`Test-SvcAccount` 白名单（大小写不敏感、自定义账户拒绝）、`ObjectName` 必须是单 token、GUI 透传、GPU 提示的三个分支（选了非 LocalSystem 不提示 / 勾了 LocalSystem 提示但不阻断 / 未知账户拒绝且不注册）。每条都先摘掉账户支持跑出失败再修。

**复查抓到两个自己引入的问题，都记在这里：**

- 把 `Show-Add` 拆成 `New-AddDialog` + `Show-Add` 之后，两个 Click 处理器引用的 `$f` / `$inName` 等
  全是**已返回函数**的局部变量。PowerShell 脚本块不是闭包，点击时解析到 `$null` ——
  点「注册并启动」抛 `You cannot call a method on a null-valued expression`，
  `Submit-AddService` 一次都进不去，界面表现为「点了没反应」，而**测试全绿**（它们直调 Submit，绕过了处理器）。
  修法是给两个处理器加 `.GetNewClosure()`（与 `logview.ps1` 同款），并补一条**真点按钮**的测试。
- `$null += "x"` 得到的不是数组而是 String，`-join` 失效，多条配置提示会粘成一行；
  而且 `@($null)` 也不是空数组（是含一个 `$null` 的数组）。改成判空后显式 `@()` 再 `+=`。
  测试最初预置了 `@()`，把这个缺陷遮住了——夹具必须还原生产状态（`$null`）才测得到。

### 2026-10-28：重服务不再被全局超时硬套

工具原先假定「所有服务都秒起」：卡片过渡态逃生 45s、HTTP 探测 3s，都是全局单值。
ComfyUI 冷启动到端口可用约 90 秒，于是第 45 秒卡片显示「未知」（服务其实还在正常启动），
HTTP 面板 3 秒不回就判「超时」——橙灯同样误导。

三条改法，都由 `tests/test-per-service-timeout.ps1` 守住：

1. `services.json` 支持 per-service `toggleTimeoutMs` / `httpTimeoutMs` / `tcpTimeoutMs`，缺省回落全局。
   `Read-SvcFile` 显式保留这三个字段——它原来只挑 `port`/`url`，用户手写的覆盖会在下一次 GUI
   保存时**被静默抹掉**。这条最容易漏，测试的第一条断言就是它。
   字段写错（`0` / 负数 / 非数字）**不抛**：抛会让 `Load-Svc` 退回 `services.example.json`，
   GUI 里显示示例服务，用户点一次增删就把示例写回真实文件——**整份清单连同已注册服务一起丢**。
   实测确认过这条路径（给一个服务写 `toggleTimeoutMs: 0`，GUI 拿到的是 6 个示例服务）。
   现在的处理是忽略该字段、回落全局，并单独弹一个「配置提示」框。
2. 探测到服务仍处于同一过渡态（StartPending/StopPending）时刷新过渡计时。这比单纯调大阈值准：
   服务确实在动，就不该按「回执丢了」处理。顺带把「有服务停在中间态」算进活跃轮询，
   慢启动期间不再退到 15s 空闲间隔。
   刷新有硬上限：`TransitionStartedAt` 只在进入过渡态时记一次，累计超过阈值 10 倍就强制逃生。
   没有这条，永久卡在 StopPending 的服务会把逃生口自己刷掉——而那正是逃生存在的理由。
   这也避免依赖「SCM 一定会把 StartPending 收敛掉」这个没实测过的假设。
3. HTTP 探测改成每请求 `CancellationTokenSource`，共享 HttpClient 的实例级 `Timeout` 放开为无限
   ——否则 per-service 想设得比全局更大根本改不动（实例级属性是上限，单次请求无法突破）。

运行时坑（已订正）：`[TimeSpan]::InfiniteTimeSpan` 在 PowerShell 里取到 `$null`，赋值直接抛
`Cannot convert null to type "System.TimeSpan"`；要用 `[System.Threading.Timeout]::InfiniteTimeSpan`。
这个错误只在后台 runspace 的错误流里，界面表现为探测不更新——第一次跑全量测试才暴露。

### 2026-10-28：env 值里自带的分隔符不再被拆坏

起因很具体：给 ComfyUI 填 `NO_PROXY=127.0.0.1,localhost`，GUI 直接报「环境变量格式错误: localhost」。

根因是 `ConvertTo-EnvPairs` 无脑 `-split $separator`。GUI 用逗号当分隔符，值里的逗号被当成下一对的开头——
`localhost` 没有 `=`，于是被 `Test-EnvPairs` 拦下。**多地址 NO_PROXY 在 GUI 里根本填不进去**，
而这是代理配置里最常见的写法之一。

CLI 侧是同类但更隐蔽的问题：`-Add ...,,A=1,B=2` 不会拆成两对，整串变成一个名为 `A`、值为 `1,B=2`
的变量；CLI 不跑 `Test-EnvPairs`，于是**静默写错**。

修法：切分时只在「下一段形如 `KEY=`」处真断开，否则当作上一段值的续写接回去。顺带把分隔符改成按字面量切
（原实现把它当正则用，传 `|` 之类会炸）。CLI 的字段切分改 `-split ',', 7`，env 段原样保留、不再先拆再拼。

三处回归测试，都**先在旧代码上跑出失败**再修（`git stash` 回旧 lib 验证过）：
`test-svc-input.ps1` 覆盖逗号/分号/字面量三种分隔符；`test-add-svc.ps1` 覆盖 CLI 的「逗号分对」与「值内逗号保留」；
`test-dialogs-submit.ps1` 断言 GUI 提交体拿到的是一条完整的 `NO_PROXY`。

> 顺带订正一个外部方案里的判断：它说 `AppEnvironmentExtra` 多值只存第一个、要在 `Get-NssmSetSpec` 里 join 成单串。
> **不成立**。`nssm-set` 传出的确是多个 argv（实测），而 nssm 自己会按 `ADDITIONAL_CRLF` 用 CRLF 拼成一个 value，
> `unformat_double_null` 再转成 `REG_MULTI_SZ`——三条都写得进去。**没有改 join**，改了就只是把对的改成另一种对的。

### 2026-10-20：静默不执行的日志清理

### `Dispatcher.BeginInvoke` 挑错重载，首帧后的日志清理从未执行

`ContentRendered` 里用 `$win.Dispatcher.BeginInvoke([Action]{ Invoke-LogCleanup ... }, 'Background')`
把清理排到后台优先级。`Dispatcher` 的重载表里**没有** `(Delegate, DispatcherPriority)` 这一组——
C# 会把 `'Background'` 隐式转成枚举、绑到 `(Delegate, DispatcherPriority, Object[])`；
**PowerShell 不转**，退回 `(Delegate, Object[])`，把字符串当成**委托的实参数组**。

后果是**静默**的，这是本次最值得记的一点：

- `BeginInvoke` 调用本身不抛错，正常返回
- 委托在 UI 线程被以 1 个参数调用，而 `[Action]` 要 0 个 → `TargetParameterCountException`
- 异常被 Dispatcher 兜底 handler `Handled=$true` 接住
- **窗口正常显示、动作永不执行**

于是 `gui-crash.log` 里那一行 `TargetParameterCountException` 被长期当成「兜底生效了」的证据
（前几批文档里甚至写着「被兜住，不影响关闭」）。**兜底接住异常 ≠ 动作完成**——两者在这条链路上长得一模一样。

修法：优先级写成显式枚举 `[System.Windows.Threading.DispatcherPriority]::Background`。
新增 `tests/test-dispatcher-priority.ps1` 守住，它不看源码文本，而是真排队 + 跑帧循环验委托执行了；
并用**反证**确认护栏本身有效（字符串写法必须仍抛 `TargetParameterCountException` 且委托体不执行）。
同族但**安全**的写法也实测过、别误伤：`MessageBox.Show(...,'OK','Warning')` 与 `SetDock($el,'Top')`
都不踩——判据不是「字符串一律不行」，而是**重载之间靠参数个数区分不开时会挑错**。

### 文档

- README 里 `Remove-Item ... D:\service-manager\st-tts-shim` 是死引用（目录与服务都已不存在，照抄会白建目录）→ 改为占位符。
- HANDOFF 关键文件表补回 D4 的三量纲（PASS 输出行 / 解析文件 / 测试条目），并订正审计命令里指向旧克隆的路径。

## [0.7.0] — 2026-10-11：审计修复 + 探测驱动过渡态卡死

两轮审计（外部报告 + 本轮自查）逐条核对后的修复。主线两条：**「过渡态不能只靠命令驱动」** 与 **「ACL 脚本得真能跑完」**。

### 探测驱动的过渡态永久卡死（H1，最严重）

`Update-CardData` 的探测分支把卡片带进「启动中/停止中」时**不写 `TransitionAt`**（那是 `Set-CardTransition` 才写的）。于是方向守卫（启动中只接受运行中收尾）把回落探测永久丢弃，而 `Test-TransitionTimedOut` 对 `TransitionAt=MinValue` 恒返回 false → 45s 逃生也失效。触发路径：外部工具启动服务、右键直接 `Send-ServiceCommand` 时探测到 `StartPending`，服务启动失败回落 `Stopped` → 卡片永久卡在「启动中」、按钮永久灰。

修法：**方向守卫只保护命令驱动的过渡态**（`TransitionAt` 有值 = `Set-CardTransition` 设过）；探测驱动的过渡态可被探测值收尾。顺带修 M1：离开过渡态时复位 `TransitionAt`（否则旧时间戳会让后续探测驱动的过渡态被误判成命令驱动）。已实跑复现 + 加回归。

### ACL 脚本完全失效（S1，2026-10-11 引入并当场修掉）

`set-service-params-acl.ps1` 移除泄漏 ACE 用 `RemoveAccessRule`，而 `APPLICATION PACKAGE AUTHORITY\ALL APPLICATION PACKAGES` 在本机**无法翻译回 SID** → 抛异常 → `$ErrorActionPreference='Stop'` 让脚本中止，`Set-Acl` 从不执行，ACL 永远没收紧。修法：`SetAccessRuleProtection($true,$false)` 丢弃继承（继承来的泄漏 ACE 直接消失，不撞翻译）+ 移除循环逐条 `try/catch` + 校验阶段报告失败主体。

### 其余审计项

- **正确性**：C1 CLI `-Add` 绕过单实例 mutex（抽 `Test-GuiInstanceRunning`）；C2 ack 成功回执无条件点亮门闩；C3 非过渡态失败回执错误回滚；C5 删除中超时收敛到「未知」；C7 `poll.ps1` 的 `$ok` 未逐迭代重置；C8 `xaml.ps1` btnNext 未走 gate。
- **安全**：S2 `NSSM_PATH` 只做 `Test-Path`（加文件名校验）；S3 服务名允许纯 `.`/`..`（拒绝）；S4 `Test-DirAclPermissive` 漏判 `Authenticated Users`；S5 APPDATA 检测等号后空格可绕过；S8 `Save-Svc` 的 `.tmp` 未进 `.gitignore`。
- **测试**：T1 single-instance 夹具 finally 抛异常吞断言；T2/T3 dialogs 两个提交体零覆盖（抽 `Submit-AddService`/`Submit-RemoveCommand`）；T4 `Show-SecurityCheck` ACL 判定零覆盖（抽 `Test-DirAclPermissive`）；T5 ACL 脚本零覆盖；T6 退出码映射无直接断言；T7 颜色矩阵缺分支。回归 20 → 23 项。
- **文档**：README 补 UAC 被拒/提权 GUI 说明；PROJECT.md 订正「方向匹配已消除」的失实描述；HANDOFF 量纲三分量 + 关键文件改相对路径；本段补记。

## [0.6.0] — 2026-10-05：过渡态健壮性与 NSSM 退出码实证

这一批的主线是「**不能把状态押在会撒谎的信号上**」：NSSM/sc.exe 的退出码、命令回执、后台 runspace 的存活，三处都曾让界面显示与实际不符。按「为什么」归并：

### 过渡态不再永久卡死（T1 + P5）

- 命令回执带 `ok`，成功失败都入队；失败时回滚卡片到命令前的终态并解封按钮（`c1526fd`）。
- 卡片过渡态加 `ToggleTimeoutMs` 超时逃生：回执丢失时按到达的探测值收敛（`c1526fd`）。
- 删除中的过渡态单独守卫：它没有「期望终态」，期间探测一律不覆盖（`a03d0fe`）。
- 过渡态设置抽 `Set-CardTransition`，启停与删除共用同一字段集（`a03d0fe`）——删除路径此前漏了 `LastToggle`/`ReadyToToggle`。

### NSSM/sc.exe 退出码不可信（`36bd21f`）

实测（NSSM 2.24-103）：`remove`/`install` 失败也返回 **0**，提权不足或服务不存在时打印「Administrator access is needed」却成功退出。只信退出码会把「删失败」判成功——UI 清掉卡片并落盘，而服务仍在。改为按「服务是否真的从 SCM 消失/出现」实证复核（`Test-ServiceGone` / `Test-ServicePresent`）。CLI 注册后启动失败也不再谎报「已启动」（`f8936b6`）。

### 交互与轮询收口（T2–T7）

- `StartPending` 视作已在启动，不再回落 `sc.exe` 取回 1056 拼出「启动失败(1056 已在运行)」的矛盾文案（`3ebaf86`）。
- 刚下发命令的那一轮用 `ProbeIntervalMs`，不再走 15s 空闲长睡眠（`338457d`）。
- 状态栏消息加显示租约，不被同一 tick 的自动刷新吞掉（`eb01d2e`）。
- Dispatcher 异常兜底补状态栏提示（`057e164`）；remove 回执「配置保存失败」不再被「已删除」覆盖（`428e22a`）。
- 订正日志保留注释口径 + 补 `test-log-retention.ps1`（`ead4bba`）。

### 测试与文档

- 把「未验项」尽量转成可验证：`test-transition-failure` / `test-status-lease` / `test-log-retention` / `test-remove-e2e` 四个新测试，删除流程端到端接缝（`40bffbb`）。
- 回归 PASS 输出行 27 → 37；解析文件 34 → 39；`run-all.ps1` 测试条目 16 → 20。

## [Unreleased] — 移除 WSL 纳管

### 移除

- **WSL 发行版纳管整体下线**：`services.json` 不再支持 `type: "wsl"`，工具回到只管理 NSSM 服务一类对象。
  - 删 `lib/poll.ps1` 的 `Get-WslState` / `Invoke-WslCommand` 与 `Invoke-PendingCommands` 的 wsl 分流，收集阶段的 wsl 分支，以及批量 `Get-Service` 前的 `$nssmNames` 过滤。
  - 删 `lib/util.ps1` `Read-SvcFile` 对 `type`/`distro` 的透传与「wsl 免端口校验」分流。
  - 删 `lib/card.ps1` 的 `IsWsl`/`Type`/`Distro` 卡片属性与全部 wsl 分支（端口徽章、endpoint 隐藏、面板按钮隐藏、右键菜单精简、健康门闩、`Update-CardInfo`/`Update-CardData` 刷新）。
  - 删 `tests/test-wsl.ps1`（从 `run-all.ps1` 摘除，回归项 17 → 16），删 `docs/audit-*-wsl-*.md` / `.log` 五份 WSL 审计留痕。
  - `services.json` / `services.example.json` 去掉 WSL 条目。

### 为什么

WSL 发行版纳管引入了一整套与 NSSM 路径并列的类型分支（探测、启停、卡片、菜单、健康判定），但实际只用得上「启停一个发行版」。为这一条用途维持两套类型分流的复杂度不值——需要时直接 `wsl -d <distro>` 即可。移除后 `type`/`distro` 成为普通 NSSM 条目读不到的多余字段，代码与配置一并清理，回到单一类型。

### 影响

- 旧 `services.json` 里残留的 `type: "wsl"` 条目会被 `Read-SvcFile` 当作普通服务处理，`port=0` 触发「端口非法」并让 `Load-Svc` 回落到示例清单。迁移：手动删掉该条目。

## [0.5.0] — 2026-10-04：并行探测 runspace 作用域修复

### 修复

- **`$tcpMs` runspace 作用域 bug**（a2556dd）：`ForEach-Object -Parallel` 开新 runspace，不继承父作用域变量。裸用 `$tcpMs` 会让子 runspace 取到 `$null`，`WaitOne($null,$false)` 等价 `WaitOne(0)`，TCP 握手没完成就判「无响应」——运行中服务被误判变红（启停时 runspace 更忙，0ms 扑空概率上升）。修正为经 `$using:tcpMs` 传入。

### 为什么

症状是「启停一个服务，别的运行中服务变红」。原 `test-parallel-probe.ps1` 探的是未监听端口，0ms 与 200ms 结果都是「无响应」，对这类 bug 天然免疫——故单开 `test-probe-timeout-scope.ps1`，静态扫描并行块裸引用 + 真监听端口端到端验证。

### 测试增强

- 静态扫描从查三个硬编码变量名升级为查一类裸引用（3aa51a5），不误报注释里的变量名。

## [0.4.0] — 2026-10-03：通用化 + 审计修复批次

### 重构

- **从 TTS 专用管理器转为通用本地服务管理工具**（7c95bea）：仓内移除自带 TTS 示例，`services.example.json` 改为通用条目。本工具不再绑定 TTS 服务。
- 清理 `util.ps1` 死代码（16bfd0c）：`Get-LogFiles` 死字段 / 死变量 / 假注释。
- `config.ps1` 变量改名 `configExamplePath` → `configPath`（90e1d06）。

### 修复

- **`Get-LogFiles` 参数名遮蔽外层 `$logDir`**（d442fcf）：参数叫 `$LogDir` 会遮蔽同名（PowerShell 变量名大小写不敏感）的外层 `$logDir`，回落变成自己赋给自己，GUI 日志下拉框自上线起一直为空。改名 `$LogPath` 后回落才能经动态作用域读到调用方的 `$logDir`。
- 敏感键检测升级为键名+值形态双判（ef68ba3）：`*_FILE` 后缀仅在值看起来像路径时才跳过提示，否则照样警告。
- GUI smoke 测试改用显式夹具（52c0ffc）：不再读本机 `services.json`（已 git 忽略，本机实配条数会改变分页行为，断言随机器漂移）。
- 迁移清单第 4 步改为条件执行（f7cb8a0）。
- `.gitignore` 移除 shim 死规则（fa459e1）。

### 文档

- 把 `$cfg`/`$logDir` 动态作用域约定记到 `util.ps1` 顶部（c87e9ba）——本模块函数直接读调用方作用域里的这两个变量，不是模块级变量。参数不得命名为 `$cfg`/`$logDir`，否则遮蔽同名外层变量导致回落静默失效。

## [0.3.0] — 2026-10-03：配置收口与纯函数抽取（PR #3/#4/#5）

### 重构

- **可调常量收口 `config.json`**（012b928，PR #3）：PerPage / 探测超时 / 日志轮转 / 双击冷却 / 托盘开关集中到 `lib/config.ps1`，默认值内嵌、`config.json` 覆盖。与 `services.json` 同构：示例进仓，实配每台机器自定。
- **提取 SvcInput/EnvPairs/NssmSetSpec 纯函数**（fbde7a8，PR #4）：输入校验、env 切分、NSSM set 键值序列抽出为可单测的纯函数，补负例测试。
- **托盘/最小化/关闭策略作为可选配置**（b7d72d9，PR #5）：默认全关，行为与历史一致（最小化进任务栏、关闭即退出）。三项都要开托盘才生效。

### 安全

- 默认 `TTS_API_KEY_FILE`，新增 `Parameters` ACL 加固脚本（c73d794）：把注册表键 ACL 从默认的「Users 可读」收紧到 `Administrators + SYSTEM`。
- 统一 `Wait-Stopped`、命令纪元、删除走后台（2425be4）：消除「SYNC: 两处同改」注释，`Wait-Stopped` 抽到 `lib/svc-common.ps1`，UI 与 runspace 共用一份。

## [0.2.0] — 2026-10-02：开源准备与 review 修复

### 新增

- LICENSE / 示例配置 / 截图 / README（bf232fa）。
- `Load-Svc` 回落链读示例清单（9fb0ad7）：`services.json` 缺失或损坏时读 `services.example.json`，去源码硬编码。
- CI（`.github/workflows/test.yml`）跑 PowerShell 回归（Windows runner）。

### 修复

- review 六项（47bfbf3）：输入校验 / 安全假阴性 / NSSM 路径 / 测试可信度。
- 折叠死分支与重复逻辑（3bfa6ce）：card/poll/xaml 三处。

## [0.1.0] — 2026-09-26 至 2026-10-01：WPF 重写与服务管理加固

### 重构

- WPF 重写 + 服务管理加固 + 回归测试（91a4115）：从 WinForms 卡片挪到 WPF，加 Mica 背景、单实例 Mutex、删除服务、`poll` AggregateException 展平。
- 精简 GUI 脚本（c59aaa3，482→461 行）。
- `restart` 复用 `Wait-Stopped` 轮询（52f144a）。
- `poll` HTTP 探测用 `GetAwaiter().GetResult()` 替 `.Result`（3efd826），取 `InnerException` 获取真实异常类型（9823422）。
- 并发/退出/启停 I/O 全面重做（5b7b1a0），修日志切换 bug。
- `Render-Page` 读 `$script:svc` 加 gate 对称（75602af，发现 15）：与后台 runspace 的读路径对称。
- `poll` 探测并行化（ea6e7ea，发现 4）：6 服务串行最坏 19 秒，并行后 3.2 秒。
- P1 显示漂移/密钥暴露/过渡态竞态 + P2/P3 体验优化（593fdd9）。

### 新增

- 单实例互斥 + 删除服务 + `poll` AggregateException 展平（65235d9）。
- 新增服务默认 `AppExit Default=Ignore`，不自动重启（28c7bd9）。
- 双击卡片切换时置过渡态防重复（e116814）。
- TTS shim 流式客户端断开保护 + GUI 健康超时/DPI/NSSM 预检（1bd6072）。
- 崩溃留痕（c872571）：`logs/gui-crash.log` 记录管理员状态、WPF 加载、窗口渲染和退出阶段。

### 修复

- 工具栏按钮全 null 致「空白退出」+ 加崩溃留痕（c872571）。
- 重复双击不再弹「已在运行」提示窗（37b7716）。
- `launch.vbs` `Environ` → `ExpandEnvironmentStrings`，修复双击无反应（30c9503）。
- review 修复三条测试可信度问题（582323c）。
- 单实例 mutex 静默退出回归测试（0600a66）。

## 历史脉络

本工具前身是 TTS 服务专用管理器（`st-tts-shim/`）。2026-10-03 的 7c95bea 把它转为通用本地服务管理工具，TTS 示例从仓内移除。`services.example.json` 改为通用条目（MyAPI / RouterA / RouterB / ProxyA / BuddyAPI / ServiceF），不再绑定 TTS。

升级路径见 README「从旧版 TTS 管理器升级」节。
