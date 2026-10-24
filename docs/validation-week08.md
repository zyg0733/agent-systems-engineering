# 第 8 周验收记录

验证日期：2026-10-20，Asia/Shanghai。环境沿用 macOS arm64、Elixir 1.20.4、Erlang/OTP 28.4、PostgreSQL 18.6，没有新增 Hex 依赖。

## 已实现的恢复契约

新增显式 `Recovery` 驱动，与原有进程实验共存。`create_run` 在同一事务提交 Run/Event/调度意图与固定恢复配置；`load` 只读；`step` 领取并执行一步；`resume` 推进到终态、未知结果暂停或步骤上限。未预先保存配置的旧 Run 返回 `run_not_resumable`，不会猜脚本游标、工作区、Session 或预算。

`RecoveryStore` 固定脚本、Session 快照、工作区、Context 策略、预算、Mock 能力与故障策略。模型游标与接受的 Event、录制及下一意图一起提交。模型尝试在启动 Provider 前预留，默认上限 8 次；每个 frame 在 ACK 前持久扣账。未完成尝试的输出字节跨崩溃保留，帧数按请求计量；绝对 Run deadline 不因 worker 重启而延长。

`IntentStore` 在 Run 锁下领取当前 pending 意图，绑定 owner、UUID token、递增 generation 与 PostgreSQL 时钟期限。领取、续租、释放和提交均检查资格，过期或被接管的凭证不能覆盖新事实。取消/失败撤销当前领取；普通未携带凭证的提交不能越过活动 lease。领取前后 COMMIT 的真实进程 kill 均已验证。

`DurableTools` 把逻辑 operation、delivery/lookup/manual attempt 与配对回执分开保存。一个 operation 的工具和完整参数不可变；每次投递保留独立 attempt、领取代次和结果。持久 Mock 的目标账本在 Runtime 结果事务之前独立提交，按 `(run_id, operation_id)` 和精确输入返回原回执，效果数不增长。

准备标记已提交、确认回执缺失的文件或 unqueryable 操作保守进入 unknown，不自动执行第二次。`reconcile` 对幂等 Mock 查询目标回执；无法证明时返回 `reconciliation_required`。明确人工结果需附非空 evidence，保存 manual attempt 与配对结果，不能删除旧尝试或自动撤销外部效果。

Provider 在长期数据库事务之外运行。有界本地 Mock/Files 在 Run 锁内复验 claim 和持久期限后执行；目标效果、工具回执与 Runtime 接受结果是不同提交。文件系统不能随数据库事务回滚。持有数据库锁仅适用于本实验有界本地工具，不是任意远程调用的执行方案。

## 完整自动化验收

```sh
./scripts/mix check
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

完整结果：**391 passed，含 389 个测试与 2 个 doctest，0 失败**。第 7 周原有 322 项保留通过，新增 69 项。格式、无警告编译、测试库迁移、10/10 原有场景，以及原创建/转换四个 COMMIT 边界真实 kill 探针全部通过。

| 新增测试 | 数量 | 主要证据 |
| --- | ---: | --- |
| IntentStore | 13 | 并发领取唯一性、期限/代次、伪造凭证、续租/释放、取消、真实领取 COMMIT 前后 kill |
| DurableTools | 16 | operation/attempt 分层、参数冲突、真实 prepare/effect/receipt 后 kill、丢回执查询、未知文件、人工证据、旧 claim、执行前期限与已有效果归档 |
| RecoveryStore | 18 | 原子登记、配置/版本/进度损坏、旧 Run 拒绝、事务边界、活动请求身份、持久扣账、cursor 与模型录制绑定 |
| Recovery 驱动 | 21 | 新 worker 接续、真实登记/模型 COMMIT kill、恢复中再次崩溃、已确认回执复用、未知核对、预算不归零、取消及超时竞争、非法人工输入/持久 ID |
| RecoveryDemo / 新 BEAM | 1 | 5 类真实崩溃、恢复中再次崩溃、独立 VM 从原配置续跑、丢回执查询与文件人工核对、拒绝覆盖证据 |

关闭数据库时：**232 passed，159 个数据库测试按标签排除**。原内存状态机、Streaming、文件修复、Session/Context 和 P1 实验均保留通过。

日志：[完整 check](../artifacts/week08-recovery/check.log)、[内存测试](../artifacts/week08-recovery/memory-tests.log)。故障注入引起的 Postgrex caller 退出日志符合预期，所有恢复断言及独立连接读取均通过。

## 正式故障演示

开发库和测试库均已执行新迁移，实际运行：

```sh
./scripts/mix lab.recover
```

正式产物位于 [artifacts/week08-recovery](../artifacts/week08-recovery/)。默认 5 类故障各重复 4 次，共 **20 个 Mock 恢复探针**；另包含一次恢复中再次崩溃和一次文件效果后崩溃，合计 **22 次真实 caller kill**。演示在观察到 hook 边界后 kill，等待真实 lease 到期，不通过修改数据库期限制造接管。

| 故障点 | 次数 | 核对结果 |
| --- | ---: | --- |
| 模型结果 COMMIT 前 | 4 | cursor/录制/Event 未接受；保留尝试与字节消耗，重试后完成 |
| 模型结果 COMMIT 后、ACK 前 | 4 | 已接受的 cursor/录制/Event 保留，不再消费同一脚本位置 |
| 工具 prepare 后 | 4 | operation/attempt 保留，幂等目标安全恢复，最终效果数各 1 |
| 工具效果后、回执前 | 4 | 目标效果已存在，重复投递复用原回执，最终效果数各 1 |
| 工具回执后、Kernel 接受前 | 4 | 直接复用已确认配对回执，最终效果数各 1 |

20 个探针全部到达 succeeded，全部与原历史重建结果相等，每个 Run 的持久 Mock 效果数均为 **1**，重复业务效果合计 **0**。每个完成 Run 有两条模型结果录制；模型 COMMIT 前的未确认尝试允许重试并保留资源消耗。

报告保留每个 Run ID、故障点、崩溃前 seq/cursor、工具尝试数、模型尝试数、效果数、录制数与状态验证结果，见 [report.json](../artifacts/week08-recovery/report.json)。

## 新 BEAM 实际续跑

新 VM 的正式 Run 为：

```text
recovery-demo-1792511138122051-5187-tool_after_effect-1
```

原 worker 在工具效果后退出；恢复 worker 再次在同一个逻辑工具的效果边界退出。两次退出后都没有确认 Runtime 工具结果。随后启动独立 BEAM，从 PostgreSQL 加载原始配置、cursor、预算、operation/attempt 和目标回执，不传入新脚本或临时 Mock。

| 观察项 | 结果 |
| --- | --- |
| 崩溃前 Kernel seq / cursor | 2 / 1 |
| 完成 seq / cursor | 4 / 2 |
| 原逻辑工具操作 | 1 个 |
| 工具 delivery attempt | 3 次，两次 prepared、一次 completed |
| 持久 Mock 业务效果 | 始终 1 次 |
| 模型尝试 / 完整录制 | 2 / 2，未重新消费已接受工具提议 |
| 最终状态 | succeeded |
| State SHA256 | `075d665ae266fdd9960d4f42f5b9984041fa03a57fe733fd4cf85e52468896d4` |

实际新 VM 日志见 [fresh-vm.log](../artifacts/week08-recovery/fresh-vm.log)。其最终 State hash 与父进程随后只读加载一致；父进程另以严格 History 重建比较完整 State。子进程执行的是 resume，可能消费未完成模型步骤，与第 7 周只读重建的零调用验收明确分开。

## 未知结果与回执审计

可查询的丢回执 Run：`recovery-demo-1792511138122051-5187-query`。执行先到 blocked，显式 reconcile 查询原目标回执，再续跑到 succeeded，效果数仍为 1。

模糊文件 Run：`recovery-demo-1792511138122051-5187-file`。真实文件写入后、回执确认前 kill。恢复保存 unknown 并到 blocked；默认 reconcile 返回 `reconciliation_required`。可信操作者明确提交结果和 evidence 后才完成续跑，文件内容始终为 `one original write\n`，未再次执行写入。测试还把文件改成其他内容，验证恢复不会覆盖后续编辑或用内容相等猜执行成功。

正式 22 个 Run 的 operation/attempt 已通过 `DurableTools.list` 重新校验，导出 [operation-journals.log](../artifacts/week08-recovery/operation-journals.log) 和惰性编码的 `operation-journals.bin`。其中保留原始 prepared 尝试、不同领取代次、配对回执、lookup 与 manual attempt，以及人工核对证据。效果统计只读诊断不构成自动核对授权。

## 竞争与资源边界补强

验证中额外封住了以下窗口，并保留回归测试：

- 空请求 token 不能在尚未预留 attempt 时扣账；脱离事务的内部进度写入被拒绝。
- 已预留模型 attempt 不能跳过结果录制单独推进 cursor。
- Context/hook 跨过期限时，在启动模型前拒绝；完整候选在提交前再次检查持久期限。
- 取消会撤销 claim；模型即使停在无输出的 sleep 中，也会由有界检查停止，不能迟到提交。
- 工具在 pre-effect hook 期间跨过 Run deadline 后不能产生新效果；既有效果的回执仍可归档。
- malformed 人工结果返回结构化错误；当前持久调用 ID 须能作为合法数据库文本键，旧 Kernel/内存契约保留。

History/checkpoint 的零执行审计扩展到 Recovery、DurableTools 与 DurableMock，共 **15 个边界入口**。原有新 VM 重建测试仍通过，重建没有因加入恢复模块而执行调度意图。

## 全新数据库验证

额外创建本任务专用空库，从零执行 **8 个迁移**，实际运行 create → 丢回执 blocked → 查询核对 → resume succeeded，确认 cursor 2、两条模型结果、一个业务效果。验证后已删除这个专用临时库；原开发库、测试库和正式演示数据保留。

证据：[全新迁移日志](../artifacts/week08-recovery/clean-migrations.log)、[空库恢复验证](../artifacts/week08-recovery/clean-probe.log)。人工 evidence 采用独立正向迁移，已同时验证旧实验库升级与全新安装。

## 文档与范围

[L07 手册](../labs/L07-recovery.md)、[参考解答](../labs/solutions/L07.md)、[ADR 0007](adr/0007-recovery-and-operation-attempts.md) 和 README 已更新。手册中的 4 个 Elixir 代码块已从 Markdown 逐字提取，在独立 BEAM 与开发 PostgreSQL 实际运行通过，专用示例数据已清理；另验证了 unqueryable 人工核对与旧 Run 拒绝续跑。

本阶段是显式、受控的恢复驱动，没有后台 dispatcher、自动监督续跑、重试退避、公平调度或完整 Worker 池。仍使用离线 Scripted Provider；未完成请求可重试，不承诺模型费用只发生一次。数据库与远端服务不共享事务，持久 Mock 的效果唯一性不外推为任意外部 exactly-once。文件 unknown 保持人工核对边界，不能自动回滚、猜成功或盲目重发。hash 是完整性检查，不是数字签名；远程 CI 未执行。
