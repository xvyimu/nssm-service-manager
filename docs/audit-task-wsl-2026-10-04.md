# DSH 只读审计任务书 — service-manager WSL 集成（2026-10-04）

## 你的角色

只读审计员。**不改任何文件、不改注册表、不跑任何写操作**。沙箱已钉死 `read-only`，
写会直接被拒。所有结论必须附**原始命令输出**；拿不到证据的，明确写「无法证实」，
不要推测填充。

## 背景

`D:\service-manager` 是 PowerShell 7 + WPF 的本地 Windows 服务管理 GUI。本次迭代给它
加了 **WSL 发行版纳管**：`services.json` 支持 `type: "wsl"` 字段，把 WSL 发行版作为卡片
纳管 GUI。普通用户即可启停 WSL，不需管理员（不碰 `WSLService`）。

工作区改动（`git -C D:\service-manager diff --stat`）：

```
 assets/screenshot.png | Bin 48713 -> 48294 bytes
 lib/card.ps1          |  58 ++++++++++++++++++++---------
 lib/poll.ps1          | 100 +++++++++++++++++++++++++++++++++++++++++++-------
 lib/util.ps1          |  11 +++++-
 3 files changed, 137 insertions(+), 32 deletions(-)
```

未提交（`git status` 显示 working tree dirty）。本次审计核验**工作区当前状态**。

## 审计对象

- 仓库：`D:\service-manager`
- 改动文件：`lib/card.ps1` / `lib/poll.ps1` / `lib/util.ps1`
- 新增文档：`README.md`（更新）/ `docs/PROJECT.md` / `docs/CHANGELOG.md`
- 配置示例：`services.json`（本机实配，含 WSL 条目）

## 本轮要核验的具体主张（请逐条给判定）

### 1. Read-SvcFile 透传 type/distro 且 wsl 允许 port=0

读 `D:\service-manager\lib\util.ps1` 的 `Read-SvcFile` 函数：

- 是否把 `$j[$k].type` 和 `$j[$k].distro` 读入并写回 `$o[$k]`？
- wsl 类型是否跳过 `port` 1-65535 校验（`if ($t -ne 'wsl' -and ...)`）？
- 非 wsl 类型 `port=0` 是否仍会抛「端口非法」？

### 2. Get-WslState 解码逻辑

读 `D:\service-manager\lib\poll.ps1` 的 `Get-WslState` 函数：

- 是否用 `ProcessStartInfo` 重定向 `BaseStream` 到 `MemoryStream`？
- 是否用 `[System.Text.Encoding]::Unicode.GetString` 解码（UTF-16LE）？
- 是否 `Trim([char]0).Trim()` 去 BOM 和零宽？
- `$lines -contains $distro` 判断 Running/Stopped 的逻辑是否正确？
- `$distro` 为空时是否回落 `未安装`？

### 3. Invoke-WslCommand 启停命令

读 `D:\service-manager\lib\poll.ps1` 的 `Invoke-WslCommand` 函数：

- start 是否用 `@('-d', $distro, 'echo', 'ready')`？
- stop 是否用 `@('--shutdown')`？
- 未知 action 是否 `return $false`？
- exit code 非 0 时是否入 `$sync.msg.Enqueue` 反馈到 UI？

### 4. Invoke-PendingCommands 分流

读 `D:\service-manager\lib\poll.ps1` 的 `Invoke-PendingCommands` 函数：

- 是否从 `$sync.svc[$n]` 读 `info` 判断 `type -eq 'wsl'`？
- wsl 类型是否走 `Invoke-WslCommand`，其余走原 NSSM 路径（`sc.exe`）？
- wsl 路径是否 `continue` 跳过下面的 NSSM switch？

### 5. 收集阶段 WSL 走 Get-WslState

读 `D:\service-manager\lib\poll.ps1` 主循环（`foreach($n in $snap)` 收集阶段）：

- wsl 类型是否跳过 `Get-Service` / TCP / HTTP，直接 `Get-WslState` 入队？
- 批量 `Get-Service` 的 `$nssmNames` 是否排除了 wsl 类型（`[string]$i.type -ne 'wsl'`）？

### 6. 卡片 UI 适配

读 `D:\service-manager\lib\card.ps1` 的 `New-Card` 函数：

- 端口徽章 wsl 类型是否显示 `$info.distro` 而非 `":$($info.port)"`？
- endpoint 行 wsl 类型是否设为空字符串？
- 「打开面板」按钮 wsl 类型是否 `Collapsed`？
- 右键菜单 wsl 类型是否只有 `启动/停止/删除` 三项（无重启/面板/日志/安全检查）？
- 卡片属性是否挂了 `IsWsl` / `Type` / `Distro`？

### 7. Update-CardData 健康逻辑

读 `D:\service-manager\lib\card.ps1` 的 `Update-CardData` 函数：

- wsl 类型是否 `$healthy = $running`（运行中即健康，不走 HTTP）？
- 状态颜色映射 wsl 是否「运行中=绿，其余=橙/灰」？
- `LblUp.Text` wsl 类型运行中是否显示 `$c.Distro + ' 运行中'`？

### 8. Invoke-CardToggle 健康门闩

读 `D:\service-manager\lib\card.ps1` 的 `Invoke-CardToggle` 函数：

- wsl 类型 `ReadyToToggle` 在运行中时是否为 true（不拦截 stop）？
- 非 wsl 类型健康不正常时是否仍拦截 stop？

### 9. Update-CardInfo 缓存刷新

读 `D:\service-manager\lib\card.ps1` 的 `Update-CardInfo` 函数：

- 翻页命中缓存时是否刷新 `Type`/`Distro`/`PortText`/`Endpoint`/`OpenBtn`？
- wsl 类型是否设 `OpenBtn.Visibility = Collapsed`？

### 10. services.json WSL 条目

读 `D:\service-manager\services.json`：

- WSL 条目是否 `type: "wsl"` + `distro` + `port: 0` + `url: ""`？
- 其余 NSSM 条目是否无 `type` 字段（按默认 nssm 处理）？

### 11. 测试覆盖

读 `D:\service-manager\tests\run-all.ps1` 和测试文件：

- 是否有针对 wsl 类型的测试？（若有，列出测试文件名和断言要点）
- 若没有，明确写「WSL 集成无单测覆盖」。

### 12. 文档与代码一致性

读 `D:\service-manager\docs\PROJECT.md` 和 `D:\service-manager\README.md` 的 WSL 章节：

- 文档说的字段（type/distro/port/url 必填性）是否与 `Read-SvcFile` 实际读的字段一致？
- 文档说「`--shutdown` 比 `-t` 快 10 倍」——代码确实用 `--shutdown` 吗？
- 文档说「不碰 WSLService」——代码里有没有 `Get-Service WSLService` 或 `sc.exe stop WSLService` 之类的调用？

## 输出格式

按 finding 组织，每条给：

- **判定**：成立 / 部分成立 / 不成立 / 无法证实
- **证据**：原始命令 + 原始输出（不要转述）
- **若为「不成立」**：具体差在哪一行、哪个值

最后给一个总表：`条目 | 判定`。**不要编造任何未实测的内容**；无法复核的项单列一节
「本轮无法核验项」并说明原因（如沙箱限制、文件缺失）。

## 环境注意

- 你处于 read-only 沙箱，pwsh 是 ConstrainedLanguage：`.NET` 静态调用 / `Add-Type` /
  反射 / COM 会报 `Cannot create type. Only core types are supported`。
  用 `Get-ItemProperty` / `Get-Content` / `Test-Path` / `Get-ChildItem` 这类 cmdlet 读文件。
- 跑 git 前先 `$env:GIT_CONFIG_COUNT='0'`（否则 git 报 missing config key）。
- 不要去读 `D:\DSH\resources\app\dsh\node_modules\`（那是被改过的磁盘副本，非现役）。
- 不要执行 `wsl.exe`（那会真的启停 WSL，不是只读操作）——只读代码判断逻辑。
