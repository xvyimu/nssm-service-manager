# PROJECT.md — service-manager 架构与设计决策

> 仓库 SSOT：代码是行为真相，本文件是**为什么这么做**的真相。代码改了行为不改这里就是漂移。
> 产品表入口：`D:\projects\README.md`。本仓在那张表里登记的「跑在哪」= Windows 原生（绑 WPF / sc.exe / nssm.exe，不进 WSL）。

## 一句话定位

PowerShell 7 + WPF 的本地 Windows 服务管理 GUI。卡片式启停 / 健康探测 / 日志查看，零外部 npm 依赖。管一类对象：

- **NSSM 服务**：`sc.exe` 查状态 + `nssm.exe` 注册/删除 + TCP/HTTP 双档健康探测

## 技术栈选型理由

| 选型 | 为什么不是别的 |
|------|---------------|
| PowerShell 7 + WPF | 本机已装 pwsh；WPF 卡片渲染比 WinForms 灵活，Mica 玻璃背景走原生 DWM API；不用 Electron（重）也不用 WinForms（卡片样式受限） |
| NSSM | Windows 原生 `sc.exe` 不能给任意 exe 加日志重定向和轮转；NSSM 补这两块，是社区事实标准 |
| 后台 runspace + ConcurrentQueue | UI 线程绝不碰 I/O（`Get-Service` / `TcpClient` / `HttpClient` 都可能阻塞）；结果回队列，DispatcherTimer 400ms 轮询取 |
| `ForEach-Object -Parallel` 探测 | 6 服务串行 TCP+HTTP 最坏 19 秒；并行后最坏 3.2 秒（HTTP 超时上限） |
| 单实例 Mutex | 重复双击启动器是常见操作；Mutex 进程级，崩溃自动释放，不卡死 |
| 配置层示例+实配分离 | `services.json` / `config.json` 每台机器自定，已 git 忽略；示例进仓保证克隆即跑 |

## 模块拓扑

```
service-manager-gui.ps1（主入口：CLI 分支 + 提权 + 模块加载 + 窗口启动）
├─ lib/config.ps1     可调常量收口（PerPage/超时/轮转/冷却/托盘/日志保留）
├─ lib/theme.ps1      系统字体、主题色 $script:T、按钮模板、Mica P/Invoke
├─ lib/util.ps1       配置持久化（Read-SvcFile/Load-Svc/Save-Svc）、命令入队（Send-ServiceCommand）、
│                     打开面板（Open-PanelUrl）、日志轮转保留（Remove-RotatedLogs）、
│                     安全检查（Resolve-ServiceExeDir/Show-SecurityCheck）
├─ lib/svc-input.ps1  纯函数族：输入校验（Test-SvcInput/Test-SvcAccount）、env 解析
│                     （ConvertTo-EnvPairs/Test-EnvPairs/Find-SensitiveEnvKeys）、
│                     NSSM set 规格（Get-NssmSetSpec，含 ObjectName）
├─ lib/nssm.ps1       NSSM 操作：nssm-set / Install-NssmService / Remove-NssmService
├─ lib/logview.ps1    日志查看器：Get-LogFiles（当前+轮转枚举）+ Show-Log（WPF 窗口）
├─ lib/dialogs.ps1    GUI 对话框：Show-Add / New-AddDialog（添加服务；后者只搭控件，
│                     留给无头测试）+ Show-Remove（删除确认）
├─ lib/svc-common.ps1 UI 与 runspace 共用的服务操作原语：Wait-Stopped、退出码/状态中文映射
│                     （Convert-ScExitCode / Convert-ServiceStatus）、删除序列（Invoke-ServiceRemove）、
│                     删除/注册的实证复核（Test-ServiceGone / Test-ServicePresent）——均只此一份
├─ lib/poll.ps1       后台 runspace 脚本块：Get-Service 批量 + TcpClient + HttpClient 并行探测
├─ lib/add-svc.ps1    CLI 入口 Add-SvcFromCli（-Add 分支用）
├─ lib/tray.ps1       可选托盘（纯函数 Get-CloseAction/Get-MinimizeAction + 惰性 Initialize-Tray）
├─ lib/card.ps1       卡片构建 + 双击防抖 + 过渡态保护（Set-CardTransition）+ 右键菜单
└─ lib/xaml.ps1       主窗口外壳（标题栏 + 工具栏 + 分页 + 状态栏）
```

加载顺序在 `service-manager-gui.ps1` 里固定：config → theme → util → svc-input → nssm →
add-svc → logview → dialogs → tray → poll → card → xaml。config 必须最早（Write-CrashLog
首次调用在提权检测处，早于模块加载区）。`nssm.ps1` 与 `add-svc.ps1` 自加载其依赖
（`svc-input.ps1` / `svc-common.ps1`），单独点源也能工作。card 与 xaml 自加载 config
是为单测 dot-source 时不依赖完整顺序。

**`card.ps1` 与 `dialogs.ps1` 是双向依赖**：`card.ps1` 右键菜单调 `Show-Remove`，
`Show-Remove` 调 `card.ps1` 的 `Set-CardTransition`。故二者顺序不分先后——
PowerShell 函数体内符号是**调用时**解析，只要全部模块加载完再调用即可。

拆分动机：原先 `add-svc.ps1`（280 行 / 10 函数）混了校验、NSSM 注册、CLI 与两个对话框；
`util.ps1`（220 行）里塞了 90 行日志窗口。拆后每个文件单一职责，纯函数族（`svc-input.ps1`）
可被测试直接点源而不加载 WPF。

## 关键数据流

### 探测流（后台 → UI）

```
后台 runspace（poll.ps1 脚本块）
  循环：Invoke-PendingCommands → 拷 svc 快照 → 批量 Get-Service → 收集 → 并行探测 → 入队
                                        ↓
                          ConcurrentQueue $sync.queue
                                        ↓
UI DispatcherTimer 400ms tick → TryDequeue → Update-CardData
```

### 命令流（UI → 后台）

```
UI 点击 → Invoke-CardToggle → Send-ServiceCommand
  → cmdEpoch++ → 入 $sync.cmd 队列 → wake.Set() 唤醒后台
                                        ↓
后台 Invoke-PendingCommands → TryDequeue → 执行 → 入 queue 带 done=true
                                        ↓
UI DispatcherTimer → ack 分支 → 解封按钮 + 冷却
```

### 命令纪元（epoch）

每次 `Send-ServiceCommand` 递增 `$script:cmdEpoch`，随命令对象入队；后台执行完把同一 epoch 跟着结果回 UI。`Update-CardData` 的 **ack 分支**据此过滤：epoch 低于卡片 `PendingEpoch` 的命令回执直接丢弃——旧命令的回执不解除新命令的过渡态。

**普通探测结果不带 epoch（视为 0），仍按 `$transitionExpect` 方向匹配收尾**：过渡态期间，启动中只接受「运行中」收尾、停止中只接受「已停止」收尾，反向探测丢弃。这是有意保留的行为，不是「症状层补丁」——它让服务真正进入终态时过渡态退出。两处各管一段：epoch 管回执的新旧，方向匹配管探测的收尾。

竞态背景：用户点「停止」，服务慢停止期间旧探测仍报「运行中」，不该覆盖用户刚触发的「停止中」过渡态。方向匹配挡住反向探测；命令完成回执（epoch 匹配）解封按钮。若回执彻底丢失（后台异常退出），由 `Test-TransitionTimedOut` 超时逃生兜底（见「已知限制」与 `test-transition-failure.ps1`）。

## 设计决策

### 1. UI 线程不碰 I/O

`Get-Service` 拉 NetTCPIP CIM provider（常驻 +10MB）、`TcpClient` 可能阻塞、`HttpClient` 可能超时 3 秒——任何一个放 UI 线程都会冻结界面。全部挪到后台 runspace，结果经 ConcurrentQueue 回 UI 侧 DispatcherTimer 取。

### 2. svc-common.ps1 只此一份

原 `poll.ps1` 的 runspace 字符串里一份 `Wait-Stopped`、`add-svc.ps1` 里一份，靠「SYNC: 两处同改」注释人工同步。抽到 `lib/svc-common.ps1`：`poll.ps1` 构造 runspace 时把本文件内容前置进脚本字符串，`add-svc.ps1` / `nssm.ps1` 直接 dot-source——引用同一份文本。

同一处理随后扩到另外三处，动机相同（都是「两处各写一份、只改一边就会漂移」）：
- **退出码/状态中文映射**（`Convert-ScExitCode` / `Convert-ServiceStatus`）：原在 `poll.ps1` 的 here-string 里，只进 runspace——UI 线程与 CLI 看不到，导致同一个退出码在 GUI 给中文、在 CLI 给裸数字。移入本文件后三个作用域都可见。
- **删除序列**（`Invoke-ServiceRemove`）：stop → 等 Stopped → `nssm remove confirm` → 实证复核。原在 `nssm.ps1` 与 `poll.ps1` 各写一份。抽出来只共用「判定」，不共用「呈现」——UI/CLI 侧要抛异常、runspace 侧要入 msg 队列，由调用方决定。
- **删除/注册的实证复核**（`Test-ServiceGone` / `Test-ServicePresent`，底层 `Get-ServiceQueryCode`）：因为 NSSM 的 remove/install 失败也返回 0（见 `HANDOFF.md` 实测），成败必须按「服务是否真的消失/出现」判，不能信退出码。

### 3. Save-Svc 全量写回

`Save-Svc` 写的是调用方传入的整个对象——`$s | ConvertTo-Json -Depth 5` 全量序列化，不做字段筛选。`Read-SvcFile` 读入什么形状，就原样写回什么形状。

### 4. 配置层示例+实配分离

`services.json` / `config.json` 每台机器自定，已 git 忽略；`services.example.json` / `config.example.json` 进仓保证克隆即跑。`Load-Svc` 回落链：`services.json` → `services.example.json` → 空清单。前者缺失或 JSON 解析失败时读示例清单（并在窗口启动后弹框提示原因，见主脚本末尾对 `configWarning` 的处理），首次运行不会是一片空白。

### 5. 单实例 Mutex 进程级

重复双击启动器是常见操作。Mutex 是进程级的，进程退出 OS 自动释放，不会卡死。`AbandonedMutexException`（前一个实例被任务管理器杀掉或崩溃时）当成「已获取」——否则第二个实例也起不来。

### 6. 删除走后台命令队列

NSSM remove 是 stop → Wait-Stopped ≤6s → nssm remove confirm，同步执行会冻结 UI。删删除走后台命令队列（`act=remove`），UI 线程只关弹窗，回执由 DispatcherTimer 处理（从 svc 与卡片缓存移除，落盘配置，刷新分页）。

### 7. 敏感键名检测不阻断

`Find-SensitiveEnvKeys` 检测 `*_API_KEY` / `*_TOKEN` 等键名，提示用户改用 `*_FILE` 路径让服务本体从密钥文件读。不阻断注册——用户可能确有需要。`*_FILE` 后缀仅在值看起来像路径时才跳过提示，否则照样警告（键名后缀不等于值就是路径）。

### 8. 超时是「全局默认 + 单服务覆盖」

`config.json` 里的 `ToggleTimeoutMs` / `HttpTimeoutMs` / `TcpTimeoutMs` 是全局默认值，假定服务都秒起。重服务（AI 服务、冷启动 JVM，一分钟才 listen）在 `services.json` 的对应条目里加 `toggleTimeoutMs` / `httpTimeoutMs` / `tcpTimeoutMs` 覆盖，缺省回落全局。

两条实现细节值得记：

- **`Read-SvcFile` 必须显式带走这三个字段**。`Save-Svc` 写的是整份 `$script:svc`，读的时候只挑 `port`/`url`，用户手写的覆盖就会在下一次 GUI 增删服务时被静默抹掉——这类「配了但没生效」比报错难查得多。
- **这三个字段写错时不能抛**。抛了会落进 `Load-Svc` 的 catch，整份清单退回 `services.example.json`；GUI 里显示的是示例服务，用户点一次增删，`Save-Svc` 就把示例写回真实文件，**真实清单连同已注册服务一起丢**。现在的处理是：忽略该字段（回落全局）+ 记一条 `configNotices`，启动后单独弹一个「配置提示」框。`configNotices` 与 `configWarning` 分开，因为后者配套的弹框写着「当前使用恢复配置」，而这条路径并没有用恢复配置。
- **HTTP 探测的超时从实例级改成了每请求 CTS**。共享 `HttpClient` 的 `Timeout` 是实例级上限，单次请求改不动它，per-service 想设得**比全局更大**就做不到。现在实例级放开成 `Timeout.InfiniteTimeSpan`（注意是 `System.Threading.Timeout` 上的那个；`TimeSpan.InfiniteTimeSpan` 在旧运行时上取到 `$null`），每请求一个 `CancellationTokenSource`。

另外，卡片过渡态在**探测到服务仍处于同一过渡态**（`StartPending`/`StopPending`）时会刷新计时：服务确实还在动，不该按「回执丢了」处理。这让慢启动不必靠调大阈值也能正常收敛。

刷新必须有上限，否则逃生口会被自己顶掉：`TransitionStartedAt` 只在**进入**过渡态时记一次（`TransitionAt` 会被刷新、它不会），累计超过 `ToggleTimeoutMs × TransitionHardCapFactor`（默认 10 倍）就强制判超时。没有这条，一个永久卡在 `StopPending` 的服务会让卡片永久显示「停止中」、按钮永久禁用——而逃生正是为这种情况存在的。这也避免了依赖「SCM 一定会把 `StartPending` 收敛掉」这个未实测的假设。

### 9. 运行账户只给内置账户

添加服务对话框的「运行账户」只列 `LocalSystem` / `LocalService` / `NetworkService`。三者都是 nssm 认得的 well-known SID（`account.cpp` 的 `well_known_username` → 密码强制空串），所以 `nssm set <服务> ObjectName <账户名>` 一条 argv 就够，工具全程不碰凭据。

自定义用户账户需要一个密码，而 nssm 只收 `nssm set <服务> ObjectName <用户名> <密码>`——用户名走 additional、密码走 value，两者都是命令行参数，同机管理员在进程列表里可见（nssm 自己能做的只是用完 `SecureZeroMemory`）。这个暴露面不值得为一个一次性操作引入，故本工具不做；需要时用 `nssm edit` 或服务管理器改。

`Get-NssmSetSpec` 对 `LocalSystem` 和空值**不产生** `ObjectName`——那本来就是 `nssm install` 的默认值，写进去只是多一条无意义的 set，还会让「没选账户」和「选了 LocalSystem」两条路径分叉。

「是不是 GPU/桌面程序」由用户在对话框里勾选声明，不做自动判断：按 exe 名字猜不准，误报比不报更烦。勾了且账户仍是 LocalSystem 时弹一条提示，**不阻断注册**。

## 已知限制

- 真实 UAC、系统 Mica 效果与 NSSM 服务生命周期需在本机交互验证（单测用替身）
- `launch.vbs` 必须保持纯 ASCII（Windows Script Host 按系统 ANSI 代码页读取，UTF-8 中文注释在部分系统触发 `800A0400`）
- **`ToggleTimeoutMs` 的全局默认值是推出来的、不是量出来的**：启动失败回落 `sc.exe start` 走 SCM 同步管道，上限 `ServicesPipeTimeout`（本机未设 = 默认 30000ms）。该路径真实耗时未真机实测（需建服务，`tests/probe-1053-timing.ps1` 管理员跑），当前值 45000 是按「管道上限 + 6s 删除路径余量」推的。跑过探针才能确认够不够。
- **CLI `-Add` 与 GUI 不能并行**：两者都全量写回 `services.json`（`Save-Svc` 无合并语义），GUI 常驻时 CLI 新增会被 GUI 下一次保存覆盖。故 `-Add` 前检测单实例 mutex（`Test-GuiInstanceRunning`），GUI 在跑则拒绝并提示先关 GUI。
- **`Show-SecurityCheck` 的 ACL 判定是启发式**：只认 `Users`/`Everyone`/`Authenticated Users`/AppContainer SID 这几类宽泛主体 + `Write|Modify|FullControl`。目录若被改写为其它宽松形态（如某个具体用户账户 FullControl），判定为「否」。不是权威审计。
- **`NSSM_PATH` 只校验「存在 + 文件名为 nssm.exe」**：不校验签名/路径。该值随后以管理员身份被调用，故文件名校验只为挡住「指向任意 exe」；仍无法防御能改管理员进程环境变量的攻击者（那种场景已超出本工具的信任边界）。**2026-10-28 评估过加 `Get-AuthenticodeSignature`**：实测本机官方 scoop 包的 `nssm.exe` 是 `NotSigned`，加了会对所有正常安装误报，故不加。
- **`Open-PanelUrl` 直接 `Start-Process` `services.json` 里的 URL**：`services.json` 是用户自己的配置（非特权输入），但若其中含 `file:///` 或自定义协议，提权 GUI 下会以管理员打开。本地单用户工具的设计取舍。

## 测试

`tests/run-all.ps1` 统一执行：PowerShell 解析检查 + 25 项回归测试。详见 README「测试与截图」节。

CI（`.github/workflows/test.yml`）跑 PowerShell 回归（Windows runner）。
