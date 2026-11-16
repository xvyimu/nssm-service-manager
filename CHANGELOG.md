# CHANGELOG.md — service-manager 迭代记录

> 本文件记录每次迭代的「为什么改」与「改了什么」，不重复 commit message（那是 git log 的事）。
> 代码是行为真相，本文件是**阶段性脉络**——读完能看懂这工具怎么走到今天。

## [1.0.13] - 2026-11-16

独立评审第二轮剩下的两类「声明改了、另一半没改」：

- **ACL 三态在消费端被压成两态**：`lib/security-check.ps1` 返回「是 / 否 / 未知（无法读取 ACL）」，
  但 GUI 自检只判 `-eq '是'`，`未知` 无声放过——上一轮补的「Get-Acl 抛错」只覆盖一半。
  现在宽 ACL 与无法判定分两个收集器、两套措辞：可写才建议迁移，读不到请人工确认权限。
- **同一失败写两次 crash log**：catch 里写带异常消息的一条，汇总循环再写一条通用行，已去掉重复。
- **空 catch 计数**：`IMPLEMENTATION-NOTES` 同一小节残留「53 处」，与实测 54 处矛盾，已统一。
- 新增 `tests/test-security-verdicts.ps1`：判据层未知态、消费端两种措辞、日志只写一次，三条都有断言。
- 文档：`AGENTS.md` docs 目录树补全；CHANGELOG 1.0.9 / 1.0.10 标题前补空行；
  README 用例表补新用例，项数 32 → 33。

## [1.0.12] - 2026-11-16

文档口径与安全自检收口（第 14 轮评审点名的 P3，无行为回归）：

- **安全自检不再吞错**：`service-manager-gui.ps1` 读不到 ACL 时不再 `catch {}` 静默跳过，改为记一条「ACL 无法读取，判定跳过」进 `securityFindings` 与 crash log——宽 ACL 目标不会被无声漏报。
- 空 catch 计数修正为 54 处（占 52 行），此前按行计写成 53，判据小节自身失准。
- `AGENTS.md` 去掉硬编码版本指针（写死 1.0.10），改为「以 VERSION 为准」。
- README 用例表补 `test-wait-stopped-budget` / `test-probe-static` 两行。
- 修正 1.0.11 小节笔误（`est-poll-commands` → `test-poll-commands`）与一个多余 TAB。

## [1.0.11] - 2026-11-16

- **CI 判据去耦合**：test-poll-commands 的空闲派发断言不再依赖全局默认值——夹具显式注入 probeIdleMs = 8000，
  断言改为 `< 4000`（注入值的一半），改 config 默认不会让门槛漂移。
- **v1.0.9 悬空 tag 收口**：该版本的 release 因上面的误红失败、未产出资产。已补一个 **draft + prerelease**
  的 release 记录（写明失败原因、指向 v1.0.10），版本历史不再断档，该构建不发布。
- **文档补记**：IMPLEMENTATION-NOTES 增加「空 catch 的取舍」，把 54 处静默 catch（占 52 行） 按清理 / 可选读取 /
  已另有提示三类写明判据。

## [1.0.10] - 2026-11-16

修一条只在 CI 上误红的断言：`test-poll-commands` 的「空闲命令派发」等的是绝对 1500ms，
而 worker 要先跑完一轮探测才会 drain 命令队列——CI 慢 runner 实测 1507ms，本地 89ms，
同一条断言两边结论相反。判据改成「不得等满空闲间隔」（默认 15000ms 的一半），
仍能区分「wake 立即派发」与「睡满空闲间隔」。

## [1.0.9] - 2026-11-16

预算封顶补齐「上次没算进去的那两段」，并把版本状态从文档里挪走：

- **EOF 等待也进预算**：`Invoke-ExternalQuiet` 的 `WaitForExit` 成功后，两段 `Wait(2000)` 原本
  不受调用方超时约束——一次「3s 超时」的查询最坏能吃 7s，上层按剩余预算收口全部失效。
  现在按剩余时间均分、上限 2000ms、下限 50ms。
- **预留不再写死 1000ms**：config 允许预算配到 100ms，固定预留会把窗口吃成负数
  （实测 budget=100 时跑成 1225ms）。改为 `min(1000, 预算/4)`，并在循环尾补一次「收尾查询」，
  不再因为「剩余不足一格」跳过本可命中的 Stopped/1060 查询。
- **测试跟着改**：`test-wait-stopped-budget` 覆盖多轮、小预算（100/300/1200）、收尾查询三条路径；
  去掉预留与去掉收尾查询分别能变红（2213ms / 最后一刻停服漏判）。
- **源码断言剥离注释**：`Get-SourceCodeOnly` 进 `test-helpers.ps1`，同时去块注释与行内注释；
  `test-state-sets` 与 `test-probe-static` 都改用它——注释里写同形字面量不再能骗过断言。
  `test-probe-static` 同时改成 hermetic：不再点源 config（那会读本机 `config.json`）。
- **HANDOFF 不再硬编码版本号**：发布状态改成「以 `VERSION` 与 tag 为准」，杜绝每次发版后
  「文档说未发布、实际已发」的复发。
## [1.0.8] - 2026-11-16

停止路径预算封顶与发布状态对齐：

- **`Wait-Stopped` 真正封顶**：两次状态查询、步长与超时后 `WaitForExit(1000)` 的收尾全部按剩余预算收口
  （预留 1000ms 给 kill 收尾），「≤12s」可核验；新增 `tests/test-wait-stopped-budget.ps1`，
  去掉预留即红（实测 2213ms > 1200+200ms 容差）。
- **诊断脚本去硬编码**：`tests/probe-1053-timing.ps1` 的 `ToggleTimeoutMs` 与停止预算从 `lib/config.ps1` 读取。
- **源码断言先剥注释**：`tests/test-state-sets.ps1` 匹配前去掉注释行，注释里写同形字面量不再能骗过它。
- **发布状态**：`v1.0.7` 已发布（release #9，资产 140862 B，digest `sha256:9da0f630…bad0`）；
  本节起 `VERSION` = 1.0.8。

## [1.0.7] - 2026-11-16

工程化整理 + 一处行为补齐（`tests/run-all.ps1` 30 项 + `tests/analyze.ps1` 全绿后交付）：

- **无端口服务可以从 GUI / CLI 添加了**（补 `probe=none` 的口径缺口）：添加对话框的探测方式
  多一项「无端口服务（进程在跑即正常）」，选它端口可留空、URL 自动置空；CLI 第 4 段写 `none`
  等价（`-Add Name,0,Exe,none`）。此前 `dialogs.ps1` 的白名单只有 auto/tcp/http，这类服务
  （rclone mount、纯守护进程）只能注册完再手改 `services.json`——正是 1.0.7 那次「整份清单被判无效」事故的源头。
  `Add-SvcEntry` 现在也把 `none` 落盘（原来只写 tcp/http，选了也会被丢成 auto）。
- **探测口径归一**：新增 `$script:ProbeModes` 与 `Resolve-ProbeSpec`（`lib/svc-input.ps1`），
  GUI 提交、CLI 简写、`Test-SvcInput` 共用一套取值与 URL 归一规则，不再各写一份分支；
  `Test-SvcInput` 增加 `-probe`，`none` 口径不校验端口范围。
- **ACL 判据归一 + 补覆盖**：新增 `lib/acl.ps1`（`Test-WidePrincipal` / `Test-WriteCapable` /
  `Test-AclHasWideWrite`）与 `tests/test-acl.ps1`。此前三处各写一份名单：GUI 自检、注册表收紧脚本、
  部署门禁——deploy 那份只匹配 Users/Everyone，漏了 AppContainer SID（S-1-15-3-*），门禁等于没查全。
  归一时顺带修掉两个判据缺陷：显式 **Deny** ACE 不再被算成「过宽」；主体按 **SID** 取（真实 ACL 经
  `GetAccessRules` 回来是 SID，德语等本地化名字不再漏判）。部署门禁改为 fail-closed：判不出 ACL 也算不通过。- **状态集合收敛**（先补覆盖再合并）：新增 `tests/test-state-sets.ps1`，把四组语义的成员用行为钉住——
  过渡态（超时逃生 / 退出确认）、SCM 中间态（poll 加速）、切换态（时长后缀）、陈旧豁免（+待保存）、
  托盘计数。随后把散在 `card/xaml/tray/ui-status` 的字面量合并到 `config.ps1` 的四个常量
  （`TRANSITION_STATES` / `SCM_PENDING_STATES` / `SWITCHING_STATES` / `STALE_EXEMPT_STATES`）；
  `poll.ps1` 在第二个 runspace 读不到 config 变量——现由入口经 `$sync.scmPendingStates` 注入，poll 内只留缺注入时的同值兜底，改动只需改 `config.ps1` 一处。
  顺带修掉两处不一致：`ui-status` 与 `tray` 的回落字面量各写 5 态，与 config 的 3 态不符。
- **`lib/util.ps1` 按职责拆分**：591 行、五类职责 → `svc-store`（清单读写）/ `ui-status`（命令入队 + 状态栏 + 每帧 tick）/
  `log-retention`（日志目录与轮转档清理）/ `security-check`（提权边界自检）/ `shutdown`（关窗收尾）；
  `util.ps1` 只剩加载顺序与共用格式化、少量数据切片；`Add-ConfigNotice` 兼容垫片已删除（实现只在 `config.ps1`），仓内不再有垫片副本。
  拆的是文件边界不是控制流——20 个函数按行原样搬过去，另加各文件头与 `Load-Svc` 一处补注。
- **依赖点源加守卫**：`lib/nssm.ps1`、`lib/add-svc.ps1` 原来无条件点源 svc-input/svc-common，
  GUI 入口已点过时会静默重定义函数；改为 `Get-Command` 存在性判断，与 util.ps1 的写法一致。
- **「服务默认不自启」显式化**：`Get-NssmSetSpec` 的 `Start=SERVICE_DEMAND_START` 补注释并加回归断言。
  `nssm install` 建出来的是 AUTO_START，这条 set 是唯一把它改回手动的点（nssm 2.24 实测生效）。
- **补 16 处函数头中文说明**（`Load-Svc` / `New-Card` / `New-MainWindow` / `Render-Page` / `Invoke-ScQuiet` /
  `Test-SvcAccount` / `Get-WebPageHtml` 等），都是跨文件调用、原来只有内联注释的函数。
- **文档同步**：README 测试命令旁的「当前 29 项」改成 30 项、HANDOFF 回归项数 20 → 30、PROJECT.md 目录树、ARCHITECTURE.md 分层表；
  IMPLEMENTATION-NOTES 的 `util.ps1` 小节加拆分说明；HANDOFF 发布状态从 `v0.9.0` 更到 `v1.0.6`（`VERSION` 当时已是 1.0.7，而 tag 停在 v1.0.6）。
- `deploy-local.ps1` 自检不再硬编码模块清单：解析入口 dot-source（与 `package-release.ps1` 共用 `scripts/lib-entry-modules.ps1`）+ `lib/*.ps1` 全集；两处各写一遍正则的漂移点一并消掉。
- **CHANGELOG 拆分**：0.9.0 及以前的内容整体移到 `docs/CHANGELOG-archive.md`（归档文件 591 行，含 4 行头注），根文件只留 1.0.x 与未发布。
- **README 测试表补齐**：22 行补到 30 行，与 `run-all.ps1` 自动收集数对齐；文件表补 `deploy-local.ps1` / `deploy.cmd` 与文档导航。
- **重试补参同步 Application**：`Set-NssmServiceParams` 现在会把 `Application` 写成当前 exe；已注册重试补参成功统一提示需重启才生效——不查服务状态，避免 UI 线程 I/O，所以**不是**「只在服务运行时提示」（`lib/nssm.ps1`、`lib/dialogs.ps1:207-211`）。
- **probe 口径单一来源**：`$script:ProbeModes` 成为唯一白名单；`svc-store` / `dialogs` / `add-svc` 全部派生，GUI 探测下拉与 CLI 简写补齐 `http`（旧版只能手改清单）。
- **写序替代回滚**：`Set-NssmServiceParams` 改成「参数先写、`Application` 最后写」；参数阶段失败时服务仍指向旧 exe，重试幂等收敛。不做逐键快照（`nssm get` 对 `AppExit`/多值键读不全，还原会写错值）。
- **探测查询硬超时**：`lib/poll.ps1` 四处 `Get-Service` 与 `Wait-Stopped` 改走 `sc.exe query`（`Get-SvcStateQuiet` / `Get-SvcStateMapQuiet`），超时由 `Invoke-ExternalQuiet` 的 `WaitForExit(timeout)+Kill` 兜住，`SvcStateTimeoutMs`（默认 3000ms，经 `$sync` 注入 runspace）可调。超时表现为状态「未知」+ 60s 限频提示，不再永久阻塞探测 runspace。
- **时长格式化收口**：`Format-Elapsed`（card.ps1）合并为 `lib/util.ps1` 的 `Format-Duration`，callers 两处。
- **死参数清理**：删 `Invoke-CardRestart` 的 `$source`、`Invoke-RetrySaveSvc` 的 `$name`（AST 扫描确认零引用），并清掉随之失效的菜单项 `Tag`。
- **测试夹具收口**：24 处 `Stop-Background` / `Write-CrashLog` 桩、临时目录与假 exe 样板统一进 `tests/test-helpers.ps1`（`test-shutdown` 先点 helpers 再点 lib，真实 `Stop-Background` 覆盖空桩）；只有 `tests/make-demo.ps1` / `make-screenshot.ps1` 保留本地空桩（它们不起 GUI 入口）。
- **NSSM 语义实测**：nssm 2.24 下 `set Application` 不改 `AppParameters` / `AppDirectory`，结论写进 `docs/IMPLEMENTATION-NOTES.md`。

### 2026-11-09 批次（并入 v1.0.7）

一台机器的真实事故：装的是 11-04 的旧版，`services.json` 里 `OpenList-Mount` 已经改成
`{"probe":"none"}`（无端口服务），旧版 `Read-SvcFile` 还要求 port ≥ 1 → 整份清单被判无效，
界面退回 `services.example.json`，用户看到 7 个「未安装」的示例服务，以为自己的服务被覆盖了
（磁盘文件其实没动，旧版只是拒绝保存）。这类「改一行配置 → 整个界面变样」的流程太大，收成三件：

- **一键部署**（`scripts/deploy-local.ps1` 重写）：普通权限运行，脚本自己弹 UAC 重跑；
  覆盖前把旧程序文件整份备份到 `%ProgramData%\ServiceManager\backup\<时间戳>\`（留最近 5 份，含新版本已删掉的旧文件），
  复制完逐文件比对 SHA256，复制或校验失败**自动按备份还原**并报出备份路径，不留半新半旧的装机目录；
  ACL 自检改为递归（`icacls /reset /T` 遇占用会跳过子文件，只查根目录等于没查）；
  部署完成默认启动程序（`-NoLaunch` 可关）。另加 `scripts/deploy.cmd`，资源管理器里双击即可。
  **这次的故障就是「改了代码但没重新部署」**，部署从 4 步命令压到一次双击，失败点各自报清楚。
- **清单里一条写错不再拦整份**：`probe` 先解析，`probe=none` 时端口字段无意义——写 `0` / 乱写都不报警、
  合法端口原样保留（改探测口径后还认得）；缺 port 且没声明 `probe=none` 时留一条「健康探测会恒失败」。
- **启动提示只保留一处弹框**：`services.json` 解析失败才弹（那时显示的是示例清单、保存被禁用，
  必须说清后果）；`config.json` 写坏、未知键、可选字段写错一律降级为状态栏一行 + `gui-crash.log`
  留档，不再每次启动点两次「确定」。`configWarning` 也随之只表示「清单不可解析」，
  修掉了「config.json 坏了却让人去修 services.json」的误导文案。
- 提示收集收口成 `Add-ConfigNotice`（六处 `$null -eq` 守卫去重）；`services.json` 不存在时补一条提示，
  免得首次运行看着示例清单以为服务丢了。
- **版本可见**：标题栏显示 `服务管理 v1.0.7`，启动时 `gui-crash.log` 也记 `version=`——
  上次事故里「跑的是旧版」只能靠猜，现在第一眼就能看出来。
- 回归：`test-config-params` 改判提示、`test-probe-none` 增加「probe=none 端口静默」三条断言。

## [1.0.6]（2026-11-04）

第二轮边界探针（删服务后点菜单、批量含幽灵服务、批量全过期、删最后一页后翻页、健康历史坏行、
空日志文件、服务名带正则字符、空 token、未来时间戳的胶囊、托盘文案超长）跑出的唯一问题：

- **胶囊对未来时间戳说「更新于 0s 前」**：颜色已转琥珀，文案却夹成 0 秒，等于替不可信的数据背书。
  超过 60 秒的未来样本现在写「更新时间在未来（检查系统时钟）」。
  新增 `test-freshness` 第 6 例。

探针其余九项确认无需改动：菜单指向已删服务（`Open-PanelUrl` 收到空 URL 直接返回）、
批量含幽灵服务（按清单筛掉了）、批量全过期（提示跳过数、不下发）、删最后一页后翻页（`Render-Page`
自带 clamp，显示 1/1）、健康历史坏行（跳过坏行，读到 2 条有效）、空日志文件（返回空串）、
服务名带点号（只匹配 `A.B.out.log`，不误伤 `AxB.out.log`）、空 token（校验拒绝）、
托盘文案（12 个服务 13 字符，未触 63 上限）。

## [1.0.5]（2026-11-04）

边界探针（空清单 / 单服务 / 跨页 / 长名 / 状态矩阵 / 坏队列项 / 未来时间戳 / 菜单可见性）跑出来的边际项：

- **未来时间戳在卡片上仍显示「运行中」**：胶囊修了，`Update-CardFreshness` 没修——`$now - $at` 恒负，
  陈旧判据永不触发。现在只接受 `[-1 个周期, 2 个周期]` 区间内的样本算新鲜，未来时间戳按陈旧降级。
  新增 `test-freshness` 第 5 例。
- **「右键重试保存清单」指向一个不存在的菜单**：卡片红字这么写，但卡片右键菜单里没有这一项——
  恢复入口只挂在状态栏汇总标签上。现在待保存卡的右键菜单自带「重试保存清单」。
  逻辑抽成 `Invoke-RetrySaveSvc`（util.ps1），状态栏菜单与卡片右键共用一份，避免两处漂移。
  新增 `test-remove-save-fail` 1c（待保存卡有、普通卡没有）。

探针确认无需改动的：空清单、单服务、7 项分页、60 字符服务名 + 120 字符 URL、缺字段的队列项
（不抛、落到 else 分支）、`svcState` 为 `$null` 时的胶囊文案。

## [1.0.4]（2026-11-04）

第三轮复审（两个极小范围任务，终于跑完）修的项：

- **日志窗「打开文件夹」会抛**：`MessageBox::Show($f2, …)` 里 `$f2` 从未定义，参数顺序也错。
  目录不存在时点这个按钮必抛，异常冒到 Dispatcher 兜底只留一行日志。
- **待保存卡被后台死亡覆盖**：同 tick 里先 `Set-CardPendingSave` 再 `Set-CardOffline`，
  后者把状态改成「未知」，而红字提示仍写着「右键重试保存清单」——卡片自相矛盾，
  恢复入口也不显眼。`Set-CardOffline` 现在跳过 `PendingSave` 卡。
- **Web 视图「停不掉」被当成停下了**：`$webStopped` 默认 `$true`，读 Handle 抛异常时
  仍走「已确认」分支，引用被清、日志不打——与注释承诺相反。默认改 `$false`，三条未确认路径都落到保留。
- **新鲜度胶囊会冻结**：它寄生在 `Update-StatusTick` 主流程里，上游一条坏数据抛错就停更，
  表现比「离线」更可信。调用单独包 `try`，失败写 crash log。
- **时钟回拨下胶囊永远显示新鲜**：`$now < $newest` 时差值恒负，陈旧判据永不触发。
  补 `$now -lt $newest` 一并转琥珀。
- **托盘计数与在途清单口径不一**：`Get-TrayStatusText` 只认三种，与 `TRANSITION_STATES` 脱钩，
  改完统一引用。同时把 `TRANSITION_STATES` 收敛成三种——`暂停中`/`继续中` 不是本工具发起的命令，
  没有回执可丢，不该拦退出（`docs/PROJECT.md` 已补说明）。
- **退出确认的注释与事实不符**：探测驱动卡死态（`TransitionAt` 为空）不判超时，永远算在途，
  注释却写成「下次 tick 就会解封」。改成限定「命令驱动的过渡态」。

## [1.0.3]（2026-11-04）

第二轮独立复审（单文件范围）给出的可复现项，逐条修：

- **「待保存」不再被探测冲掉**：删除已落盘但清单写失败时卡片标「待保存」，
  而下一拍探测会直接 `ST=$st`，状态行写「运行中」、提示条写「已从系统删除」，自相矛盾。
  现在 `Update-CardData` 对 `PendingSave` 与 `Offline` 一并拒绝应用（新增回归段）。
- **成功回执清掉旧失败提示**：原来只有下次点按钮才清，「启动失败」会一直挂着。
- **`why` 不再跨命令泄漏**：`$ok` 每轮重置而 `$why` 没重置，上一轮的失败原因会跟着
  这一轮的成功回执回传。加上 `$why=''`。
- **`svcState` 惰性建也走 Synchronized**：两处 `= @{}` 整体替换会让 Web runspace
  继续读旧实例（静默分叉）；现在同时写回 `$sync.svcState`。
- **`bgStopped` 用 `-eq $true` 判**：首次读在 GUI 赋值之前，StrictMode 下会在置位前抛。
- **Web 停不掉时保留引用**：不再无条件 `$null`，句柄不丢、日志可查。
- **副标题不再复述状态词**：卡片状态「等待中」下面原本写「无响应 · 已等待 22s」，
  而「无响应」是 120 秒后才该出现的状态（真机截图发现）。改成「探测未通过（无响应）」。

评审建议里有一条被**否决并回退**：让 `Set-CardTransition` 保留真终态作为回滚目标。
`restart` 启动阶段失败时停止已经执行过，回滚到「停止前」是谎报；回「未知」等探测纠正才对，
`test-transition-failure` 4c 锁的正是这个语义。

## [1.0.2]（2026-11-04）

- **后台死后残样本不再把卡片写回「运行中」**：后台结束前最后一批探测结果可能还在队列里，
  而 `bgDeathReported` 已挡住新鲜度降级——这些结果被应用后，卡片会永久显示旧值。
  现在 `Set-CardOffline` 置 `Offline` 标记，`Update-CardData` 见到就拒绝应用。
  新增回归：`test-bg-death` 第 4 段（去掉守卫必红）。
- **部署脚本的 ACL 顺序修正**：先 `/reset /T` 清掉复制进来的显式 ACE，再断继承、最后写显式规则。
  原顺序会把目录自身的显式规则一起重置回从父目录继承——目标路径若不在 `Program Files` 下，
  等于 ACL 没设。已在临时目录树实测：根目录三条显式规则、子文件全部继承、普通用户写 ACE = 0。

## [1.0.1]（2026-11-04）

- **卡死的过渡态不再拦关窗**：退出确认原先只按「清单里还存在」过滤，仍会把一张
  「回执早就不来了、服务早已不在 SCM」的卡当成在途，每次退出都误报一次。
  现在再加一层 `Test-TransitionTimedOut`：已超时的过渡态不计入；`Test-TransitionTimedOut`
  不可用时（CLI 或只加载 util+xaml 的单测）保守按在途处理，不放行真操作。

## [1.0.0]（2026-11-04）封板：状态诚实 · 失败可恢复 · 提权边界

不新增功能。这一版把「界面说的和实际发生的一致」与「装在哪才安全」两件事做完，之后进入冻结维护。

### P0 提权边界

- **程序与 NSSM 改到管理员独占目录**：新增 `scripts/deploy-local.ps1`（幂等，不覆盖本机清单），
  默认部署到 `C:\Program Files\ServiceManager`，`Users` 只读执行、`Administrators`/`SYSTEM` 完全控制；
  `nssm.exe` 固定到 `C:\Program Files\nssm\nssm.exe`。
- **不再信任用户环境**：GUI 只认上述固定路径，删掉 `NSSM_PATH` / `Get-Command` / scoop 三级探测；
  `launch.vbs` 删掉 scoop 与 PATH 回退，只认 Program Files 的 `pwsh.exe`。
  原因：这两处都以管理员身份执行，用户可写目录里的副本等于让标准用户决定管理员进程跑什么。
- **自检扩面但仍不冒充防护**：启动检查程序目录、`lib`、NSSM 目录的 ACL；添加 `LocalSystem` 服务时
  若 exe 目录可写再告警一次。真正边界由部署脚本建立。

### P1 状态诚实

- **采样时刻由 worker 回传**：`poll.ps1` 每个结果带 `at`；`svcState.at` 不再是 UI 消费时刻。
  限流跳过的那轮沿用上次采样时刻，不再伪装成「刚更新」。
- **陈旧样本降级**：超过 `2 × ProbeIntervalMs` 没新结果 → 「状态未知」+ 禁用动作（`Update-CardFreshness`）。
- **后台死亡全员转未知**：原先只改「查询中」的卡，其余继续显示旧的「运行中/正常」；现在全部走 `Set-CardOffline`。
- **失败原因留在卡片上**：回执带 `why`，`Set-CardLastError` 渲染红字一条；状态栏改为带时间戳的 30 秒动作日志。

### P2 失败可恢复

- **添加服务幂等续做**：已注册但清单没写成时，重试只补 `nssm set` + 保存 + 启动，不再报「服务已存在」。
- **删除先落盘再改内存**：保存失败时卡片保留并标「待保存」，右键「重试保存清单」是恢复入口；
  不再出现「界面说删了、磁盘还在」。
- 抽出 `Set-NssmServiceParams`，让「补参数」与「首次注册」分开，回滚策略由调用方决定。

### P3 退出生命周期

- `Stop-Background` 幂等 + 有界：确认管道结束才拆 runspace，未结束只发停止请求；
  关闭前兜底排空健康队列，不再丢最后一条变化。
- 退出确认：有在途命令或未超时过渡态时提示；清单里已不存在的残留卡片不再拦人。

### P4 交付一致性

- 打包加入 `assets/icon.ico`；自检清单从主入口 dot-source 列表派生，并断言包内不含实配/日志/tests。
- release：按 `VERSION` 精确取包、tag 上补跑静态分析、发布幂等、加 concurrency。
- CI 新增 `version-consistency`：`VERSION` 必须是 semver 且等于 `CHANGELOG.md` 首个版本小节。
- 文档：`CHANGELOG.md` 移到仓根（唯一 SSOT）；新增 `docs/README.md`、`ARCHITECTURE.md`、`adr/`、`lessons/`。

### P5 体验收尾

- 语义色改为 WCAG AA 达标值（橙 `#FFA500`≈2.0:1 → 琥珀 `#8A5300`；红 `#FF0000` → `#C0392B`），
  颜色不再单独承载语义。
- 层级：服务名 19→17、状态 21→18；卡片可聚焦，Enter/菜单键等价鼠标；`AutomationProperties.Name` 补全。
- 标题栏新鲜度胶囊（`更新于 Ns 前` / `离线`）；底栏写出真实快捷键。
- 对话框：删除框 Esc/Enter/滚动 + 实时差量提示；批量停止列出目标名单。
- 日志窗等宽字体、跟随最新、文件大小与更新时间、打开文件夹/复制路径。
- 托盘 tooltip 带计数、菜单加全部启停与日志目录、首次收进托盘提示一次。
- DPI 改 PerMonitorV2，初始尺寸按工作区夹取。

### 测试

- 新增 6 个回归：`test-freshness`、`test-bg-death`、`test-add-idempotent`、`test-remove-save-fail`、
  `test-shutdown`、`test-exit-confirm`；全套 26 项 + parser 自检，`PSScriptAnalyzer` Error/Warning = 0。


更早版本（0.9.0 及以前）见 `docs/CHANGELOG-archive.md`。
