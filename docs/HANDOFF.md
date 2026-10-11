<!-- doc-template: project/HANDOFF v1 -->
# HANDOFF

> **更新日：** 2026-10-11
> **状态：** 进行中（P0-1 / P0-2 / P1 / P2 / P4 已落地；P3 未做。T1–T7 已落地并提交；2026-10-11 审计修复批次已落地，见下节）
> 本文件**无日期后缀**（带日期会让链接永久腐烂）。当前在哪一天由上一行回答。

---

## 上一段做到哪（2026-10-11 审计修复批次）

对一份外部审计报告（基线 `f8936b6`）逐条核对并修复。审计的 20 项里，一部分在 `f8936b6`
之后的 4 个提交（`591037b` / `cf17369` / `593f8bc` / `d6c81ca`）已改掉（README 文件表、
PROJECT.md 模块描述、`ToggleTimeoutMs` 抬到 45000），本轮补上剩余的：

| 类 | 项 | 改动 |
|----|----|------|
| 正确性 | C1 | CLI `-Add` 绕过单实例 mutex → 加 `Test-GuiInstanceRunning` 检测，GUI 在跑则拒绝 |
| 正确性 | C2 | ack 成功回执无条件点亮按钮/门闩 → 按当前状态/健康重算 |
| 正确性 | C3 | 非过渡态的失败回执错误回滚 → 加守卫（右键启停路径） |
| 正确性 | C4 | 后台 runspace 死亡时过渡态永久卡住 → `Update-StatusTick` 每帧无条件扫卡片逃生 |
| 正确性 | C5 | 删除中超时按探测值收敛会点亮按钮 → 收敛到「未知」 |
| 正确性 | C7 | `poll.ps1` 的 `$ok` 未逐迭代重置 → 循环开头置 `$null` |
| 正确性 | C8 | `xaml.ps1` btnNext 读 svc.Count 未走 gate → 加锁，与 Render-Page 对称 |
| 安全 | S1 | ACL 脚本只摘 Users，漏 `ALL APPLICATION PACKAGES` / `S-1-15-3-*` → 判据抽 `Test-LeakyAce`，移除与校验共用 |
| 安全 | S2 | 只判「ACE 存在」不判 FullControl → 改 `Set-FullControlAce` 判权限 |
| 安全 | S3 | 敏感键名正则漏 `DB_PASS`/`APIKEY`/`*_AUTH` 等 → 扩充（`\bPASS\b` 对 `DB_PASS` 不成立，改 `(^\|[_-])PASS([_-]\|$)`） |
| 测试 | T1 | single-instance 夹具 finally 抛异常吞掉后两段 → `ReleaseMutex` 包 try/catch |
| 测试 | T2/T3 | dialogs 两个 Click 提交体零覆盖 → 抽 `Submit-AddService` / `Submit-RemoveCommand` + 新测试 |
| 测试 | T4 | `Show-SecurityCheck` ACL 判定零覆盖 → 抽 `Test-DirAclPermissive` + 断言 |
| 测试 | T5 | ACL 脚本零覆盖 → `test-acl-script.ps1` 守「判据单源」不变量 |
| 测试 | T6 | 退出码映射无直接断言 → `test-exitcode-map.ps1` 直测完整表 |
| 测试 | T7 | 颜色矩阵缺「未安装」「未知」 → 补两个 case |
| 文档 | D3 | card.ps1 注释说「方向匹配已消除」与实现不符 → 订正；PROJECT.md 同步 |
| 文档 | D4 | HANDOFF 量纲混用「项」 → 改为「PASS 输出行 / 解析文件 / 测试条目」三分量 |
| 文档 | D5 | CHANGELOG 缺 10-05 批次 → 补 `[0.6.0]` 段；HANDOFF 提交表补 `40bffbb`/`f8936b6` |
| 文档 | D6 | HANDOFF 引用仓外文件 → 注明未进版本控制 |
| 文档 | S5 | README 未写 UAC 被拒/提权 GUI 结束不掉 → 补「启动」「排错」两节 |

**实测证据（本机，非引用文档）**：
- `Parameters` 键默认 ACL 实测含 `BUILTIN\Users` + `ALL APPLICATION PACKAGES` + 裸 SID
  `S-1-15-3-*`（均 ReadKey，inherited）——S1 成立。
- `sc.exe query`：存在返回 0，不存在返回 1060——T8 的语义确认（见「本轮真机复核」）。
- `pwsh -NoProfile -File tests/run-all.ps1` → 23 项全 PASS，exit 0。

**没做的**：C6（`ServicesPipeTimeout` 耗时竞争）仍未有真机数字，`ToggleTimeoutMs=45000`
是按管道上限推的——已记进 PROJECT.md「已知限制」。`tests/probe-1053-timing.ps1` 需管理员跑。

### 第二轮审计（自查，2026-10-11）

对修复后的 HEAD 再做一轮三方向审计（正确性 / 安全 / 测试+文档）。新发现：

| 类 | 项 | 改动 |
|----|----|------|
| 正确性 | **H1（最严重）** | 探测驱动的过渡态不写 `TransitionAt` → 方向守卫永久丢弃反向探测、45s 逃生也失效（`Test-TransitionTimedOut` 对 MinValue 恒 false）→ 卡片永久卡死。已实跑复现。修法：方向守卫只保护命令驱动的过渡态 |
| 正确性 | M1 | 离开过渡态时 `TransitionAt` 不复位 → 旧时间戳污染后续判据。随 H1 一并修 |
| 安全 | **S1（本批引入的回归）** | ACL 脚本扩了泄漏主体后，`RemoveAccessRule` 对不可翻译的 `ALL APPLICATION PACKAGES` 抛异常，`$ErrorActionPreference='Stop'` → 脚本中止、`Set-Acl` 从不执行、ACL 永远没收紧。修法：`SetAccessRuleProtection($true,$false)` 丢弃继承 + 移除循环 try/catch |
| 安全 | S2 | `NSSM_PATH` 只做 `Test-Path` → 加文件名校验（须为 `nssm.exe`） |
| 安全 | S3 | 服务名允许纯 `.`/`..` → 拒绝（路径归一化会指错注册表键） |
| 安全 | S4 | `Test-DirAclPermissive` 漏判 `Authenticated Users` / AppContainer SID → 补入 |
| 安全 | S5 | APPDATA 检测等号后空格可绕过（`$kv[1]` 未 Trim）→ Trim 后判 |
| 安全 | S8 | `Save-Svc` 的 `.tmp` 未进 `.gitignore` → 补规则 |
| 文档 | — | HANDOFF「关键文件」指向旧克隆 `D:\service-manager\` 且行号失效 → 改相对路径 + 函数名定位；Mica「已验」措辞澄清（验的是 DWM 返回值，非可见效果）；CHANGELOG 补本批段 |

**H1 实跑复现（本机，自建 harness）**：
```
2.probe=启动中           ST=启动中 TransAtSet=False Btn=False
3.probe=已停止(期望终态否) ST=启动中 TransAtSet=False Btn=False   ← 修前：永久丢弃
5.after sweep            ST=启动中 ...                            ← 修前：45s 逃生也不动
6.double-click           status='S 正在切换中'                     ← 用户无法操作
```
修后第 3 步即收敛为「已停止 Btn=True」。回归见 `tests/test-transition-failure.ps1` 第 4b 段。

**未修（设计取舍，记入 PROJECT.md 已知限制）**：L1 `Test-GuiInstanceRunning` 的 TOCTOU（GUI 启动早期探测判「无 GUI」是固有窗口）；L2 删除失败回滚到删除前终态（≤4s 自愈）；S7 `Open-PanelUrl` 的 URL 来自用户自己的 `services.json`。

---

## 上一段做到哪（本轮 T1–T7）

按外部给的七条修复任务逐条修复，各一个提交（基线 `eca4b86` 起）。
**注：原始任务清单是仓外的 `service-manager-修复任务-提示词.md`，未进版本控制**——下表按任务号概述其要求，仓外读者据此可追溯。

| 任务 | 提交 | 说明 |
|------|------|------|
| T1 | `c1526fd` | 过渡态没有失败出口，卡片会永久卡死。三层补齐：`poll.ps1` 回执带 `ok`（成功失败都 Enqueue）；`gui` 的 ack 分支按 `ok` 分流、失败回滚；`card.ps1` 加 `ToggleTimeoutMs` 超时逃生 |
| T2 | `3ebaf86` | `Invoke-ServiceStart` 对 `StartPending` 友好：与 `Running` 同组直接返回，不再回落 `sc.exe` 取回 1056 → 「启动失败(1056 已在运行)」的矛盾文案 |
| T3 | `338457d` | 在途命令也算活跃：刚下发命令的那一轮用 `ProbeIntervalMs`，不再走 15s 空闲长睡眠 |
| T4 | `eb01d2e` | 状态栏消息加显示租约，不被同一 tick 的自动刷新吞掉；tick 主体抽成 `util.ps1` 的 `Update-StatusTick` 以便直测 |
| T5 | `057e164` | Dispatcher 异常兜底补状态栏提示（截断 80 字符，整段包 try/catch） |
| T6 | `428e22a` | remove 回执里「配置保存失败」提示不再被「已删除」覆盖 |
| T7 | `ead4bba` | 订正日志保留注释口径（选 (a)：实现是对的，注释错）+ 补 `test-log-retention.ps1`（该函数此前零覆盖） |
| 收尾 | `cba78eb` | 删掉 T4 遗留的重复 DispatcherTimer 注释行 |
| 收尾 | `223d066` | `ToggleTimeoutMs` 注释不写未实测的耗时数字 |
| 收尾 | `74af131` | 自审收口：Open-PanelUrl 失败提示补租约、测试抽 `Wait-FakePollAck`、README/PROJECT 配置表与测试计数补齐 |
| 收尾 | `36bd21f` | **nssm 退出码不可信**（remove/install 失败返回 0）→ 删除/注册改按「服务是否真的消失/出现」实证复核 |
| 收尾 | `40bffbb` | 把未验项尽量转成可验证：T5 自动回归 + 删除流程端到端接缝（`test-remove-e2e.ps1`） |
| 收尾 | `f8936b6` | CLI 注册后启动失败不报「已启动」+ 合并重复的 `sc.exe query` |

新增测试四个：`test-transition-failure.ps1`、`test-status-lease.ps1`、`test-log-retention.ps1`、`test-remove-e2e.ps1`。
**三个量纲别混**：PASS 输出行 27 → 37 条；解析文件 34 → 39；`run-all.ps1` 的测试条目 16 → 20。

### 本轮真机复核到的（原先标「未验」的，已收口）

- **single-instance 失败确认是环境项**：持有 `Local\service-manager-gui` 的是本机正在跑的 GUI
  （PID 10988，13:10 启动，早于本轮改动）。`gui-crash.log` 里 16:44 那次
  `Already running; another instance holds the mutex` 是真实的第二实例被拒记录。
- **UAC 提权路径有效**：crash log 每次启动均记 `admin=True`（launch.vbs → ShellExecute runas）。
- **Mica 的 DWM 调用实测成功**：离屏建窗后 `DwmSetWindowAttribute(DWMWA_SYSTEMBACKDROP_TYPE=38, 2)`
  返回 hr=0，`DwmGetWindowAttribute` 回读 = 2。（注：验的是**调用返回值**，不是肉眼可见的
  玻璃效果——后者仍需真机交互确认，见文末「未验的部分」。）
- **`ServiceController` 行为与注释相符**：构造不抛；对不存在服务 `.Status` 返回空串不抛；
  `.Start()` 抛 `MethodInvocationException`（内层 `InvalidOperationException`）。
- **非管理员 `sc.exe start <已运行服务>` 返回 5**（拒绝访问），不是 1056 —— 与代码注释一致。
- **nssm 退出码实测**：`remove`/`install` 失败返回 **0**、`stop`/`start`/`restart` 返回 3、
  `set`/`reset` 返回 1。已据此修复（见 `36bd21f`）。
- **`sc.exe query` 退出码实测**（2026-10-11，非管理员）：服务存在返回 **0**，不存在返回
  **1060**——正是 `Test-ServiceGone`（认 1060/1072）与 `Test-ServicePresent`（认 0）依赖的语义。
  注：测试替身里这两个码由旋钮（`$sync.serviceGone` / `$script:nssmInstalled`）决定，
  「服务真消失」这个事实由 SCM 决定——判定逻辑真跑，被替身的是 SCM 那一端。
- **`Remove-RotatedLogs` 口径**：真 `logs/` 现有 112 份轮转档，全在 14 天窗口内 → 删除 0 份，
  与注释订正后的一致（跨窗口时的行为见 `test-log-retention.ps1`）。
- **`DispatcherUnhandledException` 可无头触发** → T5 那条「人工确认」已改成自动回归（真抛真接）。
- **删除流程端到端接缝**（runspace 回执 → UI tick）已补自动测试 `test-remove-e2e.ps1`。

**仍未验（需要管理员或交互式 GUI，本轮做不到）**：

- 启动失败路径（SCM 1053）的真实耗时 —— 需注册服务，非管理员 `OpenSCManager` 即失败。
  已写 `tests/probe-1053-timing.ps1`（管理员跑）供实测。注意 SCM 的 `ServicesPipeTimeout`
  本机未设 = 默认 **30000ms**，而启动失败回落 `sc.exe start` 走的正是这条同步管道。
  `ToggleTimeoutMs` 已从 30000 抬到 **45000**（留 15s 余量）以避免逃生抢在回执前触发，
  但这是按「管道上限 + 余量」推的值，**不是量出来的** —— 跑过探针才能确认够不够。
- 真实 NSSM 服务生命周期（注册/启动/删除真服务）。
- 交互式点击 `Show-Remove` 模态框走完整删除流程（GUI 跑在提权进程里，非提权侧受 UIPI 限制
  无法驱动其窗口；且那个实例是改动前的旧代码）。等价接缝已由 `test-remove-e2e.ps1` 覆盖。

---

## 上一段做到哪（审计复核那轮，基线 34 文件 + 27 项）

审计复核 + 修复 + 结构拆分 + 精简，全部已提交并推送到
`origin/refactor/generic-tool-and-audit-fixes`（推送走 SSH-443，见文末「坑」）。

基线自跑（**当时**）：`pwsh -NoProfile -File tests/run-all.ps1` → 解析 34 文件 + 27 项 PASS。
唯一失败项 `single-instance` 为 **pre-existing 环境敏感问题**（见 Blockers）。

外部审计报告给了 P0-1 / P0-2 两个崩溃口和一些性能主张。复核结论：**两个崩溃口成立，
但报告里几条性能归因是错的**（Add-Type 归因反了、并行池成本高估、CI「从未触发」不准确），
逐条实测见下文。

---

## 下一步（直接做，勿重问范围）

### P0-1 · 打开面板能把整个 GUI 带走（**已落地**）

改动：
- `lib/util.ps1` 新增 `Open-PanelUrl`（空值前置返回 + `try/catch` + 状态栏提示 + crashlog）。
- `service-manager-gui.ps1` 紧跟 AppDomain handler 之后加 Dispatcher 级 `UnhandledException`，
  `Handled=$true`，记完继续跑。
- `lib/card.ps1:95`（按钮 Click）与 `:134`（右键菜单 open）改调 `Open-PanelUrl`。

验证（本机，`/tmp/m28.ps1` 在真实 `ShowDialog` 上下文里跑）：
- `Open-PanelUrl 'not a url at all'` → catch 接住，crashlog 记 `InvalidOperationException`，窗口不死。
- 模拟 Click handler 直接 `throw` → Dispatcher handler 接住，crashlog 记 `RuntimeException`，窗口不死。
- 同样的 throw 在改之前（无 Dispatcher handler）会让 `ShowDialog` 抛 `MethodInvocationException`、进程退。

回归：解析 + 15 项全 PASS（`single-instance` 见下文 Blockers）。


### P0-2 · `sc.exe start` 同步等待（**已落地**）

改动：`lib/poll.ps1` 新增 `Invoke-ServiceStart`，`Invoke-PendingCommands` 的 `'start'` 与
`'restart'` 末步改调它。`ServiceController.Start()` 立即返回，不等 RUNNING。

报告给的代码两处坑，落地时都避开了（见 docs/HANDOFF.md P0-2 原始复核）：
1. `ServiceController.Status` 对不存在的服务返回空串——先判空走 `Invoke-Sc` 取 sc.exe 退出码。
2. `Start()` 对已运行/无权限抛 `MethodInvocationException`，内层是英文包壳——catch 后回落 `Invoke-Sc`，
   经 `Convert-ScExitCode` 出中文文案。

验证（本机非管理员，`/tmp/m29.ps1`）：
- 已运行（Spooler）：`already Running` → return `$true`，不调 `Start()`。
- 不存在（zzz-no-such-xyz）：`Status empty` → `Invoke-Sc` 兜底 → exit 1060「服务未安装」。
- 被禁用（SysMain）：`Start()` 抛 → catch → `Invoke-Sc` 兜底 → exit 5。

回归：解析 + `poll-commands` / `parallel-probe` 等均 PASS。


## 下一步（直接做，勿重问范围）

> 状态：P0-1 / P0-2 / P1 / P2 / P4 已落地并提交。P3 判定收益过小，不做。

**已提交并推送（本分支 `refactor/generic-tool-and-audit-fixes`）**
```
a03d0fe fix: 删除中的卡片被探测结果刷回「已停止」并重新点亮按钮
cfebe47 refactor: 破坏性操作色收口到 theme.ps1 的 $script:T
323681b refactor: 精简本轮的参数写法与日志清理调用点
4b269eb refactor: 剩余硬编码常量收口到 config.json
ae7e4fe feat: 日志根可配置（config.LogDir），默认仍仓内 logs/
98ad8a7 docs: 落 HANDOFF，记录本轮审计复核与 P0-P4 落地
90dcd38 refactor: 拆分 add-svc.ps1 / util.ps1 为单职责模块
86e1f50 fix: 日志轮转档保留策略，logs/ 不再无界增长
faf9280 fix: Convert-ScExitCode 给退出码 5 加映射
daf3779 fix: sc.exe start 同步等待改 ServiceController 异步
e023be3 fix: 打开面板崩溃口 + Dispatcher 级异常兜底
```

### P5 · 删除中的过渡态被探测结果覆盖（**已落地**）

`Update-CardData` 的过渡态守卫只认「启动中/停止中」，「删除中」不在表里。删除走后台
stop → Wait-Stopped ≤6s → nssm remove confirm，期间探测每 4s 一轮，于是卡片从
「删除中」被刷回「已停止」、按钮重新点亮——用户能对一个正在删除的服务点「启动」。

修法：`Update-CardData` 对 `$c.ST -eq '删除中'` 一律 return。该状态与启动/停止本质不同——
它没有「期望终态」可等，终态由 remove 回执决定（主脚本 ack 分支），期间探测报「已停止」
（删除本就先 stop）或「未安装」都只是过程中的中间态。

顺带收口过渡态设置的重复：新增 `card.ps1 Set-CardTransition`，启停与删除共用
（删除路径原本漏了 `LastToggle` / `ReadyToToggle`）。修 `dialogs.ps1` 时发现一处真 bug——
函数实参位置写 `[datetime]::Now` 会被当字面字符串，改传 `(Get-Date)`。

**该 bug 在 `84b2e3e` 已存在**，非本轮引入。

### P0-2 附带 · `Convert-ScExitCode` 的 1056 死映射（**已落地**）

给 `Convert-ScExitCode` 加了 `5 { '拒绝访问（可能非管理员）' }`，保留 1056 分支
（管理员路径仍有效）。验证：本机非管理员——Spooler/SysMain → exit 5 出中文文案；
zzz-no-such-xyz → exit 1060「服务未安装」。

### P1 · 日志无界增长（**已落地**）

`lib/util.ps1` 新增 `Remove-RotatedLogs`；`lib/config.ps1` 加 `LogKeepCount`(10) /
`LogKeepDays`(14)；主脚本 `ContentRendered` 后异步跑一次 + `Stop-Background` 收尾再跑一次。
验证：`/tmp/test-rotated.ps1` + `test-rotated2.ps1`（6 服务×4 档 → 删 12 留 25、
gui-crash.log 不动、幂等；单服务 20 旧档 → 删 10 留 10）。本机真实 `logs/` 干跑 deleted=0
（全部 ≤14 天，符合预期）。

**数字已核实**（原始记录保留）：`logs/` 实测 121 个文件 / 30.22 MB；轮转档 108 / 27.71 MB。
NSSM `AppRotateFiles` 只改名不删档，命名带 `T` 与毫秒（`NewAPI.err-20261001T154751.222.log`）。

**报告原片三处错（落地时已避开，留档备查）**：
1. `function Remove-RotatedLogs([string]$LogPath,[int]$KeepCount 10,...)` → 解析失败
   （`Missing ')' in function parameter list.`），默认值要写 `=10`。
2. `Set-Backdrop([System.IntPtr]$hwnd,[int]$type 2)` 同样错法，同样原因。
3. `$rot | Where-Object $_.FullName -notin $keepNames -and ...` 解析能过、**运行时抛**
   `ParameterBindingException`。`Where-Object` 属性简写只接受单个比较，多条件必须用
   `{ }` 脚本块。
正则 `\.(out|err)-\d{8}` 已验证可用：匹配带 T 与毫秒的真实命名，不误伤当前档
（`NewAPI.err` → `rotated=False`）。

### P2 · 日志根可配置（**已落地，安全的那半**）

外部建议「默认迁到 `%LOCALAPPDATA%\service-manager\logs`」，理由是「30MB 目录放仓根
会被同步/备份工具反复扫」。**该理由本机不成立**：无同步工具进程（Syncthing/Dropbox/
OneDrive/Resilio 均无），仓里无同步标记目录，`logs/*.log` 已被 `.gitignore` 挡住，
backup-guard 只碰 `~/.claude`。故**不做默认迁移**。

但报告没提到的真陷阱存在：已注册服务的 `AppStdout`/`AppStderr` 写死在注册表
`HKLM\...\Services\<名>\Parameters`，本机 5 个服务都指向 `D:\service-manager\logs\`。
改默认 LogDir 会让那些服务照旧写老路径、而本工具按新路径读——5 个服务的日志窗口
全变「无日志」，须逐个重新注册。

故只做安全的那半：新增 `config.LogDir`（默认 `''` = 仓内 `logs/`），想迁的人自己迁、
自己重注册；不迁的人零影响。

### P3 · 卡片精简（**判定不做**）

实测三种写法，收益比报告说的小一个量级（本机 6 卡，各 3 次独立进程）：

| 写法 | 首建（含一次性 JIT） | 预热后 | `New-Card` 函数体 |
|---|---|---|---|
| `New-Object -Property`（现状） | 282/311/287 ms | 12–19 ms | 51 行 |
| `::new()` 逐属性 | 255/249/262 ms | 4 ms | **52 行** |
| 小工厂 + `::new()` | 275/277/289 ms | 8–9 ms | 46 行 |

- 那 ~280ms 首建基本是省不掉的一次性成本（WPF 类型加载 + JIT），三种写法同区间。
- 报告的「−70~100 行」站不住：`::new()` 逐属性赋值**反而多一行**，减行只能靠工厂，
  而工厂只减 5 行。
- 唯一真实收益是预热后 12–19ms → 4ms，但那是翻页重建时一页省 ~10ms，用户无感。
- **不要**改成 `ItemsControl` 绑 `PSCustomObject`——不实现 `INotifyPropertyChanged`，
  WPF 绑定静默失效。这条报告说对了。

结论：不做。改动核心 UI 代码 + 无法真机验证渲染，换 ~10ms 预热收益，不划算。

### P4 · 结构拆分（**已落地**）

拆成 `lib/svc-input.ps1`（纯函数族 76 行）/ `lib/nssm.ps1`（41）/ `lib/logview.ps1`（110）/
`lib/dialogs.ps1`（144）；`lib/util.ps1` 220 → 160 行，`lib/add-svc.ps1` 280 → 61 行。
`docs/PROJECT.md` 模块拓扑与加载顺序已同步。

验证（`/tmp/loadorder.ps1` + `/tmp/isolate.ps1`）：
- 复刻主脚本加载顺序 → 23 个跨模块函数全部可解析，`New-MainWindow` 建成，
  `Get-LogFiles` 单参/双参各 44 文件，`Remove-RotatedLogs` 默认参数走 `$logDir` 回落。
- `svc-input.ps1` 单独点源（不加载 WPF/config/util）即可用——拆分的主要收益。
- `nssm.ps1` 自加载 `svc-input` + `svc-common`，单独点源后 5 个依赖函数全部可解析。
- 回归：解析 34 文件 + 27 项 PASS。

---

## 复核中推翻的报告主张（**别再按原报告做**）

1. **「`Add-Type -MemberDefinition`（Mica 的 DWM P/Invoke）单独实测 292ms，占加载期 59%」——归因反了。**
   贵的是「进程里第一次 `Add-Type -MemberDefinition`」，与编译哪段 P/Invoke 无关。
   按 GUI 真实顺序测：`WPF -AssemblyName` 92–99ms → **第一个 `-MemberDefinition` 119–305ms**
   → 第二个 6–13ms。把 Dpi 与 Dwm 顺序对调，贵的跟着换到 Dpi。
   单独隔离测（全新进程只调一个）：Dwm 219/207/529ms，Dpi 225/209/214ms，同量级。
   所以 `lib/theme.ps1:62` 那个 `Add-Type` 挪去哪都省不掉；报告提的
   「惰性化 + 推 `ContentRendered` 换 −300ms」不成立——只是把耗时挪到首帧之后，
   窗口可见时间不变，还多一次 Mica 闪。报告自己也写了「收益基本为零」，两者别混做。
2. **「`ForEach-Object -Parallel` 每轮新建 runspace 池，空转实测 38–66ms」——量不出这个数。**
   本机 20 轮：单元素 `min=2 / med=3 / max=16ms`；**空输入 `min=0 / med=0 / max=0ms`**。
   按 4s 周期约 900 轮/小时，池成本约 2.7s/小时，不是报告的 34–60s。
   「全停止时拉长到 15s」仍值得做（省的是唤醒与整轮扫描），但别按 38–66ms 论证。
3. **「CI 写的是 `push: branches: [main]`，当前分支的推送根本没触发过一次 CI」——不准确。**
   `.github/workflows/test.yml` 确有 `push: branches: [main]`，但同一文件还有
   `pull_request:`（无分支限制）。`gh run list` 显示当前分支已触发 **9 次 CI，全 success**
   （最近 37223964736，2026-10-04T18:19，`event=pull_request`）。
   真实缺口只是「直接 push 该分支不跑」，不是「从没跑过」。
4. **`-ThrottleLimit 8` 硬编码、`AppRotateBytes 5242880`、`AppStopMethodConsole 5000`、
   `Wait-Stopped` 的 300ms、DispatcherTimer 的 400ms 未收口——这条成立**，
   `lib/config.ps1` 确实漏了这几处，值得补 `ProbeIdleMs` / `ProbeThrottleLimit` 等键。

---

## Blockers

- **`single-instance` 测试在本机**改前改后**都失败**。
  根因已定位（不再是「疑似」）：本机 `Local\service-manager-gui` 这个 mutex **已被某个进程持有**
  （实测 `WaitOne(0) = False`）。`[Threading.Mutex]::new($true, $name)` 在 mutex 已存在时
  **不会给创建者所有权**，于是 `tests/test-single-instance.ps1:38` 的 `$holder.ReleaseMutex()`
  抛 `Object synchronization method was called from an unsynchronized block of code.`
  这是测试夹具的脆弱性（假设自己创建就持有），不是产品 bug。
  已确认**不是本轮改动引起的**——`git stash` 到干净 `84b2e3e` 同样复现；
  `84b2e3e` 在 CI 上是 success（干净 runner 无残留 mutex）。
  本会话验过的其它 26 项 + 解析全 PASS。

## 坑（本会话新踩，下次直接用）

- **HTTPS push 被重置**：`git push origin <branch>` 报
  `Recv failure: Connection was reset`（FlClash 7890 代理对 GitHub HTTPS 无效）。
  但 `gh` CLI 的 API 通道正常（`gh run list` / `gh api` 都通）。
  绕法：走 SSH over 443。已加 remote `gh443`（**未动 `origin`**）：
  ```
  gh443  ssh://git@ssh.github.com:443/xvyimu/nssm-service-manager.git
  ```
  推送用 `git push gh443 <branch>`。验证 SSH 通不通：
  `ssh -T -o ConnectTimeout=12 -p 443 git@ssh.github.com`
  返回 `Hi xvyimu! You've successfully authenticated` 即通（exit 1 是正常的——
  GitHub 不提供 shell access）。
- **MSYS 会改写 `/` 开头的参数**：`gh api /user/keys` 被解析成
  `C:/Program Files/Git/user/keys`。去掉前导斜杠写 `gh api user/keys`。
- **PowerShell 函数实参位置不能写 `[datetime]::Now`**：会被当字面字符串
  （`Cannot convert value "[datetime]::Now" to type "System.DateTime"`）。
  传 `(Get-Date)`，或先赋给变量。赋值语句位置（`$x = [datetime]::Now`）则合法。


## 关键文件

> 用**仓内相对路径**，不写绝对盘符——本文件曾指向旧克隆 `D:\service-manager\`（当前仓在
> `D:\projects\nssm-service-manager`），行号也随重构失效。行号会继续漂，定位以函数名为准。

- `lib/card.ps1` —— 卡片状态机：`Update-CardData` / `Set-CardTransition` / `Set-CardRollback` / `Test-CardToggleReady` / `Invoke-TransitionTimeoutEscape`。
- `service-manager-gui.ps1` —— Dispatcher handler（`add_UnhandledException`）；`$sync` 注入；CLI `-Add` 分支的单实例守卫。
- `lib/poll.ps1` —— 后台 runspace：`Invoke-PendingCommands` / `Invoke-Sc` / `Invoke-ServiceStart`；轮询周期。
- `lib/svc-common.ps1` —— 退出码/状态中文映射（`Convert-ScExitCode` / `Convert-ServiceStatus`）、删除序列（`Invoke-ServiceRemove`）、实证复核谓词（`Test-ServiceGone` / `Test-ServicePresent`）。**原先散在 `poll.ps1` 的 here-string 与 `nssm.ps1` 里，2026-10-08 起统一到本文件**——here-string 里的定义只进 runspace，UI 线程与 CLI 取不到。
- `lib/util.ps1` —— `Open-PanelUrl` / `Remove-RotatedLogs` / `Update-StatusTick` / `Test-GuiInstanceRunning`；`Get-LogFiles` 已移 `lib/logview.ps1`。
- `lib/config.ps1` —— 可调常量收口。
- `tests/run-all.ps1` —— 回归入口，改完必跑（解析检查 + 23 项）。
- `docs/PROJECT.md` —— 架构与设计决策 SSOT，动结构时同步。

## 决策与坑（本次新增）

- **本仓缺标准要求的文档**。`node ~/.claude/templates/bin/audit-docs.mjs --repo D:\service-manager`
  报 `docs/ARCHITECTURE.md`、`docs/adr/README.md`、`docs/lessons/README.md`、`docs/README.md`、
  `CHANGELOG.md`(仓根)、`docs/HANDOFF.md` 均缺失（本文件即补其中的 HANDOFF）。
  另有 `AGENTS.md` / `CLAUDE.md` / `CONTRIBUTING.md` / `SECURITY.md` 缺失告警。
  是否补齐是独立议题，**未做**，别混进 P0–P4。
- **报告里的代码片段不可信**。本次至少 3 处语法/运行期错误（见 P1）。
  外部审计的结论可以采信，代码片段必须自己解析一遍再抄——
  `tests/run-all.ps1` 的解析检查会拦住语法错，但拦不住 `Where-Object` 那种运行期错。
- **未验的部分**：真实 UAC 提权、真实 Mica 效果、真实 NSSM 服务生命周期，
  以及 P0-1 修完后的真机点击行为——本机测试全用替身/模拟，需要交互式复核。
