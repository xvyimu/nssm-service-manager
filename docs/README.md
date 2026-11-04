# docs 导航

> 本文件只做导航，不写正文。任何结论都落在它指向的文件里。

| 文件 | 回答什么 | 何时读 |
|---|---|---|
| `PROJECT.md` | 这是什么、为什么用这个栈、已知限制、范围外 | 动架构或判断「该不该做」之前 |
| `ARCHITECTURE.md` | 模块边界、数据流、线程模型 | 改跨模块行为之前 |
| `IMPLEMENTATION-NOTES.md` | 踩过的坑与实现细节（代码里 `§小节名` 指向这里） | 改具体函数之前 |
| `ITERATION-PLAN.md` | 本轮封板范围、批次、验收与停止标准 | 判断「还要不要继续改」时 |
| `HANDOFF.md` | 当前状态、下一步、交接信息 | 接手或发版前 |
| `adr/` | 一次性决策的记录 | 想推翻某个设计之前 |
| `lessons/` | 事后复盘：哪里判断错了 | 犯同类错之前 |
| `../CHANGELOG.md` | 每个版本改了什么、为什么 | 发版与追溯 |

## 维护约定

- 同一事实只有一个来源：栈在 `PROJECT.md`，坑在 `IMPLEMENTATION-NOTES.md`，计划在 `ITERATION-PLAN.md`。
- 行为改了不同步文档 = 漂移；文档改了没动代码，也应在 `CHANGELOG.md` 记一行。
- `docs/session/` 不进 git；`HANDOFF.md` 进 git。
