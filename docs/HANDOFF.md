<!-- doc-template: project/HANDOFF v1 -->
# HANDOFF

> **更新日：** 2026-10-30　**版本：** `VERSION` = 0.9.0
> **本文件只写接手指南**：当前状态 / 已知限制 / 下一步。改了什么看 `docs/CHANGELOG.md`，
> 为什么这么设计看 `docs/PROJECT.md`（技术栈与取舍的 SSOT），实现细节看
> `docs/IMPLEMENTATION-NOTES.md`（代码里的 `§小节名` 指向那里）。

## 1. 当前状态

- **运行形态**：`service-manager-gui.ps1`（PowerShell 7 + WPF，管理员身份）+ `lib/` 模块；
  双击入口 `launch.vbs`；CLI 分支 `-Add Name,Port,Exe[,Url|tcp,Dir,Args,Env]` 不弹 GUI。
- **数据文件**：`services.json`（服务清单，SSOT）与 `config.json`（可调常量覆盖）都是**本机实配**，
  已 git 忽略；仓里只有 `services.example.json` / `config.example.json`。日志在 `logs/`，
  健康历史在 `logs/health/health-YYYYMMDD.ndjson`（留 30 天，只记变化）。
- **质量门**（两条都要绿，改动后各跑一次）：
  ```powershell
  pwsh -NoProfile -File tests/run-all.ps1     # parser + 20 项回归（自动收集 tests/test-*.ps1）
  pwsh -NoProfile -File tests/analyze.ps1     # PSScriptAnalyzer，Error/Warning 必须为 0
  ```
  `analyze.ps1` 需要一次性 `Install-Module PSScriptAnalyzer -Scope CurrentUser`；规则集与每条
  豁免的理由在 `PSScriptAnalyzerSettings.psd1`（CI 的 `static-analysis` 任务跑同一条命令）。
- **CI**（`.github/workflows/`）：`test.yml` = `regression` + `static-analysis` + `secrets`(gitleaks)；
  `release.yml` = 打 tag `v*` → 跑回归 → `scripts/package-release.ps1` 出 zip → `gh release create`。
- **发布状态**：`VERSION`、打包脚本、release workflow 都已就位，本地已打 tag `v0.9.0`
  （`git describe --tags` 可查），**还没 push**。推送需要写权限，属于人来做的一步：
  ```powershell
  git push origin main; git push origin v0.9.0
  ```
  `release.yml` 会校验 `VERSION` 与 tag 一致，不一致直接红。改版本时 `git tag -d v0.9.0` 重打即可。
- **本轮（2026-10-30 优化方案 A/B/C 批）落地**：
  - A1 `Add-SvcEntry` 改 copy-on-write：保存失败不再让内存与磁盘分叉（`lib/util.ps1`）。
  - A2 `Save-Svc` 写前清目标只读属性，清不掉翻译成「services.json 是只读的」。
  - A3 添加对话框保存失败保持窗口，正文写清「已在 NSSM 注册但没写入清单」+ 两句处置。
  - A4 批量启停跳过超过 `2 × ProbeIntervalMs` 的过期状态，并在文案里说明跳过数。
  - B1 添加服务支持「探测方式」（GUI 下拉 + CLI 第 4 段写 `tcp` 的简写）。
  - B2 右键重启改为两段式过渡态（`停止中` → 中间回执 → `启动中`），重启期间双击被拒。
  - B3 健康历史改按文件尾部反向扫描（大文件不再整份读 + 逐行解析）。
  - C1 静态分析进 CI；C2 `VERSION` + 打包脚本 + release workflow；C3 本文件重写。

## 2. 已知限制

完整清单与「为什么这样取舍」在 `docs/PROJECT.md` §已知限制（含实测数据）。接手时必须知道的几条：

1. **UAC 链路与重启两段态已实测，其余服务动作仍靠单测**：2026-10-30 从沙箱副本走非管理员入口 →
   `launch.vbs` → UAC → 提权实例（日志 `Startup: admin=True` / `Window constructed: cards=4` /
   `ShowDialog returned (normal exit path)`，父进程 `Elevation launcher exited: code=0`）。
   同一轮用真实 NSSM 临时服务（`pwsh` 监听 59997，`probe=tcp`）验了右键重启：卡片
   `运行中(绿) → 停止中(橙,双按钮禁用) → 启动中 → 运行中(绿)`，状态条「重启中…」，验完已
   `nssm remove`（`sc query` 返回 1060）。**仍未被真机覆盖**：批量启停的真实下发、
   暂停/继续（本机没有可暂停的服务）、删除全链路（单测用替身）。
2. **全量写回，CLI 与 GUI 不能并行**：`Save-Svc` 无合并语义，GUI 常驻时 CLI 新增会被下一次 GUI
   保存覆盖。故 `-Add` 前用 `Global\` mutex 探测 GUI，在跑就拒绝。
3. **探测驱动的中间态没有按钮出口**：服务真卡在 `StartPending` / `StopPending` 时卡片按钮禁用，
   右键菜单是唯一逃生口（有意取舍，详见 PROJECT.md）。
4. **`launch.vbs` 必须保持纯 ASCII**：Windows Script Host 按系统 ANSI 代码页读，中文注释在部分
   系统上触发 `800A0400`。
5. **ACL 判定是启发式**：安全检查只看 ACE 里是否出现宽面 SID（含 `S-1-15-3-*` / AppContainer），
   不解析完整 ACL 继承链；`NSSM_PATH` 只校验文件名与目录可写，不验签。
6. **健康历史只记变化**：平稳期没有记录是设计（否则一天几万行噪声），别当成"漏记"来查。
7. **批量启停只碰终态**（已停止 / 运行中），并跳过过期探测值；`启动中/停止中/暂停` 一律不碰，
   免得和手动命令打架。
8. **Web 只读视图默认关闭**（`WebViewEnabled`），开启后只绑 `127.0.0.1` + token 门禁，GET only。

## 3. 下一步

按「事故概率 × 修复成本」排，都是**建议**，动之前先确认需求真实性：

1. **可选优化（批次 D，等真实痛点再做）**：跨页过滤/排序（服务数 > 12 才值得）、
   两份 `services.json` 的差异对比（换机迁移用）、健康历史可视化、Web 只读拓扑图。
   这四项都是新需求而非修复，没有实际使用反馈前不要开工。
2. **首次发布**：打 `v0.9.0` tag → 确认 Release 附件能解压即跑（zip 里 `launch.vbs` + `lib/` +
   example 配置齐）。之后每次发版只改 `VERSION` + CHANGELOG 再打 tag。
3. **文档漂移巡检**：改了行为就同步 `README.md`（功能/文件表/CLI 用法）与
   `docs/PROJECT.md`（取舍、已知限制）；`docs/CHANGELOG.md` 的 `[未发布]` 段在发版时改成版本号。
4. **测试数量**：`tests/run-all.ps1` 自动收集，新增用例不必登记；README 与 PROJECT.md 里
   写死的「20 项」在新增 `test-*.ps1` 时要一起改（本轮只加了用例内断言，数量未变）。
