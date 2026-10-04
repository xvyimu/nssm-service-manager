# CHANGELOG.md — service-manager 迭代记录

> 本文件记录每次迭代的「为什么改」与「改了什么」，不重复 commit message（那是 git log 的事）。
> 代码是行为真相，本文件是**阶段性脉络**——读完能看懂这工具怎么走到今天。

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
