<!-- doc-template: project/HANDOFF v1 -->
# HANDOFF

> **更新日：** 2026-10-05
> **状态：** 进行中（P0-1 / P0-2 / P1 / P4 已落地并提交；P2 / P3 未做）
> 本文件**无日期后缀**（带日期会让链接永久腐烂）。当前在哪一天由上一行回答。

---

## 上一段做到哪

对 `refactor/generic-tool-and-audit-fixes`（HEAD `84b2e3e`）做了一轮审计复核，
基线自己跑过：`pwsh -NoProfile -File tests/run-all.ps1` → 解析 + 16 项全 PASS。

外部审计报告给了 P0-1 / P0-2 两个崩溃口和一些性能主张。复核结论：**两个崩溃口成立，
但报告里几条性能归因是错的，不能照抄**。下面每条都标「已验证 / 已推翻」，附本机实测。

**本轮已落地 P0-1、P0-2**（工作区未提交，`git status` 见 `M lib/card.ps1 lib/poll.ps1 lib/util.ps1 service-manager-gui.ps1`）。

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

> 状态：P0-1 / P0-2 / P1 / P4 已落地并提交。剩下 P2 / P3。

**已提交（本分支 `refactor/generic-tool-and-audit-fixes`）**
```
90dcd38 refactor: 拆分 add-svc.ps1 / util.ps1 为单职责模块
86e1f50 fix: 日志轮转档保留策略，logs/ 不再无界增长
faf9280 fix: Convert-ScExitCode 给退出码 5 加映射
daf3779 fix: sc.exe start 同步等待改 ServiceController 异步
e023be3 fix: 打开面板崩溃口 + Dispatcher 级异常兜底
```

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

### P2 · 日志根迁到 `%LOCALAPPDATA%\service-manager\logs`

- 现状 `logs/` 在仓根，会被同步/备份工具反复扫。config 可覆盖。

### P3 · 卡片精简（**方向对，数字要重估**）

- 抽 `New-TextBlock` / `New-Border` 小工厂 + 用 `::new()` 直接赋属性，值得做。
- **不要**改成 `ItemsControl` 绑 `PSCustomObject`——它不实现 `INotifyPropertyChanged`，
  WPF 绑定静默失效，等于把状态刷新全打回手写。这条报告说对了。
- 建控件成本实测（本机，6 卡）：
  - 独立进程首建：`New-Object -Property` 135/65/70ms vs `::new()` 91/59/49ms。
  - 预热后：两者都 0–3ms。
  - 报告说的「6 卡 120ms ≈ 20ms/张」量不出；首建的差价主要是一次性 JIT/程序集加载，
    与建卡数量无关。收益按「首屏 −30~60ms」估更稳，别按 −120ms 报。

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

- **`single-instance` 测试在**改前改后**都失败**（同一台机器同一会话里）：
  `tests/test-single-instance.ps1:38` 的 `$holder.ReleaseMutex()` 抛
  `Object synchronization method was called from an unsynchronized block of code.`
  这是因为 `$holder = [Threading.Mutex]::new($true, $mutexName)` 在主线程创建并持有，
  但脚本块里 runspace 在另一线程，主线程创建的持有权与 runspace 线程的 `OpenExisting + WaitOne(0)`
  让 OS 把所有权判给了 runspace 线程，主线程 `ReleaseMutex` 时线程不匹配就抛。
  已确认**不是我改的代码引起的**——`git stash` 到干净 `84b2e3e` 也复现。
  这是 pre-existing 的环境敏感测试（`single-instance` 在 `84b2e3e` 的 CI 上是 success，
  本机之前也能跑过；疑似有残留 pwsh 进程占着 `Local\service-manager-gui` mutex）。
  本会话验过的其它 15 项 + 解析全 PASS。


## 关键文件

- `D:\service-manager\lib\card.ps1` —— P0-1 的两处 `Start-Process`（第 95、134 行）。
- `D:\service-manager\service-manager-gui.ps1` —— P0-1 的 Dispatcher handler 落点（第 118 行后）；P0-2 的 `$sync` 注入（第 141 行）。
- `D:\service-manager\lib\poll.ps1` —— P0-2 的 `Invoke-PendingCommands` / `Invoke-Sc` / `Convert-ScExitCode`；P1 的轮询周期。
- `D:\service-manager\lib\util.ps1` —— P0-1 的 `Open-PanelUrl` 落点；P1 的 `Remove-RotatedLogs` 落点；`Get-LogFiles` 的轮转档识别可复用。
- `D:\service-manager\lib\config.ps1` —— P2 / P4 的收口键落点。
- `D:\service-manager\tests\run-all.ps1` —— 回归入口，改完必跑（解析检查 + 16 项）。
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
