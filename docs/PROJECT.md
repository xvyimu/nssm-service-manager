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
├─ lib/svc-input.ps1  纯函数族：输入校验（Test-SvcInput）、env 解析（ConvertTo-EnvPairs/
│                     Test-EnvPairs/Find-SensitiveEnvKeys）、NSSM set 规格（Get-NssmSetSpec）
├─ lib/nssm.ps1       NSSM 操作：nssm-set / Install-NssmService / Remove-NssmService
├─ lib/logview.ps1    日志查看器：Get-LogFiles（当前+轮转枚举）+ Show-Log（WPF 窗口）
├─ lib/dialogs.ps1    GUI 对话框：Show-Add（添加服务）+ Show-Remove（删除确认）
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

每次 `Send-ServiceCommand` 递增 `$script:cmdEpoch`，随命令对象入队；后台执行完把同一 epoch 跟着结果回 UI。`Update-CardData` 据此过滤在途旧探测——过渡态期间只接受 epoch ≥ 卡片 `PendingEpoch` 的回执，旧探测（无 epoch）直接丢弃。

这是为了解决一个竞态：用户点「停止」，服务慢停止期间旧探测仍报「运行中」，不该覆盖用户刚触发的「停止中」过渡态。原方案靠「方向匹配」做症状层补丁（启动中只接受运行中收尾），现在用 epoch 过滤更干净——旧探测一律丢，直到命令完成回执解封按钮，下一轮探测自然落到终态。

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

## 已知限制

- 真实 UAC、系统 Mica 效果与 NSSM 服务生命周期需在本机交互验证（单测用替身）
- `launch.vbs` 必须保持纯 ASCII（Windows Script Host 按系统 ANSI 代码页读取，UTF-8 中文注释在部分系统触发 `800A0400`）

## 测试

`tests/run-all.ps1` 统一执行：PowerShell 解析检查 + 20 项回归测试。详见 README「测试与截图」节。

CI（`.github/workflows/test.yml`）跑 PowerShell 回归（Windows runner）。
