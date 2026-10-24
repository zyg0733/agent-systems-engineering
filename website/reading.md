---
title: 六章阅读路线
description: 按状态、执行、上下文、历史、外部效果与任务所有权，阅读现有六章试读稿。
---

# 六章阅读路线

从纯状态转换出发，逐步遇到进程、数据库与外部世界。以下六章已有试读正文；其余章节当前以[30 张章节设计卡](../book/chapter-cards.md)记录目标、依赖与写作计划。

<ReadingProgress />

## 建议顺序

| 顺序 | 正文 | 带着这个问题读 | 配套实验 |
| --- | --- | --- | --- |
| 01 | [第 2 章 · 状态机、命令、事件与系统不变量](../book/ch02-agent-state-machine.md) | 为什么命令可以拒绝，事件却能重建状态？ | [L01 状态机](../labs/L01-state-machine.md) |
| 02 | [第 5 章 · Agent Loop 的理论、设计与实现](../book/ch05-agent-loop-and-tools.md) | 模型提出工具调用后，谁决定能否执行？ | [L03 Streaming](../labs/L03-streaming-control.md)、[L04 受控工具](../labs/L04-controlled-tools.md) |
| 03 | [第 8 章 · Session、Turn、Message 与状态演化](../book/ch08-session-context.md) | 完整会话如何变成有限的模型输入？ | [L05 Session 与 Context](../labs/L05-session-context.md) |
| 04 | [第 14 章 · Event History、Checkpoint 与纯重建](../book/ch14-history-checkpoints-and-replay.md) | 重建历史和恢复执行为什么是两件事？ | [L06 历史与检查点](../labs/L06-history-checkpoints.md)、[L20 迁移与备份恢复](../labs/L20-history-migration-backup-restore.md) |
| 05 | [第 16 章 · 外部效果、提交协议与 Unknown 核对](../book/ch16-durable-effects-and-reconciliation.md) | 外部效果已发生、回执丢失时，可以直接重试吗？ | [L07 恢复](../labs/L07-recovery.md)、[L08 重试与核对](../labs/L08-retries-and-reconciliation.md) |
| 06 | [第 20 章 · Lease、Heartbeat、超时与任务所有权](../book/ch20-scheduling-and-recovery.md) | 租约到期后，旧 Worker 为什么仍需 fencing？ | [L11 租约与 fencing](../labs/L11-leases-heartbeats-fencing.md)、[L13 数据库故障](../labs/L13-database-outages-p3.md) |

章节编号沿用全书规划，因此不连续。上表给出阅读联系；动手前仍需检查每份实验的前置条件。

## 读正文，做实验，查设计卡

**正文**解释问题、反例与实现选择。**实验手册**给出准备、任务、命令和验收证据。**章节设计卡**组织全书七篇、三十章的后续写作。三种材料各有用途，六章正文均仍处于试读阶段。

若按完整课程推进，使用[十二单元课程地图](../docs/course-map.md)。实际实验顺序为：

1. 完成 C01—C06，建立状态、事务、工具、历史与恢复基础。
2. 先做 C07 的 L10，再做 C08 的 L11，然后回到 C07 完成 L12/L13。
3. 进入 C09—C12 的隔离、MCP、编排、审批、评估与综合验收。

L23—L25 补充冻结候选、版本化发行评估与跨环境验证。需要核对整体技术证据时，可查[结果索引](../docs/results-index.md)与[证据阅读说明](../docs/evidence-guide.md)。

## 把卡点变成可复验的问题

读完一章，试着用自己的话解释表格中的问题，再用对应实验给出证据。记录卡点时包含章节和小节、实际命令、期望与结果，保留原始输出。

参与正式试读请先阅读[六章试读协议](../book/reader-study/README.md)，确认冻结版本、独立练习副本和反馈要求。自动测试与技术审阅各自有用途；外部真人试读仍按协议单独验收。

::: tip 阅读位置
本站仅在此浏览器保存最近阅读的正文章节，便于从首页或本页继续阅读。记录不会发送到服务器，可随时清除；浏览器禁止本地存储时，阅读仍可正常使用。
:::
