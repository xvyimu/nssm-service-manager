---
name: Bug 报告
about: 行为不符合预期，或界面/脚本报错
title: "[bug] "
labels: bug
assignees: ''
---

**描述问题**
一句话说明发生了什么。

**复现步骤**
1.
2.
3.

**期望 vs 实际**
- 期望：
- 实际：

**环境**
- Windows 版本：Win+R 输 `winver` 查看
- PowerShell 版本：`pwsh --version`
- NSSM 版本：`nssm --version`，或 `$env:NSSM_PATH` 指向的版本
- 本工具 commit：`git log --oneline -1`

**涉及的服务**
`services.json` 里的条目（服务名/端口/URL，可脱敏）：

**日志**
- GUI 崩溃：`logs/gui-crash.log` 尾部 50 行
- 某服务异常：该服务的 `.out.log` / `.err.log` 尾部

**回归测试**
`pwsh -NoProfile -File tests/run-all.ps1` 通过/未跑/失败（失败贴输出）。
