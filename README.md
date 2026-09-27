# service-manager

本地 NSSM Windows 服务的统一管理 GUI。

## 文件

| 文件 | 作用 |
|------|------|
| `service-manager-gui.ps1` | 卡片式 WinForms GUI（唯一入口） |
| `services.json` | 服务清单（名称 → 端口/面板 URL） |
| `st-tts-shim/server.mjs` | TTSShim 服务本体：StepFun TTS → OpenAI 兼容 `/v1/audio/speech` 薄适配层（零依赖） |
| `st-tts-shim/test-speech.ps1` | TTSShim 打穿测试脚本 |
| `logs/` | NSSM 服务运行日志（`.out.log` / `.err.log`，git 忽略） |
| `logs/gui-crash.log` | GUI 崩溃留痕（UI 线程异常 / 进程级异常 / 关闭原因，git 忽略） |

## 启动

桌面快捷方式 `服务管理.lnk` → `pwsh -NoProfile -ExecutionPolicy Bypass -File service-manager-gui.ps1`

脚本会自动请求 UAC 提权（NSSM/sc.exe 需要管理员权限）。

## 功能

- 每个服务一张圆角卡片：服务名、端口、状态（带圆点）、健康
- 双击卡片 = 启停切换
- 右键卡片 = 启动/停止/重启/面板/日志
- 工具栏：添加服务（NSSM install + env 一次注入）/ 删除服务 / 刷新 / services.msc
- 后台 runspace 探测（`sc.exe query` + HTTP），UI 线程不碰 I/O，不卡顿
- 托盘最小化，关窗缩到托盘，右键托盘退出

## 托管的 6 个服务

| 服务 | 端口 | 面板 | 本体 |
|------|------|------|------|
| NewAPI | 3000 | http://127.0.0.1:3000 | 独立部署 |
| Router9 | 20128 | http://127.0.0.1:20128/dashboard | 独立部署 |
| OmniRoute | 20129 | http://127.0.0.1:20129/dashboard | 独立部署 |
| CPA | 8317 | http://127.0.0.1:8317/management.html | 独立部署 |
| WorkBuddy2API | 7863 | http://127.0.0.1:7863/panel/ | 独立部署 |
| TTSShim | 8001 | http://127.0.0.1:8001/health | 本仓 `st-tts-shim/server.mjs`（NSSM `AppDirectory` 指向本目录，`AppEnvironmentExtra` 注入 `TTS_API_KEY`） |

## 依赖

- PowerShell 7（`pwsh`）
- NSSM 2.24（scoop 安装，路径 `~/scoop/apps/nssm/current/nssm.exe`）
- Node.js 18+（仅 TTSShim 需要，内置 `http` + 全局 `fetch`，无 npm 依赖）

## 添加新服务

工具栏「➕ 添加」→ 填服务名/端口/可执行文件/工作目录/启动参数/环境变量。
环境变量格式 `KEY=VAL,KEY2=VAL2`（一次传入，NSSM `AppEnvironmentExtra` 是整列表替换）。

## TTSShim 重建

`st-tts-shim/server.mjs` 是 2026-09-27 按 `logs/TTSShim.out.log` 启动横幅与记忆里的行为契约重建的（原版随 `D:\orca\.scratch` 被磁盘清理误删）。零依赖，只靠 Node.js 内置 `http` + 全局 `fetch`。

环境变量（NSSM `AppEnvironmentExtra` 注入 `TTS_API_KEY`，其余可按需加）：

| 变量 | 默认 | 说明 |
|------|------|------|
| `PORT` | 8001 | 监听端口 |
| `HOST` | 127.0.0.1 | 绑定地址 |
| `TTS_BASE` | `https://api.stepfun.com/step_plan/v1` | 上游 base |
| `TTS_MODEL` | `stepaudio-2.5-tts` | 缺省 model |
| `TTS_DEFAULT_VOICE` | `lengyanyujie` | 请求未带 voice 时的缺省音色 |
| `TTS_AUTH_STYLE` | `bearer` | 上游鉴权风格（`bearer` 或原样放 key） |
| `TTS_API_KEY` / `STEPFUN_API_KEY` | — | 上游密钥，缺失拒绝启动 |
| `TTS_TIMEOUT_MS` | 120000 | 上游请求超时 |

打穿测试：`pwsh -NoProfile -File st-tts-shim/test-speech.ps1`
