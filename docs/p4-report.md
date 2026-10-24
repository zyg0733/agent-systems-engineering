# P4 阶段验收：隔离、MCP、DAG 与人工审批

验收日期：2026-10-22，Asia/Shanghai。本阶段覆盖 W15—W18 的教学实现；结论基于本机 macOS arm64、单 PostgreSQL 与固定 Scripted/原生实验探针。不是生产安全认证或任意远端 exactly-once 承诺。

## 交付链路与证据

| 周次 | 当前能力 | 正式证据及本轮复核范围 |
| --- | --- | --- |
| W15 | 宿主固定文件/网络策略、单目标隔离执行、资源限制和进程清理 | [W15 验收](validation-week15.md)与原正式探针证据保留；W18 全量测试实际重跑现有隔离、越界、取消与清理测试 |
| W16 | MCP 固定协议 stdio、发现/调用、生命周期、错误与未知结果核对 | [W16 验收](validation-week16.md)与原正式 20 项保留；W18 全量测试实际重跑现有传输、权限、持久回执和 MCPDemo |
| W17 | 事务 DAG、独立子 Run、并行汇合、失败与崩溃恢复 | [W17 验收](validation-week17.md)与原正式 9 项保留；W18 全量测试重跑现有 DAG 演练、并发、取消和 fencing |
| W18 | 人工审批、产物/基线哈希、持久暂停、预声明有限返工 | [W18 验收](validation-week18.md)：新正式 11 项、新 BEAM、原始持久事实与源码冻结审计 |

冻结 W18 代码的 `./scripts/mix check` 为 **806 passed（804 tests、2 doctests），0 失败**，原 **10/10 fixtures** 和四个 COMMIT 前后真实进程 kill 检查通过。包括 W18 新增的 58 项测试，原有 748 项保持。不能把 W15—W17 原正式输出说成同一轮新正式演练；本次复核范围按上表区分，原源码与结果继续保留。

## 阶段门槛

| 门槛 | 已验证机制 |
| --- | --- |
| 越界与未授权操作被阻断 | 文件工具和隔离/MCP 继续使用宿主策略；Artifact 只能选择该轮已授权的私人工作区，相对路径、链接、别名和大小限制 fail closed |
| 模型不能授予权限或批准自己 | 模型没有审批/控制工具；Reviewer 输出只是数据；操作者由可信宿主认证并检查 Plan allowlist，请求不能携带配置或预算 |
| 产物改变不能复用批准 | subject 绑定完整字节、基线、Plan、轮次、generation 与 Workflow 证据；fresh 验证后放行不可变字节，改回旧内容也需新批准 |
| 暂停不是一次进程停止 | 持久 Control 撤销 claim，快速恢复后旧凭证仍失效；暂停期间人工核对不恢复执行；应用重启按原 Case/Workflow ID 继续 |
| 返工有界且不重置责任 | 全部一至三轮提前固定并静态预留总预算，独立工作区；原 deadline、旧轮账单和回执保持，新轮与人工决定一次原子登记 |
| 歧义不会变成自动重投 | prepared/unknown 保留原操作与可见 manual 队列；暂停/取消不回滚外部效果，旧 receipt 不能覆盖新状态 |
| 恢复与重建分开 | 真正新 BEAM 分别验证持久批准的放行和变化失效；空闲新 BEAM 只读重建时模型、工具、控制变更和产物捕获入口均为零 |

当前正式审批实验使用合成操作者，包含真实工具效果门闩、产物/基线变化、暂停恢复、批准与返工 COMMIT 前后 kill。Case 的 approved、awaiting_review、paused/manual、cancelled 和 failed 按实际保留，不以全 succeeded 代替判据通过。原始数据和数量见 W18 记录。

## 运行边界与后续

本期形成从受限工具、独立子任务、完整回执到哈希绑定人工放行的教学闭环。审批服务返回不可变字节及基线版本，不应用补丁、不部署或发布；真正消费者仍需以原基线做 compare-and-swap，并负责外部系统的幂等与核对。已经释放的字节不能被撤回，读取也不是跨文件系统事务。

身份是可信宿主 API 边界，没有新增登录、签名或多租户 RBAC。返工只选预声明轮次，没有动态 Planner、任意图扩展或自动权限升级。静态预算不代表动态 credit 池、真实 token 计费或资金预算；审批等待仍计入原绝对期限。

隔离后端仍为 macOS 单目标、禁止 fork/spawn 的教学实现。Linux、任意后代、硬内存/总磁盘、网络 allowlist、HTTP/OAuth、完整 MCP 与任意第三方服务器兼容均未因此获得支持。故障注入没有停止共享 PostgreSQL，也没有批量清理其他任务或人工核对记录。

复现与事故操作见 [L14](../labs/L14-isolated-execution.md)、[L15](../labs/L15-mcp-stdio.md)、[L16](../labs/L16-dag-workflows.md)、[L17](../labs/L17-human-approvals.md)及[运行手册第 13—16 节](recovery-runbook.md#13-隔离执行与清理)。
