# CHANGELOG.md — service-manager 迭代记录

> 本文件记录每次迭代的「为什么改」与「改了什么」，不重复 commit message（那是 git log 的事）。
> 代码是行为真相，本文件是**阶段性脉络**——读完能看懂这工具怎么走到今天。

## [未发布] — 2026-10-20：静默不执行的日志清理

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
