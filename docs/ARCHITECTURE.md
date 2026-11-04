# ARCHITECTURE.md — 模块边界与数据流

> **产品：** service-manager（本地 Windows 服务管理 GUI）
> **本地：** `D:\projects\nssm-service-manager`（开发副本）；运行时副本在管理员独占目录
> **本文件 = 模块边界与线程模型的权威。** 技术栈表在 `docs/PROJECT.md`，此处不复述；实现细节在 `docs/IMPLEMENTATION-NOTES.md`。

## 1. 分层

```
入口层      service-manager-gui.ps1     CLI 分支 · 提权 · 依赖预检 · 模块加载 · 窗口启动
            launch.vbs                  wscript → runas pwsh（无控制台）
UI 层       lib/xaml.ps1                窗口外壳 · 分页 · 状态栏
            lib/card.ps1                卡片：状态呈现、按钮、右键菜单、过渡态
            lib/dialogs.ps1             添加/删除对话框（提交体可单测）
            lib/logview.ps1             日志窗口 · 健康历史窗口
            lib/tray.ps1                可选托盘（WinForms 按需加载）
            lib/theme.ps1               字体 · 语义色 · 按钮模板 · Mica P/Invoke
领域层      lib/util.ps1                清单读写 · 命令入队 · 状态 tick · 收尾
            lib/add-svc.ps1             CLI 添加服务
            lib/nssm.ps1                NSSM 命令包装（install / set / remove）
            lib/svc-input.ps1           纯函数：输入校验 · env 解析 · NSSM set 规格
            lib/svc-common.ps1          UI 与后台共用原语：sc 解析 · 外部命令 · 状态映射 · 删除流程
            lib/health.ps1              健康历史纯函数（NDJSON）
            lib/webview*.ps1            可选只读 Web（回环 + token）
数据层      services.json               服务清单（本机实配，git 忽略）
            config.json                 可调常量覆盖（本机实配，git 忽略）
            logs/                       NSSM stdout/stderr · health/ · gui-crash.log
```

依赖方向单向：入口 → UI → 领域 → 数据。领域层不认识 UI；`svc-input.ps1` 与 `health.ps1` 是纯函数族，可单独点源测试。

## 2. 三种事实，分开存放

| 事实 | 存在哪 | 谁是权威 |
|---|---|---|
| SCM 里的服务状态 | Windows 服务数据库 | `sc.exe query` / `Get-Service` |
| 清单里的期望服务 | `services.json` | 文件本身（`.bak` 是上一版） |
| 界面显示的状态 | `$script:svcState` + 卡片 | 由前两者派生的**带时间戳快照** |

界面只显示两者都支持的状态；分歧必须显式可见（「未安装」「待保存」「状态未知」），不能靠猜。

## 3. 线程模型

```
UI 线程 (STA)                          后台 runspace (STA)
  DispatcherTimer 400ms                 探测循环 + 命令执行
    ├ 排空 $queue（结果/回执）           ├ Get-Service 批量查询
    ├ 排空 $msgQueue（失败文案）          ├ ForEach-Object -Parallel 探测 TCP/HTTP
    ├ 排空 $healthQueue → 落盘            └ 执行 $cmdQueue 里的启停/删除
    └ 刷新卡片/时钟/新鲜度
       ↑                    ↓
       └──── ConcurrentQueue ×3（结果 / 命令 / 消息）────┘
```

硬规则：UI 线程只做格式化与入队。`Get-Service`、`Install-NssmService`、`Save-Svc`、`Invoke-ExternalQuiet`、`Read-LogTail` 不得出现在事件处理体里（唯一有意例外：关闭时的日志清理与健康队列收尾，量级可控）。

## 4. 状态机

```
查询中 → 运行中 ⇄ 已停止
  ↓        ↓
未知   等待中 → 无响应
```

- **过渡态**（启动中/停止中/删除中）：命令驱动，绑 epoch，有硬上限逃生（`ToggleTimeoutMs × TransitionHardCapFactor`）。
- **陈旧态**：`svcState.at` 超过 `2 × ProbeIntervalMs` 未更新 → 显示「状态未知」，禁用动作。
- **离线态**：后台 runspace 结束 → 所有卡片转未知（`Set-CardOffline`）。
- **待保存**：服务已从 SCM 删除但清单写盘失败 → 卡片保留，右键「重试保存清单」。

## 5. 失败语义

- 回执失败：回滚过渡态 + 卡片上留 `LastError` + 状态栏一句（30 秒）。
- 部分成功：不回滚已完成的系统操作，把分歧显示出来，给可重试入口。
- 外部进程：`sc.exe` / `nssm.exe` 退出码不可信，最终以 SCM 实证为准（`sc query` 1060 = 已删）。
