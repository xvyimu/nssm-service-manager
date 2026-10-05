<!-- doc-template: project/HANDOFF v1 -->
# HANDOFF

> **更新日：** 2026-10-05
> **状态：** 进行中（P0-1 / P0-2 / P1 / P2 / P4 已落地；P3 未做，判定收益过小。本轮 T1–T7 已落地并提交，见下节）
> 本文件**无日期后缀**（带日期会让链接永久腐烂）。当前在哪一天由上一行回答。

---

## 上一段做到哪（本轮 T1–T7）

按 `service-manager-修复任务-提示词.md` 的七条任务逐条修复，各一个提交（基线 `eca4b86` 起）：

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

新增测试三个：`test-transition-failure.ps1`、`test-status-lease.ps1`、`test-log-retention.ps1`。
回归从 27 项增至 33 项 PASS；解析文件 34 → 37。唯一失败项仍是 `single-instance` 环境敏感问题。

**未验（如实标注，留给真机）**：真实 UAC 提权、Mica、NSSM 服务生命周期；交互式点击触发
Dispatcher 异常时状态栏的表现；启动失败路径（SCM 1053）的真实耗时——`ToggleTimeoutMs=30000`
是否够大取决于它，配置注释里已按「未实测」标注。

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

- `D:\service-manager\lib\card.ps1` —— P0-1 的两处 `Start-Process`（第 95、134 行）。
- `D:\service-manager\service-manager-gui.ps1` —— P0-1 的 Dispatcher handler 落点（第 118 行后）；P0-2 的 `$sync` 注入（第 141 行）。
- `D:\service-manager\lib\poll.ps1` —— P0-2 的 `Invoke-PendingCommands` / `Invoke-Sc` / `Convert-ScExitCode`；P1 的轮询周期。
- `D:\service-manager\lib\util.ps1` —— P0-1 的 `Open-PanelUrl` 落点；P1 的 `Remove-RotatedLogs` 落点；`Get-LogFiles` 的轮转档识别可复用。
- `D:\service-manager\lib\config.ps1` —— P2 / P4 的收口键落点。
- `D:\service-manager\tests\run-all.ps1` —— 回归入口，改完必跑（解析检查 + 19 项）。
- `D:\service-manager\docs\PROJECT.md` —— 架构与设计决策 SSOT，动结构时同步。

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
