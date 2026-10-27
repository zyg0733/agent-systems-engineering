# 命令与实现参考

本页保留原 README 的详细命令、实现说明与逐阶段阅读入口。所有命令均在项目根目录执行；新克隆环境先按 [首页](../README.md)安装。当前接口合同以[公开接口与扩展契约](public-interfaces.md)为准，实际结果以各周验收记录为准。

《Agent Systems Engineering》的 Elixir/OTP 配套实验项目。已完成第 1—21 周：状态机、Provider 与工具、事务存储、Streaming、取消与预算、受控文件与补丁、Session/Context、历史与模型录制、持久恢复、有限重试和核对队列、后台多 Worker 调度、lease/heartbeat/fencing、背压与公平性、数据库断连恢复、P3 验收、隔离执行器、MCP stdio、持久化 DAG、绑定产物的人工审批与受控返工、统一观测、固定任务评测与基线回归，以及旧历史迁移、版本兼容与备份还原。配套 L01—L25 实验、阶段验收证据、Oban 源码对照与全书 30 章正文草稿；原六章试读稿属于此前冻结记录。第 22 周技术交付与干净环境复现已落地，第 23 周整理发布准备入口、版本契约、12 个课程单元与 30 张章节卡；第 24 周冻结矩阵与候选交付见实际验收记录；第 25 周增加版本化发行评估、显式冻结试读与追加反馈闭环；第 26 周补齐跨环境执行与有界证据采集；历史真人统计、冷主机、完整 Linux 与正式发布准入保留各自证据口径；当前教材修订采用 subagent 模拟与实际检查，不以真人招募为前置。

固定输入、脚本、配置与工作区基线可重现实验轨迹。工具效果与模型提议分开；回执丢失会阻塞执行，必须查询核对才能继续。

## 开始运行

验证环境为 Elixir **1.20.4**、Erlang/OTP **28.4**、PostgreSQL **18.6**。依赖已通过 `mix.lock` 锁定，包含 Ecto SQL 与 Postgrex。无需模型密钥。语言要求为 Elixir 1.18 及以上的兼容 1.x 版本；其他组合尚未验证。

以下快捷命令适用于已安装项目专用运行时、依赖和数据库的工作副本；新克隆目录不包含这些本机安装与数据。先确认 `PGHOST/PGPORT/PGUSER/PGPASSWORD` 指向自己的可丢弃实验实例；不设置时使用下方项目默认值，再清除父终端的 `DATABASE_URL`：

```sh
unset DATABASE_URL MIX_ENV
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
./scripts/postgres status
env -u DATABASE_URL MIX_ENV=test LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/mix check
./scripts/mix lab.verify_db
./scripts/mix lab.demo
./scripts/mix lab.demo --lost-response
./scripts/mix lab.stream
./scripts/mix lab.stream --cancel
./scripts/mix lab.stream --budget
./scripts/mix lab.repair
./scripts/mix lab.p1
./scripts/mix lab.history
./scripts/mix lab.recover
./scripts/mix lab.retry
./scripts/mix lab.reconcile
./scripts/mix lab.p2
./scripts/mix lab.schedule
./scripts/mix lab.fence
./scripts/mix lab.load
./scripts/mix lab.database
./scripts/mix lab.p3
./scripts/mix lab.isolate
./scripts/mix lab.mcp
./scripts/mix lab.workflow
./scripts/mix lab.approval
./scripts/mix lab.observe
./scripts/mix lab.trace RUN_ID --json
./scripts/mix lab.eval
./scripts/mix lab.eval.verify
./scripts/mix lab.upgrade
```

在新的 macOS 环境中运行：

```sh
unset DATABASE_URL MIX_ENV
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
sh scripts/bootstrap_runtime.sh
./scripts/mix local.hex --force
./scripts/mix deps.get
sh scripts/bootstrap_postgres.sh
./scripts/postgres start
./scripts/mix setup
env -u DATABASE_URL MIX_ENV=test LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/mix check
```

脚本按 [Elixir 官方安装方式](https://elixir-lang.org/install/) 下载固定版本，并从 PostgreSQL 官方源码构建项目专用实例；文件与数据都位于 `.runtime/`，不修改 shell 配置。构建 PostgreSQL 需要 C 编译器、make、Bison、Flex 和 Perl，完整系统前置见 [README](../README.md#快速开始)。Linux 需另备固定版本工具链；CI 配置已加入 PostgreSQL 服务。

### 完整回归的环境准备

默认连接为 `127.0.0.1:55432`，用户 `postgres`，开发库 `agent_systems_lab_dev`，测试库 `agent_systems_lab_test`。项目实例仅监听回环地址，使用开发环境的本机 trust 认证；它不是生产数据库配置。启动脚本启用 fsync、同步提交与 full_page_writes。

单个实验可以用 `DATABASE_URL` 指定自己的实验库；完整 `check` 则先通过 `PGHOST/PGPORT/PGUSER/PGPASSWORD` 选择专用、可丢弃实例，保留默认测试库名 `agent_systems_lab_test`，再在同一终端执行以下准备。当前恢复测试会创建、迁移并删除自己管理的临时数据库，全局 URL 会覆盖动态 Repo 的目标，因此不能将原实验 URL 原样带入完整回归。不要指向生产库、共享库或归属不明的实例。

```sh
unset DATABASE_URL MIX_ENV
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
./scripts/mix setup
env -u DATABASE_URL MIX_ENV=test LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/mix check
LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/mix test
```

`unset` 修改当前终端，后续 IEx 和实验命令继承它；`env -u DATABASE_URL` 只清除这一次子进程的 URL，不能代替父终端准备。另开终端时先重新确认同一专用实例并重复 `unset` 与两条 `export`。单命令的内存模式前缀不会改变父终端，下一条完整回归仍显式启用数据库并关闭全局 Scheduler。应用级调度演示只在对应实验中显式启用，不能带进完整回归。

普通演示最终输出：

```text
status=succeeded turns=2 requests=1 effects=1
rebuild_matches=true (in-memory history; no durable storage)
```

丢回执演示会先到达 `blocked`，查询 Mock 台账、记录 `tool_reconciled` 后继续。请求数和业务效果数仍各为 1。

## 命令

| 命令 | 用途 |
| --- | --- |
| `./scripts/mix setup` | 创建并迁移当前环境数据库 |
| `./scripts/mix check` | 格式、编译、测试库迁移、完整测试、10 条场景和数据库崩溃验收 |
| `./scripts/mix test` | 单元、OTP 和真实 PostgreSQL 集成测试；测试库须先迁移 |
| `./scripts/mix lab.verify_db` | 创建/更新各两个提交边界的真实进程 kill 与独立连接检查 |
| `./scripts/iex` | 使用项目运行时、Hex 和 Mix 缓存启动交互环境 |
| `./scripts/mix lab.verify` | 执行 fixture，核对终态、效果数和事件重建 |
| `./scripts/mix lab.demo` | 普通工具调用的完整事件轨迹 |
| `./scripts/mix lab.demo --lost-response` | 效果成功但回执丢失后的核对轨迹 |
| `./scripts/mix lab.stream` | 分片工具参数 → 提交意图 → 工具效果 → 流式文本 |
| `./scripts/mix lab.stream --cancel` | 参数未完整时取消，停止 Provider，效果数为 0 |
| `./scripts/mix lab.stream --budget` | 字节超限进入 failed，效果数为 0 |
| `./scripts/mix lab.repair [--output PATH]` | 离线修复配送费边界样例，保存 diff、前后验收日志与事件 |
| `./scripts/mix lab.p1 [--output PATH]` | 持久 Session、压缩输入与 manifest、流式修复、取消和四个提交边界 kill 验收 |
| `LAB_DATABASE_ENABLED=false ./scripts/mix lab.p1 --memory [--output PATH]` | 不使用数据库的 P1 演示，明确跳过数据库验收 |
| `./scripts/mix lab.history [--output PATH]` | 实际写入一次文件、保存 checkpoint 与模型结果，再在独立 BEAM 中验证状态相同且模型/工具调用为零 |
| `./scripts/mix lab.rebuild RUN_ID [--checkpoint]` | 只读重建持久 Run；可选择验证 checkpoint 前缀与 tail |
| `./scripts/mix lab.recover [--output PATH] [--repetitions N]` | 5 个故障点各重复 4 次、恢复中再次崩溃、新 VM 续跑、丢回执查询和文件未知结果核对 |
| `./scripts/mix lab.retry [--output PATH]` | 有限重试与实际退避、调度后崩溃/新 VM、次数耗尽、工具效果 0→0→1 与超时核对 |
| `./scripts/mix lab.reconcile [--run RUN_ID] [--limit N] [--json]` | 只读展示已提交 unknown 核对队列，不查询目标或执行工具 |
| `./scripts/mix lab.p2 [--output PATH] [--repetitions N]` | P2：16 个故障窗口默认各 20 次真实 kill，验证二次崩溃、回执、fencing、预算与新 BEAM 重建 |
| `./scripts/mix lab.schedule [--output PATH] [--runs N]` | 两个后台调度器、有限 Worker、真实续租与重复投递、到期重试、新 BEAM 应用自动启动 |
| `./scripts/mix lab.fence [--output PATH] [--repetitions N]` | 5 个窗口默认各 5 轮真实 SIGSTOP/SIGCONT，同 seq 接管后旧执行器实际迟到写入被拒 |
| `./scripts/mix lab.load [--output PATH] [--jobs N]` | 饱和投递、双池共享配额、进程采样、aging 与饥饿检测、任务预算及超时回收 |
| `./scripts/mix lab.database [--output PATH] [--repetitions N]` | 独立连接的真实断连、COMMIT ACK 丢失、失租、未知效果与同一 Scheduler 自动重连 |
| `./scripts/mix lab.p3 [--output PATH] [--repetitions N]` | 重跑 W11—W14 四组件，核对全部阶段门槛，并在独立 BEAM 中审计历史和零执行 |
| `./scripts/mix lab.isolate [--output PATH]` | 真实 syscall 验证文件/网络拒绝、fork/spawn 阻断、资源限制、取消及调用方崩溃后的 OS 进程清理 |
| `./scripts/mix lab.mcp [--output PATH] [--memory]` | MCP 握手/发现/调用、错误与取消、进程退出和未知结果不重放；memory 明确只验证 stdio 部分 |
| `./scripts/mix lab.workflow [--output PATH]` | 真实 PostgreSQL DAG 依赖、并行汇合、同预算 Reviewer 对照、失败/取消与提交及控制器崩溃恢复 |
| `./scripts/mix lab.approval [--output PATH]` | 人工请求、哈希失效、基线冲突、暂停恢复、有限返工、审批/返工 COMMIT 前后 kill 与只读审计 |
| `./scripts/mix lab.observe [--output PATH]` | 八项观测演练：Run 关联、核对、审批返工、导出故障等价、有界缓冲、观察器缺失、COMMIT kill 与零执行查询 |
| `./scripts/mix lab.trace RUN_ID [--json] [--scope run\|related] [--limit N] [--max-related-runs N]` | 有界只读查询模型、工具、意图、恢复、预算及审批返工关系；不执行或续跑 |
| `./scripts/mix lab.eval [--output DIR] [--split dev\|holdout] [--profile reference\|regressed] [--repetitions N] [--baseline REPORT]` | 新 Run 执行固定分割，独立评分产物，从持久账本统计成功率、合成成本和实测延迟 |
| `./scripts/mix lab.eval.compare BASELINE CANDIDATE [--output DIR]` | 只读保存报告，重算验证后比较总体及逐任务回归；不启动应用或执行任务 |
| `./scripts/mix lab.eval.verify [--output DIR]` | 六组开发/保留集基线、重复与主动退步，验证可重复语义、完整分母和零执行比较 |

已安装全局 Elixir 时可以使用全局 `mix`，但仍须遵循上述实例选择与环境准备；例如完整回归使用 `env -u DATABASE_URL MIX_ENV=test LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false mix check`。

只研究内存模式且不启动数据库时，用 `LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/mix test` 排除数据库测试；同样的单命令前缀可用于内存演示和 Streaming 演示。完整 `check`、L02 与 L03 的数据库实验需要 PostgreSQL。

## 代码与阅读顺序

1. [L01 实验手册](../labs/L01-state-machine.md)：独立练习、故障注入与验收标准。
2. [架构说明](../docs/architecture.md)：状态图、命令与事件、组件边界。
3. [Kernel](../lib/agent_systems_lab/kernel.ex)：纯状态转换与严格事件重建。
4. [Scripted Provider](../lib/agent_systems_lab/providers/scripted.ex)：显式脚本游标与请求上下文。
5. [Mock Tool](../lib/agent_systems_lab/tools/mock.ex)：操作台账、幂等、故障与效果计数。
6. [RunServer](../lib/agent_systems_lab/run_server.ex)：逐步驱动模型和工具，遇到 unknown 暂停。
7. [ADR 0001](../docs/adr/0001-pure-kernel-and-explicit-effects.md)：架构选择与当前保证。
8. [L02 实验手册](../labs/L02-transactions.md)、[Storage](../lib/agent_systems_lab/storage.ex) 与 [ADR 0002](../docs/adr/0002-transactional-storage.md)：Run、Event 与调度意图的事务边界。
9. [第 3 周验收记录](../docs/validation-week03.md)：数据库、崩溃和独立 VM 验证结果。
10. [L03 Streaming 实验](../labs/L03-streaming-control.md)、[解答](../labs/solutions/L03.md) 与 [ADR 0003](../docs/adr/0003-streaming-cancellation-and-budgets.md)：实时帧、取消、预算、持久提交的边界。
11. [Stream](../lib/agent_systems_lab/stream.ex)、[Budget](../lib/agent_systems_lab/budget.ex) 与 [第 4 周验收记录](../docs/validation-week04.md)：组装协议、资源限制与验证证据。
12. [L04 受控工具实验](../labs/L04-controlled-tools.md)、[解答](../labs/solutions/L04.md) 与 [ADR 0004](../docs/adr/0004-controlled-tools-and-call-pairing.md)：schema、调用 ID、配对、文件边界与离线修复。
13. [工具目录](../lib/agent_systems_lab/tools/catalog.ex)、[Gateway](../lib/agent_systems_lab/tools/gateway.ex)、[Files](../lib/agent_systems_lab/tools/files.ex) 与 [第 5 周验收记录](../docs/validation-week05.md)：契约、实现与实际验证。
14. [L05 Session 与 Context 实验](../labs/L05-session-context.md)、[解答](../labs/solutions/L05.md) 与 [ADR 0005](../docs/adr/0005-session-context-and-manifests.md)：原文、受保护输入、摘要、来源与重建。
15. [Session](../lib/agent_systems_lab/session.ex)、[Context](../lib/agent_systems_lab/context.ex)、[ContextStore](../lib/agent_systems_lab/context_store.ex) 与 [第 6 周验收记录](../docs/validation-week06.md)：输入构造及 P1 证据。
16. [L06 历史重建实验](../labs/L06-history-checkpoints.md)、[解答](../labs/solutions/L06.md) 与 [ADR 0006](../docs/adr/0006-history-checkpoints-and-recorded-results.md)：严格版本、可信前缀、提交边界与已接受结果。
17. [History](../lib/agent_systems_lab/history.ex)、[CheckpointStore](../lib/agent_systems_lab/checkpoint_store.ex)、[ModelResultStore](../lib/agent_systems_lab/model_result_store.ex) 与 [第 7 周验收记录](../docs/validation-week07.md)：独立进程状态重建和零执行证据。
18. [L07 崩溃恢复实验](../labs/L07-recovery.md)、[解答](../labs/solutions/L07.md) 与 [ADR 0007](../docs/adr/0007-recovery-and-operation-attempts.md)：逻辑操作、执行尝试、领取凭证、回执与安全续跑。
19. [Recovery](../lib/agent_systems_lab/recovery.ex)、[RecoveryStore](../lib/agent_systems_lab/recovery_store.ex)、[IntentStore](../lib/agent_systems_lab/intent_store.ex)、[DurableTools](../lib/agent_systems_lab/durable_tools.ex) 与 [第 8 周验收记录](../docs/validation-week08.md)：持久策略、故障窗口与实际恢复证据。
20. [L08 有限重试与核对实验](../labs/L08-retries-and-reconciliation.md)、[解答](../labs/solutions/L08.md) 与 [ADR 0008](../docs/adr/0008-bounded-retries-and-reconciliation.md)：错误分类、持久退避、超时效果语义与核对队列。
21. [ErrorPolicy](../lib/agent_systems_lab/error_policy.ex)、[RetryStore](../lib/agent_systems_lab/retry_store.ex)、[ReconciliationQueue](../lib/agent_systems_lab/reconciliation_queue.ex) 与 [第 9 周验收记录](../docs/validation-week09.md)：有限尝试、期限、可见 unknown 及实际证据。
22. [L09 P2 验收实验](../labs/L09-p2-fault-acceptance.md)、[解答](../labs/solutions/L09.md) 与 [ADR 0009](../docs/adr/0009-p2-fault-acceptance.md)：冻结恢复契约，反复验证关键故障窗口。
23. [P2Verification](../lib/agent_systems_lab/p2_verification.ex)、[P2 故障报告](../docs/p2-fault-report.md)、[恢复运行手册](../docs/recovery-runbook.md) 与 [第 10 周验收记录](../docs/validation-week10.md)：原始证据、缺陷修复与同一 Run 的恢复操作。
24. [L10 后台调度实验](../labs/L10-background-scheduling.md)、[解答](../labs/solutions/L10.md)、[ADR 0010](../docs/adr/0010-background-scheduling.md) 与 [第 11 周验收记录](../docs/validation-week11.md)：原子 claim-next、持久优先级、有限 Worker、租约续期与真实到期重试。
25. [L11 Lease 与 fencing 实验](../labs/L11-leases-heartbeats-fencing.md)、[解答](../labs/solutions/L11.md)、[ADR 0011](../docs/adr/0011-leases-heartbeats-fencing.md) 与 [第 12 周验收记录](../docs/validation-week12.md)：操作系统暂停、同 seq fencing、续租写入边界及旧 Worker 恢复后的迟到结果。

## 固定评测与基线比较

第 20 周新增冻结的 6 个开发任务和 4 个保留任务、固定产物 oracle、独立 OS BEAM 评分与版本化报告。每个 task/trial 使用新 Run 和工作区，通过原 Recovery、受控文件工具与预算执行；最终自称成功不影响评分。开发集与保留集显式分开，输入、oracle、scorer、定价、执行合同与运行时身份不一致时拒绝比较。

报告保留全部计划样本，包括错误产物、超时、预算失败和评分器故障。成本来自已扣模型尝试、输出字节与工具 execution attempt，单位是固定 synthetic lab units，USD 为 null；使用量缺失或源事实漂移不会填成零。延迟记录执行、独立评分及总耗时的微秒样本、p50/p95。总体与逐任务均有回归门槛，保存比较后以非零退出提示回归；不完整批次不能成为基线。

默认 reference 和故意退步的 regressed 都是宿主固定 Scripted 响应。这些公开教学数据用于验证评测机制，保留集不是秘密盲测，也不证明真实模型能力。相同配置重复应保持语义签名与成本，真实延迟允许波动；文件 hash 不是认证。见 [L19](../labs/L19-repeatable-evaluation.md)、[参考解答](../labs/solutions/L19.md)、[ADR 0019](../docs/adr/0019-repeatable-evaluation-and-regression.md)、[运行手册第 18 节](../docs/recovery-runbook.md#18-可重复评测与回归比较) 和 [W20 验收](../docs/validation-week20.md)。

## Trace、Metrics 与按 Run ID 诊断

第 19 周新增内部 schema v1 的结构化观测、确定性 Trace/Span ID、固定标签的 Metrics 与本地 JSONL exporter。模型和工具的开始/结束关联同一次尝试；Run 之间的 DAG、Workflow、审批 Case 与返工关系用 links 表达。默认 Null exporter，宿主显式配置后才写 JSONL；本周没有增加 SDK 依赖或 OTLP 网络导出。

`Observability.emit/4` 不做 IO、数据库查询或同步进程调用，始终返回 `:ok`。固定槽位与字节准入、合并 wake、单个超时导出 Worker、独立 recent 上限共同限制积压；导出错误、异常、退出和挂起只造成可见的观测丢失。默认观察器是 temporary child，消失后由宿主显式 `Observability.restart()` 恢复，不重启业务 sibling。producer 在预留与插入之间被 kill 可造成有限容量损失，宿主重启观察器可清除，不能据此声称自动无损恢复。

`Observability.Query.run(run_id)` 从原数据库事实构建有界只读诊断，即使实时通知丢失也可读取。默认沿存储归属关联返工各轮；`scope: :run` 只选原 Run。输出不含 prompt、模型正文、工具参数/结果、路径、人工身份/理由或 claim token；业务 ID 本身仍须由宿主保证不含秘密。实时事件可能重复或丢失，Metrics 统计已排出的观察次数，不能代替唯一业务事件计数、预算或授权。历史行时间不是真实模型耗时。

两个命令要求 PostgreSQL，且在启动应用前拒绝启用全局 Scheduler。`lab.observe` 只创建自己的私有队列和演练数据，拒绝覆盖旧目录；`lab.trace` 不启动模型、工具或恢复。见 [L18](../labs/L18-observability.md)、[参考解答](../labs/solutions/L18.md)、[ADR 0018](../docs/adr/0018-observability-and-diagnostic-evidence.md)、[运行手册第 17 节](../docs/recovery-runbook.md#17-trace-metrics-与按-run-id-诊断) 和 [W19 验收](../docs/validation-week19.md)。

## 人工审批、暂停与受控返工

第 18 周新增 `Approvals`。宿主在开始前固定一至三轮 Workflow、各轮独立工作区与产物选择、protected baseline、审批者 allowlist 和所有轮次的五维预算预留。`decide` 只接受操作者身份、原因、请求 ID、原 seq 和 subject hash，不能提供脚本、权限或新预算。`approve/rework/reject` 与原子轮次登记留在持久事件历史中，重复请求不会重复创建返工。

审批 subject 绑定 Case/Plan、当前轮、generation、成功任务证据及产物的完整字节哈希。观察到产物改变即撤销当前批准、递增 generation；改回旧字节也需重新审批。protected baseline 改动会形成可见冲突，不能强行放行。`release` 每次重新验证当前产物（包括重复请求），返回获批的不可变字节及基线版本；它不发布、不应用补丁，也不授予工具权限。只读 `load/rebuild` 展示持久化事实，不能代替当前文件的授权检查。

`Workflows.pause/resume` 可持久化暂停独立图；审批所属图必须经 `Approvals.pause/resume`。暂停在原锁顺序中撤销已领取 token，快速恢复也不能让旧 Worker 提交。Run 身份、回执与支出保留，原绝对 deadline 继续计时；不确定效果仍由原核对队列处理。返工只选择下一预声明轮次，旧轮证据不重写、已用预算不退款。身份由可信宿主认证后传入，本项目没有新增登录服务，模型 Reviewer 的 `approved` 输出不构成人工批准。

运行 `lab.approval` 需要真实 PostgreSQL、关闭全局 Scheduler 和全新输出目录；演练使用合成的宿主操作者请求，不代替真实发布审批。见 [L17](../labs/L17-human-approvals.md)、[参考解答](../labs/solutions/L17.md)、[ADR 0017](../docs/adr/0017-human-approvals-and-rework.md)、[运行手册第 16 节](../docs/recovery-runbook.md#16-人工审批暂停与受控返工)、[W18 验收](../docs/validation-week18.md) 和 [P4 总结](../docs/p4-report.md)。

## DAG 编排与子任务

第 17 周新增 `Workflows`：可信宿主定义静态 DAG，最多八节点、最大反链宽度三，`max_parallel` 为一至三。定义、事件链、节点投影、工作流私有队列与就绪子 Run 在同一事务内保存；依赖全部成功才创建下游。Coordinator 使用一个有界数据库 helper 观察持久事实，原 Scheduler、claim、lease 和 fencing 负责执行与提交，多个 Coordinator 共用队列并发上限。

每节点使用自己的 Session、预算、工作区、隔离与 MCP 策略。依赖携带原任务、完整输出和工具回执、来源 Run/seq/hash，不能继承权限或覆盖宿主配置。五维分配总量不得超过父 cap，重试和崩溃不退款，下游沿用原绝对 deadline；汇合超过 1 MiB 显式失败。失败或取消关闭父门禁并收敛子任务，unknown 仍在原人工核对队列中可见。`load/rebuild` 只读，`sync` 推进持久依赖，`stop` 暂停当前 Coordinator，`cancel` 持久化终止父图。

`lab.workflow` 在 PostgreSQL 上运行九项演练：同图单/双 Worker、同预算单 Run 与实施者加 Reviewer、失败、取消、模糊效果、控制器强杀、下游准入 COMMIT 前后强杀和绝对 deadline。Reviewer 使用预设结构化意见；对照证明调度、证据和预算机制，不能推导模型质量优势。已有输出目录拒绝覆盖，失败保留报告；需要数据库且全局 Scheduler 关闭。见 [L16](../labs/L16-dag-workflows.md)、[参考解答](../labs/solutions/L16.md)、[ADR 0016](../docs/adr/0016-static-dag-workflows.md)、[W17 验收](../docs/validation-week17.md) 和[运行手册第 15 节](../docs/recovery-runbook.md#15-dag-编排与子任务恢复)。动态 DAG、Planner、自动返工和发布审批留待后续阶段。

## MCP stdio 与恢复

第 16 周固定实现 **MCP 2025-11-25 stdio 子集**。2026-07-28 已改变握手与能力传递，本实现不静默升级或混用两个版本。`initialize`、`notifications/initialized`、分页 `tools/list` 与 `tools/call` 使用 UTF-8 换行 JSON-RPC；独立处理 stderr、服务端 ping、工具清单变更、请求时限和 advisory 取消。每连接至多一个在途请求；超时、取消和协议错误后的连接不会承接新调用，迟到回报不能配到其它请求。

宿主用 `MCP.Policy.new/1` 固定服务器命令/参数、W15 isolation policy、批准工具、精确 input schema 与宿主描述。模型看到 `mcp.<server>.<remote>`；远端 description、instructions、annotations 与额外发现工具均不能授予权限。Gateway 和底层 Connection 都会校验白名单与参数；schema 漂移在 tools/call 前拒绝。Schema 支持有界 closed object、array、string、number/integer、boolean、null 和 enum，未知关键字、引用、正则与组合器直接拒绝。

stdio 服务器仍在默认断网、单目标且禁止 fork 的 Seatbelt 中执行；独立 native bridge 为 stdin/stdout/stderr 与可信控制帧分流，不退回普通宿主进程。每次 `MCP.execute/4` 创建并关闭自己的连接；显式 Connection 可复用其仍有效的发现快照。`isError=true` 映射为配对的 `mcp_tool_error`，JSON-RPC error 映射为 `mcp_rpc_error`；调用发出后超时/断连/错误 ID/非法响应映射为 unknown。

持久 Run 将 `mcp_policy` 存为独立、带 hash 的不可变 sidecar；原 config v1、文件与隔离工具兼容。prepared 先提交，进程在 SQL 锁外运行，回执再次 fencing。MCP 工具一律按非幂等处理，未知结果进入 manual queue，不采信 idempotentHint 自动重投；已确认回执重复投递只复用。重建审计现覆盖 27 个模型/工具/执行入口。

`lab.mcp` 使用仓库控制的固定 C server 与私有 canary，20 个窗口包含协议正常/错误、权限、取消与调用方崩溃、迟到结果，以及两项真实 PostgreSQL 恢复演练。无数据库时显式使用 `LAB_DATABASE_ENABLED=false ./scripts/mix lab.mcp --memory --output artifacts/mcp-memory`，报告为 stdio_only、18 项、recovery_verified=false。默认目录已存在会拒绝覆盖；生成物不代替源码。见 [L15](../labs/L15-mcp-stdio.md)、[ADR 0015](../docs/adr/0015-mcp-stdio.md)、[W16 验收](../docs/validation-week16.md)和[运行手册第 14 节](../docs/recovery-runbook.md#14-mcp-stdio-连接与核对)。

本周没有增加 Hex 依赖，没有接入 HTTP/OAuth、2026 协议、完整 JSON Schema、resources/prompts、sampling/roots/elicitation 或 Tasks。当前隔离后端及 Linux/硬内存/总磁盘限制延续 W15；固定 C fixture 是实验探针，尚未进行任意第三方 MCP server 的互操作验收。

## 隔离执行与策略

第 15 周增加 opt-in `sandbox_exec`。宿主用 `Isolation.Policy.new/1` 登记私人 workspace、绝对可执行文件白名单、`network: :deny` 和有限资源；模型只传 `command` 与 `args`，不能授予权限、传环境或替换 profile。未登记策略的旧 Run 不公开该工具。文件工具与隔离工具分别授权；两者同时启用时应明确指定同一私人工作目录。

当前为本机 macOS Seatbelt 教学后端。可信 C guardian 在 exec 前建立独立 session、关闭继承 FD、清空环境、应用最小 profile 和硬 rlimit；目标禁止 fork/posix_spawn，至多一个目标进程。内核限制 CPU、单文件大小和 64 个 FD；guardian 限制输出与墙钟时间，取消或 owner 死亡后 kill 自有 group 并 reap。控制帧与目标 stdout 使用不同管道，工作区不能改写 profile 或编译缓存。新命令不经 shell 解释。

持久 Run 的 policy 作为不可变、带 hash 的 sidecar 保存。prepared 先提交，启动前短事务复验资格与期限，外部程序运行时不占用 Run 锁；结束后再 fencing 提交配对回执。每次运行取 policy、Run、任务、retry 和本次观测 lease 的最早期限。进程结果未确认时进入 unknown/manual，禁止自动重跑。取消可阻止迟到回执覆盖状态，已经产生的文件效果仍需核对。

`lab.isolate` 的 18 项真实探针覆盖正常文件、越界读写、符号/硬链接、有效 loopback 服务上的网络拒绝、fork/spawn/setsid、CPU、文件大小、FD、输出、超时、取消、调用方崩溃及未登记命令。首次执行自动用系统 clang 编译仓库内固定 guardian；不新增 Hex 依赖。已有输出目录拒绝覆盖。运行示例见 [L14](../labs/L14-isolated-execution.md)，结果见 [第 15 周验收记录](../docs/validation-week15.md)，处置见[运行手册第 13 节](../docs/recovery-runbook.md#13-隔离执行与清理)。

自定义 Seatbelt 接口已被 Apple 弃用，不作为生产或多租户安全承诺。Linux 后端、任意后代、硬内存与总磁盘配额、允许网络白名单尚未实现；请求未支持能力会被拒绝，后端失败不退回宿主执行。Ubuntu CI 明确排除标记为 `:seatbelt` 的平台测试，纯策略与后端拒绝测试仍执行；本周完整验收在 macOS 实际运行。详见 [ADR 0014](../docs/adr/0014-isolated-execution.md)。

## 数据库断连、源码对照与 P3

第 14 周把领取和续租交给数量受限的异步数据库 helper，避免 SQL 等待拖住控制进程。每个 Scheduler 最多一个在途领取，每个 Worker 最多一个续租或清理 helper。`Scheduler.status(pid)` 增加 database 状态、连续失败、剩余退避和 pending_claim；默认 `database_timeout_ms: 1000`、`database_backoff_ms: 100`、`max_database_backoff_ms: 5000`。重复 wake 不绕过退避，连接恢复后原实例自动重新扫描。

数据库异常与业务 retry 分开处理。领取 COMMIT 未确认时不启动 executor；续租未确认时先停并等待本次执行，不猜测旧 expiry 或主动释放未知资格。模型帧扣账、工具回执中的数据库异常保留原事实，不能冒充模型失败或确定未发生的工具失败。已合法扣除的预算不退还，未知工具结果继续按原 operation 核对。

`lab.database` 启动自己的子 BEAM 和 loopback pgwire 代理，只断开它拥有的连接。五个窗口包括提交前断连、实际 COMMIT 成功回报丢失、heartbeat 断连、工具效果后断连、同一 Scheduler 自动重连。共享 PostgreSQL 不停止；代理收到服务器 CommandComplete 后才切断 COMMIT 回报，父进程用独立连接核对提交事实。默认每点 2 次，范围 1—10，原始证据保存在 `artifacts/week14-database/`；已有目录拒绝覆盖。

`lab.p3` 在新目录实际重跑 scheduling、fencing、load、database 四个组件，保留逐组件门槛、原始报告、失败位置和全部 Run 身份。默认 2 次仅作用于信号/数据库故障窗口；scheduling/load 各运行一次、12 个任务。随后用一个独立 BEAM 重建全部本轮历史，逐 Run 比较原 State，并检查所有执行入口零调用。W16 增补 Gateway 与 MCP 的新入口后现为 27 个；W15/W14 已保存报告分别按当时 23/20 个计数保留。父进程再次核对投影、工具效果和模型录制未改变。`all_passed` 和 `outcomes.all_runs_succeeded` 分开，预算耗尽与 manual blocked 均须保持真实状态。

[S6 源码研究](../docs/research/oban-scheduling-recovery.md) 固定 Oban 2.24.2 提交，下载并校验 19 个文件，追踪 fetch/rescue/ack、事务退避和 Unique 的责任边界。没有安装 Oban 或运行上游测试；[ADR 0013](../docs/adr/0013-queue-engine-selection-and-database-recovery.md) 决定本期保留教学队列，未来 adapter 必须只有一个调度权威并通过相同故障契约。还新增 [第 20 章初稿](../book/ch20-scheduling-and-recovery.md)，与已验证机制对应，尚待试读与技术审校。

复现步骤与恢复操作见 [L13](../labs/L13-database-outages-p3.md)、[参考解答](../labs/solutions/L13.md)、[运行手册第 12 节](../docs/recovery-runbook.md#12-数据库断连与恢复)、[P3 阶段报告](../docs/p3-report.md) 和 [第 14 周验收记录](../docs/validation-week14.md)。结论限于受控客户端连接故障与单 PostgreSQL，不扩展成节点复制切换、跨区高可用或任意远端 exactly-once。

## 背压、任务预算与公平性

第 13 周增加显式命名队列。`QueueStore.create("lab", capacity: 100, max_inflight: 4)` 固定准入与共享领取配额；`Recovery.create_run(id, input, queue: "lab")` 在同一事务中核对名额并写入 Run、Events、intent、恢复策略与任务预算。满载返回 `{:error, :queue_full}`，不留下半成品；终态释放准入名额，blocked/manual 核对仍占名额。`Scheduler.start_link(queue: "lab", max_workers: 4)` 消费该队列，多个实例和显式 `IntentStore.claim` 共用数据库配额。已有无队列 Run 保留旧入口；未配置 `queue` 的 Scheduler 只扫描无队列 Run。

每个排队任务默认 `task_budget: [max_dispatches: 32, execution_timeout_ms: 5_000]`，可在创建时设置。每个新 claim token 在任何 hook、模型或工具执行前持久预留一次，Worker 崩溃与重试都不退还计数。模型次数、输出字节、工具次数与原 Run 总 deadline 继续有效；这些是本地执行预算，不代表 token 或费用估算。`TaskBudgetStore.load(id)` 可审查不可变策略和累计预留。

Worker watchdog 取任务执行上限、Scheduler 的 `execution_timeout_ms`（默认 30 秒）与 Run 剩余时间中的较小值。到期先停止并等待 executor，再在有效 claim 下归档：无工具记录则失败，已确认回执复用，prepared/unknown 则进入可见核对队列。持久任务 deadline 也在模型启动、帧扣账、结果接受及工具效果入口检查，直接调用 `Recovery.step` 同样受约束。人工核对可处理已耗尽预算的原操作，不能借此重发未知效果。

命名队列每次最多验证 `scan_limit` 个候选（默认 32，上限 256），持久 cursor 和 cycle ceiling 让未来 retry 或坏记录前缀不能永久挡住后续工作。页内按 `min(9, priority + floor(intent_age_ms / aging_ms))` 排序，同级旧 intent 优先；默认 aging 为 1 秒，饥饿告警阈值为 10 秒。`QueueStore.stats/starvation` 排除有效 lease、未来 retry 和 blocked，并展示当前可执行候选的 intent age；它不是连续 ready 时间或全库最优排序。`wake` 用进程注册的原子 gate 合并通知，避免调用方制造无界通知积压。

`lab.load` 默认向容量 12 的队列并发投递 24 次，采样两个 pool 的 Worker、executor、provider 与监视进程，验证低优先级 aging、告警解除、预算耗尽、慢模型杀停和模糊工具结果。报告与完整台账保存在 `artifacts/week13-load/`，目录存在时拒绝覆盖。共享配额限制有效 lease；已失租但尚在退出的旧 Worker 仍受各实例槽位和 fencing 约束。准入名额不限制已完成历史的存储量，采样也不代表整个 BEAM 的进程上限或生产公平 SLO。

参见 [L12 实验](../labs/L12-backpressure-budgets-fairness.md)、[参考解答](../labs/solutions/L12.md)、[ADR 0012](../docs/adr/0012-backpressure-and-fairness.md) 与 [第 13 周验收记录](../docs/validation-week13.md)。

## Lease、Heartbeat 与旧 Worker 恢复

第 12 周使用 `lab.fence` 启动它拥有的独立 BEAM，核验 PID 握手后真实发送 SIGSTOP，并用 `ps` 确认停止态。PostgreSQL 与父接管者保持运行；等待原 lease 自然到期，新 owner 在同 intent/seq 上取得新 token/generation，再以 SIGCONT 恢复旧 BEAM。5 个窗口分别覆盖模型接受前、工具效果前、效果后、receipt 后和 successor 已提交后的旧结果。

实验使用明确的控制 gate，让恢复后的旧 executor 先尝试真实迟到写入，再让过期 heartbeat 停止它。这样分别验证数据库拒绝与本地清理，避免只看到执行器被杀就误判 fencing 已通过。旧模型、帧扣账、工具效果/回执、renew/release 均需返回陈旧资格错误；接管快照在旧调用前后严格相等。generation 在每个 intent 内递增；完整资格还绑定 intent ID、seq、owner 和随机 token，不能把单个 generation 数字当作全局远端 fencing 契约。

续租 UPDATE 在实际写入时检查原 expiry，并以数据库时钟计算新期限。即使调用通过了前置校验后暂停，也不能在过期后以原 token 续命。Worker 的续期 timer 使用每轮 reference，忽略重复和陈旧 tick，避免计时器重放增加续租循环。`Scheduler.status(pid).active` 新增 `heartbeat` 和 `heartbeat_age_ms`，可观察序号、ACK、往返时长和返回的 expiry；它们是当前 BEAM 的非持久诊断，数据库仍决定资格。

默认产物位于 `artifacts/week12-fencing/`，保留完整暂停/接管/旧调用前后快照、真实旧 executor 返回、子进程日志、PID/停止态与清理证据。目录存在时拒绝覆盖；`--repetitions` 范围为 1—20。实验要求应用级全库 Scheduler 关闭，子进程只启用自己的 scoped 实例。

普通完成、异常和超时均会清理自己的子进程；暂停中抛异常的测试验证了 CONT、终止及实际退出。父进程被 OS 强杀时没有独立 watchdog，不能承诺自动收尾。当前结论针对本地受控模型/工具与 PostgreSQL，任意远端效果仍需目标自己的幂等、查询或 fencing 协议；lease 过期不能证明效果撤销。操作流程见[恢复运行手册](../docs/recovery-runbook.md)。

## 后台调度与多 Worker

后台模式默认关闭。`Scheduler.start_link(run_ids: [id1, id2], max_workers: 2)` 创建按指定 Run 范围运行的后台调度器；省略 `run_ids` 且不配置 `queue` 时扫描无队列且已登记 Recovery 的可执行 Run。`Scheduler.status(pid)` 展示在途 Worker/执行器、领取凭证和续期次数，`wake(pid)` 只加快下一次扫描，不是任务事实来源。周期扫描确保没有通知也能发现下一意图、过期 lease 和到期 retry。

`IntentStore.claim_next/2` 先以 `FOR UPDATE SKIP LOCKED` 领取 Run 行锁，再验证当前意图、恢复配置及原 retry journal，COMMIT 后才把凭证交给 Worker。`Recovery.execute_claim/2` 只执行这个凭证对应的一步，每次写入仍重新验证 claim/seq。未登记恢复配置的旧 Run、终态、blocked/reconcile、有效 lease 和尚未到期的 retry 都不会自动执行。

新 Run 可以设置 `Recovery.create_run(id, input, script: [...], priority: 7)`，优先级 0—9，默认 0，高值优先；同级按 intent ID 排序。这是非抢占策略，不改已有领取。此处描述旧无队列模式：没有全局 FIFO、跨实例总并发上限或饥饿保证；每个 Scheduler 的 `max_workers` 限制其在途 Worker，不预先领取一批任务放进内存等待。

每个 Worker 有独立执行器和续租定时器。长模型调用不阻塞续租；续期保留 token/generation，期限以数据库时间为准。失去资格或正常停止时，先停止并等待执行器退出；资格明确时才尝试释放自己的 live claim，数据库结果未知则保留 lease 等待核对或到期；异常死亡通过进程链接停止执行器，数据库 lease 自然到期后允许重复投递。复用原 operation/回执或保留 unknown 的安全规则继续有效，lease 本身不提供外部效果唯一性。

第 12 个迁移增加 `lab_intents.available_at` 和 `lab_runs.priority`。retry 的 due 与意图时间投影在同一事务写入；旧 NULL 和错误投影均以完整权威 journal 复核，不提前领取、不花费新次数。当前教学扫描逐候选验证历史，`available_at` 用于诊断而非唯一资格依据；不承诺大队列扫描性能。调度器不持有 lease 睡眠等 retry 到期。

`lab.schedule` 默认只运行它创建的新 Run，生成 `artifacts/week11-scheduling/` 中的报告、完整台账和独立应用进程日志，并留下一个 manual unknown 供只读队列演练。目录存在时拒绝覆盖，重做使用新的 `--output`。

需要在 Application 监督树启用时，先迁移，再在实验库运行 `LAB_SCHEDULER_ENABLED=true ./scripts/iex`；配置见 `config/config.exs` 的 `scheduler_options`。默认配置扫描所连接实验库的无队列可恢复 Run；消费命名队列需在配置中显式填写 `queue`。手工启动的调度器用 `Scheduler.stop(pid)` 停止；监督树中的永久子进程会被重启，暂停需 `Supervisor.terminate_child(AgentSystemsLab.Supervisor, AgentSystemsLab.Scheduler)`，恢复用 `Supervisor.restart_child/2`。详细操作见[恢复运行手册](../docs/recovery-runbook.md)。

## P2 故障窗口验收

第 10 周通过 `lab.p2` 创建独立演练 Run，以观察到的确定 hook 为屏障真实终止调用进程，等待 PostgreSQL 时钟上的原 lease 到期，再接管原意图。默认 16 个窗口各重复 20 次，包含工具效果成功后、回执提交后、Run 事务提交前后、恢复中再次崩溃，以及重试和核对的提交边界。旧 token 的写入必须被拒绝；已接受的模型 cursor、原 deadline 和输出扣账必须保留。

核对回执与 Kernel 接受核对是两个提交边界。回执已提交而 Run 仍 blocked 时，`Recovery.reconcile(id)` 先在当前 claim 下验证并读取本地已确认回执，直接提交原事实，不再次查询目标、不占用新查询次数。该路径同样适用于文件和 unqueryable 工具；没有本地确认事实时仍遵循原查询能力、有限额度与可信人工证据要求。

默认产物在 `artifacts/week10-p2/`，包括总报告、逐场景故障前后快照、operation/attempt/receipt/retry/recording 台账和两个新 BEAM 的续跑及零执行重建日志。目录存在时拒绝覆盖；重新验收使用新的 `--output`。`lab.p2` 创建新的演练数据；恢复已有 Run 请按[运行手册](../docs/recovery-runbook.md)使用原 ID 调用 `Recovery.resume/reconcile`。

## 有限重试、退避与核对队列

第 9 周在创建 Recovery Run 时显式传 `retry_policy: []` 启用重试；默认 `nil` 保留第 8 周的一次失败处理。策略、离线尝试脚本与故障计划作为不可变 sidecar 随创建事务保存，原 v1 配置和旧数据格式保持不变。`ErrorPolicy` 区分 transient、permanent、timeout、conflict、cancelled 和 unknown；未识别错误保守视为 permanent，分类本身不能授权重发可能发生效果的操作。

| 重试策略 | 默认值 | 含义 |
| --- | ---: | --- |
| `max_attempts` | 3 | 当前意图/阶段的总尝试上限，包含首次和崩溃前预留 |
| `base_delay_ms` | 100 | 第一次重试延迟 |
| `max_delay_ms` | 5,000 | 指数退避延迟上限；本实验不加入随机 jitter |
| `max_elapsed_ms` | 30,000 | 从该阶段首次预留起的总窗口 |
| `tool_timeout_ms` | 1,000 | 当前工具投递或显式核对查询的等待上限 |

`RetryStore` 在效果前持久预留尝试，并保存完整失败分类、投递身份、下次可执行时间和耗尽原因。到期时间由 PostgreSQL 时钟决定；重启、重复调用或领取不能重置它。指数延迟为 `min(max_delay_ms, base_delay_ms * 2^(attempts - 1))`，同时受次数、阶段窗口和原 Run deadline 约束。模型仍受跨 Run 的 `max_model_attempts` 与输出预算限制。

`Recovery.resume` 遇到尚未到期的重试，返回包含 `snapshot.recovery.retry` 的暂停快照；它不持有 lease 等待，不循环睡眠。提前 `step` 返回 `{:retry_not_due, due_ms}` 错误而不消费新尝试。调用者到期后显式续跑。`model_attempt_scripts: %{0 => [{:error, :unavailable}, {:final, "done"}]}` 和 `mock_transient_failures: 2` 是固定离线故障计划，需启用策略，不能在 resume 时更改。

只有幂等 Mock 由适配器确认的 transient/no-effect 结果允许再次投递。工具超时会先停止并等待 worker 退出，再核对本地已确认回执；有回执就复用，否则保存 unknown 和 observation attempt。非幂等工具的模糊结果不会自动重发。`ReconciliationQueue.list/get` 从 blocked Run、unknown 事实和 reconcile 意图构建可见队列，与业务状态同一提交即可生效，不存在第二次 enqueue 丢失的窗口。

队列标明原 Run/调用、原因、等待时间、最近尝试和 queryable/manual 能力。列表只读，不调用 Provider、工具或目标查询。`Recovery.reconcile` 对可查询目标使用独立的有限查询窗口；查明后接受原回执，查不明仍 blocked。执行 Run 过期后仍可核对已有效果，但不授权后续执行。可信人工结果和 evidence 是独立核对事实，不因自动查询额度耗尽而被禁止。

`lab.retry` 输出到 `artifacts/week09-retries/`，保留新 BEAM 日志、完整 retry/operation/attempt 台账、次数耗尽和效果计数报告，并留下一个实际 blocked 的非幂等 unknown Run 供 `lab.reconcile` 查看。目录已存在时拒绝覆盖；重复实验使用新的 `--output`。

## 崩溃恢复与安全续跑

新建可恢复运行使用 `Recovery.create_run(id, input, script: [...])`。它将 Run/Event/意图与恢复配置一次提交，固定脚本、Session 快照、工作区、Context 策略和预算。`Recovery.load(id)` 只读；`Recovery.step(id)` 执行一步；`Recovery.resume(id)` 执行到终态、未知结果暂停或步数上限。恢复时不传新的脚本或工作区。原有 RunServer API 保持原实验语义，未预先登记恢复配置的旧 Run 明确返回 `run_not_resumable`。

每一步使用 `IntentStore.claim` 原子领取当前意图，取得 owner、随机 token、递增 generation 和数据库时钟期限；确认转换时再次校验。续租、释放和结果提交都不能使用过期或被接管的凭证。取消/失败可撤销领取。这里是逐步恢复所需的最小领取协议，尚无后台扫描、多 Worker 池、优先级或公平性；重试启用后的到期资格由 RetryStore 另行约束。

模型游标仅在完整响应、录制、Run/Event/下一意图同事务提交时推进。接受前崩溃可重试未确认请求，接受后崩溃直接继续下一意图。每次尝试先持久预留，流式帧在 ACK 前持久扣除输出字节；重启不归零。默认最多 8 次模型尝试，原字节/帧/工具/turn 限制继续生效，绝对 Run 期限也不重置。模型恢复只支持 inert Scripted 配置；PID/ref 测试 gate 通过宿主故障 hook 注入，不写入配置。

`DurableTools` 将一个 `(run_id, operation_id)` 的不可变输入与每次 delivery attempt、领取凭证、配对回执和人工证据分开保存。持久 Mock 的目标台账在 Runtime 接受结果之前独立提交，相同操作和参数复用原回执，修改参数明确冲突。`mock_response: :lost` 产生可见 `blocked`，`Recovery.reconcile(id)` 查询真实回执后记录核对事实，再用 `resume` 继续。

文件效果无法与数据库事务一起回滚。若执行标记已经提交却没有确认回执，恢复会保守地记为 unknown，匹配当前文件内容也不会被当作执行成功的证明。`mock_mode: :unqueryable` 使用同样的保守边界。自动核对无法证明结果时返回 `reconciliation_required`；可信操作者可显式传 `result` 与非空 `evidence`，保存人工核对记录。这些入口不能执行补偿操作或扩大工作区。持久 Mock 的受控测试结果不等于任意外部服务的 exactly-once 保证。

`lab.recover` 默认输出 `artifacts/week08-recovery/`，包括逐次故障报告、新 BEAM 续跑日志和文件样例。目录存在时拒绝覆盖。旧的 `lab.rebuild` 和 History 始终只读，零执行审计已扩展到新的 Recovery/DurableTools 入口。

## 历史、checkpoint 与模型录制

`History.rebuild/3` 按原始顺序验证 Event，拒绝缺口、重复、错 Run、非法转换和未知 `schema_version`。`Checkpoint.new/3` 保存合法前缀的 State、序号、`max_turns` 与前缀/State hash；`History.from_checkpoint/2` 在可信 checkpoint 上应用 tail。重建只应用已经提交的事实，`waiting_tool` 或 `blocked` 不会触发工具或自动核对。

`CheckpointStore.create/3` 在 Run 锁与 expected sequence 下提交不可覆盖的 checkpoint。存储读取先校验完整权威历史、投影与意图，再验证 checkpoint 原始前缀和 tail，结果须与全量重建相等。本阶段不承诺 checkpoint 减少冷启动成本。没有 checkpoint 时明确走全量路径；最新 checkpoint 损坏则报错。Event、checkpoint、录制封装、模型响应及 Codec 分别严格校验版本，没有自动迁移或不安全解码回退。

正常 Runtime 接受的完整模型响应会出现在 `snapshot.recordings`。PostgreSQL 模式将录制与 Run/Event/调度意图放进同一事务，绑定先前提交的 Context、精确输入、完整响应、对应事件序号和 hash；`ModelResultStore.load/list` 重新核对这些绑定。半截流、取消、Provider 错误、预算拒绝和陈旧响应都不会成为可复用录制；输入 capture 可以没有结果。手工 `command({:model_response, ...})` 仍是显式导入事实，不冒充模型调用。

内存 Mock 延续允许任意参数 map 的旧契约。若其中含 PID、reference、function 等无法安全持久化的临时值，合法转换仍可接受，`snapshot.recording_errors` 明确记录该事件无法生成惰性录制；不会把它伪装成可复用结果。PostgreSQL 和可复用 Recording 的 Codec 限制保持严格。

`Providers.Recorded` 由宿主显式构造，精确匹配下一条录制的输入，不匹配时不推进游标。历史重建不会调用它。显式返回保存的工具提议之后，宿主若另行调度，仍可能执行工具。录制、checkpoint 与 hash 都不恢复运行时预算、Provider 游标或文件台账，也不提供自动续跑或外部效果恰好一次保证。

`lab.history` 默认生成 `artifacts/week07-history/`，包含 `report.json`、`fresh-vm.log`、`events.bin` 和实际文件。它在工具效果前创建 seq 2 checkpoint，完成唯一一次写入后启动新 BEAM，比较 seq 4 的完整状态，并计数模型、工具及 RunServer 启动入口。目录存在时拒绝覆盖；重复演示请指定新的 `--output`。

## Session、Context 与 P1

Session 保留完整的宿主对话原文，并在创建时固定 `facts`、`acceptance`、`constraints`。`Session.append/3` 返回新版本，允许 `user`、`assistant`、`note` 消息；不允许冒充 `system` 或 `tool`。工具事实继续来自 Run 的 `operations`，不重复写成对话。应用应把必须保留的任务事实和验收条件放在这些固定字段或 Run input 中；实现不自动从任意叙述中提取事实。

内存 Run 可传 `session: session`。持久 Session 先调用 `SessionStore.create/1`，再用 `storage: :postgres, session_id: id` 创建 Run；追加使用行锁和预期版本。`RunServer.append_message/3` 在无模型请求且非终态时追加，持久模式先提交再更新快照。Session 版本过期会拒绝输入捕获，不会静默替换成另一个版本。

每次模型请求通过 Context 构建器生成输入，保留旧的 `input`、`operations` 和 `available_tools` 等字段，并加入任务、宿主权限、消息与摘要。权限来自真实工具配置，消息和摘要不能扩大工作区或授予 shell/network。任务事实、验收条件、约束及全部操作和回执精确保留；只裁剪可丢弃的对话叙述。受保护部分超限会在调用模型前进入明确失败终态。

`context_options` 的默认策略为：

| 选项 | 默认值 | 含义 |
| --- | ---: | --- |
| `max_context_bytes` | 262,144 | Provider payload 的确定性 ETF 字节上限，非 token/费用 |
| `keep_recent_messages` | 4 | 需要压缩时优先保留的近期消息数上限 |
| `max_summary_bytes` | 2,048 | 完整摘要封装的 ETF 字节上限 |

完整输入能放下时不压缩；超限时裁剪旧消息并生成 UTF-8 安全的确定性提取摘要。摘要明确标为不可信派生叙述，附原消息 ID 与 hash，不调用模型、不替代硬约束。放不下摘要时也明确记录省略；完整 Session 不会被覆盖。

`snapshot.context` 包含实际 payload 与独立 manifest，`snapshot.context_id` 指向持久捕获记录。manifest 不传给 Provider、不计入 payload 上限，记录输入/保护部分/Session/策略的 hash、来源消息的保留或省略及摘要来源。PostgreSQL 模式在启动模型任务前提交完整来源、payload 和 manifest，`ContextStore.load/1` 重新构造并核对；这提供自一致性验证。模型结果另由录制事务绑定到该输入；hash 不是数字签名，也不提供自动续跑。

实际 P1 演示输出位于 `artifacts/week06-p1/`：40 条 Session 原文保持不变，4 次模型输入全部完成裁剪与摘要，并保留任务、完整回执和权限；流式修复使固定验收从 3/4 提升为 4/4；取消路径没有文件写入。目录包含总报告、每轮 manifest 和可验证输入 bundle、Session 原文、repair diff 与前后测试日志。目录存在时拒绝覆盖，重做请指定新的 `--output`。

## 受控文件工具与离线修复

创建 Run 时显式传入 `workspace: absolute_private_directory`，才会向模型公开 `file_read`、`file_write`、`file_patch`。参数使用字符串键，拒绝缺失或额外字段；完整模型响应和直接提交的模型命令都经过校验。未知工具名延续旧实验的受控错误行为，不获得执行能力。

| 工具 | 必需参数 | 行为 |
| --- | --- | --- |
| `file_read` | `path` | 读取文本，返回内容、字节数和 SHA256 |
| `file_write` | `path`、`content`、`expected_sha256` | 匹配原 hash 后整体替换；`"absent"` 只用于创建 |
| `file_patch` | `path`、`expected_sha256`、`edits` | 依次唯一匹配 `old`/`new`，全预检成功后一次替换 |

路径必须位于指定目录内，拒绝绝对路径、dot/dotdot、符号链接、硬链接、控制字符和保留元数据目录；保留名按 Unicode casefold 比较，避免大小写与字符别名绕过。父目录须已存在；文件上限 64 KiB，内容必须是无 NUL 的 UTF-8 文本；一次 patch 最多 32 项。写入使用同目录临时文件、同步和原子重命名。该边界适用于没有恶意并发写者的私人实验目录，不能代替操作系统沙箱。

`operation_id` 在本阶段同时标识 Provider 调用与单次逻辑操作。新工具结果携带 `tool_result.v1` 封装，核对 ID、工具名与待处理调用；结果进入下一轮模型 context。存活 Files 实例对同 ID 同输入去重，改输入报冲突；这不是跨重启的操作台账。`snapshot.file_stats` 单独统计文件请求、成功读取与写入，原 `tool_stats` 保持 Mock 口径。

运行 `LAB_DATABASE_ENABLED=false ./scripts/mix lab.repair` 可在无需数据库或模型密钥的条件下完成：读取源码 → 修补 `> 100` 为 `>= 100` → 新建修复说明 → 最终回答。固定验收驱动在独立 BEAM 中执行原始测试，修复前 3/4 通过、修复后 4/4 通过。它只运行核对过源码与测试字节的固定 fixture，不向模型开放任意命令执行。

默认输出到 `artifacts/week05-repair/`，包含 `repair.diff`、`before-test.log`、`after-test.log`、`report.json`、可重建的 `events.bin` 和修改后的 `workspace/`。目录已存在时拒绝覆盖；重做请指定新的 `--output artifacts/another-repair`。diff 可应用到原始 fixture，生成物不纳入源码版本控制。

## Streaming 与控制

`RunServer.start_stream/1` 立即返回请求 reference；先调用 `subscribe/1` 的进程会收到有序的 `{:agent_stream, run_id, request_ref, seq, event}`。原有 `step/1` 等待一轮完整响应，等待期间 RunServer 仍能处理快照和 `cancel/2`。每个 Run 同时只允许一个模型请求，重复启动返回 `{:error, :busy}`。

Scripted Provider 支持 `text_delta`、`tool_start`、`arguments_delta` 与 `:done`；工具参数只在完整 JSON 对象通过校验后接受。旧完整响应脚本继续可用。模型请求在 Task.Supervisor 下执行，每帧等待 RunServer 确认；取消或超时会停止该任务，并忽略迟到消息。快照只保留最近 128 条实时通知，实时帧不写业务 Event 表。`:done` 后还须 Provider 成功返回，才提交完整响应。

| `start_run/1` 选项 | 默认值 | 口径 |
| --- | ---: | --- |
| `max_turns` | 4 | 持久化的完整模型决策数 |
| `max_output_bytes` | 65,536 | 当前进程内累计输出字节，含工具 ID、名称及参数 |
| `max_stream_events` | 4,096 | 单次模型请求的帧数，包含完成帧 |
| `max_tool_calls` | 16 | Run 中已接受的操作总数 |
| `model_timeout_ms` | 5,000 | 单次模型请求的单调时钟期限 |
| `run_timeout_ms` | 60,000 | RunServer 初始化完成后的总期限，含手动等待 |

预算耗尽会提交 `run_failed`，原因记录在 `state.terminal_reason`。字节不是 token 或费用；旧工具响应的参数按 ETF 字节计量，流式参数按原始 JSON 字节计量。原 RunServer 除 `max_turns` 和操作历史外，策略、计数与时钟期限没有持久化，不能用重启重置预算后自动续跑；Recovery 路径另行持久化策略、消耗与绝对期限。原进程实验的精确规则见 L03，跨崩溃规则见 L07。

## OTP 与实验边界

Application 监督树依次包含可选 Repo、Registry、Provider Task.Supervisor 和 Run DynamicSupervisor，采用 rest_for_one。每个 RunServer 拥有独立 Mock 进程。Registry 子树有序停止会停止依赖它的运行进程；RunServer 是 temporary child，不会在崩溃后自动重跑业务。强制终止监督树可能使整个应用停止，具体边界见架构说明。

RunServer 默认保持 L01 内存模式。传入 `storage: :postgres` 后，每次被接受的状态转换会先提交 Run 投影、Event 与调度意图，再发布快照。`Storage.load/1` 在全新 BEAM 中读取并重放核对；并发写入使用行锁和 expected_seq，陈旧调用不能覆盖新事实。

原有 RunServer 的 Provider 游标、Mock 台账与 Files 去重台账仍在内存中，持久读取不会自动续跑工具。Recovery 路径单独登记持久配置、领取凭证、操作台账与回执；后台 Scheduler 默认关闭，宿主可显式启用。原 RunServer 不自动恢复业务。本地事务不保证任意外部效果恰好发生一次；尚未接入真实模型。Mock 参数中的路径只是数据；显式启用的文件与隔离工具会实际改变所授权的工作区。

Streaming 使用 Provider 通用协议和离线逐帧实现，尚未接入厂商 HTTP/SSE。模型与隔离工具任务支持运行中取消；Mock 与文件工具仍同步执行。执行前读取与外部效果之间仍有并发窗口；Recovery 在 Run 锁内复验领取和期限，短文件操作在临界区完成，隔离程序在提交授权事务之后执行。prepared 防止模糊操作自动重复；效果发生后、回执事务提交前仍可能崩溃，取消不会撤销已有外部效果。远端工具仍需要自己的幂等或 fencing 契约。

提交前崩溃会回滚整次转换；提交后、函数返回前崩溃仍保留完整事实。后者需要查询稳定 Run ID 和序号来确认，不能盲目换 ID 重发。详见 L02。

## 旧历史迁移与备份还原

第 21 周新增独立历史存储格式 v1→v2，业务 Event schema 与 Codec 仍为 1。显式迁移在 Run 锁中保留原字节和完整状态，记录可校验的迁移前缀；未知版本、混合布局、损坏历史、过时 seq 与活跃 claim 均明确拒绝。新增第 21 个 SQL migration，既有 Run 默认继续使用 v1。

`./scripts/mix lab.upgrade` 在四个全新受管数据库中生成真实旧 20 版表结构，完成迁移与三份原生备份的还原矩阵。目标先保持只读，验证所有行、schema、序列、Event/checkpoint 和 sidecar 绑定，再撤销复制 lease、推进 fencing generation，最后显式续跑。原权限、已扣预算、deadline、unknown 核对和审批产物约束继续生效。

本实验的备份仅含数据库，原工作区保留在原授权根；不提供 roles/WAL/文件归档或生产 PITR。见 [L20](../labs/L20-history-migration-backup-restore.md)、[解答](../labs/solutions/L20.md)、[ADR 0020](../docs/adr/0020-history-migration-backup-restore.md)、[运行手册第 19 节](../docs/recovery-runbook.md#19-历史迁移版本兼容与备份还原) 与 [W21 验收](../docs/validation-week21.md)。

## 六章试读与干净环境复现

W22 按原计划聚焦修订与复现，不扩展业务运行时。六章 ch02/ch05/ch08/ch14/ch16/ch20 与现行实验逐项对齐，修复编号、预算/恢复边界和环境步骤卡点。`lab.reading` 生成冻结、自含的源码与试读包，严格绑定反馈版本，并将技术验收和真实外部读者分开。

```sh
./scripts/mix lab.reading prepare --output artifacts/reading-unique
./scripts/mix lab.reading report artifacts/reading-unique
./scripts/mix lab.reproduce export --output /absolute/fresh-parent/project
./scripts/mix lab.reproduce verify --output /absolute/fresh-parent/project
./scripts/mix lab.reproduce cache --output /absolute/fresh-parent/project
./scripts/mix lab.reproduce plan --output /absolute/fresh-parent/project --port 55439
```

后四个命令只准备与验证，不执行plan。干净复现使用同宿主上声明的安装缓存、新runtime prefix、新依赖编译和独立PostgreSQL集群，不复用旧deps/build/业务数据。用户确认先完成技术工作，当前外部真人数0、P5外部gate保持false；模板与代理不计数。见[六章指南](../book/reader-study/README.md)、[L21](../labs/L21-reader-study-and-clean-reproduction.md)、[解答](../labs/solutions/L21.md)、[修订记录](../docs/reader-study-revisions.md)、[运行手册](../docs/recovery-runbook.md#20-六章试读与干净环境复现)、[W22验收](../docs/validation-week22.md)。

## 发布准备与课程入口

第 23 周将原计划的十二个实验组织为 [C01—C12 课程单元](../docs/course-map.md)，明确对应已经交付的 L01—L22；原实验编号和入口保持可用。[三十张章节设计卡](../book/chapter-cards.md)分别提供目标、前置、源码、实验、问题与教师参考，不把设计卡计为完成全书。

```sh
./scripts/mix lab.release check
./scripts/mix lab.release plan
```

这两个入口只读取有界源码元数据并输出 JSON，不启动应用、连接数据库或执行计划。版本契约固定当前 `0.1.0-dev`、OTP/Elixir/PostgreSQL、依赖锁、21 个 SQL migration 和独立历史版本域。`check` 通过仅表示发布准备材料自洽；不代表真人试读、Linux CI、完整冻结故障矩阵或 `0.1.0` 已发布。

操作入口见 [公开接口与扩展契约](../docs/public-interfaces.md)、[发布操作手册](../docs/release-operations.md)、[已知限制](../docs/known-limitations.md)、[L22](../labs/L22-release-readiness.md)、[参考解答](../labs/solutions/L22.md)、[运行手册第 21 节](../docs/recovery-runbook.md#21-发布准备版本契约与课程入口)及 [W23 验收](../docs/validation-week23.md)。

## 冻结矩阵与 v0.1 候选教学包

第 24 周以固定源码运行验收、保存结果及打包，不扩展 Agent 业务机制。教学材料保留 C01—C12、30 张章节设计卡、六章试读稿及连续 L01—L23；发布收尾见 [L23](../labs/L23-frozen-candidate-release.md)、[参考解答](../labs/solutions/L23.md)、[候选说明](../docs/candidate-release.md)、[结果索引](../docs/results-index.md)、[后续 backlog](../docs/backlog.md)与 [W24 实际验收](../docs/validation-week24.md)。

候选包用 `v0.1.0-rc.1` 清单标签绑定源码和证据。W24 候选创建时没有 Git 仓库，该清单标签不是 Git tag；`mix.exs` 仍为 `0.1.0-dev`。技术验收和完整性核对通过不替代外部试读、Linux CI 或正式发布准入。包中运行时、数据库和模型能力的范围以已知限制及实际报告为准。

## 版本化发行评估与试读闭环

第 25 周新增 `lab.reading.frozen` 与 `lab.release.assess`。试读准备显式选择已验证的冻结源码；原始反馈独占保存，修复与原读者复验追加成链，报告只读重算。发行评估绑定候选、源码、试读协议、固定政策和外部材料，材料缺失继续 pending，不创建 tag 或发布。

原 W22 试读包、`v0.1.0-rc.1` 候选与原门槛保持不变。当前仍需 3—5 名独立真人、至少一次新工作区主实验、冷主机与完整 Linux 隔离/冻结验收；模板、代理和合成 fixture 不计外部证据。详见 [L24](../labs/L24-versioned-release-assessment.md)、[参考判断](../labs/solutions/L24.md)、[发行评估操作](../docs/release-assessment.md)、[ADR 0024](../docs/adr/0024-versioned-release-assessment.md)和[运行手册第 23 节](../docs/recovery-runbook.md#23-版本化发行评估与追加式试读闭环)。

## 跨环境执行与证据采集

第 26 周新增 Python 固定计划执行器 `scripts/environment_validate.py` 与纯文件 `lab.environment plan/collect/verify`。显式选择冻结源码，分别记录 `macos-warm`、真实新主机 `macos-cold` 和 `linux-core`；执行使用独立源码副本与自有 PostgreSQL，采集只校验有界文件和来源，不执行报告中的命令。

本机 warm-cache 不算冷主机；Linux 适用回归的 Seatbelt 排除不算完整 Linux 隔离通过。真实新主机、Linux runner 和读者证据未取得时继续 pending，原候选与发布门槛保持。具体命令、来源记录及精确清理见 [L25](../labs/L25-cross-environment-validation.md)、[参考判断](../labs/solutions/L25.md)、[跨环境操作](../docs/cross-environment-validation.md)、[ADR 0025](../docs/adr/0025-cross-environment-validation.md)、[运行手册第 24 节](../docs/recovery-runbook.md#24-跨环境执行证据与独占资源清理)与 [W26 验收](../docs/validation-week26.md)。
