# L09：P2 故障窗口验收与恢复演练

对应第 10 周，建议用时 12—16 小时；前置实验为 L01—L08。本次冻结前两周建立的恢复语义，系统验证工具成功后崩溃、接管中再次崩溃、退避与核对提交等边界，完成 P2 阶段验收。此处 L09 按仓库实际实验顺序编号，对应第 10 周。

验收对象是已提交事实、外部回执与安全的下一步。任务停在明确的 `blocked`、进入可见核对队列且没有重复投递，可以是正确结果；把所有任务都推进 `succeeded` 不能作为验收标准。

阅读 [ADR 0009](../docs/adr/0009-p2-fault-acceptance.md)、[恢复运行手册](../docs/recovery-runbook.md) 与 [P2 故障报告](../docs/p2-fault-report.md)。最终实测数量与环境以 [第 10 周验收记录](../docs/validation-week10.md) 为准。

## 1. 明确验收的不变量

为一次业务操作分别记录 Run ID、operation ID、精确参数、claim 代次、delivery attempt、目标回执与 Kernel Event。它们不能互相替代：

| 证据 | 要证明的性质 |
| --- | --- |
| 原始 Event 与投影 | 序号连续、状态一致；完整重建与 checkpoint 重建得到相同 State |
| claim/token/generation | 只有当前有效资格能写入；过期 owner 的迟到结果被拒绝 |
| Recovery progress | cursor、累计输出、模型尝试与绝对 deadline 在重启后保留 |
| Retry journal | 预留次数不返还，原 due 不重算，次数与时间有界 |
| operation 与 attempts | 原操作及参数绑定不变；每次执行、查询、观察和人工核对有独立审计 |
| 目标业务回执 | 已发生的效果可以在能力契约允许时按原身份核对 |
| unknown / reconcile intent | 无法判断的结果保持可见，不能被失败字样或新 operation ID 掩盖 |
| 模型录制 | 只录制完整且已经被接受的响应；接受事务前后均不存在半份事实 |

把以下五条作为硬性门槛：

1. 已确认的业务效果不因 caller 未收到 ACK 而重复产生。
2. 未知的非幂等或不可查询效果不自动重发；正确暂停必须能从队列找到。
3. 新进程保留旧预算、cursor、重试次数与时间边界，旧 token 无法覆盖新事实。
4. 纯重建、只读核对队列和审计查询不执行 Provider 或工具。
5. 故障窗口有确定 gate、真实退出和独立读取证据，不能用普通 sleep 猜注入位置。

## 2. 运行完整验收

在项目根目录执行：

运行下段完整回归前，先按[完整回归的环境准备](../docs/command-reference.md#完整回归的环境准备)确认自己的可丢弃 PostgreSQL 实例；自定义实例先设置 `PGHOST/PGPORT/PGUSER/PGPASSWORD`，再清除 `DATABASE_URL`。完整回归使用默认测试库名 `agent_systems_lab_test`；另开终端时重新做同样准备。

```sh
unset DATABASE_URL MIX_ENV
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
./scripts/postgres start
./scripts/mix setup
env -u DATABASE_URL MIX_ENV=test LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/mix check
./scripts/mix lab.p2
LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/mix test
```

后续命令与 IEx 沿用这个终端；另开终端时先选择实例、清除 `DATABASE_URL` 并重新设置上述两个环境变量。P2 需要启用 Repo，并由 runner 自己显式驱动领取、等待与接管，全局 Scheduler 不应同时消费这些故障夹具。

`lab.p2` 为每个故障窗口创建独立 Run，默认每个窗口重复 20 次。它会执行真实的调用进程 kill、等待 PostgreSQL lease 到期、在同一业务身份下接管，并用新 BEAM 继续专门的跨进程场景。该命令会调用离线 Provider 和持久 Mock，属于执行路径。请使用实验数据库和独立输出目录。

快速检查或再次运行时明确指定参数：

```sh
./scripts/mix lab.p2 --output artifacts/week10-p2-smoke --repetitions 1
./scripts/mix lab.p2 --output artifacts/week10-p2-repeat --repetitions 20
```

输出目录已存在时命令拒绝覆盖。`--repetitions 1` 适合检查脚本与环境，正式 P2 验收仍使用 20。重复次数说明这些确定边界被重复验证，不构成故障概率、生产 SLO 或任意崩溃点的统计保证。

先查看 `report.json` 和对应完整审计。每个 `故障名/轮次/` 目录保存 `initial.bin`（注入前）、`before.bin`（故障后第一次采证）、`after.bin`（处理后）、`crashes.bin`（实际退出与 claim）及 `summary.json`。不能只导出最终成功摘要。记录包含 Run/seq、claim、原始 Events、Recovery progress、Retry deliveries、operation/attempts、录制与待核对状态。新 BEAM 场景另有 `fresh-resume.log` 与 `fresh-rebuild.log`。目标计数用于教学诊断；业务上是否发生必须依据该工具契约允许读取的回执或可信人工证据。

默认矩阵的 16 个窗口如下，20 轮对应目标 320 个 probe；实际完成数与 kill 数分别检查 report，二次失联不能只算一次 kill：

| case ID | 到达的边界 |
| --- | --- |
| `after_claim` | 调度领取已经提交，工作尚未执行 |
| `model_before_commit` / `model_after_commit` | 模型结果接受事务 COMMIT 前 / 后 |
| `tool_after_prepare` / `tool_before_effect` | 工具 attempt 准备后 / 效果前 |
| `tool_after_effect` / `tool_before_receipt` | 目标效果后 / 本地 receipt 确认前 |
| `tool_after_receipt` | 本地 receipt 已确认，Kernel 尚未接受 |
| `tool_result_before_commit` / `tool_result_after_commit` | 工具结果接受事务 COMMIT 前 / 后 |
| `recovery_after_effect_twice` | 初始 caller 与恢复 caller 均在效果后失联 |
| `retry_after_reserve` / `retry_after_schedule` | 重试预留 / due 调度已提交 |
| `query_before_commit` / `query_after_commit` | 核对结果接受事务 COMMIT 前 / 后 |
| `manual_after_receipt` | 人工 receipt 已确认，核对 Event 尚未接受 |

按当前 runner 的静态契约，1 轮预期为 16 probe、17 次真实 kill，20 轮为 320 probe、340 次 kill；多出的一次来自每轮的 `recovery_after_effect_twice`。新 BEAM 场景只在第一轮的两个指定窗口执行，因此两种轮数的 `fresh_vm_probes` 均预期为 2。以上是核对目标，实际数量必须从本次报告读取。

这 16 个窗口的受控夹具都有可复用的确认结果，runner 最终逐项要求 `succeeded`、一个 Mock 效果及空的当前核对队列。`manual_after_receipt` 在 kill 前已经提交人工确认回执，恢复时复用它并完成核对，不能把这个窗口的最终空队列解释为“尚未查明的 manual unknown 也自动解决了”。另按 [L08 第 6 节](L08-retries-and-reconciliation.md#6-让-unknown-可见并通过核对解除)在提交人工证据之前采证，或检查对应禁止重投保护测试，提交至少一条仍未查明且未取消的 blocked/可见队列证据；它与 runner 的成功窗口分别验收。

## 3. 工具成功后的三个提交边界

以一次 `mock_write` 为例，画出下面顺序，并给每两个相邻提交之间安排一个 kill：

```text
原调用意图已提交
  → operation / execution attempt 准备完成
  → 目标业务效果与稳定回执已提交
  → 本地 operation receipt 已确认
  → Kernel tool_result Event / Run / 下一意图已提交
  → caller 收到返回
```

工具返回成功与 Runtime 已接受结果是两个事实。分别比较：

| kill 位置 | 新 owner 的依据 | 正确观察 |
| --- | --- | --- |
| 准备后、效果前 | 原 operation 已经存在，执行是否完成尚不确定 | 仅在原能力契约允许时安全取得结果；非幂等保持 unknown |
| 目标效果后、本地 receipt 前 | 可查询 Mock 的稳定身份与目标回执 | 核对或幂等复用原效果，效果总数为 1 |
| 本地 receipt 后、Kernel 接受前 | 已确认、完整配对的本地 receipt | 复用同一结果，不再执行目标效果 |
| Kernel COMMIT 前 | 原始 Event 尚未接受本次结果 | 重读原 operation 与 receipt，再提交缺失的事实 |
| Kernel COMMIT 后、ACK 前 | 结果与下一意图已经是事实 | 消费下一意图，不能再接受同一工具结果 |

对照文件操作：文件写入与 PostgreSQL 不共享事务。准备后崩溃已足以产生不确定性；不能从“没有本地成功”推出“没有写入”。内容符合预期、修改时间或一个教学计数器也不能证明原 operation 的完成。文件案例必须保留 `blocked`、原 operation 和人工核对入口，直到有明确可信的证据。

练习：删掉本地 receipt 复用分支，或在未知文件路径重新调用工具。前者应破坏已确认结果复用断言；后者应破坏禁止重复写入断言。完成对照后恢复实现，不保留破坏性修改。

## 4. 接管中再次崩溃

至少做两条链路：

1. 初始 worker 在效果后失联；恢复者取得新 claim 后再次失联；第三个 worker 用同一 Run 与 operation 完成安全观察或继续。
2. 初始 worker 留下 unknown；核对者在保存回执或接受 reconciliation 事务边界失联；后续核对者重读事实，核对 Event 只被接受一次。

每次退出都必须先收到指定 hook 到达通知，再监控实际调用进程的 `:DOWN`。`after_frame` 位于 Provider worker，kill 它只能证明 Provider 失败；用它证明调用 Recovery 的进程退出时，测试必须另行 kill 真正的 caller。工具 hooks 也可能在工具 worker 中，必须记录被杀的进程角色。

两个失联 owner 的 lease 都按 PostgreSQL 时间自然到期后才允许接管。恢复者不能清空旧 token、手动回拨 due、直接改 claim 到期时间，或给原任务分配新 ID。故障用 hook 与 gate 精确定位；等待真实 lease / due 到期是时间资格测试，不是猜测故障位置。

比较每次接管前后：

- token 更新、generation 增长，旧 token 写入被 `stale_claim` 或 `claim_expired` 拒绝。
- 原 operation ID 与参数完全相同，新增的是 attempt 或 observation，目标业务效果不增长。
- 已扣输出与模型尝试不减少，cursor 只随已接受模型结果推进。
- unknown 在多次 resume 后仍可见；确认回执已保存时不伪造新的 unknown。
- Recovery 再次崩溃后，第三个 worker 仍能仅用持久事实决定下一步。

## 5. 退避、超时与 unknown 的交叉验证

在 `after_retry_reserve` 后失联，检查预留 ordinal 保留；未完成模型/查询先记 abandonment 并有限退避，工具的不确定性进入核对。接着在 `after_retry_schedule` 后失联，新进程必须读到相同 due，而不是从重启时刻重新计算。

due 前多次 `resume` 应返回等待快照且不持有 lease；`step` 返回 `{:error, {:retry_not_due, due}}`。到期后只消耗下一次有界尝试。核对机会耗尽不能使模糊结果变成成功或重新授予执行资格，manual 队列仍保留。

超时后先停止并等待本地 worker 退出，再归档观察结果。若本地已确认 receipt，复用它；否则 unknown。这个顺序不承诺真实远端任务已经取消。Run deadline 过后仍允许核对可能发生的效果，核对成功后也不能执行新的模型或工具步骤。

P2 不需要新增后台定时调度器。等待和再调用由实验观察者或操作人明确驱动，原 deadline、次数上限、due 与权限继续作为资格来源。

## 6. 一次操作员恢复演练

从正式报告中选择一条演示 Run，先按 [恢复运行手册](../docs/recovery-runbook.md) 只读采集证据。不要调用 `create_run` 重建原任务；`lab.recover` 运行的是新的第 8 周演示，也不接管已有 Run。

按下列顺序完成演练：

1. 用 `Storage.load`、`Recovery.load`、模型录制、retry 与 operation/attempts 对齐当前 seq。
2. 若 intent 有有效 owner，停止第二份执行；若尚在退避，等原 due。
3. 若 blocked，先判断 queue 的 `queryable` / `manual` 和 `recoverable`，再显式核对。
4. 需要人工证据时，固定 Run、operation、tool、参数与预期 seq，收集独立业务回执；使用当前 claim 提交配对结果。
5. 写入遇到过期或冲突时重新采证；不要用旧 token 覆盖已前进的事实。
6. 续跑后重建并检查回执、历史和资源，保存恢复决策及其依据。

若目标没有权威查询能力，应把“继续 blocked、明确交接”作为完成结果。若数据库不可用，既不能确认 COMMIT，也不能证明外部未执行；恢复数据库读取后再判断。取消只停止未来执行，不撤销外部效果。

## 7. P2 交付与完成标准

提交以下成果：

- 可重复执行的 `lab.p2` 与对应故障注入测试，正式默认重复轮次全部通过。
- 每个故障点的 initial/before/after 审计、实际退出记录、故障位置、正确结果、实际结果与未覆盖边界。
- 新 BEAM 读取并续跑相同 Run 的证据；纯重建与队列读取零执行证据。
- 至少一条恢复中再次崩溃链路，以及一条可见且禁止自动重发的 manual unknown。
- [P2 故障报告](../docs/p2-fault-report.md)、[恢复运行手册](../docs/recovery-runbook.md) 和本实验解答。
- 全量 `mix check` 与无数据库测试通过；已有场景、历史重建、事务崩溃、预算和受控文件测试仍通过。

建议评分：提交边界与二次崩溃 30 分，幂等/unknown 与核对 25 分，预算/退避/资格保留 20 分，可审计证据与运行手册 20 分，边界说明 5 分。任一硬性不变量失败都应暂停 P2 验收。

当前验证是单机 PostgreSQL 与离线 Scripted Provider 的教学范围。它没有验证主机断电、磁盘介质损坏、网络分区、真实服务的计费与幂等、生产后台 dispatcher 或完整分布式暂停接管。参考解答见 [L09 解答](solutions/L09.md)。
