# 十二单元课程地图：原计划与实际实验入口

原[研究计划第 8 节](../Agent%20Systems%20Engineering%20研究与落地计划.md#08-十二个实验与故障验收)的 **L01–L12 是主题编号**。实施中加入 Streaming、重试、故障验收等分册，实际已交付 **25 份手册，连续编号为 L01–L25**。本地图用 C01–C12 固定课程单元对应原十二主题；L23–L25 是 C12 之后的发行与跨环境进阶实验。保留所有已交付文件名，不把实际 L12 误称为评估实验。30 章的七篇依赖与正文状态见[章节设计卡](../book/chapter-cards.md)。

所有单元均从同一 [mix.exs](../mix.exs) `0.1.0-dev` 完整源码开始，通过 [Reproduction](../lib/agent_systems_lab/reproduction.ex) 的 source manifest 冻结文件字节、大小、模式和目录。独立练习时导出到自己拥有的新目录，可在副本中改变实现再与参考解答对照。仓库没有历史 Git 标签；本课程不声称存在逐实验的 start/solution 标签，也不伪造逐周缺功能的起始版本。教师应保存学生修改与冻结源的 diff，禁止覆盖正式试读包。

共同环境：已验收 macOS arm64、Elixir **1.20.4** / OTP **28.4**、PostgreSQL **18.6**；精确依赖以 [mix.lock](../mix.lock) 为准。按 [README](../README.md) 安装、启动自有实验 PG 并运行 `./scripts/mix setup`；完整 `./scripts/mix check` 包含格式、warnings-as-errors、测试、固定场景和数据库故障验收。`LAB_DATABASE_ENABLED=false ./scripts/mix test` 是另报排除数的内存回归，不能替代数据库用例。完整隔离/MCP 实验还需 clang、Seatbelt 和 Unix 信号；平台不支持时明确阻断，不跳过后声称完整通过。

以下测试命令是受版本控制的固定入口，默认完整 PG 环境；不是从读者反馈生成的命令，也不会自动执行。每单元须提交独立任务报告、预测与实际差异、原始输出以及所列成功标准。现有完整实现供阅读和对照，只运行演示不能代替学生任务。使用实验 CLI 时按对应手册指定**全新输出目录**，保留失败日志，不覆盖以前的产物。

| 课程 | 原计划主题 | 实际连续交付手册 |
| --- | --- | --- |
| C01 | 原 L01 状态机与 reducer | [L01](../labs/L01-state-machine.md) |
| C02 | 原 L02 事务与持久化 | [L02](../labs/L02-transactions.md) |
| C03 | 原 L03 Agent Loop 与工具调用 | [L03](../labs/L03-streaming-control.md)、[L04](../labs/L04-controlled-tools.md) |
| C04 | 原 L04 Session 与 Context | [L05](../labs/L05-session-context.md) |
| C05 | 原 L05 历史与 checkpoint | [L06](../labs/L06-history-checkpoints.md) |
| C06 | 原 L06 工具幂等与不确定结果 | [L07](../labs/L07-recovery.md)、[L08](../labs/L08-retries-and-reconciliation.md)、[L09](../labs/L09-p2-fault-acceptance.md) |
| C07 | 原 L07 Queue 与 Worker | [L10](../labs/L10-background-scheduling.md)、[L12](../labs/L12-backpressure-budgets-fairness.md)、[L13](../labs/L13-database-outages-p3.md) |
| C08 | 原 L08 Lease 与 fencing | [L11](../labs/L11-leases-heartbeats-fencing.md) |
| C09 | 原 L09 Sandbox 与权限 | [L14](../labs/L14-isolated-execution.md) |
| C10 | 原 L10 MCP 工具适配 | [L15](../labs/L15-mcp-stdio.md) |
| C11 | 原 L11 DAG 与人工审批 | [L16](../labs/L16-dag-workflows.md)、[L17](../labs/L17-human-approvals.md) |
| C12 | 原 L12 评估与回归 | [L18](../labs/L18-observability.md)、[L19](../labs/L19-repeatable-evaluation.md)、[L20](../labs/L20-history-migration-backup-restore.md)、[L21](../labs/L21-reader-study-and-clean-reproduction.md)、[L22](../labs/L22-release-readiness.md) |

实际执行顺序为 C01–C06 → C07 的 L10 → C08 的 L11 → 回到 C07 完成 L12/L13 → C09–C12。这样先理解基本领取，再验证 lease/fencing，最后做背压与断连综合实验，满足各手册前置；课程编号保持原主题顺序。C01–C06 构成可靠执行阶段，C07–C11 构成调度、安全与编排阶段，C12 提交综合验收。C12 的 L19 为原评估核心，其他分册为固定路径的综合补充，可拆多次课。单元不等于作者周次，建议课时依各手册的实际前置与任务安排。

教师通用评分：不变量说明、反例与修复、实际证据三项各 0–2 分，至少 **5/6** 且无违反权限、预算、恢复约束才通过。只抄参考输出不给证据分。以下各单元再规定具体判据。

<!-- course:C01 -->
## C01 状态机与 reducer（原计划 L01）

起点：统一 `0.1.0-dev` 冻结源码；先读 ch01/ch02，了解纯函数和模式匹配，从当前完整实现阅读 Kernel 与 Mock。实验入口：[L01](../labs/L01-state-machine.md)。

学生任务：画出七种状态及非法命令；独立构造合法事件序列并重建；提交错 ID、重复 ID 和终态迟到结果。

参考解答：[L01 教师参考](../labs/solutions/L01.md)。评分时核对 `Kernel.dispatch/2` 与 `rebuild/3` 的输入输出、错误原因及拒绝前后状态。

测试命令：对应[Kernel](../test/agent_systems_lab/kernel_test.exs)与[场景](../test/agent_systems_lab/scenarios_test.exs)测试，在项目根目录执行并记录退出码：

```sh
./scripts/mix test test/agent_systems_lab/kernel_test.exs test/agent_systems_lab/scenarios_test.exs
```

成功标准：状态、seq、pending operation 与完整事件一致；非法转换不产生新事件；重放不调用工具。

平台要求：无需数据库，可在本机 Elixir/OTP 完成；后续完整实验使用共同验收环境，无需真实模型 key。

<!-- course:C02 -->
## C02 事务与持久化（原计划 L02）

起点：统一 `0.1.0-dev` 冻结源码；完成 C01，理解 SQL 事务、Ecto Repo、monitor；从当前 Storage 入口开始。实验入口：[L02](../labs/L02-transactions.md)。

学生任务：画出 Run/Event/intent 同一事务；预测并执行首次创建和已有 Run 转换的 COMMIT 前后四个 kill 点；新进程对比持久投影与历史重建。

参考解答：[L02 教师参考](../labs/solutions/L02.md)。评分时逐窗口对比旧/新 seq、Event 与 pending intent，不只检查是否存在 Run 行。

测试命令：对应[Storage](../test/agent_systems_lab/storage_test.exs)与[持久 RunServer](../test/agent_systems_lab/persisted_run_server_test.exs)测试：

```sh
./scripts/mix test test/agent_systems_lab/storage_test.exs test/agent_systems_lab/persisted_run_server_test.exs
```

成功标准：提交前无半笔新事实；提交后 ACK 丢失仍保留完整事实；竞争 expected_seq 最多一项提交；记录真实 PG 持久性配置。

平台要求：真实 PostgreSQL，连接须指向可丢弃的 dev/test 实验库；应用 kill 不等同于主机断电测试。

<!-- course:C03 -->
## C03 Agent Loop 与工具调用（原计划 L03）

起点：统一 `0.1.0-dev` 冻结源码；完成 C01/C02，理解异步 Task、完整响应、schema、SHA-256；阅读 ch05/ch06/ch07。入口：[L03](../labs/L03-streaming-control.md)、[L04](../labs/L04-controlled-tools.md)。

学生任务：用 Scripted 屏障在半截参数时取消并触发预算限制；完成受控文件读取、补丁、写入与调用配对；运行固定离线修复并解释 diff。

参考解答：[L03 教师参考](../labs/solutions/L03.md)、[L04 教师参考](../labs/solutions/L04.md)。分别记录流 seq 与 Event seq、模型轮数与工具执行数。

测试命令：对应[运行中流](../test/agent_systems_lab/run_server_stream_test.exs)、[文件调用](../test/agent_systems_lab/run_server_files_test.exs)、[结果配对](../test/agent_systems_lab/kernel_tool_pairing_test.exs)测试：

```sh
./scripts/mix test test/agent_systems_lab/run_server_stream_test.exs test/agent_systems_lab/run_server_files_test.exs test/agent_systems_lab/kernel_tool_pairing_test.exs
```

成功标准：半截参数无效果；错 ID/工具名结果被拒；取消后不新增操作；补丁预检失败文件不变；固定修复前失败、后成功。

平台要求：完整实验需 PostgreSQL 和私有 workspace；不调用真实模型，修复只执行固定可信 fixture。

<!-- course:C04 -->
## C04 Session 与 Context（原计划 L04）

起点：统一 `0.1.0-dev` 冻结源码；完成 C03，理解完整 Session 不等于模型输入；读 ch08/ch09/ch10。入口：[L05](../labs/L05-session-context.md)。

学生任务：构造含叙述、回执和宿主约束的 Session；缩小叙述预算生成 manifest；篡改 snapshot 或 manifest 并核验拒绝。

参考解答：[L05 教师参考](../labs/solutions/L05.md)。评分时核对 manifest 来源与实际 payload，不以摘要的授权文字代替宿主权限。

测试命令：对应[Session](../test/agent_systems_lab/session_test.exs)、[Context](../test/agent_systems_lab/context_test.exs)、[持久 Context](../test/agent_systems_lab/persisted_context_runtime_test.exs)测试：

```sh
./scripts/mix test test/agent_systems_lab/session_test.exs test/agent_systems_lab/context_test.exs test/agent_systems_lab/persisted_context_runtime_test.exs
```

成功标准：压缩后任务事实、全部回执及权限完整；原 Session 不变；硬事实超容量时明确失败，不静默删除。

平台要求：纯构造可离线运行，持久输入和 P1 演示需 PostgreSQL；不包含长期检索或模型摘要质量评估。

<!-- course:C05 -->
## C05 历史与 checkpoint（原计划 L05）

起点：统一 `0.1.0-dev` 冻结源码；完成 C04，理解 Event schema、Codec 与 checkpoint 前缀；阅读 ch13/ch14。入口：[L06](../labs/L06-history-checkpoints.md)。

学生任务：保存完整历史和检查点；新 BEAM 比较全量/检查点重建与原状态；分别注入 seq、版本、payload 或 checkpoint 不一致。

参考解答：[L06 教师参考](../labs/solutions/L06.md)。核对零调用监测入口范围和原始报告，状态 hash 不能单独证明没有副作用。

测试命令：对应[History](../test/agent_systems_lab/history_test.exs)、[CheckpointStore](../test/agent_systems_lab/checkpoint_store_test.exs)、[结果录制](../test/agent_systems_lab/run_server_recording_test.exs)测试：

```sh
./scripts/mix test test/agent_systems_lab/history_test.exs test/agent_systems_lab/checkpoint_store_test.exs test/agent_systems_lab/run_server_recording_test.exs
```

成功标准：重建状态一致且工作区不变；被监测 Provider/Tool 入口零调用；不兼容历史明确拒绝；录制与事件配对。

平台要求：完整历史和录制路径需 PostgreSQL；新 BEAM 是同宿主进程，不代表跨机复现。

<!-- course:C06 -->
## C06 工具幂等与不确定结果（原计划 L06）

起点：统一 `0.1.0-dev` 冻结源码；完成 C05，理解 Operation/Attempt、稳定幂等 key、unknown 和绝对 deadline；读 ch15–ch17。入口：[L07](../labs/L07-recovery.md)、[L08](../labs/L08-retries-and-reconciliation.md)、[L09](../labs/L09-p2-fault-acceptance.md)。

学生任务：注入工具成功后回执提交前崩溃和恢复中再次崩溃；分类有限重试并等待 due_at；把非幂等模糊结果送入可见核对队列。

参考解答：[L07 教师参考](../labs/solutions/L07.md)、[L08 教师参考](../labs/solutions/L08.md)、[L09 教师参考](../labs/solutions/L09.md)。逐窗口核对效果数、attempt 与回执；保留无法确认的 blocked 也可构成正确结果。

测试命令：对应[claim](../test/agent_systems_lab/recovery_claim_test.exs)、[持久工具](../test/agent_systems_lab/durable_tools_test.exs)、[核对队列](../test/agent_systems_lab/reconciliation_queue_test.exs)、[重试安全](../test/agent_systems_lab/retry_runtime_safety_test.exs)测试：

```sh
./scripts/mix test test/agent_systems_lab/recovery_claim_test.exs test/agent_systems_lab/durable_tools_test.exs test/agent_systems_lab/reconciliation_queue_test.exs test/agent_systems_lab/retry_runtime_safety_test.exs
```

成功标准：幂等 Mock 效果唯一；未证实无效果不得盲重试；重启不重置预算、重试次数、deadline；unknown 核对有证据且可见。

平台要求：真实 PostgreSQL、自有工具 fixture 和进程；完整 P2 故障演示使用新输出目录，不连接生产服务。

<!-- course:C07 -->
## C07 Queue 与 Worker（原计划 L07）

起点：统一 `0.1.0-dev` 冻结源码；完成 C06，理解原子 claim、有限并发和数据库错误；读 ch18/ch19 并先了解 lease 术语。入口：[L10](../labs/L10-background-scheduling.md)、[L12](../labs/L12-backpressure-budgets-fairness.md)、[L13](../labs/L13-database-outages-p3.md)。

学生任务：并发 Worker 领取与重复投递同组 intent；测量饱和时队列/进程上界、aging 与饥饿；使用 owned loopback 代理断开并恢复 PG 连接。

参考解答：[L10 教师参考](../labs/solutions/L10.md)、[L12 教师参考](../labs/solutions/L12.md)、[L13 教师参考](../labs/solutions/L13.md)。公平性使用真实等待与服务份额，不能假定固定 20ms 内其他任务不会老化。

测试命令：对应[Scheduler](../test/agent_systems_lab/scheduler_test.exs)、[Queue](../test/agent_systems_lab/queue_store_test.exs)、[deadline](../test/agent_systems_lab/scheduler_deadline_test.exs)、[DB 故障](../test/agent_systems_lab/database_fault_demo_test.exs)测试：

```sh
./scripts/mix test test/agent_systems_lab/scheduler_test.exs test/agent_systems_lab/queue_store_test.exs test/agent_systems_lab/scheduler_deadline_test.exs test/agent_systems_lab/database_fault_demo_test.exs
```

成功标准：无重复有效 claim；到期前不领取；并发、admission、扫描有界；低优先级等待可测；断连不授权提交且恢复后可继续。

平台要求：真实 PG 与 loopback 代理权限；所有 Worker 复用同一权威数据库，P3 不是主从 failover。

<!-- course:C08 -->
## C08 Lease 与 fencing（原计划 L08）

起点：统一 `0.1.0-dev` 冻结源码；完成 C07，理解 expiry、heartbeat 与 generation；阅读 ch20。入口：[L11](../labs/L11-leases-heartbeats-fencing.md)。

学生任务：SIGSTOP 暂停真实 owned 旧 Worker；等待租约到期后由新 Worker 接管；SIGCONT 恢复后用旧 token 尝试关键提交和受控效果。

参考解答：[L11 教师参考](../labs/solutions/L11.md)。评分必须同时覆盖本地状态写入与受控效果端；lease 过期不意味着旧进程死亡。

测试命令：对应[lease/heartbeat](../test/agent_systems_lab/lease_heartbeat_test.exs)与[fencing 安全](../test/agent_systems_lab/fencing_safety_test.exs)测试：

```sh
./scripts/mix test test/agent_systems_lab/lease_heartbeat_test.exs test/agent_systems_lab/fencing_safety_test.exs
```

成功标准：旧代次无法提交迟到状态或覆盖新事实；受控效果端拒绝旧 token；重复效果为零；保留真实 PID 与时序。

平台要求：已验收 macOS arm64/Unix 信号环境、真实 PG；只暂停本实验明确拥有的进程。

<!-- course:C09 -->
## C09 Sandbox 与权限（原计划 L09）

起点：统一 `0.1.0-dev` 冻结源码；完成 C08，理解 OS PID、权限错误与进程树；阅读 ch25 和后端限制。入口：[L14](../labs/L14-isolated-execution.md)。

学生任务：固定 C 探针直接越界读写、connect 和 fork；触发 CPU、输出、文件及 wall-clock 限制；取消、超时及调用者崩溃后核对 owned 进程退出。

参考解答：[L14 教师参考](../labs/solutions/L14.md)。分别记录网关拒绝、OS 阻断、程序退出和超时清理，不将所有非零结果都计作权限通过。

测试命令：对应[策略](../test/agent_systems_lab/isolation_policy_test.exs)、[隔离](../test/agent_systems_lab/isolation_test.exs)、[持久权限](../test/agent_systems_lab/durable_isolation_test.exs)测试：

```sh
./scripts/mix test test/agent_systems_lab/isolation_policy_test.exs test/agent_systems_lab/isolation_test.exs test/agent_systems_lab/durable_isolation_test.exs
```

成功标准：已存在 canary 的越界访问返回权限拒绝；网络被阻断；资源限制可见；目标和 guardian 实际退出；后端失败关闭。

平台要求：已验收 Darwin arm64、clang、Seatbelt/sandbox-exec；Linux namespace/cgroup、总内存/磁盘强限额未验收，不可退回宿主执行。

<!-- course:C10 -->
## C10 MCP 工具适配（原计划 L10）

起点：统一 `0.1.0-dev` 冻结源码；完成 C09，理解 JSON-RPC、有限 schema 子集与 allowlist；阅读 ch11。入口：[L15](../labs/L15-mcp-stdio.md)。

学生任务：固定 MCP server 完成 stdio 握手、分页发现和调用；制造协议、ID、schema 错误与超时取消；验证授权和 unknown/reconcile 仍经过网关。

参考解答：[L15 教师参考](../labs/solutions/L15.md)。工具回执与 JSON-RPC 请求身份分别配对；取消通知不证明远端效果已撤销。

测试命令：对应[传输](../test/agent_systems_lab/mcp_transport_test.exs)、[schema](../test/agent_systems_lab/mcp_schema_test.exs)、[持久 MCP](../test/agent_systems_lab/durable_mcp_test.exs)测试：

```sh
./scripts/mix test test/agent_systems_lab/mcp_transport_test.exs test/agent_systems_lab/mcp_schema_test.exs test/agent_systems_lab/durable_mcp_test.exs
```

成功标准：发现不自动授权；错 ID 和 schema 漂移被拒；连接清理有目标与 guardian 退出证据；模糊非幂等结果保持 unknown。

平台要求：macOS arm64 原生隔离、clang、完整 PG 故障测试；固定 `2025-11-25` stateful stdio 子集，未接入 HTTP/OAuth。

<!-- course:C11 -->
## C11 DAG 与人工审批（原计划 L11）

起点：统一 `0.1.0-dev` 冻结源码；完成 C10，理解静态 DAG、预算分配和产物 hash；阅读 ch23/ch24。入口：[L16](../labs/L16-dag-workflows.md)、[L17](../labs/L17-human-approvals.md)。

学生任务：构造 fork/join 并验证失败传播、取消与恢复；对照单/双固定角色与独立 workspace；暂停、审批、改变产物、受控返工并重启核验。

参考解答：[L16 教师参考](../labs/solutions/L16.md)、[L17 教师参考](../labs/solutions/L17.md)。以 Case、subject、revision 和 artifact hash 核验批准，Reviewer 自报 passed 不替代人工决定。

测试命令：对应[图定义](../test/agent_systems_lab/workflow_definition_test.exs)、[控制流](../test/agent_systems_lab/workflow_controls_test.exs)、[审批 Case](../test/agent_systems_lab/approval_cases_test.exs)测试：

```sh
./scripts/mix test test/agent_systems_lab/workflow_definition_test.exs test/agent_systems_lab/workflow_controls_test.exs test/agent_systems_lab/approval_cases_test.exs
```

成功标准：依赖未满足不启动；汇合绑定正确前驱；分配与每 Run 预算不越界；审批持久且产物变化使旧批准失效；暂停不重置 deadline。

平台要求：真实 PG、独立私有 workspace；角色使用 Scripted Provider，人工决定由可信本地主机调用，未实现登录身份系统。

<!-- course:C12 -->
## C12 评估与回归（原计划 L12）

起点：统一 `0.1.0-dev` 冻结源码；完成 C01–C11，阅读 ch12/ch17/ch26–ch30。入口：[L18](../labs/L18-observability.md)、[L19](../labs/L19-repeatable-evaluation.md)、[L20](../labs/L20-history-migration-backup-restore.md)、[L21](../labs/L21-reader-study-and-clean-reproduction.md)、[L22](../labs/L22-release-readiness.md)。L19 是核心，其余为综合补充。

学生任务：关联观测并注入 exporter 失败；冻结 dev/holdout 完成独立 scorer 和回归比较；演练旧历史、只读还原、fence；最后核验试读包与发布材料入口。

参考解答：[L18 教师参考](../labs/solutions/L18.md)、[L19 教师参考](../labs/solutions/L19.md)、[L20 教师参考](../labs/solutions/L20.md)、[L21 教师参考](../labs/solutions/L21.md)、[L22 教师参考](../labs/solutions/L22.md)。原始性能 regressed 不可改写为 passed；源 manifest 不证明真人身份。

测试命令：对应[观测](../test/agent_systems_lab/observability_test.exs)、[评测](../test/agent_systems_lab/evaluation_test.exs)、[报告](../test/agent_systems_lab/evaluation_report_test.exs)、[迁移](../test/agent_systems_lab/history_migration_test.exs)、[备份](../test/agent_systems_lab/backup_test.exs)、[试读](../test/agent_systems_lab/reader_study_test.exs)、[发布前核验](../test/agent_systems_lab/release_readiness_test.exs)测试：

```sh
./scripts/mix test test/agent_systems_lab/observability_test.exs test/agent_systems_lab/evaluation_test.exs test/agent_systems_lab/evaluation_report_test.exs test/agent_systems_lab/history_migration_test.exs test/agent_systems_lab/backup_test.exs test/agent_systems_lab/reader_study_test.exs test/agent_systems_lab/release_readiness_test.exs
```

成功标准：所有计划样本进入分母，成功率、成本、延迟可追踪；exporter 失败不改执行且缓冲有界；迁移还原保留权限、预算和核对事实；材料检查不得改变真人 0 人待验收或 P5 false。

平台要求：完整路径需 macOS arm64、固定 Elixir/OTP/PG、clang、PG dump/restore；干净复现使用新目录、新 runtime/deps/PGDATA，并声明可信缓存来源。

课程材料的状态分别记录：30 张设计卡不代表全书完成；六章稿不代表真人试读通过；同宿主新目录复现不代表另一 OS/机器验证。[W22 验收记录](validation-week22.md)保留真实外部读者 **0 人**、P5 外部 gate **false**，本地图保持该结论。[W24 冻结验收](validation-week24.md)已有历史候选证据，正式发行仍待验收。故障处置沿用[运行手册](recovery-runbook.md)，发布前检查参照 [L22](../labs/L22-release-readiness.md)。

## C12 之后：发行与跨环境进阶

完成 C12 后，按以下顺序继续 L23–L25。它们使用同一项目的冻结、证据与评估机制，把综合实验延伸到候选交付和外部复现，不新增课程单元编号。

| 进阶实验 | 学习重点 | 前置与结果边界 |
| --- | --- | --- |
| [L23 冻结候选发行](../labs/L23-frozen-candidate-release.md) | 冻结源码与证据、候选打包、解压校验及失败记录 | 完成 C12；候选验证通过不表示正式发布已获批准 |
| [L24 版本化发行评估](../labs/L24-versioned-release-assessment.md) | 绑定政策、源码、试读协议、环境报告与问题复验，分别判断证据和批准 | 完成 L23；工具与 fixture 不能替代独立真人试读 |
| [L25 跨环境验证](../labs/L25-cross-environment-validation.md) | 执行 macOS warm/cold 与 Linux core 合同，采集原始日志并核验来源 | 完成 L24；同宿主新目录不计冷主机，Linux core 不能替代完整 Linux 隔离 |

参考解答分别见 [L23](../labs/solutions/L23.md)、[L24](../labs/solutions/L24.md)、[L25](../labs/solutions/L25.md)。实际历史结果见 [W24](validation-week24.md)、[W25](validation-week25.md)、[W26](validation-week26.md)；首次 GitHub 托管后的 Linux 核心回归见 [GitHub CI](github-ci.md)，各记录保持各自的源码身份。
