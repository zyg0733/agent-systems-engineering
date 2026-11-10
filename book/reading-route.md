---
title: 全书阅读路线与章节
description: 按七篇三十章学习 Agent 系统的状态、执行、上下文、恢复、调度、安全与验收。
---

# 全书阅读路线与章节

当前已有 **30 章正文草稿**、25 份实验手册和 12 个课程单元。正文解释机制与反例，实验负责取得证据，设计卡保留全书目标与旧发行契约；三者不能互相替代。整书仍在编辑审校阶段，正文齐备不等于正式出版、生产平台或公开托管已经完成。

第一次阅读先看[先修自测与桥接](../book/prerequisites.md)，从第 1 章开始按下表顺序读；随时查[术语表](../book/glossary.md)。不要求先跑全套实验才能开始下一章的概念阅读。代码块须按页内前置、shell/IEx 上下文与具体能力要求执行。

## 建议顺序

| 篇 | 已有正文 | 学习目标 |
| --- | --- | --- |
| 1 · 基础模型与持久化 | [1 · 从 LLM 应用到 Agent 系统](../book/ch01-from-llm-apps-to-agent-systems-engineering.md)、[2 · 状态机与系统不变量](../book/ch02-agent-state-machine.md)、[3 · 进程、Actor 与消息传递](../book/ch03-processes-actors-and-messages.md)、[4 · 事务、WAL 与故障模型](../book/ch04-transactions-wal-and-failures.md) | 从任务约定、纯状态走到进程和数据库提交 |
| 2 · Agent 执行与会话 | [5 · Agent Loop 与工具](../book/ch05-agent-loop-and-tools.md)、[6 · Streaming、取消与控制](../book/ch06-streaming-cancellation-and-control.md)、[7 · 工具调用与生命周期](../book/ch07-tool-calling-and-lifecycle.md)、[8 · Session 与状态演化](../book/ch08-session-context.md) | 理解循环、流式控制、工具执行与会话事实 |
| 3 · 上下文与工具协议 | [9 · Context 构造](../book/ch09-context-construction.md)、[10 · 压缩、记忆与检索边界](../book/ch10-compaction-and-memory.md)、[11 · 工具 Registry、MCP 与 Schema](../book/ch11-tool-registry-mcp-and-schema.md)、[12 · 状态版本与 Context Recovery](../book/ch12-state-versioning-and-context-recovery.md) | 构造有限输入，解释压缩损失与协议版本 |
| 4 · 历史、外部效果与恢复 | [13 · Checkpoint 与持久化快照](../book/ch13-checkpoints-and-persistent-snapshots.md)、[14 · 事件历史与纯重建](../book/ch14-history-checkpoints-and-replay.md)、[15 · 重试、超时与幂等](../book/ch15-retry-timeout-and-idempotency.md)、[16 · 外部效果与提交协议](../book/ch16-durable-effects-and-reconciliation.md)、[17 · 续跑、迁移与任务恢复](../book/ch17-resume-migration-and-recovery.md) | 把历史、checkpoint、重试和外部效果接成恢复协议 |
| 5 · 调度与所有权 | [18 · 队列、优先级与背压](../book/ch18-queues-priority-and-backpressure.md)、[19 · Worker Pool 与公平调度](../book/ch19-worker-pools-and-fair-scheduling.md)、[20 · Lease、Heartbeat 与所有权](../book/ch20-scheduling-and-recovery.md)、[21 · 分布式状态与复制](../book/ch21-distributed-state-and-replication.md)、[22 · 故障转移、资源与多租户](../book/ch22-failover-resources-and-multitenancy.md) | 以同一权威数据库的任务所有权解释队列与并发，再讨论未实现的复制/多租户案例 |
| 6 · 编排、安全与审批 | [23 · 规划、DAG 与工作流](../book/ch23-planning-dags-and-workflows.md)、[24 · 多 Agent、交接与审批](../book/ch24-multi-agent-handoffs-and-approvals.md)、[25 · 文件、进程与网络隔离](../book/ch25-sandbox-files-processes-and-network.md)、[26 · 身份、授权、Secrets 与审计](../book/ch26-identity-authorization-secrets-and-audit.md) | 将静态编排、审批、隔离和宿主授权接成有边界的执行路径 |
| 7 · 观测、评估与系统验收 | [27 · Trace、Span 与 Metrics](../book/ch27-traces-spans-and-metrics.md)、[28 · 数据集、Rubric 与评估](../book/ch28-evaluation-datasets-and-scorers.md)、[29 · 重建、回归与故障注入](../book/ch29-replay-regression-and-fault-injection.md)、[30 · 完整系统设计与交付](../book/ch30-complete-system-design-and-delivery.md) | 记录观测与固定评测，按证据组织回归、复现和交付 |

第 21、22 章的复制、数据库故障转移和多租户部分包含设计推演；当前项目的实跑对照仍是单 PostgreSQL、受控代理断连与静止还原副本。第 10 章的长期检索、第 27 章的 OTLP 等也逐项标记现有能力和扩展边界，不将纸面设计计为运行通过。

### 按目标选择一次阅读

- **第一次建立直觉**：第 1—8 章，从最小状态机与进程进入真实工具和取消，先完成 L01。
- **解释上下文与恢复**：第 9—17 章，先掌握 Session/Context，再逐步完成 L05—L09。
- **理解并发、安全和综合交付**：第 18—30 章，按下面实验路径补齐前置，保留反例、原始输出及未覆盖项。
- **回看原六章核心路线**：2 → 5 → 8 → 14 → 16 → 20 仍可用于复习；新读者需要时通过相邻完整正文补桥接。

概念阅读顺序与实验的运行依赖分别说明：

| 读到这里 | 实验路径 | 额外准备 |
| --- | --- | --- |
| 第 1—3 章 | [L01](../labs/L01-state-machine.md) 小练习与完整任务 | 纯值/内存，所选例子不需 PostgreSQL |
| 第 4—11 章 | [L02 事务](../labs/L02-transactions.md) → [L03 Streaming](../labs/L03-streaming-control.md) → [L04 工具](../labs/L04-controlled-tools.md) → [L05 Context](../labs/L05-session-context.md) | 自有实验 PostgreSQL；纯值首次练习可先做 |
| 第 12—17 章 | [L06 历史](../labs/L06-history-checkpoints.md) → [L07 恢复](../labs/L07-recovery.md) → [L08 核对](../labs/L08-retries-and-reconciliation.md) → [L09 故障验收](../labs/L09-p2-fault-acceptance.md) | 前一行完成；每次新 Run ID 和输出目录 |
| 第 18—22 章 | [L10 调度](../labs/L10-background-scheduling.md) → [L11 租约](../labs/L11-leases-heartbeats-fencing.md) → [L12 背压](../labs/L12-backpressure-budgets-fairness.md) → [L13 数据库故障](../labs/L13-database-outages-p3.md) | 顺序包含 C07→C08→C07，不按课程编号盲跑 |
| 第 23—26 章 | [L14 隔离](../labs/L14-isolated-execution.md)、[L15 MCP](../labs/L15-mcp-stdio.md)、[L16 编排](../labs/L16-dag-workflows.md)、[L17 审批](../labs/L17-human-approvals.md) | 各册额外平台前置；完整隔离要求当前受支持的 macOS 能力 |
| 第 27—30 章 | [L18 观测](../labs/L18-observability.md)、[L19 评测](../labs/L19-repeatable-evaluation.md)、[L20 迁移还原](../labs/L20-history-migration-backup-restore.md)、[L21 复现](../labs/L21-reader-study-and-clean-reproduction.md)、[L22 发行核查](../labs/L22-release-readiness.md) | 完成对应课程；L23—L25 按候选、版本化评估与跨环境目标再选 |

L20 是后续综合练习，不作为首次阅读 checkpoint 概念的必做任务。历史真人反馈字段继续保留旧语义，本轮代理审查不填入真人字段。

## 把阅读路线走成实验路线

每一段按“预测 → 运行 → 查原始证据 → 换一个条件解释 → 查参考解答”推进。演示跑通与独立完成手册中的改写、反例和测试任务分别记录；不要只凭一个 `all_passed` 就认定全部练习已完成。建议留下下面四段检查记录：

| 段落 | 至少留下的证据 | 换条件后的自测 | 参考入口 |
| --- | --- | --- | --- |
| L01—L05：状态、执行与上下文 | 错 ID 不推进；半截流取消不产生工具提议；修复前后验收与当前输出目录的 Context 核验 | 手动输入一个 tool result 能证明文件真的写了吗？摘要能新增权限吗？ | [L01](../labs/solutions/L01.md)、[L02](../labs/solutions/L02.md)、[L03](../labs/solutions/L03.md)、[L04](../labs/solutions/L04.md)、[L05](../labs/solutions/L05.md) |
| L06—L09：事实历史与效果恢复 | 非空 tail 重建、调用计数、结果未知及回执边界；P2 的每类原始故障证据 | 只有 State hash 相等够不够？直接取消 unknown 后队列空能说明效果已核清吗？ | [L06](../labs/solutions/L06.md)、[L07](../labs/solutions/L07.md)、[L08](../labs/solutions/L08.md)、[L09](../labs/solutions/L09.md) |
| L10—L12：领取、续期与背压 | 原 due、有限并发、同 seq 下的旧 token 拒绝、队列/任务预算 | successor 已推进 seq 的拒绝，能单独证明 token fencing 吗？lease 续期会延长任务 deadline 吗？ | [L10](../labs/solutions/L10.md)、[L11](../labs/solutions/L11.md)、[L12](../labs/solutions/L12.md) |
| L13：数据库故障与综合核对 | COMMIT 前后独立读取、断连后的原身份、组件和新 BEAM 只读审计 | caller 报错是否等于回滚？恢复连接是否允许重发未知效果？ | [L13](../labs/solutions/L13.md) |

### 先确认执行上下文

- `sh` 块在项目根目录的终端执行；`elixir` 块按手册进入指定 IEx。普通表达式后的预期注释不是断言，需实际比较；`true = ...`、元组匹配等才会在不符合时直接失败。另开 IEx 会丢失上一次的变量与进程，只有已提交数据库事实和文件仍可读取。
- L01 和纯值小练习关闭数据库。L02 起先准备自己的实验 PostgreSQL，再显式设 `LAB_DATABASE_ENABLED=true`、`LAB_SCHEDULER_ENABLED=false`；不要继承上一终端的后台调度配置。手动启动的教学 Scheduler 仍须使用手册限定的 `run_ids` 或 queue。
- 完整 `check` 使用专用实验实例的默认测试库名。若曾设置 `DATABASE_URL`，先通过 `PGHOST/PGPORT/PGUSER/PGPASSWORD` 选定实例，再在同一终端 `unset DATABASE_URL`；单次 `env -u` 不会修改父终端。各册完整回归命令也显式移除 URL，避免恢复测试的动态 Repo 被全局 URL 覆盖。单个实验仍可用 URL 指定库，但之后运行完整回归要重新确认此环境。
- 每次 runner 使用全新的 `--output` 目录，IEx 中读取产物也指向该次目录。只有明确核对旧版本时才读历史产物；`output_exists` 是保护旧证据，不能靠删旧目录掩盖新一轮失败。
- 演示自带的受控故障窗口与手册的独立挑战分别记录。L09 的一轮 smoke 不能代替每窗 20 轮的正式 P2；L11 的信号与 L13 的本地代理只作用于 runner 自己创建的资源，不能对照进程列表随意暂停或终止别的实验。

每段做完先解释表中的反例，再查解答。若解答与输出不一致，保留命令、实际返回、源码身份和该次目录，按下面的卡点记录方式复查；不要为得到“成功”而更换 operation、清空 retry 或放宽断言。

## 读正文，做实验，查设计卡

**正文**解释问题、反例与实现选择。**实验手册**给出准备、任务、命令和验收证据。**章节设计卡**记录七篇、三十章的目标、维护方向及能力边界。三种材料各有用途，30 章正文均仍是草稿。

若按完整课程推进，使用[十二单元课程地图](../docs/course-map.md)。实际实验顺序为：

1. 完成 C01—C06，建立状态、事务、工具、历史与恢复基础。
2. 先做 C07 的 L10，再做 C08 的 L11，然后回到 C07 完成 L12/L13。
3. 进入 C09—C12 的隔离、MCP、编排、审批、评估与综合验收。

L23—L25 补充冻结候选、版本化发行评估与跨环境验证。需要核对整体技术证据时，可查[结果索引](../docs/results-index.md)与[证据阅读说明](../docs/evidence-guide.md)。

## 把卡点变成可复验的问题

读完一章，试着用自己的话解释表格中的问题，再用对应实验给出证据。记录卡点时包含章节和小节、实际命令、期望与结果，保留原始输出。

本书作为开源教程草稿持续修订，由多个 subagent 模拟不同阅读起点，审查路线、概念、练习和界面，不安排真人试读。模拟评审可以发现问题，但不能给出真人理解率、满意度或实际学习耗时。[历史六章试读协议](../book/reader-study/README.md)保留其原有发行证据契约，模拟记录不填入真人反馈字段。

::: tip 阅读位置
本站仅在此浏览器保存最近阅读的正文章节，便于从首页或本页继续阅读。记录不会发送到服务器，可随时清除；浏览器禁止本地存储时，阅读仍可正常使用。
:::
