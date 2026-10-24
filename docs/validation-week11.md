# 第 11 周验收记录

验证日期：2026-10-21，Asia/Shanghai。环境沿用 macOS arm64、Elixir 1.20.4、Erlang/OTP 28.4、PostgreSQL 18.6；没有新增 Hex 依赖。新增第 12 个迁移 `20261021010000_add_intent_availability`。

## 实现结果

新增 `IntentStore.claim_next/2`、`Scheduler` 和临时 delivery `Scheduler.Worker`。调度器周期扫描 PostgreSQL 中已提交意图，在空闲容量内逐次领取，调用 `Recovery.execute_claim/2` 执行一个已领取步骤，完成后重新竞争下一意图。没有内存预领取队列，wake 提示丢失不影响最终发现。

领取按 Run 行锁在先、Intent 在后的顺序，使用 `FOR UPDATE OF run SKIP LOCKED`；在锁下校验完整历史、当前意图、Recovery 配置与真实 Retry journal，COMMIT 后才返回新 token/generation。仅处理登记过恢复配置的 running/model 或 waiting_tool/tool；legacy、终态、blocked/reconcile、有效 lease 和未到 due 的重试不会被自动执行。损坏候选有明确错误并可跳过，不会妨碍同批健康候选。

Run 创建时支持 `priority: 0..9`，默认 0，高优先级先考虑，同级按 intent ID 排序；不抢占已领取工作。新 `available_at` 与 retry 的预留、调度、abandonment 和关闭在同一事务维护。它是诊断投影，旧 NULL、提前或延后的 hint 都不能替代原 journal 的 due。当前 SQL 不以 hint 硬过滤，兼容原数据并避免错误提示隐藏已就绪工作。

Worker 的执行器与续期过程独立，模型等待不会阻塞续租。续期使用 PostgreSQL 时间、保持 token/generation。租约丢失和正常停止先停止并等待执行器，再尝试释放自身 live claim；异常 kill 通过链接终止执行器，原 lease 自然到期后可以接管。所有效果和结果接受继续验证当前凭证，复用原 operation/receipt 或保留 unknown，不把多次投递等同于多次业务效果。

Application 的后台调度默认关闭；`LAB_SCHEDULER_ENABLED=true` 显式启用受监督的命名调度器，要求 PostgreSQL。教学/测试可手工启动带 `run_ids` 范围的实例，不触及之前保留的故障 Run。配置、操作和暂停永久子进程的方法见[恢复运行手册](recovery-runbook.md)。

## 全量自动化验收

```sh
./scripts/mix check
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

最终结果：**512 passed，含 510 个测试与 2 个 doctest，0 失败**。第 10 周原有 473 项全部保留通过，新增 39 项。格式检查、无警告编译、测试库迁移、原 10/10 fixtures，以及 Run 创建和转换的 COMMIT 前后四个真实 kill 探针全部通过。

| 新增测试组 | 数量 | 主要验证 |
| --- | ---: | --- |
| IntentDispatch | 16 | 12 个消费者竞争 6 行、SKIP LOCKED、优先级/非抢占、真实 lease 到期、原 due、旧 NULL/错误 hint、坏候选隔离、COMMIT 可见性/回滚、投影原子性 |
| Scheduler | 11 | 两个独立池、容量和无预领取、重复 wake、长模型续期、取消/续租丢失、正常停止/重启、Worker/Scheduler 真 kill、自动到期、manual 排除、有限诊断 |
| RecoveryClaim | 6 | 预领取单步、旧资格/错误 operation、调用方保留 lease、不可变执行配置、外层事务拒绝、legacy 与优先级验证 |
| SchedulerDeadline | 3 | 效果后 kill 再到期保留 unknown、确认回执只补录事实、无准备记录的工具超时不产生效果 |
| SchedulingDemo | 3 | 演示参数边界、拒绝覆盖、完整多池/续期/重复投递/retry/新 BEAM 应用验证 |

无数据库模式：**245 passed，267 个数据库测试按标签排除**。新增两项参数与证据目录检查无需数据库；原内存实验全部通过。

日志：[完整 check](../artifacts/week11-scheduling/check.log)、[无数据库测试](../artifacts/week11-scheduling/memory-tests.log)。真实调用进程被 kill 导致的 Postgrex 断连信息符合故障注入预期；不是测试失败。

纯历史重建审计新增 `Recovery.execute_claim/2` 和 `Scheduler.start_link/1`，现为 **20 个效果入口**。原独立 BEAM 测试继续检查 full/checkpoint/原 State 严格相等，全部 20 个入口计数为 0，重建没有启动后台执行。

## 正式后台演示

实际命令：

```sh
./scripts/mix lab.schedule --output artifacts/week11-scheduling --runs 12
```

正式前缀：`schedule-1792516236700224-13`。演示共有 16 个独立 Run，12 个用于批量工作，其余分别验证续租、效果后 kill 重投、manual unknown 与新 BEAM 应用启动。

| 场景 | 实际结果 |
| --- | --- |
| 两个 Scheduler，各 2 个 Worker | 确定 gate 同时观察到 4 个在途步骤；4 个 intent 身份互异；12 个 Run 最终成功，每个工具效果为 1 |
| 模型暂时错误 | 后台按实际 due 执行 unavailable → rate_limited → 原工具提议；该阶段共 3 次尝试，已接受结果和 cursor 不重复 |
| 工具安全 no-effect 暂时错误 | 原 operation 共 3 次 delivery，直到最后一次成功；效果仍为 1 |
| 长模型输入 gate | 跨过初始 400 ms lease；观察到 6 次续租，同 token/generation，竞争 owner 被拒绝，原 Run deadline 保留 |
| 工具效果后真实 kill Worker | 关联执行器退出，原 lease 自然到期；新 generation 从 1 到 2，2 次 execution attempts，目标效果仍为 1 |
| 不可查询丢回执 | 自动执行到 blocked；再扫描至少 3 次仍不新增 claim/attempt/effect，manual unknown 可见 |
| 新 BEAM Application 启动 | 在进程启动配置中启用受监督 Scheduler，只限定原 Run；无需手工 step/resume 就成功，效果为 1，父子读取的 State hash 一致 |

新 BEAM Run 为 `schedule-1792516236700224-13-application`，父子 State hash：

```text
66ea7710e4227c7941580bce7a7f0122974c91486a79f17b1710db4da97367a1
```

证据：[report.json](../artifacts/week11-scheduling/report.json)、[运行日志](../artifacts/week11-scheduling/run.log)、[fresh-application.log](../artifacts/week11-scheduling/fresh-application.log)。[journals.bin](../artifacts/week11-scheduling/journals.bin) 保存所有 Run 的完整快照、Events/意图、恢复进度、operation/attempt/receipt、retry、模型录制与核对项；导出 struct 转为 inert map，没有放宽 Codec。业务数据继续保留在开发库。

## 保留的人工核对项

```text
run_id:       schedule-1792516236700224-13-manual
operation_id: once
status/seq:   blocked / 3
safe_mode:    manual
journal:      unknown
```

该 Run 有意保留；不通过自动查询或新 operation ID 将其强行完成。正式输出的扫描后不变断言与[实际只读队列输出](../artifacts/week11-scheduling/queue-cli.json)相互核对。全库可能还有第 8—10 周保留的其他 unknown，不能把本次报告的一项解释成全库只有一项。

需要恢复这个或其他已有 Run 时使用原 ID；先暂停相关后台范围再做人工审阅，按[运行手册](recovery-runbook.md)提交明确 evidence。核对产生新的可执行意图后，仍运行的 Scheduler 可以立即领取，所以人工流程不能仅依据上一次只读快照决定后续动作。

## 验证中修复的问题

预领取入口的初版在外层事务中调用 `Recovery.load`；当启用 retry 但尚无预留行时，内部 `retry_not_found` 的嵌套回滚会污染外层事务。已改为在已有 Run 锁下直接使用不嵌套事务的 snapshot/policy 校验；执行阶段仍在实际写入时验证 claim。带 retry 的新 Run、原 due 和文档示例现已通过。

交叉验证还复现了原恢复器在总期限后直接失败的窗口：工具效果后失联、直到 Run deadline 以后接管时，prepared 操作会退出人工核对队列；本地确认回执也未被接受。修复只针对真实 Run timeout：无准备台账则失败；已确认回执只补录原工具 Event，后续模型仍因原期限失败；模糊投递只归档观察并 blocked。该路径不 reserve retry、不查目标、不执行工具，也不延长任何期限。3 项真实 Worker kill/自然到期测试全部通过，原预算测试保持通过。

## 全新数据库与文档执行

创建本任务专用空库，从零执行 **12 个迁移**，再以 4 个批量 Run 执行完整后台演示，包含两池、续租、实际重投、自动 retry、manual 队列与新 BEAM 应用启动，全部通过。验证结束后仅删除该专用库；开发库、测试库及正式证据保留。

证据：[clean-migrations.log](../artifacts/week11-scheduling/clean-migrations.log)、[clean-probe.log](../artifacts/week11-scheduling/clean-probe.log)、[独立空库报告](../artifacts/week11-clean-scheduling/report.json)。迁移后的历史兼容还由旧 NULL 提示、错误 hint 与原历史/checkpoint 全量回归验证。

新增 [L10](../labs/L10-background-scheduling.md)、[参考解答](../labs/solutions/L10.md)、[ADR 0010](adr/0010-background-scheduling.md)，更新 README 和恢复手册。L10 的 Elixir 示例从 Markdown 提取后在新 BEAM 实际执行：3 个 scoped Run 成功，6 次步骤调用、14 次续期、0 failed/errors；工具效果为 1，重试模型 2 次尝试只接受一个结果。监督树中调度器的 terminate/restart 操作也在独立范围实际验证；专用示例 Run 均按原精确 ID 清理。

文档证据：[示例运行](../artifacts/week11-scheduling/doc-examples.log)、[示例报告](../artifacts/week11-scheduling/doc-report.json)、[监督生命周期](../artifacts/week11-scheduling/lifecycle.log)。

## 保证与当前范围

`status` 的计数反映当前进程的步骤投递与返回，不是业务成功数，也不是持久指标。步骤已经 COMMIT 而 ACK 尚未返回时，续期可能看到旧意图已失效并记录 delivery 失败；业务事实仍以数据库为准。错误最多保留 20 条诊断，周期扫描不以错误为由热循环重发。

当前实现限制每个 Scheduler 的在途 Worker，多个实例容量相加；没有全数据库配额、租户公平性、抢占或吞吐 SLO。候选扫描会校验完整历史并在事务中保留已访问 Run 锁；大量未来重试或损坏记录会增加扫描工作量和锁等待。`SKIP LOCKED` 不等同于无锁或大队列性能保证。

本周验证单机 PostgreSQL、离线 Provider 和受控工具的进程恢复；租约并不提供任意远端效果恰好一次。OS SIGSTOP/SIGCONT 暂停旧 Worker、外部服务 fencing、全局背压、公平性和数据库断连在后续阶段验证。本地完整检查通过，远程 CI 未运行。
