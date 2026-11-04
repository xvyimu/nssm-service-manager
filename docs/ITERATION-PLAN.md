# ITERATION-PLAN.md — 收敛到长期可用的完整迭代方案

> **本文件 = 本次封板迭代的范围、顺序与验收权威。** 改范围先改这里，再动代码。
> 基线：`VERSION` = 0.9.0，`main` 工作树干净，20 项回归 + PSScriptAnalyzer 全绿（2026-11-04 实测）。
> 目标不是加功能，是把「状态可信 · 失败可恢复 · 提权边界 · 交付可复现」四件事一次性闭环。

## 0. 一句话结论

这个工具的核心机制已经成熟（命令纪元、过渡态逃生、SCM 实证、原子写 + `.bak`、F5 热重载、批量过期跳过），
**短板集中在四类**：失败原因 5 秒即蒸发、陈旧数据冒充实时、部分成功后 UI 先说成功、提权脚本位于用户可写目录。
按 P0→P4 做完即封板；P5 是一次性体验收尾。此后只在真实痛点出现时单条开案。

## 1. 现状证据（可复跑）

| 项 | 结果 | 命令 |
|---|---|---|
| 回归 | 20 项 + parser 全 PASS，exit 0（44.7 s） | `pwsh -NoProfile -File tests/run-all.ps1` |
| 静态分析 | Error/Warning = 0，exit 0 | `pwsh -NoProfile -File tests/analyze.ps1` |
| 发布包 | 26 项，96.9 KB，核心文件齐、无 `config.json`/`services.json`/`logs`/`tests` | `pwsh -NoProfile -File scripts/package-release.ps1` |
| 本机清单 | 6 项全部已注册、`AppStdout` 已登记、SCM 无依赖声明 | `sc.exe query` / 注册表 `Parameters` |
| 目录 ACL | 仓、父目录、`lib` 均为 `Users` / `Authenticated Users` **FullControl（继承）** | `Get-Acl` |
| 文档审计 | 缺 `docs/ARCHITECTURE.md`、`docs/README.md`、`docs/adr/`、`docs/lessons/`、根 `CHANGELOG.md` | `node ~/.agent-infra/templates/bin/audit-docs.mjs --repo .` |

已复现的四个具体缺陷（隔离副本内探针，未碰真实服务）：

1. **固定端口 Web 视图假成功**：`Start-WebView` 先把传入端口写进 `$sync.webPort`，GUI 的等待条件 `-not $sync.webPort` 立即为假；
   端口被占时仍打印 `listening`，`webError` 之后无人读取。→ 探针 `PortAdvertisedBeforeBind=true`。
2. **新鲜度造假**：结果入队 218 ms 后才被 UI 消费，`svcState.at` 记的是**消费时刻**，worker 未回传采样时刻。
   后台卡住时批量筛选用的是变新的旧值。→ 探针 `StoredTimestampIsUiConsumptionTime=true`。
3. **后台死亡后假活**：`bgDeathReported` 只处理「查询中」的卡，其余卡保留旧状态继续显示「运行中/正常」。
   → 探针 `CardStillSaysRunning=true / CardStillSaysHealthy=true`。
4. **删除部分成功先抹 UI**：`remove` 回执成功后先从内存与卡片移除，再 `Save-Svc`；保存失败时磁盘仍有条目，
   只有状态栏一句提示。→ 探针 `MemoryEntryRemoved=true / CardRemoved=true`。

## 2. 范围（封板做什么）

**纳入**：P0 提权边界 · P1 状态诚实 · P2 失败可恢复 · P3 退出生命周期 · P4 交付一致性 · P5 体验收尾。

**明确不做**（写进 `docs/PROJECT.md`「范围外」，避免下一轮被"优化"回来）：

- 不换栈、不重写、不引 MVVM / 第三方依赖、不增 `lib/` 模块（除 P1 允许在现有文件内加函数）。
- 不做自更新 / MSI / 代码签名 / 安装器；不把 GUI 拆成常驻服务或多进程 IPC。
- 不做 SCM 与文件的「事务」表述；只做两阶段 + 补偿 + 分歧可见。
- 不做依赖图、定时编排、远程管理、告警外发、多用户共用、驱动类服务。
- 不做暗色主题、拖拽排序、多页签、Web 视图扩容。
- 不为「更少行数」做重构：精简是软目标，功能冻结优先。
- 不在 CI 跑真 SCM + 真 nssm 的 e2e（需管理员，共享 runner 上必 flaky）。

## 3. P0 · 提权边界（唯一安全类封板项，部署为主）

**信任模型先说清**：进程以管理员运行，所以「脚本自己检查自己」只能发现装错，不能防攻击者。
信任只能来自 NTFS ACL 与固定路径。当前仓在用户可写目录，任何标准用户在 `lib\*.ps1` 加一行，
你下次双击并同意 UAC 后即执行。**这不是理论风险，是已确认的权限现状。**

| # | 动作 | 文件 | 验收 |
|---|---|---|---|
| P0-1 | 复制程序到管理员独占目录（`C:\Program Files\<产品名>\`），关闭继承，`Users` 只读+执行 | 无（部署） | `icacls` 显示 `Users:(OI)(CI)(RX)`；标准用户 `Set-Content` 被拒 |
| P0-2 | 数据（`services.json` / `config.json` / `logs`）随程序目录；确认进程可写 | 无（部署） | 启动后可正常启停一次并落一条健康史 |
| P0-3 | NSSM 固定路径，解析顺序改为「受信任固定路径 → Program Files → 拒绝」，**不再读取用户环境 `NSSM_PATH`** | `service-manager-gui.ps1:24-36` | 设 `NSSM_PATH` 指向别处仍用固定路径；缺失时弹明确错误 |
| P0-4 | `launch.vbs` 去掉 scoop / PATH 回退，找不到 Program Files 的 pwsh 就报错退出 | `launch.vbs:18-24`（Ask first） | 临时改名验证：报可读错误，不启动任意副本 |
| P0-5 | 启动自检扩面：程序目录、`lib`、NSSM 目录、清单、每个 `LocalSystem` 服务的 exe 目录，统一告警（不阻断） | `service-manager-gui.ps1`、`lib/util.ps1` | 从可写目录启动 → crash log 有 `Security:` 行 + 状态栏提示；从独占目录启动 → 无提示 |
| P0-6 | 添加服务时对「LocalSystem + 用户可写 exe 目录」给一次告警（不阻断） | `lib/dialogs.ps1`、`lib/svc-input.ps1` | `test-dialogs-submit.ps1` 新增用例：告警被调用且注册继续 |
| P0-7 | 文档写明「必须放在仅管理员可写目录」与部署步骤 | `README.md`、`docs/PROJECT.md` | 按文档从零部署一遍可通 |

**为什么 P0-3/P0-4 必须做**：`NSSM_PATH` 与 PATH 回退让标准用户可以决定管理员进程执行哪个 `nssm.exe`，
与 `launch.vbs` 注释里已经写明的威胁模型自相矛盾。ACL 自检是可见性，不是防护。

**回滚**：全部是路径与判据改动，`git revert` 单提交即可；部署侧回滚 = 从旧 zip 解压回原目录。

## 4. P1 · 状态诚实（数据可信是工具存在的唯一理由）

| # | 动作 | 文件 |
|---|---|---|
| P1-1 | worker 采样时刻随结果回传（`at`/`observedAt`），UI 只展示、不自己盖时间 | `lib/poll.ps1`、`lib/util.ps1:285` |
| P1-2 | 超龄判定：超过 `2 × ProbeIntervalMs` 显示「状态未知（N 秒未更新）」并禁写操作 | `lib/card.ps1`、`lib/xaml.ps1` |
| P1-3 | 后台 runspace 结束：**全部**卡片转未知、动作禁用、给「重新连接」入口 | `lib/util.ps1:308-317` |
| P1-4 | 操作失败原因落到卡片（`LastError = @{text; at}`），红字一行 + 「查看日志」，只在下次操作或状态变化时清除 | `lib/card.ps1:400-437` |
| P1-5 | 状态栏改为「动作日志」语义：带时间戳，结论驻留到下一动作或 30 s | `lib/util.ps1:222-230` |
| P1-6 | 语义收口：拆分「操作中」与「未知」（现在同色同词），未知用灰、操作中用琥珀 | `lib/card.ps1:471-496`、`lib/theme.ps1` |

**验收**：新增 `tests/test-freshness.ps1`（陈旧样本必须显示未知、不得显示运行中）、
`tests/test-bg-death.ps1`（后台结束后全部卡片非运行中、按钮禁用）；复跑本文件 §1 的 2、3 号探针必须翻转。
**回滚**：全部为展示层 + 结果字段新增，不改命令协议；旧测试若断言 `at` 形态需同步改。

## 5. P2 · 失败可恢复（只承认「证据成立」的状态）

**添加**（现序 install → set… → save → start）：

- P2-1 幂等续做：`Install-NssmService` 前先查服务是否存在；已存在且清单缺条目 → 跳过 `install`，只跑 `nssm set` + 保存 + 启动，
  文案改为「服务已存在，将补写清单并启动」。解决「注册成功、保存失败，用户只能 `nssm remove` 重来」。
- P2-2 `nssm set` 失败回滚保留，但失败信息从 `Write-Warning` 改为可持久显示 + 可复制的清理命令。

**删除**（现序 stop → wait → remove → 实证 → 内存删 → save）：

- P2-3 **保存成功前不移除卡片**。保存失败 → 卡片进入「已从系统删除，清单未保存」+ [重试保存]；
  不动 SCM、不回滚删除、不自动改 `.bak`。重启后磁盘条目仍在 → 显示「未安装」，再删一次即收敛。

**批量**：

- P2-4 结果聚合常驻：`尝试 N · 成功 S · 失败 F（名单+原因）`，失败项可在卡片上单独重试；
  确认框列名单（≤6 全列）。

**验收**：`tests/test-add-idempotent.ps1`（已存在 + 清单缺失 → 不重复 install、最终可启动）、
`tests/test-remove-save-fail.ps1`（保存失败时卡片保留、`services.json` 未变、可重试）；
复跑 §1 的 4 号探针必须翻转。**回滚**：单提交 revert，不涉及 schema 变更。

## 6. P3 · 退出与生命周期

| # | 动作 | 文件 |
|---|---|---|
| P3-1 | `Stop-Background` 幂等 + 有界：置 stop → `Set` wake → 等 1500 ms → 完成才 `EndInvoke`；未完成不解 runspace、不 Dispose | `service-manager-gui.ps1:250-266` |
| P3-2 | 退出前若有过渡态卡片或 `cmdQueue` 非空 → 确认框（默认「否」），文案点明风险 | `service-manager-gui.ps1` |
| P3-3 | 关闭前排空 `healthQ`（最多一次 drain），不再丢最后一条变化 | `lib/poll.ps1`、`service-manager-gui.ps1` |
| P3-4 | `CloseToTray` 取消关闭时不得触发收尾；托盘「退出」才走完整清理 | `lib/xaml.ps1:110-116`、`lib/tray.ps1` |

**验收**：`tests/test-shutdown.ps1`（伪 runspace + 慢命令，断言 < 2 s 返回、无异常、可重复调用、健康队列已排空）。
**回滚**：纯顺序与守卫调整，无接口变化。

## 7. P4 · 交付一致性（让「解压即用」真的成立）

| # | 动作 | 文件 | 验收 |
|---|---|---|---|
| P4-1 | 打包加 `assets/icon.ico`（不带 gif/png） | `scripts/package-release.ps1` | 解压后窗口与托盘有图标 |
| P4-2 | 自检清单改为从主入口 dot-source 列表派生，并加负向断言（不得含实配/日志/tests） | 同上 | 删一个 lib 文件 → 打包失败 |
| P4-3 | release 精确取 `service-manager-$version.zip`；tag 上补跑 `analyze.ps1`；上传幂等（`--clobber` 兜底） | `.github/workflows/release.yml` | 重跑同一 tag 不红 |
| P4-4 | 启动首行写 `version=`；`test.yml` 断言 `VERSION` 为 semver 且与 CHANGELOG 首节一致 | `service-manager-gui.ps1`、`.github/workflows/test.yml` | 改坏 VERSION → CI 红 |
| P4-5 | 文档修正：发布状态写实（远端已有 `v0.9.0`，本地领先 2 个提交，下一版需定 0.9.1/0.10.0）、计数不写死、补部署/升级/回滚三节 | `docs/HANDOFF.md`、`CHANGELOG.md`（仓根）、`README.md` | 按文档走一遍发布 |
| P4-6 | 补 `docs/README.md`（导航）、`docs/ARCHITECTURE.md`、`docs/adr/README.md`、`docs/lessons/README.md`、根 `CHANGELOG.md` | 新增 | `audit-docs.mjs --repo .` 无 error |

## 8. P5 · 体验收尾（一次性做完，之后冻结 UI）

按设计评审结论执行，不新增模块：

- **对比度**：状态文字全部 ≥4.5:1（橙 `#FFA500` → 深琥珀 `#8A5300`，红 `#FF0000` → `#C0392B`），色不单独承载语义。
- **层级**：服务名 19→17、状态 21→18；名字重新成为第一锚点。
- **新鲜度胶囊**：标题栏常驻 `6 个服务 · 1 个待处理` + `更新于 2s 前`，超阈值变「离线」。
- **批量**：入口从状态栏右键改为两个 ghost 按钮，右键保留。
- **对话框**：`IsDefault`/`IsCancel` + 差量提示（还差 N 字符 / 大小写不一致）+ `ScrollViewer` + 主按钮走主题色。
- **日志窗**：`Consolas` 11px、跟随开关、`最近 500 行 · 文件大小 · 更新时间`、打开文件夹/复制路径、去 emoji。
- **托盘**：tooltip 带状态计数；菜单加全部启动/停止/打开日志目录；首次关到托盘气泡提示；失败气泡（可选）。
- **DPI**：`SetProcessDPIAware()` → PerMonitorV2，失败回落；初始尺寸按工作区夹取（Ask first，属启动链）。
- **键盘/无障碍**：卡片可聚焦 + Enter/菜单键等价、`AutomationProperties.Name`、底栏写出 F5。

**验收**：7 条收敛判据全绿（见 §9）+ 安全/失败/退出/交付四组测试；视觉部分需真机目视一次。

## 9. 停止迭代标准（全绿即冻结）

**系统（5 条）**

1. 四个已复现缺陷全部翻转，且各有回归测试。
2. 任一失败在 30 s 内、不翻页、不重开窗口，就能在发起它的卡片上看到原因与下一步。
3. 陈旧数据永不显示为「运行中」；后台死亡后所有卡片不再假装有状态。
4. 关闭不超过 2 s，无 `ObjectDisposed` 噪声，连续 20 次开/关一致。
5. 解压 zip 即可运行（含图标），程序目录为管理员独占。

**界面（4 条）**

6. 状态词 ≤ 8 个，一词一色一义；对比度全部 ≥4.5:1。
7. 三条键盘路径成立：Tab 到卡片 → Enter 动作 → 菜单键；Esc 关任一弹窗。
8. 6 个服务、150% 缩放下默认窗口无截断、无横向滚动、底栏可见。
9. 批量操作前有名单、后有聚合结果、失败可单独重试。

**冻结规则**：9 条全绿后本轮结束；此后只有「≥2 次真实使用摩擦」才开案，一次只改一条，
且必须先补一条能复现的测试。

## 10. 执行顺序、验证与回滚

| 批次 | 提交粒度 | 必跑 | 回滚 |
|---|---|---|---|
| P0 | 1 提交（代码）+ 部署文档 | 两条质量门 + 从独占目录启动一次 | `git revert` + 旧 zip |
| P1 | 2 提交（worker 字段 / UI 展示） | `run-all` + 两个新用例 + 探针复跑 | 单提交 revert |
| P2 | 2 提交（添加幂等 / 删除保存失败） | 同上 + 手动冒烟一次 | 单提交 revert |
| P3 | 1 提交 | `test-shutdown` + 20 次开关 | 单提交 revert |
| P4 | 3 提交（打包 / CI / 文档） | 打包 + `audit-docs` + CI 绿 | 单提交 revert |
| P5 | 3 提交（信任 / 安全交互 / 边缘） | 9 条判据 + 真机目视 | 逐批 revert |

**每批完成后**：`git diff` 只含点名文件；`run-all.ps1` 与 `analyze.ps1` 全绿；文档同步；再进下一批。
**发布**：全部批次完成后 `VERSION` 升 1.0.0，打 tag，走 release workflow（外发按门槛先问）。

## 11. 执行记录（2026-11-04）

| 批次 | 状态 | 证据 |
|---|---|---|
| P0 提权边界 | 已落地并部署 | `scripts/deploy-local.ps1` 跑通（exit 0）；`Program Files\ServiceManager` 的 `Users` 只有 RX，非管理员写测试被拒；`nssm.exe` 已固定在 `Program Files\nssm` |
| P1 状态诚实 | 已落地 | 六个新用例 + `test-freshness` / `test-bg-death` 全 PASS；§1 的 2、3 号缺陷已翻转 |
| P2 失败可恢复 | 已落地 | `test-add-idempotent` / `test-remove-save-fail` 全 PASS；§1 的 4 号缺陷已翻转 |
| P3 退出生命周期 | 已落地 | `test-shutdown` / `test-exit-confirm` 全 PASS |
| P4 交付一致性 | 已落地 | 打包含图标、负向断言通过；`VERSION` 与 CHANGELOG 首节一致；`audit-docs` 0 error |
| P5 体验收尾 | 已落地，待目视 | 语义色全部 ≥4.5:1（theme 注释记了比值）；无头窗口断言通过 |
| 全套回归 | 绿 | 26 项 + parser，exit 0 |
| 静态分析 | 绿 | `PSScriptAnalyzer` Error/Warning = 0 |

**仍未完成（需人参与）**：真机目视一次（Mica 叠色、托盘气泡、多屏缩放）；`VERSION` 1.0.0 的 tag 与 push
（外发动作，按门槛先问）。

## 12. 日常运维（封板后照这个走）

- **每天**：双击快捷方式 → 看标题栏胶囊与卡片红点 → 有红点右键看日志。
- **故障定位顺序**：卡片失败条 → `logs/gui-crash.log` → `logs/health/health-<日期>.ndjson` → `sc.exe query <名>`。
  不要先怀疑 `nssm set`：它只写配置，不拉起服务。
- **升级**：解压新 zip 覆盖程序文件，保留 `services.json` / `config.json` / `logs`；配置键只增不删。
- **回滚**：还原旧 zip；清单如需回退，用 `services.json.bak`（同目录，`Save-Svc` 每次写前生成）。
- **大版本后**（Windows / PowerShell / NSSM）：跑两条质量门 + 手动启停一次 + 看一次日志。
- **单条服务注销**：清单删条目 → 备份 `Parameters` → `sc stop` → `nssm remove <名> confirm` → `sc query` 得 1060；
  「整理干净」不含删程序目录与数据目录。

## 13. 「一直用不需要改进」的现实边界

**能承诺**：范围冻结；每个已知失败模式都有可见状态与恢复路径；发布可复现；升级/回滚三步内完成。

**不能承诺**：Windows / SCM / NSSM / PowerShell 大版本行为不变；ACL 或安装路径被改后安全前提失效；
换机迁移；新服务形态（驱动、依赖桌面会话、域账户）；多用户共用；上游 NSSM 停止维护。

维护下限：每次 OS / pwsh / NSSM 大版本后跑两条命令 + 一次冒烟；其余时间只读 crash log。
一旦需要定时编排、依赖关系、远程操作或第 7 类服务形态，那是另一个产品，不应塞进这个仓。
