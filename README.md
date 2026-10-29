# nssm-service-manager

[![test](https://github.com/xvyimu/nssm-service-manager/actions/workflows/test.yml/badge.svg)](https://github.com/xvyimu/nssm-service-manager/actions/workflows/test.yml)

本地 Windows 服务的统一管理 GUI——PowerShell 7 + WPF，卡片式启停/健康探测/日志查看，零外部 npm 依赖。管 NSSM 服务（sc.exe / nssm.exe）。

![演示](assets/demo.gif)
![主界面](assets/screenshot.png)

## 为什么用它

NSSM 本身是命令行工具。服务一多，日常启停、查状态、看日志全靠背命令——这个工具把它们收敛成一个窗口：

- **一眼看全**——每张卡显示服务名、端口、健康圆点（绿=正常 / 橙=等待中或响应慢 / 红=无响应），六个服务一屏扫完
- **一个键一个方向**——卡片右上角是「关闭」「启动」两个按钮，各自只管一个方向；习惯双击的也能双击切换。右键管重启/日志/删除，8 秒冷却 + 健康门闩挡住误操作
- **配置是清单不是代码**——`services.json` 一份 JSON 列出所有服务，换机器复制即用；CLI 也有增删入口，脚本和 agent 可直接调用
- **健康探测不靠猜**——端口 TCP + HTTP 两档并行：服务在但响应慢标「超时」，端口没监听标「无响应」
- **安全默认**——删除要输入完整服务名确认；填入敏感环境变量时提示明文进注册表的风险

## 快速开始

```powershell
# 1. 装依赖（NSSM 用 scoop，或自行放置后设 NSSM_PATH）
scoop install nssm

# 2. 复制示例配置（config.json 可选，不复制就用内嵌默认值）
Copy-Item services.example.json services.json
Copy-Item config.example.json config.json

# 3. 跑回归测试（不需要管理员）
pwsh -NoProfile -File tests/run-all.ps1

# 4. 启动 GUI（会弹 UAC，NSSM/sc.exe 需要管理员）
pwsh -NoProfile -File service-manager-gui.ps1
```

日常用双击 `launch.vbs`（wscript 无控制台，不闪黑窗）→ UAC → 管理员 GUI。非管理员 PowerShell 入口会用它提权。

**UAC 与提权后的行为**：UAC 被拒时 `launch.vbs` 弹「需要管理员权限」提示并以退出码 1 结束，非管理员入口原样透传，日志里有 `Elevation launcher exited: code=1`。提权后的 GUI 由管理员进程持有，普通权限的任务管理器**结束不掉**它（UIPI 限制）——退出请用窗口 ✕ 或托盘「退出」。

NSSM 路径按三档探测：`$env:NSSM_PATH` → `Get-Command nssm.exe` → scoop 安装路径。都找不到时弹窗提示安装。进程声明 DPI Aware，高缩放屏下不糊。

**提权面**：`launch.vbs` 优先用 `C:\Program Files\PowerShell\7\pwsh.exe`，scoop 的 shim 只是次选——scoop 装在用户目录，中等完整性进程能替换它，下一次双击 + UAC 就是管理员权限。NSSM 也一样：启动时检查 `nssm.exe` 所在目录的 ACL，普通用户可写就在状态栏提示「建议改装到系统目录」（不阻断，scoop 默认就这么装）。

## 文件

| 文件 | 作用 |
|------|------|
| `launch.vbs` | 启动器（双击入口）：wscript 无控制台 → ShellExecute runas pwsh → 管理员 GUI，零黑窗 |
| `service-manager-gui.ps1` | 主入口：CLI 分支 + 提权 + 模块加载 + 窗口启动 |
| `lib/theme.ps1` | 系统字体、主题色、按钮样式、Mica P/Invoke |
| `lib/util.ps1` | 配置持久化（`Load-Svc` / `Save-Svc` / `Add-SvcEntry`）、状态栏与租约、日志轮转、安全检查、命令入队 |
| `lib/poll.ps1` | 后台 runspace 探测脚本块（Get-Service 批量 + TcpClient + HttpClient 健康探测）+ 命令执行 |
| `lib/svc-common.ps1` | UI 线程与后台 runspace 共用的原语（`Wait-Stopped` / `Invoke-ServiceRemove` / 退出码与状态中文映射 / `Invoke-ExternalQuiet`）——poll.ps1 构造 runspace 时前置其文本 |
| `lib/svc-input.ps1` | 纯函数族：输入校验、env 解析、敏感键名检测、NSSM set 参数组装（可单独点源，不加载 WPF/config） |
| `lib/nssm.ps1` | NSSM 注册/删除：`nssm-set` / `Install-NssmService` / `Remove-NssmService` |
| `lib/add-svc.ps1` | CLI 添加服务入口（`Add-SvcFromCli`，agent 友好，不弹 GUI） |
| `lib/dialogs.ps1` | GUI 对话框：`Show-Add` / `New-AddDialog`（只搭控件，留给无头测试）+ `Show-Remove` |
| `lib/logview.ps1` | 日志窗口：`Get-LogFiles` / `Show-Log` |
| `lib/config.ps1` | 可调常量集中收口，默认值内嵌，`config.json` 覆盖 |
| `lib/tray.ps1` | 可选托盘图标（`TrayEnabled` 打开才加载 WinForms）+ 关闭/最小化策略纯函数 |
| `lib/card.ps1` | 卡片构建 + 启停门闩与冷却 + 过渡态保护 + 右键菜单 |
| `lib/xaml.ps1` | 主窗口外壳（自定义标题栏 + 最大化/双击标题栏 + 工具栏 + 分页 + 状态栏） |
| `assets/icon.ico` | 自绘齿轮图标（窗口 + 任务栏） |
| `services.example.json` | 服务清单示例（复制为 `services.json`；后者已 git 忽略） |
| `config.example.json` | 可调常量示例（复制为 `config.json`；后者已 git 忽略） |
| `scripts/set-service-params-acl.ps1` | 收紧 NSSM 服务 `Parameters` 注册表键 ACL（见下） |
| `tests/run-all.ps1` | 语法检查 + 全部回归测试 |
| `tests/make-screenshot.ps1` | 离屏渲染主窗口导出 `assets/screenshot.png` |
| `tests/make-demo.ps1` | 离屏渲染 12 帧 PNG 序列，供 ffmpeg 合成 `assets/demo.gif` |
| `docs/IMPLEMENTATION-NOTES.md` | 实现注记：代码里的 `§小节名` 指针指向这里（踩坑记录、实测数据、为什么这么写） |
| `logs/` | NSSM 服务运行日志（`.out.log` / `.err.log`，git 忽略） |

## 功能

- 卡片网格填满主区域（默认 3 列 × 2 行六张，`PerPage` 可调），窗口缩放同步伸展；单页隐藏分页按钮
- 每张卡：服务名、端口、URL、状态圆点、健康说明、运行时长、打开面板、「关闭」「启动」两个按钮（关闭在左）
- 健康三档：`正常` / `超时`（服务在但响应慢）/ `无响应`（端口未监听或连接被拒）。进程在但探测没过时先显示「等待中」，超过 `WaitHealthyTimeoutMs`（默认 2 分钟）才升级为「无响应」——冷启动不给红点，真卡死也不会一直挂着等待中。恢复要连续两次探测正常，单次抖动不算
- 状态覆盖 SCM 全部取值：`已停止` / `启动中` / `运行中` / `停止中` / `已暂停` / `暂停中` / `继续中` / `未安装`。暂停态两个按钮都禁用，副标题提示用右键「重启」**尝试**恢复——这条未实测：本机没有可暂停的服务，且暂停/恢复需管理员；能否接受 STOP 控制码由各服务自己的控制处理函数决定
- 按钮各管一个方向（启动只在未运行时可点、关闭只在运行中可点，过渡态两个都禁用）；双击卡片仍是切换（8 秒冷却 + 健康门闩：只有运行中且健康正常才允许关闭）
- 过渡态保护：启动中/停止中时，在途的旧探测不覆盖用户刚触发的过渡态，直到同方向终态探测到达才收尾
- 右键卡片 = 启动/停止/重启/面板/日志/安全检查/删除（删除需输入完整服务名；走后台命令队列，UI 不冻结）
- 后台 runspace 探测（批量 `Get-Service` + 并行 TCP/HTTP），UI 线程只取结果刷卡片；命令入队并唤醒后台，每次探测之间优先处理
- 后台不会因为一条命令而瘫痪：单条命令抛异常、外部进程挂住（`ExtCommandTimeoutMs` 超时即 Kill）、runspace 整个退出——三种情况都有对应处理，最后一种会在状态栏提示重启
- 中间态（启动中/停止中/暂停中/继续中）状态查询 1 秒一次，健康探测仍按 4 秒限流，不互相拖累
- `sc.exe` 失败时状态栏给中文原因（1056 已在运行 / 1060 服务未安装 等），不是裸数字
- 日志查看器支持轮转历史（`*.out-*.log` / `*.err-*.log`）下拉切换
- 单实例互斥：重复启动只保留第一个窗口；互斥体用 `Global\` 命名空间，计划任务/SSH 会话里跑 CLI 也能看到 GUI 正在运行。重启走 stop→轮询 Stopped（≤6s）→start，避免端口未释放导致 bind 失败
- 删除后卡片缓存清零，同名重建显示新端口/URL；配置变更后翻页命中缓存也刷新
- 浅色高对比 + 系统 Mica 背景；主题色统一收口在 `lib/theme.ps1` 的 `$script:T`，改色只动一份
- 默认关闭即退出、最小化进任务栏；需要常驻可开托盘（见 `TrayEnabled` / `MinimizeToTray` / `CloseToTray`）

## 托管的服务

`services.json` 是每台机器自己的配置（已 git 忽略）。克隆后复制示例并按需改：

```powershell
Copy-Item services.example.json services.json
```

示例条目（服务名/端口/面板全可改）：

| 服务 | 端口 | 面板 |
|------|------|------|
| MyAPI | 3000 | http://127.0.0.1:3000 |
| RouterA | 20128 | http://127.0.0.1:20128/dashboard |
| ProxyA | 8317 | http://127.0.0.1:8317/management.html |
| ServiceF | 9000 | http://127.0.0.1:9000/health |

**`services.json` 是 SSOT**：GUI 运行时增删服务会原子写回（`$PID.$guid.tmp` → `Replace`）。`Load-Svc` 有回落链 `services.json` → `services.example.json` → 空清单，前者缺失或 JSON 坏时读示例并弹框说明原因，首次运行不会一片空白。**新增服务请走 GUI「添加」或 CLI `-Add`**——NSSM 注册必须由脚本完成（stdout/stderr/停止超时/启动类型/日志轮转一并设置）。

### 重服务（冷启动慢）的单服务覆盖

`config.json` 的超时是**全局**的，假定服务秒起。AI 服务、冷启动 JVM 这类动辄一分钟才 listen 的，在 `services.json` 的该条目里加三项覆盖，缺省回落全局：

```json
{
  "ComfyUI": {
    "port": 8188,
    "url": "http://127.0.0.1:8188",
    "toggleTimeoutMs": 180000,
    "httpTimeoutMs": 12000,
    "tcpTimeoutMs": 800
  }
}
```

| 字段 | 回落 | 作用 |
|------|------|------|
| `toggleTimeoutMs` | `ToggleTimeoutMs` | 过渡态超时逃生阈值。重服务冷启动时调大，别让它显示「未知」 |
| `httpTimeoutMs` | `HttpTimeoutMs` | 该服务的 HTTP 探测超时 |
| `tcpTimeoutMs` | `TcpTimeoutMs` | 该服务的端口探测超时 |

字段名大小写不敏感，必须是正整数毫秒。写错（`0` / 负数 / 非数字）时**只有该字段失效、回落全局**，服务条目照常保留，启动时弹一条提示说明是哪个服务的哪个字段——不会因为一个数字写错就把整份清单换成示例。这些字段由 `Read-SvcFile` 显式保留，GUI 增删别的服务不会抹掉。

> **环境变量与注册表暴露面：** NSSM 把 `AppEnvironmentExtra` 明文写进 `HKLM\SYSTEM\CurrentControlSet\Services\<服务名>\Parameters`，该键 ACL 默认允许 `BUILTIN\Users` 读取——本机任意标准用户无需提权即可读出明文。**含密钥的变量（`*_API_KEY` / `*_TOKEN` / `*SECRET` / `*PASSWORD` / `*ACCESS_KEY` / `*CREDENTIAL` / `*PRIVATE_KEY` / `*PASSPHRASE`）不要直接填环境变量框**，改为让服务本体从独立密钥文件读（仅 Administrators+SYSTEM 可读），路径不进注册表。GUI 与 CLI 在填此类键名时会提示；`*_FILE` 后缀仅在值看起来像路径时才跳过提示。要彻底收紧键 ACL 用下面的脚本。

### 收紧 Parameters 注册表键 ACL（可选，深度防御）

```powershell
# 管理员 PowerShell
pwsh -NoProfile -File scripts/set-service-params-acl.ps1 -ServiceName <服务名>
```

脚本流程：禁用继承（保留本键显式 ACE）→ 移除 `BUILTIN\Users` 与 `Everyone` 的全部 ACE → 确保 `Administrators` 与 `SYSTEM` 完全控制 → 读回校验无残留 ACE（Allow 与 Deny 都查）。失败时不自动回退——回退等于重新放宽权限，提示人工处理。

## 可调常量（config.json）

所有阈值收口在 `lib/config.ps1`，默认值内嵌、开箱即用。`config.json` 已 git 忽略；未知键忽略，覆盖值按默认值的类型校验——`"TcpTimeoutMs": "200ms"` 这种写法保留默认并给一条提示，不会让窗口起不来；解析失败同样不阻断启动，回落默认值并弹框。

| 键 | 默认 | 作用 |
|------|------|------|
| `PerPage` | 6 | 卡片每页数量（列数按 `ceil(sqrt(PerPage))` 自适应） |
| `TcpTimeoutMs` | 200 | 端口探测超时（TcpClient BeginConnect） |
| `HttpTimeoutMs` | 3000 | HTTP 探测超时（每请求一个 CancellationTokenSource；共享 HttpClient 的实例级 Timeout 已放开为无限，否则 per-service 的更大值改不动单次请求） |
| `CrashLogMaxBytes` | 524288 | `gui-crash.log` 轮转阈值（512 KiB，超则挪成 `.1`） |
| `ToggleCooldownMs` | 8000 | 双击启停冷却（`card.ps1` Invoke-CardToggle） |
| `ToggleTimeoutMs` | 45000 | 过渡态超时逃生：回执丢失时按到达的探测值收敛并解封按钮。须大于正常路径最长耗时——启动失败回落 `sc.exe start` 走 SCM 同步管道，上限 `ServicesPipeTimeout`（**2026-10-28 实测该路径 30.0s**），故留 15s 余量。服务仍在同一过渡态时计时刷新（慢启动不误判），累计超 `TransitionHardCapFactor` 倍后强制逃生。单服务可单独调大，见「重服务」 |
| `TransitionHardCapFactor` | 10 | 过渡计时刷新的硬上限倍数，防止永久卡在中间态的服务把逃生口刷掉 |
| `WaitHealthyTimeoutMs` | 120000 | 「运行中但健康探测不通过」超过此时长：「等待中」升级为「无响应」+ 红点。冷启动一分钟起的服务可以调大 |
| `WaitStoppedTimeoutMs` | 6000 | 重启/删除前轮询 Stopped 的上限（`Wait-Stopped`，UI 与 runspace 共用一份） |
| `ExtCommandTimeoutMs` | 60000 | 外部命令（`sc.exe` / `nssm.exe`）超时：超时即 `Kill` 整棵进程树并返回 `exit=-1`，不让一条挂住的命令拖死后台 |
| `LogKeepCount` | 10 | 轮转日志保留份数，**按日志目录**各留前 N 份：共用 `LogDir` 的服务算一个目录，有独立 `AppStdout` 目录的各算一份配额 |
| `LogKeepDays` | 14 | 轮转日志保留天数：删除须同时满足「不在前 N 份」且「早于 N 天」，故窗口内高频轮转的档一份不删 |
| `LogDir` | `''` | 日志根覆盖；空 = 仓内 `logs/`。只影响新注册的服务——已注册服务的 AppStdout 写死在注册表。日志窗口与保留策略按每个服务实际的 AppStdout 目录走，`LogDir` 只在读不到时兜底（手工 `nssm install` 的服务也能被看到和清理） |
| `ProbeThrottleLimit` | 8 | 并行探测的 ThrottleLimit |
| `ProbeIntervalMs` | 4000 | 有运行中服务、或本轮执行过命令时的轮询间隔，也用作健康探测的最小间隔 |
| `ProbePendingMs` | 1000 | 有服务处于启动中/停止中/暂停中/继续中时的轮询间隔。**只加快状态查询**，健康探测仍按 `ProbeIntervalMs` 限流；被限流跳过的那一轮照样把新状态送给卡片（沿用上次健康值） |
| `ProbeIdleMs` | 15000 | 全停止、无在途命令、无中间态时的轮询间隔——省下空转的唤醒与整轮扫描 |
| `WaitStoppedPollMs` | 300 | `Wait-Stopped` 轮询步长 |
| `AppRotateBytes` | 5242880 | 单日志档轮转阈值（5 MiB，NSSM `AppRotateBytes`） |
| `AppRotateSeconds` | 86400 | 轮转年龄门槛：文件比这更新就不轮转。`AppRotateFiles=1` 是每次启动都轮转，频繁重启一天能堆几十个档 |
| `AppStopMethodConsole` | 5000 | 停止时给控制台进程的收尾毫秒 |
| `AckPollIntervalMs` | 400 | 命令回执/探测结果轮询的 DispatcherTimer 间隔 |
| `TrayEnabled` | false | 托盘总开关；关时下面两项无效，也不加载 WinForms |
| `MinimizeToTray` | false | 点最小化收进托盘（需 `TrayEnabled`） |
| `CloseToTray` | false | 关闭窗口收进托盘而非退出（需 `TrayEnabled`） |

托盘默认全关：最小化进任务栏、关闭即退出。三项都要开托盘总开关才生效；「退出」是唯一真正退出的入口（`CloseToTray` 下点 ✕ 只隐藏）。

## 依赖

- PowerShell 7（`pwsh`）
- NSSM 2.24（scoop 安装，或自备后设 `NSSM_PATH`）

## 添加新服务

**GUI**：工具栏「添加服务」→ 3 必填（服务名/端口/可执行文件）+ 高级折叠（URL/工作目录/启动参数/环境变量/运行账户/GPU 勾选）。

运行账户只列三个内置账户——`LocalSystem`（默认）、`LocalService`、`NetworkService`，**都不需要密码**。CLI `-Add` 没有账户参数，注册的即默认 `LocalSystem`；要改走 GUI 或 `nssm set <服务> ObjectName <账户名>`。自定义用户账户不做：nssm 要求密码，而密码只能作为命令行参数传（同机管理员在进程列表里可见），这个暴露面不值得为一次性操作引入。勾选「GPU / 桌面交互程序」且账户仍是 `LocalSystem` 时弹提示（不阻断）：GPU 程序在 LocalSystem 下未必拿得到显卡，视驱动与会话形态而定。

**CLI（agent 友好）**：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File service-manager-gui.ps1 -Add Name,Port,Exe[,Url,Dir,Args,Env]
```

不弹 GUI，注册 + 启动后退出。`Env` 多对用分号分隔（`KEY=VAL;KEY2=VAL2`），逗号也认。**值里自带分隔符不会拆坏**：只有「这一段含 `=`」才算新变量，不含 `=` 的片段并回上一个值，所以 `NO_PROXY=127.0.0.1,localhost`、`PATH=C:\a;C:\b` 都按一条处理；变量名不限于字母数字开头（`2FA_TOKEN=x`、`ProgramFiles(x86)=C:\PF` 照样识别）。

`services.json` 解析失败时 `-Add` **直接退出（码 1）**而不是继续——继续会把回落的示例清单写回你的真实配置。GUI 侧也不示弱：`Save-Svc` 在同样的条件下拒绝落盘，免得点一次「添加」就把示例清单覆盖真实文件（`Replace` 不带备份，`services.json` 又不在 git 里）。服务名限 `A-Za-z0-9_.-`；exe 必须是**存在的文件**的**完整本地路径**——UNC（含 `//host/share` 这种正斜杠写法）、目录、相对路径一律拒，因为注册成 LocalSystem 后，UNC 等于把提权面交给共享写者。两条入口共用 `Test-SvcInput`（校验顺序：名称 → exe → 端口 → 重名）；`Test-SvcAccount` 把关账户白名单；`Get-NssmSetSpec` 收口要 set 的全部键值，`Install-NssmService` 只负责执行与失败回滚。

## 测试与截图

```powershell
pwsh -NoProfile -File tests/run-all.ps1              # 语法检查 + 13 项回归
pwsh -NoProfile -STA -File tests/make-screenshot.ps1 # 重新生成 assets/screenshot.png
pwsh -NoProfile -File tests/make-demo.ps1            # 生成帧序列（.demo-tmp/，已 git 忽略）
```

| 测试 | 守什么 |
|------|--------|
| `test-dispatcher-priority` | 命令在探测间隙优先处理、空闲唤醒、FIFO |
| `test-card-actions` | 两个按钮各管一个方向、双击切换、20 个状态/门闩用例、反馈文案、暂停态双禁用 |
| `test-card-clock` | 时长显示（秒/分/时边界、负值）；首次观测不起算、启动完成才起算 |
| `test-transition-failure` | 过渡态失败回执、回滚、超时逃生、后台死亡逃生、方向门闩 |
| `test-poll-commands` | 命令队列、`StartPending` 不回落 `sc.exe`、中间态 1 秒轮询、状态/退出码映射表 |
| `test-per-service-timeout` | per-service 超时字段保留与 round-trip、坏值只丢字段、并行块 `$using:` 静态扫描 |
| `test-svc-input` | 输入校验四类拒绝、env 解析、账户白名单、`Get-NssmSetSpec` 参数组装 |
| `test-add-svc` | `sc.exe` 走 `Get-ScExe` 解析、CLI 注册、失败回滚、删除流程 |
| `test-config-params` | `config.json` 覆盖、坏 JSON 回落、runspace 注入值 |
| `test-remove-e2e` | 真 runspace 回执 → 真 UI tick 消费，成功/失败两向 |
| `test-dialogs-submit` | 两个提交体全分支；真弹一次「添加服务」并点击 |
| `test-external-timeout` | 外部命令挂住时被 Kill、返回失败；正常命令的退出码与输出不受影响 |
| `test-log-rotation` | 只删轮转档、当前档永不误删；NSSM 的 `T…` 时间戳格式能识别；保留窗口生效 |

NSSM、服务启停、配置保存及菜单的外部操作都用替身，不会注册测试服务或改 `services.json`。真实 UAC、Mica 效果与 NSSM 生命周期需本机交互验证。

**没有自动覆盖的**（改到对应代码时手工过一遍）：`Set-ServiceParamsAcl` 泄漏判据、托盘策略、启动器/UAC、单实例互斥（跨会话那条尤其）、`BeginStop` 的关闭路径、GUI 冒烟、状态栏租约、暂停态恢复路径。

`tests/probe-1053-timing.ps1` 是手动探针（需管理员，不在 `run-all` 里）：注册一个指向「存在但非服务程序」的 exe，让 SCM 拉起进程等它连 SCP，超时返回 1053。**2026-10-28 实测**：`ServiceController.Start()` 30032ms、`sc.exe start` 30034ms，与 `ServicesPipeTimeout` 默认 30000ms 吻合。注意不能用「exe 路径不存在」造场景——那条路 SCM 立刻返回 2，15ms 就结束，走不到管道等待。

**提交前密钥扫描（每个 clone 做一次）**：`git config core.hooksPath .githooks`，否则 `.githooks/pre-commit` 不执行。装 `gitleaks` 后钩子才真扫，没装只打一行警告放行。CI 另有独立任务跑 `gitleaks-action`，覆盖网页提交与 fork 的 PR，但只在推送 main 或开 PR 时触发。

演示 GIF 由 `make-demo.ps1` 离屏渲染 12 帧后合成：

```bash
ffmpeg -y -framerate 3 -i .demo-tmp/frame-%02d.png -vf "scale=640:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer:bayer_scale=4" assets/demo.gif
```

## 排错

`launch.vbs` 必须保持纯 ASCII：Windows Script Host 按系统 ANSI 代码页读取，UTF-8 中文注释在部分系统会触发 `800A0400` 编译错误。

`logs/gui-crash.log` 记录管理员状态、WPF 加载、窗口渲染和退出阶段，不记录 CLI 参数或环境变量。只有启动器退出码为 0 不能证明窗口已出现，应检查 `Window content rendered` 或实际窗口。

窗口起不来时先看这个日志：`Elevation requested via launch.vbs` 之后若无 `Single-instance mutex acquired`，要么 UAC 被拒（`Elevation launcher exited: code=1`），要么已有实例在跑（`Already running`）。

## Roadmap

按「最可能先做」排序，不承诺时间：

- **健康状态持久化**——目前刷新即弃，服务挂了只看当前页；计划落一份历史，打开即见「最近一次异常是什么时候」
- **分页再宽松**——`PerPage` 可调，但跨页过滤/排序还欠
- **服务配置差异对比**——`services.json` 换机器迁移时一键 diff 出不一致项
- **Web 只读视图**——局域网里不动 GUI 也能看健康（NSSM 常驻机器一般不接显示器）

提新方向用「功能请求」模板开 issue，修 bug 用「Bug 报告」模板（`.github/ISSUE_TEMPLATE/`）。

## 许可

MIT，见 `LICENSE`。
