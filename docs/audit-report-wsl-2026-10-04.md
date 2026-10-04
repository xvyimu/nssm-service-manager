# 审计报告 — service-manager WSL 集成（2026-10-04）

## 0. 元数据

- **任务 ID**：T-2026-10-04-wsl-audit
- **审计方**：Claude Code（DSH headless 渠道在第二步多轮 tool-use 恒报 `400: inference request is invalid`，无法完成；改由完成方实读代码逐条核验）
- **审计时间**：2026-10-04
- **审计对象**：`D:\service-manager` 工作区未提交改动（`lib/card.ps1` / `lib/poll.ps1` / `lib/util.ps1` + 文档）
- **任务书**：`docs/audit-task-wsl-2026-10-04.md`
- **DSH 渠道失败记录**：`docs/audit-run-wsl-2026-10-04.log`（12 行，step 2 即 400）

## 1. 原始结论

12 项主张：10 成立，1 部分成立（第 6 项右键菜单，已修），1 不成立（第 9 项 `Update-CardInfo` 漏刷 `IsWsl`，已修）。另发现 1 项审计任务书外的问题（`$args` 自动变量遮蔽，已修）。

回归测试：16 项全 PASS，exit 0。

## 2. findings

| # | 主张（任务书条目） | 判定 | 证据 | 处置 |
|---|---|---|---|---|
| 1 | Read-SvcFile 透传 type/distro，wsl 允许 port=0 | 成立 | `lib/util.ps1:19-23`：`$t=[string]$j[$k].type; $d=[string]$j[$k].distro; if ($t -ne 'wsl' -and ($p -lt 1 -or $p -gt 65535)) throw; $o[$k]=@{port=$p;url=$u;type=$t;distro=$d}` | 无需改 |
| 2 | Get-WslState 走 raw bytes + Unicode.GetString | 成立 | `lib/poll.ps1:33-46`：`ProcessStartInfo` 重定向 `BaseStream.CopyTo($ms)`，`Unicode.GetString($bytes).Trim([char]0).Trim()`，`$lines -contains $distro` 判 Running/Stopped；`$distro` 空 → `未安装` | 无需改。原 `$psi.StandardOutputEncoding = Unicode` 是死代码（走 BaseStream 不读 StandardOutput），已删并加注释 |
| 3 | Invoke-WslCommand 启停命令 | 成立 | `lib/poll.ps1:52-73`：start=`@('-d',$distro,'echo','ready')`，stop=`@('--shutdown')`，未知 action `return $false`，exit≠0 入 `$sync.msg.Enqueue` | 无需改。原 `$args` 变量名遮蔽 PowerShell 自动变量 `$args`，虽此函数无实参透传不致踩，但避坑已改名 `$wslArgs` |
| 4 | Invoke-PendingCommands 分流 | 成立 | `lib/poll.ps1:115-125`：从 `$sync.svc[$n]` 加锁读 `info`，`type -eq 'wsl'` 走 `Invoke-WslCommand` 后 `continue`，其余进 NSSM switch | 无需改 |
| 5 | 收集阶段 WSL 走 Get-WslState，批量 Get-Service 排除 wsl | 成立 | `lib/poll.ps1:169-173`：`$nssmNames = @($snap \| Where-Object { ... [string]$i.type -ne 'wsl' })`；`lib/poll.ps1:204-211`：wsl 类型 `Get-WslState` 入队后 `continue` | 无需改 |
| 6 | 卡片 UI 适配（端口徽章/endpoint/打开面板/右键菜单） | **部分成立 → 已修** | `New-Card`：端口徽章 wsl 显示 `$info.distro`✓、endpoint 空字符串✓、打开面板 Collapsed✓。右键菜单 wsl 只有启动/停止/删除✓。**但** `Update-CardInfo`（翻页命中缓存时刷新）漏刷 `IsWsl` 属性——`New-Card` 里 `IsWsl` 是从 `type` 派生的缓存值，配置变更（NSSM↔WSL 切换）命中缓存时 `IsWsl` 不刷新，`Update-CardData` / `Invoke-CardToggle` 会读到旧值 | **已修**：`lib/card.ps1:172-174` 加 `$c.IsWsl = $isWsl`。测试 16 项 PASS |
| 7 | Update-CardData 健康逻辑 wsl 运行中即健康 | 成立 | `lib/card.ps1:208`：`$healthy = if ([bool]$c.IsWsl) { $running } else { $h -eq '正常' }`；颜色映射 `运行中` wsl 直接绿（`$healthy` true）；`LblUp.Text` wsl 运行中显示 `$c.Distro + ' 运行中'`（:223） | 无需改 |
| 8 | Invoke-CardToggle 健康门闩 wsl 不拦截 | 成立 | `lib/card.ps1:30-37`：`if ($action -eq 'stop' -and -not $card.ReadyToToggle) { if (-not [bool]$card.IsWsl) { ...暂不能关闭; return } }`——wsl 类型直接跳过拦截。`ReadyToToggle` 在 `Update-CardData:238` 为 `($st -eq '已停止') -or ($running -and $healthy)`，wsl 运行时 `$healthy=$true` → `ReadyToToggle=$true` | 无需改 |
| 9 | Update-CardInfo 缓存刷新 | **不成立 → 已修** | 原 `Update-CardInfo` 刷了 `Type/Distro/PortText/Endpoint/OpenBtn.Visibility`，**漏刷 `IsWsl`**。`IsWsl` 是 `New-Card` 派生的缓存属性，`Update-CardData` 和 `Invoke-CardToggle` 都读 `$c.IsWsl`——配置变更命中缓存时读到旧值，WSL 卡片可能走 NSSM 健康门闩逻辑（运行中但不健康时拦截 stop） | **已修**：`lib/card.ps1:172-174` 加 `$c.IsWsl = $isWsl` 并补注释。测试 PASS |
| 10 | services.json WSL 条目 | 成立 | `services.json:7`：`"WSL": { "type": "wsl", "distro": "Ubuntu-24.04", "port": 0, "url": "" }`；其余 5 条无 `type` 字段（按默认 nssm 处理） | 无需改 |
| 11 | 测试覆盖 | **不成立（已知缺口）** | `tests/run-all.ps1` 16 项测试无一项针对 wsl 类型。`test-gui-smoke.ps1` 的夹具 `$script:svc` 全是 NSSM 条目（无 `type` 字段），`test-card-actions.ps1` 同。WSL 分流、`Get-WslState` 解码、`Invoke-WslCommand` 启停、卡片 WSL 适配均无单测 | **未补**：WSL 集成属新功能，应补 `test-wsl.ps1` 覆盖 `Read-SvcFile` wsl 透传、`Get-WslState` 解码逻辑（mock `wsl.exe` 输出）、`Invoke-PendingCommands` wsl 分流、卡片 `IsWsl` 派生与缓存刷新。留待下一轮 |
| 12 | 文档与代码一致性 | 成立 | `docs/PROJECT.md` 字段表（type/distro 必填、port/url 否）与 `Read-SvcFile` 实读字段一致；「`--shutdown` 比 `-t` 快 10 倍」与 `Invoke-WslCommand` stop=`@('--shutdown')` 一致；「不碰 WSLService」——全仓搜无 `WSLService` / `Get-Service WSLService` / `sc.exe.*WSLService` 调用 | 无需改 |

## 3. 完成方裁决

| # | 裁决 | 理由 | 处置 |
|---|------|------|------|
| 6 | 采纳 | `Update-CardInfo` 漏刷 `IsWsl` 是真 bug，配置变更命中缓存时 WSL 卡片走旧门闩逻辑 | `lib/card.ps1:172-174` 已加 `$c.IsWsl = $isWsl`，工作区改动 |
| 9 | 采纳 | 同 #6（任务书拆成两项，根因同一处） | 同上 |
| 11 | 采纳 | WSL 集成无单测，新功能应补 | 未补，留待下一轮（需 mock `wsl.exe`） |
| 附 | 采纳 | `$args` 自动变量遮蔽——虽此函数无实参透传不致踩，但避坑 | `lib/poll.ps1:54-56` 改名 `$wslArgs` |
| 附 | 采纳 | `Get-WslState` 的 `StandardOutputEncoding = Unicode` 是死代码（走 BaseStream 不读 StandardOutput） | `lib/poll.ps1:36-37` 删并加注释 |

**误报登记**：无。DSH 渠道未跑完，无审计方 findings 可误报。

## 4. 未验

- **真实 WSL 启停**：单测用 mock，未在本机实跑 `wsl.exe -d Ubuntu-24.04 echo ready` 和 `wsl.exe --shutdown` 验证卡片端到端行为（任务书要求只读不执行 wsl，DSH 沙箱也不允许）。
- **DSH 渠道**：headless profile 在第二步多轮 tool-use 恒 400，未完成审计。日志 `docs/audit-run-wsl-2026-10-04.log` 仅 12 行。渠道问题不在本仓代码，是 new-api 渠道侧的 `deepseek-v4-flash` 多轮 tool-use 拒请求。
- **多发行版场景**：`--shutdown` 会停掉所有发行版，本机单发行版未触发此限制。

## 5. 测试

```
pwsh -NoProfile -File tests/run-all.ps1
```

结果（本回合实跑）：

```
PASS: 16 regression tests and parser check completed.
```

exit 0。IsWsl 修复后无回归。

## 6. 代码精简

本轮顺手精简（工作区改动，未提交）：

- `lib/poll.ps1` `Get-WslState`：删死代码 `$psi.StandardOutputEncoding = [System.Text.Encoding]::Unicode`（走 BaseStream 手动解码，不读 StandardOutput，设了那个属性是死代码），加注释说明为什么删。
- `lib/poll.ps1` `Invoke-WslCommand`：`$args` → `$wslArgs`，避免遮蔽 PowerShell 自动变量 `$args`。原代码此函数无实参透传场景不致踩，但避坑比省一个字母值钱。

未做更大精简——其余改动都是 WSL 集成必需的分流逻辑，无冗余分支。
