# service-manager

本地 NSSM Windows 服务的统一管理 GUI。

## 文件

| 文件 | 作用 |
|------|------|
| `service-manager-gui.ps1` | 卡片式 WinForms GUI（唯一入口） |
| `services.json` | 服务清单（名称 → 端口/面板 URL） |
| `logs/` | NSSM 服务运行日志（`.out.log` / `.err.log`，git 忽略） |

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

| 服务 | 端口 | 面板 |
|------|------|------|
| NewAPI | 3000 | http://127.0.0.1:3000 |
| Router9 | 20128 | http://127.0.0.1:20128/dashboard |
| OmniRoute | 20129 | http://127.0.0.1:20129/dashboard |
| CPA | 8317 | http://127.0.0.1:8317/management.html |
| WorkBuddy2API | 7863 | http://127.0.0.1:7863/panel/ |
| TTSShim | 8001 | http://127.0.0.1:8001/health |

## 依赖

- PowerShell 7（`pwsh`）
- NSSM 2.24（scoop 安装，路径 `~/scoop/apps/nssm/current/nssm.exe`）

## 添加新服务

工具栏「➕ 添加」→ 填服务名/端口/可执行文件/工作目录/启动参数/环境变量。
环境变量格式 `KEY=VAL,KEY2=VAL2`（一次传入，NSSM `AppEnvironmentExtra` 是整列表替换）。
