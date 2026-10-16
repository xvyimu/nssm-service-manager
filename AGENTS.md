# AGENTS.md

> 给 AI coding agent 的项目约定。命令与边界优先；细节见 `README.md` / `docs/PROJECT.md`。

## 命令速查（先看这里）

```powershell
# 回归测试（不需要管理员；CI 就跑这个）
pwsh -NoProfile -File tests/run-all.ps1

# 启动 GUI（会弹 UAC；NSSM/sc.exe 需要管理员）
pwsh -NoProfile -File service-manager-gui.ps1

# 装依赖（NSSM 走 scoop，或自行放置后设 NSSM_PATH）
scoop install nssm
```

改动后：**跑 `pwsh -NoProfile -File tests/run-all.ps1`**，全绿才算完。测试是 WPF/STA，需 Windows。

## 项目结构

```
service-manager-gui.ps1   # 主入口：CLI 分支 + 提权 + 模块加载 + 窗口启动
launch.vbs                # 双击入口（wscript 无控制台 → runas pwsh → 管理员 GUI）
lib/                      # 模块（config/theme/util/poll/svc-common/svc-input/nssm/add-svc/dialogs/logview/tray/card）
scripts/                  # 独立脚本（set-service-params-acl.ps1）
tests/                    # 回归测试（run-all.ps1 汇总；test-*.ps1 单项）
docs/                     # PROJECT.md（架构与决策）/ CHANGELOG.md / HANDOFF.md
config.example.json       # 配置示例（实配 config.json 已 gitignore）
services.example.json     # 服务清单示例（实配 services.json 已 gitignore）
```

## 技术栈与约定

- **栈**：PowerShell 7 + WPF（Windows 原生，绑 `sc.exe`/`nssm.exe`，**不进 WSL**）。零外部 npm 依赖。
- **SSOT**：`docs/PROJECT.md` 是「为什么这么做」的真相；代码是行为真相。改行为不改文档 = 漂移。
- **UI 线程绝不碰 I/O**：`Get-Service`/`TcpClient`/`HttpClient` 都可能阻塞 → 后台 runspace + ConcurrentQueue，DispatcherTimer 400ms 轮询取结果。
- **模块分层**：常量收口在 `lib/config.ps1`（不在别处硬编）；纯函数族（如 `lib/svc-input.ps1`）可单独点源测试，不加载 WPF。
- **提交信息**：conventional commits（`feat:` / `fix:` / `docs:` / `refactor:`）。

## 边界（三级）

- ✅ **Always**：改完跑 `pwsh -NoProfile -File tests/run-all.ps1`；新逻辑补对应 `tests/test-*.ps1`；常量加进 `lib/config.ps1` 而非散落硬编。
- ⚠️ **Ask first**：改 `scripts/set-service-params-acl.ps1`（动 ACL）；改提权逻辑 / `launch.vbs`；增删 `lib/` 模块；改 `docs/PROJECT.md` 的技术栈。
- 🚫 **Never**：提交 `config.json` / `services.json`（机器专属，已 gitignore）；提交密钥；改 `nssm.exe`/`sc.exe` 行为的字段却没测；直接删失败的测试。

## 环境注意

- 测试需 **Windows**（WPF/STA + Windows runner）；CI 在 Windows runner 上跑 `pwsh 7`。
- `config.json` 可缺省（不复制就用内嵌默认值）；`services.json` 决定管哪些服务。
- 实配 `config.json` / `services.json` **每台机器自定、已 gitignore**；示例进仓保证克隆即跑。
