---
title: 六章阅读路线
description: 按状态、执行、上下文、历史、外部效果与任务所有权，阅读现有六章试读稿。
---

# 六章阅读路线

从纯状态转换出发，逐步遇到进程、数据库与外部世界。以下六章已有试读正文；其余章节当前以[30 张章节设计卡](../book/chapter-cards.md)记录目标、依赖与写作计划。

第一次阅读先看[先修自测与桥接](../book/prerequisites.md)。这条路线只依赖已有正文、桥接页和实验手册，不要求先读尚未成稿的章节。阅读中可随时查[术语表](../book/glossary.md)。

## 建议顺序

| 顺序 | 正文 | 进入前会什么 | 读完能解释什么 |
| --- | --- | --- | --- |
| 01 | [第 2 章 · 状态机、命令、事件与系统不变量](../book/ch02-agent-state-machine.md) | 函数输入输出、元组和 map；可先查[示例语法](../book/prerequisites.md#读懂示例语法) | 为什么命令可以拒绝；错 ID 为什么不能推进状态；先做 [L01 小练习](../labs/L01-state-machine.md#first-exercise) |
| 02 | [第 5 章 · Agent Loop 的理论、设计与实现](../book/ch05-agent-loop-and-tools.md) | 第 2 章；[进程与事务桥接](../book/prerequisites.md#纯转换与事务) | 模型提议与工具执行为何分开；半截参数、取消和完整结果如何处理 |
| 03 | [第 8 章 · Session、Turn、Message 与状态演化](../book/ch08-session-context.md) | 第 5 章的一次模型/工具轮次 | 完整会话如何变成有限输入；为何权限和回执不能当普通叙述裁掉 |
| 04 | [第 14 章 · Event History、Checkpoint 与纯重建](../book/ch14-history-checkpoints-and-replay.md) | 第 2 章的 seq 与事件、第 8 章的来源清单；[历史桥接](../book/prerequisites.md#从历史到外部效果) | 重建与恢复执行的区别；为什么状态 hash 相等不证明零外部调用 |
| 05 | [第 16 章 · 外部效果、提交协议与 Unknown 核对](../book/ch16-durable-effects-and-reconciliation.md) | 第 14 章；COMMIT 与 ACK 的差别；术语表的 operation/attempt/receipt | 效果已发生而回执丢失时为何不能盲重试；取消为何不能撤销效果 |
| 06 | [第 20 章 · Lease、Heartbeat、超时与任务所有权](../book/ch20-scheduling-and-recovery.md) | 第 16 章；[并发领取桥接](../book/prerequisites.md#并发领取)与 [L10 调度协议](../labs/L10-background-scheduling.md#2-先读调度协议) | 租约到期后旧 Worker 为什么仍需 fencing；哪些远端边界不受它保护 |

章节编号沿用全书规划，因此不连续。上表是概念阅读路线，不能把跳读正文等同于完成实验前置。动手按以下分组推进：

| 读到这里 | 实验路径 | 额外准备 |
| --- | --- | --- |
| 第 2 章 | L01 小练习 → 完整 [L01](../labs/L01-state-machine.md) | 仅内存，无需 PostgreSQL |
| 第 5、8 章 | [L02 事务](../labs/L02-transactions.md) → [L03 Streaming](../labs/L03-streaming-control.md) → [L04 工具](../labs/L04-controlled-tools.md) → [L05 Context](../labs/L05-session-context.md) | 自有实验 PostgreSQL、事务与进程基础 |
| 第 14、16 章 | [L06 历史](../labs/L06-history-checkpoints.md) → [L07 恢复](../labs/L07-recovery.md) → [L08 核对](../labs/L08-retries-and-reconciliation.md) → [L09 故障验收](../labs/L09-p2-fault-acceptance.md) | 前一行已完成；每份手册使用新编号和输出目录 |
| 第 20 章 | [L10 调度](../labs/L10-background-scheduling.md) → [L11 租约](../labs/L11-leases-heartbeats-fencing.md) → [L12 背压](../labs/L12-backpressure-budgets-fairness.md) → [L13 数据库故障](../labs/L13-database-outages-p3.md) | 前一行已完成；受控进程、真实 PostgreSQL 与所需平台能力 |

[L20 迁移与备份恢复](../labs/L20-history-migration-backup-restore.md)是后续综合练习，先按其前置完成课程后再做，不作为首次读第 14 章的必做任务。

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

**正文**解释问题、反例与实现选择。**实验手册**给出准备、任务、命令和验收证据。**章节设计卡**组织全书七篇、三十章的后续写作。三种材料各有用途，六章正文均仍处于试读阶段。

若按完整课程推进，使用[十二单元课程地图](../docs/course-map.md)。实际实验顺序为：

1. 完成 C01—C06，建立状态、事务、工具、历史与恢复基础。
2. 先做 C07 的 L10，再做 C08 的 L11，然后回到 C07 完成 L12/L13。
3. 进入 C09—C12 的隔离、MCP、编排、审批、评估与综合验收。

L23—L25 补充冻结候选、版本化发行评估与跨环境验证。需要核对整体技术证据时，可查[结果索引](../docs/results-index.md)与[证据阅读说明](../docs/evidence-guide.md)。

## 把卡点变成可复验的问题

读完一章，试着用自己的话解释表格中的问题，再用对应实验给出证据。记录卡点时包含章节和小节、实际命令、期望与结果，保留原始输出。

本轮由多个 subagent 模拟不同阅读起点，审查路线、概念、练习和界面；暂不安排真人试读，也不公开发布。模拟评审可以发现问题，但不能给出真人理解率、满意度或实际学习耗时。[历史六章试读协议](../book/reader-study/README.md)保留其原有发行证据契约，模拟记录不填入真人反馈字段。

::: tip 阅读位置
本站仅在此浏览器保存最近阅读的正文章节，便于从首页或本页继续阅读。记录不会发送到服务器，可随时清除；浏览器禁止本地存储时，阅读仍可正常使用。
:::
