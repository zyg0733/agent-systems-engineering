# 六章首批高风险技术主张核查

本页保留 2026-10-25 首轮核查的基准与执行口径。2026-10-26 的完整路线、练习和解答复查见[第二轮记录](learning-round2-review.md)，其中进一步区分教学 RunServer 的取消顺序、持久超时处理、opaque 与配对回执，以及 P2 最终成功与未查明 blocked 的证据。

2026-10-25。基准代码提交为 `7ab3bac02a93f93fd9be0ca23ea011fb8006cd1c`。六章首个修订提交 `2a3ee3d` 未改变运行时代码；随后针对其 Actions 暴露的领取竞争补充 T13 与最小实现修复。迁移、冻结验收清单和测试排除策略不变。本页核对本仓库的教学契约，不能推广为任意 Agent 系统或外部服务的保证。

本轮采用多代理模拟评审，记录见[首批学习修订审查](learning-revision-review.md)。下面的“代理静态核查”表示读取实现和对应测试定义；它不表示本轮已经重新运行该数据库故障实验，更不是专家或真人试读结果。“纯值实测”仅表示列明的代码段和断言已实际执行。未来源码或章节变更后，应按主张 ID 复查对应边界。

## 证据口径与执行范围

| 记录 | 本轮含义 |
| --- | --- |
| 源码、测试路径和函数/测试名 | 可定位的契约依据；行号以基准提交为准 |
| 第 14 章首个 Elixir 代码块 | 已按字面提取执行：完整 State 比较、checkpoint/tail 比较、缺口和未来 schema 拒绝 |
| 第 16 章首次小练习代码块 | 已按字面提取执行：blocked → cancelled，operation 保持 unknown，终态拒绝 reconcile |
| 执行命令 | `LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/mix run --no-start artifacts/learning-revision-20261025/durable-chapters/pure_examples.exs` |
| 原始证据 | 维护者本地 `artifacts/learning-revision-20261025/durable-chapters/` 下的 `execution-context.json`、`pure_examples.exs`、`pure-examples-verified.log` 和 `source-evidence-sha256.json` |

首次沙箱尝试因 Mix 本机 TCP 文件锁权限被拒绝，未执行示例；允许本机锁后重跑退出码为 0，两段均打印 PASS。以上命令没有启动应用、数据库、Provider 或工具；没有运行跨 BEAM 零调用审计、SIGSTOP、数据库断连或完整 P2/P3。这些范围要引用各自真实运行记录，不能由此次纯值结果代替。

## T01：Kernel 接受事实，不执行模型或工具

**可保留表述**：第 2、5 章的 Kernel 是纯状态转换；合法命令产生下一 State 与 Event，非法命令返回错误。Event 重建按同一规则验证连续 seq、身份、schema 和转换，不通过排序、去重或补执行“修复”历史。

**依据**：[Kernel](../lib/agent_systems_lab/kernel.ex) 的 `dispatch/2`、`apply_event/2`、`rebuild/3`（第 58—103 行）；[kernel_test](../test/agent_systems_lab/kernel_test.exs) 中 `queued runs must start before model or tool commands`、`replay checks identity, sequence, schema, event type, and payload`、`replaying a duplicate or missing event fails at its first sequence mismatch`（第 94、349、385 行）。

**反例与边界**：一个包含工具提议的 Event 不是实际工具调用。纯 Kernel 测试不能证明 Runtime 的进程终止、权限或外部效果安全。**状态：代理静态核查；T03 的纯值代码补充了当前重建示例实测。**

## T02：Context 字节预算不是厂商 token 预算

**可保留表述**：第 8 章用确定性本地 ETF 编码后的字节数衡量完整 payload。任务事实、权限和完整工具台账属于受保护部分；仅压缩可裁剪叙述。受保护部分自身超限时明确拒绝，不删 receipt 来强行装入。

**依据**：[Context](../lib/agent_systems_lab/context.ex) 的 `encoded_bytes/1`、`protected_payload/3`、`compact/3`（第 97—138 行）；[context_test](../test/agent_systems_lab/context_test.exs) 中字节边界、完整工具台账、叙述不能授权和受保护部分超限用例（第 30、79、100、138 行）。

**反例与边界**：把 `max_context_bytes` 数值直接当作 API token 上限，会混淆编码、请求包装和厂商 tokenizer；本实现没有完成这种换算，也不承诺摘要内容具有新的事实权威。**状态：代理静态核查。**

## T03：rebuild 的只读契约不能移给 resume

**可保留表述**：第 14 章 `History.rebuild/3` 和经验证的 `CheckpointStore.rebuild/2` 恢复已接受事实；`Recovery.resume/2` 会推进业务，可能调用模型和工具。能解释历史不代表具备原配置、有效资格、权限和剩余预算。

**依据**：[History](../lib/agent_systems_lab/history.ex) 的 `rebuild/3`、`from_checkpoint/2`；[Recovery](../lib/agent_systems_lab/recovery.ex) 的 `load/1`、`resume/2`、`execute_claim/2`（第 102、128、156 行）；[RebuildAudit](../lib/agent_systems_lab/rebuild_audit.ex) 的执行边界清单与 `run/2`；[history_test](../test/agent_systems_lab/history_test.exs) 的 every-cut、严格历史与 schema 测试（第 7、43、61 行）。

**反例与边界**：`lab.history` 先创建有真实文件写入的演示，再在新 BEAM 只读核验；整个 runner 不能被称为零效果。`RebuildAudit` 计数范围是当前 VM，应使用新或空闲 BEAM，不能以“没有控制台日志”代替调用计数。**状态：代理静态核查 + 第 14 章纯值例子实测通过；本轮未重跑新 BEAM 数据库审计。**

## T04：checkpoint hash 既非权威，也非启动加速证明

**可保留表述**：第 14 章 hash 用于确定性内容匹配，不是签名或写入者身份认证。`History.from_checkpoint/2` 信任调用者提供的 checkpoint；持久入口还用原始完整前缀核验。当前实现不承诺减少读取或加速启动，最新 checkpoint 损坏时不静默回退。

**依据**：[Checkpoint](../lib/agent_systems_lab/checkpoint.ex) 的 `verify/2`（第 41 行）、[CheckpointStore](../lib/agent_systems_lab/checkpoint_store.ex) 的 `rebuild_snapshot/2`、`decode_row/2`（第 104、147 行）；[checkpoint_store_test](../test/agent_systems_lab/checkpoint_store_test.exs) 中 latest corruption、self consistent forged checkpoint（第 77、125 行）；[history_test](../test/agent_systems_lab/history_test.exs) 中 forged state（第 117 行）。

**反例与边界**：伪造 State 后重算 State hash，内容仍可自洽，却不匹配权威历史。仅调用 `Checkpoint.validate/1` 不是前缀授权检查；删原历史后不能继续声称本实现验证了来源。**状态：代理静态核查；普通 checkpoint/tail 纯值路径实测通过，数据库伪造/损坏测试本轮未单独重跑。**

## T05：录制响应必须绑定输入与实际接受事件

**可保留表述**：第 14 章录制保存完整、通过校验且被接受的响应，核对精确输入、Context 来源和接受 Event；`Recorded` 不按语义相似度寻找回答。显式使用录制适配器后，宿主继续 Runtime 仍会执行正常业务检查。

**依据**：[Recording](../lib/agent_systems_lab/recording.ex) 的 `validate/1`、`verify/2`（第 46、85 行）；[ModelResultStore](../lib/agent_systems_lab/model_result_store.ex) 的 `insert_for_transition/4`、`load/1`；[recording_test](../test/agent_systems_lab/recording_test.exs) 的精确类型、篡改与键形状测试（第 35、79、92 行）；[run_server_recording_test](../test/agent_systems_lab/run_server_recording_test.exs) 的接受绑定和取消候选用例（第 20、52 行）。

**反例与边界**：仅有一份响应 hash，不能证明响应被 Kernel 接受；标签相同也不能证明 Provider 身份。当前录制不是厂商原始网络包或完整计费归档。**状态：代理静态核查。**

## T06：receipt 与 结果事务 COMMIT 是不同提交

**可保留表述**：第 16 章必须分开 prepare、目标 effect、本地配对 receipt、Kernel 接受 Event 四个边界。完整 receipt 可以先于 Kernel 接受存在；恢复应复用已确认 receipt，补交缺失事实，而非再产生效果。

**依据**：[DurableTools](../lib/agent_systems_lab/durable_tools.ex) 的 `execute/3`、`confirmed_receipt/3`、`confirm_result/5`（第 61、139、515 行）；[Storage](../lib/agent_systems_lab/storage.ex) 的 `dispatch/4`（第 167 行）；[recovery_test](../test/agent_systems_lab/recovery_test.exs) 的 `confirmed durable receipt is reused after a crash before kernel result acceptance`（第 147 行）；[durable_tools_test](../test/agent_systems_lab/durable_tools_test.exs) 的 after receipt COMMIT 测试（第 83 行）。

**反例与边界**：HTTP 成功文字、当前文件内容相同或 `stats/1` 诊断不是原 operation 的通用权威 receipt。Run/Event/intent 的数据库原子性不覆盖任意远端效果。**状态：代理静态核查；本轮未重新注入 receipt/Kernel 间真实崩溃。**

## T07：caller error 不能证明 COMMIT 回滚

**可保留表述**：第 14、16、20 章区分“服务器提交”与“调用者收到成功确认”。结果未知时重读原身份和持久事实；领取回报未知时不启动业务 Worker，按持久 lease 处理接管。

**依据**：[Storage](../lib/agent_systems_lab/storage.ex) 的事务边界注释和 `commit/2` helper（第 13—20、576 行）；[storage_test](../test/agent_systems_lab/storage_test.exs) 的 before/after COMMIT kill 用例（第 276、292 行）；[IntentStore](../lib/agent_systems_lab/intent_store.ex) 的事务后 hook（第 411 行）与 [intent_store_test](../test/agent_systems_lab/intent_store_test.exs) 的 claimant kill 用例（第 194 行）；[DatabaseFaultDemo](../lib/agent_systems_lab/database_fault_demo.ex) 的 `commit_ack_lost` case（第 142—170 行）。

**反例与边界**：协议探针截断工具结果 COMMIT ACK 的直接证据，不能扩写成“同一次探针还验证了所有领取故障”；领取策略有不同组件测试。本地 helper 退出同样不撤销已经提交的事务。**状态：代理静态核查；本轮未重跑协议断连探针。**

## T08：Mock 的幂等效果不能推广为任意远端 exactly-once

**可保留表述**：受控 `DurableMock` 用原 Run/operation、精确输入和独立目标台账查询/复用已存在效果。相同 operation 换参数拒绝；不可查询文件或远端在模糊结果后不得自动重发。

**依据**：[DurableMock](../lib/agent_systems_lab/tools/durable_mock.ex) 的 `execute/5`、`lookup/3`、`decode/3`（第 14、41、85 行）；[DurableTools](../lib/agent_systems_lab/durable_tools.ex) 的 `execute/3` 和能力分支；[durable_tools_test](../test/agent_systems_lab/durable_tools_test.exs) 的一个效果、多次投递（第 24 行）、prepared file 不重发（第 127 行）、精确输入冲突（第 278 行）；[recovery_test](../test/agent_systems_lab/recovery_test.exs) 的两次效果后退出与匹配文件仍 unknown（第 132、202 行）。

**反例与边界**：远端可能不支持幂等键、到期删除键，或查询无法区分尚未完成和未执行。仅把 operation ID 放进请求，不足以证明这些性质；`safe_mode: queryable` 当前只用于对应 Mock 契约。**状态：代理静态核查。**

## T09：直接取消 blocked Run 会退出核对队列，unknown 仍保留

**修正后的表述**：不能笼统写“unknown 一直 blocked，直到核对”。当前 Kernel 允许取消所有非终态，包括 blocked；Run 变 cancelled 后不再推进，operation 的 unknown 仍保留。`ReconciliationQueue` 只列 blocked，`Recovery.reconcile/2` 对 cancelled 返回 `:not_blocked`。

**依据**：[Kernel](../lib/agent_systems_lab/kernel.ex) 的终态拒绝与通用 cancel（第 105、149—150 行）；[Recovery](../lib/agent_systems_lab/recovery.ex) 的 `reconcile/2`、`cancel/2`（第 228、322 行）；[ReconciliationQueue](../lib/agent_systems_lab/reconciliation_queue.ex) 的 `list/1`、`entry/1`（第 21、59 行）；[kernel_test](../test/agent_systems_lab/kernel_test.exs) 的 unresolved facts 和终态拒绝（第 298、319 行）；[reconciliation_queue_test](../test/agent_systems_lab/reconciliation_queue_test.exs) 的 legacy cancellable 用例（第 98 行）。

**反例与边界**：队列空不证明所有效果已解决。直接取消后，可信宿主须在原 Run 之外继续调查与记录；当前没有通用终态后核对台账或重开入口。若需要现有 reconciliation API，应先保留 blocked 并核对，再终结。本轮修订解释既有接口，没有静默修改状态机，也没有把说明缺口定性为运行时缺陷。**状态：代理静态核查 + 第 16 章纯值取消例子实测通过；数据库队列分支本轮未单独重跑。**

## T10：Workflow 父取消保留 ambiguous 子核对，是另一条策略

**可保留表述**：父 Workflow 关闭执行门，已不确定的子 Run 保持 blocked 与核对入口；核对成功不会重开父级，也不释放下游依赖。它不同于 T09 中直接取消该子 Run。

**依据**：[Workflows.Store](../lib/agent_systems_lab/workflows/store.ex) 的 `gate_in_transaction/3`、`fanout/1`、`stop_child/3`（第 248、454、470 行）；[workflows_coordinator_test](../test/agent_systems_lab/workflows_coordinator_test.exs) 的 `an ambiguous non-idempotent child stays visible and cannot unlock its dependent`（第 223—289 行）；[WorkflowDemo](../lib/agent_systems_lab/workflow_demo.ex) 的 `unknown_on_cancel`（第 389—436 行）。

**反例与边界**：父状态 cancelled 不意味着每个子 Run 已被直接取消；子人工核对变 running 也不授权再执行模型。测试明确后续 `claim` 和 `step` 返回 `workflow_closed`。**状态：代理静态核查；本轮未重跑 Workflow 故障 runner。**

## T11：lease 资格以数据库当前事实为准，renew 不复活过期代次

**可保留表述**：第 20 章 token/generation/原 intent 及数据库当前 expiry 一同决定资格。renew UPDATE 自身再次要求 expiry 大于数据库实时钟，且从该时钟计算新 deadline；本地缓存的未来时间不能复活过期 claim，旧缓存过期也不能否定数据库里成功续期的同一代次。

**依据**：[IntentStore](../lib/agent_systems_lab/intent_store.ex) 的 `renew/2`（第 297—327 行）、`verify/4`（第 372—383 行）、`database_now/1`（第 471 行）；[fencing_safety_test](../test/agent_systems_lab/fencing_safety_test.exs) 的旧观察时间、伪造未来 expiry 和同 seq 混合身份测试（第 36、59、77 行）。PostgreSQL 官方说明 `now()` 使用事务起始时间，`clock_timestamp()` 随实际执行时间变化：[PostgreSQL 18 当前日期与时间](https://www.postgresql.org/docs/18/functions-datetime.html#FUNCTIONS-DATETIME-CURRENT)，2026-10-25 核对。

**反例与边界**：只比较 seq 会漏掉同 seq 接管，只比较 token 会漏掉暂停后跨 expiry 的 renew。数据库墙钟需要运维保证；UTC 表达不自动提供硬实时、跨库同步或防时钟回拨证明。**状态：代理静态核查 + 官方文档核对；三情形为推理题，本轮未重跑 SQL/信号实验。**

## T12：执行前检查不能代替提交门，恢复不重开预算

**可保留表述**：领取后、效果授权和结果提交均检查相应权威。恢复保留原权限、attempt/cursor/输出扣费、dispatch、retry due 和绝对 deadline；heartbeat 只延长 lease。deadline 后允许核对旧效果和接受已确认 receipt，不授权新的业务效果。

**依据**：[Recovery](../lib/agent_systems_lab/recovery.ex) 的 `execute_claim/2`（第 156—183 行）；[DurableTools](../lib/agent_systems_lab/durable_tools.ex) 的效果分支、`confirm_result/5` 和 `authorize/2`（第 360—445、515、584 行）；[RecoveryStore](../lib/agent_systems_lab/recovery_store.ex) 的 `begin_model_attempt/2`、`charge_frame/3`、`check_effect_deadline/2`；[TaskBudgetStore](../lib/agent_systems_lab/task_budget_store.ex) 的 `reserve/1`；[fencing_safety_test](../test/agent_systems_lab/fencing_safety_test.exs) 的 stale receipt/manual/timeout/工具入口测试（第 196、213、243、262 行）；[scheduler_deadline_test](../test/agent_systems_lab/scheduler_deadline_test.exs) 的期限后 unknown 与已确认回执（第 24、50 行）；[recovery_test](../test/agent_systems_lab/recovery_test.exs) 的已扣输出与效果门 deadline（第 236、342 行）。

**反例与边界**：停止本地 executor 不证明远端停止，fencing 拒绝本地迟到写入不撤销已经发生的效果。换 Run/operation、清 cursor/attempt 或延长任务 deadline 来“恢复”，是在改变原契约。**状态：代理静态核查；本轮未重跑各数据库故障窗口。**

## T13：扫描候选不等于当前领取资格

**修正后的表述**：第 20 章的候选 JOIN 使用语句快照，`FOR UPDATE OF Run SKIP LOCKED` 只锁 Run。已在快照中满足条件的 intent，可能在取得 Run 锁之前被另一事务领取。锁下重读发现当前有效 lease 时，应跳过该候选并继续扫描；这不属于损坏的恢复配置，也不意味着可以替换原 token。

**依据**：[IntentStore](../lib/agent_systems_lab/intent_store.ex) 的 `next_candidate/4`、`claim_page/4` 和 `available/2`；[intent_dispatch_test](../test/agent_systems_lab/intent_dispatch_test.exs) 的并行领取与旧候选快照测试。PostgreSQL 官方说明指定 `OF` 只锁相应表，其余 JOIN 表按普通查询读取：[PostgreSQL 18 SELECT 锁定说明](https://www.postgresql.org/docs/18/sql-select.html#SQL-FOR-UPDATE-SHARE)。2026-10-25 核对。

**反例与边界**：不能在最外层把 `:intent_claimed` 一律改成空结果，否则会漏掉后续可领取 Run；显式 `claim(run_id)` 仍拒绝当前有效 lease。正常并行领取的六个唯一 Run、六个唯一 token、generation=1 及六个空结果断言均保留。首次 CI 的单项失败与本地重复复现记录见[修订审查](learning-revision-review.md)，不能用后续固定夹具或崩溃核验的成功覆盖该失败。

## 继续维护本台账

每次变更先标出受影响 T 编号，再更新主张、具体入口、相邻反例和执行证据。章节推理题、测试定义、实际日志三类证据分别记录；不从 CI 总数推出每个教学代码块都已逐字执行，也不从代理模拟得分推出真人学习效果。当前工作完成与否按本轮[修订审查](learning-revision-review.md)和项目 CI 记录，不以旧研究阶段的真人试读工具字段作为本轮教材修订门槛。
